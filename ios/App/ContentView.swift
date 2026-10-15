import AppIntents
import MapKit
import SwiftUI
import WidgetKit

struct ContentView: View {
    @State private var selection = SharedStore.load()
    @State private var board: Board?
    @State private var loadState = LoadState.loading
    /// Moves along every few seconds so trains you can no longer catch drop off the list.
    @State private var now = Date.now
    /// The train the Lock Screen countdown is for, while one is running.
    @State private var countdownTrain: Date? = TrainActivityController.currentTrain
    @State private var countdownProblem: String?
    @State private var choosingTrain = false

    private enum LoadState { case loading, loaded, failed }

    private var station: Station? { selection.station }
    /// The trains you can still catch, given the walking time.
    private var trains: [Arrival] { selection.catchable(board?.trains ?? [], now: now) }

    var body: some View {
        NavigationStack {
            List {
                trainSection
                Section {
                    Stepper(value: $selection.walkMinutes, in: 0...60) {
                        Text(selection.walkMinutes == 0 ? "Walk to the station: not set" : "Walk to the station: \(selection.walkMinutes) min")
                    }
                } header: {
                    Text("Getting there")
                } footer: {
                    Text("Trains you can't reach in time are left out, and the widget counts down to when to leave.")
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
                Section {
                    SiriTipView(intent: NextTrainIntent())
                    ShortcutsLink()
                } header: {
                    Text("Siri and Shortcuts")
                }
                if !SharedStore.isAvailable {
                    Section {
                        Label("The widget can't see your choice on this install, so it keeps showing Prospect Av (R) toward Manhattan.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } footer: {
                        Text("The shared storage the app and widget use wasn't set up when this was installed. Reinstalling with AltStore should fix it.")
                    }
                }
            }
            .navigationTitle("Train Times")
            .sheet(isPresented: $choosingTrain) {
                TrainPicker(selection: $selection)
            }
            .refreshable { await loadBoard() }
            .onChange(of: selection) { _, new in
                SharedStore.save(new)
                WidgetCenter.shared.reloadAllTimelines()
            }
            .task(id: selection) { await loadBoard() }
            .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { now = $0 }
        }
    }

    /// The chosen train; tapping it chooses another, in three steps.
    private var trainSection: some View {
        Section {
            Button {
                choosingTrain = true
            } label: {
                HStack(spacing: 12) {
                    LineBullets(routes: selection.routes, size: 36)
                        .frame(width: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station?.name ?? "Choose a train").font(.headline).foregroundStyle(.primary)
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
        } header: {
            Text("Train")
        } footer: {
            Text("Widgets show this train unless you pick one in a widget's Edit menu.")
        }
    }

    private var trainsSection: some View {
        Section {
            if loadState == .failed {
                Text("Couldn't reach the MTA").foregroundStyle(.secondary)
            } else if loadState == .loading && trains.isEmpty {
                ProgressView()
            } else if trains.isEmpty {
                Text("No \(selection.linesLabel) trains predicted").foregroundStyle(.secondary)
            } else {
                ForEach(trains.prefix(5), id: \.self) { train in
                    TrainRow(
                        train: train,
                        leave: selection.walkMinutes > 0 ? selection.leaveTime(for: train) : nil,
                        marksLine: selection.marksLine(of: train)
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
            }
            if let countdownProblem {
                Text(countdownProblem).foregroundStyle(.secondary)
            }
        } header: {
            Text("On your way")
        } footer: {
            Text("Counts down to your train on the Lock Screen and in the Dynamic Island until you stop it. A widget's walk button starts and stops it too. Tap ↻ on it, or open the app, for new times.")
        }
    }

    private func startCountdown() async {
        do {
            countdownTrain = try await TrainActivityController.start(for: selection)
            countdownProblem = nil
        } catch {
            countdownProblem = error.localizedDescription
        }
    }

    private func alertsSection(_ alerts: [ServiceAlert]) -> some View {
        Section {
            if alerts.isEmpty {
                Label("No alerts for this line here right now", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(alerts) { alert in
                    AlertRow(alert: alert)
                }
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
                if loadState == .loaded && outages.isEmpty {
                    Label("All elevators and escalators are working", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(outages) { outage in
                    OutageRow(outage: outage)
                }
                Toggle("Show elevator outages on the widget", isOn: $selection.elevatorAlerts)
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

    private func loadBoard() async {
        loadState = .loading
        now = .now
        countdownTrain = TrainActivityController.currentTrain
        do {
            board = try await TrainService.board(for: selection)
            loadState = .loaded
        } catch {
            // a newer choice cancels this load; that isn't a failure
            if !Task.isCancelled { loadState = .failed }
        }
    }
}

private struct TrainRow: View {
    let train: Arrival
    /// When to set off, if a walking time is set.
    let leave: Date?
    /// Shown with its bullet: one of several lines chosen, or an N running local on the R, say.
    let marksLine: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(train.time, format: .dateTime.hour().minute())
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(train.isLive ? Color.liveText : Color.primary)
            if marksLine {
                LineBullet(route: train.route, size: 20)
            }
            if let terminal = train.terminal {
                Text(terminal).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let leave {
                Text("leave in").font(.footnote).foregroundStyle(.secondary)
                Text(leave, style: .timer)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            } else {
                Text(train.time, style: .timer)
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
