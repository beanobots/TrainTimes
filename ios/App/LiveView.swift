import CoreLocation
import MapKit
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
/// changes to at the change, going the same way.
struct TransferPage: Hashable {
    let selection: Selection
    let change: Change

    /// The lines changed to, as a train of their own at the change.
    var changeTrain: Selection {
        Selection(stationID: change.stationID, routes: change.routes, direction: selection.direction,
                  elevatorAlerts: selection.elevatorAlerts, serviceAlerts: selection.serviceAlerts)
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var location = NearbyLocation()
    @State private var path = NavigationPath()
    /// Each train's next arrivals, by `Selection.trainID`, as last fetched.
    @State private var trains: [String: [Arrival]] = [:]
    @State private var loadState = LoadState.loading
    /// Moves along every few seconds so the minutes count down.
    @State private var now = Date.now
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

    private enum LoadState { case loading, loaded, failed }

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

    private var marksLive: Bool { settings.marksLive(withoutColor: withoutColor) }
    private var marksScheduled: Bool { settings.settings.marksScheduledTimes }

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
                    // Its own page for each train: one opened from the widget in
                    // place of another would otherwise keep the other's state
                    .id(selection.trainID)
            }
            .navigationDestination(for: StationPage.self) { page in
                StationLive(station: page.station, routes: page.routes, marksLive: marksLive, marksScheduled: marksScheduled) { path.append($0) }
            }
            .navigationDestination(for: TransferPage.self) { page in
                TransferLive(page: page, marksLive: marksLive, marksScheduled: marksScheduled)
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
                                    Text("\(Lines.list(widget.selection.routes)) \(widget.selection.heading)")
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
            .refreshable {
                if location.isAllowed && pin == nil { location.find() }
                await load()
            }
            // New times every minute, and straight away for a new train or station
            .task(id: everyTrain.map(\.trainID)) {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    now = .now
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                if location.isAllowed && pin == nil { location.find() }
                Task { await load() }
            }
            // With the last favorite gone the Edit button goes too, so editing ends with it
            .onChange(of: favorites.favorites.isEmpty) { _, isEmpty in
                if isEmpty { editMode = .inactive }
            }
        }
    }

    private var favoritesSection: some View {
        Section {
            if loadState == .failed {
                Label("Couldn't reach the MTA. Pull down to try again.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            if favorites.favorites.isEmpty {
                Text("Tap ☆ on any train, or +, to keep it here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(favorites.favorites, id: \.trainID) { selection in
                NavigationLink(value: selection) {
                    FavoriteRow(
                        selection: selection,
                        trains: trains[selection.trainID].map { selection.catchable($0, now: now) },
                        now: now,
                        marksLive: marksLive,
                        marksScheduled: marksScheduled,
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
                        trains[selection.trainID]?.filter { $0.route == route && $0.time > now }
                    },
                    now: now,
                    marksLive: marksLive,
                    marksScheduled: marksScheduled,
                    open: { path.append($0) }
                )
            }
        }
    }

    private func load() async {
        let selections = everyTrain
        guard !selections.isEmpty else { return }
        if trains.isEmpty { loadState = .loading }
        let fetched = await TrainService.trains(for: selections)
        // A newer list cancels this load; that isn't a failure
        guard !Task.isCancelled else { return }
        trains.merge(fetched) { $1 }
        now = .now
        loadState = fetched.isEmpty ? .failed : .loaded
    }
}

/// A favorite: its lines, station and direction, and when its next trains come.
private struct FavoriteRow: View {
    let selection: Selection
    /// The trains you can still catch; nil until they're fetched.
    let trains: [Arrival]?
    let now: Date
    let marksLive: Bool
    let marksScheduled: Bool
    /// Left out while editing, for the delete and move controls.
    let showsTimes: Bool

    var body: some View {
        HStack(spacing: 12) {
            LineBullets(routes: selection.routes, size: 30)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(selection.station?.name ?? "Train").font(.headline)
                Text("\(Lines.list(selection.routes)) \(selection.heading)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if showsTimes {
                Minutes(trains: trains, now: now, marksLive: marksLive, marksScheduled: marksScheduled)
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
    let marksLive: Bool
    let marksScheduled: Bool
    let open: (Selection) -> Void
    /// Each train's next arrivals, by `Selection.trainID`, as last fetched.
    @State private var trains: [String: [Arrival]] = [:]
    @State private var failed = false
    /// Moves along every few seconds so the minutes count down.
    @State private var now = Date.now

    private var selections: [Selection] {
        station.routes.flatMap { route in
            Direction.allCases.map { Selection(stationID: station.id, routes: [route], direction: $0) }
        }
    }

    var body: some View {
        List {
            if failed {
                Label("Couldn't reach the MTA. Pull down to try again.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(routes, id: \.self) { route in
                    NearbyLineRow(
                        station: station,
                        route: route,
                        trains: { selection in
                            // Each line's own trains, not those of another line running on its tracks
                            trains[selection.trainID]?.filter { $0.route == route && $0.time > now }
                        },
                        now: now,
                        marksLive: marksLive,
                        marksScheduled: marksScheduled,
                        open: open
                    )
                }
            } header: {
                Text(station.borough)
            }
        }
        .navigationTitle(station.name)
        .refreshable { await load() }
        // New times every minute
        .task(id: station.id) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                now = .now
            }
        }
    }

    private func load() async {
        let fetched = await TrainService.trains(for: selections)
        guard !Task.isCancelled else { return }
        trains.merge(fetched) { $1 }
        now = .now
        failed = fetched.isEmpty
    }
}

/// The two stations of a Transfers widget, from a tap on it: its train at
/// yours, then the lines it changes to at the change. Each opens on its own.
private struct TransferLive: View {
    let page: TransferPage
    let marksLive: Bool
    let marksScheduled: Bool
    /// Each train's next arrivals, by `Selection.trainID`, as last fetched.
    @State private var trains: [String: [Arrival]] = [:]
    @State private var failed = false
    /// Moves along every few seconds so the minutes count down.
    @State private var now = Date.now

    private var selections: [Selection] { [page.selection, page.changeTrain] }

    var body: some View {
        List {
            if failed {
                Label("Couldn't reach the MTA. Pull down to try again.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            Section("Your train") {
                row(page.selection)
            }
            Section("Then change") {
                row(page.changeTrain)
            }
        }
        .navigationTitle("Transfer")
        .refreshable { await load() }
        // New times every minute
        .task(id: selections.map(\.trainID)) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                now = .now
            }
        }
    }

    /// With your walking time, your train's left out until you can catch it.
    private func row(_ selection: Selection) -> some View {
        NavigationLink(value: selection) {
            FavoriteRow(
                selection: selection,
                trains: trains[selection.trainID].map { selection.catchable($0, now: now) },
                now: now,
                marksLive: marksLive,
                marksScheduled: marksScheduled,
                showsTimes: true
            )
        }
    }

    private func load() async {
        let fetched = await TrainService.trains(for: selections)
        guard !Task.isCancelled else { return }
        trains.merge(fetched) { $1 }
        now = .now
        failed = fetched.isEmpty
    }
}

/// One line at a station near you, and its next trains each way. Each
/// direction opens on its own. A direction with no name, at the end of the
/// line, has no trains to show and is left out.
private struct NearbyLineRow: View {
    let station: Station
    let route: String
    /// A direction's trains; nil until they're fetched.
    let trains: (Selection) -> [Arrival]?
    let now: Date
    let marksLive: Bool
    let marksScheduled: Bool
    let open: (Selection) -> Void

    private var directions: [Direction] {
        let platforms = station.platforms(serving: [route])
        let named = Direction.allCases.filter { direction in
            platforms.contains { !$0.directionName(direction).isEmpty }
        }
        // Where the MTA names neither, both, as "Northbound" and "Southbound"
        return named.isEmpty ? Direction.allCases : named
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
                            Minutes(trains: trains(selection), now: now, marksLive: marksLive, marksScheduled: marksScheduled)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Lines.name(of: route)) \(station.directionLabel(direction, routes: [route]))")
                    // The label stands for the whole row, so the times come as its value
                    .accessibilityValue(Minutes.spoken(trains(selection), now: now))
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
    let now: Date
    let marksLive: Bool
    let marksScheduled: Bool

    var body: some View {
        if let trains {
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

    /// As VoiceOver reads them: "Now, 1 minute, 7 minutes".
    static func spoken(_ trains: [Arrival]?, now: Date) -> String {
        guard let trains else { return "Loading" }
        guard !trains.isEmpty else { return "No trains" }
        return trains.prefix(3).map { train in
            let minutes = Int(train.time.timeIntervalSince(now) / 60)
            return minutes < 1 ? "Now" : minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        .joined(separator: ", ")
    }

    /// The trains' minutes, each after its mark, then "min"; never wrapped.
    private func row(_ trains: ArraySlice<Arrival>) -> some View {
        HStack(spacing: 6) {
            ForEach(trains, id: \.self) { train in
                HStack(spacing: 2) {
                    if marksLive && train.isLive {
                        LiveMark(size: 9)
                    } else if marksScheduled && !train.isLive {
                        ScheduledMark(size: 9)
                    }
                    Text(label(for: train))
                }
                .foregroundStyle(train.isLive ? Color.liveText : Color.primary)
            }
            Text("min").foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func label(for train: Arrival) -> String {
        let minutes = Int(train.time.timeIntervalSince(now) / 60)
        return minutes < 1 ? "Now" : "\(minutes)"
    }
}

#Preview {
    LiveView(opening: .constant(nil))
        .environment(FavoritesStore())
        .environment(WidgetStore())
        .environment(SettingsStore())
}
