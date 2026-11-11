import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import TrainCore

/// Three docks round 4 Av/9 St, one not renting, and one GBFS has no place for.
private let information = """
{"data":{"stations":[
 {"station_id":"a","name":"4 Av & 9 St","lat":40.6700,"lon":-73.9880},
 {"station_id":"b","name":"5 Av & 9 St","lat":40.6710,"lon":-73.9860},
 {"station_id":"c","name":"Far Away","lat":40.7500,"lon":-73.9900}
]}}
"""

private let status = """
{"data":{"stations":[
 {"station_id":"a","num_bikes_available":5,"num_ebikes_available":2,"num_docks_available":10,"is_installed":1,"is_renting":1,"is_returning":1},
 {"station_id":"b","num_bikes_available":3,"num_ebikes_available":0,"num_docks_available":4,"is_installed":1,"is_renting":0,"is_returning":1},
 {"station_id":"c","num_bikes_available":8,"num_ebikes_available":8,"num_docks_available":1,"is_installed":1,"is_renting":1,"is_returning":1},
 {"station_id":"new","num_bikes_available":1,"num_ebikes_available":0,"num_docks_available":1,"is_installed":1,"is_renting":1,"is_returning":1}
]}}
"""

/// GBFS's answers by file, counting what's asked.
private actor FakeGBFS {
    var asked: [String: Int] = [:]
    var failing = false

    func answer(_ request: URLRequest) -> (Data, Int) {
        let name = request.url?.lastPathComponent ?? ""
        asked[name, default: 0] += 1
        if failing { return (Data(), 503) }
        return (Data((name == "station_status.json" ? status : information).utf8), 200)
    }

    func fail(_ failing: Bool = true) { self.failing = failing }
}

/// A clock tests move on.
private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_793_000_000)
}

@Suite struct CitiBikeDocksTests {
    private func docks(_ gbfs: FakeGBFS, _ clock: Clock = Clock()) -> CitiBikeDocks {
        CitiBikeDocks(fetch: { await gbfs.answer($0) }, now: { clock.now })
    }

    @Test func nearestFirstWithinRangeByWhatTheyHave() async throws {
        let gbfs = FakeGBFS()
        let docks = docks(gbfs)
        let here = (40.6700, -73.9880)
        let any = try #require(await docks.nearest(to: here, limit: 5, within: 800, has: .any))
        #expect(any.map(\.id) == ["a", "b"])
        #expect(any[0].bikes == 3 && any[0].eBikes == 2 && any[0].name == "4 Av & 9 St")
        // b isn't renting: no bikes to take there
        #expect(await docks.nearest(to: here, limit: 5, within: 800, has: .bike)?.map(\.id) == ["a"])
        #expect(await docks.nearest(to: here, limit: 5, within: 800, has: .service)?.map(\.id) == ["a", "b"])
        #expect(await docks.nearest(to: here, limit: 1, within: 800, has: .any)?.map(\.id) == ["a"])
        #expect(await docks.docks(ids: ["c", "zzz", "a"])?.map(\.id) == ["c", "a"])
    }

    @Test func readsTheCityOnceAWhileHoweverManyAsk() async throws {
        let gbfs = FakeGBFS(), clock = Clock()
        let docks = docks(gbfs, clock)
        let here = (40.6700, -73.9880)
        async let first = docks.nearest(to: here, limit: 5, within: 800, has: .any)
        async let second = docks.nearest(to: here, limit: 5, within: 800, has: .any)
        _ = await (first, second)
        _ = await docks.docks(ids: ["a"])
        #expect(await gbfs.asked["station_status.json"] == 1)
        #expect(await gbfs.asked["station_information.json"] == 1)

        clock.now += CitiBikeDocks.countsLifetime
        _ = await docks.docks(ids: ["a"])
        #expect(await gbfs.asked["station_status.json"] == 2)
        // The unplaced dock reads the places again, but only once `newDockWait`'s gone by
        #expect(await gbfs.asked["station_information.json"] == 1)
        clock.now += CitiBikeDocks.newDockWait
        _ = await docks.docks(ids: ["a"])
        #expect(await gbfs.asked["station_information.json"] == 2)

        // Failing, the last counts
        await gbfs.fail()
        clock.now += CitiBikeDocks.countsLifetime
        #expect(await docks.docks(ids: ["a"])?.map(\.id) == ["a"])
        #expect(await gbfs.asked["station_status.json"] == 4)
        // And not asked again on every request meanwhile, but once `countsFailedWait`'s gone by
        clock.now += 5
        #expect(await docks.docks(ids: ["a"])?.map(\.id) == ["a"])
        #expect(await gbfs.asked["station_status.json"] == 4)
        clock.now += CitiBikeDocks.countsFailedWait
        _ = await docks.docks(ids: ["a"])
        #expect(await gbfs.asked["station_status.json"] == 5)
    }

    @Test func readsWhereTheDocksAreOnceHoweverManyAskAndWaitsAfterAFailure() async throws {
        let gbfs = FakeGBFS(), clock = Clock()
        let docks = docks(gbfs, clock)
        async let first = docks.everyPlaceAnswer()
        async let second = docks.everyPlaceAnswer()
        let (one, two) = await (first, second)
        #expect(one?.etag != nil && one?.etag == two?.etag)
        #expect(await gbfs.asked["station_information.json"] == 1)

        // A day on, Citi Bike down: the last copy, the same answer, and not asked again for a while
        await gbfs.fail()
        clock.now += CitiBikeDocks.placesLifetime
        #expect(await docks.everyPlaceAnswer()?.etag == one?.etag)
        clock.now += 60
        #expect(await docks.everyPlaceAnswer()?.etag == one?.etag)
        #expect(await gbfs.asked["station_information.json"] == 2)
        await gbfs.fail(false)
        clock.now += CitiBikeDocks.placesFailedWait
        // Read again, the same places: the same tag
        #expect(await docks.everyPlaceAnswer()?.etag == one?.etag)
        #expect(await gbfs.asked["station_information.json"] == 3)
    }

    @Test func servedByTheRoute() async throws {
        let gbfs = FakeGBFS()
        let services = HTTPServices(store: try Store(directory: nil), auth: .secret("test-secret-0123456789abcdef"),
                                    appID: testAppID, limits: testLimits(), docks: docks(gbfs))
        try await Application(router: HTTPRoutes.router(services)).test(.router) { client in
            struct Answer: Decodable { var docks: [CitiBikeDocks.Dock] }
            try await client.execute(uri: "/docks?at=40.6700,-73.9880&limit=5&has=bike", method: .get) { response in
                #expect(response.status == .ok)
                let answer = try JSONDecoder().decode(Answer.self, from: Data(buffer: response.body))
                #expect(answer.docks.map(\.id) == ["a"])
            }
            try await client.execute(uri: "/docks?ids=b,a", method: .get) { response in
                let answer = try JSONDecoder().decode(Answer.self, from: Data(buffer: response.body))
                #expect(answer.docks.map(\.id) == ["b", "a"])
            }
            let etag = try await client.execute(uri: "/docks?places=1", method: .get) { response in
                let answer = try JSONDecoder().decode(Answer.self, from: Data(buffer: response.body))
                #expect(answer.docks.map(\.id) == ["a", "b", "c"])
                #expect(response.headers[.cacheControl] == "max-age=3600")
                return try #require(response.headers[.eTag])
            }
            // A phone with them: nothing to download
            try await client.execute(uri: "/docks?places=1", method: .get, headers: [.ifNoneMatch: etag]) { response in
                #expect(response.status == .notModified)
                #expect(response.body.readableBytes == 0)
            }
            try await client.execute(uri: "/docks?places=1", method: .get, headers: [.ifNoneMatch: "\"old\""]) {
                #expect($0.status == .ok)
            }
            for bad in ["/docks", "/docks?at=1,2", "/docks?at=40.67,-73.98&limit=50", "/docks?at=40.67,-73.98&has=car",
                        "/docks?at=40.67,-73.98&within=9000", "/docks?ids=a%2Fb"] {
                try await client.execute(uri: bad, method: .get) { #expect($0.status == .badRequest, "\(bad)") }
            }
        }
    }
}

/// GBFS answering with `status` for the counts and `information`'s places.
private actor StatusGBFS {
    let status: String
    init(_ status: String) { self.status = status }

    func answer(_ request: URLRequest) -> (Data, Int) {
        (Data((request.url?.lastPathComponent == "station_status.json" ? status : information).utf8), 200)
    }
}

/// Docks silent too long, and counts below none.
@Suite struct CitiBikeDocksStaleTests {
    private func read(_ status: String, at clock: Clock = Clock()) async throws -> [String: CitiBikeDocks.Dock] {
        let gbfs = StatusGBFS(status)
        let docks = CitiBikeDocks(fetch: { await gbfs.answer($0) }, now: { clock.now })
        let found = try #require(await docks.docks(ids: ["a", "b", "c"]))
        return Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
    }

    @Test func dockSilentOverHalfAnHourIsOutOfService() async throws {
        let now = Int(Clock().now.timeIntervalSince1970)
        let status = """
        {"data":{"stations":[
         {"station_id":"a","num_bikes_available":5,"num_docks_available":5,"is_installed":1,"is_renting":1,"is_returning":1,"last_reported":\(now - 31 * 60)},
         {"station_id":"b","num_bikes_available":5,"num_docks_available":5,"is_installed":1,"is_renting":1,"is_returning":1,"last_reported":\(now - 29 * 60).0},
         {"station_id":"c","num_bikes_available":5,"num_docks_available":5,"is_installed":1,"is_renting":1,"is_returning":1}
        ]}}
        """
        let byID = try await read(status)
        let stale = try #require(byID["a"])
        #expect(!stale.renting && !stale.returning && stale.lastReported == now - 31 * 60)
        #expect(byID["b"]?.renting == true && byID["b"]?.returning == true && byID["b"]?.lastReported == now - 29 * 60)
        // Not said: as before
        #expect(byID["c"]?.renting == true && byID["c"]?.lastReported == nil)
        #expect(!CitiBikeDocks.Has.service.admits(stale) && CitiBikeDocks.Has.any.admits(stale))
    }

    @Test func zeroOrAbsurdReportIsNotSaid() async throws {
        let status = """
        {"data":{"stations":[
         {"station_id":"a","num_bikes_available":5,"is_installed":1,"is_renting":1,"is_returning":1,"last_reported":0},
         {"station_id":"b","num_bikes_available":5,"is_installed":1,"is_renting":1,"is_returning":1,"last_reported":1e300}
        ]}}
        """
        let byID = try await read(status)
        #expect(byID["a"]?.renting == true && byID["b"]?.renting == true && byID["b"]?.lastReported == nil)
    }

    @Test func countsNeverBelowNone() async throws {
        let status = """
        {"data":{"stations":[
         {"station_id":"a","num_bikes_available":5,"num_ebikes_available":-3,"num_docks_available":-2,"is_installed":1,"is_renting":1,"is_returning":1}
        ]}}
        """
        let dock = try #require(try await read(status)["a"])
        #expect(dock.bikes == 5 && dock.eBikes == 0 && dock.docks == 0)
    }

    @Test func lastReportedLeftOutWhereNotSaid() throws {
        var dock = CitiBikeDocks.Dock(id: "a", name: "A", lat: 40.7, lon: -74, bikes: 1, eBikes: 0, docks: 1,
                                      renting: true, returning: true)
        #expect(!String(decoding: try JSONEncoder().encode(dock), as: UTF8.self).contains("lastReported"))
        dock.lastReported = 1_793_000_000
        #expect(String(decoding: try JSONEncoder().encode(dock), as: UTF8.self).contains("\"lastReported\":1793000000"))
    }
}
