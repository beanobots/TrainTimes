import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import TrainCore

/// Bus Time's stops near 4 Av/9 St, as MTA Bus Time gives them, routes inline: the B63 both
/// ways, and the B61 round the corner.
private let mtaStops = """
{"code":200,"currentTime":1793000000000,"data":{"limitExceeded":false,"stops":[
 {"code":"308209","direction":"NE","id":"MTA_308209","lat":40.6697,"lon":-73.9877,"locationType":0,"name":"4 AV/9 ST",
  "routes":[{"id":"MTA NYCT_B63","shortName":"B63","agency":{"id":"MTA NYCT"}}],"wheelchairBoarding":"UNKNOWN"},
 {"code":"308210","direction":"SW","id":"MTA_308210","lat":40.6699,"lon":-73.9874,"name":"4 AV/9 ST",
  "routes":[{"id":"MTA NYCT_B63","shortName":"B63"}]},
 {"code":"301234","direction":"E","id":"MTA_301234","lat":40.66974,"lon":-73.98768,"name":"9 ST/4 AV",
  "routes":[{"id":"MTA NYCT_B61","shortName":"B61"}]}
]},"text":"OK","version":2}
"""

/// The same as other OneBusAway servers give them: a list, with route ids and references.
private let obaStops = """
{"code":200,"data":{"list":[
 {"code":"308209","direction":"NE","id":"MTA_308209","lat":40.6697,"lon":-73.9877,"name":"4 AV/9 ST",
  "routeIds":["MTA NYCT_B63","MTA NYCT_M15+"]}
],"references":{"routes":[{"id":"MTA NYCT_B63","shortName":"B63"}]}}}
"""

/// Where Google has a B63 ride board, a few meters from 308209.
private let boarding = (40.66975, -73.98768)

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// SIRI version 2's answer, names as lists: a bus 12 minutes off, one approaching, and one yet
/// to leave its terminal, out of order.
private func siri(now: Date) -> String {
    """
    {"Siri":{"ServiceDelivery":{"ResponseTimestamp":"\(iso(now))","StopMonitoringDelivery":[{"MonitoredStopVisit":[
     {"MonitoredVehicleJourney":{"LineRef":"MTA NYCT_B63","PublishedLineName":["B63"],
      "DestinationName":["BAY RIDGE SHORE RD via 5 AV"],
      "MonitoredCall":{"ExpectedArrivalTime":"\(iso(now + 720))","AimedArrivalTime":"\(iso(now + 600))",
       "ArrivalProximityText":"1.4 miles away","NumberOfStopsAway":9,"StopPointRef":"MTA_308209"}},
      "RecordedAtTime":"\(iso(now))"},
     {"MonitoredVehicleJourney":{"PublishedLineName":["B63"],"DestinationName":["BAY RIDGE SHORE RD via 5 AV"],
      "MonitoredCall":{"ExpectedArrivalTime":"\(iso(now + 185))","ArrivalProximityText":"approaching","NumberOfStopsAway":0}}},
     {"MonitoredVehicleJourney":{"PublishedLineName":["B63"],"DestinationName":["BAY RIDGE SHORE RD via 5 AV"],
      "MonitoredCall":{"AimedArrivalTime":"\(iso(now + 1500))"}}}
    ]}]}}}
    """
}

/// Bus Time's answers by path, counting what's asked.
private actor FakeBusTime {
    var stops = mtaStops
    var arrivals: String
    var status = 200
    private(set) var asked: [String] = []

    init(now: Date) { arrivals = siri(now: now) }

    func answer(_ request: URLRequest) -> (Data, Int) {
        let path = request.url?.path ?? ""
        asked.append(path)
        return (Data((path.contains("stop-monitoring") ? arrivals : stops).utf8), status)
    }

    func set(status: Int) { self.status = status }
    func count(_ part: String) -> Int { asked.filter { $0.contains(part) }.count }
}

@Suite struct BusTimeTests {
    let now = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func readsLinesNamesTheWayBothNameThem() {
        #expect(BusTime.canonical("B63") == "B63")
        #expect(BusTime.canonical("bx12") == "BX12")
        #expect(BusTime.canonical("M15-SBS") == "M15+")
        #expect(BusTime.canonical("M15 SBS") == "M15+")
        #expect(BusTime.canonical("M15+") == "M15+")
        #expect(BusTime.validLine(" B63 ") == "B63")
        #expect(BusTime.validLine("SIM1C") == "SIM1C")
        for bad in ["", "  ", "B63&key=x", "B63/1", "ABCDEFGHIJKLMNOPQ", "Б63", "-"] {
            #expect(BusTime.validLine(bad) == nil, "\(bad)")
        }
    }

    @Test func readsStopsEitherWayAndPicksTheNearestOnTheLine() throws {
        let mta = try #require(BusTime.candidates(in: Data(mtaStops.utf8)))
        #expect(mta.count == 3)
        #expect(mta[0].stop == BusTime.Stop(id: "308209", name: "4 AV/9 ST", latitude: 40.6697, longitude: -73.9877,
                                            direction: "NE"))
        #expect(mta[0].lines == [BusTime.Candidate.Line(ref: "MTA NYCT_B63", name: "B63")])
        let oba = try #require(BusTime.candidates(in: Data(obaStops.utf8)))
        // One named in the references, one not, known by its id
        #expect(oba[0].lines == [BusTime.Candidate.Line(ref: "MTA NYCT_B63", name: "B63"),
                                 BusTime.Candidate.Line(ref: "MTA NYCT_M15+", name: "M15+")])
        #expect(BusTime.nearest(serving: "M15+", to: boarding, in: oba)?.lineRef == "MTA NYCT_M15+")

        // The B61's stop is nearer, but isn't the B63's; of the two that are, the nearer
        let found = try #require(BusTime.nearest(serving: "B63", to: boarding, in: mta))
        #expect(found.stop.id == "308209")
        #expect(found.lineRef == "MTA NYCT_B63")
        #expect(BusTime.nearest(serving: "B61", to: boarding, in: mta)?.stop.id == "301234")
        // Too far, or no such line
        #expect(BusTime.nearest(serving: "B63", to: (40.6740, -73.9877), in: mta) == nil)
        #expect(BusTime.nearest(serving: "B67", to: boarding, in: mta) == nil)
        // An error, or not OneBusAway's at all
        #expect(BusTime.candidates(in: Data(#"{"code":401,"text":"permission denied","data":null}"#.utf8)) == nil)
        #expect(BusTime.candidates(in: Data("nope".utf8)) == nil)
    }

    @Test func readsArrivalsSoonestFirstFromEitherVersion() throws {
        let buses = try #require(BusTime.arrivals(in: Data(siri(now: now).utf8)))
        #expect(buses.map(\.distance) == ["approaching", "1.4 miles away", nil])
        #expect(buses[0].line == "B63")
        #expect(buses[0].destination == "BAY RIDGE SHORE RD via 5 AV")
        #expect(buses[0].stopsAway == 0)
        #expect(buses[1].expected.map { $0.timeIntervalSince(now).rounded() } == 720)
        #expect(buses[1].aimed.map { $0.timeIntervalSince(now).rounded() } == 600)
        // Only the timetable's time for a bus at its terminal
        #expect(buses[2].expected == nil)
        #expect(buses[2].aimed.map { $0.timeIntervalSince(now).rounded() } == 1500)

        let version1 = """
            {"Siri":{"ServiceDelivery":{"StopMonitoringDelivery":[{"MonitoredStopVisit":[
             {"MonitoredVehicleJourney":{"PublishedLineName":"B63","DestinationName":"FT GREENE",
              "MonitoredCall":{"ExpectedArrivalTime":"2026-10-25T15:52:10-04:00",
               "Extensions":{"Distances":{"PresentableDistance":"2 stops away","StopsFromCall":2}}}}}
            ]}]}}}
            """
        let old = try #require(BusTime.arrivals(in: Data(version1.utf8)))
        #expect(old == [BusTime.Arrival(line: "B63", destination: "FT GREENE",
                                        expected: ISO8601DateFormatter().date(from: "2026-10-25T19:52:10Z"),
                                        aimed: nil, stopsAway: 2, distance: "2 stops away")])

        // No buses just now is none; an error is no answer
        let none = #"{"Siri":{"ServiceDelivery":{"StopMonitoringDelivery":[{"MonitoredStopVisit":[]}]}}}"#
        #expect(BusTime.arrivals(in: Data(none.utf8)) == [])
        let error = #"{"Siri":{"ServiceDelivery":{"StopMonitoringDelivery":[{"ErrorCondition":{"OtherError":{"ErrorText":"No such stop"}}}]}}}"#
        #expect(BusTime.arrivals(in: Data(error.utf8)) == nil)
        #expect(BusTime.arrivals(in: Data("nope".utf8)) == nil)
    }

    @Test func escapesThePlusOfSelectBusService() throws {
        let request = BusTime.arrivalsRequest(stop: "401234", lineRef: "MTA NYCT_M15+", key: "k")
        let query = try #require(request.url?.query)
        #expect(query.contains("LineRef=MTA%20NYCT_M15%2B"))
        #expect(query.contains("MonitoringRef=401234"))
        #expect(query.contains("version=2"))
        #expect(request.url?.host == BusTime.base.host)
        let stops = try #require(BusTime.stopsRequest(near: boarding, key: "k").url)
        #expect(stops.path == "/api/where/stops-for-location.json")
        #expect(stops.query?.contains("lat=40.66975") == true)
    }

    @Test func keepsTheStopForADayAndArrivalsForThirtySeconds() async throws {
        let fake = FakeBusTime(now: now)
        let buses = BusTime(key: "k") { await fake.answer($0) }
        guard case .arrivals(let first) = await buses.arrivals(line: "B63", near: boarding, client: "a", now: now) else {
            Issue.record("expected arrivals"); return
        }
        #expect(first.stop.id == "308209")
        #expect(first.arrivals.count == 3)
        // Asked again soon, and by the line's other name for it: nothing more of Bus Time
        _ = await buses.arrivals(line: "b63", near: boarding, client: "a", now: now + 20)
        #expect(await fake.count("stops-for-location") == 1)
        #expect(await fake.count("stop-monitoring") == 1)
        // Then its buses again, from the stop it has, leaving out the one that's gone
        guard case .arrivals(let later) = await buses.arrivals(line: "B63", near: boarding, client: "a", now: now + 300) else {
            Issue.record("expected arrivals"); return
        }
        #expect(await fake.count("stops-for-location") == 1)
        #expect(await fake.count("stop-monitoring") == 2)
        #expect(later.arrivals.count == 2)
    }

    @Test func noStopIsKeptAndBusTimeFailingIsUnavailable() async {
        let fake = FakeBusTime(now: now)
        let buses = BusTime(key: "k") { await fake.answer($0) }
        #expect(await buses.arrivals(line: "B67", near: boarding, client: "a", now: now) == .noStop)
        #expect(await buses.arrivals(line: "B67", near: boarding, client: "a", now: now + 60) == .noStop)
        #expect(await fake.count("stops-for-location") == 1)

        await fake.set(status: 500)
        #expect(await buses.arrivals(line: "B63", near: boarding, client: "a", now: now) == .unavailable)
        let unreachable = BusTime(key: "k") { _ in throw URLError(.notConnectedToInternet) }
        #expect(await unreachable.arrivals(line: "B63", near: boarding, client: "a", now: now) == .unavailable)
    }

    @Test func readsWhichWaysAreOpposite() {
        #expect(BusTime.opposite("NE", "SW"))
        #expect(BusTime.opposite("N", "SE"))
        #expect(!BusTime.opposite("N", "E"))
        #expect(!BusTime.opposite("S", "s"))
        #expect(BusTime.opposite(nil, "S"))
    }

    @Test func placesPairEachStopWithTheOneAcrossThenTheNextLines() throws {
        let stops = try #require(BusTime.candidates(in: Data(mtaStops.utf8)))
        // The B63 both ways, then the B61's stop, whose line the first place hasn't
        let places = BusTime.places(near: (40.6697, -73.9877), in: stops)
        #expect(places.map { $0.map(\.stop.id) } == [["308209", "308210"], ["301234"]])
        #expect(places[0][0].meters < 1)
        // Only as many as asked for
        #expect(BusTime.places(near: (40.6697, -73.9877), in: stops, limit: 1).count == 1)
        // A place whose lines a nearer one has is left out: the B63 again, one stop on
        var again = stops
        again.append(BusTime.Candidate(stop: BusTime.Stop(id: "308300", name: "5 AV/7 ST", latitude: 40.6712, longitude: -73.9866,
                                                           direction: "NE"),
                                       lines: [BusTime.Candidate.Line(ref: "MTA NYCT_B63", name: "B63")]))
        #expect(!BusTime.places(near: (40.6697, -73.9877), in: again).flatMap { $0.map(\.stop.id) }.contains("308300"))
        // A kilometer off, none
        #expect(BusTime.places(near: (40.6787, -73.9877), in: stops).isEmpty)
    }

    @Test func nearbyAsksForEveryLineAtEachStopAndKeepsTheArea() async throws {
        let fake = FakeBusTime(now: now)
        let buses = BusTime(key: "k") { await fake.answer($0) }
        let places = try await buses.nearbyPlaces((40.6697, -73.9877), client: "a", now: now)
        // In order, though asked of Bus Time together
        #expect(places.map { $0.map(\.stop.id) } == [["308209", "308210"], ["301234"]])
        #expect(places.joined().allSatisfy { $0.arrivals.count == 3 })
        #expect(await fake.count("stop-monitoring") == 3)
        // Moved a few meters, soon after: the same area and buses, nothing more of Bus Time
        _ = try await buses.nearbyPlaces((40.66972, -73.98772), client: "a", now: now + 10)
        #expect(await fake.count("stops-for-location") == 1)
        #expect(await fake.count("stop-monitoring") == 3)

        let every = try #require(BusTime.arrivalsRequest(stop: "308209", lineRef: nil, key: "k").url?.query)
        #expect(!every.contains("LineRef"))
        let wide = try #require(BusTime.stopsRequest(near: boarding, key: "k", nearby: true).url?.query)
        #expect(wide.contains("latSpan=0.009"))

        await fake.set(status: 500)
        let failing = BusTime(key: "k") { await fake.answer($0) }
        await #expect(throws: BusTime.Failure.unavailable) {
            try await failing.nearbyPlaces((40.6697, -73.9877), client: "a", now: now)
        }
    }

    @Test func keepsToDailyLimitsOnWhatItAsksOfBusTime() async throws {
        let fake = FakeBusTime(now: now)
        let limited = BusTime.Failure.limited(retryAfter: DailyLimiter.secondsUntilReset(now: now))
        // A client's own: its stop and buses are 2, the third is refused
        let buses = BusTime(key: "k", perClientPerDay: 2, perDay: 100) { await fake.answer($0) }
        guard case .arrivals = await buses.arrivals(line: "B63", near: boarding, client: "a", now: now) else {
            Issue.record("expected arrivals"); return
        }
        #expect(await buses.arrivals(line: "B61", near: boarding, client: "a", now: now) == BusTime.Outcome(limited))
        // What's kept doesn't count
        guard case .arrivals = await buses.arrivals(line: "B63", near: boarding, client: "a", now: now + 10) else {
            Issue.record("expected kept arrivals"); return
        }
        // Someone else has their own, until everyone's is used up
        let shared = BusTime(key: "k", perClientPerDay: 100, perDay: 3) { await fake.answer($0) }
        _ = await shared.arrivals(line: "B63", near: boarding, client: "a", now: now)
        await #expect(throws: limited) { try await shared.nearbyPlaces((40.6697, -73.9877), client: "b", now: now) }
        // Till midnight UTC
        guard case .arrivals = await shared.arrivals(line: "B63", near: boarding, client: "b", now: now + 86400) else {
            Issue.record("expected arrivals the next day"); return
        }
    }

    @Test func configReadsTheKeyAndLimits() throws {
        let base = ["APNS_KEY_PATH": "/k.p8", "APNS_KEY_ID": "K", "APNS_TEAM_ID": "T", "DATA_DIR": "/d"]
        let without = try Config(environment: base)
        #expect(without.busTimeKey == nil)
        #expect(without.limits.busTimePerIPPerDay == 2_000)
        #expect(without.limits.busTimePerDay == 100_000)
        let with = try Config(environment: base.merging(["BUS_TIME_API_KEY": " key ", "BUS_TIME_PER_IP_PER_DAY": "5",
                                                         "BUS_TIME_PER_DAY": "50"]) { $1 })
        #expect(with.busTimeKey == "key")
        #expect(with.limits.busTimePerIPPerDay == 5)
        #expect(with.limits.busTimePerDay == 50)
        #expect(throws: Config.Problem.self) { try Config(environment: base.merging(["BUS_TIME_PER_DAY": "0"]) { $1 }) }
        #expect(throws: Config.Problem.self) { try Config(environment: base.merging(["BUS_TIME_PER_IP_PER_DAY": "x"]) { $1 }) }
    }
}

@Suite struct BusesHTTPTests {
    func withApp(buses: BusTime?, _ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        let services = HTTPServices(store: try Store(directory: nil), auth: .secret("test-secret-0123456789abcdef"),
                                    appID: testAppID, limits: testLimits(), buses: buses)
        try await Application(router: HTTPRoutes.router(services)).test(.router) { client in try await body(client) }
    }

    private static func busTime(status: Int = 200) async -> BusTime {
        let fake = FakeBusTime(now: .now)
        await fake.set(status: status)
        return BusTime(key: "k") { await fake.answer($0) }
    }

    @Test func notOfferedWithoutAKey() async throws {
        try await withApp(buses: nil) { client in
            try await client.execute(uri: "/buses?line=B63&stop=40.66975,-73.98768", method: .get) {
                #expect($0.status == .notFound)
            }
        }
    }

    @Test func answersWithTheStopAndItsNextBuses() async throws {
        try await withApp(buses: await Self.busTime()) { client in
            try await client.execute(uri: "/buses?line=B63&stop=40.66975,-73.98768", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                let decoded = try JSONDecoder().decode(BusTime.Arrivals.self, from: Data(response.body.readableBytesView))
                #expect(decoded.stop.id == "308209")
                #expect(decoded.arrivals.map(\.distance) == ["approaching", "1.4 miles away", nil])
            }
            // A line that doesn't stop near there
            try await client.execute(uri: "/buses?line=B67&stop=40.66975,-73.98768", method: .get) {
                #expect($0.status == .notFound)
            }
        }
    }

    @Test func refusesMalformedAndOutOfTownAsks() async throws {
        try await withApp(buses: await Self.busTime()) { client in
            for query in ["", "?line=B63", "?stop=40.66975,-73.98768", "?line=B63%26key%3Dx&stop=40.66975,-73.98768",
                          "?line=B63&stop=42.36,-71.06"] {
                try await client.execute(uri: "/buses\(query)", method: .get) { #expect($0.status == .badRequest, "\(query)") }
            }
        }
    }

    @Test func busTimeFailingIsBadGateway() async throws {
        try await withApp(buses: await Self.busTime(status: 503)) { client in
            try await client.execute(uri: "/buses?line=B63&stop=40.66975,-73.98768", method: .get) {
                #expect($0.status == .badGateway)
            }
            try await client.execute(uri: "/buses/nearby?at=40.6697,-73.9877", method: .get) {
                #expect($0.status == .badGateway)
            }
        }
    }

    @Test func overADailyLimitIsTooManyRequests() async throws {
        let fake = FakeBusTime(now: .now)
        try await withApp(buses: BusTime(key: "k", perClientPerDay: 1, perDay: 100) { await fake.answer($0) }) { client in
            // The stop is the one, its buses the next
            for uri in ["/buses?line=B63&stop=40.66975,-73.98768", "/buses/nearby?at=40.6697,-73.9877"] {
                try await client.execute(uri: uri, method: .get) { response in
                    #expect(response.status == .tooManyRequests, "\(uri)")
                    #expect(response.headers[.retryAfter] != nil)
                }
            }
        }
    }

    @Test func nearbyAnswersWithBothWays() async throws {
        struct Response: Decodable { var ways: [BusTime.Way]; var places: [[BusTime.Way]] }
        try await withApp(buses: await Self.busTime()) { client in
            try await client.execute(uri: "/buses/nearby?at=40.6697,-73.9877", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                let decoded = try JSONDecoder().decode(Response.self, from: Data(response.body.readableBytesView))
                #expect(decoded.ways.map(\.stop.id) == ["308209", "308210"])
                #expect(decoded.ways[0].arrivals.first?.distance == "approaching")
                // Each place, the first the same as `ways`
                #expect(decoded.places.map { $0.map(\.stop.id) } == [["308209", "308210"], ["301234"]])
            }
            // Nowhere near a stop is none, not an error
            try await client.execute(uri: "/buses/nearby?at=40.6787,-73.9877", method: .get) { response in
                #expect(response.status == .ok)
                let decoded = try JSONDecoder().decode(Response.self, from: Data(response.body.readableBytesView))
                #expect(decoded.ways.isEmpty)
            }
            for query in ["", "?at=nope", "?at=42.36,-71.06"] {
                try await client.execute(uri: "/buses/nearby\(query)", method: .get) {
                    #expect($0.status == .badRequest, "\(query)")
                }
            }
        }
    }
}
