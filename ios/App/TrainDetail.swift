import CoreLocation
import MapKit
import SwiftUI

/// One train's times, countdown, alerts and map.
struct TrainDetail: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Selection
    @State private var board: Board?
    @State private var loadState = LoadState.loading
    @State private var timesFetched: Date?
    /// The last refresh failed, so the times shown are stale.
    @State private var refreshFailed = false
    /// When alerts and elevator outages were fetched; they change far less often than times.
    @State private var noticesFetched: Date?
    /// When the times shown were fetched, if they're a widget's or the countdown's (saved by
    /// `SharedStore`), shown until this page gets its own: below ground that can take a while.
    @State private var savedFetched: Date?
    /// The MTA couldn't be reached and there were no times to catch, so the timetable's are shown.
    @State private var fromTimetable = false
    /// Ticks every few seconds so uncatchable trains drop off.
    @State private var now = AppClock.now
    /// The arrival time the running Lock Screen countdown is for, if any.
    @State private var countdownTrain: Date?
    @State private var countdownProblem: String?
    /// Blocks a second tap, and makes loads during startup fetch notices too.
    @State private var startingCountdown = false
    @State private var choosingTrain = false

    private enum LoadState { case loading, loaded, failed }

    init(selection: Selection) {
        _selection = State(initialValue: selection)
        _countdownTrain = State(initialValue: TrainActivityController.currentTrain(for: selection))
    }

    private var station: Station? { selection.station }
    /// Trains you can still catch given the walking time.
    private var trains: [Arrival] { selection.catchable(board?.trains ?? [], now: now) }

    var body: some View {
        List {
            trainSection
            trainsSection
            countdownSection
            if loadState == .loaded, let board {
                alertsSection(board.alerts)
            }
            if let station {
                StationInfoSections(selection: selection, station: station, outages: board?.outages,
                                    loaded: loadState == .loaded && board != nil)
            }
        }
        .navigationTitle(station?.name ?? "Train")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $choosingTrain) {
            TrainPicker(selection: chosenTrain)
        }
        .refreshable { await loadBoard(includingNotices: true) }
        // Times every 30 s; alerts every 10 min (or with the times while counting down).
        // Keyed on trainID, so a walking-time change doesn't reload; not in the background, and
        // loaded as soon as the app comes back
        .task(id: Polling(id: selection.trainID, inForeground: scenePhase != .background)) {
            guard scenePhase != .background else { return }
            while !Task.isCancelled {
                await loadBoard()
                // After a failure, sooner; and as soon as the network's back (a station after a
                // tunnel)
                await Connectivity.shared.pause(for: .seconds(refreshFailed || loadState == .failed ? 10 : 30))
            }
        }
        .ticking($now)
        // Countdown handlers live on the List: on the Section, each row, header and footer
        // would run them. A start error belongs to the previous train
        .onChange(of: selection.trainID) { countdownProblem = nil }
        // Feed this page's fetched times to the countdown
        .onChange(of: timesFetched) {
            guard countdownTrain != nil, let board, let fetched = timesFetched else { return }
            let shown = selection
            Task {
                let train = await TrainActivityController.update(for: shown, from: board, fetched: fetched)
                if selection.trainID == shown.trainID { countdownTrain = train }
            }
        }
    }

    /// Picking a new train clears the old train's times and alerts.
    private var chosenTrain: Binding<Selection> {
        Binding {
            selection
        } set: { chosen in
            guard chosen.trainID != selection.trainID else { return }
            board = nil
            noticesFetched = nil
            refreshFailed = false
            savedFetched = nil
            fromTimetable = false
            selection = chosen
        }
    }

    /// The current train; tapping opens the picker to choose another.
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
            // Stale times that have all passed tell you nothing
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
                if fromTimetable {
                    Label("Couldn't reach the MTA, so these are timetable times.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                } else if let savedFetched {
                    if refreshFailed {
                        Label("Couldn't reach the MTA, so these times are from \(Spoken.clock(savedFetched)).",
                              systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("These times are from \(Spoken.clock(savedFetched)). Getting new ones…",
                              systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                    }
                } else if refreshFailed, let timesFetched {
                    Label("Couldn't reach the MTA, so these times are from \(Spoken.clock(timesFetched)).",
                          systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                }
                if let scheduled = board?.scheduledRoutes, !scheduled.isEmpty, !fromTimetable {
                    Label("Couldn't get live times for the \(Lines.list(scheduled)), so \(scheduled.count == 1 ? "its" : "their") times are the timetable's.",
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
            // Ignore if another train was chosen meanwhile
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

    /// Shown times stay up while loading, and on failure are kept with their age noted.
    /// Alerts and outages are refetched only if `includingNotices`, if they're 10 minutes old,
    /// or while this train's countdown is running or starting (it gets them too, and would
    /// otherwise have a newer notice overwritten by older ones).
    /// Before this page's own times, any a widget or the countdown saved still catchable
    /// (`savedFetched`).
    private func loadBoard(includingNotices: Bool = false) async {
        if board == nil {
            loadState = .loading
            if !AppClock.isPretending, let saved = SharedStore.loadBoard(for: selection),
               !selection.catchable(saved.trains, now: AppClock.now).isEmpty {
                board = Board(trains: saved.trains)
                savedFetched = saved.fetched
            }
        }
        // Times are stamped at fetch start; `now` ticks on meanwhile, and a countdown
        // refreshed during the fetch keeps its newer times
        let started = Date.now
        now = AppClock.now
        countdownTrain = TrainActivityController.currentTrain(for: selection)
        let trainID = selection.trainID
        let fetchesNotices = includingNotices || board == nil || countdownTrain != nil || startingCountdown
            || noticesFetched.map { !$0.isWithin(10 * 60, before: started) } ?? true
        do {
            // A line whose feed can't be had gets the timetable's times, if another's can
            var fetched = try await TrainService.board(for: selection, includingAlerts: fetchesNotices,
                                                       includingOutages: fetchesNotices,
                                                       fillingFrom: { TimetableStore.load() })
            // A newer choice cancels the task but not the fetch; drop the old train's result
            guard !Task.isCancelled, trainID == selection.trainID else { return }
            // Notices count as fresh for 10 minutes only once both arrive; otherwise keep the
            // old ones and retry next load
            if fetchesNotices && fetched.alerts != nil && fetched.outages != nil {
                noticesFetched = started
            }
            fetched.alerts = fetched.alerts ?? board?.alerts
            fetched.outages = fetched.outages ?? board?.outages
            board = fetched
            timesFetched = started
            savedFetched = nil
            fromTimetable = false
            refreshFailed = false
            loadState = .loaded
        } catch {
            // Cancelled by a newer choice; not a failure
            guard !Task.isCancelled, trainID == selection.trainID else { return }
            // Nothing shown you can still catch: the timetable's times, if there's a timetable
            // Off main: it may unzip on a cold cache
            let timetable = selection.catchable(board?.trains ?? [], now: AppClock.now).isEmpty
                ? await Task.detached(priority: .userInitiated) { TimetableStore.load() }.value : nil
            guard !Task.isCancelled, trainID == selection.trainID else { return }
            if let timetable {
                var timed = TrainService.board(for: selection, from: timetable)
                timed.alerts = board?.alerts
                timed.outages = board?.outages
                board = timed
                savedFetched = nil
                fromTimetable = true
            }
            if board == nil {
                loadState = .failed
            } else {
                refreshFailed = true
                loadState = .loaded
            }
        }
    }
}

/// A line at a station both ways, as a Nearby tile opens it: each way's own times and
/// countdown.
struct LineWays: Hashable {
    struct Way: Hashable {
        /// The line alone, this way, with your walk to the station.
        let selection: Selection
        /// "Manhattan", "Brooklyn"
        let label: String
    }

    let ways: [Way]
}

/// A line at a station both ways: each way a section of the trains you can still catch, with
/// when to leave, and its own countdown; the line's alerts, the station's elevators and its map
/// once, under both.
struct LineDetail: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.scenePhase) private var scenePhase
    let line: LineWays

    /// Each way's times, alerts and outages, by `Selection.trainID`.
    @State private var boards: [String: Board] = [:]
    /// Ways whose last load failed: their times shown are old, or there are none.
    @State private var failed: Set<String> = []
    /// Ways showing the timetable's times, the MTA unreachable.
    @State private var fromTimetable: Set<String> = []
    /// When each way's alerts and outages were fetched; they change far less often than times.
    @State private var noticesFetched: [String: Date] = [:]
    /// Each way's running Lock Screen countdown's train, if it's this way's.
    @State private var countdownTrains: [String: Date] = [:]
    @State private var countdownProblems: [String: String] = [:]
    /// The way whose countdown is starting, to block a second tap.
    @State private var starting: String?
    /// Ticks every few seconds so uncatchable trains drop off.
    @State private var now = AppClock.now

    private var first: Selection? { line.ways.first?.selection }
    private var station: Station? { first?.station }

    var body: some View {
        List {
            if let first, let station {
                Section {
                    HStack(spacing: 12) {
                        LineBullet(route: first.firstRoute, size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Lines.name(of: first.firstRoute)) at \(station.name)").font(.headline)
                            if first.walkMinutes > 0 {
                                Text("\(first.walkMinutes) min walk").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            ForEach(line.ways, id: \.self) { way in
                waySection(way, isLast: way == line.ways.last)
            }
            alertsSection
            if let first, let station {
                StationInfoSections(selection: first, station: station, outages: boards[first.trainID]?.outages,
                                    loaded: boards[first.trainID] != nil)
            }
        }
        .navigationTitle(station?.name ?? "Train")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadAll(includingNotices: true) }
        // Times every 30 s, sooner after a failure; alerts every 10 min; not in the background
        .task(id: Polling(id: line, inForeground: scenePhase != .background)) {
            guard scenePhase != .background else { return }
            while !Task.isCancelled {
                await loadAll()
                await Connectivity.shared.pause(for: .seconds(failed.isEmpty ? 30 : 10))
            }
        }
        .ticking($now)
    }

    @ViewBuilder private func waySection(_ way: LineWays.Way, isLast: Bool) -> some View {
        let selection = way.selection
        let id = selection.trainID
        let board = boards[id]
        let trains = selection.catchable(board?.trains ?? [], now: now)
        Section {
            if board == nil {
                if failed.contains(id) {
                    Text("Couldn't reach the MTA").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } else if trains.isEmpty {
                if failed.contains(id) {
                    Text("Couldn't reach the MTA").foregroundStyle(.secondary)
                } else if board?.trains.contains(where: { $0.leaves > now }) == true {
                    Text("No \(selection.linesLabel) trains you can reach in time").foregroundStyle(.secondary)
                } else {
                    Text("No \(selection.linesLabel) trains predicted").foregroundStyle(.secondary)
                }
            } else {
                if fromTimetable.contains(id) {
                    Label("Couldn't reach the MTA, so these are timetable times.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                } else if failed.contains(id) {
                    Label("Couldn't reach the MTA, so these times may be out of date.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                }
                ForEach(trains.prefix(3), id: \.self) { train in
                    TrainRow(train: train,
                             leave: selection.walkMinutes > 0 ? selection.leaveTime(for: train) : nil,
                             marksLine: selection.marksLine(of: train),
                             marks: settings.timeMarks(withoutColor: withoutColor))
                }
            }
            if let train = countdownTrains[id] {
                Label("Counting down to the \(Spoken.clock(train)) train", systemImage: "timer")
                Button("Stop the countdown", role: .destructive) {
                    Task {
                        await TrainActivityController.endAll()
                        countdownTrains = [:]
                    }
                }
            } else {
                Button {
                    Task { await startCountdown(selection) }
                } label: {
                    Label("I'm on my way", systemImage: "figure.walk.departure")
                }
                .disabled(starting != nil)
            }
            if let problem = countdownProblems[id] {
                Text(problem).foregroundStyle(.secondary)
            }
        } header: {
            Text("To \(way.label)")
        } footer: {
            if isLast {
                Text("Green times are live predictions. I'm on my way counts down to that way's train on the Lock Screen and in the Dynamic Island, in place of any other countdown.")
            }
        }
    }

    /// Both ways' alerts, each once.
    private var alertsSection: some View {
        let loaded = line.ways.compactMap { boards[$0.selection.trainID]?.alerts }
        var seen: Set<ServiceAlert.ID> = []
        let alerts = loaded.flatMap { $0 }.filter { seen.insert($0.id).inserted }
        return Section {
            if loaded.isEmpty {
                if boards.isEmpty {
                    ProgressView()
                } else {
                    CouldntLoadNote(what: "alerts")
                }
            } else if alerts.isEmpty {
                NoAlertsNote()
            } else {
                ForEach(alerts) { AlertRow(alert: $0) }
            }
        } header: {
            Text("Service alerts")
        } footer: {
            Text("Delays, service changes and notices from the MTA that affect this line at this station.")
        }
    }

    private func loadAll(includingNotices: Bool = false) async {
        now = AppClock.now
        await withTaskGroup(of: Void.self) { group in
            for way in line.ways {
                group.addTask { await load(way.selection, includingNotices: includingNotices) }
            }
        }
    }

    /// One way's times, kept on failure with the failure noted; the timetable's, if none shown
    /// can still be caught. Alerts and outages refetched only if `includingNotices`, 10 minutes
    /// old, or this way's counting down.
    private func load(_ selection: Selection, includingNotices: Bool) async {
        let id = selection.trainID
        if boards[id] == nil, !AppClock.isPretending, let saved = SharedStore.loadBoard(for: selection),
           !selection.catchable(saved.trains, now: AppClock.now).isEmpty {
            boards[id] = Board(trains: saved.trains)
        }
        let started = Date.now
        countdownTrains[id] = TrainActivityController.currentTrain(for: selection)
        let fetchesNotices = includingNotices || countdownTrains[id] != nil || starting == id
            || noticesFetched[id].map { !$0.isWithin(10 * 60, before: started) } ?? true
        do {
            var fetched = try await TrainService.board(for: selection, includingAlerts: fetchesNotices,
                                                       includingOutages: fetchesNotices,
                                                       fillingFrom: { TimetableStore.load() })
            guard !Task.isCancelled else { return }
            if fetchesNotices && fetched.alerts != nil && fetched.outages != nil { noticesFetched[id] = started }
            fetched.alerts = fetched.alerts ?? boards[id]?.alerts
            fetched.outages = fetched.outages ?? boards[id]?.outages
            boards[id] = fetched
            failed.remove(id)
            fromTimetable.remove(id)
            // Feed this page's times to its countdown
            if countdownTrains[id] != nil {
                countdownTrains[id] = await TrainActivityController.update(for: selection, from: fetched, fetched: started)
            }
        } catch {
            guard !Task.isCancelled else { return }
            // Off main: it may unzip on a cold cache
            let timetable = selection.catchable(boards[id]?.trains ?? [], now: AppClock.now).isEmpty
                ? await Task.detached(priority: .userInitiated) { TimetableStore.load() }.value : nil
            guard !Task.isCancelled else { return }
            if let timetable {
                var timed = TrainService.board(for: selection, from: timetable)
                timed.alerts = boards[id]?.alerts
                timed.outages = boards[id]?.outages
                boards[id] = timed
                fromTimetable.insert(id)
            }
            failed.insert(id)
        }
    }

    private func startCountdown(_ selection: Selection) async {
        let id = selection.trainID
        starting = id
        defer { starting = nil }
        do {
            let train = try await TrainActivityController.start(for: selection)
            // One countdown at a time: the other way's, if it was running, is replaced
            countdownTrains = [id: train]
            countdownProblems[id] = nil
        } catch {
            countdownProblems[id] = error.localizedDescription
        }
    }
}

/// A station's step-free access and elevator outages, and its map with walking directions, for
/// `selection`'s lines and way: under Train Detail's times, and once under both ways' on a
/// line's page.
private struct StationInfoSections: View {
    @Environment(SettingsStore.self) private var settings
    let selection: Selection
    let station: Station
    /// Nil if not fetched or unavailable.
    let outages: [Outage]?
    /// Whether times have loaded, so a missing `outages` means they couldn't be.
    let loaded: Bool

    var body: some View {
        accessibilitySection(station)
        mapSection(station)
    }

    private func accessibilitySection(_ station: Station) -> some View {
        Section {
            // Per-platform rows only when access differs (e.g. at 14 St-Union Sq the N is
            // step-free, the 4 isn't)
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
                    .accessibilityValue(stepFreeNote(platform))
                }
            } else if let platform = platforms.first {
                Label(platform.accessibility ?? "No step-free access", systemImage: stepFreeSymbol(platform))
                    .accessibilityValue(stepFreeNote(platform))
            }
            if EquipmentDirectory.hasEquipment(serving: platforms) {
                let shown = outages ?? []
                if loaded {
                    if outages == nil {
                        CouldntLoadNote(what: "elevator status")
                    } else if shown.isEmpty {
                        // Outages are filtered to the chosen lines
                        Label("No elevator or escalator outages for the \(Lines.list(selection.routes))", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(shown) { outage in
                    OutageRow(outage: outage)
                }
            } else if EquipmentDirectory.hasEquipment(atComplex: station.complex) {
                // The station's equipment serves other platforms (e.g. Canal St: the 6, not the R)
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

    /// Stairs if `platform` isn't step-free in this train's direction (e.g. 28 St's 6 is
    /// step-free downtown only).
    private func stepFreeSymbol(_ platform: Platform) -> String {
        platform.isStepFree(going: selection.direction) == false ? "figure.stairs" : "figure.roll"
    }

    /// For VoiceOver, what only the stairs symbol shows: partly step-free, but not your way.
    private func stepFreeNote(_ platform: Platform) -> String {
        platform.ada == 2 && platform.isStepFree(going: selection.direction) == false
            ? "Not step-free going this way" : ""
    }

    private func mapSection(_ station: Station) -> some View {
        Section {
            StationMap(station: station, route: selection.firstRoute)
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
            Button {
                // Named so Maps shows the station, not the street address
                let destination = walkingDestination(station)
                let item = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude),
                                     address: nil)
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

    /// The entrance to this train's platforms nearest you (or the station centre, without a
    /// recent fix). In step-free mode, prefers elevators. Falls back to the station centre
    /// if the MTA lists no entrances.
    private func walkingDestination(_ station: Station) -> CLLocationCoordinate2D {
        let platforms = selection.platforms.isEmpty ? station.platforms : selection.platforms
        let ways = platforms.flatMap(\.entrances).filter { $0.exitOnly != true }
        let elevators = ways.filter(\.isElevator)
        let candidates = settings.settings.stepFree && !elevators.isEmpty ? elevators : ways
        let middle = station.location
        // Ignore fixes older than 10 minutes
        let here = (PretendLocation.current ?? CLLocationManager().location).flatMap { Date.now.timeIntervalSince($0.timestamp) < 10 * 60 ? $0 : nil }
        let from = here ?? middle
        let nearest = candidates.min { a, b in
            from.distance(from: CLLocation(latitude: a.lat, longitude: a.lon))
                < from.distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
        }
        return nearest.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } ?? middle.coordinate
    }
}

private struct TrainRow: View {
    let train: Arrival
    /// When to set off; nil without a walking time.
    let leave: Date?
    /// Show the line bullet (several lines chosen, or e.g. an N running local on the R).
    let marksLine: Bool
    /// Which times get a symbol in addition to colour.
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
            // Clamp at 0:00: a train held at the platform stays listed past its time
            if let leave {
                Text("leave in").font(.footnote).foregroundStyle(.secondary)
                Text(timerInterval: min(AppClock.real(leave), Date.now)...AppClock.real(leave), countsDown: true)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            } else {
                Text(timerInterval: min(AppClock.real(train.time), Date.now)...AppClock.real(train.time), countsDown: true)
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
        // Disclosure only when there's more to show
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
    @State private var position: MapCameraPosition

    init(station: Station, route: String) {
        self.station = station
        self.route = route
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: station.coordinate,
            latitudinalMeters: 350,
            longitudinalMeters: 350
        )))
    }

    var body: some View {
        Map(position: $position) {
            Marker(station.name, systemImage: "tram.fill", coordinate: station.coordinate)
                .tint(LineStyle.of(route).swiftUIColor)
            ForEach(Array(station.entrances.enumerated()), id: \.offset) { _, entrance in
                Annotation(entrance.isElevator ? "Elevator" : "", coordinate: CLLocationCoordinate2D(latitude: entrance.lat, longitude: entrance.lon)) {
                    EntranceMark(entrance: entrance)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // Turned Grid North where it rests, if Settings says: a little further out, for the
        // square round the station's corners
        .turnsNorth($position, widening: 1.2)
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
        // Speak what the colour and fill show
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entrance.isElevator ? "Elevator entrance" : entrance.exitOnly == true ? "Exit only" : "Entrance")
    }
}
