import AppIntents
import SwiftUI

/// "When's my next train in Train Times?"
struct NextTrainIntent: AppIntent {
    static let title: LocalizedStringResource = "When's my next train?"
    static let description = IntentDescription("Says when your next train comes, and when to leave if you've set a walking time.")

    @Parameter(title: "Train", description: "Leave empty for the train your default widget shows.")
    var stop: StopEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let now = Date.now
        // In the default widget's commuting hours, their train, as the widget shows
        let app = Selection.defaultWidgetTrain(at: now)
        let selection = stop?.selection(basedOn: app) ?? app
        guard let board = try? await TrainService.board(for: selection, includingOutages: selection.elevatorAlerts, now: now) else {
            return .result(dialog: "I couldn't reach the MTA. Try again in a moment.", view: NextTrainSnippet(selection: selection, trains: []))
        }
        let trains = selection.catchable(board.trains, now: now)
        let notice = board.notice(for: selection, settings: SharedStore.loadSettings())
        // The board's trains are all still to come, so any not caught are too soon to reach
        let sentence = Spoken.nextTrain(selection: selection, trains: trains, unreachable: trains.count < board.trains.count,
                                        notice: notice, now: now)
        return .result(dialog: "\(sentence)", view: NextTrainSnippet(selection: selection, trains: Array(trains.prefix(3))))
    }
}

/// "Start my train countdown in Train Times": the Lock Screen and Dynamic Island countdown.
struct StartCountdownIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start my train countdown"
    static let description = IntentDescription("Counts down to your next train on the Lock Screen and in the Dynamic Island.")

    @Parameter(title: "Train", description: "Leave empty for the train your default widget shows.")
    var stop: StopEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = Selection.defaultWidgetTrain()
        let selection = stop?.selection(basedOn: app) ?? app
        let train = try await TrainActivityController.start(for: selection)
        return .result(dialog: "Counting down to the \(Spoken.clock(train)) train.")
    }
}

/// What Siri listens for, with nothing to set up. iOS needs the app's name in each phrase.
struct TrainShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextTrainIntent(),
            phrases: [
                "When's my next train in \(.applicationName)",
                "When is my next train in \(.applicationName)",
                "Next train in \(.applicationName)",
                "Check \(.applicationName)",
            ],
            shortTitle: "Next train",
            systemImageName: "tram.fill"
        )
        AppShortcut(
            intent: StartCountdownIntent(),
            phrases: [
                "Start my train countdown in \(.applicationName)",
                "I'm on my way in \(.applicationName)",
            ],
            shortTitle: "Count down to my train",
            systemImageName: "timer"
        )
    }
}

/// The card Siri and Shortcuts show with the answer.
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
