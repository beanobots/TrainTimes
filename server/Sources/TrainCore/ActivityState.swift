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

    /// The notice of a countdown with no trains and no alert that's why
    /// (`ContentState.refreshed(for:board:settings:now:)`).
    static let noTrains = "No trains predicted"

    /// `new`, made from `board`, with `last`'s notice where that may still
    /// hold but `board` can't say: it hasn't the alerts, or the outages, that
    /// `selection` asks for, which isn't the same as there being none. The
    /// notice would otherwise go, and come back with the next pass, a push
    /// each time. An alert's stays unless an elevator out is now known to
    /// come before it; an elevator's, unless the trains have gone, when the
    /// notice names only an alert.
    static func keepingNotice(of last: ContentState, in new: ContentState, board: Board,
                              selection: Selection) -> ContentState {
        guard let notice = last.notice, notice != new.notice else { return new }
        let alerts = Set(ServiceAlert.Kind.allCases.map(\.label))
        func isElevator(_ label: String?) -> Bool {
            guard let label else { return false }
            return label != noTrains && !alerts.contains(label)
        }
        let mayHold: Bool
        if alerts.contains(notice) {
            mayHold = selection.serviceAlerts && board.alerts == nil && !isElevator(new.notice)
        } else {
            mayHold = isElevator(notice) && selection.elevatorAlerts && board.outages == nil && new.notice != noTrains
        }
        guard mayHold else { return new }
        var state = new
        state.notice = notice
        return state
    }
}
