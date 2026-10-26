import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import TrainCore

/// Counts reads of the MTA, answering each with the feed's address, or nothing when `failing`.
private actor FakeMTA {
    var reads = 0
    var failing = false

    func read(_ url: URL) -> Data? {
        reads += 1
        return failing ? nil : Data(url.absoluteString.utf8)
    }

    func fail(_ failing: Bool) { self.failing = failing }
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
            // Before the first tick: nothing to pass on, so the phone tries the MTA
            try await client.execute(uri: "/feeds?name=nyct/gtfs-l", method: .get) { #expect($0.status == .badGateway) }
            await relay.refresh()
            try await client.execute(uri: "/feeds?name=nyct/gtfs-nqrw", method: .get) { response in
                #expect(response.status == .ok)
                #expect(text(response) == "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-nqrw")
                #expect(response.headers[.cacheControl] == "no-store")
            }
            try await client.execute(uri: "/feeds?name=nyct%2Fgtfs-nqrw", method: .get) { #expect($0.status == .ok) }
            try await client.execute(uri: "/feeds", method: .get) { #expect($0.status == .badRequest) }
            try await client.execute(uri: "/feeds?name=https://example.com", method: .get) { #expect($0.status == .notFound) }
        }
        #expect(await mta.reads == FeedRelay.feeds.count)
    }

    @Test func feedsHaveARateLimitOfTheirOwn() async throws {
        var limits = testLimits()
        limits.requestsPerMinute = 1
        limits.requestBurst = 1
        limits.feedRequestsPerMinute = 3
        limits.feedRequestBurst = 3
        let relay = FeedRelay(interval: 20) { _ in Data() }
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
