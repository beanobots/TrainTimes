import Foundation

/// Google's Routes API, kept only to compare its trips with the server's own
/// (`TransitPlanner`, `PlannerComparison` in the tests): `GET /routes` no longer asks it, as
/// Google's terms don't allow its routes on Apple's map. To be removed once the comparison's done.
enum GoogleRoutes {
    static let endpoint = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!

    /// A transit request by subway alone, or with `bus` by subway and bus (by bus alone without
    /// `subway`; `subway` alone counts without `bus`), with Google's
    /// alternatives, asking only for the rides' details (the field mask), which keeps it Google's
    /// cheapest kind of request.
    static func request(from: (Double, Double), to: (Double, Double), departure: Date, key: String,
                        bus: Bool = false, subway: Bool = true) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("routes.legs.steps.transitDetails", forHTTPHeaderField: "X-Goog-FieldMask")
        let place = { (point: (Double, Double)) -> [String: Any] in
            ["location": ["latLng": ["latitude": point.0, "longitude": point.1]]]
        }
        let body: [String: Any] = [
            "origin": place(from),
            "destination": place(to),
            "travelMode": "TRANSIT",
            "departureTime": ISO8601DateFormatter().string(from: departure),
            "computeAlternativeRoutes": true,
            "transitPreferences": ["allowedTravelModes": bus ? (subway ? ["SUBWAY", "BUS"] : ["BUS"]) : ["SUBWAY"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return request
    }

    /// Each route's subway rides from Google's response, and with `bus` its bus rides; routes
    /// with none are left out, and so are those with a ride the app can't show (the LIRR, a
    /// ferry, a bus without `bus`), which would leave a gap in the trip. The Staten Island
    /// Railway, whichever kind of train Google calls it, is a subway ride. Nil if it isn't
    /// Google's response at all.
    static func routes(in data: Data, bus: Bool = false) -> [TransitRoute]? {
        struct Response: Decodable {
            var routes: [Route]?
            struct Route: Decodable { var legs: [Leg]? }
            struct Leg: Decodable { var steps: [Step]? }
            struct Step: Decodable { var transitDetails: Details? }
            struct Details: Decodable {
                var stopDetails: Stops?
                var headsign: String?
                var transitLine: Line?
                var stopCount: Int?
            }
            struct Stops: Decodable {
                var departureStop: Stop?, arrivalStop: Stop?
                var departureTime: String?, arrivalTime: String?
            }
            struct Stop: Decodable {
                var name: String?
                var location: Location?
            }
            struct Location: Decodable { var latLng: LatLng? }
            struct LatLng: Decodable { var latitude: Double, longitude: Double }
            struct Line: Decodable {
                var nameShort: String?
                var name: String?
                var vehicle: Vehicle?
            }
            struct Vehicle: Decodable { var type: String? }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let stop = { (stop: Response.Stop?) -> TransitRoute.Stop? in
            guard let stop, let point = stop.location?.latLng else { return nil }
            return TransitRoute.Stop(name: stop.name ?? "", latitude: point.latitude, longitude: point.longitude)
        }
        return (response.routes ?? []).compactMap { route in
            // Walks between the rides have no details
            let rides = (route.legs ?? []).flatMap { $0.steps ?? [] }.compactMap(\.transitDetails)
            var legs: [TransitRoute.Leg] = []
            for details in rides {
                guard let line = details.transitLine?.nameShort ?? details.transitLine?.name,
                      let mode = mode(of: details.transitLine?.vehicle?.type, line: line, bus: bus),
                      let from = stop(details.stopDetails?.departureStop),
                      let to = stop(details.stopDetails?.arrivalStop) else { return nil }
                let time = { (text: String?) in text.flatMap(Web.date) }
                let leaves = time(details.stopDetails?.departureTime)
                let seconds = leaves.flatMap { leaves in
                    time(details.stopDetails?.arrivalTime).map { Int($0.timeIntervalSince(leaves)) }
                }.flatMap { $0 >= 0 ? $0 : nil }
                legs.append(TransitRoute.Leg(line: line, from: from, to: to, headsign: details.headsign,
                                             stops: details.stopCount, mode: mode, seconds: seconds,
                                             leaves: leaves.map { Int($0.timeIntervalSince1970) }))
            }
            return legs.isEmpty ? nil : TransitRoute(legs: legs)
        }
    }

    /// A ride's mode by Google's kind of vehicle: nil for one the app can't show. The Staten
    /// Island Railway ("SIR") is the app's SI, a subway line, whatever Google calls its trains.
    private static func mode(of vehicle: String?, line: String, bus: Bool) -> TransitRoute.Mode? {
        switch vehicle {
        case "SUBWAY", "METRO_RAIL": return .subway
        case "BUS": return bus ? .bus : nil
        case "RAIL", "HEAVY_RAIL", "COMMUTER_TRAIN":
            return ["SIR", "STATEN ISLAND RAILWAY"].contains(line.uppercased()) ? .subway : nil
        default: return nil
        }
    }

}
