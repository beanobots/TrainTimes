import Foundation
import ServiceLifecycle
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    struct Stats: Equatable, Sendable {
        var registrations = 0
        var updates = 0
        var refreshes = 0
        var ended = 0
        var dropped = 0
        var failed = 0
        var withoutFeeds = 0
    }

    private struct Job: Sendable {
        enum Kind: Sendable { case update, refresh, end }
        var kind: Kind
        var registration: Registration
        /// Nil for an end with nothing ever pushed: there's nothing to end on the phone.
        var push: Push?
    }

    /// One round: ends countdowns that iOS would have ended, fetches each feed
    /// once for all the rest, and pushes to those that changed, `concurrency`
    /// at a time. What happened is saved in one transaction.
    @discardableResult
    func pass(at now: Date) async -> Stats {
        let all = await store.all
        var stats = Stats(registrations: all.count)
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
                let state: ContentState
                if let new = ActivityState.state(for: registration.selection, board: board, now: now,
                                                 following: registration.lastState?.trip ?? registration.trip,
                                                 settings: registration.settings) {
                    state = new
                } else if let last = registration.lastState {
                    state = ActivityState.noTrains(from: last, now: now)
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
                if case .failed(let reason) = result, errorLines < 10 {
                    errorLines += 1
                    Log.error("end \(registration.tokenPrefix) failed: \(reason)")
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
        Log.info("pass: \(stats.registrations) countdowns, \(stats.updates) updates, \(stats.refreshes) refreshes, "
            + "\(stats.ended) ended, \(stats.dropped) dropped, \(stats.failed) failed")
        return stats
    }

    // MARK: - The MTA's feeds

    /// A board for each of `selections`, as `TrainService.board(for:includingOutages:now:)`
    /// makes the app's countdown's (outages only for those that mention
    /// elevators). Each feed is fetched and read once for all of them, as
    /// `TrainService.trains(for:)` does, but its arrivals are indexed by stop,
    /// so each selection looks only at its own: linear in the number of them.
    /// One whose own lines' feeds didn't come is left out.
    @Sendable
    static func liveBoards(for selections: [Selection], now: Date) async -> [Selection: Board] {
        let unique = Array(Set(selections))
        let feeds = unique.map { Lines.feedURLs(sharingTracksWith: $0.routes) }
        let urls = Set(feeds.flatMap { $0.own + $0.others })
        let stops = Set(unique.flatMap(\.stopIDs))

        async let alertEntries = TrainService.alertEntries()
        async let outageData = unique.contains(where: \.elevatorAlerts) ? fetch(OutagesFeed.url) : nil
        let arrivals = await withTaskGroup(of: (URL, [String: [Arrival]]?).self) { group in
            for url in urls {
                group.addTask {
                    guard let data = await fetch(url), let arrivals = try? SubwayFeed.arrivals(at: stops, in: data) else {
                        return (url, nil)
                    }
                    return (url, Dictionary(grouping: arrivals, by: \.stop))
                }
            }
            var all: [URL: [String: [Arrival]]] = [:]
            for await (url, byStop) in group {
                all[url] = byStop
            }
            return all
        }
        let (entries, outagesFeed) = await (alertEntries, outageData)

        var outagesByComplex: [String: [Outage]?] = [:]
        var boards: [Selection: Board] = [:]
        for (selection, feeds) in zip(unique, feeds) where feeds.own.allSatisfy({ arrivals[$0] != nil }) {
            // Mirrors TrainService.trains(for:): own and other lines' feeds, these stops, soonest first, once per trip
            let stopIDs = selection.stopIDs
            let trains = (feeds.own + feeds.others)
                .flatMap { url in stopIDs.flatMap { arrivals[url]?[$0] ?? [] } }
                .filter { $0.time > now && selection.shows($0) }
                .sorted { $0.time < $1.time }
                .oncePerTrip()
            var outages: [Outage]? = nil
            if selection.elevatorAlerts {
                let complex = selection.station?.complex ?? ""
                if let cached = outagesByComplex[complex] {
                    outages = cached
                } else {
                    outages = Self.outages(for: selection, in: outagesFeed)
                    outagesByComplex[complex] = outages
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

    /// Mirrors the private `TrainService.outages(for:if:)`: nil when the feed
    /// couldn't be had or read.
    private static func outages(for selection: Selection, in data: Data?) -> [Outage]? {
        guard let complex = selection.station?.complex else { return [] }
        guard let data else { return nil }
        return try? OutagesFeed.outages(atComplex: complex, in: data)
    }

    /// As the private `TrainService.data(from:)` fetches.
    private static func fetch(_ url: URL) async -> Data? {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

private extension [Arrival] {
    /// Mirrors the private `oncePerTrip()` in TrainService.swift.
    func oncePerTrip() -> [Arrival] {
        var seen = Set<String>()
        return filter { $0.trip.isEmpty || seen.insert($0.trip).inserted }
    }
}
