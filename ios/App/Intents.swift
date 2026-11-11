import AppIntents
import SwiftUI

/// "When's my next train in Leeway?"
struct NextTrainIntent: AppIntent {
    static let title: LocalizedStringResource = "When's my next train?"
    static let description = IntentDescription("Says when your next train comes, and when to leave if you've set a walking time.")

    @Parameter(title: "Train", description: "Leave empty for your default train, set in Settings.")
    var stop: StopEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let now = Date.now
        // A bus home stop, with no train asked for: its next buses
        if stop == nil, let bus = SharedStore.defaultBus {
            let times = await BusTimes.arrivals(lines: bus.allLines, at: bus.place, onlyAt: bus.stop.id, now: now)
            let buses = Array((times?.arrivals ?? []).prefix(3))
            return .result(dialog: "\(Spoken.nextBus(bus, buses: buses, reached: times != nil, now: now))",
                           view: NextBusSnippet(bus: bus, buses: buses))
        }
        let app = Selection.defaultTrain
        let selection = stop?.selection(basedOn: app) ?? app
        let settings = SharedStore.loadSettings()
        // Only the alerts and outages Siri can mention
        guard let board = try? await TrainService.board(for: selection, includingAlerts: selection.mentionsAlerts(with: settings),
                                                        includingOutages: selection.elevatorAlerts, now: now) else {
            return .result(dialog: "I couldn't reach the MTA. Try again in a moment.", view: NextTrainSnippet(selection: selection, trains: []))
        }
        let trains = selection.catchable(board.trains, now: now)
        let notice = board.notice(for: selection, settings: settings)
        // All board trains are upcoming, so any not catchable are too soon to reach
        let sentence = Spoken.nextTrain(selection: selection, trains: trains, unreachable: trains.count < board.trains.count,
                                        notice: notice, now: now)
        return .result(dialog: "\(sentence)", view: NextTrainSnippet(selection: selection, trains: Array(trains.prefix(3))))
    }
}

/// "Start my train countdown in Leeway": Lock Screen and Dynamic Island countdown.
struct StartCountdownIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start my train countdown"
    static let description = IntentDescription("Counts down to your next train on the Lock Screen and in the Dynamic Island.")

    @Parameter(title: "Train", description: "Leave empty for your default train, set in Settings.")
    var stop: StopEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // A bus home stop, with no train asked for: its next bus
        if stop == nil, let bus = SharedStore.defaultBus {
            let started = try await TrainActivityController.start(bus: bus)
            return .result(dialog: "Counting down to the \(Spoken.clock(started.due)) \(BusNames.label(started.line)).")
        }
        let app = Selection.defaultTrain
        let selection = stop?.selection(basedOn: app) ?? app
        let train = try await TrainActivityController.start(for: selection)
        return .result(dialog: "Counting down to the \(Spoken.clock(train)) train.")
    }
}

/// Siri phrases, no setup needed. iOS requires the app's name in each phrase.
struct TrainShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextTrainIntent(),
            phrases: [
                "When's my next train in \(.applicationName)",
                "When is my next train in \(.applicationName)",
                "Next train in \(.applicationName)",
                "Check \(.applicationName)",
                "When's my next bus in \(.applicationName)",
                "Next bus in \(.applicationName)",
            ],
            shortTitle: "Next train",
            systemImageName: "tram.fill"
        )
        AppShortcut(
            intent: StartCountdownIntent(),
            phrases: [
                "Start my train countdown in \(.applicationName)",
                "Start my bus countdown in \(.applicationName)",
                "I'm on my way in \(.applicationName)",
            ],
            shortTitle: "Count down to my train",
            systemImageName: "timer"
        )
    }
}

/// Siri's card for a bus home stop: its lines, stop and way, then its next buses.
struct NextBusSnippet: View {
    let bus: BusChoice
    let buses: [BusArrival]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(bus.allLines.prefix(3), id: \.self) { BusBadge(line: $0, size: 26) }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(bus.stopName).font(.headline)
                    Text("Toward \(bus.shortWayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if buses.isEmpty {
                Text("No buses to show").foregroundStyle(.secondary)
            }
            ForEach(buses, id: \.self) { arrival in
                HStack(spacing: 8) {
                    if let time = arrival.time {
                        Text(time, format: .dateTime.hour().minute())
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(arrival.isLive ? Color.liveText : .primary)
                    }
                    if bus.allLines.count > 1 {
                        BusBadge(line: arrival.line, size: 18)
                    }
                    if let stops = arrival.stopsAway {
                        Text(stops == 1 ? "1 stop away" : "\(stops) stops away")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
        .padding()
    }
}

/// The answer card Siri and Shortcuts show.
struct NextTrainSnippet: View {
    let selection: Selection
    let trains: [Arrival]
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    var body: some View {
        let marks = SharedStore.loadSettings().timeMarks(withoutColor: withoutColor)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LineBullets(routes: selection.routes, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(selection.station?.name ?? "").font(.headline)
                    Text(selection.heading)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if trains.isEmpty {
                Text("No trains to show").foregroundStyle(.secondary)
            }
            ForEach(trains, id: \.self) { train in
                HStack(spacing: 8) {
                    Text(train.time, format: .dateTime.hour().minute())
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(train.statusColor(scheduled: .primary))
                    StatusMark(isLive: train.isLive, marks: marks, size: 12)
                        .foregroundStyle(train.statusColor(scheduled: .primary))
                    if selection.marksLine(of: train) {
                        LineBullet(route: train.route, size: 18)
                    }
                    if let terminal = train.terminal {
                        Text(terminal).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if selection.walkMinutes > 0 {
                        Text("leave \(Spoken.clock(selection.leaveTime(for: train)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }
}
