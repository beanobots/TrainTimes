import Foundation
import ServiceLifecycle

/// Every so often, new times for every registered countdown, pushed when
/// they're worth it. One pass at a time: one that overruns skips ticks.
final class Poller: Service {
    typealias BoardSource = @Sendable ([Selection], Date) async -> [Selection: Board]

    private let store: Store
    private let pusher: any Pusher
    private let interval: TimeInterval
    private let timing: PushTiming
    private let concurrency: Int
    private let keyRetention: TimeInterval
    private let logPushes: Bool
    private let boards: BoardSource
    /// Read at the start of each tick, before the pass, which makes its boards from it.
    private let feeds: FeedRelay?

    init(store: Store, pusher: any Pusher, interval: TimeInterval, timing: PushTiming = PushTiming(), concurrency: Int = 100,
         keyRetention: TimeInterval = Limits().keyRetention, logPushes: Bool = false, feeds: FeedRelay? = nil,
         boards: @escaping BoardSource) {
        self.store = store
        self.pusher = pusher
        self.interval = interval
        self.timing = timing
        self.concurrency = concurrency
        self.keyRetention = keyRetention
        self.logPushes = logPushes
        self.feeds = feeds
        self.boards = boards
    }

    func run() async throws {
        let clock = ContinuousClock()
        var lastPurge = Date.distantPast
        while !Task.isCancelled && !Task.isShuttingDownGracefully {
            let start = clock.now
            // Every tick, countdowns or not: the app and widgets read them too
            await feeds?.refresh()
            await pass(at: .now)
            if Date.now.timeIntervalSince(lastPurge) >= 60 * 60 {
                await purge(now: .now)
                lastPurge = .now
            }
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let (delay, skipped) = Self.schedule(elapsed: seconds, interval: interval)
            if skipped > 0 {
                Log.error("pass took \(String(format: "%.1f", seconds)) s, over POLL_SECONDS: skipping \(skipped) tick\(skipped == 1 ? "" : "s")")
            }
            // Until the next tick, moving countdowns on to their next train as each is due
            let nextPass = Date.now.addingTimeInterval(delay)
            do {
                while true {
                    let wake = await nextDue(after: .now).map { min($0, nextPass) } ?? nextPass
                    try await cancelWhenGracefulShutdown {
                        try await Task.sleep(for: .seconds(max(0, wake.timeIntervalSinceNow)))
                    }
                    guard wake < nextPass else { break }
                    await pushDue(at: wake)
                }
            } catch {
                break
            }
        }
    }

    /// How long to wait after a pass that took `elapsed`, to start the next on
    /// the next tick not yet begun, and how many ticks it overran.
    static func schedule(elapsed: TimeInterval, interval: TimeInterval) -> (delay: TimeInterval, skipped: Int) {
        guard elapsed >= interval else { return (interval - elapsed, 0) }
        let skipped = Int((elapsed / interval).rounded(.down))
        return (Double(skipped + 1) * interval - elapsed, skipped)
    }

    /// Keys unused for 90 days, and what they registered.
    func purge(now: Date) async {
        do {
            let purged = try await store.purgeKeys(unusedSince: now.addingTimeInterval(-keyRetention))
            if purged > 0 { Log.info("purged \(purged) attest keys unused for \(Int(keyRetention / 86400)) days") }
        } catch {
            Log.error("purging keys: \(error)")
        }
    }

    struct Stats: Equatable, Sendable, CustomStringConvertible {
        var registrations = 0
        var updates = 0
        var refreshes = 0
        var ended = 0
        var dropped = 0
        /// Pushes that failed: updates and refreshes, tried again next pass, and ends.
        var failed = 0
        var withoutFeeds = 0
        /// Phones told to reload their widgets, as their countdown's times changed.
        var widgetReloads = 0
        /// Attest keys known as the pass began, for the log; nil if they couldn't be counted.
        var keys: Int?

        /// The pass's line in the log, which the admin app reads (by name, so new counts are
        /// safe to add).
        var description: String {
            "\(registrations) countdowns, \(updates) updates, \(refreshes) refreshes, \(ended) ended, "
                + "\(dropped) dropped, \(failed) failed, \(withoutFeeds) without feeds, \(widgetReloads) widget reloads"
                + (keys.map { ", \($0) attest keys" } ?? "")
        }
    }

    private struct Job: Sendable {
        enum Kind: Sendable { case update, refresh, end }
        var kind: Kind
        var registration: Registration
        /// Nil for an end with no state, pushed or sent by the app: nothing to end it with.
        var push: Push?
    }

    /// One round: ends countdowns that iOS would have ended, fetches each feed
    /// once for all the rest, and pushes to those that changed, `concurrency`
    /// at a time. What happened is saved in one transaction, and its totals
    /// logged, even when there was nothing to do.
    @discardableResult
    func pass(at now: Date) async -> Stats {
        let all = await store.all
        var stats = Stats(registrations: all.count, keys: try? await store.keyCount())
        defer { Log.info("pass: \(stats)") }
        guard !all.isEmpty else { return stats }

        var jobs: [Job] = []
        var active: [Registration] = []
        for registration in all {
            if now >= registration.ends {
                // Its 30 minutes are up (`CountdownState.lifetime`): ends it on the phone, then forgets it
                let push = registration.lastState.map { last -> Push in
                    var state = last
                    state.updated = now
                    return Push(token: registration.token, environment: registration.environment, event: .end,
                                state: state, priority: 10, timestamp: now, dismissalDate: now)
                }
                jobs.append(Job(kind: .end, registration: registration, push: push))
            } else {
                active.append(registration)
            }
        }

        // Each countdown's trains after its following ones, for pushes as trains are due
        var later: [(token: String, revision: UUID, trains: [Arrival])] = []
        if !active.isEmpty {
            // Transfers' changed-to trains too, for their alerts
            let boards = await boards(active.flatMap { [$0.selection] + $0.changeSelections }, now)
            var trainsWithoutFeeds = Set<String>()
            for registration in active {
                // Without the MTA's feeds, the countdown keeps what it last had
                guard var board = boards[registration.selection] else {
                    stats.withoutFeeds += 1
                    trainsWithoutFeeds.insert(registration.selection.trainID)
                    continue
                }
                // A Transfers widget's countdown mentions its changed-to lines' alerts too, as
                // the widget does; any whose feeds didn't come are left out
                if let own = board.alerts, !registration.changeSelections.isEmpty {
                    board.alerts = AlertsFeed.merged([own] + registration.changeSelections.compactMap { boards[$0]?.alerts })
                }
                // As the app refreshes it (Shared/Countdown.swift)
                let state: ContentState
                if let last = registration.lastState {
                    let refreshed = last.refreshed(for: registration.selection, board: board,
                                                   settings: registration.settings, now: now)
                    state = ActivityState.keepingNotice(of: last, in: refreshed, board: board,
                                                        selection: registration.selection, now: now)
                } else if let new = ContentState(for: registration.selection, board: board, settings: registration.settings,
                                                 now: now, following: registration.trip, after: nil) {
                    state = new
                } else {
                    // Nothing pushed yet, and nothing to push: the app's own state stands
                    continue
                }
                let trains = Self.later(after: state, in: board, now: now)
                if trains != registration.later {
                    later.append((registration.token, registration.revision, trains))
                }
                let decision = ActivityState.push(state, last: registration.lastState,
                                                  lastPush: registration.lastPush, now: now, timing: timing)
                guard decision != .none else { continue }
                let push = Push(token: registration.token, environment: registration.environment, event: .update,
                                state: state, priority: decision == .update ? 10 : 5, timestamp: now,
                                staleDate: ActivityState.staleDate(for: state))
                jobs.append(Job(kind: decision == .update ? .update : .refresh, registration: registration, push: push))
            }
            if !trainsWithoutFeeds.isEmpty {
                Log.error("no feeds for \(trainsWithoutFeeds.count) trains (\(stats.withoutFeeds) countdowns): keeping their last state")
            }
        }
        if !later.isEmpty { await store.keepLater(later) }
        guard !jobs.isEmpty else { return stats }
        await send(jobs, now: now, stats: &stats)
        return stats
    }

    /// Sends `jobs`' pushes, `concurrency` at a time, and saves what happened in one
    /// transaction, counting it in `stats`.
    private func send(_ jobs: [Job], now: Date, stats: inout Stats) async {
        let pusher = pusher
        let results = await Concurrency.map(jobs, limit: concurrency) { job -> (Job, PushResult?) in
            guard let push = job.push else { return (job, nil) }
            return (job, await pusher.send(push))
        }

        var outcomes: [PushOutcome] = []
        var errorLines = 0
        for (job, result) in results {
            let registration = job.registration
            switch (job.kind, result) {
            case (.end, let result):
                if case .failed(let reason) = result {
                    stats.failed += 1
                    if errorLines < 10 {
                        errorLines += 1
                        Log.error("end \(registration.tokenPrefix) (\(registration.environment.rawValue)) failed: \(reason)")
                    }
                }
                stats.ended += 1
                outcomes.append(.drop(token: registration.token, revision: registration.revision))
            case (_, .sent?):
                if job.kind == .update { stats.updates += 1 } else { stats.refreshes += 1 }
                if logPushes, let push = job.push {
                    Log.info("push \(registration.tokenPrefix) p\(push.priority) train \(Log.relative(push.state.train, to: now))"
                        + " (\(push.state.route ?? "?"))" + (push.state.notice.map { " notice \"\($0)\"" } ?? ""))
                }
                if let push = job.push {
                    outcomes.append(.pushed(token: registration.token, revision: registration.revision,
                                            state: push.state, at: now))
                }
            case (_, .invalidToken(let reason)?):
                stats.dropped += 1
                Log.info("drop \(registration.tokenPrefix): APNs \(reason)")
                outcomes.append(.drop(token: registration.token, revision: registration.revision))
            case (_, .failed(let reason)?):
                stats.failed += 1
                if errorLines < 10 {
                    errorLines += 1
                    Log.error("push \(registration.tokenPrefix) (\(registration.environment.rawValue)) failed: \(reason)")
                }
            case (_, nil):
                break
            }
        }
        if stats.failed > errorLines { Log.error("… and \(stats.failed - errorLines) more failed pushes") }
        outcomes += await reloadWidgets(after: results, stats: &stats)
        do {
            try await store.apply(outcomes)
        } catch {
            Log.error("couldn't save the pass: \(error)")
        }
    }

    /// After `results`' pushes, tells each phone whose countdown now has other times to reload
    /// its widgets, which then show them (each phone once, though it may have several
    /// registrations). Only once the countdown's push is sent, so the widgets find its new state.
    /// Returns the registrations whose widget push token APNs no longer knows.
    private func reloadWidgets(after results: [(Job, PushResult?)], stats: inout Stats) async -> [PushOutcome] {
        var phones: [String: (environment: PushEnvironment, registrations: [Registration])] = [:]
        for (job, result) in results {
            guard job.kind != .end, result == .sent, let push = job.push, let widgetToken = job.registration.widgetToken,
                  ActivityState.changesWidgets(push.state, from: job.registration.lastState) else { continue }
            phones[widgetToken, default: (job.registration.environment, [])].registrations.append(job.registration)
        }
        guard !phones.isEmpty else { return [] }
        let pusher = pusher
        let sent = await Concurrency.map(Array(phones), limit: concurrency) { token, phone in
            (phone.registrations, await pusher.sendWidgetReload(token: token, environment: phone.environment))
        }
        var outcomes: [PushOutcome] = []
        for (registrations, result) in sent {
            switch result {
            case .sent:
                stats.widgetReloads += 1
            case .invalidToken(let reason):
                Log.info("forget widget token of \(registrations[0].tokenPrefix): APNs \(reason)")
                outcomes += registrations.map { .dropWidgetToken(token: $0.token, revision: $0.revision) }
            case .failed(let reason):
                // Its widgets catch up when they next reload
                Log.error("widget reload for \(registrations[0].tokenPrefix) failed: \(reason)")
            }
        }
        return outcomes
    }

    // MARK: - Trains due between passes

    /// When the soonest countdown's train is due after `now`, if it has a next train to move on
    /// to: when `pushDue(at:)` should push it, rather than leave it at 0:00 until the next pass.
    func nextDue(after now: Date) async -> Date? {
        await store.all.compactMap { registration -> Date? in
            guard let train = registration.lastState?.train, train > now,
                  Self.movedOn(registration, at: train) != nil else { return nil }
            return train
        }.min()
    }

    /// Pushes each countdown whose train is due at `now` on to its next train, so it counts down
    /// to that from 0:00, out of date in turn as that's due (`CountdownState.movedOn(at:)`, as the
    /// Lock Screen draws it), with as many trains after it as before. Without reading the feeds,
    /// it's the next train as the last push had it, then the last pass's later ones; the next
    /// pass brings its trip and new times. Logged only when there were any.
    @discardableResult
    func pushDue(at now: Date) async -> Stats {
        let jobs = await store.all.compactMap { registration -> Job? in
            guard let state = Self.movedOn(registration, at: now) else { return nil }
            let push = Push(token: registration.token, environment: registration.environment, event: .update,
                            state: state, priority: 10, timestamp: now, staleDate: ActivityState.staleDate(for: state))
            return Job(kind: .update, registration: registration, push: push)
        }
        var stats = Stats(registrations: jobs.count)
        guard !jobs.isEmpty else { return stats }
        await send(jobs, now: now, stats: &stats)
        Log.info("due: \(stats.updates) moved on, \(stats.dropped) dropped, \(stats.failed) failed")
        return stats
    }

    /// `registration`'s last state moved on to the next train once its own is due at `now`; nil
    /// if it isn't due yet, there's no next train, or the countdown has ended.
    static func movedOn(_ registration: Registration, at now: Date) -> ContentState? {
        guard now < registration.ends, let last = registration.lastState else { return nil }
        var moved = last.movedOn(at: now)
        guard moved != last else { return nil }
        // Back to as many trains after it as it had, from the last pass's later ones
        let after = moved.following.last ?? moved.train
        let added = registration.later.filter { $0.time > after }
            .prefix(max(0, last.following.count - moved.following.count))
        moved.following += added.map(\.time)
        moved.followingRoutes = moved.followingRoutes.map { $0 + added.map(\.route) }
        return moved
    }

    /// How many trains after `state`'s following ones to keep: enough to fill them again
    /// should a few come due before the next pass.
    static let laterCount = 3

    /// The first `laterCount` of `board`'s trains after `state`'s following ones, still to come
    /// at `now`. None when it has none following, as then there are no more.
    static func later(after state: ContentState, in board: Board, now: Date) -> [Arrival] {
        guard let last = state.following.last else { return [] }
        return Array(board.trains.filter { $0.time > last && $0.time > now }
            .sorted { $0.time < $1.time }.prefix(laterCount))
    }

    // MARK: - The MTA's feeds

    /// A board for each of `selections`, as `TrainService.board(for:includingOutages:now:)`
    /// makes the app's countdown's (outages only for those that mention
    /// elevators), from the feeds as `feeds` last read them this tick, each
    /// decoded once for all of them. One whose own lines' feeds didn't come,
    /// or are out of date, is left out.
    static func liveBoards(from feeds: FeedRelay) -> BoardSource {
        { selections, now in
            let copies = await feeds.current(now: now)
            // Each train once, and only the feeds they need decoded
            let unique = Array(Dictionary(selections.map { ($0.trainID, $0) }, uniquingKeysWith: { first, _ in first }).values)
            let needed = Set(unique.flatMap { (selection: Selection) -> [URL] in
                let urls = TrainService.feedURLs(for: selection, includingOtherLines: true)
                return urls.own + urls.others
            })
            let arrivals = TrainService.arrivals(at: Set(unique.flatMap(\.stopIDs)),
                                                 in: copies.filter { needed.contains($0.key) }, now: now)
            let trains = TrainService.trains(for: unique, in: arrivals, now: now)
            let entries = copies[AlertsFeed.url].flatMap { try? AlertsFeed.entries(in: $0, now: now) }
            return boards(for: selections, trains: trains, alerts: entries, outages: copies[OutagesFeed.url], now: now)
        }
    }

    /// `liveBoards(for:now:)` once the feeds are read: `trains` has each
    /// selection's by `Selection.trainID`, and none for one whose own lines'
    /// feeds didn't come; `alerts` and `outages` are those feeds as read, nil
    /// when they couldn't be had.
    static func boards(for selections: [Selection], trains: [String: [Arrival]], alerts entries: [AlertsFeed.Entry]?,
                       outages outagesFeed: Data?, now: Date) -> [Selection: Board] {
        let entries = entries.map(AlertsFeed.prepared)
        var outagesByPlatforms: [[String]: [Outage]?] = [:]
        var boards: [Selection: Board] = [:]
        for selection in Set(selections) {
            guard let trains = trains[selection.trainID] else { continue }
            var outages: [Outage]? = nil
            if selection.elevatorAlerts {
                let platforms = selection.platforms.map(\.id)
                if let cached = outagesByPlatforms[platforms] {
                    outages = cached
                } else {
                    outages = TrainService.outages(for: selection, in: outagesFeed)
                    outagesByPlatforms[platforms] = outages
                }
            }
            boards[selection] = Board(
                trains: trains,
                alerts: entries.map { AlertsFeed.alerts(for: selection, in: $0, now: now) },
                outages: outages
            )
        }
        return boards
    }
}
