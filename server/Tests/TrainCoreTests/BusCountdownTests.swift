import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import TrainCore

/// The B63 at 5 Av & Union St toward Pier 6, as the app's bus home stop has it.
let homeBus = BusChoice(line: "B63", lines: ["B63", "B103"],
                        stop: BusStop(id: "308209", name: "5 AV/UNION ST", latitude: 40.67700, longitude: -73.98080),
                        destination: "PIER 6 BKLYN BRIDGE PARK via 5 AV")

/// What a bus countdown registers with: no station, its bus.
let noTrain = Selection(stationID: "", routes: [], direction: .north)

func busRegistration(token: String = sampleToken, started: Date = now) -> Registration {
    Registration(token: token, owner: "key", environment: .production, selection: noTrain, trip: "", started: started,
                 alertKinds: nil, revision: UUID(), bus: homeBus)
}

func bus(_ line: String, in minutes: Double, live: Bool = true, to destination: String? = "PIER 6") -> CountdownBus {
    CountdownBus(line: line, destination: destination, time: now.addingTimeInterval(minutes * 60), isLive: live)
}

@Suite struct BusCountdownTests {
    @Test func countsDownToTheNextBusThenTheTwoAfter() throws {
        let buses = [bus("B103", in: 9), bus("B63", in: -1), bus("B63", in: 4, live: false), bus("B63", in: 15), bus("B103", in: 20)]
        let state = try #require(ContentState(buses: buses, after: nil, now: now))
        #expect(state.train == now.addingTimeInterval(240))
        #expect(!state.isLive)
        #expect(state.route == "bus:B63")
        #expect(state.following == [now.addingTimeInterval(540), now.addingTimeInterval(900)])
        #expect(state.followingRoutes == ["bus:B103", "bus:B63"])
        #expect(state.terminal == "Pier 6")
        #expect(state.trip == "")
        // Once started, not a bus before the one it showed, give or take a minute
        let later = try #require(ContentState(buses: buses, after: now.addingTimeInterval(570), now: now))
        #expect(later.train == now.addingTimeInterval(540))
        #expect(ContentState(buses: [bus("B63", in: -2)], after: nil, now: now) == nil)
    }

    @Test func theStoreKeepsABusCountdownsBus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try Store(directory: directory)
            _ = try await store.upsert(busRegistration(), maxTotal: 10, maxPerOwner: 5)
            _ = try await store.upsert(testRegistration(token: String(repeating: "cd34", count: 16)), maxTotal: 10, maxPerOwner: 5)
        }
        let reopened = try Store(directory: directory)
        #expect(await reopened.registration(for: sampleToken)?.bus == homeBus)
        #expect(await reopened.registration(for: String(repeating: "cd34", count: 16))?.bus == nil)
        #expect(await reopened.count == 2)
    }

    @Test func pushesBusCountdownsFromBusTimeAndTrainsFromTheFeeds() async throws {
        let store = try Store(directory: nil)
        _ = try await store.upsert(busRegistration(), maxTotal: 10, maxPerOwner: 5)
        let asked = Counter()
        let boardsAsked = BusChoicesSeen()
        let pusher = FakePusher()
        let poller = Poller(store: store, pusher: pusher, interval: 30, buses: { choices, _ in
            asked.increment()
            #expect(choices == [homeBus])
            return [Poller.busKey(homeBus): [bus("B63", in: 4), bus("B103", in: 9)]]
        }) { selections, _ in
            await boardsAsked.add(selections)
            return [:]
        }

        let stats = await poller.pass(at: now)
        #expect(stats.updates == 1)
        #expect(asked.value == 1)
        // Its placeholder train isn't asked of the feeds
        #expect(await boardsAsked.selections.isEmpty)
        let push = try #require(pusher.pushes.first)
        #expect(push.state.route == "bus:B63")
        #expect(push.state.followingRoutes == ["bus:B103"])
        #expect(push.priority == 10)
        #expect(await store.registration(for: sampleToken)?.lastState == push.state)

        // Its bus 4 minutes off: not asked again for a minute
        await poller.pass(at: now.addingTimeInterval(30))
        #expect(asked.value == 1)
        #expect(pusher.pushes.count == 1)
        // Then asked, the same buses: nothing worth pushing
        await poller.pass(at: now.addingTimeInterval(61))
        #expect(asked.value == 2)
        #expect(pusher.pushes.count == 1)
    }

    @Test func asksLessOftenTheFurtherOffTheBus() {
        #expect(Poller.busInterval(until: nil, now: now) == 0)
        #expect(Poller.busInterval(until: now.addingTimeInterval(25 * 60), now: now) == 240)
        #expect(Poller.busInterval(until: now.addingTimeInterval(10 * 60), now: now) == 120)
        #expect(Poller.busInterval(until: now.addingTimeInterval(5 * 60), now: now) == 60)
        #expect(Poller.busInterval(until: now.addingTimeInterval(60), now: now) == 30)
    }

    @Test func countdownsAtTheSameStopShareAnAsk() async throws {
        let store = try Store(directory: nil)
        _ = try await store.upsert(busRegistration(), maxTotal: 10, maxPerOwner: 5)
        var other = busRegistration(token: String(repeating: "cd34", count: 16))
        other.owner = "other"
        other.bus?.lines = nil
        _ = try await store.upsert(other, maxTotal: 10, maxPerOwner: 5)
        let asked = Counter()
        let pusher = FakePusher()
        let poller = Poller(store: store, pusher: pusher, interval: 30, buses: { choices, _ in
            asked.increment()
            return Dictionary(choices.map { (Poller.busKey($0), [bus("B63", in: 4)]) }, uniquingKeysWith: { a, _ in a })
        }) { _, _ in [:] }
        let stats = await poller.pass(at: now)
        #expect(asked.value == 1)
        #expect(stats.updates == 2)
    }

    @Test func aBusCountdownWithoutBusTimeKeepsItsLastState() async throws {
        let store = try Store(directory: nil)
        _ = try await store.upsert(busRegistration(), maxTotal: 10, maxPerOwner: 5)
        let pusher = FakePusher()
        let poller = Poller(store: store, pusher: pusher, interval: 30, buses: { _, _ in [:] }) { _, _ in [:] }
        let stats = await poller.pass(at: now)
        #expect(stats.withoutFeeds == 1)
        #expect(pusher.pushes.isEmpty)
    }

    @Test func endsABusCountdownOnceItsTimeIsUp() async throws {
        let store = try Store(directory: nil)
        var registration = busRegistration(started: now.addingTimeInterval(-ActivityState.lifetime - 1))
        registration.lastState = ContentState(buses: [bus("B63", in: 4)], after: nil, now: now)
        _ = try await store.upsert(registration, maxTotal: 10, maxPerOwner: 5)
        let pusher = FakePusher()
        let poller = Poller(store: store, pusher: pusher, interval: 30, buses: { _, _ in [:] }) { _, _ in [:] }
        let stats = await poller.pass(at: now)
        #expect(stats.ended == 1)
        #expect(pusher.pushes.first?.event == .end)
        #expect(await store.count == 0)
    }
}

/// The selections a pass asked the feeds for.
actor BusChoicesSeen {
    private(set) var selections: [Selection] = []
    func add(_ more: [Selection]) { selections += more }
}

@Suite struct BusCountdownHTTPTests {
    let secret = "test-secret-0123456789abcdef"
    var bearer: HTTPFields { [.authorization: "Bearer \(secret)"] }

    func withApp(buses: BusTime?, _ body: @escaping @Sendable (any TestClientProtocol, Store) async throws -> Void) async throws {
        let store = try Store(directory: nil)
        let services = HTTPServices(store: store, auth: .secret(secret), appID: testAppID, limits: testLimits(), buses: buses)
        try await Application(router: HTTPRoutes.router(services)).test(.router) { client in try await body(client, store) }
    }

    func body(_ bus: BusChoice) throws -> ByteBuffer {
        var json = try JSONSerialization.jsonObject(with: Data(registrationBody(selection: noTrain, trip: ""))) as! [String: Any]
        json["bus"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bus))
        return ByteBuffer(bytes: Array(try JSONSerialization.data(withJSONObject: json)))
    }

    /// Never asked: registering doesn't call Bus Time.
    static let busTime = BusTime(key: "k") { _ in throw URLError(.badURL) }

    @Test func registersABusCountdown() async throws {
        try await withApp(buses: Self.busTime) { (client, store) async throws in
            try await client.execute(uri: "/activities", method: .post, headers: bearer, body: try body(homeBus)) {
                #expect($0.status == .noContent)
            }
            let saved = try #require(await store.registration(for: sampleToken))
            #expect(saved.bus == homeBus)
            #expect(saved.countdownID == "bus B63,B103 @308209")
        }
    }

    @Test func registersABusAtABusyStopWithoutItsChanges() async throws {
        var busy = homeBus
        busy.lines = ["B63", "B103", "B61", "B67", "B69", "B65", "B41", "B45", "B57"]
        busy.changes = [BusChange(stop: homeBus.stop, minutes: 4, walkMinutes: 2,
                                  selection: Selection(stationID: "R31", routes: ["R"], direction: .north))]
        let sent = busy
        // Only some stop there by the timetable (the B63): Bus Time may have others there on a detour
        #expect(BusStops.lines["308209"] == ["B63"])
        try await withApp(buses: Self.busTime) { (client, store) async throws in
            try await client.execute(uri: "/activities", method: .post, headers: bearer, body: try body(sent)) {
                #expect($0.status == .noContent)
            }
            let saved = try #require(await store.registration(for: sampleToken))
            #expect(saved.bus?.allLines == sent.lines)
            #expect(saved.bus?.changes == nil)
        }
    }

    @Test func aStopsLinesMatchBusTimesNamesWithoutLeadingZeros() {
        // The file names the Q6 as Bus Time does, "Q6"; an older app may have saved the GTFS id, "Q06"
        let stop = BusStop(id: "505334", name: "", latitude: 40.70, longitude: -73.81)
        #expect(BusStops.isReal(BusChoice(line: "Q6", stop: stop)))
        #expect(BusStops.isReal(BusChoice(line: "Q06", stop: stop)))
        #expect(!BusStops.isReal(BusChoice(line: "Q60", stop: stop)))
    }

    @Test func aRefusedStopSaysWhyWithItsCodeAndLines() {
        let stop = BusStop(id: "505334", name: "", latitude: 40.70, longitude: -73.81)
        #expect(BusStops.refusal(of: BusChoice(line: "Q6", stop: stop)) == nil)
        // A stop new in the GTFS, not yet in the file
        let new = BusStop(id: "999999", name: "", latitude: 40.70, longitude: -73.81)
        #expect(BusStops.refusal(of: BusChoice(line: "Q6", stop: new))
            == "stop 999999 not in bus_stop_lines.json (Q6 at 999999)")
        #expect(BusStops.refusal(of: BusChoice(line: "Q6", lines: ["Q6", "Q60"], stop: stop, otherStop: new))
            == "stop 999999 not in bus_stop_lines.json (Q6,Q60 at 505334/999999)")
        #expect(BusStops.refusal(of: BusChoice(line: "Q60", stop: stop))
            == "no line stops there by bus_stop_lines.json (Q60 at 505334)")
    }

    @Test func refusesABusCountdownWithoutBusTime() async throws {
        try await withApp(buses: nil) { (client, store) async throws in
            try await client.execute(uri: "/activities", method: .post, headers: bearer, body: try body(homeBus)) {
                #expect($0.status == .serviceUnavailable)
            }
            #expect(await store.count == 0)
        }
    }

    @Test func refusesABusOutOfTownOrWithTooManyLines() async throws {
        var boston = homeBus
        boston.stop.latitude = 42.36
        boston.stop.longitude = -71.06
        var many = homeBus
        many.lines = (1...21).map { "B\($0)" }
        var odd = homeBus
        odd.line = "B63&key=x"
        odd.lines = nil
        // A made-up stop, one across the street that's made up, and a real stop none of its lines stop at
        var madeUp = homeBus
        madeUp.stop.id = "999999"
        var madeUpAcross = homeBus
        madeUpAcross.otherStop = BusStop(id: "999998", name: "5 AV/UNION ST", latitude: 40.67710, longitude: -73.98070)
        var elsewhere = homeBus
        elsewhere.line = "M15"
        elsewhere.lines = ["M15", "M15-SBS"]
        let bads = [boston, many, odd, madeUp, madeUpAcross, elsewhere]
        try await withApp(buses: Self.busTime) { (client, store) async throws in
            for bad in bads {
                try await client.execute(uri: "/activities", method: .post, headers: bearer, body: try body(bad)) {
                    #expect($0.status == .badRequest)
                }
            }
            // Nor a train without a station, as before
            try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try registrationBody(selection: noTrain))) {
                #expect($0.status == .badRequest)
            }
            #expect(await store.count == 0)
        }
    }
}

extension BusCountdownTests {
    @Test func movesOnToTheNextBusWithAsManyAfterAndNoSecondPush() async throws {
        let store = try Store(directory: nil)
        _ = try await store.upsert(busRegistration(), maxTotal: 10, maxPerOwner: 5)
        let pusher = FakePusher()
        let coming = [4, 9, 15, 20, 25].map { bus("B63", in: $0) }
        let poller = Poller(store: store, pusher: pusher, interval: 30, buses: { _, _ in
            [Poller.busKey(homeBus): coming]
        }) { _, _ in [:] }
        await poller.pass(at: now)
        // The buses after its following ones kept, for moving on between asks
        #expect(await store.registration(for: sampleToken)?.later.map(\.time) == [20, 25].map { now.addingTimeInterval($0 * 60) })
        #expect(await store.registration(for: sampleToken)?.later.first?.route == "bus:B63")
        let due = try #require(await poller.nextDue(after: now))
        await poller.pushDue(at: due)
        let moved = try #require(pusher.pushes.last?.state)
        #expect(moved.train == now.addingTimeInterval(9 * 60))
        #expect(moved.following == [15, 20].map { now.addingTimeInterval($0 * 60) })
        #expect(moved.followingRoutes == ["bus:B63", "bus:B63"])
        #expect(pusher.pushes.count == 2)
        // Asked again, the same buses, its destination back: nothing more to push
        await poller.pass(at: due.addingTimeInterval(120))
        #expect(pusher.pushes.count == 2)
    }

    @Test func oneNotYetPushedIsAskedForAMinuteApartWhileItsStopHasNoneOfItsBuses() async throws {
        let store = try Store(directory: nil)
        _ = try await store.upsert(busRegistration(), maxTotal: 10, maxPerOwner: 5)
        let asked = Counter()
        let poller = Poller(store: store, pusher: FakePusher(), interval: 30, buses: { choices, _ in
            asked.increment()
            return [Poller.busKey(homeBus): []]
        }) { _, _ in [:] }
        // At once when registered
        await poller.pass(at: now)
        #expect(asked.value == 1)
        await poller.pass(at: now.addingTimeInterval(20))
        await poller.pass(at: now.addingTimeInterval(40))
        #expect(asked.value == 1)
        await poller.pass(at: now.addingTimeInterval(60))
        #expect(asked.value == 2)
        // Another registered there meanwhile is asked for at once
        var other = busRegistration(token: String(repeating: "cd34", count: 16))
        other.owner = "other"
        _ = try await store.upsert(other, maxTotal: 10, maxPerOwner: 5)
        await poller.pass(at: now.addingTimeInterval(80))
        #expect(asked.value == 3)
    }

    @Test func aStopBusTimeCouldntAnswerForIsAskedAgainOnlyAfterTwoMinutes() async throws {
        let store = try Store(directory: nil)
        _ = try await store.upsert(busRegistration(), maxTotal: 10, maxPerOwner: 5)
        let asked = Counter()
        let poller = Poller(store: store, pusher: FakePusher(), interval: 30, buses: { _, _ in
            asked.increment()
            return [:]
        }) { _, _ in [:] }
        await poller.pass(at: now)
        await poller.pass(at: now.addingTimeInterval(60))
        await poller.pass(at: now.addingTimeInterval(100))
        #expect(asked.value == 1)
        await poller.pass(at: now.addingTimeInterval(120))
        #expect(asked.value == 2)
    }
}
