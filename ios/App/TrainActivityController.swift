import ActivityKit
import Foundation
import WidgetKit

/// Starts, refreshes and ends the Lock Screen countdown.
///
/// Without a push server, a Live Activity only gets new times while the app runs:
/// when it's opened, or when someone taps a refresh or walk button (which run
/// their intents in the app). In between, the countdown still ticks on its own.
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

    /// iOS ends a Live Activity after 8 hours.
    private static let lifetime: TimeInterval = 8 * 60 * 60

    /// Countdowns still running: not ones that have ended or been swiped away.
    private static var running: [Activity<TrainActivityAttributes>] {
        Activity<TrainActivityAttributes>.activities.filter { [.active, .stale].contains($0.activityState) }
    }

    /// The train the running countdown is for, if there is one.
    static var currentTrain: Date? {
        running.first?.content.state.train
    }

    /// The train the running countdown is for, if it's one of `selection`'s.
    static func currentTrain(for selection: Selection) -> Date? {
        running.first { $0.attributes.selection.trainID == selection.trainID }?.content.state.train
    }

    /// The last of `start`, `toggle`, `refresh` and `endAll` asked for. They
    /// run one at a time: each waits on the network or on iOS, and two at once
    /// (a double tap) could leave two countdowns running, or have a toggle
    /// start one rather than stop it.
    @MainActor private static var last: Task<Void, Never>?

    /// Runs `body` once everything asked for before it has finished.
    @MainActor
    private static func inTurn<T>(_ body: @escaping () async throws -> T) async throws -> T {
        let previous = last
        let task = Task {
            await previous?.value
            return try await body()
        }
        last = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Starts counting down to the next train you can catch, replacing any
    /// countdown already running, and returns when that train arrives.
    @discardableResult
    static func start(for selection: Selection) async throws -> Date {
        try await inTurn { try await startNow(for: selection) }
    }

    private static func startNow(for selection: Selection) async throws -> Date {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Problem.notAllowed }
        let now = Date.now
        let board = try await TrainService.board(for: selection, includingOutages: selection.elevatorAlerts, now: now)
        // The widgets redraw with these times rather than fetching them again
        SharedStore.saveBoard(board, for: selection, fetched: .now)
        guard let state = state(for: selection, board: board, now: now, following: nil) else { throw Problem.noTrains }
        let attributes = TrainActivityAttributes(
            selection: selection,
            stationName: selection.station?.name ?? "",
            heading: selection.heading
        )
        // The old one ends only once there's a new one, so if iOS refuses it,
        // the old countdown, and what the widgets show, stay as they were
        let activity = try Activity.request(attributes: attributes, content: content(state))
        await endActivities(except: activity.id)
        tellWidgets(SharedStore.Countdown(trainID: selection.trainID, ends: now.addingTimeInterval(lifetime)))
        return state.train
    }

    /// A widget's walk button: stops the countdown if it's for this train,
    /// otherwise starts one for it.
    static func toggle(for selection: Selection) async throws {
        try await inTurn {
            if running.contains(where: { $0.attributes.selection.trainID == selection.trainID }) {
                await endAllNow()
            } else {
                _ = try await startNow(for: selection)
            }
        }
    }

    /// New times for every running countdown: the same train while it's still
    /// coming, the next one once it has gone. With no trains at all it stays up,
    /// saying so, until you stop it.
    static func refresh() async {
        _ = try? await inTurn { await refreshNow() }
    }

    private static func refreshNow() async {
        // It may have ended without the app knowing: swiped away, or after 8 hours
        if running.isEmpty { tellWidgets(nil) }
        for activity in running {
            let selection = activity.attributes.selection
            let now = Date.now
            guard let board = try? await TrainService.board(for: selection, includingOutages: selection.elevatorAlerts, now: now) else { continue }
            SharedStore.saveBoard(board, for: selection, fetched: .now)
            if let state = state(for: selection, board: board, now: now, following: activity.content.state.trip) {
                await activity.update(content(state))
            } else {
                var state = activity.content.state
                state.following = []
                state.notice = "No trains predicted"
                state.updated = now
                await activity.update(content(state))
            }
        }
    }

    static func endAll() async {
        _ = try? await inTurn { await endAllNow() }
    }

    private static func endAllNow() async {
        await endActivities()
        tellWidgets(nil)
    }

    private static func endActivities(except kept: String? = nil) async {
        for activity in Activity<TrainActivityAttributes>.activities where activity.id != kept {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Lets the widgets know which train's walk button to show as on.
    private static func tellWidgets(_ countdown: SharedStore.Countdown?) {
        guard SharedStore.loadCountdown() != countdown else { return }
        SharedStore.saveCountdown(countdown)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Shown as out of date two minutes after the train is due.
    private static func content(_ state: TrainActivityAttributes.ContentState) -> ActivityContent<TrainActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.train.addingTimeInterval(2 * 60))
    }

    /// The tracked trip if it's still coming; when starting, the first train you
    /// can catch; once the tracked train has gone, the next one you can catch.
    private static func state(for selection: Selection, board: Board, now: Date, following trip: String?) -> TrainActivityAttributes.ContentState? {
        let upcoming = board.trains.filter { $0.time > now }
        let catchable = selection.catchable(upcoming, now: now).first
        let target: Arrival?
        // A trip without an id can't be told from another one without
        if let trip, !trip.isEmpty {
            target = upcoming.first { $0.trip == trip } ?? catchable
        } else {
            target = catchable
        }
        guard let target else { return nil }
        let following = upcoming.filter { $0.time > target.time }.prefix(2)
        return TrainActivityAttributes.ContentState(
            train: target.time,
            trip: target.trip,
            isLive: target.isLive,
            terminal: target.terminal,
            following: following.map(\.time),
            notice: board.notice(for: selection, settings: SharedStore.loadSettings())?.label,
            updated: now,
            route: target.route,
            followingRoutes: following.map(\.route)
        )
    }
}
