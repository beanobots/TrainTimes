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

let prospectPoint = (40.6644, -73.9935)
let museumPoint = (40.7813, -73.9740)

/// Google's request and answer, kept only for comparing its trips with the server's own.
@Suite struct GoogleRoutesTests {
    @Test func readsEachRoutesSubwayRidesAndDropsTheRest() throws {
        let routes = try #require(GoogleRoutes.routes(in: Data(googleResponse.utf8)))
        // The third, with no rides, is left out; the second, with a bus that wasn't asked for
        #expect(routes.count == 1)
        #expect(routes[0].legs.map(\.line) == ["R", "B"])
        #expect(routes[0].legs[0].from.name == "Prospect Av")
        #expect(routes[0].legs[0].to == TransitRoute.Stop(name: "DeKalb Av", latitude: 40.690635, longitude: -73.981824))
        #expect(routes[0].legs[0].headsign == "Forest Hills - 71 Av")
        #expect(routes[0].legs[1].stops == 14)
        // Ten minutes by Google's times, leaving at its time; none where it gives none
        #expect(routes[0].legs[0].seconds == 600)
        #expect(routes[0].legs[0].leaves == Int(try #require(Web.date("2026-10-23T15:04:00Z")).timeIntervalSince1970))
        #expect(routes[0].legs[1].seconds == nil)
        #expect(routes[0].legs[1].leaves == nil)
        // No routes at all is none found; something else isn't Google's answer
        #expect(GoogleRoutes.routes(in: Data("{}".utf8)) == [])
        #expect(GoogleRoutes.routes(in: Data("nope".utf8)) == nil)
    }

    @Test func withBusKeepsBusRidesTooMarkedAsSuch() throws {
        let routes = try #require(GoogleRoutes.routes(in: Data(googleResponse.utf8), bus: true))
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

    @Test func dropsRoutesWithARideTheAppCantShowButKeepsTheStatenIslandRailway() throws {
        let ride = { (line: String, type: String) in
            """
            {"transitDetails":{"stopDetails":{
               "departureStop":{"name":"A","location":{"latLng":{"latitude":40.70,"longitude":-73.80}}},
               "arrivalStop":{"name":"B","location":{"latLng":{"latitude":40.75,"longitude":-73.99}}}},
             "transitLine":{"nameShort":"\(line)","vehicle":{"type":"\(type)"}}}}
            """
        }
        let route = { (rides: [String]) in #"{"legs":[{"steps":[{},"# + rides.joined(separator: ",") + "]}]}" }
        let response = #"{"routes":["# + [
            route([ride("Port Washington", "COMMUTER_TRAIN"), ride("7", "SUBWAY")]),
            route([ride("B63", "BUS"), ride("NYC Ferry", "FERRY")]),
            route([ride("SIR", "HEAVY_RAIL"), ride("S78", "BUS")]),
            route([ride("A", "SUBWAY"), ride("Q", "TRAM")]),
            route([ride("E", "SUBWAY")]),
        ].joined(separator: ",") + "]}"
        // The LIRR, a ferry or a tram would leave a gap between the rides kept
        let routes = try #require(GoogleRoutes.routes(in: Data(response.utf8), bus: true))
        #expect(routes.map { $0.legs.map(\.line) } == [["SIR", "S78"], ["E"]])
        #expect(routes[0].legs.map(\.mode) == [.subway, .bus])
        // Without buses, the bus ride is one the app can't show
        let subway = try #require(GoogleRoutes.routes(in: Data(response.utf8)))
        #expect(subway.map { $0.legs.map(\.line) } == [["E"]])
    }

    @Test func withBusAsksForSubwayAndBus() throws {
        let request = GoogleRoutes.request(from: prospectPoint, to: museumPoint, departure: .now, key: "k", bus: true)
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((body["transitPreferences"] as? [String: Any])?["allowedTravelModes"] as? [String] == ["SUBWAY", "BUS"])
    }

    @Test func withoutSubwayAsksForBusAlone() throws {
        #expect(try allowedModes(GoogleRoutes.request(from: prospectPoint, to: museumPoint, departure: .now, key: "k",
                                                bus: true, subway: false)) == ["BUS"])
        // Neither is taken as the subway
        #expect(try allowedModes(GoogleRoutes.request(from: prospectPoint, to: museumPoint, departure: .now, key: "k",
                                                bus: false, subway: false)) == ["SUBWAY"])
    }

    @Test func asksForSubwayTransitWithTheKeyInAHeaderAndOnlyTheRidesDetails() throws {
        let departure = Date(timeIntervalSince1970: 1_793_000_000)
        let request = GoogleRoutes.request(from: prospectPoint, to: museumPoint, departure: departure, key: "secret-key")
        #expect(request.httpMethod == "POST")
        #expect(request.url == GoogleRoutes.endpoint)
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

}

/// The modes a request to Google allows.
private func allowedModes(_ request: URLRequest) throws -> [String]? {
    let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    return (body["transitPreferences"] as? [String: Any])?["allowedTravelModes"] as? [String]
}
