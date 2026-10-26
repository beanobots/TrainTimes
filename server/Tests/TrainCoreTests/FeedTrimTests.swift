import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import TrainCore

/// Cutting feeds to what a phone reads, and gzipping them, so phones with little signal below
/// ground download less (`GET /feeds?stops=…&routes=…`).
@Suite struct FeedTrimTests {
    /// An R through Prospect Av (R34N), another that turns short of it, an N elsewhere, and
    /// each one's position.
    let feed = GTFSFeed.feed([
        GTFSFeed.trip("R1", stops: [FeedStop("R35N", at: 1), FeedStop("R34N", at: 3), FeedStop("R33N", at: 5)]),
        GTFSFeed.vehicle("R1", at: "R35N", status: 1),
        GTFSFeed.trip("R2", stops: [FeedStop("R41N", at: 2), FeedStop("R40N", at: 4)]),
        GTFSFeed.vehicle("R2", at: "R41N", status: nil),
        GTFSFeed.trip("N1", route: "N", stops: [FeedStop("R20N", at: 6)]),
        GTFSFeed.vehicle("N1", route: "N", at: "R20N", status: nil),
    ])

    @Test func keepsOnlyTripsCallingAtTheStopsAndTheirPositions() throws {
        let trimmed = try SubwayFeed.trimmed(feed, toStops: ["R34N", "R20N"])
        #expect(trimmed.count < feed.count)
        // The same arrivals as the whole feed has, positions and all
        for stops: Set<String> in [["R34N"], ["R20N"], ["R34N", "R20N"]] {
            #expect(try SubwayFeed.arrivals(at: stops, in: trimmed, now: now) == SubwayFeed.arrivals(at: stops, in: feed, now: now))
        }
        #expect(try SubwayFeed.arrivals(at: ["R34N"], in: trimmed, now: now).first?.position?.stop == "R35N")
        // The header, so its age still counts
        #expect(SubwayFeed.made(trimmed) == SubwayFeed.made(feed))
        // Not the trip that doesn't call there, nor its position
        #expect(try SubwayFeed.arrivals(at: ["R41N"], in: trimmed, now: now).isEmpty)
        #expect(try SubwayFeed.trimmed(feed, toStops: ["R41N"]).count < feed.count)
        // No stops: just the header
        #expect(try SubwayFeed.arrivals(at: ["R34N", "R41N", "R20N"], in: SubwayFeed.trimmed(feed, toStops: []), now: now).isEmpty)
    }

    @Test func trimmingAMalformedFeedThrows() {
        #expect(throws: FeedError.self) { try SubwayFeed.trimmed(Data([0x12, 0x40, 0x01]), toStops: ["R34N"]) }
    }

    /// An alert in the alerts feed's JSON, in effect from `start` to `end` minutes from now.
    func alert(_ id: String, informed: String = #"{"route_id":"R"}"#, affected: String? = nil,
               from start: Int = -60, to end: Int = 60) -> String {
        let seconds = { (minutes: Int) in Int(now.timeIntervalSince1970) + minutes * 60 }
        let mercury = affected.map { #","transit_realtime.mercury_alert":{"alert_type":"Delays","affected_stations":[\#($0)]}"# } ?? ""
        return """
            {"id":"\(id)","alert":{"active_period":[{"start":\(seconds(start)),"end":\(seconds(end))}],
            "informed_entity":[\(informed)],"header_text":{"translation":[{"text":"[R] trains are delayed.","language":"en"}]}\(mercury)}}
            """
    }

    @Test func keepsOnlyAlertsForTheRoutesInEffectAroundNow() throws {
        let entities = [
            alert("r"),
            alert("n", informed: #"{"route_id":"N"}"#),
            alert("rFurtherAlong", informed: #"{"route_id":"N"}"#, affected: #"{"route_id":"R","stop_id":"R34"}"#),
            alert("rLater", from: 300, to: 400),
            alert("si", informed: #"{"route_id":"SIR"}"#),
            #"{"id":"notAnAlert"}"#,
        ].joined(separator: ",")
        let alerts = Data((#"{"header":{"gtfs_realtime_version":"1.0"},"entity":["# + entities + "]}").utf8)
        let trimmed = try AlertsFeed.trimmed(alerts, toRoutes: ["R", "SI"], activeFrom: now.addingTimeInterval(-15 * 60),
                                             to: now.addingTimeInterval(2 * 60 * 60))
        #expect(trimmed.count < alerts.count)
        let ids = { (data: Data) in try AlertsFeed.alerts(for: prospect, in: AlertsFeed.entries(in: data, now: now), now: now).map(\.id) }
        #expect(try ids(trimmed) == ids(alerts))
        #expect(try ids(trimmed).sorted() == ["r", "rFurtherAlong"])
        // Staten Island's, under the feed's "SIR"
        #expect(try AlertsFeed.entries(in: trimmed, now: now).count == 3)
    }

    @Test func gzipsAsGzipReadsIt() throws {
        let data = Data(String(repeating: "R34N R33N R32N ", count: 200).utf8)
        let gzipped = try Gzip.compress(data)
        #expect(gzipped.count < data.count / 4)
        #expect(Array(gzipped.prefix(3)) == [0x1f, 0x8b, 8])
        #expect(try unzipped(gzipped) == data)
        // The check value gzip's trailer has for "123456789"
        #expect(Gzip.crc32(Data("123456789".utf8)) == 0xcbf4_3926)
    }

    @Test func gzipOnlyWhenAccepted() {
        #expect(Gzip.isAccepted(by: "gzip, deflate, br"))
        #expect(Gzip.isAccepted(by: "br;q=1.0, gzip;q=0.8, *;q=0.1"))
        #expect(Gzip.isAccepted(by: "*"))
        #expect(!Gzip.isAccepted(by: nil))
        #expect(!Gzip.isAccepted(by: "br, deflate"))
        #expect(!Gzip.isAccepted(by: "gzip;q=0"))
    }

    @Test func appAsksForJustWhatItReads() throws {
        let server = try #require(URL(string: "https://api.example.com"))
        let feed = try #require(Lines.feedURLs(sharingTracksWith: ["R"]).own.first)
        #expect(TrainService.relayed(feed, via: server, for: .init(stops: ["R34N", "R20S"]))?.absoluteString
            == "https://api.example.com/feeds?name=nyct/gtfs-nqrw&stops=R20S,R34N")
        #expect(TrainService.relayed(AlertsFeed.url, via: server, for: .init(routes: ["R", "N"]))?.absoluteString
            == "https://api.example.com/feeds?name=camsys/subway-alerts.json&routes=N,R")
    }

    @Test func servesJustThoseStopsGzipped() async throws {
        let whole = feed
        let relay = FeedRelay(interval: 20) { _ in whole }
        await relay.refresh()
        let services = HTTPServices(store: try Store(directory: nil), auth: .secret("test-secret-0123456789abcdef"),
                                    appID: testAppID, limits: testLimits(), feeds: relay)
        try await Application(router: HTTPRoutes.router(services)).test(.router) { client in
            try await client.execute(uri: "/feeds?name=nyct/gtfs-nqrw&stops=R34N", method: .get,
                                     headers: [.acceptEncoding: "gzip, deflate, br"]) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentEncoding] == "gzip")
                #expect(response.headers[.vary] == "Accept-Encoding")
                let body = try unzipped(Data(response.body.readableBytesView))
                #expect(try body == SubwayFeed.trimmed(whole, toStops: ["R34N"]))
            }
            // Without Accept-Encoding, as it was
            try await client.execute(uri: "/feeds?name=nyct/gtfs-nqrw", method: .get) { response in
                #expect(response.headers[.contentEncoding] == nil)
                #expect(Data(response.body.readableBytesView) == whole)
            }
            for bad in ["stops=R34N;drop", "stops=" + String(repeating: "R", count: 9), "routes=%20"] {
                try await client.execute(uri: "/feeds?name=nyct/gtfs-nqrw&\(bad)", method: .get) {
                    #expect($0.status == .badRequest)
                }
            }
        }
    }

    /// `gzipped`'s contents, read past gzip's header and trailer as gzip does, checked against
    /// the trailer.
    private func unzipped(_ gzipped: Data) throws -> Data {
        let deflated = gzipped.dropFirst(10).dropLast(8)
        let data = try (Data(deflated) as NSData).decompressed(using: .zlib) as Data
        let trailer = Array(gzipped.suffix(8))
        let word = { (at: Int) in (0..<4).reduce(UInt32(0)) { $0 | UInt32(trailer[at + $1]) << ($1 * 8) } }
        #expect(word(0) == Gzip.crc32(data))
        #expect(Int(word(4)) == data.count)
        return data
    }
}
