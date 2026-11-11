import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import TrainCore

/// Counts reads of the MTA, answering each with a feed naming its address (a trip with it as
/// id, or a JSON list of it), or nothing when `failing`, or an empty body when `empty`, or
/// train feeds with no trips when `noTrips`.
private actor FakeMTA {
    var reads = 0
    var failing = false
    var empty = false
    var noTrips = false

    func read(_ url: URL) -> Data? {
        reads += 1
        if failing { return nil }
        if empty { return Data() }
        if noTrips, url != AlertsFeed.url, url != OutagesFeed.url { return GTFSFeed.feed([]) }
        if url == AlertsFeed.url || url == OutagesFeed.url { return Data("[\"\(url.absoluteString)\"]".utf8) }
        return GTFSFeed.feed([GTFSFeed.trip(url.absoluteString, stops: [])])
    }

    func answerEmpty(_ empty: Bool) { self.empty = empty }

    func answerNoTrips(_ noTrips: Bool) { self.noTrips = noTrips }

    func fail(_ failing: Bool) { self.failing = failing }
}

/// Counts reads of each feed.
private actor ReadCounts {
    private var counts: [URL: Int] = [:]

    @discardableResult
    func add(_ url: URL) -> Int {
        counts[url, default: 0] += 1
        return counts[url] ?? 0
    }

    func of(_ url: URL) -> Int { counts[url] ?? 0 }
}

@Suite struct FeedRelayTests {
    @Test func namesEveryFeedTheAppReads() {
        #expect(Set(FeedRelay.feeds.keys) == [
            "nyct/gtfs", "nyct/gtfs-ace", "nyct/gtfs-bdfm", "nyct/gtfs-g", "nyct/gtfs-jz", "nyct/gtfs-l",
            "nyct/gtfs-nqrw", "nyct/gtfs-si", "camsys/subway-alerts.json", "nyct/nyct_ene.json",
        ])
        #expect(FeedRelay.feeds["nyct/gtfs-nqrw"] == Lines.feedURLs(sharingTracksWith: ["R"]).own.first)
    }

    @Test func appAsksForAnMTAFeedByName() throws {
        let server = try #require(URL(string: "https://api.example.com"))
        let feed = try #require(Lines.feedURLs(sharingTracksWith: ["R"]).own.first)
        #expect(TrainService.relayed(feed, via: server)?.absoluteString == "https://api.example.com/feeds?name=nyct/gtfs-nqrw")
        #expect(TrainService.relayed(AlertsFeed.url, via: server)?.absoluteString
            == "https://api.example.com/feeds?name=camsys/subway-alerts.json")
        // Nothing but the MTA's feeds
        #expect(TrainService.relayed(try #require(URL(string: "https://example.com/feed")), via: server) == nil)
    }

    @Test func asksForTheSameAreKeptAsOne() {
        typealias Ask = FeedRelay.Ask
        // Each feed cut only by what it can be
        #expect(FeedRelay.normalised(Ask(name: "nyct/gtfs-l", stops: ["L01N"], routes: ["L"], gzip: true))
            == Ask(name: "nyct/gtfs-l", stops: ["L01N"], gzip: true))
        #expect(FeedRelay.normalised(Ask(name: "camsys/subway-alerts.json", stops: ["L01N"], routes: ["L"]))
            == Ask(name: "camsys/subway-alerts.json", routes: ["L"]))
        #expect(FeedRelay.normalised(Ask(name: "nyct/nyct_ene.json", stops: ["L01N"], routes: ["L"]))
            == Ask(name: "nyct/nyct_ene.json"))
    }

    @Test func requestsNeverReadTheMTA() async throws {
        let mta = FakeMTA()
        let relay = FeedRelay(interval: 20) { await mta.read($0) }
        // Nothing till the first tick
        #expect(await relay.feed(named: "nyct/gtfs-nqrw") == nil)
        #expect(await mta.reads == 0)
        await relay.refresh()
        #expect(await mta.reads == FeedRelay.feeds.count)
        for _ in 0..<5 {
            #expect(await relay.feed(named: "nyct/gtfs-nqrw") != nil)
        }
        #expect(await mta.reads == FeedRelay.feeds.count)
    }

    @Test func keepsALastCopyOnlyForAWhile() async throws {
        let mta = FakeMTA()
        let relay = FeedRelay(interval: 20) { await mta.read($0) }
        let start = Date.now
        await relay.refresh(now: start)
        await mta.fail(true)
        // A tick whose read fails keeps the last copy, but only for two ticks and 10 s
        await relay.refresh(now: start.addingTimeInterval(20))
        #expect(await relay.feed(named: "nyct/gtfs-ace", now: start.addingTimeInterval(49)) != nil)
        #expect(await relay.feed(named: "nyct/gtfs-ace", now: start.addingTimeInterval(50)) == nil)
        #expect(await relay.feed(named: "../etc/passwd", now: start) == nil)
    }

    @Test func onlyAFeedIsTakenAsOne() throws {
        let nqrw = try #require(FeedRelay.feeds["nyct/gtfs-nqrw"])
        // A 200 with nothing, or no header, reads as a failed fetch, not as no trains
        #expect(!TrainService.isUsable(Data(), from: nqrw))
        #expect(!TrainService.isUsable(GTFSFeed.feed(made: nil, []), from: nqrw))
        #expect(TrainService.isUsable(GTFSFeed.feed([]), from: nqrw))
        #expect(!TrainService.isUsable(Data(), from: AlertsFeed.url))
        #expect(!TrainService.isUsable(Data("{\"entity\": [".utf8), from: AlertsFeed.url))
        #expect(TrainService.isUsable(Data("[]".utf8), from: OutagesFeed.url))
        // JSON by its ends, not parsed
        #expect(TrainService.isUsable(Data(" {\"entity\": []}\n".utf8), from: AlertsFeed.url))
        #expect(!TrainService.isUsable(Data("[{}".utf8), from: OutagesFeed.url))
        #expect(!TrainService.isUsable(Data("{".utf8), from: OutagesFeed.url))
        #expect(!TrainService.isUsable(Data("<html></html>".utf8), from: AlertsFeed.url))
        // What isn't an MTA feed is taken as it is
        #expect(TrainService.isUsable(Data(), from: try #require(URL(string: "https://example.com/x"))))
    }

    @Test func anEmptyReadKeepsTheLastCopy() async throws {
        let mta = FakeMTA()
        let relay = FeedRelay(interval: 20) { await mta.read($0) }
        let start = Date.now
        await relay.refresh(now: start)
        let first = await relay.feed(named: "nyct/gtfs-ace", now: start)
        #expect(first?.isEmpty == false)
        // A 200 with nothing in it isn't "no trains"
        await mta.answerEmpty(true)
        await relay.refresh(now: start.addingTimeInterval(20))
        #expect(await relay.feed(named: "nyct/gtfs-ace", now: start.addingTimeInterval(20)) == first)
        #expect(await relay.feed(named: "camsys/subway-alerts.json", now: start.addingTimeInterval(20))?.isEmpty == false)
        #expect(await relay.feed(named: "nyct/gtfs-ace", now: start.addingTimeInterval(50)) == nil)
    }

    @Test func countsAFeedsTrips() {
        #expect(SubwayFeed.tripCount(GTFSFeed.feed([])) == 0)
        let feed = GTFSFeed.feed([GTFSFeed.trip("R1", stops: [FeedStop("R34N", at: 3)]),
                                  GTFSFeed.vehicle("R1", at: "R34N", status: 1),
                                  GTFSFeed.trip("R2", stops: [FeedStop("R34N", at: 9)])])
        #expect(SubwayFeed.tripCount(feed) == 2)
        #expect(SubwayFeed.tripCount(feed.prefix(feed.count - 3)) == nil)
    }

    @Test func aFeedWithNoTripsKeepsTheLastCopyTillTheThirdInARow() async throws {
        let mta = FakeMTA()
        let relay = FeedRelay(interval: 20) { await mta.read($0) }
        let start = Date.now
        await relay.refresh(now: start)
        let first = try #require(await relay.feed(named: "nyct/gtfs-ace", now: start))
        #expect(SubwayFeed.tripCount(first) == 1)
        // As the MTA's feeds come back for a read or two during a restart: not "no trains" yet
        await mta.answerNoTrips(true)
        for tick in 1...2 {
            let at = start.addingTimeInterval(Double(tick) * 20)
            await relay.refresh(now: at)
            #expect(await relay.feed(named: "nyct/gtfs-ace", now: at) == first)
            // Held as this read, not aging out before the third: none would be served then
            #expect(await relay.feed(named: "nyct/gtfs-ace", now: at.addingTimeInterval(19)) == first)
        }
        // The third in a row is believed
        let third = start.addingTimeInterval(60)
        await relay.refresh(now: third)
        #expect(await relay.feed(named: "nyct/gtfs-ace", now: third).flatMap(SubwayFeed.tripCount) == 0)
        // And trips again start over
        await mta.answerNoTrips(false)
        await relay.refresh(now: start.addingTimeInterval(80))
        await mta.answerNoTrips(true)
        await relay.refresh(now: start.addingTimeInterval(100))
        #expect(await relay.feed(named: "nyct/gtfs-ace", now: start.addingTimeInterval(100)).flatMap(SubwayFeed.tripCount) == 1)
    }

    @Test func aSlowReadIsGivenUpOnWithoutHoldingBackTheOthers() async throws {
        let slow = try #require(FeedRelay.feeds["nyct/gtfs-ace"])
        let relay = FeedRelay(interval: 20, readTimeout: 0.2) { url in
            if url == slow { try? await Task.sleep(for: .seconds(30)) }
            return GTFSFeed.feed([GTFSFeed.trip(url.absoluteString, stops: [])])
        }
        let clock = ContinuousClock()
        let took = await clock.measure { await relay.refresh() }
        #expect(took < .seconds(10))
        #expect(await relay.feed(named: "nyct/gtfs-ace") == nil)
        #expect(await relay.feed(named: "nyct/gtfs-l") != nil)
    }

    @Test func manyDifferentCutsAtOnceAreEachServed() async throws {
        let feed = GTFSFeed.feed((0..<200).map { GTFSFeed.trip("R\($0)", stops: [FeedStop("R\($0)N", at: 3)]) })
        let relay = FeedRelay(interval: 20) { _ in feed }
        await relay.refresh()
        let gzippedWhole = try #require(await relay.served(FeedRelay.Ask(name: "nyct/gtfs-nqrw", gzip: true)))
        let served = await Concurrency.map(Array(0..<40), limit: 40) { index in
            await relay.served(FeedRelay.Ask(name: "nyct/gtfs-nqrw", stops: ["R\(index)N"], gzip: true))
        }
        // Each its own cut, or past the cuts allowed at once, the whole feed as already made
        #expect(served.count == 40)
        #expect(served.allSatisfy { $0?.gzipped == true })
        #expect(served.allSatisfy { $0.map { $0.data.count < gzippedWhole.data.count || $0.data == gzippedWhole.data } ?? false })
    }

    @Test func countdownsUseTheSameCopies() async throws {
        let nqrw = try #require(FeedRelay.feeds["nyct/gtfs-nqrw"])
        let feed = GTFSFeed.feed([GTFSFeed.trip("R1", stops: [FeedStop("R34N", at: 3), FeedStop("G08N", arrival: 40)])])
        let mta = FakeMTA()
        // Only the R's feed comes; the others it shares tracks with are optional
        let relay = FeedRelay(interval: 20) { url in
            _ = await mta.read(url)
            return url == nqrw ? feed : nil
        }
        let boards = Poller.liveBoards(from: relay)
        #expect(await boards([prospect], now).isEmpty)
        await relay.refresh(now: now)
        #expect(await boards([prospect, prospect], now)[prospect]?.trains.map(\.trip) == ["R1"])
        // Made from what was read at the tick, not read again
        #expect(await mta.reads == FeedRelay.feeds.count)
    }

    private func withApp(limits: Limits = testLimits(), relay: FeedRelay,
                         _ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        let services = HTTPServices(store: try Store(directory: nil), auth: .secret("test-secret-0123456789abcdef"),
                                    appID: testAppID, limits: limits, feeds: relay)
        try await Application(router: HTTPRoutes.router(services)).test(.router) { client in try await body(client) }
    }

    @Test func servesFeedsWithoutAuthentication() async throws {
        let mta = FakeMTA()
        let relay = FeedRelay(interval: 20) { await mta.read($0) }
        try await withApp(relay: relay) { client in
            // Before the first tick, the MTA down: the request's read gets nothing to pass on,
            // so the phone tries the MTA; the next within the tick doesn't read again
            await mta.fail(true)
            try await client.execute(uri: "/feeds?name=nyct/gtfs-l", method: .get) { #expect($0.status == .badGateway) }
            try await client.execute(uri: "/feeds?name=nyct/gtfs-l", method: .get) { #expect($0.status == .badGateway) }
            #expect(await mta.reads == FeedRelay.feeds.count)
            await mta.fail(false)
            await relay.refresh()
            try await client.execute(uri: "/feeds?name=nyct/gtfs-nqrw", method: .get) { response in
                #expect(response.status == .ok)
                #expect(text(response).contains("https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-nqrw"))
                #expect(response.headers[.cacheControl] == "no-store")
            }
            try await client.execute(uri: "/feeds?name=nyct%2Fgtfs-nqrw", method: .get) { #expect($0.status == .ok) }
            try await client.execute(uri: "/feeds", method: .get) { #expect($0.status == .badRequest) }
            try await client.execute(uri: "/feeds?name=https://example.com", method: .get) { #expect($0.status == .notFound) }
        }
        #expect(await mta.reads == 2 * FeedRelay.feeds.count)
    }

    @Test func alertsAndOutagesAreReadLessOftenAndKeptLongerToMatch() async throws {
        let reads = ReadCounts()
        let relay = FeedRelay(interval: 20) { url in
            await reads.add(url)
            if url == AlertsFeed.url || url == OutagesFeed.url { return Data("[]".utf8) }
            return GTFSFeed.feed([GTFSFeed.trip("R1", stops: [])])
        }
        let nqrw = try #require(FeedRelay.feeds["nyct/gtfs-nqrw"])
        let start = Date.now
        // Ticks a little off the 20 s still read each on its own
        for (tick, offset) in [0, -0.5, 0.5, -0.3, 0.2, 0.1, 0].enumerated() {
            await relay.refresh(now: start.addingTimeInterval(Double(tick) * 20 + offset))
        }
        #expect(await reads.of(nqrw) == 7)
        #expect(await reads.of(AlertsFeed.url) == 3)
        #expect(await reads.of(OutagesFeed.url) == 2)
        // Read a minute ago, still served; train feeds only for two ticks
        #expect(await relay.feed(named: "camsys/subway-alerts.json", now: start.addingTimeInterval(120 + 129)) != nil)
        #expect(await relay.feed(named: "camsys/subway-alerts.json", now: start.addingTimeInterval(120 + 130)) == nil)
        #expect(await relay.feed(named: "nyct/nyct_ene.json", now: start.addingTimeInterval(120 + 249)) != nil)
        #expect(await relay.maxAge(of: nqrw) == 50)
    }

    @Test func aFeedReadTheSameKeepsWhatWasMadeFromIt() async throws {
        let reads = ReadCounts()
        let relay = FeedRelay(interval: 20) { url in
            // Each train feed new each read, the alerts the same
            let count = await reads.add(url)
            if url == AlertsFeed.url || url == OutagesFeed.url { return Data("{\"entity\": []}".utf8) }
            return GTFSFeed.feed([GTFSFeed.trip("R\(count)", stops: [])])
        }
        let start = Date.now
        await relay.refresh(now: start)
        let alerts = FeedRelay.Ask(name: "camsys/subway-alerts.json", gzip: true)
        let trains = FeedRelay.Ask(name: "nyct/gtfs-nqrw", gzip: true)
        _ = await relay.served(alerts, now: start)
        let first = try #require(await relay.served(trains, now: start))
        #expect(await relay.madeCount == 2)
        await relay.refresh(now: start.addingTimeInterval(60))
        // The alerts' still made, and its copy read again; the train feed's to make again
        #expect(await relay.madeCount == 1)
        #expect(await relay.feed(named: "camsys/subway-alerts.json", now: start.addingTimeInterval(60 + 129)) != nil)
        let served = try #require(await relay.served(trains, now: start.addingTimeInterval(60)))
        #expect(served.data != first.data)
        #expect(await relay.madeCount == 2)
    }

    @Test func idleWithNoCountdownsTheFeedsArentReadTillAsked() async throws {
        let mta = FakeMTA()
        let relay = FeedRelay(interval: 20) { await mta.read($0) }
        let store = try Store(directory: nil)
        let start = Date.now
        #expect(await !Poller.wantsFeeds(store: store, feeds: relay, now: start))
        await relay.refresh(now: start)
        _ = await relay.served(FeedRelay.Ask(name: "nyct/gtfs-nqrw"), now: start)
        #expect(await Poller.wantsFeeds(store: store, feeds: relay, now: start.addingTimeInterval(FeedRelay.wantedFor - 1)))
        #expect(await !Poller.wantsFeeds(store: store, feeds: relay, now: start.addingTimeInterval(FeedRelay.wantedFor)))
        // A train countdown wants them whoever's asked
        _ = try await store.upsert(testRegistration(), maxTotal: 10, maxPerOwner: 5)
        #expect(await Poller.wantsFeeds(store: store, feeds: relay, now: start.addingTimeInterval(FeedRelay.wantedFor)))

        // The first ask after the idle spell, its copy gone: read then, and answered
        let later = start.addingTimeInterval(10 * 60)
        #expect(await relay.feed(named: "nyct/gtfs-nqrw", now: later) == nil)
        #expect(await relay.served(FeedRelay.Ask(name: "nyct/gtfs-nqrw"), now: later) != nil)
        #expect(await mta.reads == 2 * FeedRelay.feeds.count)
        // And the next not
        #expect(await relay.served(FeedRelay.Ask(name: "nyct/gtfs-l"), now: later.addingTimeInterval(1)) != nil)
        #expect(await mta.reads == 2 * FeedRelay.feeds.count)
    }

    @Test func feedsHaveARateLimitOfTheirOwn() async throws {
        var limits = testLimits()
        limits.requestsPerMinute = 1
        limits.requestBurst = 1
        limits.feedRequestsPerMinute = 3
        limits.feedRequestBurst = 3
        let relay = FeedRelay(interval: 20) { _ in GTFSFeed.feed([]) }
        await relay.refresh()
        try await withApp(limits: limits, relay: relay) { client in
            for _ in 0..<3 {
                try await client.execute(uri: "/feeds?name=nyct/gtfs", method: .get) { #expect($0.status == .ok) }
            }
            try await client.execute(uri: "/feeds?name=nyct/gtfs", method: .get) { #expect($0.status == .tooManyRequests) }
            // Feeds use none of the other routes' limit
            try await client.execute(uri: "/health", method: .get) { #expect($0.status == .ok) }
            try await client.execute(uri: "/health", method: .get) { #expect($0.status == .tooManyRequests) }
        }
    }
}
