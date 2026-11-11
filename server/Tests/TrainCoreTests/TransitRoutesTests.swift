import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import TrainCore

/// The fixtures' network (`plannerSubway`, `plannerBuses`), and points by its stops.
private let network = TransitNetwork(subway: plannerSubway(), buses: plannerBuses())
private let prospectAv = (40.6659, -73.9929)
private let canal = (40.7189, -74.0005)
private let fifthAvenue = (40.6655, -73.9850)
private let nearB2 = (40.6755, -73.9790)
private let leaving = Date(timeIntervalSince1970: 1_793_000_060)

private func planner(perClientPerDay: Int = 10, perDay: Int = 100,
                     network: TransitNetwork? = network) -> TransitRoutes {
    TransitRoutes(perClientPerDay: perClientPerDay, perDay: perDay) { network }
}

@Suite struct TransitRoutesTests {
    @Test func keepsToEachClientsAndEveryonesDailyLimit() async {
        let routes = planner(perClientPerDay: 2, perDay: 3)
        let now = leaving
        // Each leaving a minute later, so none is the same trip as one kept
        let asked = Counter()
        let ask = { (client: String) -> TransitRoutes.Outcome in
            asked.increment()
            return await routes.routes(from: prospectAv, to: canal, departure: now.addingTimeInterval(Double(asked.value) * 60),
                                       client: client, now: now)
        }
        guard case .routes(let found) = await ask("a") else { Issue.record("expected routes"); return }
        #expect(found.first?.legs.map(\.line) == ["R", "Q"])
        #expect(await ask("a") != .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now)))
        // a's two used
        #expect(await ask("a") == .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now)))
        // b's first, the third today
        #expect(await ask("b") != .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now)))
        // Everyone's three used
        #expect(await ask("c") == .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now)))
        // The next day, again
        let tomorrow = now.addingTimeInterval(86400)
        guard case .routes = await routes.routes(from: prospectAv, to: canal, departure: now, client: "a", now: tomorrow)
        else { Issue.record("expected routes the next day"); return }
    }

    @Test func theSameTripAskedAgainSoonIsKeptNotCounted() async {
        let routes = planner(perClientPerDay: 1)
        let now = leaving
        guard case .routes(let found) = await routes.routes(from: prospectAv, to: canal, departure: now, client: "a", now: now)
        else { Issue.record("expected routes"); return }
        // Within the minute and nearly the same places: kept, counting toward no limit (the client's one used)
        #expect(await routes.routes(from: (prospectAv.0 + 0.00001, prospectAv.1), to: canal,
                                    departure: now.addingTimeInterval(30), client: "a", now: now.addingTimeInterval(100))
            == .routes(found))
        // Two minutes on, or another trip: planned again, so over the client's limit
        let then = now.addingTimeInterval(TransitRoutes.keptFor)
        #expect(await routes.routes(from: prospectAv, to: canal, departure: now, client: "a", now: then)
            == .limited(retryAfter: DailyLimiter.secondsUntilReset(now: then)))
        #expect(await routes.routes(from: prospectAv, to: canal, departure: now, client: "a", bus: true, now: now)
            == .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now)))
    }

    @Test func busOneAddsBusesAndSubwayZeroIsBusesAlone() async {
        let routes = planner()
        guard case .routes(let trains) = await routes.routes(from: fifthAvenue, to: nearB2, departure: leaving, client: "a"),
              case .routes(let both) = await routes.routes(from: fifthAvenue, to: nearB2, departure: leaving, client: "a",
                                                          bus: true),
              case .routes(let buses) = await routes.routes(from: fifthAvenue, to: nearB2, departure: leaving, client: "a",
                                                           bus: true, subway: false)
        else { Issue.record("expected routes"); return }
        #expect(trains.allSatisfy { $0.legs.allSatisfy { $0.mode == .subway } })
        #expect(both.contains { $0.legs.map(\.line) == ["B63"] })
        #expect(!buses.isEmpty)
        #expect(buses.allSatisfy { $0.legs.allSatisfy { $0.mode == .bus } })
    }

    @Test func noTimetableIsUnavailableAndBusesWithoutTheirsTooButTrainsStillPlan() async {
        let none = planner(network: nil)
        #expect(await none.routes(from: prospectAv, to: canal, departure: leaving, client: "a") == .unavailable)
        let trainsOnly = planner(network: TransitNetwork(subway: plannerSubway(), buses: nil))
        #expect(await trainsOnly.routes(from: prospectAv, to: canal, departure: leaving, client: "a",
                                        bus: true, subway: false) == .unavailable)
        guard case .routes(let found) = await trainsOnly.routes(from: prospectAv, to: canal, departure: leaving,
                                                                client: "a", bus: true)
        else { Issue.record("expected trains"); return }
        #expect(found.first?.legs.map(\.line) == ["R", "Q"])
    }

    @Test func configReadsTheLimits() throws {
        let base = ["APNS_KEY_PATH": "/k.p8", "APNS_KEY_ID": "K", "APNS_TEAM_ID": "T", "DATA_DIR": "/d"]
        let without = try Config(environment: base)
        #expect(without.limits.routesPerIPPerDay == 1_000)
        #expect(without.limits.routesPerDay == 200_000)
        let with = try Config(environment: base.merging(["ROUTES_PER_IP_PER_DAY": "5", "ROUTES_PER_DAY": "50"]) { $1 })
        #expect(with.limits.routesPerIPPerDay == 5)
        #expect(with.limits.routesPerDay == 50)
        #expect(throws: Config.Problem.self) { try Config(environment: base.merging(["ROUTES_PER_DAY": "0"]) { $1 }) }
    }

    @Test func readsPointsAndKeepsToTheCity() {
        #expect(TransitRoutes.point("40.6644,-73.9935").map { [$0.0, $0.1] } == [40.6644, -73.9935])
        for bad in [nil, "", "40.6", "40.6,-73.9,1", "north,south", "nan,-73.9", "inf,-73.9"] {
            #expect(TransitRoutes.point(bad) == nil, "\(bad ?? "nil")")
        }
        #expect(TransitRoutes.isInCity(prospectPoint))
        #expect(TransitRoutes.isInCity(museumPoint))
        // Boston and Philadelphia aren't planned
        #expect(!TransitRoutes.isInCity((42.36, -71.06)))
        #expect(!TransitRoutes.isInCity((39.95, -75.17)))
    }
}

@Suite struct RoutesHTTPTests {
    func withApp(routes: TransitRoutes?, _ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        let services = HTTPServices(store: try Store(directory: nil), auth: .secret("test-secret-0123456789abcdef"),
                                    appID: testAppID, limits: testLimits(), routes: routes)
        try await Application(router: HTTPRoutes.router(services)).test(.router) { client in try await body(client) }
    }

    /// From Prospect Av to Canal St, leaving now.
    private static let trip = "/routes?from=40.6659,-73.9929&to=40.7189,-74.0005"

    /// The fixtures' network with its trains running from a minute ago, as `/routes` plans from now.
    private static func running(perClientPerDay: Int = 10) -> TransitRoutes {
        let started = Date.now.addingTimeInterval(-60)
        return planner(perClientPerDay: perClientPerDay,
                       network: TransitNetwork(subway: plannerSubway(from: started), buses: plannerBuses(from: started)))
    }

    @Test func answersWithTheRidesNeedingNoAuthThenTheClientsLimit() async throws {
        try await withApp(routes: Self.running(perClientPerDay: 1)) { client in
            try await client.execute(uri: Self.trip, method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                let decoded = try JSONDecoder().decode([String: [TransitRoute]].self,
                                                       from: Data(response.body.readableBytesView))
                #expect(decoded["routes"]?.first?.legs.map(\.line) == ["R", "Q"])
                // As the app reads them: each ride's mode, when it leaves and how long it takes
                let json = String(decoding: response.body.readableBytesView, as: UTF8.self)
                #expect(json.contains(#""mode":"subway""#))
                #expect(json.contains(#""leaves":"#))
                #expect(json.contains(#""seconds":"#))
            }
            // One a day for this client (another trip: the same is kept)
            try await client.execute(uri: Self.trip.replacingOccurrences(of: "-74.0005", with: "-74.0006"), method: .get) {
                #expect($0.status == .tooManyRequests)
                #expect($0.headers[.retryAfter] != nil)
            }
        }
    }

    @Test func notOfferedWithoutAPlanner() async throws {
        try await withApp(routes: nil) { client in
            try await client.execute(uri: Self.trip, method: .get) { #expect($0.status == .notFound) }
        }
    }

    @Test func refusesMissingMalformedAndOutOfTownPlacesWithoutCounting() async throws {
        try await withApp(routes: Self.running(perClientPerDay: 1)) { client in
            for query in ["", "?from=40.6644,-73.9935", "?from=x&to=40.7813,-73.974", "?from=42.36,-71.06&to=40.7813,-73.974"] {
                try await client.execute(uri: "/routes\(query)", method: .get) { #expect($0.status == .badRequest, "\(query)") }
            }
            try await client.execute(uri: Self.trip, method: .get) { #expect($0.status == .ok) }
        }
    }

    @Test func noTimetableYetIsBadGateway() async throws {
        try await withApp(routes: planner(network: nil)) { client in
            try await client.execute(uri: Self.trip, method: .get) { #expect($0.status == .badGateway) }
        }
    }
}
