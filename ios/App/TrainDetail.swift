import CoreLocation
import MapKit
import SwiftUI

/// One train, opened from the Live tab: its times, countdown, alerts and map.
/// A favorite's walking time is saved with it; ☆ adds or removes it.
struct TrainDetail: View {
    @Environment(FavoritesStore.self) private var favorites
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @State private var selection: Selection
    @State private var board: Board?
    @State private var loadState = LoadState.loading
    /// When the board's times were fetched.
    @State private var timesFetched: Date?
    /// Whether the last try for new times failed, so those shown are older.
    @State private var refreshFailed = false
    /// When the board's alerts and elevator outages were fetched, which change
    /// far less often than the times.
    @State private var noticesFetched: Date?
    /// Moves along every few seconds so trains you can no longer catch drop off the list.
    @State private var now = Date.now
    /// The train this train's Lock Screen countdown is for, while one is running.
    @State private var countdownTrain: Date?
    @State private var countdownProblem: String?
    /// While a countdown's starting, so a second tap doesn't start another,
    /// and a load begun meanwhile gets the notices too.
    @State private var startingCountdown = false
    @State private var choosingTrain = false

    private enum LoadState { case loading, loaded, failed }

    init(selection: Selection) {
        _selection = State(initialValue: selection)
        _countdownTrain = State(initialValue: TrainActivityController.currentTrain(for: selection))
    }

    private var isFavorite: Bool { favorites.contains(selection) }

    private var station: Station? { selection.station }
    /// The trains you can still catch, given the walking time.
    private var trains: [Arrival] { selection.catchable(board?.trains ?? [], now: now) }

    var body: some View {
        List {
            trainSection
            Section {
                WalkStepper(minutes: $selection.walkMinutes)
            } header: {
                Text("Getting there")
            } footer: {
                Text(isFavorite
                     ? "Trains you can't reach in time are left out, here and in Favorites."
                     : "Trains you can't reach in time are left out. Add this train to Favorites to keep its walking time.")
            }
            trainsSection
            countdownSection
            if loadState == .loaded, let board {
                alertsSection(board.alerts)
            }
            if let station {
                accessibilitySection(station)
                mapSection(station)
            }
        }
        .navigationTitle(station?.name ?? "Train")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star") {
                    if isFavorite {
                        favorites.remove(selection)
                    } else {
                        favorites.add(selection)
                    }
                }
            }
        }
        .sheet(isPresented: $choosingTrain) {
            TrainPicker(selection: chosenTrain)
        }
        // The walking time is a favorite's own
        .onChange(of: selection) { _, selection in favorites.update(selection) }
        .refreshable { await loadBoard(includingNotices: true) }
        // New times every 30 seconds, and alerts every 10 minutes, or with the times while
        // counting down; a new walking time needs none
        .task(id: selection.trainID) {
            while !Task.isCancelled {
                await loadBoard()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .ticking($now)
        // The countdown's, on the list: on its section, each of its rows,
        // header and footer would run them. A problem starting one is the
        // other train's
        .onChange(of: selection.trainID) { countdownProblem = nil }
        // The countdown gets the times this page fetches, so it moves on with them
        .onChange(of: timesFetched) {
            guard countdownTrain != nil, let board, let fetched = timesFetched else { return }
            let shown = selection
            Task {
                let train = await TrainActivityController.update(for: shown, from: board, fetched: fetched)
                if selection.trainID == shown.trainID { countdownTrain = train }
            }
        }
    }

    /// The train the picker changes: a favorite moves to the new train, keeping
    /// its place and walking time, and the old train's times and alerts go.
    private var chosenTrain: Binding<Selection> {
        Binding {
            selection
        } set: { chosen in
            guard chosen.trainID != selection.trainID else { return }
            favorites.replace(selection, with: chosen)
            board = nil
            noticesFetched = nil
            refreshFailed = false
            selection = favorites.favorite(matching: chosen) ?? chosen
        }
    }

    /// Which train this is; the arrow chooses another, in three steps.
    private var trainSection: some View {
        Section {
            Button {
                choosingTrain = true
            } label: {
                TrainChoiceRow(selection: selection, placeholder: "Train")
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Choose another station, line or direction")
        }
    }

    private var trainsSection: some View {
        Section {
            // Old times that have all gone say nothing of what's coming
            if loadState == .failed || (refreshFailed && trains.isEmpty) {
                Text("Couldn't reach the MTA").foregroundStyle(.secondary)
            } else if loadState == .loading && trains.isEmpty {
                ProgressView()
            } else if trains.isEmpty {
                if board?.trains.contains(where: { $0.leaves > now }) == true {
                    Text("No \(selection.linesLabel) trains you can reach in time").foregroundStyle(.secondary)
                } else {
                    Text("No \(selection.linesLabel) trains predicted").foregroundStyle(.secondary)
                }
            } else {
                if refreshFailed, let timesFetched {
                    Label("Couldn't reach the MTA, so these times are from \(Spoken.clock(timesFetched)).",
                          systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                }
                ForEach(trains.prefix(5), id: \.self) { train in
                    TrainRow(
                        train: train,
                        leave: selection.walkMinutes > 0 ? selection.leaveTime(for: train) : nil,
                        marksLine: selection.marksLine(of: train),
                        marks: settings.timeMarks(withoutColor: withoutColor)
                    )
                }
            }
        } header: {
            Text("Next trains")
        } footer: {
            Text("Green times are live predictions. The rest are timetable times, which can change. With more than one line, or another line running on yours, each train shows its bullet.")
        }
    }

    private var countdownSection: some View {
        Section {
            if let countdownTrain {
                Label("Counting down to the \(Spoken.clock(countdownTrain)) train", systemImage: "timer")
                Button("Stop the countdown", role: .destructive) {
                    Task {
                        await TrainActivityController.endAll()
                        self.countdownTrain = nil
                    }
                }
            } else {
                Button {
                    Task { await startCountdown() }
                } label: {
                    Label("I'm on my way", systemImage: "figure.walk.departure")
                }
                .disabled(startingCountdown)
            }
            if let countdownProblem {
                Text(countdownProblem).foregroundStyle(.secondary)
            }
        } header: {
            Text("On your way")
        } footer: {
            Text("Counts down to your train on the Lock Screen and in the Dynamic Island until you stop it, in place of any other countdown. A widget's walk button starts and stops it too. While this page is open, it gets the times shown here; otherwise tap ↻ on it, or open the app, for new times.")
                .accessibilityLabel("Counts down to your train on the Lock Screen and in the Dynamic Island until you stop it, in place of any other countdown. A widget's walk button starts and stops it too. While this page is open, it gets the times shown here; otherwise tap Refresh on it, or open the app, for new times.")
        }
    }

    private func startCountdown() async {
        let trainID = selection.trainID
        startingCountdown = true
        defer { startingCountdown = false }
        do {
            let train = try await TrainActivityController.start(for: selection)
            // Unless another train was chosen meanwhile
            guard selection.trainID == trainID else { return }
            countdownTrain = train
            countdownProblem = nil
        } catch {
            guard selection.trainID == trainID else { return }
            countdownProblem = error.localizedDescription
        }
    }

    private func alertsSection(_ alerts: [ServiceAlert]?) -> some View {
        Section {
            if let alerts, alerts.isEmpty {
                NoAlertsNote()
            } else if let alerts {
                ForEach(alerts) { alert in
                    AlertRow(alert: alert)
                }
            } else {
                CouldntLoadNote(what: "alerts")
            }
        } header: {
            Text("Service alerts")
        } footer: {
            Text("Delays, service changes and notices from the MTA that affect this line at this station.")
        }
    }

    private func accessibilitySection(_ station: Station) -> some View {
        Section {
            // The chosen lines' platforms, each with its lines where they differ:
            // the N's is step-free at 14 St-Union Sq, the 4's isn't
            let platforms = selection.platforms
            if Set(platforms.map(\.accessibility)).count > 1 {
                ForEach(platforms) { platform in
                    Label {
                        HStack(spacing: 4) {
                            ForEach(platform.routes.filter(selection.routes.contains), id: \.self) { route in
                                LineBullet(route: route, size: 18)
                            }
                            Text(platform.accessibility ?? "No step-free access")
                        }
                    } icon: {
                        Image(systemName: stepFreeSymbol(platform))
                    }
                }
            } else if let platform = platforms.first {
                Label(platform.accessibility ?? "No step-free access", systemImage: stepFreeSymbol(platform))
            }
            if EquipmentDirectory.hasEquipment(serving: platforms) {
                let outages = board?.outages ?? []
                if loadState == .loaded, let board {
                    if board.outages == nil {
                        CouldntLoadNote(what: "elevator status")
                    } else if outages.isEmpty {
                        // Only those that serve the lines chosen are listed
                        Label("No elevator or escalator outages for the \(Lines.list(selection.routes))", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(outages) { outage in
                    OutageRow(outage: outage)
                }
            } else if EquipmentDirectory.hasEquipment(atComplex: station.complex) {
                // The station's go to other platforms: Canal St's to the 6's, not the R's
                Text("No elevators or escalators for the \(Lines.list(selection.routes))").foregroundStyle(.secondary)
            } else {
                Text("No elevators or escalators at this station").foregroundStyle(.secondary)
            }
        } header: {
            Text("Accessibility")
        } footer: {
            Text("Elevator and escalator status from the MTA.")
        }
    }

    /// Stairs where there's no step-free access to `platform` going this
    /// train's way, as at 28 St's 6 uptown, which is step-free downtown only.
    private func stepFreeSymbol(_ platform: Platform) -> String {
        platform.isStepFree(going: selection.direction) == false ? "figure.stairs" : "figure.roll"
    }

    private func mapSection(_ station: Station) -> some View {
        Section {
            StationMap(station: station, route: selection.firstRoute)
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
            Button {
                // Named, so Maps says the station rather than the street address
                let item = MKMapItem(placemark: MKPlacemark(coordinate: walkingDestination(station)))
                item.name = station.name
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
            } label: {
                Label("Walking directions in Maps", systemImage: "figure.walk")
            }
        } header: {
            Text("Map")
        } footer: {
            if station.entrances.isEmpty {
                Text("The MTA doesn't list this station's entrances.")
            } else {
                Text("Dots are entrances; blue ones have an elevator. Hollow dots are exit only.")
            }
        }
    }

    /// Where walking directions go: the way in to this train's platforms
    /// nearest you, or without a recent fix on you, nearest the middle of the
    /// station; in step-free mode, one with an elevator where there is one.
    /// The middle of the station where the MTA lists no way in.
    private func walkingDestination(_ station: Station) -> CLLocationCoordinate2D {
        let platforms = selection.platforms.isEmpty ? station.platforms : selection.platforms
        let ways = platforms.flatMap(\.entrances).filter { $0.exitOnly != true }
        let elevators = ways.filter(\.isElevator)
        let candidates = settings.settings.stepFree && !elevators.isEmpty ? elevators : ways
        let middle = CLLocation(latitude: station.lat, longitude: station.lon)
        // Where you were a while ago says little about which side you'll come from
        let here = CLLocationManager().location.flatMap { Date.now.timeIntervalSince($0.timestamp) < 10 * 60 ? $0 : nil }
        let from = here ?? middle
        let nearest = candidates.min { a, b in
            from.distance(from: CLLocation(latitude: a.lat, longitude: a.lon))
                < from.distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
        }
        return nearest.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } ?? middle.coordinate
    }

    /// Times already shown stay up while new ones load, and if they don't come,
    /// saying how old they are. Alerts and outages come with them only when
    /// `includingNotices`, or when the ones shown are 10 minutes old, or while
    /// this train's countdown is running or starting, which gets them too and
    /// would otherwise lose a newer notice to them; otherwise those shown stay.
    private func loadBoard(includingNotices: Bool = false) async {
        if board == nil { loadState = .loading }
        // The times are as of when the fetch begins; `now` ticks on while it
        // runs, and a countdown refreshed meanwhile keeps its newer times
        let started = Date.now
        now = started
        countdownTrain = TrainActivityController.currentTrain(for: selection)
        let trainID = selection.trainID
        let fetchesNotices = includingNotices || board == nil || countdownTrain != nil || startingCountdown
            || noticesFetched.map { !$0.isWithin(10 * 60, before: started) } ?? true
        do {
            var fetched = try await TrainService.board(for: selection, includingAlerts: fetchesNotices,
                                                       includingOutages: fetchesNotices)
            // A newer choice cancels this load, but can't stop the fetch: what
            // it brings is the other train's
            guard !Task.isCancelled, trainID == selection.trainID else { return }
            // Only once both have come are they good for 10 minutes; until
            // then, any shown before stay, and the next load tries again
            if fetchesNotices && fetched.alerts != nil && fetched.outages != nil {
                noticesFetched = started
            }
            fetched.alerts = fetched.alerts ?? board?.alerts
            fetched.outages = fetched.outages ?? board?.outages
            board = fetched
            timesFetched = started
            refreshFailed = false
            loadState = .loaded
        } catch {
            // a newer choice cancels this load; that isn't a failure
            guard !Task.isCancelled, trainID == selection.trainID else { return }
            if board == nil {
                loadState = .failed
            } else {
                refreshFailed = true
            }
        }
    }
}

private struct TrainRow: View {
    let train: Arrival
    /// When to set off, if a walking time is set.
    let leave: Date?
    /// Shown with its bullet: one of several lines chosen, or an N running local on the R, say.
    let marksLine: Bool
    /// Which times get their symbol: a live prediction as well as its green.
    let marks: TimeMarks

    var body: some View {
        HStack(spacing: 8) {
            Text(train.time, format: .dateTime.hour().minute())
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(train.statusColor(scheduled: .primary))
            StatusMark(isLive: train.isLive, marks: marks, size: 12)
                .foregroundStyle(train.statusColor(scheduled: .primary))
            if marksLine {
                LineBullet(route: train.route, size: 20)
            }
            if let terminal = train.terminal {
                Text(terminal).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            // Stopping at 0:00: a train held at the platform is still listed after its time
            if let leave {
                Text("leave in").font(.footnote).foregroundStyle(.secondary)
                Text(timerInterval: min(leave, Date.now)...leave, countsDown: true)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            } else {
                Text(timerInterval: min(train.time, Date.now)...train.time, countsDown: true)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AlertRow: View {
    let alert: ServiceAlert

    var body: some View {
        // Folded away only where there's more to read
        if alert.period == nil && alert.details.isEmpty {
            summary
        } else {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    if let period = alert.period {
                        Label(period, systemImage: "calendar")
                    }
                    if !alert.details.isEmpty {
                        Text(alert.details)
                    }
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            } label: {
                summary
            }
        }
    }

    /// Its kind and headline.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            NoticeKindLabel(kind: .alert(alert.kind))
            Text(alert.header)
        }
    }
}

private struct OutageRow: View {
    let outage: Outage

    private var title: String {
        let machine = outage.isElevator ? "elevator" : "escalator"
        return outage.isPlanned ? "Planned \(machine) work" : (outage.isElevator ? "Elevator out" : "Escalator out")
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !outage.reason.isEmpty {
                    Text("Reason: \(outage.reason)")
                }
                if outage.isAccessibilityElevator && !outage.alternative.isEmpty {
                    Text(outage.alternative)
                }
            }
            .font(.subheadline)
            .padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: outage.isElevator ? "arrow.up.arrow.down.square" : "stairs")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(outage.isPlanned ? Color.secondary : Color.orange)
                Text(outage.serving)
                if !outage.when.isEmpty {
                    Text(outage.when).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The station on a map, with its entrances.
private struct StationMap: View {
    let station: Station
    let route: String

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: station.lat, longitude: station.lon),
            latitudinalMeters: 350,
            longitudinalMeters: 350
        ))) {
            Marker(station.name, systemImage: "tram.fill", coordinate: CLLocationCoordinate2D(latitude: station.lat, longitude: station.lon))
                .tint(LineStyle.of(route).swiftUIColor)
            ForEach(Array(station.entrances.enumerated()), id: \.offset) { _, entrance in
                Annotation(entrance.isElevator ? "Elevator" : "", coordinate: CLLocationCoordinate2D(latitude: entrance.lat, longitude: entrance.lon)) {
                    EntranceMark(entrance: entrance)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .id(station.id)
        .accessibilityLabel("Map of \(station.name) and its entrances")
    }
}

private struct EntranceMark: View {
    let entrance: Station.Entrance

    var body: some View {
        Group {
            if entrance.isElevator {
                Image(systemName: "figure.roll")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(Color.blue))
            } else if entrance.exitOnly == true {
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 2))
            } else {
                Circle()
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
            }
        }
        // What its colour and fill say
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entrance.isElevator ? "Elevator entrance" : entrance.exitOnly == true ? "Exit only" : "Entrance")
    }
}
