import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import TrainCore

/// Google's answer for Prospect Av to the Museum of Natural History, trimmed to the field mask:
/// the R, then the B at DeKalb Av; a walk between; and an alternative with a bus, then the C.
private let googleResponse = """
{"routes":[
 {"legs":[{"steps":[
  {},
  {"transitDetails":{"stopDetails":{
     "departureStop":{"name":"Prospect Av","location":{"latLng":{"latitude":40.665414,"longitude":-73.992872}}},
     "arrivalStop":{"name":"DeKalb Av","location":{"latLng":{"latitude":40.690635,"longitude":-73.981824}}},
     "departureTime":"2026-10-23T15:04:00Z","arrivalTime":"2026-10-23T15:14:00Z"},
   "headsign":"Forest Hills - 71 Av","transitLine":{"nameShort":"R","vehicle":{"type":"SUBWAY"}},"stopCount":5}},
  {"transitDetails":{"stopDetails":{
     "departureStop":{"name":"DeKalb Av","location":{"latLng":{"latitude":40.690635,"longitude":-73.981824}}},
     "arrivalStop":{"name":"81 St - Museum of Natural History","location":{"latLng":{"latitude":40.781433,"longitude":-73.972143}}}},
   "headsign":"Bedford Park Blvd","transitLine":{"nameShort":"B","vehicle":{"type":"SUBWAY"}},"stopCount":14}},
  {}
 ]}]},
 {"legs":[{"steps":[
  {"transitDetails":{"stopDetails":{
     "departureStop":{"name":"4 Av/9 St","location":{"latLng":{"latitude":40.67,"longitude":-73.99}}},
     "arrivalStop":{"name":"Jay St","location":{"latLng":{"latitude":40.69,"longitude":-73.98}}}},
   "transitLine":{"nameShort":"B63","vehicle":{"type":"BUS"}}}},
  {"transitDetails":{"stopDetails":{
     "departureStop":{"name":"Jay St - MetroTech","location":{"latLng":{"latitude":40.692,"longitude":-73.987}}},
     "arrivalStop":{"name":"81 St","location":{"latLng":{"latitude":40.781,"longitude":-73.972}}}},
   "transitLine":{"nameShort":"C","vehicle":{"type":"SUBWAY"}}}}
 ]}]},
 {"legs":[{"steps":[{}]}]}
]}
"""

private let prospectPoint = (40.6644, -73.9935)
private let museumPoint = (40.7813, -73.9740)

@Suite struct TransitRoutesTests {
    @Test func readsEachRoutesSubwayRidesAndDropsTheRest() throws {
        let routes = try #require(TransitRoutes.routes(in: Data(googleResponse.utf8)))
        // The third, with no rides, is left out; the bus, from the second
        #expect(routes.count == 2)
        #expect(routes[0].legs.map(\.line) == ["R", "B"])
        #expect(routes[0].legs[0].from.name == "Prospect Av")
        #expect(routes[0].legs[0].to == TransitRoute.Stop(name: "DeKalb Av", latitude: 40.690635, longitude: -73.981824))
        #expect(routes[0].legs[0].headsign == "Forest Hills - 71 Av")
        #expect(routes[0].legs[1].stops == 14)
        // Ten minutes by Google's times; none where it gives none
        #expect(routes[0].legs[0].seconds == 600)
        #expect(routes[0].legs[1].seconds == nil)
        #expect(routes[1].legs.map(\.line) == ["C"])
        // No routes at all is none found; something else isn't Google's answer
        #expect(TransitRoutes.routes(in: Data("{}".utf8)) == [])
        #expect(TransitRoutes.routes(in: Data("nope".utf8)) == nil)
    }

    @Test func withBusKeepsBusRidesTooMarkedAsSuch() throws {
        let routes = try #require(TransitRoutes.routes(in: Data(googleResponse.utf8), bus: true))
        #expect(routes.count == 2)
        #expect(routes[0].legs.map(\.mode) == [.subway, .subway])
        #expect(routes[1].legs.map(\.line) == ["B63", "C"])
        #expect(routes[1].legs.map(\.mode) == [.bus, .subway])
        #expect(routes[1].legs[0].from == TransitRoute.Stop(name: "4 Av/9 St", latitude: 40.67, longitude: -73.99))
        // Each ride says which it is, so the app can tell
        let json = String(decoding: try JSONEncoder().encode(routes[1]), as: UTF8.self)
        #expect(json.contains(#""mode":"bus""#))
        #expect(json.contains(#""mode":"subway""#))
    }

    @Test func withBusAsksForSubwayAndBus() throws {
        let request = TransitRoutes.request(from: prospectPoint, to: museumPoint, departure: .now, key: "k", bus: true)
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((body["transitPreferences"] as? [String: Any])?["allowedTravelModes"] as? [String] == ["SUBWAY", "BUS"])
    }

    @Test func asksForSubwayTransitWithTheKeyInAHeaderAndOnlyTheRidesDetails() throws {
        let departure = Date(timeIntervalSince1970: 1_793_000_000)
        let request = TransitRoutes.request(from: prospectPoint, to: museumPoint, departure: departure, key: "secret-key")
        #expect(request.httpMethod == "POST")
        #expect(request.url == TransitRoutes.endpoint)
        // Not in the URL, where logs might keep it
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-Goog-Api-Key") == "secret-key")
        #expect(request.value(forHTTPHeaderField: "X-Goog-FieldMask") == "routes.legs.steps.transitDetails")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["travelMode"] as? String == "TRANSIT")
        #expect(body["computeAlternativeRoutes"] as? Bool == true)
        #expect((body["transitPreferences"] as? [String: Any])?["allowedTravelModes"] as? [String] == ["SUBWAY"])
        #expect(body["departureTime"] as? String == ISO8601DateFormatter().string(from: departure))
        let origin = (body["origin"] as? [String: Any])?["location"] as? [String: Any]
        let latLng = origin?["latLng"] as? [String: Double]
        #expect(latLng?["latitude"] == prospectPoint.0)
        #expect(latLng?["longitude"] == prospectPoint.1)
    }

    @Test func keepsToEachClientsAndEveryonesDailyLimit() async {
        let routes = TransitRoutes(key: "k", perClientPerDay: 2, perDay: 3) { _ in (Data(googleResponse.utf8), 200) }
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let ask = { (client: String) in await routes.routes(from: prospectPoint, to: museumPoint, departure: now, client: client, now: now) }
        guard case .routes(let found) = await ask("a") else { Issue.record("expected routes"); return }
        #expect(found.count == 2)
        #expect(await ask("a") != .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now)))
        // a's two used
        #expect(await ask("a") == .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now)))
        // b's first, the third today
        #expect(await ask("b") != .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now)))
        // Everyone's three used
        #expect(await ask("c") == .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now)))
        // The next day, again
        let tomorrow = now.addingTimeInterval(86400)
        guard case .routes = await routes.routes(from: prospectPoint, to: museumPoint, departure: tomorrow, client: "a", now: tomorrow)
        else { Issue.record("expected routes the next day"); return }
    }

    @Test func googleFailingIsUnavailable() async {
        let refused = TransitRoutes(key: "k", perClientPerDay: 10, perDay: 10) { _ in (Data(#"{"error":{}}"#.utf8), 403) }
        #expect(await refused.routes(from: prospectPoint, to: museumPoint, departure: .now, client: "a") == .unavailable)
        let unreachable = TransitRoutes(key: "k", perClientPerDay: 10, perDay: 10) { _ in throw URLError(.notConnectedToInternet) }
        #expect(await unreachable.routes(from: prospectPoint, to: museumPoint, departure: .now, client: "a") == .unavailable)
    }

    @Test func configReadsTheKeyAndLimits() throws {
        let base = ["APNS_KEY_PATH": "/k.p8", "APNS_KEY_ID": "K", "APNS_TEAM_ID": "T", "DATA_DIR": "/d"]
        let without = try Config(environment: base)
        #expect(without.googleRoutesKey == nil)
        #expect(without.limits.routesPerIPPerDay == 30)
        #expect(without.limits.routesPerDay == 300)
        let with = try Config(environment: base.merging(["GOOGLE_ROUTES_API_KEY": " key ", "ROUTES_PER_IP_PER_DAY": "5",
                                                         "ROUTES_PER_DAY": "50"]) { $1 })
        #expect(with.googleRoutesKey == "key")
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
        // Boston and Philadelphia aren't asked of Google
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

    private static func google(status: Int = 200) -> TransitRoutes {
        TransitRoutes(key: "k", perClientPerDay: 1, perDay: 100) { _ in (Data(googleResponse.utf8), status) }
    }

    @Test func notOfferedWithoutAKey() async throws {
        try await withApp(routes: nil) { client in
            try await client.execute(uri: "/routes?from=40.6644,-73.9935&to=40.7813,-73.974", method: .get) {
                #expect($0.status == .notFound)
            }
        }
    }

    @Test func answersWithTheRidesNeedingNoAuthThenTheClientsLimit() async throws {
        try await withApp(routes: Self.google()) { client in
            try await client.execute(uri: "/routes?from=40.6644,-73.9935&to=40.7813,-73.974", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                let decoded = try JSONDecoder().decode([String: [TransitRoute]].self,
                                                       from: Data(response.body.readableBytesView))
                #expect(decoded["routes"]?.first?.legs.map(\.line) == ["R", "B"])
            }
            // One a day for this client
            try await client.execute(uri: "/routes?from=40.6644,-73.9935&to=40.7813,-73.974", method: .get) { response in
                #expect(response.status == .tooManyRequests)
                #expect(response.headers[.retryAfter] != nil)
            }
        }
    }

    @Test func busOneGivesBusRides() async throws {
        try await withApp(routes: Self.google()) { client in
            try await client.execute(uri: "/routes?from=40.6644,-73.9935&to=40.7813,-73.974&bus=1", method: .get) { response in
                #expect(response.status == .ok)
                let decoded = try JSONDecoder().decode([String: [TransitRoute]].self,
                                                       from: Data(response.body.readableBytesView))
                #expect(decoded["routes"]?.map { $0.legs.map(\.line) } == [["R", "B"], ["B63", "C"]])
            }
        }
    }

    @Test func refusesMissingMalformedAndOutOfTownPlacesWithoutAskingGoogle() async throws {
        // Asking Google at all would use up the one a day
        try await withApp(routes: Self.google()) { client in
            for query in ["", "?from=40.6644,-73.9935", "?from=x&to=40.7813,-73.974", "?from=42.36,-71.06&to=40.7813,-73.974"] {
                try await client.execute(uri: "/routes\(query)", method: .get) { #expect($0.status == .badRequest, "\(query)") }
            }
            try await client.execute(uri: "/routes?from=40.6644,-73.9935&to=40.7813,-73.974", method: .get) {
                #expect($0.status == .ok)
            }
        }
    }

    @Test func googleFailingIsBadGateway() async throws {
        try await withApp(routes: Self.google(status: 500)) { client in
            try await client.execute(uri: "/routes?from=40.6644,-73.9935&to=40.7813,-73.974", method: .get) {
                #expect($0.status == .badGateway)
            }
        }
    }
}
