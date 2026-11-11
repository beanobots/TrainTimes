import Foundation

/// How far times have to move for a push, and how often a countdown is
/// refreshed anyway: PUSH_EARLIER_SECONDS and the rest.
struct PushTiming: Sendable, Equatable {
    /// How far the train's time has to move earlier, beyond which it's an update:
    /// less than later, as a train coming sooner could be missed.
    var earlier: TimeInterval = 15
    /// How far the train's time has to move later, beyond which it's an update.
    var later: TimeInterval = 60
    /// How far one of the following trains has to move for an update.
    var following: TimeInterval = 60
    /// How old the last push can get before a low-priority refresh.
    var refresh: TimeInterval = 5 * 60
}

/// Decides when the countdown's new state, made as the app makes it
/// (Shared/Countdown.swift), is worth a push.
enum ActivityState {
    /// How long a countdown runs before it's ended (`CountdownState.lifetime`).
    static let lifetime = CountdownState.lifetime

    /// Out of date as the train is due, as the app posts it (`CountdownState.staleDate`).
    static func staleDate(for state: ContentState) -> Date {
        state.staleDate
    }

    enum Push: Equatable {
        /// Something changed that's worth showing: priority 10, or 5 when only the trains after
        /// the one counted down to did (`priority(of:_:last:timing:)`).
        case update
        /// Nothing much changed, but `updated` is getting old: priority 5.
        case refresh
        case none
    }

    /// Whether to push `new`, given the last state pushed and when. Not the app's:
    /// it updates whenever it refreshes, but pushes have a budget.
    static func push(_ new: ContentState, last: ContentState?, lastPush: Date?, now: Date,
                     timing: PushTiming = PushTiming()) -> Push {
        guard let last, let lastPush else { return .update }
        if isMeaningful(new, comparedTo: last, timing: timing) { return .update }
        return now.timeIntervalSince(lastPush) >= timing.refresh ? .refresh : .none
    }

    static func isMeaningful(_ new: ContentState, comparedTo last: ContentState,
                             timing: PushTiming = PushTiming()) -> Bool {
        if changesTrain(new, comparedTo: last, timing: timing) { return true }
        if new.following.count != last.following.count || new.followingRoutes != last.followingRoutes { return true }
        return zip(new.following, last.following).contains { abs($0.timeIntervalSince($1)) >= timing.following }
    }

    /// Whether the train counted down to changed enough to push (`isMeaningful`): another
    /// train, moved, now live or not, or another notice. Not only the trains after it.
    static func changesTrain(_ new: ContentState, comparedTo last: ContentState,
                             timing: PushTiming = PushTiming()) -> Bool {
        // Another train (or the same trip now ending somewhere else, or on another line). Not
        // once moved on between passes (`Poller.pushDue`), which leaves its trip and terminal
        // unknown till the next pass fills them in: the same train still, on the same line, as
        // far as its times say (a bus's has no trip, and only its terminal goes)
        let movedOn = last.trip.isEmpty && last.terminal == nil
        if new.route != last.route || !movedOn && (new.trip != last.trip || new.terminal != last.terminal) { return true }
        let moved = new.train.timeIntervalSince(last.train)
        if moved < -timing.earlier || moved > timing.later { return true }
        return new.isLive != last.isLive || new.notice != last.notice
    }

    /// APNs priority for pushing `new` as `decision` says: 10, sent at once, when the train
    /// counted down to changed (`changesTrain`), or for the first push; 5, which APNs may hold
    /// to save the phone's battery, for a refresh or when only the trains after it moved.
    static func priority(of decision: Push, _ new: ContentState, last: ContentState?,
                         timing: PushTiming = PushTiming()) -> Int {
        guard decision == .update else { return 5 }
        guard let last else { return 10 }
        return changesTrain(new, comparedTo: last, timing: timing) ? 10 : 5
    }

    /// Whether the phone's widgets for the countdown's train would show `new` differently from
    /// `last` (nil before the first push): another train or line, live or not, or its time in
    /// another minute, as widgets show minutes (`MinutesToGo`) and clock times. Seconds within
    /// a minute aren't worth a reload; the next does. The trains after it only once one comes or
    /// goes, or moves as far as an update takes (`PushTiming.following`): crossing into another
    /// minute by a few seconds isn't worth waking every widget for. A trip filled in after a
    /// move-on (`isMeaningful`) isn't a change: without one, widgets find the train by its time
    /// and line instead (`CountdownSync`), which comes to the same train.
    static func changesWidgets(_ new: ContentState, from last: ContentState?,
                               timing: PushTiming = PushTiming()) -> Bool {
        guard var last else { return true }
        if last.trip.isEmpty { last.trip = new.trip }
        func minute(_ date: Date) -> Int { Int((date.timeIntervalSinceReferenceDate / 60).rounded(.down)) }
        return new.trip != last.trip || new.route != last.route || new.isLive != last.isLive
            || minute(new.train) != minute(last.train)
            || new.following.count != last.following.count || new.followingRoutes != last.followingRoutes
            || zip(new.following, last.following).contains { abs($0.timeIntervalSince($1)) >= timing.following }
    }

    /// The notice of a countdown with no trains and no alert that's why
    /// (`ContentState.refreshed(for:board:settings:now:)`).
    static let noTrains = "No trains predicted"

    /// `new`, made from `board` at `now`, with `last`'s notice where that may
    /// still hold but `board` can't say: it hasn't the alerts, or the outages,
    /// that `selection` asks for, which isn't the same as there being none.
    /// The notice would otherwise go, and come back with the next pass, a push
    /// each time. An alert's stays unless an elevator out is now known to
    /// come before it; an elevator's, unless the trains have gone, when the
    /// notice names only an alert.
    static func keepingNotice(of last: ContentState, in new: ContentState, board: Board,
                              selection: Selection, now: Date) -> ContentState {
        guard let notice = last.notice, notice != new.notice else { return new }
        func isElevator(_ label: String?) -> Bool {
            label.flatMap(Notice.Kind.init(label:)) == .elevator
        }
        let mayHold: Bool
        if case .alert? = Notice.Kind(label: notice) {
            mayHold = selection.serviceAlerts && board.alerts == nil && !isElevator(new.notice)
        } else if isElevator(notice), selection.elevatorAlerts, board.outages == nil {
            // Unless the trains have gone, as `refreshed` finds them
            mayHold = ContentState(for: selection, trains: board.trains, notice: nil, now: now,
                                   following: last.trip, after: last.train) != nil
        } else {
            mayHold = false
        }
        guard mayHold else { return new }
        var state = new
        state.notice = notice
        return state
    }
}
