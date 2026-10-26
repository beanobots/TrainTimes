import Foundation
import ServiceLifecycle
import Testing
@testable import TrainCore

/// Records pushes rather than sending them, and how many were in flight at once.
final class FakePusher: Pusher, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Push] = []
    private var inFlight = 0
    private var peak = 0
    private var gaveUp = false
    let result: PushResult
    /// Each push waits until this many have been in flight at once.
    let gate: Int?

    init(result: PushResult = .sent, gate: Int? = nil) {
        self.result = result
        self.gate = gate
    }

    func send(_ push: Push) async -> PushResult {
        lock.withLock {
            sent.append(push)
            inFlight += 1
            peak = max(peak, inFlight)
        }
        if let gate { await waitForPeak(gate) }
        lock.withLock { inFlight -= 1 }
        return result
    }

    /// Until `count` pushes have been in flight at once. After 10 seconds
    /// none waits any more, so pushes made fewer at a time fail a test
    /// rather than hang it.
    private func waitForPeak(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while lock.withLock({ peak < count && !gaveUp }) {
            if ContinuousClock.now >= deadline { lock.withLock { gaveUp = true } }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private var widgetTokens: [String] = []
    /// What widget reloads return.
    var widgetResult: PushResult = .sent

    func sendWidgetReload(token: String, environment: PushEnvironment) async -> PushResult {
        lock.withLock {
            widgetTokens.append(token)
            return widgetResult
        }
    }

    func shutdown() async {}
    var pushes: [Push] { lock.withLock { sent } }
    var widgetReloads: [String] { lock.withLock { widgetTokens } }
    var maxInFlight: Int { lock.withLock { peak } }
}

/// Counts from any task.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
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
        // Out of date as its train is due, as the app makes it
        #expect(first.staleDate == first.state.train)
        #expect(await store.registration(for: sampleToken)?.lastState == first.state)

        await poller.pass(at: now.addingTimeInterval(30))
        #expect(pusher.pushes.count == 1)

        await poller.pass(at: now.addingTimeInterval(300))
        first = try #require(pusher.pushes.last)
        #expect(pusher.pushes.count == 2)
        #expect(first.priority == 5)
    }

    @Test func movesOnToTheNextTrainWithoutTakingOffTheWalkAgain() async throws {
        let store = try Store(directory: nil)
        var registration = testRegistration()
        registration.selection.walkMinutes = 5
        _ = try await store.upsert(registration, maxTotal: 10, maxPerOwner: 5)
        let pusher = FakePusher()
        // The feed drops each train once it's due
        let poller = Poller(store: store, pusher: pusher, interval: 30) { selections, time in
            var board = fixtureBoard()
            board.trains.removeAll { $0.time <= time }
            return Dictionary(selections.map { ($0, board) }, uniquingKeysWith: { a, _ in a })
        }
        await poller.pass(at: now)
        #expect(pusher.pushes.last?.state.trip == "b")
        // b has gone; c, 2 minutes away, is too soon to walk to from home, but you set off when it started
        await poller.pass(at: now.addingTimeInterval(7 * 60))
        #expect(pusher.pushes.count == 2)
        #expect(pusher.pushes.last?.state.trip == "c")
    }

    @Test func pushesTheNextTrainAsTheTrainIsDue() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let pusher = FakePusher()
        let poller = poller(store, pusher)
        await poller.pass(at: now)
        // b, then c (an N) and d
        #expect(await poller.nextDue(after: now) == now.addingTimeInterval(6 * 60))
        #expect(await poller.pushDue(at: now.addingTimeInterval(5 * 60)).updates == 0)
        #expect(pusher.pushes.count == 1)

        let stats = await poller.pushDue(at: now.addingTimeInterval(6 * 60))
        #expect(stats.updates == 1)
        #expect(pusher.pushes.count == 2)
        let moved = try #require(pusher.pushes.last)
        #expect(moved.event == .update)
        #expect(moved.priority == 10)
        #expect(moved.state.train == now.addingTimeInterval(9 * 60))
        #expect(moved.state.route == "N")
        #expect(moved.state.following == [now.addingTimeInterval(15 * 60)])
        #expect(moved.staleDate == moved.state.train)
        #expect(await store.registration(for: sampleToken)?.lastState == moved.state)
        // Then d, and after that nothing to move on to until the next pass
        #expect(await poller.nextDue(after: now.addingTimeInterval(6 * 60)) == now.addingTimeInterval(9 * 60))
        await poller.pushDue(at: now.addingTimeInterval(9 * 60))
        #expect(pusher.pushes.last?.state.train == now.addingTimeInterval(15 * 60))
        #expect(await poller.nextDue(after: now.addingTimeInterval(9 * 60)) == nil)
    }

    @Test func keepsTwoTrainsAfterTheOneDueFromTheLastPassesLaterOnes() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let pusher = FakePusher()
        var board = fixtureBoard()
        board.trains += [arrival(20, trip: "e", route: "W"), arrival(24, trip: "f"), arrival(30, trip: "g"),
                         arrival(36, trip: "h")]
        let poller = poller(store, pusher, board: board)
        await poller.pass(at: now)
        // b, then c and d; e, f and g kept for later
        #expect(pusher.pushes.last?.state.following == [9, 15].map { now.addingTimeInterval($0 * 60) })
        #expect(await store.registration(for: sampleToken)?.later.map(\.trip) == ["e", "f", "g"])

        await poller.pushDue(at: now.addingTimeInterval(6 * 60))
        var moved = try #require(pusher.pushes.last?.state)
        #expect(moved.train == now.addingTimeInterval(9 * 60))
        #expect(moved.following == [15, 20].map { now.addingTimeInterval($0 * 60) })
        #expect(moved.followingRoutes == ["R", "W"])
        // Due again before the next pass: still two after it
        await poller.pushDue(at: now.addingTimeInterval(9 * 60))
        moved = try #require(pusher.pushes.last?.state)
        #expect(moved.train == now.addingTimeInterval(15 * 60))
        #expect(moved.following == [20, 24].map { now.addingTimeInterval($0 * 60) })
        #expect(moved.followingRoutes == ["W", "R"])
    }

    // MARK: Widgets

    let widgetToken = String(repeating: "cd34", count: 16)

    func registeredWithWidgets(_ store: Store, token: String = sampleToken) async throws {
        var registration = testRegistration(token: token)
        registration.widgetToken = widgetToken
        _ = try await store.upsert(registration, maxTotal: 10, maxPerOwner: 5)
    }

    @Test func reloadsThePhonesWidgetsWhenTheCountdownsTimesChange() async throws {
        let store = try Store(directory: nil)
        try await registeredWithWidgets(store)
        let pusher = FakePusher()
        let poller = poller(store, pusher)

        var stats = await poller.pass(at: now)
        #expect(pusher.widgetReloads == [widgetToken])
        #expect(stats.widgetReloads == 1)
        #expect(stats.description.contains("1 widget reloads"))

        // A refresh with the same times: the widgets already show them
        stats = await poller.pass(at: now.addingTimeInterval(300))
        #expect(pusher.pushes.count == 2)
        #expect(pusher.widgetReloads.count == 1)

        // Moving on to the next train between passes: they show that too
        await poller.pushDue(at: now.addingTimeInterval(6 * 60))
        #expect(pusher.widgetReloads.count == 2)
    }

    @Test func reloadsOnlyWhenTheTimesMovedAtAll() throws {
        let last = state(train: 4)
        var new = last
        new.updated = now.addingTimeInterval(30)
        new.notice = "Delays"
        #expect(!ActivityState.changesWidgets(new, from: last))
        // However little: they'd otherwise show other times from the Lock Screen
        new.train = last.train.addingTimeInterval(5)
        #expect(ActivityState.changesWidgets(new, from: last))
        #expect(ActivityState.changesWidgets(last, from: nil))
    }

    @Test func reloadsEachPhoneOnceAndNotWithoutAToken() async throws {
        let store = try Store(directory: nil)
        try await registeredWithWidgets(store)
        try await registeredWithWidgets(store, token: String(repeating: "ef56", count: 16))
        _ = try await store.upsert(testRegistration(token: String(repeating: "0123", count: 16)), maxTotal: 10, maxPerOwner: 5)
        let pusher = FakePusher()
        await poller(store, pusher).pass(at: now)
        #expect(pusher.pushes.count == 3)
        #expect(pusher.widgetReloads == [widgetToken])
    }

    @Test func forgetsAWidgetTokenAPNsDoesntKnowButKeepsPushing() async throws {
        let store = try Store(directory: nil)
        try await registeredWithWidgets(store)
        let pusher = FakePusher()
        pusher.widgetResult = .invalidToken("410 Unregistered")
        let poller = poller(store, pusher)
        await poller.pass(at: now)
        let registration = try #require(await store.registration(for: sampleToken))
        #expect(registration.widgetToken == nil)
        #expect(registration.lastState != nil)

        await poller.pushDue(at: now.addingTimeInterval(6 * 60))
        #expect(pusher.pushes.count == 2)
        #expect(pusher.widgetReloads.count == 1)
    }

    @Test func registeringAgainForgetsTheLaterTrains() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        var board = fixtureBoard()
        board.trains += [arrival(20, trip: "e")]
        await poller(store, FakePusher(), board: board).pass(at: now)
        #expect(await store.registration(for: sampleToken)?.later.count == 1)
        try await registered(store)
        #expect(await store.registration(for: sampleToken)?.later.isEmpty == true)
    }

    @Test func doesntMoveOnOnceItsTimeIsUp() async throws {
        let store = try Store(directory: nil)
        // Ends 5 minutes from now, before b is due
        try await registered(store, started: now.addingTimeInterval(-ActivityState.lifetime + 5 * 60))
        let pusher = FakePusher()
        let poller = poller(store, pusher)
        await poller.pass(at: now)
        #expect(await poller.nextDue(after: now) == nil)
        #expect(await poller.pushDue(at: now.addingTimeInterval(6 * 60)).updates == 0)
        #expect(pusher.pushes.count == 1)
    }

    @Test func registeredAgainMidwayTheFirstPushMovesOnFromTheAppsState() async throws {
        // A new push token, after the train the countdown started on has gone
        // and the Lock Screen has moved on by itself: a, two minutes away, is
        // still yours, though from home you couldn't reach it
        var registration = testRegistration()
        registration.selection.walkMinutes = 5
        registration.trip = "gone"
        let time = { (minutes: Double) in now.addingTimeInterval(minutes * 60) }
        registration.lastState = ContentState(train: time(-1), trip: "gone", isLive: true, terminal: nil,
                                              following: [time(2), time(6)], notice: nil, updated: time(-6))
        let store = try Store(directory: nil)
        _ = try await store.upsert(registration, maxTotal: 10, maxPerOwner: 5)
        let pusher = FakePusher()
        await poller(store, pusher).pass(at: now)
        let first = try #require(pusher.pushes.first)
        #expect(first.state.trip == "a")
        #expect(first.priority == 10)

        // Without the app's state, the first you can reach from now
        let fresh = try Store(directory: nil)
        registration.lastState = nil
        _ = try await fresh.upsert(registration, maxTotal: 10, maxPerOwner: 5)
        let other = FakePusher()
        await poller(fresh, other).pass(at: now)
        #expect(other.pushes.first?.state.trip == "b")
    }

    @Test func noTrainsKeepsTheLastTrainAndNamesTheAlert() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let pusher = FakePusher()
        let poller = Poller(store: store, pusher: pusher, interval: 30) { selections, time in
            var board = fixtureBoard()
            if time > now { board.trains = [] }
            return Dictionary(selections.map { ($0, board) }, uniquingKeysWith: { a, _ in a })
        }
        await poller.pass(at: now)
        let first = try #require(pusher.pushes.last)
        await poller.pass(at: now.addingTimeInterval(30))
        let second = try #require(pusher.pushes.last)
        #expect(pusher.pushes.count == 2)
        #expect(second.state.train == first.state.train)
        #expect(second.state.following.isEmpty)
        #expect(second.state.notice == "Service change")
    }

    @Test func noTrainsSaysSoOnceThenOnlyRefreshes() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let pusher = FakePusher()
        let poller = Poller(store: store, pusher: pusher, interval: 30) { selections, time in
            var board = fixtureBoard()
            board.alerts = []
            if time > now { board.trains = [] }
            return Dictionary(selections.map { ($0, board) }, uniquingKeysWith: { a, _ in a })
        }
        await poller.pass(at: now)
        await poller.pass(at: now.addingTimeInterval(30))
        let noTrains = try #require(pusher.pushes.last)
        #expect(pusher.pushes.count == 2)
        #expect(noTrains.state.notice == ActivityState.noTrains)
        #expect(noTrains.priority == 10)

        await poller.pass(at: now.addingTimeInterval(60))
        #expect(pusher.pushes.count == 2)
        await poller.pass(at: now.addingTimeInterval(330))
        #expect(pusher.pushes.count == 3)
        #expect(pusher.pushes.last?.priority == 5)
        #expect(pusher.pushes.last?.state.notice == ActivityState.noTrains)
    }

    @Test func withNothingPushedYetAndNoTrainsTheAppsOwnStateStands() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let pusher = FakePusher()
        var board = fixtureBoard()
        board.trains = []
        let stats = await poller(store, pusher, board: board).pass(at: now)
        #expect(stats == Poller.Stats(registrations: 1, keys: 0))
        #expect(pusher.pushes.isEmpty)
        #expect(await store.registration(for: sampleToken)?.lastState == nil)
    }

    @Test func keepsTheLastStateWithoutFeeds() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let pusher = FakePusher()
        await poller(store, pusher).pass(at: now)
        let pushed = try #require(await store.registration(for: sampleToken))
        #expect(pushed.lastState != nil)
        // Long enough after that a refresh would be due
        let stats = await poller(store, pusher, board: nil).pass(at: now.addingTimeInterval(400))
        #expect(stats.withoutFeeds == 1)
        #expect(pusher.pushes.count == 1)
        let kept = try #require(await store.registration(for: sampleToken))
        #expect(kept.lastState == pushed.lastState)
        #expect(kept.lastPush == pushed.lastPush)
    }

    @Test func keepsAnAlertWhileTheAlertsCantBeHad() async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let pusher = FakePusher()
        var board = fixtureBoard()
        await poller(store, pusher, board: board).pass(at: now)
        #expect(pusher.pushes.last?.state.notice == "Service change")

        board.alerts = nil
        await poller(store, pusher, board: board).pass(at: now.addingTimeInterval(30))
        #expect(pusher.pushes.count == 1)
        #expect(await store.registration(for: sampleToken)?.lastState?.notice == "Service change")
        // Once they're had again and it's over, it goes
        board.alerts = []
        await poller(store, pusher, board: board).pass(at: now.addingTimeInterval(60))
        #expect(pusher.pushes.count == 2)
        #expect(pusher.pushes.last?.state.notice == nil)
    }

    @Test func keepsAnElevatorOutWhileTheOutagesCantBeHad() async throws {
        let store = try Store(directory: nil)
        var registration = testRegistration()
        registration.selection.elevatorAlerts = true
        _ = try await store.upsert(registration, maxTotal: 10, maxPerOwner: 5)
        let pusher = FakePusher()
        var board = fixtureBoard()
        await poller(store, pusher, board: board).pass(at: now)
        #expect(pusher.pushes.last?.state.notice == "Elevator out")

        board.outages = nil
        await poller(store, pusher, board: board).pass(at: now.addingTimeInterval(30))
        #expect(pusher.pushes.count == 1)
        // With the trains gone, though, it's not an elevator the countdown names
        board.trains = []
        board.alerts = []
        await poller(store, pusher, board: board).pass(at: now.addingTimeInterval(60))
        #expect(pusher.pushes.count == 2)
        #expect(pusher.pushes.last?.state.notice == ActivityState.noTrains)
    }

    @Test func namesTheAlertOnceTheTrainsHaveGoneThoughTheOutagesCantBeHad() async throws {
        let store = try Store(directory: nil)
        var registration = testRegistration()
        registration.selection.elevatorAlerts = true
        _ = try await store.upsert(registration, maxTotal: 10, maxPerOwner: 5)
        let pusher = FakePusher()
        var board = fixtureBoard()
        await poller(store, pusher, board: board).pass(at: now)
        #expect(pusher.pushes.last?.state.notice == "Elevator out")

        board.trains = []
        board.outages = nil
        board.alerts = [ServiceAlert(id: "2", kind: .suspended, type: "Suspended", header: "No R trains",
                                     details: "", period: nil)]
        await poller(store, pusher, board: board).pass(at: now.addingTimeInterval(30))
        #expect(pusher.pushes.count == 2)
        #expect(pusher.pushes.last?.state.notice == "Suspended")
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

    @Test func endsOnceItsTimeIsUp() async throws {
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

    @Test func forgetsOneNeverPushedOnceItWouldHaveEnded() async throws {
        let store = try Store(directory: nil)
        try await registered(store, started: now.addingTimeInterval(-ActivityState.lifetime - 1))
        let pusher = FakePusher()
        let stats = await poller(store, pusher).pass(at: now)
        #expect(stats.ended == 1)
        // There's nothing on the phone to end
        #expect(pusher.pushes.isEmpty)
        #expect(await store.count == 0)
    }

    @Test func forgetsOneWhoseEndFailsAndCountsEveryFailedPush() async throws {
        let store = try Store(directory: nil)
        func register(_ i: Int, started: Date) async throws {
            _ = try await store.upsert(testRegistration(token: String(format: "%064x", i + 1), owner: "k\(i)",
                                                        started: started), maxTotal: 100, maxPerOwner: 5)
        }
        for i in 0..<12 {
            try await register(i, started: now.addingTimeInterval(-ActivityState.lifetime + 10))
        }
        await poller(store, FakePusher()).pass(at: now)
        for i in 12..<15 {
            try await register(i, started: now)
        }
        // 12 ends and 3 first pushes, more than there are error lines for
        let failing = FakePusher(result: .failed("APNs 500"))
        let stats = await poller(store, failing).pass(at: now.addingTimeInterval(10))
        #expect(failing.pushes.filter { $0.event == .end }.count == 12)
        #expect(stats.ended == 12)
        #expect(stats.failed == 15)
        #expect("\(stats)" == "15 countdowns, 0 updates, 0 refreshes, 12 ended, 0 dropped, 15 failed, 0 without feeds, 0 widget reloads, 0 attest keys")
        #expect(await store.count == 3)
    }

    @Test(arguments: [PushResult.sent, .invalidToken("410 Unregistered")])
    func aRegistrationReplacedDuringAPassIsntOverwritten(result: PushResult) async throws {
        let store = try Store(directory: nil)
        try await registered(store)
        let old = try #require(await store.registration(for: sampleToken))
        // The app registers it again while the pass fetches the feeds
        let poller = Poller(store: store, pusher: FakePusher(result: result), interval: 30) { selections, _ in
            _ = try? await store.upsert(testRegistration(), maxTotal: 10, maxPerOwner: 5)
            return Dictionary(selections.map { ($0, fixtureBoard()) }, uniquingKeysWith: { a, _ in a })
        }
        let stats = await poller.pass(at: now)
        #expect(stats.updates + stats.dropped == 1)
        let new = try #require(await store.registration(for: sampleToken))
        #expect(new.revision != old.revision)
        #expect(new.lastState == nil)
        #expect(await store.count == 1)
    }

    @Test func pushesConcurrentlyWithinTheBound() async throws {
        let store = try Store(directory: nil)
        for i in 0..<40 {
            _ = try await store.upsert(testRegistration(token: String(format: "%064x", i + 1), owner: "k\(i)"),
                                       maxTotal: 100, maxPerOwner: 5)
        }
        // Each push waits for 8 to be in flight at once: as many as there can be, and no more
        let pusher = FakePusher(gate: 8)
        let stats = await poller(store, pusher, concurrency: 8).pass(at: now)
        #expect(stats.updates == 40)
        #expect(pusher.maxInFlight == 8)
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

    @Test(.timeLimit(.minutes(1))) func runsPassesAndPurgesHourlyUntilCancelled() async throws {
        let store = try Store(directory: nil)
        let started = Date.now
        func key(_ id: String) -> AttestKey {
            let lastUsed = started.addingTimeInterval(-91 * 86400)
            return AttestKey(id: id, publicKey: Data(repeating: 4, count: 65), counter: 0, environment: .production,
                             created: lastUsed, lastUsed: lastUsed)
        }
        #expect(try await store.addKey(key("old")))
        _ = try await store.upsert(testRegistration(started: started), maxTotal: 10, maxPerOwner: 5)
        let passes = Counter()
        let poller = Poller(store: store, pusher: FakePusher(), interval: 0.01) { selections, _ in
            passes.increment()
            return Dictionary(selections.map { ($0, Board(trains: [])) }, uniquingKeysWith: { a, _ in a })
        }
        let run = Task { try await poller.run() }
        while passes.value < 3 { try await Task.sleep(for: .milliseconds(5)) }
        // Purged after the first pass, and not again within the hour
        #expect(try await store.key(id: "old") == nil)
        #expect(try await store.addKey(key("older")))
        let after = passes.value
        while passes.value < after + 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try await store.key(id: "older") != nil)

        run.cancel()
        try await run.value
        let last = passes.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(passes.value == last)
        #expect(await store.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func wakesBetweenPassesToPushADueTrain() async throws {
        let store = try Store(directory: nil)
        let started = Date.now
        var registration = testRegistration(started: started)
        var last = state(train: 0)
        last.train = started.addingTimeInterval(0.2)
        last.following = [started.addingTimeInterval(60)]
        last.followingRoutes = ["R"]
        registration.lastState = last
        registration.lastPush = started
        _ = try await store.upsert(registration, maxTotal: 10, maxPerOwner: 5)
        let pusher = FakePusher()
        // No feeds, so passes push nothing; the next would be an hour away
        let poller = Poller(store: store, pusher: pusher, interval: 60 * 60) { _, _ in [:] }
        let run = Task { try await poller.run() }
        while pusher.pushes.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        run.cancel()
        try await run.value
        #expect(pusher.pushes.count == 1)
        #expect(pusher.pushes.first?.state.train == started.addingTimeInterval(60))
        #expect(pusher.pushes.first?.timestamp == last.train)
    }

    @Test(.timeLimit(.minutes(1))) func stopsWaitingWhenShutDownGracefully() async throws {
        let store = try Store(directory: nil)
        _ = try await store.upsert(testRegistration(started: .now), maxTotal: 10, maxPerOwner: 5)
        let passes = Counter()
        // After its first pass, it would wait an hour for the next
        let poller = Poller(store: store, pusher: FakePusher(), interval: 60 * 60) { selections, _ in
            passes.increment()
            return Dictionary(selections.map { ($0, Board(trains: [])) }, uniquingKeysWith: { a, _ in a })
        }
        let group = ServiceGroup(services: [poller])
        async let running: Void = group.run()
        while passes.value < 1 { try await Task.sleep(for: .milliseconds(5)) }
        await group.triggerGracefulShutdown()
        try await running
        #expect(passes.value == 1)
    }

    @Test func timesOutAHungPush() async {
        await #expect(throws: Concurrency.TimedOut.self) {
            try await Concurrency.withTimeout(0.05) { try await Task.sleep(for: .seconds(10)) }
        }
    }
}

/// A Transfers widget's countdown, which mentions its changed-to lines' alerts too.
@Suite struct TransferCountdownTests {
    /// Your R's board (a service change), and a delay on the D you change to at Atlantic Av.
    private func poller(_ store: Store, _ pusher: FakePusher) -> Poller {
        Poller(store: store, pusher: pusher, interval: 30) { selections, _ in
            Dictionary(selections.map { selection in
                var board = fixtureBoard()
                if selection != prospect {
                    board.alerts = [ServiceAlert(id: "d", kind: .delays, type: "Delays", header: "D trains are delayed",
                                                 details: "", period: nil)]
                }
                return (selection, board)
            }, uniquingKeysWith: { a, _ in a })
        }
    }

    @Test func mentionsTheChangedToLinesAlerts() async throws {
        let store = try Store(directory: nil)
        var registration = testRegistration()
        registration.change = Change(stationID: "R31", routes: ["D", "N"])
        _ = try await store.upsert(registration, maxTotal: 10, maxPerOwner: 5)
        let pusher = FakePusher()
        await poller(store, pusher).pass(at: now)
        #expect(pusher.pushes.last?.state.notice == "Delays")
    }

    @Test func withoutAChangeOnlyItsOwn() async throws {
        let store = try Store(directory: nil)
        _ = try await store.upsert(testRegistration(), maxTotal: 10, maxPerOwner: 5)
        let pusher = FakePusher()
        await poller(store, pusher).pass(at: now)
        #expect(pusher.pushes.last?.state.notice == "Service change")
    }
}
