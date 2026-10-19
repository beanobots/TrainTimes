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

    /// `widgetID` is the widget whose walk button asked for it, if one did.
    ///
    /// It starts as soon as it has a train to count down to: from the times a
    /// widget last saved for this train, or else from the chosen lines' own
    /// feed alone. Then it fetches everything, the alert and rerouted trains
    /// too, and updates the countdown with them.
    private static func startNow(for selection: Selection, widgetID: String? = nil) async throws -> Date {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Problem.notAllowed }
        let now = Date.now
        var fullBoard: Board?
        var state: TrainActivityAttributes.ContentState?
        if let saved = SharedStore.loadBoard(for: selection) {
            state = Self.state(for: selection, trains: saved.trains, notice: saved.notice?.label, now: now, following: nil)
        }
        if state == nil, let quick = try? await TrainService.board(for: selection, includingAlerts: false,
                                                                    includingOtherLines: false, now: now) {
            state = Self.state(for: selection, board: quick, now: now, following: nil)
        }
        if state == nil {
            // None on the chosen lines' own feed, or it failed: maybe a rerouted train
            let board = try await fetchAll(for: selection)
            fullBoard = board
            state = Self.state(for: selection, board: board, now: .now, following: nil)
        }
        guard let state else { throw Problem.noTrains }
        let attributes = TrainActivityAttributes(
            selection: selection,
            stationName: selection.station?.name ?? "",
            heading: selection.heading
        )
        // The old one ends only once there's a new one, so if iOS refuses it,
        // the old countdown, and what the widgets show, stay as they were
        let activity = try Activity.request(attributes: attributes, content: content(state))
        await endActivities(except: activity.id)
        tellWidgets(SharedStore.Countdown(trainID: selection.trainID, ends: now.addingTimeInterval(lifetime),
                                          widgetID: widgetID), tapped: widgetID)
        guard fullBoard == nil else { return state.train }
        // It's up; now the alert and any rerouted trains, following the same train
        guard let board = try? await fetchAll(for: selection),
              let full = Self.state(for: selection, board: board, now: .now, following: state.trip) else { return state.train }
        await activity.update(content(full))
        return full.train
    }

    /// Everything for `selection`'s countdown, saved for the widgets to redraw
    /// with rather than fetching it again.
    private static func fetchAll(for selection: Selection) async throws -> Board {
        let board = try await TrainService.board(for: selection, includingOutages: selection.elevatorAlerts)
        SharedStore.saveBoard(board, for: selection, fetched: .now)
        return board
    }

    /// A widget's walk button (`widgetID` is that widget's): stops the
    /// countdown if the widget shows it, otherwise starts one for it.
    static func toggle(for selection: Selection, widgetID: String) async throws {
        try await inTurn {
            let shown = SharedStore.loadCountdown()?.isShown(onWidget: widgetID, for: selection.trainID) ?? false
            if shown && running.contains(where: { $0.attributes.selection.trainID == selection.trainID }) {
                await endActivities()
                tellWidgets(nil, tapped: widgetID)
            } else {
                _ = try await startNow(for: selection, widgetID: widgetID)
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

    /// Lets the widgets know whose countdown is running. After a tap on
    /// a widget's (`tapped`), iOS reloads that widget, so the others reload
    /// only if one of them showed the countdown before or does now.
    private static func tellWidgets(_ countdown: SharedStore.Countdown?, tapped: String? = nil) {
        let old = SharedStore.loadCountdown()
        guard old != countdown else { return }
        SharedStore.saveCountdown(countdown)
        let onlyTapped = { (countdown: SharedStore.Countdown?) in
            countdown.map { $0.widgetID != nil && $0.widgetID == tapped } ?? true
        }
        if !(onlyTapped(old) && onlyTapped(countdown)) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Out of date as the train is due, so iOS redraws the countdown then, and
    /// it moves on to the next train it has; see `ContentState.movedOn(at:)`.
    private static func content(_ state: TrainActivityAttributes.ContentState) -> ActivityContent<TrainActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.train)
    }

    /// The tracked trip if it's still coming; when starting, the first train you
    /// can catch; once the tracked train has gone, the next one you can catch.
    private static func state(for selection: Selection, board: Board, now: Date, following trip: String?) -> TrainActivityAttributes.ContentState? {
        state(for: selection, trains: board.trains, notice: board.notice(for: selection, settings: SharedStore.loadSettings())?.label,
              now: now, following: trip)
    }

    /// `notice` is the label of the alert to mention, if any.
    private static func state(for selection: Selection, trains: [Arrival], notice: String?, now: Date,
                              following trip: String?) -> TrainActivityAttributes.ContentState? {
        let upcoming = trains.filter { $0.time > now }
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
            notice: notice,
            updated: now,
            route: target.route,
            followingRoutes: following.map(\.route)
        )
    }
}
