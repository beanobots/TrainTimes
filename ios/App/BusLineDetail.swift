import CoreLocation
import SwiftUI

/// A bus line at a stop both ways, as a Nearby tile opens it.
struct BusLineWays: Hashable {
    /// "B67"
    let line: String
    /// The nearer stop's name, as its sign has it: "7 Av & 9 St".
    let stopName: String
    /// Each way's stop and next buses, as Nearby last had them.
    let ways: [NearbyBusPick.Way]
    /// Your walk to the stop; nil once the map's moved off you.
    let walkMinutes: Int?
}

/// A bus line at a stop both ways, as Train Detail's line page has a train's: each way a
/// section of the buses you can still make, with when to leave, and its own countdown.
struct BusLineDetail: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.scenePhase) private var scenePhase
    let line: BusLineWays

    /// Each way's buses: Nearby's to start with, then this page's own.
    @State private var ways: [NearbyBusPick.Way]
    /// The last load failed: the buses shown may be out of date.
    @State private var failed = false
    /// Each way's running countdown's bus, by its stop's id, if it's counting down to it.
    @State private var countdownBuses: [String: Date] = [:]
    @State private var countdownProblems: [String: String] = [:]
    /// The stop whose countdown is starting, to block a second tap.
    @State private var starting: String?
    /// Ticks every few seconds so buses gone drop off.
    @State private var now = AppClock.now

    init(line: BusLineWays) {
        self.line = line
        _ways = State(initialValue: line.ways)
    }

    private var walk: Int { line.walkMinutes ?? 0 }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    BusBadge(line: line.line, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(BusBadge.label(line.line)) at \(line.stopName)").font(.headline)
                        if let minutes = line.walkMinutes {
                            Text("\(minutes) min walk").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(ways, id: \.stop.id) { way in
                waySection(way, isLast: way.stop.id == ways.last?.stop.id)
            }
        }
        .navigationTitle(line.stopName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        // Every 30 s, sooner after a failure; not in the background
        .task(id: Polling(id: line, inForeground: scenePhase != .background)) {
            guard scenePhase != .background else { return }
            while !Task.isCancelled {
                await load()
                await Connectivity.shared.pause(for: .seconds(failed ? 10 : 30))
            }
        }
        .ticking($now)
    }

    /// `way`'s buses you can reach in time, as arrivals.
    private func buses(_ way: NearbyBusPick.Way) -> [(arrival: Arrival, bus: BusArrival)] {
        let reachable = now.addingTimeInterval(TimeInterval(walk) * 60)
        return way.arrivals.compactMap { bus in
            guard let time = bus.time, time >= reachable else { return nil }
            return (Arrival(route: line.line, time: time, stop: way.stop.id, lastStop: bus.destination ?? "",
                            isLive: bus.isLive && !failed), bus)
        }
    }

    private func choice(_ way: NearbyBusPick.Way) -> BusChoice {
        BusChoice(line: line.line, stop: way.stop, destination: way.destination)
    }

    @ViewBuilder private func waySection(_ way: NearbyBusPick.Way, isLast: Bool) -> some View {
        let id = way.stop.id
        let coming = buses(way)
        let marks = settings.timeMarks(withoutColor: withoutColor)
        Section {
            if failed {
                Label("Couldn't reach Bus Time, so these times may be out of date.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            if coming.isEmpty {
                Text(way.arrivals.contains { ($0.time ?? .distantPast) > now }
                     ? "No \(BusBadge.label(line.line)) buses you can reach in time"
                     : "No \(BusBadge.label(line.line)) buses due")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(coming.prefix(3).enumerated()), id: \.offset) { index, pair in
                // The next bus's only: Bus Time's for the ones after can be its too
                BusTimeRow(train: pair.arrival, stopsAway: index == 0 ? pair.bus.stopsAway : nil,
                           walkMinutes: walk, marks: marks)
            }
            if let bus = countdownBuses[id] {
                Label("Counting down to the \(Spoken.clock(bus)) bus", systemImage: "timer")
                Button("Stop the countdown", role: .destructive) {
                    Task {
                        await TrainActivityController.endAll()
                        countdownBuses = [:]
                    }
                }
            } else {
                Button {
                    Task { await startCountdown(way) }
                } label: {
                    Label("I'm on my way", systemImage: "figure.walk.departure")
                }
                .disabled(starting != nil)
            }
            if let problem = countdownProblems[id] {
                Text(problem).foregroundStyle(.secondary)
            }
        } header: {
            Text("To \(way.name)")
        } footer: {
            if isLast {
                Text("Green times are from where the bus is now; the rest are the timetable's. I'm on my way counts down to that way's bus on the Lock Screen and in the Dynamic Island, in place of any other countdown.")
            }
        }
    }

    /// This line's buses at the same stops, found as Nearby finds them; kept on failure.
    private func load() async {
        now = AppClock.now
        for way in ways {
            countdownBuses[way.stop.id] = TrainActivityController.currentBus(choice(way))
        }
        guard let stop = ways.first?.stop else { return }
        let ids = Set(ways.map(\.stop.id))
        let places = await NearbyBuses.places(near: CLLocation(latitude: stop.latitude, longitude: stop.longitude))
        guard !Task.isCancelled else { return }
        guard let places else {
            failed = true
            return
        }
        failed = false
        let label = BusBadge.label(line.line).uppercased()
        // Each stop's ways for this line, from whichever place found it: the place round the
        // first stop may pair it with another stop across
        var found: [String: NearbyBusPick.Way] = [:]
        for place in places where place.ways.contains(where: { ids.contains($0.stop.id) }) {
            for pick in place.lines(at: AppClock.now) where BusBadge.label(pick.line).uppercased() == label {
                for way in pick.ways where ids.contains(way.stop.id) && found[way.stop.id] == nil {
                    found[way.stop.id] = way
                }
            }
        }
        // Each way kept in place, its buses replaced; one not found keeps what it had, which
        // runs out by itself
        ways = ways.map { found[$0.stop.id] ?? $0 }
    }

    private func startCountdown(_ way: NearbyBusPick.Way) async {
        let id = way.stop.id
        starting = id
        defer { starting = nil }
        do {
            let started = try await TrainActivityController.start(bus: choice(way))
            // One countdown at a time: the other way's, if it was running, is replaced
            countdownBuses = [id: started.due]
            countdownProblems[id] = nil
        } catch {
            countdownProblems[id] = error.localizedDescription
        }
    }
}

/// One bus: when it's due, how many stops off it is, and when to leave for it, or with no walk,
/// how long till it's here.
private struct BusTimeRow: View {
    let train: Arrival
    let stopsAway: Int?
    let walkMinutes: Int
    let marks: TimeMarks

    var body: some View {
        HStack(spacing: 8) {
            Text(train.time, format: .dateTime.hour().minute())
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(train.statusColor(scheduled: .primary))
            StatusMark(isLive: train.isLive, marks: marks, size: 12)
                .foregroundStyle(train.statusColor(scheduled: .primary))
            if let stopsAway {
                Text(stopsAway == 1 ? "1 stop away" : "\(stopsAway) stops away").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            // Clamp at 0:00: a bus late at the stop stays listed past its time
            if walkMinutes > 0 {
                let leave = train.time.addingTimeInterval(-TimeInterval(walkMinutes) * 60)
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
