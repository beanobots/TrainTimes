import ActivityKit
import Foundation

/// Starts, refreshes and ends the Lock Screen countdown.
///
/// Without a push server, a Live Activity only gets new times while the app runs:
/// when it's opened, or when someone taps the countdown's refresh button (which
/// runs `RefreshCountdownIntent` in the app). In between, the countdown still
/// ticks on its own.
enum TrainActivityController {
    enum Problem: LocalizedError {
        case notAllowed, noTrains

        var errorDescription: String? {
            switch self {
            case .notAllowed: "Live Activities are off for Train Times. Turn them on in Settings › Train Times."
            case .noTrains: "There's no train you can catch right now."
            }
        }
    }

    /// The train the running countdown is for, if there is one.
    static var currentTrain: Date? {
        Activity<TrainActivityAttributes>.activities.first?.content.state.train
    }

    /// Starts counting down to the next train you can catch, replacing any
    /// countdown already running, and returns when that train arrives.
    @discardableResult
    static func start(for selection: Selection) async throws -> Date {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Problem.notAllowed }
        let now = Date.now
        let board = try await TrainService.board(for: selection, includingOutages: selection.elevatorAlerts, now: now)
        guard let state = state(for: selection, board: board, now: now, following: nil) else { throw Problem.noTrains }
        await endAll()
        let attributes = TrainActivityAttributes(
            selection: selection,
            stationName: selection.station?.name ?? "",
            heading: selection.station?.directionLabel(selection.direction) ?? ""
        )
        _ = try Activity.request(attributes: attributes, content: content(state))
        return state.train
    }

    /// New times for every running countdown: the same train while it's still
    /// coming, the next one once it has gone.
    static func refresh() async {
        for activity in Activity<TrainActivityAttributes>.activities {
            let selection = activity.attributes.selection
            let now = Date.now
            guard let board = try? await TrainService.board(for: selection, includingOutages: selection.elevatorAlerts, now: now) else { continue }
            if let state = state(for: selection, board: board, now: now, following: activity.content.state.trip) {
                await activity.update(content(state))
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    static func endAll() async {
        for activity in Activity<TrainActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Shown as out of date two minutes after the train is due.
    private static func content(_ state: TrainActivityAttributes.ContentState) -> ActivityContent<TrainActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.train.addingTimeInterval(2 * 60))
    }

    /// The tracked trip if it's still coming; when starting, the first train you
    /// can catch; once the tracked train has gone, the next one.
    private static func state(for selection: Selection, board: Board, now: Date, following trip: String?) -> TrainActivityAttributes.ContentState? {
        let upcoming = board.trains.filter { $0.time > now }
        let target: Arrival?
        if let trip {
            target = upcoming.first { $0.trip == trip } ?? upcoming.first
        } else {
            target = selection.catchable(upcoming, now: now).first
        }
        guard let target else { return nil }
        return TrainActivityAttributes.ContentState(
            train: target.time,
            trip: target.trip,
            isLive: target.isLive,
            terminal: target.terminal,
            following: upcoming.filter { $0.time > target.time }.prefix(2).map(\.time),
            notice: board.notice(includingElevators: selection.elevatorAlerts)?.label,
            updated: now
        )
    }
}
