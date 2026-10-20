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

    /// How old the times a widget saved can be for a countdown to start from them.
    private static let savedBoardAge: TimeInterval = 5 * 60

    /// Countdowns still running: not ones that have ended or been swiped away.
    private static var running: [Activity<TrainActivityAttributes>] {
        Activity<TrainActivityAttributes>.activities.filter { [.active, .stale].contains($0.activityState) }
    }

    /// The train the running countdown is for, if it's one of `selection`'s:
    /// as the Lock Screen shows it, moved on to the next once its own has gone.
    static func currentTrain(for selection: Selection) -> Date? {
        running.first { $0.attributes.selection.trainID == selection.trainID }?.content.state.movedOn(at: .now).train
    }

    /// The last of `start`, `toggle`, `refresh`, `redraw` and `endAll` asked
    /// for. They run one at a time: each waits on the network or on iOS, and
    /// two at once (a double tap) could leave two countdowns running, or have
    /// a toggle start one rather than stop it.
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
    /// `trip` is the train to count down to, while it's still coming: on the
    /// Transfers widget, the next that gets to the change, which needn't be
    /// the next at your station; nil for the first you can catch.
    ///
    /// It starts as soon as it has a train to count down to: from the times a
    /// widget saved for this train in the last few minutes, or else from the
    /// chosen lines' own feed alone. Then it fetches everything, the alert and
    /// rerouted trains too, and updates the countdown with them. The widgets
    /// reload after that, so any that redraw for it find those times saved
    /// rather than fetching them too.
    private static func startNow(for selection: Selection, widgetID: String? = nil, trip: String? = nil) async throws -> Date {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Problem.notAllowed }
        let now = Date.now
        var fullBoard: Board?
        var fromOwnLines = false
        var state: CountdownState?
        if let saved = SharedStore.loadBoard(for: selection), saved.fetched.isWithin(savedBoardAge, before: now) {
            state = CountdownState(for: selection, trains: saved.trains, notice: saved.notice?.label, now: now,
                                   following: trip, after: nil)
            // Updated when they were
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
            // None on the chosen lines' own feed, or it failed: maybe a rerouted train
            let board = try await fetchAll(for: selection)
            fullBoard = board
            state = CountdownState(for: selection, board: board, settings: SharedStore.loadSettings(), now: .now,
                                   following: trip, after: nil)
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
        let countdown = SharedStore.Countdown(trainID: selection.trainID, ends: now.addingTimeInterval(CountdownState.lifetime),
                                              widgetID: widgetID)
        // Saved at once, so a walk button stops it even should iOS end the
        // app before the times below come in
        let old = record(countdown)
        // It's up; now the alert and any rerouted trains, for the same train
        guard fullBoard == nil, let board = try? await fetchAll(for: selection) else {
            reloadWidgets(from: old, to: countdown, tapped: widgetID)
            return state.train
        }
        reloadWidgets(from: old, to: countdown, tapped: widgetID)
        let settings = SharedStore.loadSettings()
        let fetched = Date.now
        // To the trip asked for, should the chosen lines' own feed have missed
        // it (another line's, running on yours); else the same train, or once
        // that has gone, the next
        let same = CountdownState(for: selection, board: board, settings: settings, now: fetched,
                                  following: trip ?? state.trip, after: state.train)
        // Unless the chosen lines' own feed missed a sooner one, of another line
        // running on yours; not when it's for a train that gets to a change
        let sooner = fromOwnLines && trip == nil
            ? CountdownState(for: selection, board: board, settings: settings, now: fetched, following: nil, after: nil)
            : nil
        guard let full = [same, sooner].compactMap({ $0 }).min(by: { $0.train < $1.train }) else { return state.train }
        await activity.update(content(full))
        return full.train
    }

    /// Everything for `selection`'s countdown, saved for the widgets to redraw
    /// with rather than fetching it again.
    private static func fetchAll(for selection: Selection) async throws -> Board {
        let board = try await fetchBoard(for: selection, settings: SharedStore.loadSettings())
        SharedStore.saveBoard(board, for: selection, fetched: .now)
        return board
    }

    /// `selection`'s trains, and only the alerts and outages its countdown can
    /// mention, as Settings has them.
    private static func fetchBoard(for selection: Selection, settings: AppSettings, now: Date = .now) async throws -> Board {
        try await TrainService.board(for: selection, includingAlerts: selection.mentionsAlerts(with: settings),
                                     includingOutages: selection.elevatorAlerts, now: now)
    }

    /// A widget's walk button (`widgetID` is that widget's): stops the
    /// countdown if the widget shows it, otherwise starts one for it, to
    /// `trip` where the widget gives one (see `startNow`).
    static func toggle(for selection: Selection, widgetID: String, trip: String? = nil) async throws {
        try await inTurn {
            let shown = SharedStore.loadCountdown()?.isShown(onWidget: widgetID, for: selection.trainID) ?? false
            if shown && running.contains(where: { $0.attributes.selection.trainID == selection.trainID }) {
                await endActivities()
                tellWidgets(nil, tapped: widgetID)
            } else {
                _ = try await startNow(for: selection, widgetID: widgetID, trip: trip)
            }
        }
    }

    /// New times for `selection`'s running countdown from `board`, which the
    /// app fetched at `fetched` for the train's own page, rather than fetching
    /// them again. Returns the train it counts down to then, if one's running.
    static func update(for selection: Selection, from board: Board, fetched: Date) async -> Date? {
        let train = try? await inTurn { () async -> Date? in
            let settings = SharedStore.loadSettings()
            for activity in running where activity.attributes.selection.trainID == selection.trainID {
                let state = activity.content.state.refreshed(for: activity.attributes.selection, board: board,
                                                             settings: settings, now: fetched)
                await activity.update(content(state))
            }
            return currentTrain(for: selection)
        }
        return train ?? nil
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
            let settings = SharedStore.loadSettings()
            let now = Date.now
            guard let board = try? await fetchBoard(for: selection, settings: settings, now: now) else {
                // Its times stay as they were, but not its marks, should Settings have changed them
                await redraw(activity)
                continue
            }
            SharedStore.saveBoard(board, for: selection, fetched: .now)
            let state = activity.content.state.refreshed(for: selection, board: board, settings: settings, now: now)
            await activity.update(content(state))
        }
    }

    /// Redraws every running countdown with Settings' marks for live and
    /// scheduled times, keeping its times.
    static func redraw() async {
        _ = try? await inTurn {
            for activity in running { await redraw(activity) }
        }
    }

    /// Posts `activity`'s state again if Settings' marks have changed since.
    private static func redraw(_ activity: Activity<TrainActivityAttributes>) async {
        let marked = content(activity.content.state)
        guard marked.state != activity.content.state else { return }
        await activity.update(marked)
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

    /// Lets the widgets know whose countdown is running: `record`, then
    /// `reloadWidgets`.
    private static func tellWidgets(_ countdown: SharedStore.Countdown?, tapped: String? = nil) {
        reloadWidgets(from: record(countdown), to: countdown, tapped: tapped)
    }

    /// Saves whose countdown is running, for the widgets and their walk
    /// buttons, and returns whose was before.
    private static func record(_ countdown: SharedStore.Countdown?) -> SharedStore.Countdown? {
        let old = SharedStore.loadCountdown()
        if old != countdown { SharedStore.saveCountdown(countdown) }
        return old
    }

    /// Reloads the widgets for a countdown that was `old` and is now
    /// `countdown`. After a tap on a widget's (`tapped`), iOS reloads that
    /// widget, so the others reload only if one of them showed the countdown
    /// before or does now. Trains near you doesn't show it.
    private static func reloadWidgets(from old: SharedStore.Countdown?, to countdown: SharedStore.Countdown?,
                                      tapped: String?) {
        guard old != countdown else { return }
        let onlyTapped = { (countdown: SharedStore.Countdown?) in
            countdown.map { $0.widgetID != nil && $0.widgetID == tapped } ?? true
        }
        if !(onlyTapped(old) && onlyTapped(countdown)) {
            WidgetCenter.shared.reloadTrainWidgets()
        }
    }

    /// Out of date as the train is due, so iOS redraws the countdown then, and
    /// it moves on to the next train it has; see `CountdownState.movedOn(at:)`.
    /// It carries Settings' marks for live and scheduled times, so that
    /// changing them redraws it.
    private static func content(_ state: CountdownState) -> ActivityContent<CountdownState> {
        var state = state
        let settings = SharedStore.loadSettings()
        state.marksLiveTimes = settings.marksLiveTimes
        state.marksScheduledTimes = settings.marksScheduledTimes
        return ActivityContent(state: state, staleDate: state.staleDate)
    }
}
