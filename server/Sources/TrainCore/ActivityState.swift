import Foundation

/// Builds the countdown's state from a board, as the app does, and decides
/// when a new one is worth a push.
enum ActivityState {
    /// iOS ends a Live Activity after 8 hours (`TrainActivityController.lifetime`).
    static let lifetime: TimeInterval = 8 * 60 * 60

    /// Shown as out of date two minutes after the train is due
    /// (`TrainActivityController.content(_:)`).
    static func staleDate(for state: ContentState) -> Date {
        state.train.addingTimeInterval(2 * 60)
    }

    /// Mirrors `TrainActivityController.state(for:board:now:following:)`: the
    /// tracked trip if it's still coming; when starting, the first train you
    /// can catch; once the tracked train has gone, the next one you can catch.
    /// The app reads `settings` from SharedStore; the server has the copy the
    /// app sent when it registered.
    static func state(for selection: Selection, board: Board, now: Date, following trip: String?,
                      settings: AppSettings) -> ContentState? {
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
        return ContentState(
            train: target.time,
            trip: target.trip,
            isLive: target.isLive,
            terminal: target.terminal,
            following: following.map(\.time),
            notice: board.notice(for: selection, settings: settings)?.label,
            updated: now,
            route: target.route,
            followingRoutes: following.map(\.route)
        )
    }

    /// Mirrors the `else` branch of `TrainActivityController.refreshNow()`: with
    /// no trains at all, the countdown stays on its last train, saying so.
    static func noTrains(from last: ContentState, now: Date) -> ContentState {
        var state = last
        state.following = []
        state.notice = "No trains predicted"
        state.updated = now
        return state
    }

    enum Push: Equatable {
        /// Something changed that's worth showing now: priority 10.
        case update
        /// Nothing much changed, but `updated` is getting old: priority 5.
        case refresh
        case none
    }

    /// How far the train's time has to move for an update.
    static let trainThreshold: TimeInterval = 30
    /// How far one of the following trains has to move for an update.
    static let followingThreshold: TimeInterval = 60
    /// How old the last push can get before a low-priority refresh.
    static let refreshInterval: TimeInterval = 5 * 60

    /// Whether to push `new`, given the last state pushed and when. Not the app's:
    /// it updates whenever it refreshes, but pushes have a budget.
    static func push(_ new: ContentState, last: ContentState?, lastPush: Date?, now: Date) -> Push {
        guard let last, let lastPush else { return .update }
        if isMeaningful(new, comparedTo: last) { return .update }
        return now.timeIntervalSince(lastPush) >= refreshInterval ? .refresh : .none
    }

    static func isMeaningful(_ new: ContentState, comparedTo last: ContentState) -> Bool {
        // Another train (or the same trip now ending somewhere else, or on another line)
        if new.trip != last.trip || new.route != last.route || new.terminal != last.terminal { return true }
        if abs(new.train.timeIntervalSince(last.train)) >= trainThreshold { return true }
        if new.isLive != last.isLive || new.notice != last.notice { return true }
        if new.following.count != last.following.count || new.followingRoutes != last.followingRoutes { return true }
        return zip(new.following, last.following).contains { abs($0.timeIntervalSince($1)) >= followingThreshold }
    }
}
