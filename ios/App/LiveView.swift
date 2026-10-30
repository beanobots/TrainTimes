import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit

/// The Nearby tab: next trains for every line at nearby stations, and, switched on, the next
/// buses at nearby stops and the bikes at nearby Citi Bike docks.
struct LiveView: View {
    /// Set when the Nearby widget's "allow location" link opens the app.
    @Binding var allowingLocation: Bool
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @State private var location = NearbyLocation()
    @State private var path = NavigationPath()
    @State private var live = LiveTrains()
    /// A map-picked place Nearby uses instead of your location, until Near Me is tapped.
    @State private var pin: CLLocation?
    @State private var droppingPin = false
    /// Closest stations to `here`, nearest first. Recomputed only when `here` changes,
    /// not on every redraw.
    @State private var nearby: [Nearby.Result] = []
    @State private var camera = MapCameraPosition.userLocation(fallback: .automatic)
    /// The chips and card over the map's bottom, for the map to frame clear of them.
    @State private var cardsHeight: CGFloat = 0
    /// The trains' full height, for the card to be no taller.
    @State private var trainsHeight: CGFloat = 0
    /// What Nearby lists, each a toggle at the foot of its card; all may be off.
    @AppStorage("nearbyShowsSubway") private var showsSubway = true
    @AppStorage("nearbyShowsBuses") private var showsBuses = false
    /// Citi Bike docks with classic bikes, e-bikes, or either, as the Citi Bike menu picks.
    @AppStorage("nearbyShowsBikes") private var showsClassicBikes = false
    @AppStorage("nearbyShowsEBikes") private var showsEBikes = false
    /// The map mark last tapped, for the card to scroll to its place.
    @State private var focusedMark: String?
    /// The bus places near `here`, as last loaded.
    @State private var buses: NearbyBusList = .finding
    /// The Citi Bike docks near `here`, nearest first; nil while finding them, and `docksFailed`
    /// if the feed couldn't be had.
    @State private var docks: [NearbyDock]?
    @State private var docksFailed = false
    /// When the last load finished, whatever it loaded.
    @State private var updated: Date?
    /// Each map mark's size, by its `mapMarks` id, and those hidden for overlapping another.
    @State private var markSizes: [String: CGSize] = [:]
    @State private var hiddenMarks: Set<String> = []

    /// The page's side margin and its card's corners, as New Trip's.
    private static let margin: CGFloat = 16
    private static let card = RoundedRectangle(cornerRadius: 26, style: .continuous)
    /// The status bar's room over the top of the map.
    private static let statusBarRoom: CGFloat = 70
    /// The card's most height, its modes row included, as New Trip's (`NewTripView.cardMax`);
    /// past it the trains scroll within it.
    private static let cardHeight: CGFloat = 250
    /// The modes row's height at the card's foot, as New Trip's.
    private static let modesRowHeight: CGFloat = 58

    /// The pin, or else your location.
    private var here: CLLocation? { pin ?? location.location }

    /// Clears the pin and re-locates, even if you haven't moved. Times reload once
    /// the nearby stations change.
    private func findLocation() {
        pin = nil
        location.find()
        Task { await load() }
    }

    /// Every nearby station's trains, fetched together; none with Subway off.
    private var everyTrain: [Selection] {
        showsSubway ? nearby.flatMap(\.station.lineSelections) : []
    }

    /// The bus places listed: up to three, nearest first.
    private var busPlaces: [NearbyBusPlace] { showsBuses ? Array(buses.places.prefix(3)) : [] }
    /// The nearest three docks with the bikes toggled on to take.
    private var shownDocks: [NearbyDock] {
        guard let bikes else { return [] }
        return Array((docks ?? []).filter { bikes.count(at: $0.dock) > 0 }.prefix(3))
    }
    private var bikes: NearbyBikes? {
        switch (showsClassicBikes, showsEBikes) {
        case (true, true): .both
        case (true, false): .bike
        case (false, true): .eBike
        case (false, false): nil
        }
    }
    private var showsBikes: Bool { bikes != nil }

    /// Restarts loading when any of it changes.
    private var loadKey: LoadKey {
        LoadKey(trains: everyTrain.map(\.trainID), subway: showsSubway, buses: showsBuses, bikes: showsBikes,
                lat: here?.coordinate.latitude, lon: here?.coordinate.longitude)
    }

    private var marks: TimeMarks { settings.timeMarks(withoutColor: withoutColor) }

    var body: some View {
        NavigationStack(path: $path) {
            // As New Trip: the map the whole screen, the stations near you on it, and their
            // trains in a glass card over its bottom
            map
                // Framed clear of the status bar and the card; its logo and Legal over the card
                .safeAreaPadding(.top, Self.statusBarRoom)
                // Half a sign more, as signs sit centred on their places
                .safeAreaPadding(.bottom, cardsHeight + 32)
                .safeAreaPadding(.leading, 12)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .overlay(alignment: .bottom) {
                    VStack(spacing: 10) {
                        chips
                        card
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
                    .padding(.horizontal, Self.margin)
                    .padding(.bottom, 8)
                }
                .navigationDestination(for: Selection.self) { selection in
                    TrainDetail(selection: selection)
                        // Fresh identity per train; otherwise a page replaced in place would keep
                        // the previous train's state
                        .id(selection.trainID)
                        .toolbar(.visible, for: .navigationBar)
                }
                // No title bar, as New Trip: the tab says where you are
                .toolbar(.hidden, for: .navigationBar)
                .onChange(of: framedIDs, initial: true) { frame() }
                .onChange(of: here) { frame() }
                .onChange(of: showsBuses) { if showsBuses { buses = .finding } }
                .onChange(of: showsBikes) { if showsBikes { docks = nil; docksFailed = false } }
                .sheet(isPresented: $droppingPin) {
                    DropPinSheet(start: (pin ?? location.location)?.coordinate) { pin = $0 }
                }
                .onAppear { location.start() }
                .onChange(of: allowingLocation, initial: true) { _, allowing in
                    guard allowing else { return }
                    allowingLocation = false
                    path = NavigationPath()
                    if location.status == .denied || location.status == .restricted,
                       let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    } else {
                        findLocation()
                    }
                }
                .onChange(of: here, initial: true) { _, here in
                    nearby = here.map { Nearby.stations(near: $0, limit: 3) } ?? []
                }
                // Reload every minute and when the train list changes; pull-to-refresh (in the
                // card) and returning to the app also re-locate (unless pinned)
                .updatingTrains(live, id: loadKey, refreshing: {
                    if location.isAllowed && pin == nil { location.find() }
                }, load: load)
        }
    }

    /// You (or the pin), the nearby stations as signs, bus stops as blue signs and docks with
    /// their bikes. Where marks would overlap, the farther-down one in `mapMarks` hides until
    /// you zoom in far enough for it to fit.
    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let pin {
                    Marker("Pin", systemImage: "mappin", coordinate: pin.coordinate)
                        .tint(.red)
                } else {
                    UserAnnotation()
                }
                if showsStations && showsSubway {
                    ForEach(nearby) { result in
                        Annotation(result.station.name, coordinate: CLLocationCoordinate2D(latitude: result.station.lat,
                                                                                         longitude: result.station.lon)) {
                            Button { focusedMark = "s" + result.id } label: {
                                MapSign(name: result.station.name, fill: .black) {
                                    ForEach(result.station.routes, id: \.self) { LineBullet(route: $0, size: 15) }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows its trains")
                            .placed(id: "s" + result.id, hidden: hiddenMarks, sizes: $markSizes)
                        }
                        // The signs carry their names
                        .annotationTitles(.hidden)
                    }
                }
                if showsStations {
                    ForEach(busPlaces, id: \.self) { place in
                        if let stop = place.ways.first?.stop {
                            Annotation(place.name, coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)) {
                                Button { focusedMark = "b" + stop.id } label: {
                                    MapSign(name: place.name, fill: BusBadge.blue) {
                                        ForEach(place.lines(at: live.now).map(\.line), id: \.self) { MapSignBusBadge(line: $0) }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Shows its buses")
                                .placed(id: "b" + stop.id, hidden: hiddenMarks, sizes: $markSizes)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    if let bikes {
                        ForEach(shownDocks) { near in
                            Annotation(near.dock.name, coordinate: near.dock.coordinate) {
                                Button { focusedMark = "d" + near.id } label: {
                                    DockMark(dock: near.dock, bikes: bikes)
                                        // Redrawn when its counts change, which the map's marks
                                        // otherwise can miss
                                        .id(bikes.kinds.map { near.dock.available($0) })
                                        // Room round the small pill to tap
                                        .padding(6)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Shows its bikes")
                                .placed(id: "d" + near.id, hidden: hiddenMarks, sizes: $markSizes)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                }
            }
            .onMapCameraChange(frequency: .continuous) { layOutMarks(proxy) }
            .onChange(of: markSizes) { layOutMarks(proxy) }
            .onChange(of: framedIDs) { layOutMarks(proxy) }
        }
    }

    /// Every mark on the map, most important first: the nearest station, bus stop and dock, then
    /// the next nearest of each, and so on, so each kind shows where there's room for one.
    private var mapMarks: [(id: String, coordinate: CLLocationCoordinate2D)] {
        guard showsStations else { return [] }
        let stations = showsSubway ? nearby.map { ("s" + $0.id, CLLocationCoordinate2D(latitude: $0.station.lat, longitude: $0.station.lon)) } : []
        let stops = busPlaces.compactMap { place in
            place.ways.first.map { ("b" + $0.stop.id, CLLocationCoordinate2D(latitude: $0.stop.latitude, longitude: $0.stop.longitude)) }
        }
        let kinds = [stations, stops, shownDocks.map { ("d" + $0.id, $0.dock.coordinate) }]
        return (0..<(kinds.map(\.count).max() ?? 0)).flatMap { index in
            kinds.compactMap { index < $0.count ? $0[index] : nil }
        }
    }

    /// Hides each mark that would overlap one before it in `mapMarks` where the map is now.
    private func layOutMarks(_ proxy: MapProxy) {
        var placed: [CGRect] = []
        var hidden: Set<String> = []
        for mark in mapMarks {
            guard let size = markSizes[mark.id], let point = proxy.convert(mark.coordinate, to: .local) else { continue }
            // Centred on its place, with a little room round it
            let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                              width: size.width, height: size.height).insetBy(dx: -3, dy: -3)
            if placed.contains(where: { $0.intersects(rect) }) {
                hidden.insert(mark.id)
            } else {
                placed.append(rect)
            }
        }
        if hidden != hiddenMarks {
            withAnimation(.easeOut(duration: 0.15)) { hiddenMarks = hidden }
        }
    }

    /// Everything on the map, to frame it again when they change.
    private var framedIDs: [String] { mapMarks.map(\.id) }

    /// Frames you (or the pin) and the nearby stations; just you before there are any.
    private func frame() {
        // Everything toggled off: leave the map where it is
        guard let here, showsSubway || showsBuses || showsBikes else { return }
        let stations = showsSubway ? nearby.map { CLLocationCoordinate2D(latitude: $0.station.lat, longitude: $0.station.lon) } : []
        let stops = busPlaces.compactMap { $0.ways.first.map { CLLocationCoordinate2D(latitude: $0.stop.latitude, longitude: $0.stop.longitude) } }
        let points = [here.coordinate] + stations + stops + shownDocks.map(\.dock.coordinate)
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return }
        // Room round the edges, and at least a few blocks across
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            // Room enough for the signs, which sit centred on their places, to clear the edges
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.9, 0.006),
                                   longitudeDelta: max((maxLon - minLon) * 1.9, 0.006)))
        withAnimation(.smooth) { camera = .region(region) }
    }

    /// Near Me and Drop Pin as glass chips over the card, as New Trip's Home and Work, the one
    /// the trains are for tinted. They lose their words where the row's too narrow for them.
    private var chips: some View {
        GlassEffectContainer(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                places(iconOnly: false)
                places(iconOnly: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func places(iconOnly: Bool) -> some View {
        HStack(spacing: 8) {
            chip("Near Me", symbol: "location.fill", tinted: pin == nil && location.isAllowed, iconOnly: iconOnly,
                 action: findLocation)
                .accessibilityHint("Finds stations near where you are now")
            chip("Drop Pin", symbol: pin == nil ? "mappin" : "mappin.circle.fill", tinted: pin != nil, iconOnly: iconOnly) {
                droppingPin = true
            }
            .accessibilityHint(pin == nil ? "Drops a pin on the map to find stations near it" : "Moves the pin")
        }
        .fixedSize()
    }

    /// What Nearby lists, at the card's foot as New Trip's ways to go: Subway and Bus each a
    /// toggle, Citi Bike a menu, then when it last loaded. All off leaves just the row.
    private var modesRow: some View {
        HStack(spacing: 8) {
            modeToggle("Subway", symbol: "tram.fill", on: $showsSubway)
            modeToggle("Bus", symbol: "bus.fill", on: $showsBuses)
            bikeMenu
            Spacer(minLength: 0)
            if let updated, listing {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Self.margin)
        .frame(height: Self.modesRowHeight)
    }

    /// What Nearby lists, an icon tinted while it's on, as New Trip's.
    private func modeToggle(_ name: String, symbol: String, on: Binding<Bool>) -> some View {
        Button {
            withAnimation(.smooth) { on.wrappedValue.toggle() }
        } label: {
            Label(name, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on.wrappedValue ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 48, height: 38)
                .background(on.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
        .accessibilityHint(name == "Subway" ? "Shows stations nearby" : "Shows bus stops nearby")
    }

    /// Citi Bike docks, a menu as New Trip's: off, or docks with bikes, e-bikes or either. Tinted
    /// while on, a bolt badge on it while it counts e-bikes.
    private var bikeMenu: some View {
        Menu {
            Picker("Citi Bike", selection: Binding(
                get: { bikes?.rawValue ?? "" },
                set: { picked in
                    let choice = NearbyBikes(rawValue: picked)
                    withAnimation(.smooth) {
                        showsClassicBikes = choice == .bike || choice == .both
                        showsEBikes = choice == .eBike || choice == .both
                    }
                })) {
                Text("Off").tag("")
                ForEach(NearbyBikes.allCases, id: \.self) { choice in
                    Label(choice.name, systemImage: choice.symbol).tag(choice.rawValue)
                }
            }
        } label: {
            Image(systemName: "bicycle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(showsBikes ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 48, height: 38)
                .background(showsBikes ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if showsEBikes {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(.yellow))
                            .offset(x: 3, y: -3)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Citi Bike")
        .accessibilityValue(bikes?.name ?? "Off")
        .accessibilityHint("Shows Citi Bike docks nearby")
    }

    private func chip(_ title: String, symbol: String, tinted: Bool, iconOnly: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if iconOnly {
                    Image(systemName: symbol)
                } else {
                    Label(title, systemImage: symbol)
                }
            }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .padding(.horizontal, iconOnly ? 12 : 14)
                .frame(height: 38)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel(title)
        .accessibilityAddTraits(tinted ? .isSelected : [])
    }

    /// Whether there are stations, stops or docks to list, rather than why not.
    private var listing: Bool {
        showsStations && (showsSubway && !nearby.isEmpty || showsBuses || showsBikes)
    }

    /// The trains at each nearby station, the buses at each stop and the bikes at each dock,
    /// scrolling within the card past `cardHeight`, or, with none to show, why, with what to do
    /// about it, at its full height so its buttons show; the modes row at its foot. All toggled
    /// off, just the row.
    private var card: some View {
        VStack(spacing: 0) {
            if listing {
                ScrollViewReader { scroller in
                    ScrollView {
                        trains
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { trainsHeight = $0 }
                    }
                    // A tap on a map mark brings its place to the top of the card
                    .onChange(of: focusedMark) { _, mark in
                        guard let mark else { return }
                        withAnimation(.smooth) { scroller.scrollTo(mark, anchor: .top) }
                        focusedMark = nil
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(trainsHeight, Self.cardHeight - Self.modesRowHeight))
                Divider()
            } else if showsSubway || showsBuses || showsBikes {
                emptyState
                    .padding(.vertical, 16)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            modesRow
        }
        .clipShape(Self.card)
        .glassEffect(.regular, in: Self.card)
    }

    /// Any failure note, then each station, bus stop and dock as a tile of its own (stations
    /// first, then stops, then docks).
    private var trains: some View {
        VStack(spacing: 8) {
            if live.anyFailed(everyTrain) {
                UnreachableNote(timetable: live.anyFromTimetable(everyTrain))
                    .font(.subheadline)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }
            if showsSubway {
                // Identified as their map marks are, for a tap on one to scroll here
                ForEach(nearby, id: \.markID) { result in
                    NearbyTile(symbol: "tram.fill", kind: "Station", name: result.station.name,
                               walkMinutes: result.walkMinutes) {
                        ForEach(result.station.routes, id: \.self) { route in
                            NearbyLineRow(station: result.station, route: route, live: live, marks: marks) { path.append($0) }
                        }
                    }
                }
            }
            if showsBuses { busTiles }
            if showsBikes { dockTiles }
            if !SharedStore.isAvailable {
                Label("The widget can't see your choice on this install, so it keeps showing Prospect Av (R) toward Manhattan. Make sure the app and widget both have the App Group in Xcode, then reinstall.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
            }
        }
        .padding(8)
    }

    /// Each nearby bus place's lines with their next buses each way; or, with none, why.
    @ViewBuilder private var busTiles: some View {
        switch buses {
        case .finding:
            NearbyNoteTile(symbol: "bus.fill", text: "Finding bus stops…", finding: true)
        case .unavailable:
            NearbyNoteTile(symbol: "bus.fill", text: "Bus times aren't available right now.")
        case .places(let places) where places.isEmpty:
            NearbyNoteTile(symbol: "bus.fill", text: "No bus stops within ¼ mile.")
        case .places:
            ForEach(busPlaces, id: \.self) { place in
                NearbyTile(symbol: "bus.fill", kind: "Bus stop", name: place.name, walkMinutes: place.walkMinutes) {
                    let lines = place.lines(at: live.now)
                    if lines.isEmpty {
                        Text("No buses due").font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    ForEach(lines, id: \.line) { pick in
                        NearbyBusRow(pick: pick, now: live.now, marks: marks)
                    }
                }
                .id("b" + (place.ways.first?.stop.id ?? ""))
            }
        }
    }

    /// The nearest docks with the bikes toggled on, and how many; or, with none, why.
    @ViewBuilder private var dockTiles: some View {
        if docksFailed {
            NearbyNoteTile(symbol: "bicycle", text: "Citi Bike isn't available right now.")
        } else if docks != nil, let bikes {
            if shownDocks.isEmpty {
                NearbyNoteTile(symbol: bikes.symbol, text: "No docks with \(bikes == .eBike ? "e-bikes" : "bikes") within ½ mile.")
            }
            ForEach(shownDocks, id: \.markID) { near in
                NearbyTile(symbol: bikes.symbol, kind: "Citi Bike dock", name: near.dock.name, walkMinutes: near.walkMinutes) {
                    NearbyDockCounts(dock: near.dock, bikes: bikes)
                }
            }
        } else {
            NearbyNoteTile(symbol: "bicycle", text: "Finding Citi Bike docks…", finding: true)
        }
    }

    /// Whether there's a place to list stations near: the pin, or your location once found.
    private var showsStations: Bool {
        pin != nil || (location.isAllowed && !location.failed && location.location != nil)
    }

    /// Why there are no station cards, with what to do about it.
    @ViewBuilder private var emptyState: some View {
        if pin != nil {
            ContentUnavailableView {
                Label("No Stations Nearby", systemImage: "mappin.slash")
            } description: {
                Text("No stations within \(Nearby.rangeDescription) of the pin.")
            } actions: {
                Button("Move the Pin") { droppingPin = true }
                    .buttonStyle(.glassProminent)
            }
        } else if location.status == .notDetermined {
            ContentUnavailableView {
                Label("Trains Near You", systemImage: "location.fill")
            } description: {
                Text("See the next trains at the stations closest to you, or drop a pin anywhere.")
            } actions: {
                Button("Allow Location") { location.find() }
                    .buttonStyle(.glassProminent)
                Button("Drop a Pin") { droppingPin = true }
            }
        } else if !location.isAllowed {
            ContentUnavailableView {
                Label("Location Is Off", systemImage: "location.slash")
            } description: {
                Text("Turn on Location for Leeway in Settings, or drop a pin to see trains near somewhere else.")
            } actions: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Turn On in Settings", destination: url)
                        .buttonStyle(.glassProminent)
                }
                Button("Drop a Pin") { droppingPin = true }
            }
        } else if location.failed {
            ContentUnavailableView {
                Label("Couldn't Find You", systemImage: "location.slash")
            } description: {
                Text("Your location isn't available right now.")
            } actions: {
                Button("Try Again") { location.find() }
                    .buttonStyle(.glassProminent)
            }
        } else if location.location == nil {
            ProgressView("Finding stations near you…")
        } else {
            ContentUnavailableView {
                Label("No Stations Nearby", systemImage: "tram")
            } description: {
                Text("No stations within \(Nearby.rangeDescription) of you.")
            } actions: {
                Button("Drop a Pin") { droppingPin = true }
            }
        }
    }

    /// Loads what's switched on together. Rows show a dash until their first load.
    private func load() async {
        let trains = everyTrain
        let wantsBuses = showsBuses, wantsBikes = showsBikes
        let here = here
        async let busPlaces: [NearbyBusPlace]? = if wantsBuses, let here { await NearbyBuses.places(near: here) } else { nil }
        async let allDocks: [CitiBike.Dock]? = wantsBikes && here != nil ? await CitiBike.docks() : nil
        // Nearby rows show only the line's own trains, which are all in its own feeds
        await live.load(trains, includingOtherLines: false)
        let places = await busPlaces, found = await allDocks
        guard !Task.isCancelled else { return }
        if wantsBuses, here != nil {
            // A failed refresh keeps the stops last found, rather than dropping them
            buses = places.map { .places($0) } ?? (buses.places.isEmpty ? .unavailable : buses)
        }
        if wantsBikes, let here {
            docksFailed = found == nil
            // All within range: the toggles pick which three show
            docks = found.map { NearbyDock.nearest(to: here, among: $0, limit: 40) }
        }
        updated = .now
    }
}

extension Nearby.Result {
    /// Its map mark's and card tile's id.
    fileprivate var markID: String { "s" + id }
}

extension NearbyDock {
    fileprivate var markID: String { "d" + id }
}

/// What restarts Nearby's loading: its trains, what's switched on, and where it's near.
private struct LoadKey: Equatable {
    var trains: [String]
    var subway: Bool
    var buses: Bool
    var bikes: Bool
    var lat: Double?
    var lon: Double?
}

/// A Citi Bike dock near Nearby's place.
struct NearbyDock: Identifiable, Hashable {
    let dock: CitiBike.Dock
    let meters: Double

    var id: String { dock.id }
    var walkMinutes: Int { max(1, Int((TripPlanner.walkSeconds(meters) / 60).rounded())) }

    /// Beyond this (about half a mile), no docks are listed.
    private static let range: Double = 800

    /// Up to `limit` docks within `range` of `location`, nearest first.
    static func nearest(to location: CLLocation, among docks: [CitiBike.Dock], limit: Int = 3) -> [NearbyDock] {
        docks.map { NearbyDock(dock: $0, meters: location.distance(from: $0.location)) }
            .filter { $0.meters <= range }
            .sorted { $0.meters < $1.meters }
            .prefix(limit)
            .map { $0 }
    }
}

/// One station, bus stop or dock in Nearby's card, a tile of its own so each is clearly apart
/// from the next: what it is and its name over its walk, then its rows.
private struct NearbyTile<Content: View>: View {
    let symbol: String
    /// "Station", "Bus stop": said by VoiceOver, shown as the icon.
    let kind: String
    let name: String
    let walkMinutes: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(name)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Label("\(walkMinutes) min", systemImage: "figure.walk")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind), \(name), \(walkMinutes) minute walk")
            .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A tile saying why there's no bus stop or dock to list, or that they're being found.
private struct NearbyNoteTile: View {
    let symbol: String
    let text: String
    var finding = false

    var body: some View {
        HStack(spacing: 8) {
            if finding {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).font(.caption.weight(.bold))
            }
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// One bus line at a stop with its next buses each way, as `NearbyLineRow` has a train's.
private struct NearbyBusRow: View {
    let pick: NearbyBusPick
    let now: Date
    let marks: TimeMarks

    var body: some View {
        HStack(spacing: 22) {
            BusBadge(line: pick.line, size: 30)
                .frame(width: 44)
            VStack(spacing: 0) {
                ForEach(Array(pick.ways.enumerated()), id: \.element.stop.id) { index, way in
                    if index > 0 {
                        Divider().padding(.vertical, 8)
                    }
                    let buses = way.arrivals.compactMap { bus in
                        bus.time.flatMap { $0 > now ? Arrival(route: pick.line, time: $0, stop: way.stop.id,
                                                              lastStop: bus.destination ?? "", isLive: bus.isLive) : nil }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(way.name).lineLimit(1)
                            if let stops = way.arrivals.first?.stopsAway {
                                Text(stops == 1 ? "1 stop away" : "\(stops) stops away")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        Minutes(trains: buses, failed: false, now: now, marks: marks, none: "No buses")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(BusBadge.spokenName(pick.line)) to \(way.name)")
                    .accessibilityValue(Minutes.spoken(buses, now: now))
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Which bikes Nearby counts at a dock, as its Citi Bike menu picks. Free docks aren't shown
/// here: they matter once you're riding, which New Trip's bike trips show.
enum NearbyBikes: String, CaseIterable {
    case bike
    case eBike
    case both

    var name: String {
        switch self {
        case .bike: "Bikes"
        case .eBike: "E-Bikes"
        case .both: "Both"
        }
    }

    var symbol: String { self == .eBike ? "bolt.fill" : "bicycle" }

    /// The bikes of this kind to take at `dock`.
    func count(at dock: CitiBike.Dock) -> Int {
        switch self {
        case .bike: dock.available(.bike)
        case .eBike: dock.available(.eBike)
        case .both: dock.available(.bike) + dock.available(.eBike)
        }
    }

    var kinds: [CitiBike.Kind] {
        switch self {
        case .bike: [.bike]
        case .eBike: [.eBike]
        case .both: [.bike, .eBike]
        }
    }
}

/// A dock's bikes, e-bikes or both side by side, as the Citi Bike menu picks, in orange where
/// they're few (`CitiBike.few`).
private struct NearbyDockCounts: View {
    let dock: CitiBike.Dock
    let bikes: NearbyBikes

    var body: some View {
        HStack(spacing: 0) {
            ForEach(bikes.kinds, id: \.self) { kind in
                count(dock.available(kind), kind.name + "s", symbol: kind == .eBike ? "bolt.fill" : "bicycle")
            }
        }
        .padding(.vertical, 6)
    }

    private func count(_ number: Int, _ name: String, symbol: String) -> some View {
        VStack(spacing: 2) {
            Text("\(number)")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(number < CitiBike.few ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            Label(name, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number) \(name)")
    }
}

/// A station or bus stop on Nearby's map, as a station sign: the name in white on `fill`
/// (black for the subway, bus blue for a stop) over its bullets or badges, a white rule along
/// the top.
private struct MapSign<Marks: View>: View {
    let name: String
    let fill: Color
    @ViewBuilder let marks: Marks

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 2) { marks }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(.white).frame(height: 1).padding(.horizontal, 6).padding(.top, 2)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .fixedSize()
    }
}

/// A bus line on a bus stop's sign: white, with the line in bus blue.
private struct MapSignBusBadge: View {
    let line: String

    var body: some View {
        Text(BusBadge.label(line))
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(BusBadge.blue)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .background(.white, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel(BusBadge.spokenName(line))
    }
}

/// A dock on Nearby's map: a Citi Bike blue capsule with the bikes the Citi Bike menu picked,
/// each kind with its symbol (a bike, or a bolt for e-bikes) and count, a count on orange where
/// it's few.
private struct DockMark: View {
    let dock: CitiBike.Dock
    let bikes: NearbyBikes

    var body: some View {
        HStack(spacing: 6) {
            ForEach(bikes.kinds, id: \.self) { kind in
                count(dock.available(kind), symbol: kind == .eBike ? "bolt.fill" : "bicycle")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Capsule().fill(Color.citiBike))
        .overlay(Capsule().stroke(.white, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dock.name)
        .accessibilityValue(bikes.kinds.map { $0.count(dock.available($0)) }.joined(separator: ", "))
    }

    private func count(_ number: Int, symbol: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text("\(number)").font(.system(size: 12, weight: .heavy)).monospacedDigit()
        }
        .padding(.horizontal, number < CitiBike.few ? 4 : 0)
        .frame(height: 16)
        .background { if number < CitiBike.few { Capsule().fill(.orange) } }
    }
}

extension View {
    /// A map mark: its size noted under `id` for laying the marks out, and hidden (and
    /// untappable) while it's among `hidden`.
    fileprivate func placed(id: String, hidden: Set<String>, sizes: Binding<[String: CGSize]>) -> some View {
        onGeometryChange(for: CGSize.self) { $0.size } action: { sizes.wrappedValue[id] = $0 }
            .opacity(hidden.contains(id) ? 0 : 1)
            .allowsHitTesting(!hidden.contains(id))
    }
}

/// Next trains for everything a Nearby tab page lists, fetched together.
@MainActor @Observable
final class LiveTrains {
    /// Next arrivals by `Selection.trainID`, as last fetched.
    private(set) var trains: [String: [Arrival]] = [:]
    /// `Selection.trainID`s whose last fetch failed. May include trains from an older
    /// list, so pages should check via `anyFailed(_:)`.
    private(set) var failed: Set<String> = []
    /// Those of `failed` showing the timetable's times instead (`TimetableStore`).
    private(set) var fromTimetable: Set<String> = []
    /// When the last load finished; nil before the first.
    private(set) var updated: Date?
    /// Ticks every few seconds so the minutes count down.
    var now = Date.now

    /// Fetches via `TrainService.trains(for:)`. Trains missing from the result lose their
    /// old times rather than count down stale ones. Trains not in `selections` keep their
    /// times and failure state, so an older load finishing late can't clear a newer one's rows.
    func load(_ selections: [Selection], includingOtherLines: Bool = true) async {
        // With nothing to fetch, nothing failed
        guard !selections.isEmpty else {
            failed = []
            return
        }
        let fetched = await TrainService.trains(for: selections, includingOtherLines: includingOtherLines)
        // Cancelled by a newer list; not a failure
        guard !Task.isCancelled else { return }
        let asked = Set(selections.map(\.trainID))
        let missing = asked.subtracting(fetched.keys)
        trains.merge(fetched) { $1 }
        // Those the MTA couldn't give, from the timetable if there is one
        let timetable = missing.isEmpty ? nil : TimetableStore.load()
        let timed = timetable.map {
            TrainService.trains(for: selections.filter { missing.contains($0.trainID) }, from: $0)
        } ?? [:]
        for trainID in missing { trains[trainID] = timed[trainID] }
        failed.subtract(asked)
        failed.formUnion(missing)
        fromTimetable.subtract(asked)
        fromTimetable.formUnion(timed.keys)
        now = .now
        updated = now
    }

    /// Whether any of a page's `selections` failed their last fetch.
    func anyFailed(_ selections: [Selection]) -> Bool {
        !failed.isDisjoint(with: selections.map(\.trainID))
    }

    /// Whether any of them show the timetable's times, as their last fetch failed.
    func anyFromTimetable(_ selections: [Selection]) -> Bool {
        !fromTimetable.isDisjoint(with: selections.map(\.trainID))
    }
}

extension View {
    /// Updates `now` every 10 seconds so, between loads, minutes count down and
    /// uncatchable trains drop off.
    func ticking(_ now: Binding<Date>) -> some View {
        task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                now.wrappedValue = .now
            }
        }
    }

    /// Runs `load` now and every minute (restarting when `id` changes), and after
    /// `refreshing` on pull-to-refresh or app foregrounding. Ticks `live.now` in between.
    fileprivate func updatingTrains<ID: Equatable>(_ live: LiveTrains, id: ID, refreshing: @escaping () -> Void = {},
                                                   load: @escaping () async -> Void) -> some View {
        modifier(UpdatingTrains(live: live, id: id, refreshing: refreshing, load: load))
    }
}

private struct UpdatingTrains<ID: Equatable>: ViewModifier {
    let live: LiveTrains
    let id: ID
    let refreshing: () -> Void
    let load: () async -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .refreshable {
                refreshing()
                await load()
            }
            .task(id: id) {
                while !Task.isCancelled {
                    await load()
                    // After a failure, sooner; and as soon as the network's back (a station
                    // after a tunnel)
                    await Connectivity.shared.pause(for: .seconds(live.failed.isEmpty ? 60 : 15))
                }
            }
            .ticking(Binding { live.now } set: { live.now = $0 })
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                refreshing()
                Task { await load() }
            }
    }
}

/// Shown above a page's trains when some failed to load; `timetable` if some of them show the
/// timetable's times instead.
private struct UnreachableNote: View {
    var timetable = false

    var body: some View {
        Label(timetable ? "Couldn't reach the MTA, so some times are the timetable's. Pull down to try again."
                  : "Couldn't reach the MTA. Pull down to try again.", systemImage: "wifi.exclamationmark")
            .foregroundStyle(.secondary)
    }
}

/// One line at a station with its next trains each way, matching the Nearby widget
/// (`Station.ways(of:trains:now:)`): toward Manhattan first. Directions with no name (end of
/// the line) are omitted, as is a direction where the line terminates at a shared platform,
/// unless some of its trains continue.
private struct NearbyLineRow: View {
    let station: Station
    let route: String
    let live: LiveTrains
    let marks: TimeMarks
    let open: (Selection) -> Void

    private var ways: [LineWay] {
        station.ways(of: route, trains: live.trains, now: live.now).compactMap { $0 }
    }

    var body: some View {
        // The bullet is centred between the directions
        HStack(spacing: 22) {
            LineBullet(route: route, size: 40)
                .frame(width: 44)
            VStack(spacing: 0) {
                ForEach(Array(ways.enumerated()), id: \.element.direction) { index, way in
                    let failed = live.failed.contains(way.selection.trainID)
                    if index > 0 {
                        Divider().padding(.vertical, 8)
                    }
                    Button {
                        open(way.selection)
                    } label: {
                        // The direction sits on the next train's baseline
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(way.label)
                                    .lineLimit(1)
                                // The next train's destination
                                if let terminal = way.trains?.first?.terminal {
                                    Text(terminal)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 12)
                            // No chevron: the whole row's the tap, as New Trip's trips
                            Minutes(trains: way.trains, failed: failed, now: live.now, marks: marks)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Lines.name(of: route)) \(way.label)"
                                        + (way.trains?.first?.terminal.map { ", to \($0)" } ?? ""))
                    // The label covers the whole row, so times go in the value
                    .accessibilityValue(Minutes.spoken(way.trains, failed: failed, now: live.now))
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// A map to tap a place for Nearby to search around.
private struct DropPinSheet: View {
    /// The last pin or your location; nil falls back to Prospect Av.
    let start: CLLocationCoordinate2D?
    let drop: (CLLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var coordinate: CLLocationCoordinate2D?
    /// The middle of the map as last moved, for VoiceOver's Drop Pin Here; nil before it's moved.
    @State private var cameraCenter: CLLocationCoordinate2D?

    private var center: CLLocationCoordinate2D {
        start ?? Selection.fallback.station.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            ?? CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: 2500, longitudinalMeters: 2500))) {
                    UserAnnotation()
                    if let coordinate {
                        Marker("Pin", systemImage: "mappin", coordinate: coordinate)
                            .tint(.red)
                    }
                }
                .onTapGesture { point in
                    coordinate = proxy.convert(point, from: .local)
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    cameraCenter = context.region.center
                }
                // Without tapping a point: the pin goes in the middle of the map
                .accessibilityAction(named: "Drop Pin Here") {
                    coordinate = cameraCenter ?? center
                }
            }
            // A glass capsule floating over the map
            .safeAreaInset(edge: .bottom) {
                Text(coordinate == nil ? "Tap the map to drop a pin." : "Tap elsewhere to move it.")
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect()
                    .padding(.bottom, 8)
            }
            .navigationTitle("Drop Pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        if let coordinate {
                            drop(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                        }
                        dismiss()
                    }
                    .disabled(coordinate == nil)
                }
            }
        }
    }
}

/// The next train large ("3 min"), the two after it small beneath ("then 9, 15 min"),
/// live predictions in green.
private struct Minutes: View {
    /// Nil until fetched.
    let trains: [Arrival]?
    /// Shows "Couldn't load" instead.
    let failed: Bool
    let now: Date
    let marks: TimeMarks
    /// Shown with none to come.
    var none = "No trains"

    var body: some View {
        if failed {
            Text("Couldn't load").font(.subheadline).foregroundStyle(.secondary)
        } else if let trains {
            if trains.isEmpty {
                Text(none).font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    next(trains[0])
                    if trains.count > 1 {
                        later(trains.dropFirst().prefix(2))
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(trains, now: now))
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// VoiceOver text, e.g. "Now, 1 minute, 7 minutes by the timetable". Scheduled
    /// times say so, as their colour does on screen.
    static func spoken(_ trains: [Arrival]?, failed: Bool = false, now: Date) -> String {
        guard !failed else { return "Couldn't load" }
        guard let trains else { return "Loading" }
        guard !trains.isEmpty else { return "No trains" }
        return trains.prefix(3).map { train in
            let time = MinutesToGo(until: train.time, from: now).spoken
            return train.isLive ? time : "\(time) by the timetable"
        }
        .joined(separator: ", ")
    }

    /// The next train, large: "3 min" or "Now".
    private func next(_ train: Arrival) -> some View {
        let minutes = MinutesToGo(until: train.time, from: now)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            time(train, markSize: 11)
                .font(.title3.weight(.bold))
            if !minutes.isNow {
                Text("min").font(.footnote.weight(.semibold))
                    .foregroundStyle(train.statusColor(scheduled: .primary))
            }
        }
    }

    /// The two after it, small: "then 6, 12 min".
    private func later(_ trains: ArraySlice<Arrival>) -> some View {
        HStack(spacing: 0) {
            Text("then ").foregroundStyle(.secondary)
            ForEach(Array(trains.enumerated()), id: \.element) { index, train in
                if index > 0 {
                    Text(", ").foregroundStyle(.secondary)
                }
                time(train, markSize: 8)
            }
            Text(" min").foregroundStyle(.secondary)
        }
        .font(.footnote.weight(.medium))
    }

    /// One train's mark and minutes, in its status colour.
    private func time(_ train: Arrival, markSize: CGFloat) -> some View {
        HStack(spacing: 2) {
            StatusMark(isLive: train.isLive, marks: marks, size: markSize)
            Text(MinutesToGo(until: train.time, from: now).number)
        }
        .foregroundStyle(train.statusColor(scheduled: .primary))
    }
}

#Preview {
    LiveView(allowingLocation: .constant(false))
        .environment(WidgetStore())
        .environment(SettingsStore())
}
