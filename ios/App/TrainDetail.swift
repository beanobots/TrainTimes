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
    /// While a countdown's starting, so a second tap doesn't start another.
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
                Stepper(value: $selection.walkMinutes, in: 0...60) {
                    Text(selection.walkMinutes == 0 ? "Walk to the station: not set" : "Walk to the station: \(selection.walkMinutes) min")
                }
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
        // New times every 30 seconds, and alerts every 10 minutes; a new walking time needs none
        .task(id: selection.trainID) {
            while !Task.isCancelled {
                await loadBoard()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                now = .now
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
                HStack(spacing: 12) {
                    LineBullets(routes: selection.routes, size: 36)
                        .frame(width: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station?.name ?? "Train").font(.headline)
                        if let station {
                            Text("\(Lines.list(selection.routes)) \(selection.heading) · \(station.borough)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
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
                if board?.trains.contains(where: { $0.time > now }) == true {
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
                        marksLive: settings.marksLive(withoutColor: withoutColor),
                        marksScheduled: settings.settings.marksScheduledTimes
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
            Text("Counts down to your train on the Lock Screen and in the Dynamic Island until you stop it, in place of any other countdown. A widget's walk button starts and stops it too. Tap ↻ on it, or open the app, for new times.")
        }
    }

    private func startCountdown() async {
        startingCountdown = true
        defer { startingCountdown = false }
        do {
            countdownTrain = try await TrainActivityController.start(for: selection)
            countdownProblem = nil
        } catch {
            countdownProblem = error.localizedDescription
        }
    }

    private func alertsSection(_ alerts: [ServiceAlert]?) -> some View {
        Section {
            if let alerts, alerts.isEmpty {
                Label("No alerts for this line here right now", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else if let alerts {
                ForEach(alerts) { alert in
                    AlertRow(alert: alert)
                }
            } else {
                Text("Couldn't load alerts from the MTA").foregroundStyle(.secondary)
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
                        Image(systemName: platform.ada == 0 ? "figure.stairs" : "figure.roll")
                    }
                }
            } else if let platform = platforms.first {
                Label(platform.accessibility ?? "No step-free access", systemImage: platform.ada == 0 ? "figure.stairs" : "figure.roll")
            }
            if EquipmentDirectory.hasEquipment(atComplex: station.complex) {
                let outages = board?.outages ?? []
                if loadState == .loaded, let board {
                    if board.outages == nil {
                        Text("Couldn't load elevator status from the MTA").foregroundStyle(.secondary)
                    } else if outages.isEmpty {
                        Label("All elevators and escalators are working", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(outages) { outage in
                    OutageRow(outage: outage)
                }
            } else {
                Text("No elevators or escalators at this station").foregroundStyle(.secondary)
            }
        } header: {
            Text("Accessibility")
        } footer: {
            Text("Elevator and escalator status from the MTA.")
        }
    }

    private func mapSection(_ station: Station) -> some View {
        Section {
            StationMap(station: station, route: selection.firstRoute)
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
            Link(destination: URL(string: "https://maps.apple.com/?daddr=\(station.lat),\(station.lon)&dirflg=w")!) {
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

    /// Times already shown stay up while new ones load, and if they don't come,
    /// saying how old they are. Alerts and outages come with them only when
    /// `includingNotices`, or when the ones shown are 10 minutes old; otherwise
    /// those shown stay.
    private func loadBoard(includingNotices: Bool = false) async {
        if board == nil { loadState = .loading }
        now = .now
        countdownTrain = TrainActivityController.currentTrain(for: selection)
        let trainID = selection.trainID
        let fetchesNotices = includingNotices || board == nil
            || noticesFetched.map { now.timeIntervalSince($0) >= 10 * 60 } ?? true
        do {
            var fetched = try await TrainService.board(for: selection, includingAlerts: fetchesNotices)
            // A newer choice cancels this load, but can't stop the fetch: what
            // it brings is the other train's
            guard !Task.isCancelled, trainID == selection.trainID else { return }
            // Only once both have come are they good for 10 minutes; until
            // then, any shown before stay, and the next load tries again
            if fetchesNotices && fetched.alerts != nil && fetched.outages != nil {
                noticesFetched = now
            }
            fetched.alerts = fetched.alerts ?? board?.alerts
            fetched.outages = fetched.outages ?? board?.outages
            board = fetched
            timesFetched = now
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
    /// Whether a live prediction gets its symbol as well as its green.
    let marksLive: Bool
    /// Whether a timetable time gets its symbol.
    let marksScheduled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(train.time, format: .dateTime.hour().minute())
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(train.isLive ? Color.liveText : Color.primary)
            if marksLive && train.isLive {
                LiveMark(size: 12).foregroundStyle(Color.liveText)
            } else if marksScheduled && !train.isLive {
                ScheduledMark(size: 12)
            }
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
            VStack(alignment: .leading, spacing: 4) {
                Label(alert.kind.label, systemImage: alert.kind.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(alert.kind.tint)
                Text(alert.header)
            }
        }
    }
}

private struct OutageRow: View {
    let outage: Outage

    private var title: String {
        let machine = outage.isElevator ? "elevator" : "escalator"
        return outage.isPlanned ? "Planned \(machine) work" : (outage.isElevator ? "Elevator out" : "Escalator out")
    }

    private var when: String {
        let start = outage.start?.formatted(date: .abbreviated, time: .shortened)
        let end = outage.estimatedReturn?.formatted(date: .abbreviated, time: .shortened)
        switch (outage.isPlanned, start, end) {
        case (true, let start?, let end?): return "\(start) to \(end)"
        case (false, let start?, let end?): return "Since \(start). Back \(end) (estimate)"
        case (false, let start?, nil): return "Since \(start)"
        default: return ""
        }
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
                if !when.isEmpty {
                    Text(when).font(.footnote).foregroundStyle(.secondary)
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
                .tint(Color(hex: LineStyle.of(route).color))
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
}
