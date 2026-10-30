import ActivityKit
import Foundation
import WidgetKit

/// Starts, refreshes and ends the Lock Screen countdown.
///
/// The push server (`ActivityPush`) gives a countdown new times while the app isn't running.
/// Without it, a Live Activity gets new times only while the app runs: when it's opened, a
/// refresh/walk button's intent runs, or a background refresh. The countdown still ticks on its
/// own in between.
enum TrainActivityController {
    enum Problem: LocalizedError {
        case notAllowed, noTrains

        var errorDescription: String? {
            switch self {
            case .notAllowed: "Live Activities are off for Leeway. Turn them on in Settings › Leeway."
            case .noTrains: "There's no train you can catch right now."
            }
        }
    }

    /// Max age of a widget's saved times for a countdown to start from them.
    private static let savedBoardAge: TimeInterval = 5 * 60

    /// Countdowns not yet ended or swiped away.
    private static var running: [Activity<TrainActivityAttributes>] {
        Activity<TrainActivityAttributes>.activities.filter { [.active, .stale].contains($0.activityState) }
    }

    /// The running countdown's train for `selection`, as the Lock Screen shows it (moved on to
    /// the next once its own has gone).
    static func currentTrain(for selection: Selection) -> Date? {
        running.first { $0.attributes.selection.trainID == selection.trainID }?.content.state.movedOn(at: .now).train
    }

    /// The latest `start`/`toggle`/`refresh`/`redraw`/`endAll` call. They run one at a time:
    /// overlapping ones (a double tap) could leave two countdowns running, or make a toggle
    /// start one instead of stopping it.
    @MainActor private static var last: Task<Void, Never>?

    /// Runs `body` after all earlier calls finish.
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

    /// Counts down to the first train you can catch, replacing any running countdown.
    /// Returns that train's arrival.
    @discardableResult
    static func start(for selection: Selection) async throws -> Date {
        try await inTurn { try await startNow(for: selection) }
    }

    /// `widgetID`: the widget whose walk button asked, if any. `trip`: the train to count down
    /// to while it's still coming (on Transfers, the first you can catch that reaches the change,
    /// not necessarily the next at your station); nil for the first you can catch. `change`: on
    /// Transfers, the widget's change, whose lines' alerts it mentions too.
    ///
    /// Starts as soon as it has a train, from a widget's recently saved times or else the chosen
    /// lines' own feed. Then fetches everything (alerts, rerouted trains) and updates. Widgets
    /// reload after that, so they find those times saved instead of fetching them again.
    private static func startNow(for selection: Selection, change: Change? = nil, widgetID: String? = nil,
                                 trip: String? = nil) async throws -> Date {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Problem.notAllowed }
        let now = Date.now
        var fullBoard: Board?
        var fromOwnLines = false
        var state: CountdownState?
        // A Transfers widget's board has its change's alerts too
        if let saved = SharedStore.loadBoard(for: selection, change: change), saved.fetched.isWithin(savedBoardAge, before: now) {
            state = CountdownState(for: selection, trains: saved.trains, notice: saved.notice?.label, now: now,
                                   following: trip, after: nil)
            // Stamped with the saved times' fetch time
            state?.updated = saved.fetched
        }
        if state == nil, let quick = try? await TrainService.board(for: selection, includingAlerts: false,
                                                                    includingOutages: false, includingOtherLines: false,
                                                                    now: now) {
            state = CountdownState(for: selection, board: quick, settings: SharedStore.loadSettings(), now: now,
                                   following: trip, after: nil)
            fromOwnLines = state != nil
        }
        if state == nil {
            // Own feed had none or failed; maybe a rerouted train
            let started = Date.now
            let board = try await fetchAll(for: selection, change: change)
            fullBoard = board
            state = CountdownState(for: selection, board: board, settings: SharedStore.loadSettings(), now: .now,
                                   following: trip, after: nil)
            // Stamped when the fetch began, like refreshes and the page
            state?.updated = started
        }
        guard let state else { throw Problem.noTrains }
        let ends = now.addingTimeInterval(CountdownState.lifetime)
        let attributes = TrainActivityAttributes(
            selection: selection,
            stationName: selection.station?.name ?? "",
            heading: selection.heading,
            ends: ends,
            change: change
        )
        // End the old one only after the new one starts, so if iOS refuses, nothing changes
        let activity: Activity<TrainActivityAttributes>
        do {
            activity = try Activity.request(attributes: attributes, content: content(state, ends: ends), pushType: .token)
        } catch {
            // Maybe only the push token (a build without push notifications); try without
            activity = try Activity.request(attributes: attributes, content: content(state, ends: ends))
        }
        await ActivityPush.watch(activity, started: now)
        await endActivities(except: activity.id)
        let countdown = SharedStore.Countdown(trainID: selection.trainID, ends: ends, widgetID: widgetID)
        // Save now, so a walk button can stop it even if iOS kills the app before the fetch below
        let old = record(countdown)
        share(activity)
        let train = fullBoard == nil
            ? await completeStart(activity, from: state, for: selection, change: change, trip: trip, fromOwnLines: fromOwnLines)
            : state.train
        // Only now, so they take the times it ends up with
        await reloadWidgets(from: old, to: countdown)
        return train
    }

    /// Once `activity` has started from `state` (from saved times or `selection`'s own lines'
    /// alone), fetches everything and updates it (see `startNow`). Returns its train.
    private static func completeStart(_ activity: Activity<TrainActivityAttributes>, from state: CountdownState,
                                      for selection: Selection, change: Change?, trip: String?,
                                      fromOwnLines: Bool) async -> Date {
        let started = Date.now
        guard let board = try? await fetchAll(for: selection, change: change) else { return state.train }
        let settings = SharedStore.loadSettings()
        let fetched = Date.now
        // The trip asked for (the own feed may have missed it: another line running on yours);
        // else the same train, or the next once it's gone
        let same = CountdownState(for: selection, board: board, settings: settings, now: fetched,
                                  following: trip ?? state.trip, after: state.train)
        // Or a sooner train the own feed missed (another line on yours); not for a change's trip
        let sooner = fromOwnLines && trip == nil
            ? CountdownState(for: selection, board: board, settings: settings, now: fetched, following: nil, after: nil)
            : nil
        guard var full = [same, sooner].compactMap({ $0 }).min(by: { $0.train < $1.train }) else { return state.train }
        full.updated = started
        await post(full, to: activity)
        return full.train
    }

    /// Updates `activity` to `state`, and saves it for widgets showing its train
    /// (`CountdownLookup`). Returns whether its trains changed, so those widgets should reload.
    @discardableResult
    private static func post(_ state: CountdownState, to activity: Activity<TrainActivityAttributes>) async -> Bool {
        let changed = !activity.content.state.hasSameTrains(as: state)
        await activity.update(content(state, ends: activity.attributes.ends))
        share(activity, state: state)
        return changed
    }

    /// Saves `activity`'s state (`state`, if just posted) and push token for widgets showing its
    /// train (`CountdownLookup`), which may not be able to read it from iOS. Again with each new
    /// push token.
    static func share(_ activity: Activity<TrainActivityAttributes>, state: CountdownState? = nil) {
        SharedStore.savePostedCountdown(SharedStore.PostedCountdown(
            trainID: activity.attributes.selection.trainID, state: state ?? activity.content.state,
            pushToken: activity.pushToken.map(CountdownLookup.hex)))
    }

    /// Fetches everything for `selection`'s countdown and saves it for the widgets. With a
    /// `change`, also its connections, saved for the Transfers widget showing it too (falling
    /// back to just the trains if the changed-to lines can't be had); its lines' alerts are added
    /// after saving (`withChangeAlerts`).
    private static func fetchAll(for selection: Selection, change: Change?) async throws -> Board {
        let settings = SharedStore.loadSettings()
        var withConnections: Board?
        if let change {
            withConnections = try? await TrainService.board(for: selection, change: change,
                                                            includingAlerts: selection.mentionsAlerts(with: settings),
                                                            includingOutages: selection.elevatorAlerts)
        }
        let board: Board
        if let withConnections {
            board = withConnections
        } else {
            board = try await fetchBoard(for: selection, settings: settings)
        }
        let fetched = Date.now
        // For Next train widgets: without the changed-to lines' alerts, which aren't theirs
        SharedStore.saveBoard(board.withoutChange, for: selection, fetched: fetched)
        if let change, withConnections != nil {
            SharedStore.saveBoard(board, for: selection, change: change, fetched: fetched)
        }
        return await withChangeAlerts(board, for: selection, change: change)
    }

    /// `board` with the alerts of `change`'s lines too (`Change.alertSelections(for:)`), for a
    /// Transfers widget's countdown, as the push server makes them. Not saved: the board saved for
    /// `selection` is the Next train widget's, which mentions only its own train's. Unchanged
    /// without a change, without alerts, or if they can't be had.
    private static func withChangeAlerts(_ board: Board, for selection: Selection, change: Change?,
                                         now: Date = .now) async -> Board {
        guard let change, let own = board.alerts else { return board }
        let changeTo = change.alertSelections(for: selection)
        guard let entries = await TrainService.alertEntries(routes: Set(changeTo.flatMap(\.routes))) else { return board }
        var board = board
        board.alerts = AlertsFeed.merged([own, AlertsFeed.alerts(for: changeTo, in: entries, now: now)])
        return board
    }

    /// `selection`'s trains plus only the alerts/outages its countdown can mention per Settings.
    private static func fetchBoard(for selection: Selection, settings: AppSettings, now: Date = .now) async throws -> Board {
        try await TrainService.board(for: selection, includingAlerts: selection.mentionsAlerts(with: settings),
                                     includingOutages: selection.elevatorAlerts, now: now)
    }

    // MARK: Walks

    /// How long a walk's countdown can run: the walk, the ride and the walk again, over an hour
    /// for the longest trips.
    static let walkLifetime: TimeInterval = 2 * 60 * 60

    /// Starts the countdown for New Trip's Go: to the first of `trains` (soonest first) that
    /// leaves once you're down, with `walk` over it. Not registered with the push server, whose
    /// countdowns have no walk; the app, following you, updates it (`updateWalk`). Replaces any
    /// running countdown.
    static func startWalk(for selection: Selection, trains: [Arrival], walk: WalkState) async throws {
        try await inTurn {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Problem.notAllowed }
            let now = Date.now
            var state = CountdownState(for: selection, trains: trains, notice: nil, now: now, following: nil, after: nil)
            if state == nil, let board = try? await fetchBoard(for: selection, settings: SharedStore.loadSettings(), now: now) {
                state = CountdownState(for: selection, board: board, settings: SharedStore.loadSettings(), now: now,
                                       following: nil, after: nil)
            }
            guard var state else { throw Problem.noTrains }
            state.walk = walk
            let ends = now.addingTimeInterval(walkLifetime)
            let attributes = TrainActivityAttributes(selection: selection, stationName: selection.station?.name ?? "",
                                                     heading: selection.heading, ends: ends)
            let activity = try Activity.request(attributes: attributes, content: content(state, ends: ends))
            await endActivities(except: activity.id)
            let countdown = SharedStore.Countdown(trainID: selection.trainID, ends: ends, widgetID: nil)
            let old = record(countdown)
            share(activity)
            await reloadWidgets(from: old, to: countdown)
        }
    }

    /// Puts up a walk with no train, walking all the way (`WalkSession.isWalkOnly`): its turns
    /// and when you'll get there, as walking out from a train. No station or line, so nothing for
    /// the widgets or the push server to follow; it's stale only once its time's up.
    static func startPlainWalk(_ walk: WalkState) async throws {
        try await inTurn {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Problem.notAllowed }
            let now = Date.now
            let ends = now.addingTimeInterval(walkLifetime)
            var state = CountdownState(train: ends, trip: "", isLive: false, terminal: nil, following: [],
                                       notice: nil, updated: now)
            state.walk = walk
            let attributes = TrainActivityAttributes(selection: Selection(stationID: "", routes: [], direction: .north),
                                                     stationName: "", heading: "", ends: ends)
            let activity = try Activity.request(attributes: attributes, content: content(state, ends: ends))
            await endActivities(except: activity.id)
            // Another countdown it took the place of is gone from the widgets
            await tellWidgets(nil)
        }
    }

    /// Updates the walk's countdown: `walk` over it, and the first of `trains` you can catch if
    /// given (soonest first, those you'd miss left out), else its train as it was. Nil `walk`
    /// makes it a plain countdown again.
    static func updateWalk(_ walk: WalkState?, trains: [Arrival]?) async {
        _ = try? await inTurn {
            for activity in running where activity.content.state.walk != nil {
                let selection = activity.attributes.selection
                var state = activity.content.state.movedOn(at: .now)
                if let trains, var fresh = CountdownState(for: selection, trains: trains, notice: state.notice, now: .now,
                                                          following: nil, after: nil) {
                    fresh.updated = .now
                    state = fresh
                }
                state.walk = walk
                guard state != activity.content.state else { continue }
                await post(state, to: activity)
            }
        }
    }

    /// Whether a walk's countdown is up: not swiped away, or ended for another countdown.
    static var isWalking: Bool {
        running.contains { $0.content.state.walk != nil }
    }

    /// Ends the walk's countdown, leaving any other.
    static func endWalk() async {
        _ = try? await inTurn {
            let walks = running.filter { $0.content.state.walk != nil }
            guard !walks.isEmpty else { return }
            for activity in walks {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            if running.isEmpty { await tellWidgets(nil) }
        }
    }

    /// A widget's walk button: stops the countdown if that widget shows it, else starts one
    /// (to `trip` if given, mentioning `change`'s alerts too; see `startNow`).
    static func toggle(for selection: Selection, change: Change? = nil, widgetID: String,
                       trip: String? = nil) async throws {
        try await inTurn {
            let shown = SharedStore.loadCountdown()?.isShown(onWidget: widgetID, for: selection.trainID) ?? false
            if shown && running.contains(where: { $0.attributes.selection.trainID == selection.trainID }) {
                await endActivities()
                await tellWidgets(nil)
            } else {
                _ = try await startNow(for: selection, change: change, widgetID: widgetID, trip: trip)
            }
        }
    }

    /// Updates `selection`'s running countdown from the page's `board` (fetch began at `fetched`)
    /// instead of fetching again. Skips countdowns with newer times (each is stamped with when
    /// its fetch began); stamps after now (clock set back) count as old. Returns the countdown's
    /// train, if one's running.
    static func update(for selection: Selection, from board: Board, fetched: Date) async -> Date? {
        let train = try? await inTurn { () async -> Date? in
            await endExpired()
            let settings = SharedStore.loadSettings()
            let now = Date.now
            var changed = false
            // Not a walk's, whose trains its walk keeps (it may be past this train, at a change)
            for activity in running where activity.attributes.selection.trainID == selection.trainID
                && activity.content.state.walk == nil
                && (activity.content.state.updated < fetched || activity.content.state.updated > now) {
                let board = await withChangeAlerts(board, for: activity.attributes.selection,
                                                   change: activity.attributes.change, now: fetched)
                let state = activity.content.state.refreshed(for: activity.attributes.selection, board: board,
                                                             settings: settings, now: fetched)
                changed = await post(state, to: activity) || changed
            }
            if changed { await WidgetCenter.shared.reloadWidgets(showing: selection.trainID) }
            return currentTrain(for: selection)
        }
        return train ?? nil
    }

    /// Fetches new times for every running countdown: same train while it's coming, else the
    /// next. With no trains it stays up, saying so, until stopped.
    static func refresh() async {
        _ = try? await inTurn { await refreshNow() }
        // A walk's, by its walk: the leg it's on, restored if iOS had closed the app
        await ActiveWalk.refreshFromLockScreen()
        // Another try at the server for any it doesn't have, without waiting for it
        Task { await ActivityPush.retry() }
    }

    private static func refreshNow() async {
        await endExpired()
        // May have ended unnoticed (swiped away)
        if running.isEmpty { await tellWidgets(nil) }
        var changed: Set<String> = []
        // Not a walk's: its walk refreshes it (`refresh()`)
        for activity in running where activity.content.state.walk == nil {
            let selection = activity.attributes.selection
            let settings = SharedStore.loadSettings()
            let now = Date.now
            guard let board = try? await fetchBoard(for: selection, settings: settings, now: now) else {
                // Keep its times, but apply any changed Settings marks
                await redraw(activity)
                continue
            }
            SharedStore.saveBoard(board, for: selection, fetched: .now)
            let full = await withChangeAlerts(board, for: selection, change: activity.attributes.change, now: now)
            let state = activity.content.state.refreshed(for: selection, board: full, settings: settings, now: now)
            if await post(state, to: activity) { changed.insert(selection.trainID) }
        }
        // Their widgets, to show the same
        for trainID in changed {
            await WidgetCenter.shared.reloadWidgets(showing: trainID)
        }
    }

    /// Redraws running countdowns with Settings' live/scheduled marks, keeping their times.
    static func redraw() async {
        _ = try? await inTurn {
            for activity in running { await redraw(activity) }
        }
    }

    /// Re-posts `activity`'s state if Settings' marks changed.
    private static func redraw(_ activity: Activity<TrainActivityAttributes>) async {
        let marked = content(activity.content.state, ends: activity.attributes.ends)
        guard marked.state != activity.content.state else { return }
        await activity.update(marked)
    }

    static func endAll() async {
        _ = try? await inTurn { await endAllNow() }
    }

    private static func endAllNow() async {
        await endActivities()
        await tellWidgets(nil)
    }

    /// Ends countdowns whose `CountdownState.lifetime` is up. The push server ends those it has
    /// at the same time; this is for the rest, whenever the app next runs.
    private static func endExpired() async {
        let now = Date.now
        let expired = running.filter { $0.attributes.ends.map { $0 <= now } ?? false }
        guard !expired.isEmpty else { return }
        for activity in expired {
            await ActivityPush.ended(activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        if running.isEmpty { await tellWidgets(nil) }
    }

    private static func endActivities(except kept: String? = nil) async {
        for activity in Activity<TrainActivityAttributes>.activities where activity.id != kept {
            await ActivityPush.ended(activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// `record`, then `reloadWidgets`.
    private static func tellWidgets(_ countdown: SharedStore.Countdown?) async {
        await reloadWidgets(from: record(countdown), to: countdown)
    }

    /// Saves the running countdown for widgets and walk buttons; returns the previous one. With
    /// none, also forgets its state saved for widgets.
    private static func record(_ countdown: SharedStore.Countdown?) -> SharedStore.Countdown? {
        let old = SharedStore.loadCountdown()
        if old != countdown { SharedStore.saveCountdown(countdown) }
        if countdown == nil { SharedStore.savePostedCountdown(nil) }
        return old
    }

    /// Reloads widgets when the countdown changes from `old` to `countdown`: every one showing
    /// either's train, as all of them take a running countdown's times (`CountdownSync`) and go
    /// back to their own once it's gone, not just one whose walk button shows it (which iOS
    /// reloads anyway when tapped). Transit Directions too, for its walk button, unless its own
    /// walk just started this one. Trains near you doesn't show it.
    private static func reloadWidgets(from old: SharedStore.Countdown?, to countdown: SharedStore.Countdown?) async {
        guard old != countdown else { return }
        for trainID in Set([old?.trainID, countdown?.trainID].compactMap { $0 }) {
            await WidgetCenter.shared.reloadWidgets(showing: trainID)
        }
        if countdown?.widgetID?.hasPrefix(WidgetKind.directions + " ") != true {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.directions)
        }
    }

    /// Stale when the train is due, so iOS redraws it then and it moves on to the next train
    /// (see `CountdownState.movedOn(at:)`), or when the countdown `ends` if that's sooner, so it
    /// says so. Carries Settings' marks so changing them redraws it.
    private static func content(_ state: CountdownState, ends: Date?) -> ActivityContent<CountdownState> {
        var state = state
        let settings = SharedStore.loadSettings()
        state.marksLiveTimes = settings.marksLiveTimes
        state.marksScheduledTimes = settings.marksScheduledTimes
        return ActivityContent(state: state, staleDate: min(state.staleDate, ends ?? .distantFuture))
    }
}
