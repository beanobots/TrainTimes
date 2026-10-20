import Foundation
import ServiceLifecycle

/// Every so often, new times for every registered countdown, pushed when
/// they're worth it. One pass at a time: one that overruns skips ticks.
final class Poller: Service {
    typealias BoardSource = @Sendable ([Selection], Date) async -> [Selection: Board]

    private let store: Store
    private let pusher: any Pusher
    private let interval: TimeInterval
    private let concurrency: Int
    private let keyRetention: TimeInterval
    private let logPushes: Bool
    private let boards: BoardSource

    init(store: Store, pusher: any Pusher, interval: TimeInterval, concurrency: Int = 100,
         keyRetention: TimeInterval = Limits().keyRetention, logPushes: Bool = false,
         boards: @escaping BoardSource = Poller.liveBoards) {
        self.store = store
        self.pusher = pusher
        self.interval = interval
        self.concurrency = concurrency
        self.keyRetention = keyRetention
        self.logPushes = logPushes
        self.boards = boards
    }

    func run() async throws {
        let clock = ContinuousClock()
        var lastPurge = Date.distantPast
        while !Task.isCancelled && !Task.isShuttingDownGracefully {
            let start = clock.now
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
            do {
                try await cancelWhenGracefulShutdown { try await Task.sleep(for: .seconds(delay)) }
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

        /// The pass's line in the log.
        var description: String {
            "\(registrations) countdowns, \(updates) updates, \(refreshes) refreshes, \(ended) ended, "
                + "\(dropped) dropped, \(failed) failed, \(withoutFeeds) without feeds"
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
        var stats = Stats(registrations: all.count)
        defer { Log.info("pass: \(stats)") }
        guard !all.isEmpty else { return stats }

        var jobs: [Job] = []
        var active: [Registration] = []
        for registration in all {
            if now >= registration.ends {
                // iOS ends a countdown after 8 hours; this ends it on the phone too, then forgets it
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

        if !active.isEmpty {
            let boards = await boards(active.map(\.selection), now)
            var trainsWithoutFeeds = Set<String>()
            for registration in active {
                // Without the MTA's feeds, the countdown keeps what it last had
                guard let board = boards[registration.selection] else {
                    stats.withoutFeeds += 1
                    trainsWithoutFeeds.insert(registration.selection.trainID)
                    continue
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
                let decision = ActivityState.push(state, last: registration.lastState,
                                                  lastPush: registration.lastPush, now: now)
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
        guard !jobs.isEmpty else { return stats }

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
                        Log.error("end \(registration.tokenPrefix) failed: \(reason)")
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
                    Log.error("push \(registration.tokenPrefix) failed: \(reason)")
                }
            case (_, nil):
                break
            }
        }
        if stats.failed > errorLines { Log.error("… and \(stats.failed - errorLines) more failed pushes") }
        do {
            try await store.apply(outcomes)
        } catch {
            Log.error("couldn't save the pass: \(error)")
        }
        return stats
    }

    // MARK: - The MTA's feeds

    /// A board for each of `selections`, as `TrainService.board(for:includingOutages:now:)`
    /// makes the app's countdown's (outages only for those that mention
    /// elevators), with the trains from `TrainService.trains(for:)`, which
    /// fetches and reads each feed once for all of them. One whose own lines'
    /// feeds didn't come, or are out of date, is left out.
    @Sendable
    static func liveBoards(for selections: [Selection], now: Date) async -> [Selection: Board] {
        // Read afresh each pass, not as the app reuses them for 30 seconds
        async let alertEntries = TrainService.alertEntries(reusingFor: 0)
        async let outageData = selections.contains(where: \.elevatorAlerts)
            ? TrainService.optionalData(from: OutagesFeed.url) : nil
        let trains = await TrainService.trains(for: selections, now: now)
        let (entries, outagesFeed) = await (alertEntries, outageData)
        return boards(for: selections, trains: trains, alerts: entries, outages: outagesFeed, now: now)
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
