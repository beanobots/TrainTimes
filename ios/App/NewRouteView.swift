import SwiftUI
import MapKit

/// New Route, planned as New Trip plans a trip: a map, From and To at the bottom, then the ways
/// there as trips are, the one tapped drawn on the map, and Save Route where Go is. Its widget's
/// size, the way back, alerts and other hours are set once it's saved, in Edit Route.
struct NewRouteView: View {
    @Environment(WidgetStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSideways) private var sideways
    @State private var widget: SavedWidget
    @State private var plan = RoutePlan()
    /// The ways there showing, From and To shrunk to a line atop them.
    @State private var showsWays: Bool
    @State private var choosingFrom = false
    @State private var choosingTo = false
    @State private var addingWay = false
    /// See Other Ways tapped: every way listed, not just the quickest two.
    @State private var showsAllWays = false
    @State private var showingCover = false
    /// Try Again taps, after the timetable didn't download.
    @State private var tries = 0
    /// The way drawn on the map, by id.
    @State private var shown: String?
    @State private var subway = true
    @State private var buses = true
    @State private var position: MapCameraPosition
    /// The cards' height over the map's bottom, which it frames the way clear of.
    @State private var cardsHeight: CGFloat = 0
    /// The map's whole size, under the bars and cards.
    @State private var mapSize: CGSize = .zero
    @FocusState private var naming: Bool
    /// The address or place From and To were picked by, each at the station or stop nearest it.
    @State private var fromNear: String?
    @State private var toNear: String?
    /// A saved place's chip tapped: the stations and stops near it, to pick To from.
    @State private var chipNear: NearAddress?

    /// With From and To both set (Save as Route in New Trip), it opens on the ways there; `fromNear`
    /// and `toNear` are the addresses its ends were picked by, if not the stations themselves.
    init(starting widget: SavedWidget, fromNear: String? = nil, toNear: String? = nil) {
        _widget = State(initialValue: widget)
        _fromNear = State(initialValue: fromNear)
        _toNear = State(initialValue: toNear)
        _showsWays = State(initialValue: widget.start.id != nil && widget.end.id != nil)
        _position = State(initialValue: Self.city)
    }

    private static let margin: CGFloat = 16
    private static let cornerRadius: CGFloat = 26
    private static let barHeight: CGFloat = 48
    private static let animation = Animation.smooth(duration: 0.35)

    var body: some View {
        map
            .overlay(alignment: .top) { top }
            .overlay(alignment: sideways ? .bottomLeading : .bottom) {
                VStack(spacing: 10) {
                    if showsWays {
                        waysCard
                        saveBar
                    } else {
                        chips
                        endsCard
                    }
                }
                .frame(maxWidth: sideways ? Sideways.width : 500)
                .frame(maxWidth: .infinity, alignment: sideways ? .leading : .center)
                .padding(.leading, sideways ? Sideways.inset : 0)
                .padding(.bottom, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
            }
            // By place, not station: another station in the same complex has the same ways
            .task(id: "\(widget.start.place ?? "") \(widget.end.place ?? "") \(tries)") {
                showsAllWays = false
                await RoutePlan.warmBusRoutes()
                await plan.plan(for: widget, fresh: true, retry: tries > 0)
                limitModes()
            }
            .onChange(of: plan.revision) { apply() }
            .onChange(of: subway) { limitModes() }
            .onChange(of: buses) { limitModes() }
            .onChange(of: shownWay) { frame() }
            .onChange(of: showsWays) { frame() }
            .onChange(of: cardsHeight) { frame() }
            .onChange(of: mapSize) { frame() }
            .onChange(of: widget.start.id) { if !showsWays { frame() } }
            .sheet(isPresented: $choosingFrom) {
                RouteEndSearch(title: "From", reachableFrom: nil) { picked, near in
                    fromNear = near
                    setEnds { $0.startAt(picked) }
                }
            }
            .sheet(isPresented: $choosingTo) {
                RouteEndSearch(title: "To", reachableFrom: widget.start) { picked, near in
                    toNear = near
                    setEnds { $0.goTo(picked) }
                }
            }
            // A saved place's chip: which station or stop near it
            .sheet(item: $chipNear) { address in
                NavigationStack {
                    NearAddressList(address: address) { place in
                        toNear = address.name
                        setEnds { $0.goTo(place) }
                        chipNear = nil
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { chipNear = nil } }
                    }
                }
            }
            .sheet(isPresented: $addingWay) { AddWaySheet(plan: plan) }
            .sheet(isPresented: $showingCover) { coverSheet }
            .sensoryFeedback(.selection, trigger: plan.revision)
    }

    // MARK: Planning

    /// Changes From or To; another station in the same complex has the same ways, which aren't
    /// found again (the plan goes by place), so their ticks are written to the route again.
    private func setEnds(_ change: (inout SavedWidget) -> Void) {
        let places = (widget.start.place, widget.end.place)
        change(&widget)
        if places == (widget.start.place, widget.end.place) { apply() }
    }

    /// Writes the ticks to the route, once there's something ticked.
    private func apply() {
        guard !takes.isEmpty else { return }
        widget = plan.applied(to: widget)
        if shown.map({ id in (visibleWays + visibleFallbacks).contains { $0.id == id } }) != true {
            shown = takes.first?.id ?? visibleWays.first?.id
        }
    }

    /// Whether `way` goes by the ways to go turned on.
    private func allowed(_ way: WayFinder.Way) -> Bool {
        let byBus = way.rides.contains { $0.contains { BusLeg.line(of: $0) != nil } }
        let byTrain = way.rides.contains { $0.contains { BusLeg.line(of: $0) == nil } }
        return (subway || !byTrain) && (buses || !byBus)
    }

    private func limitModes() {
        guard !plan.ways.isEmpty else { return }
        plan.limit(to: allowed)
        if shown.map({ id in (visibleWays + visibleFallbacks).contains { $0.id == id } }) != true {
            shown = takes.first?.id ?? visibleWays.first?.id
        }
    }

    private var visibleWays: [WayFinder.Way] { plan.ways.filter(allowed) }

    /// How many ways show until See Other Ways, the quickest first.
    private static let firstWays = 2

    /// The ways listed: the two quickest and any ticked or on the map, or with See Other Ways
    /// tapped, all of them.
    private var listedWays: [WayFinder.Way] {
        guard !showsAllWays else { return visibleWays }
        let quickest = Set(visibleWays.sorted { $0.best < $1.best }.prefix(Self.firstWays).map(\.id))
        return visibleWays.filter { quickest.contains($0.id) || plan.ticked.contains($0.id) || $0.id == shown }
    }

    /// Ticks or unticks `way`; one from See Other Ways' sheet is listed, ticked.
    private func take(_ way: WayFinder.Way) {
        if plan.more.contains(where: { $0.id == way.id }) { plan.add(way) } else { plan.toggle(way) }
    }
    private var takes: [WayFinder.Way] { plan.takes.filter(allowed) }

    private var shownWay: WayFinder.Way? {
        (plan.ways + plan.more + plan.fallbacks).first { $0.id == shown }
    }

    private var canSave: Bool { !takes.isEmpty && widget.trip != nil && !plan.finding }

    private func save() {
        store.add(widget)
        store.setLook(.medium, for: widget.id)
        dismiss()
    }

    // MARK: Map

    private var map: some View {
        Map(position: $position) {
            if showsWays, let way = shownWay {
                ForEach(segments(of: way)) { segment in
                    if segment.walk {
                        MapPolyline(coordinates: segment.path)
                            .stroke(.secondary, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [6, 8]))
                    } else {
                        MapPolyline(coordinates: TrackShapes.rounded(segment.path))
                            .stroke(segment.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                }
                ForEach(Array(changePoints(of: way).enumerated()), id: \.offset) { _, point in
                    Annotation("", coordinate: point, anchor: .center) {
                        Circle().fill(.white).stroke(.black, lineWidth: 2).frame(width: 11, height: 11)
                    }
                }
            }
            if let start = Self.coordinate(widget.start) {
                Annotation(widget.start.name ?? "", coordinate: start, anchor: .center) {
                    Circle().fill(.tint).stroke(.white, lineWidth: 2.5).frame(width: 16, height: 16)
                        .shadow(radius: 1)
                }
            }
            if showsWays, let end = Self.coordinate(widget.end) {
                Annotation(widget.end.name ?? "", coordinate: end, anchor: .center) {
                    Circle().fill(.red).stroke(.white, lineWidth: 2.5).frame(width: 16, height: 16)
                        .shadow(radius: 1)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { }
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
    }

    /// One ride or walk of a way, drawn on the map.
    private struct Segment: Identifiable {
        let id: Int
        let path: [CLLocationCoordinate2D]
        let color: Color
        let walk: Bool
    }

    /// `way`'s rides along their tracks (a bus straight from stop to stop), and the walks
    /// between them, through the first ticked place at each change.
    private func segments(of way: WayFinder.Way) -> [Segment] {
        var board = Self.coordinate(station: way.start.stationID, stop: way.start.stop)
        var segments: [Segment] = []
        for (index, lines) in way.rides.enumerated() {
            let option = index < way.changes.count ? place(at: index, of: way) : nil
            let off = option.map { Self.coordinate(station: $0.offStationID, stop: $0.offStop) }
                ?? Self.coordinate(station: way.end.stationID, stop: way.end.stop)
            if let from = board, let to = off, let route = lines.first {
                if BusLeg.line(of: route) != nil {
                    segments.append(Segment(id: segments.count, path: [from, to], color: Self.busColor, walk: false))
                } else {
                    let path = TrackShapes.track(of: route, from: from, to: to) ?? [from, to]
                    segments.append(Segment(id: segments.count, path: path, color: LineStyle.of(route).swiftUIColor, walk: false))
                }
            }
            if let option {
                let next = Self.coordinate(station: option.boardStationID, stop: option.boardStop)
                if let off, let next, !option.across, Self.meters(off, next) > 30 {
                    segments.append(Segment(id: segments.count, path: [off, next], color: .secondary, walk: true))
                }
                board = next
            } else if let off, way.end.walk > 0, let end = Self.coordinate(widget.end), Self.meters(off, end) > 30 {
                segments.append(Segment(id: segments.count, path: [off, end], color: .secondary, walk: true))
            }
        }
        return segments
    }

    /// Where `way` changes, at its first ticked place for each.
    private func changePoints(of way: WayFinder.Way) -> [CLLocationCoordinate2D] {
        way.changes.indices.compactMap { index in
            let option = place(at: index, of: way)
            return Self.coordinate(station: option.boardStationID, stop: option.boardStop)
                ?? Self.coordinate(station: option.offStationID, stop: option.offStop)
        }
    }

    /// The change's first ticked place.
    private func place(at index: Int, of way: WayFinder.Way) -> WayFinder.Way.Option {
        way.changes[index].first { plan.isTicked($0, change: index, of: way) } ?? way.changes[index][0]
    }

    /// Buses drawn in the MTA's bus blue.
    private static let busColor = Color(red: 0, green: 0.36, blue: 0.67)

    private static func coordinate(station id: String?, stop: BusRoutes.Stop?) -> CLLocationCoordinate2D? {
        if let stop { return stop.location.coordinate }
        return id.flatMap(StationDirectory.station(id:)).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    private static func coordinate(_ place: RouteStart) -> CLLocationCoordinate2D? {
        switch place {
        case .station(let station): CLLocationCoordinate2D(latitude: station.lat, longitude: station.lon)
        case .stop(let stop): stop.location.coordinate
        case .none: nil
        }
    }

    private static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// The city, with nowhere to frame yet.
    private static let city = MapCameraPosition.region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.73, longitude: -73.95),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)))

    /// The map on the way shown, or with the ways hidden, on From: framed in what's left between
    /// the top bar and the cards (or on its side, right of them).
    private func frame() {
        var points: [CLLocationCoordinate2D]
        if showsWays, let way = shownWay {
            points = segments(of: way).flatMap(\.path) + [Self.coordinate(widget.end)].compactMap { $0 }
        } else {
            points = [Self.coordinate(widget.start)].compactMap { $0 }
        }
        guard !points.isEmpty, mapSize.width > 0 else { return }
        var rect = MKMapRect.null
        for point in points.map(MKMapPoint.init) {
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        // A street or two round a single place; a margin round a way
        let pad = points.count == 1 ? 1_500 : max(rect.width, rect.height) * 0.04 + 150
        rect = rect.insetBy(dx: -pad, dy: -pad)
        // The room it's framed in, in points
        let top: CGFloat = 110
        let left: CGFloat = sideways ? Sideways.width + Sideways.inset : 0
        let bottom: CGFloat = sideways ? 0 : cardsHeight + 8
        let room = CGSize(width: max(mapSize.width - left, 120), height: max(mapSize.height - top - bottom, 120))
        // As wide for its height as the room, so it's shown whole
        let aspect = room.width / room.height
        if rect.width / rect.height < aspect {
            let width = rect.height * aspect
            rect = MKMapRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        } else {
            let height = rect.width / aspect
            rect = MKMapRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        }
        // Then out under the bar, the cards and down the side, map points per point as in the room
        let scale = rect.height / room.height
        rect = MKMapRect(x: rect.minX - left * scale, y: rect.minY - top * scale,
                         width: rect.width + left * scale, height: rect.height + (top + bottom) * scale)
        withAnimation(Self.animation) { position = .rect(rect) }
    }

    // MARK: Top

    private var top: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Cancel", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            Spacer()
            Text("New Route")
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .glassEffect(.regular, in: Capsule())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, Self.margin)
    }

    // MARK: From and To

    /// Home Station for From; Home, Work and the places added for To, each then a pick of the
    /// stations and stops near it.
    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if let home = settings.defaultTrain.station {
                    chip("Home Station", "tram.fill") {
                        fromNear = nil
                        setEnds { $0.startAt(home) }
                    }
                }
                ForEach(placeChips, id: \.name) { saved in
                    chip(saved.name, saved.symbol) {
                        Task {
                            let start = widget.start
                            let reachable = start.id == nil ? nil : await RoutePlan.reachable(from: start)
                            chipNear = NearAddress(name: saved.name, location: saved.location, reachable: reachable,
                                                   excluding: start.id)
                        }
                    }
                }
            }
            .padding(.horizontal, Self.margin)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    /// The saved places with somewhere set, for To at the station or stop nearest each.
    private var placeChips: [(name: String, symbol: String, location: CLLocation)] {
        let places = SavedPlaces.shared
        return places.slots.compactMap { slot in
            guard let location = places.place(slot)?.location else { return nil }
            return (places.name(slot), places.symbol(slot), location)
        }
    }

    private func chip(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(name, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var endsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    endRow("From", widget.start, near: fromNear, placeholder: "Choose start") { choosingFrom = true }
                    Divider().padding(.leading, Self.margin)
                    endRow("To", widget.end, near: toNear, placeholder: "Choose destination") { choosingTo = true }
                }
                Button {
                    swap(&fromNear, &toNear)
                    setEnds { $0.swapEnds() }
                } label: {
                    Label("Swap From and To", systemImage: "arrow.up.arrow.down")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(widget.start.id == nil || widget.end.id == nil)
                .padding(.trailing, Self.margin)
            }
            Divider()
            HStack(spacing: 8) {
                modeToggle("Subway", "tram.fill", on: $subway)
                modeToggle("Bus", "bus.fill", on: $buses)
                Spacer(minLength: 0)
                findButton
            }
            .padding(.leading, Self.margin)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .padding(.horizontal, sideways ? 0 : Self.margin)
    }

    private func endRow(_ title: String, _ place: RouteStart, near: String?, placeholder: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                if let name = place.name {
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(name).foregroundStyle(.secondary)
                            HStack(spacing: 2) {
                                ForEach(marks(place).prefix(4), id: \.self) { RouteMark(route: $0, size: 18) }
                            }
                        }
                        // Picked by an address: the station's for it
                        if let near {
                            Text("Near \(near)").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text(placeholder).foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, Self.margin)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(place.name.map { name in near.map { "\(name), nearest to \($0)" } ?? name } ?? placeholder)
        .accessibilityAddTraits(.isButton)
    }

    /// A place's lines: a station's bullets, a stop's buses.
    private func marks(_ place: RouteStart) -> [String] {
        switch place {
        case .station(let station): Change.lines(at: station)
        case .stop(let stop):
            (BusRoutes.linesAtStop[stop.code] ?? []).map(\.line).reduce(into: [String]()) { lines, line in
                if !lines.contains(BusLeg.prefix + line) { lines.append(BusLeg.prefix + line) }
            }
        case .none: []
        }
    }

    private func modeToggle(_ name: String, _ symbol: String, on: Binding<Bool>) -> some View {
        Button {
            on.wrappedValue.toggle()
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
        .accessibilityHint("Offers ways by \(name.lowercased())")
    }

    /// Shows the ways there, found as soon as From and To were both set.
    private var findButton: some View {
        let canFind = widget.start.id != nil && widget.end.id != nil
        return Button {
            withAnimation(Self.animation) { showsWays = true }
        } label: {
            Label("Find Ways", systemImage: "arrow.right")
                .labelStyle(.iconOnly)
                .font(.body.weight(.bold))
                .foregroundStyle(canFind ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 44, height: 44)
                .background(canFind ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canFind)
    }

    // MARK: Ways there

    private var waysCard: some View {
        VStack(spacing: 0) {
            endsStrip
            Divider()
            nameRow
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    waysStatus
                    ForEach(listedWays) { way in
                        wayRow(way)
                    }
                    // First the rest listed here, then those found but not listed, in a sheet
                    let hidden = listedWays.count < visibleWays.count
                    if (hidden || !plan.more.isEmpty), !plan.finding {
                        Button("See Other Ways", systemImage: "ellipsis.circle.fill") {
                            if hidden {
                                withAnimation(.smooth(duration: 0.25)) { showsAllWays = true }
                            } else {
                                addingWay = true
                            }
                        }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Self.margin)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: sideways ? .infinity : 270)
            .fixedSize(horizontal: false, vertical: !sideways)
            if !takes.isEmpty {
                Divider()
                coverRow
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .padding(.horizontal, sideways ? 0 : Self.margin)
    }

    /// From and To shrunk to a line; a tap opens them again.
    private var endsStrip: some View {
        Button {
            withAnimation(Self.animation) { showsWays = false }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(.tint).frame(width: 8, height: 8)
                Text(widget.start.name ?? "")
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(widget.end.name ?? "")
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, Self.margin)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From \(widget.start.name ?? "") to \(widget.end.name ?? "")")
        .accessibilityHint("Change where from or where to")
        .accessibilityAddTraits(.isButton)
    }

    private var nameRow: some View {
        HStack(spacing: 12) {
            Text("Name")
            TextField(widget.summary, text: $widget.name)
                .multilineTextAlignment(.trailing)
                .focused($naming)
                .submitLabel(.done)
                .accessibilityLabel("Name")
        }
        .font(.subheadline)
        .padding(.horizontal, Self.margin)
        .frame(height: 44)
    }

    @ViewBuilder private var waysStatus: some View {
        Group {
            if plan.finding {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding every way there this week…")
                }
            } else if plan.noTimetable {
                HStack {
                    Text("The timetable hasn't downloaded yet.")
                    Spacer()
                    Button("Try Again") { tries += 1 }.fontWeight(.semibold)
                }
            } else if plan.ways.isEmpty {
                Text("No way there in up to two changes.")
            } else if visibleWays.isEmpty {
                Text(subway ? "No way there by subway alone." : buses ? "No way there by bus alone." : "Turn on Subway or Bus.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 10)
    }

    /// A way there, as New Trip's trips: tapped, it's drawn on the map; its tick takes it. Shown
    /// and ticked, its changes' stations as chips, any ticked of which will do.
    private func wayRow(_ way: WayFinder.Way) -> some View {
        let isShown = way.id == shown
        let isTicked = plan.ticked.contains(way.id)
        return VStack(alignment: .leading, spacing: 8) {
            // Lines, minutes and the tick along the top; what it is under them, the row's width
            Button {
                naming = false
                withAnimation(.smooth(duration: 0.25)) { shown = way.id }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .center, spacing: 12) {
                        RideChain(rides: way.rides, size: Self.bulletSize(way))
                        Spacer(minLength: 0)
                        Text(way.minutesLabel)
                            .font(.headline)
                            .monospacedDigit()
                            .fixedSize()
                        // Room for the tick, laid over this corner
                        Color.clear.frame(width: 32, height: 32)
                    }
                    Text(changeDetail(way))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let local = way.localTrackLabel {
                        Text(local)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Side by side, or the fastest under when it runs if they don't fit
                    let fastest = way.fastest(among: visibleWays)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { whenLabel(way); fastest.map(fastestLabel) }
                        VStack(alignment: .leading, spacing: 2) { whenLabel(way); fastest.map(fastestLabel) }
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows it on the map")
            .overlay(alignment: .topTrailing) {
                Button {
                    take(way)
                } label: {
                    Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isTicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isTicked ? "Taken" : "Take this way")
                .accessibilityAddTraits(isTicked ? .isSelected : [])
                .accessibilityHint("The widget shows whichever ticked way gets you there first")
            }
            if isShown && isTicked {
                changeChips(way)
            }
            if way.id == fallbackHost?.id, !visibleFallbacks.isEmpty {
                fallbackBox
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isShown ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 6)
    }

    /// The fallbacks the ways to go let through, ticked first.
    private var visibleFallbacks: [WayFinder.Way] {
        plan.fallbacks.filter(allowed).sorted { plan.ticked.contains($0.id) && !plan.ticked.contains($1.id) }
    }

    /// The way the fallbacks hang under: the first listed from the main start, ticked first.
    private var fallbackHost: WayFinder.Way? {
        let main = listedWays.filter { $0.start == plan.mainStart }
        return main.first { plan.ticked.contains($0.id) } ?? main.first
    }

    /// Under the way it stands in for, indented in orange: "When Manhattan-bound R trains aren't
    /// running", and the ways for then, each tickable and shown on the map when tapped.
    private var fallbackBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text("When \(plan.mainTrainsName ?? "they") aren't running")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(showsAllWays ? visibleFallbacks : Array(visibleFallbacks.prefix(1))) { way in
                    fallbackRow(way)
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func fallbackRow(_ way: WayFinder.Way) -> some View {
        let isTicked = plan.ticked.contains(way.id)
        var detail = way.fallbackDetail(from: plan.mainStart)
        if way.changes.count == 1, let how = how(way.changes[0]) { detail += " · " + how }
        return Button {
            naming = false
            withAnimation(.smooth(duration: 0.25)) { shown = way.id }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    RideChain(rides: way.rides, size: 20)
                    Spacer(minLength: 0)
                    Text(way.minutesLabel)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .fixedSize()
                    Color.clear.frame(width: 32, height: 32)
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                whenLabel(way).font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows it on the map")
        .overlay(alignment: .topTrailing) {
            Button {
                take(way)
            } label: {
                Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isTicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isTicked ? "Taken when they aren't running" : "Take this way when they aren't running")
            .accessibilityAddTraits(isTicked ? .isSelected : [])
        }
    }

    /// Smaller bullets the more lines there are, to keep the row in the card.
    private static func bulletSize(_ way: WayFinder.Way) -> CGFloat {
        switch way.rides.joined().count {
        case ...4: 24
        case 5...6: 20
        default: 17
        }
    }

    /// "Straight there", "Change at DeKalb Av · across the platform", "Change at Court St or
    /// Jay St, then Times Sq".
    private func whenLabel(_ way: WayFinder.Way) -> some View {
        Label(way.when, systemImage: way.whenSymbol)
            .foregroundStyle(way.isLimited ? Color.orange : Color.secondary)
            .fixedSize()
    }

    private func fastestLabel(_ text: String) -> some View {
        Text(text).fontWeight(.semibold).foregroundStyle(.green).fixedSize()
    }

    private func changeDetail(_ way: WayFinder.Way) -> String {
        guard !way.changes.isEmpty else { return "Straight there" }
        let places = way.changes.map { options in
            options.count > 2 ? "\(options[0].name) or \(options.count - 1) more"
                : options.map(\.name).joined(separator: " or ")
        }
        var text = "Change at " + places.joined(separator: ", then ")
        if way.changes.count == 1, let how = how(way.changes[0]) { text += " · " + how }
        return text
    }

    /// "across the platform", "3 min walk", or a range across the stations.
    private func how(_ options: [WayFinder.Way.Option]) -> String? {
        if options.allSatisfy(\.across) { return "across the platform" }
        let walks = options.map { $0.across ? 0 : $0.walkMinutes }
        guard let low = walks.min(), let high = walks.max() else { return nil }
        if low == 0 { return "across or \(high) min walk" }
        return low == high ? "\(low) min walk" : "\(low)–\(high) min walk"
    }

    private func changeChips(_ way: WayFinder.Way) -> some View {
        ForEach(Array(way.changes.enumerated()), id: \.offset) { index, options in
            if options.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(way.changes.count > 1 ? "Change \(index + 1) at any of:" : "Change at any of:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ChipFlow {
                        ForEach(options, id: \.place) { option in
                            let on = plan.isTicked(option, change: index, of: way)
                            Button {
                                plan.toggle(option, change: index, of: way)
                            } label: {
                                ChangeChip(name: option.name, on: on)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }

    /// When the ticked ways run: covered all week, or where they don't and the way to tick for it.
    private var coverRow: some View {
        let gap = plan.filling()
        let gaps = plan.gaps
        let covered = gaps.isEmpty
        return HStack(spacing: 8) {
            Button { showingCover = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: covered ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(covered ? .green : .orange)
                    Text(covered ? "Covered all week" : "Not covered \(WayFinder.Part.named(gaps))")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if covered || gap == nil {
                        Text(takes.count == 1 ? "1 way" : "\(takes.count) ways").foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows when each ticked way runs")
            if let gap, !covered {
                Button("Tick \(gap.way.rides.map { $0.map { BusLeg.line(of: $0) ?? $0 }.joined(separator: "/") }.joined(separator: " → "))") {
                    plan.toggle(gap.way)
                    shown = gap.way.id
                }
                .fontWeight(.semibold)
                .lineLimit(1)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, Self.margin)
        .frame(height: 46)
    }

    private var coverSheet: some View {
        NavigationStack {
            List {
                Section {
                    CoverGrid(cover: plan.cover())
                } footer: {
                    Text("The quickest ticked way at each time of the week. The widget shows whichever ticked way gets you there first.")
                }
            }
            .navigationTitle("When You're Covered")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { showingCover = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: Save

    /// In New Trip's Go bar's place: back to From and To, and Save Route.
    private var saveBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Self.animation) { showsWays = false }
            } label: {
                Label("Change From or To", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: Self.barHeight, height: Self.barHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            Button(action: save) {
                Label("Save Route", systemImage: "bookmark.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: Self.barHeight)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSave ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .disabled(!canSave)
            .glassEffect(canSave ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Capsule())
            .accessibilityHint("Saves it to Routes, for your widgets")
        }
        .padding(.horizontal, sideways ? 0 : 21)
    }
}

// MARK: - From and To search

/// New Route's From or To, searched as Navigate's are: stations, addresses, places and
/// contacts (`TripPlaceList`), and bus stops. An address or place is the route's at the station
/// nearest it that can be got to, or with none in a short walk, the nearest stop.
struct RouteEndSearch: View {
    let title: String
    /// For To, where the route starts: only places reachable from there are taken.
    let reachableFrom: RouteStart?
    /// The place picked, and the address or place it's nearest to, if it was picked by one.
    let pick: (RouteStart, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @State private var search = ""
    @State private var submits = 0
    @State private var stops: [BusRoutes.Stop] = []
    @State private var choosing = false
    @State private var location = NearbyLocation()
    /// For To, the places reachable from `reachableFrom`, once found.
    @State private var reachable: Set<String>?
    /// An address picked: the stations and stops near it to choose from.
    @State private var near: NearAddress?

    /// The three stations nearest you, each with how far; for To, of those reachable.
    private var nearest: [(station: Station, meters: CLLocationDistance)] {
        guard let here = location.location else { return [] }
        if reachableFrom != nil, reachable == nil { return [] }
        return StationDirectory.all
            .filter { $0.id != reachableFrom?.id && (reachable?.contains($0.complex) ?? true) }
            .map { (station: $0, meters: here.distance(from: $0.location)) }
            .sorted { $0.meters < $1.meters }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if search.isEmpty {
                    suggestions
                } else {
                    VStack(spacing: 0) {
                        if !stops.isEmpty { stopChips }
                        TripPlaceList(search: search, submits: submits) { place in
                            Task { await choose(place) }
                        }
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .overlay {
                if choosing {
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: 72, height: 72)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Station, address, person or bus stop")
            .onSubmit(of: .search) { submits += 1 }
            .navigationDestination(item: $near) { address in
                NearAddressList(address: address) { place in
                    pick(place, address.name)
                    dismiss()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
            }
            .task(id: search) {
                if !search.isEmpty {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
                stops = await BusStopSearch.find(search, among: nil, limit: 12)
            }
            .task {
                guard let from = reachableFrom else { return }
                // No timetable yet: every station
                reachable = await RoutePlan.reachable(from: from) ?? Set(StationDirectory.all.map(\.complex))
            }
            .onAppear {
                location.start()
                if location.isAllowed { location.find() }
            }
        }
    }

    /// Before typing: the three stations nearest you, Home Station, then the saved places.
    private var suggestions: some View {
        List {
            let nearest = nearest
            if !nearest.isEmpty {
                Section("Nearest") {
                    ForEach(nearest, id: \.station.id) { near in
                        Button {
                            pick(.station(near.station), nil)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(near.station.name).foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    LineBullets(routes: near.station.routes, size: 18)
                                    Text(Measurement(value: near.meters, unit: UnitLength.meters)
                                        .formatted(.measurement(width: .abbreviated, usage: .road)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if location.status == .notDetermined {
                Button("Show Stations Near Me", systemImage: "location.fill") { location.find() }
            }
            if let home = settings.defaultTrain.station {
                Button {
                    pick(.station(home), nil)
                    dismiss()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(home.name).foregroundStyle(.primary)
                            Text("Home Station").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tram.fill").foregroundStyle(.tint)
                    }
                }
            }
            let places = SavedPlaces.shared
            ForEach(places.slots, id: \.self) { slot in
                if let place = places.place(slot) {
                    Button {
                        Task { await choose(place, named: places.name(slot)) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(places.name(slot)).foregroundStyle(.primary)
                                Text(place.name).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: places.symbol(slot)).foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .disabled(choosing)
    }

    /// The bus stops for the search, as chips over the places.
    private var stopChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(stops, id: \.code) { stop in
                    Button {
                        pick(.stop(stop), nil)
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            if let line = BusRoutes.linesAtStop[stop.code]?.first?.line {
                                BusBadge(line: line, size: 16)
                            }
                            Text(BusNames.readable(stop.name)).lineLimit(1)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 16, for: .scrollContent)
    }

    /// A station picked is itself; an address or place, the station or stop nearest it.
    private func choose(_ place: TripPlace, named name: String? = nil) async {
        guard !choosing, let point = place.point else { return }
        if let station = StationDirectory.all.first(where: { $0.name == place.name
            && abs($0.lat - point.latitude) < 1e-6 && abs($0.lon - point.longitude) < 1e-6 }) {
            pick(.station(station), nil)
            dismiss()
            return
        }
        choosing = true
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        let reachable = if let reachableFrom, reachableFrom.id != nil {
            if let reachable = self.reachable { reachable } else { await RoutePlan.reachable(from: reachableFrom) }
        } else { Set<String>?.none }
        near = NearAddress(name: name ?? place.name, location: location, reachable: reachable,
                           excluding: reachableFrom?.id)
        choosing = false
    }

    /// Meters from an address a station or stop is offered.
    fileprivate static let addressReach: CLLocationDistance = 805
}

/// An address picked in `RouteEndSearch`: the stations and bus stops within half a mile, nearest
/// first; without any, the three nearest stations.
struct NearAddress: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let stations: [(station: Station, meters: CLLocationDistance)]
    let stops: [(stop: BusRoutes.Stop, meters: CLLocationDistance)]
    /// None within half a mile: `stations` are the nearest instead.
    let isFar: Bool

    /// With `reachable`, only those among its places; never `excluding`, where the route starts.
    init(name: String, location: CLLocation, reachable: Set<String>?, excluding: String?) {
        self.name = name
        let reach = RouteEndSearch.addressReach
        let all = StationDirectory.all
            .filter { $0.id != excluding && (reachable?.contains($0.complex) ?? true) }
            .map { (station: $0, meters: location.distance(from: $0.location)) }
            .sorted { $0.meters < $1.meters }
        let coordinate = location.coordinate
        stops = BusRoutes.allStops
            // A rough box first: 13,000 stops
            .filter { abs($0.latitude - coordinate.latitude) < 0.008 && abs($0.longitude - coordinate.longitude) < 0.011 }
            .filter { "stop " + $0.code != excluding && (reachable?.contains(WayFinder.stopPlace($0.code)) ?? true) }
            .map { (stop: $0, meters: location.distance(from: $0.location)) }
            .filter { $0.meters <= reach }
            .sorted { $0.meters < $1.meters }
        let close = all.filter { $0.meters <= reach }
        isFar = close.isEmpty && stops.isEmpty
        stations = isFar ? Array(all.prefix(3)) : close
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The stations and stops near an address, to pick which the route starts or ends at.
private struct NearAddressList: View {
    let address: NearAddress
    let pick: (RouteStart) -> Void

    private func distance(_ meters: CLLocationDistance) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    var body: some View {
        List {
            if !address.stations.isEmpty {
                Section {
                    ForEach(address.stations, id: \.station.id) { near in
                        row(.station(near.station)) {
                            Text(near.station.name).foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                LineBullets(routes: near.station.routes, size: 18)
                                Text(distance(near.meters)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Stations")
                } footer: {
                    if address.isFar { Text("None within half a mile, so the nearest.") }
                }
            }
            if !address.stops.isEmpty {
                Section("Bus Stops") {
                    ForEach(address.stops, id: \.stop.code) { near in
                        let lines = BusRoutes.linesAtStop[near.stop.code] ?? []
                        let buses = lines.map(\.line).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        let caption = Text([distance(near.meters), lines.first.map { "toward \(BusNames.destination($0.to))" }]
                            .compactMap(\.self).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        row(.stop(near.stop)) {
                            Text(BusNames.readable(near.stop.name)).foregroundStyle(.primary)
                            // Badges and caption on one line if they fit; a busy stop's badges wrap
                            // with the caption on the line under them
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) {
                                    HStack(spacing: 3) {
                                        ForEach(buses, id: \.self) { BusBadge(line: $0, size: 16) }
                                    }
                                    caption
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    ChipFlow(spacing: 3) {
                                        ForEach(buses, id: \.self) { BusBadge(line: $0, size: 16) }
                                    }
                                    caption
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(address.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ place: RouteStart, @ViewBuilder label: () -> some View) -> some View {
        Button {
            pick(place)
        } label: {
            VStack(alignment: .leading, spacing: 4) { label() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
