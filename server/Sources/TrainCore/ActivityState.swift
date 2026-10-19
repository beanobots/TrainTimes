import Foundation

/// Decides when the countdown's new state, made as the app makes it
/// (Shared/Countdown.swift), is worth a push.
enum ActivityState {
    /// iOS ends a Live Activity after 8 hours (`CountdownState.lifetime`).
    static let lifetime = CountdownState.lifetime

    /// Out of date as the train is due, as the app posts it (`CountdownState.staleDate`).
    static func staleDate(for state: ContentState) -> Date {
        state.staleDate
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
