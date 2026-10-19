import Foundation
import Testing
@testable import TrainCore

/// Records pushes rather than sending them, and how many were in flight at once.
final class FakePusher: Pusher, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Push] = []
    private var inFlight = 0
    private var peak = 0
    let result: PushResult
    let delay: Duration?

    init(result: PushResult = .sent, delay: Duration? = nil) {
        self.result = result
        self.delay = delay
    }

    func send(_ push: Push) async -> PushResult {
        lock.withLock {
            sent.append(push)
            inFlight += 1
            peak = max(peak, inFlight)
        }
        if let delay { try? await Task.sleep(for: delay) }
        lock.withLock { inFlight -= 1 }
        return result
    }

    func shutdown() async {}
    var pushes: [Push] { lock.withLock { sent } }
    var maxInFlight: Int { lock.withLock { peak } }
}

func testRegistration(token: String = sampleToken, owner: String = "key", started: Date = now) -> Registration {
    Registration(token: token, owner: owner, environment: .production, selection: prospect,
                 trip: "b", started: started, alertKinds: nil, revision: UUID())
}

@Suite struct PollerTests {
    func registered(_ store: Store, started: Date = now) async throws {
        _ = try await store.upsert(testRegistration(started: started), maxTotal: 10, maxPerOwner: 5)
    }

    func poller(_ store: Store, _ pusher: FakePusher, board: Board? = fixtureBoard(), concurrency: Int = 100) -> Poller {
        Poller(store: store, pusher: pusher, interval: 30, concurrency: concurrency) { selections, _ in
            board.map { board in Dictionary(selections.map { ($0, board) }, uniquingKeysWith: { a, _ in a }) } ?? [:]
        }
    }

    @Test func pushesFirstThenOnlyWhenWorthIt() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let pusher = FakePusher()
        let poller = poller(store, pusher)

        let stats = await poller.pass(at: now)
        #expect(stats.updates == 1)
        var first = try #require(pusher.pushes.first)
        #expect(first.event == .update)
        #expect(first.priority == 10)
        #expect(first.environment == .production)
        // Follows the trip the app registered
        #expect(first.state.trip == "b")
        #expect(first.staleDate == first.state.train.addingTimeInterval(120))
        #expect(await store.registration(for: sampleToken)?.lastState == first.state)

        await poller.pass(at: now.addingTimeInterval(30))
        #expect(pusher.pushes.count == 1)

        await poller.pass(at: now.addingTimeInterval(300))
        first = try #require(pusher.pushes.last)
        #expect(pusher.pushes.count == 2)
        #expect(first.priority == 5)
    }

    @Test func keepsTheLastStateWithoutFeeds() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let pusher = FakePusher()
        let stats = await poller(store, pusher, board: nil).pass(at: now)
        #expect(stats.withoutFeeds == 1)
        #expect(pusher.pushes.isEmpty)
        #expect(await store.count == 1)
    }

    @Test func dropsTokensAPNsNoLongerKnows() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let pusher = FakePusher(result: .invalidToken("410 Unregistered"))
        await poller(store, pusher).pass(at: now)
        #expect(pusher.pushes.count == 1)
        #expect(await store.count == 0)
    }

    @Test func keepsTokensOnOtherFailures() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        await poller(store, FakePusher(result: .failed("APNs 500"))).pass(at: now)
        #expect(await store.registration(for: sampleToken)?.lastState == nil)
        #expect(await store.count == 1)
    }

    @Test func endsAfterEightHours() async throws {
        let store = try Store(directory: nil)
        try await registered(store, started: now.addingTimeInterval(-ActivityState.lifetime + 10))
        let pusher = FakePusher()
        let poller = poller(store, pusher)
        await poller.pass(at: now)
        let stats = await poller.pass(at: now.addingTimeInterval(10))
        #expect(stats.ended == 1)
        let end = try #require(pusher.pushes.last)
        #expect(pusher.pushes.count == 2)
        #expect(end.event == .end)
        #expect(end.dismissalDate == now.addingTimeInterval(10))
        #expect(await store.count == 0)
    }

    @Test func aRegistrationReplacedDuringAPassIsntOverwritten() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let old = try #require(await store.registration(for: sampleToken))
        try await registered(store)
        try await store.apply([.pushed(token: sampleToken, revision: old.revision, state: state(train: 3), at: now),
                               .drop(token: sampleToken, revision: old.revision)])
        #expect(await store.registration(for: sampleToken)?.lastState == nil)
        #expect(await store.count == 1)
    }

    @Test func pushesConcurrentlyWithinTheBound() async throws {
        let store = try Store(directory: nil)
        for i in 0..<40 {
            _ = try await store.upsert(testRegistration(token: String(format: "%064x", i + 1), owner: "k\(i)"),
                                       maxTotal: 100, maxPerOwner: 5)
        }
        let pusher = FakePusher(delay: .milliseconds(20))
        let start = ContinuousClock.now
        let stats = await poller(store, pusher, concurrency: 8).pass(at: now)
        let elapsed = ContinuousClock.now - start
        #expect(stats.updates == 40)
        #expect(pusher.maxInFlight <= 8)
        #expect(pusher.maxInFlight >= 4)
        // 40 at 20 ms, 8 at a time, is about 100 ms; one at a time would be 800
        #expect(elapsed < .milliseconds(600))
        #expect(await store.all.allSatisfy { $0.lastState != nil })
    }

    @Test func tenThousandCountdownsInOnePass() async throws {
        let store = try Store(directory: nil)
        for i in 0..<10_000 {
            var registration = testRegistration(token: String(format: "%064x", i + 1), owner: "k\(i % 2000)")
            registration.selection.walkMinutes = i % 7
            _ = try await store.upsert(registration, maxTotal: 100_000, maxPerOwner: 5)
        }
        let pusher = FakePusher()
        let start = ContinuousClock.now
        let stats = await poller(store, pusher).pass(at: now)
        let second = await poller(store, pusher).pass(at: now.addingTimeInterval(30))
        let elapsed = ContinuousClock.now - start
        #expect(stats.updates == 10_000)
        #expect(second.updates + second.refreshes == 0)
        // Linear work: well under a second on a Mac mini; quadratic would take minutes
        #expect(elapsed < .seconds(10))
    }

    @Test func concurrencyMapRunsEverythingOnceWithinTheLimit() async {
        final class Gauge: @unchecked Sendable {
            let lock = NSLock()
            var current = 0, peak = 0
        }
        let gauge = Gauge()
        let results = await Concurrency.map(Array(0..<50), limit: 5) { item -> Int in
            gauge.lock.withLock { gauge.current += 1; gauge.peak = max(gauge.peak, gauge.current) }
            try? await Task.sleep(for: .milliseconds(2))
            gauge.lock.withLock { gauge.current -= 1 }
            return item * 2
        }
        #expect(results.sorted() == (0..<50).map { $0 * 2 })
        #expect(gauge.peak <= 5)
    }

    @Test func overrunningPassesSkipTicks() {
        #expect(Poller.schedule(elapsed: 4, interval: 30) == (26, 0))
        #expect(Poller.schedule(elapsed: 30, interval: 30) == (30, 1))
        #expect(Poller.schedule(elapsed: 45, interval: 30) == (15, 1))
        #expect(Poller.schedule(elapsed: 95, interval: 30) == (25, 3))
    }

    @Test func timesOutAHungPush() async {
        await #expect(throws: Concurrency.TimedOut.self) {
            try await Concurrency.withTimeout(0.05) { try await Task.sleep(for: .seconds(10)) }
        }
    }
}
