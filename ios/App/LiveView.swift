import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit

/// What a tap on the Nearby or Transfers widget opens in the Live tab.
enum LiveOpening: Equatable {
    /// One of its trains.
    case train(Selection)
    /// A station's every line, both ways.
    case station(StationPage)
    /// A Transfers widget's train, and the lines it changes to.
    case transfer(TransferPage)
    /// The stations near you, found again.
    case nearby
    /// Location for the app: asked for the first time, and once it's been
    /// turned off, in Settings.
    case allowLocation
}

/// A station's every line both ways, with `first` at the top: the lines a
/// tap on "4 more lines" on the Nearby widget was for.
struct StationPage: Hashable {
    let station: Station
    var first: [String] = []

    /// The station's lines, `first` first, the rest in the station's order.
    var routes: [String] {
        station.routes.filter(first.contains) + station.routes.filter { !first.contains($0) }
    }
}

/// A Transfers widget's two stations: its train at yours, and the lines it
/// changes to at the change, going their way.
struct TransferPage: Hashable {
    let selection: Selection
    let change: Change

    /// The lines changed to, as trains of their own at the change: one for
    /// each station of it they stop at, as 59 St's 4 5 6 for a change at
    /// Lexington Av/59 St.
    var changeTrains: [Selection] {
        guard let station = change.station else { return [] }
        let direction = change.departureDirection(for: selection)
        return StationDirectory.stations(inComplexOf: station).compactMap { joined in
            let routes = joined.routes.filter(change.routes.contains)
            guard !routes.isEmpty else { return nil }
            return Selection(stationID: joined.id, routes: routes, direction: direction,
                             elevatorAlerts: selection.elevatorAlerts, serviceAlerts: selection.serviceAlerts)
        }
    }
}

/// The Live tab: the next trains of your favorites, and of every line at the
/// stations near you. Tapping one opens its times, countdown, alerts and map.
struct LiveView: View {
    /// What a tap on the Nearby widget opens; cleared once it's open.
    @Binding var opening: LiveOpening?
    @Environment(FavoritesStore.self) private var favorites
    @Environment(WidgetStore.self) private var widgets
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @State private var location = NearbyLocation()
    @State private var path = NavigationPath()
    /// How many trains the widgets have opened, so each gets a page of its own.
    @State private var openings = 0
    /// The next trains of every train in both lists.
    @State private var live = LiveTrains()
    /// Adding a favorite starts by choosing its train.
    @State private var choosingTrain = false
    @State private var chosenTrain: Selection?
    /// A place picked on the map, which Nearby goes by instead of where you are until Find Location.
    @State private var pin: CLLocation?
    @State private var droppingPin = false
    /// The closest few stations to the pin, or to you, nearest first. Found
    /// again only when either moves, not each time the list redraws.
    @State private var nearby: [Nearby.Result] = []
    /// Shared with the Edit button; while editing, favorites leave out their times.
    @State private var editMode = EditMode.inactive

    /// Where Nearby goes by: the pin, or else you.
    private var here: CLLocation? { pin ?? location.location }

    /// New times for what's shown, keeping the pin or where you were found.
    private func refresh() {
        Task { await load() }
    }

    /// Back to where you are, found again even if you haven't moved. New
    /// times follow once the stations near you change.
    private func findLocation() {
        pin = nil
        location.find()
        Task { await load() }
    }

    /// Every train in both lists, for fetching them together.
    private var everyTrain: [Selection] {
        favorites.favorites + nearby.flatMap { result in
            result.station.routes.flatMap { route in
                Direction.allCases.map { Selection(stationID: result.station.id, routes: [route], direction: $0) }
            }
        }
    }

    private var marks: TimeMarks { settings.timeMarks(withoutColor: withoutColor) }

    /// Starts out at the last favorite's station, with the walking time and alerts at their defaults.
    private var newTrain: Binding<Selection> {
        Binding {
            chosenTrain ?? favorites.favorites.last.map {
                Selection(stationID: $0.stationID, routes: $0.routes, direction: $0.direction)
            } ?? .fallback
        } set: {
            chosenTrain = $0
        }
    }

    private func add() {
        chosenTrain = nil
        choosingTrain = true
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                favoritesSection
                nearbySection
                if !SharedStore.isAvailable {
                    Section {
                        Label("The widget can't see your choice on this install, so it keeps showing Prospect Av (R) toward Manhattan.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } footer: {
                        Text("The shared storage the app and widget use wasn't set up when this was installed. Reinstalling with AltStore should fix it.")
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationDestination(for: Selection.self) { selection in
                // A nearby train that's a favorite too opens with its walking time
                TrainDetail(selection: favorites.favorite(matching: selection) ?? selection)
                    // Its own page for each train, and each time a widget opens
                    // one: opened in place of another, or of itself switched to
                    // another train, it would otherwise keep that one's state
                    .id("\(selection.trainID) \(openings)")
            }
            .navigationDestination(for: StationPage.self) { page in
                StationLive(station: page.station, routes: page.routes, marks: marks) { path.append($0) }
            }
            .navigationDestination(for: TransferPage.self) { page in
                TransferLive(page: page, marks: marks)
            }
            .toolbar {
                if !favorites.favorites.isEmpty {
                    // Not EditButton: that edits the navigation stack's own edit mode, not this one
                    ToolbarItem(placement: .topBarLeading) {
                        Button(editMode.isEditing ? "Done" : "Edit") {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        }
                        .fontWeight(editMode.isEditing ? .semibold : .regular)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Add a Favorite", systemImage: "plus") {
                        Button("Create New", systemImage: "plus.circle", action: add)
                        Menu("Add from Widget", systemImage: "app") {
                            // Each saved widget's train, with its walking time; one already here is greyed out
                            ForEach(widgets.saved.widgets) { widget in
                                Button {
                                    favorites.add(widget.selection)
                                } label: {
                                    Text(widget.title)
                                    Text(widget.selection.caption)
                                }
                                .disabled(favorites.contains(widget.selection))
                            }
                        }
                    }
                }
            }
            // Once the train's chosen, it's a favorite; cancelled, nothing
            .sheet(isPresented: $choosingTrain, onDismiss: {
                if let chosenTrain { favorites.add(chosenTrain) }
            }) {
                TrainPicker(selection: newTrain)
            }
            .sheet(isPresented: $droppingPin) {
                DropPinSheet(start: (pin ?? location.location)?.coordinate) { pin = $0 }
            }
            .onAppear { location.start() }
            .onChange(of: opening, initial: true) { _, opening in
                guard let opening else { return }
                self.opening = nil
                switch opening {
                case .train(let selection):
                    openings += 1
                    path = NavigationPath([selection])
                case .station(let page):
                    path = NavigationPath([page])
                case .transfer(let page):
                    path = NavigationPath([page])
                case .nearby:
                    path = NavigationPath()
                    findLocation()
                case .allowLocation:
                    path = NavigationPath()
                    if location.status == .denied || location.status == .restricted,
                       let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    } else {
                        findLocation()
                    }
                }
            }
            .onChange(of: here, initial: true) { _, here in
                nearby = here.map { Nearby.stations(near: $0, limit: 3) } ?? []
            }
            // New times every minute, and straight away for a new train or
            // station; pulled down or back in the app, it finds you again too
            .updatingTrains(live, id: everyTrain.map(\.trainID), refreshing: {
                if location.isAllowed && pin == nil { location.find() }
            }, load: load)
            // With the last favorite gone the Edit button goes too, so editing ends with it
            .onChange(of: favorites.favorites.isEmpty) { _, isEmpty in
                if isEmpty { editMode = .inactive }
            }
        }
    }

    private var favoritesSection: some View {
        Section {
            if !live.failed.isEmpty {
                UnreachableNote()
            }
            if favorites.favorites.isEmpty {
                Text("Tap ☆ on any train, or +, to keep it here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(favorites.favorites, id: \.trainID) { selection in
                NavigationLink(value: selection) {
                    FavoriteRow(
                        selection: selection,
                        trains: live.trains[selection.trainID].map { selection.catchable($0, now: live.now) },
                        failed: live.failed.contains(selection.trainID),
                        now: live.now,
                        marks: marks,
                        showsTimes: !editMode.isEditing
                    )
                }
                .contextMenu {
                    Button("Remove from Favorites", systemImage: "star.slash", role: .destructive) {
                        favorites.remove(selection)
                    }
                }
            }
            .onDelete { favorites.delete(atOffsets: $0) }
            .onMove { favorites.move(fromOffsets: $0, toOffset: $1) }
        } header: {
            Text("Favorites")
        }
    }

    /// The stations near a dropped pin; otherwise a button to allow location
    /// until it's allowed, then the closest stations' lines, or why there are none.
    private var nearbySection: some View {
        Section {
            if pin != nil {
                HStack {
                    Label("Near your dropped pin", systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Pin", systemImage: "xmark.circle.fill", action: findLocation)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.borderless)
                }
                if nearby.isEmpty {
                    Text("No stations within \(Nearby.rangeDescription) of the pin").foregroundStyle(.secondary)
                } else {
                    nearbyRows
                }
            } else if location.status == .notDetermined {
                Button {
                    location.find()
                } label: {
                    Label("Show trains near you", systemImage: "location")
                }
            } else if !location.isAllowed {
                Text("Location is off for Train Times.").foregroundStyle(.secondary)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: url) {
                        Label("Turn It On in Settings", systemImage: "location")
                    }
                }
            } else if location.failed {
                Button {
                    location.find()
                } label: {
                    Label("Couldn't find you. Try again", systemImage: "location.slash")
                }
            } else if location.location == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding stations near you…").foregroundStyle(.secondary)
                }
            } else if nearby.isEmpty {
                Text("No stations within \(Nearby.rangeDescription) of you").foregroundStyle(.secondary)
            } else {
                nearbyRows
            }
        } header: {
            HStack(spacing: 8) {
                Text("Nearby")
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                Button("Find Location", systemImage: "location", action: findLocation)
                Button("Drop Pin", systemImage: "mappin") { droppingPin = true }
            }
            // Symbols only; the titles stay for VoiceOver
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.mini)
            .textCase(nil)
        }
    }

    /// Each nearby station, then its lines and their next trains each way.
    private var nearbyRows: some View {
        ForEach(nearby) { result in
            NearbyStationRow(result: result)
            ForEach(result.station.routes, id: \.self) { route in
                NearbyLineRow(
                    station: result.station,
                    route: route,
                    trains: { selection in
                        // Each line's own trains, not those of another line running on its tracks
                        live.trains[selection.trainID]?.filter { $0.route == route && $0.leaves > live.now }
                    },
                    failed: { live.failed.contains($0.trainID) },
                    now: live.now,
                    marks: marks,
                    open: { path.append($0) }
                )
            }
        }
    }

    /// New times for every train in both lists. Until a train's first come,
    /// its row shows a dash.
    private func load() async {
        let selections = everyTrain
        // Nearby rows show only each line's own trains, which are all in its
        // own feeds; a favorite shows those of other lines running on it too
        let nearbyOnly = Set(selections.map(\.trainID)).subtracting(favorites.favorites.map(\.trainID))
        await live.load(selections, ownLinesOnly: nearbyOnly)
    }
}

/// A favorite: its lines, station and direction, and when its next trains come.
private struct FavoriteRow: View {
    let selection: Selection
    /// The trains you can still catch; nil until they're fetched.
    let trains: [Arrival]?
    /// Whether they couldn't be fetched the last time.
    let failed: Bool
    let now: Date
    let marks: TimeMarks
    /// Left out while editing, for the delete and move controls.
    let showsTimes: Bool

    var body: some View {
        HStack(spacing: 12) {
            LineBullets(routes: selection.routes, size: 30)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(selection.station?.name ?? "Train").font(.headline)
                Text(selection.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if showsTimes {
                Minutes(trains: trains, failed: failed, now: now, marks: marks)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A station near you, over its lines: its name and how far it is.
private struct NearbyStationRow: View {
    let result: Nearby.Result

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.station.name).font(.headline)
                Text(result.station.borough).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(result.distance).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A station's every line and its next trains each way, from a tap on its
/// name on the Nearby widget. Each direction opens on its own.
private struct StationLive: View {
    let station: Station
    /// Its lines, in the order they're shown.
    let routes: [String]
    let marks: TimeMarks
    let open: (Selection) -> Void
    @State private var live = LiveTrains()

    private var selections: [Selection] {
        station.routes.flatMap { route in
            Direction.allCases.map { Selection(stationID: station.id, routes: [route], direction: $0) }
        }
    }

    var body: some View {
        List {
            if !live.failed.isEmpty {
                UnreachableNote()
            }
            Section {
                ForEach(routes, id: \.self) { route in
                    NearbyLineRow(
                        station: station,
                        route: route,
                        trains: { selection in
                            // Each line's own trains, not those of another line running on its tracks
                            live.trains[selection.trainID]?.filter { $0.route == route && $0.leaves > live.now }
                        },
                        failed: { live.failed.contains($0.trainID) },
                        now: live.now,
                        marks: marks,
                        open: open
                    )
                }
            } header: {
                Text(station.borough)
            }
        }
        .navigationTitle(station.name)
        .updatingTrains(live, id: station.id) {
            // Each line's own trains are all in its own feeds
            await live.load(selections, includingOtherLines: false)
        }
    }
}

/// The two stations of a Transfers widget, from a tap on it: its train at
/// yours, then the lines it changes to at the change. Each opens on its own.
private struct TransferLive: View {
    let page: TransferPage
    let marks: TimeMarks
    @State private var live = LiveTrains()

    private var selections: [Selection] { [page.selection] + page.changeTrains }

    var body: some View {
        List {
            if !live.failed.isEmpty {
                UnreachableNote()
            }
            Section("Your train") {
                row(page.selection)
            }
            Section("Then change") {
                ForEach(page.changeTrains, id: \.trainID) { train in
                    row(train)
                }
            }
        }
        .navigationTitle("Transfer")
        .updatingTrains(live, id: selections.map(\.trainID)) {
            await live.load(selections)
        }
    }

    /// With your walking time, your train's left out until you can catch it.
    private func row(_ selection: Selection) -> some View {
        NavigationLink(value: selection) {
            FavoriteRow(
                selection: selection,
                trains: live.trains[selection.trainID].map { selection.catchable($0, now: live.now) },
                failed: live.failed.contains(selection.trainID),
                now: live.now,
                marks: marks,
                showsTimes: true
            )
        }
    }
}

/// The next trains of what a page of the Live tab lists, fetched together:
/// your favorites and the stations near you, a station's every line, or a
/// transfer's trains.
@MainActor @Observable
final class LiveTrains {
    /// Each train's next arrivals, by `Selection.trainID`, as last fetched.
    private(set) var trains: [String: [Arrival]] = [:]
    /// The `Selection.trainID`s whose trains couldn't be fetched the last time.
    private(set) var failed: Set<String> = []
    /// Moves along every few seconds so the minutes count down.
    var now = Date.now

    /// New times for `selections`, as `TrainService.trains(for:)` fetches
    /// them. One left out couldn't be fetched: its old times go, rather than
    /// count down as if they were new. Other trains keep theirs, so a load of
    /// an older list that ends after the newer one's doesn't clear its rows.
    func load(_ selections: [Selection], includingOtherLines: Bool = true, ownLinesOnly: Set<String> = []) async {
        // With nothing to fetch, nothing failed
        guard !selections.isEmpty else {
            failed = []
            return
        }
        let fetched = await TrainService.trains(for: selections, includingOtherLines: includingOtherLines,
                                                ownLinesOnly: ownLinesOnly)
        // A newer list cancels this load; that isn't a failure
        guard !Task.isCancelled else { return }
        let missing = Set(selections.map(\.trainID)).subtracting(fetched.keys)
        trains.merge(fetched) { $1 }
        for trainID in missing { trains[trainID] = nil }
        failed = missing
        now = .now
    }
}

extension View {
    /// Sets `now` to the time every 10 seconds while the view is up, so
    /// between loads the minutes count down and trains you can no longer
    /// catch drop off.
    func ticking(_ now: Binding<Date>) -> some View {
        task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                now.wrappedValue = .now
            }
        }
    }

    /// Keeps `live` up to date with `load`: straight away and every minute,
    /// starting over whenever `id` changes, and after `refreshing` when the
    /// list is pulled down or the app comes back. In between, its `now` ticks.
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
                    try? await Task.sleep(for: .seconds(60))
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

/// Over a page's trains when some of them couldn't be fetched.
private struct UnreachableNote: View {
    var body: some View {
        Label("Couldn't reach the MTA. Pull down to try again.", systemImage: "wifi.exclamationmark")
            .foregroundStyle(.secondary)
    }
}

/// One line at a station near you, and its next trains each way. Each
/// direction opens on its own. A direction with no name, at the end of the
/// line, has no trains to show and is left out; so is the way a line ends at
/// a platform others go on from, unless some of its trains go on too.
private struct NearbyLineRow: View {
    let station: Station
    let route: String
    /// A direction's trains; nil until they're fetched.
    let trains: (Selection) -> [Arrival]?
    /// Whether a direction's trains couldn't be fetched the last time.
    let failed: (Selection) -> Bool
    let now: Date
    let marks: TimeMarks
    let open: (Selection) -> Void

    private var directions: [Direction] {
        let platforms = station.platforms(serving: [route])
        let named = Direction.allCases.filter { direction in
            platforms.contains { !$0.directionName(direction).isEmpty }
        }
        // Where the MTA names neither, both, as "Northbound" and "Southbound"
        return (named.isEmpty ? Direction.allCases : named).filter { direction in
            !StationDirectory.line(route, endsAt: station, going: direction)
                || trains(Selection(stationID: station.id, routes: [route], direction: direction))?.isEmpty == false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            LineBullet(route: route, size: 30)
                .frame(width: 40)
            VStack(spacing: 10) {
                ForEach(directions, id: \.self) { direction in
                    let selection = Selection(stationID: station.id, routes: [route], direction: direction)
                    Button {
                        open(selection)
                    } label: {
                        HStack(spacing: 8) {
                            Text(station.directionLabel(direction, routes: [route]))
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Minutes(trains: trains(selection), failed: failed(selection), now: now, marks: marks)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Lines.name(of: route)) \(station.directionLabel(direction, routes: [route]))")
                    // The label stands for the whole row, so the times come as its value
                    .accessibilityValue(Minutes.spoken(trains(selection), failed: failed(selection), now: now))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A map to tap a place on, for Nearby to list the stations around it.
private struct DropPinSheet: View {
    /// Where the map opens: the last pin or where you are, or else Prospect Av.
    let start: CLLocationCoordinate2D?
    let drop: (CLLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var coordinate: CLLocationCoordinate2D?

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
            }
            .safeAreaInset(edge: .bottom) {
                Text(coordinate == nil ? "Tap the map to drop a pin." : "Tap elsewhere to move it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
            .navigationTitle("Drop Pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
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

/// The next few trains, in minutes: "Now 6 12 min", live predictions in green.
private struct Minutes: View {
    /// Nil until they're fetched.
    let trains: [Arrival]?
    /// Whether they couldn't be fetched the last time, which it then says instead.
    let failed: Bool
    let now: Date
    let marks: TimeMarks

    var body: some View {
        if failed {
            Text("Couldn't load").font(.subheadline).foregroundStyle(.secondary)
        } else if let trains {
            if trains.isEmpty {
                Text("No trains").font(.subheadline).foregroundStyle(.secondary)
            } else {
                // Always on one line: as many of the next three as fit, down to one
                ViewThatFits(in: .horizontal) {
                    row(trains.prefix(3))
                    row(trains.prefix(2))
                    row(trains.prefix(1))
                }
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(trains, now: now))
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// As VoiceOver reads them: "Now, 1 minute, 7 minutes by the timetable".
    /// A timetable time says so, as its colour does on screen.
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

    /// The trains' minutes, each after its mark, then "min"; never wrapped.
    private func row(_ trains: ArraySlice<Arrival>) -> some View {
        HStack(spacing: 6) {
            ForEach(trains, id: \.self) { train in
                HStack(spacing: 2) {
                    StatusMark(isLive: train.isLive, marks: marks, size: 9)
                    Text(MinutesToGo(until: train.time, from: now).number)
                }
                .foregroundStyle(train.statusColor(scheduled: .primary))
            }
            Text("min").foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

#Preview {
    LiveView(opening: .constant(nil))
        .environment(FavoritesStore())
        .environment(WidgetStore())
        .environment(SettingsStore())
}
