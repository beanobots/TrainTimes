import Foundation

/// A subway route from Google's Routes API: just its train rides, and with `bus` its bus rides,
/// in order, for the app to match to its stations. For trips shared from Apple Maps or Google
/// Maps, whose links say only where they start and end.
struct TransitRoute: Codable, Equatable, Sendable {
    var legs: [Leg]

    /// One train or bus ride.
    struct Leg: Codable, Equatable, Sendable {
        /// Google's short name for the line: "R", "6", "S", "B63".
        var line: String
        var from: Stop
        var to: Stop
        /// Where the train's going, e.g. "Forest Hills - 71 Av".
        var headsign: String?
        /// Stops ridden, counting the last.
        var stops: Int?
        var mode: Mode = .subway
        /// Seconds from boarding to getting off, by Google's timetable: for timing what comes
        /// after a bus, as Bus Time only says when it's due where you board.
        var seconds: Int? = nil
    }

    enum Mode: String, Codable, Sendable {
        case subway, bus
    }

    struct Stop: Codable, Equatable, Sendable {
        var name: String
        var latitude: Double
        var longitude: Double
    }
}

/// Asks Google's Routes API for subway routes (`GET /routes`), keeping to daily limits so its
/// free allowance isn't used up: each client's, and everyone's together. The key stays here, as
/// the app can't keep one secret.
actor TransitRoutes {
    typealias Fetch = Web.Fetch

    enum Outcome: Equatable, Sendable {
        case routes([TransitRoute])
        /// Over a daily limit, until the counts start again.
        case limited(retryAfter: Int)
        /// Google refused or couldn't be reached.
        case unavailable
    }

    static let endpoint = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!

    private let key: String
    private let perClient: DailyLimiter
    private let everyone: DailyLimiter
    private let fetch: Fetch

    init(key: String, perClientPerDay: Int, perDay: Int, fetch: Fetch? = nil) {
        self.key = key
        perClient = DailyLimiter(limit: perClientPerDay)
        everyone = DailyLimiter(limit: perDay)
        self.fetch = fetch ?? Web.fetch
    }

    /// Google's routes from `from` to `to` leaving at `departure`, best first, for `client`; by
    /// bus too with `bus`. A request counts toward the limits whether or not Google finds a route.
    func routes(from: (Double, Double), to: (Double, Double), departure: Date, client: String,
                bus: Bool = false, now: Date = .now) async -> Outcome {
        guard await perClient.take(client, now: now), await everyone.take("everyone", now: now) else {
            return .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now))
        }
        let request = Self.request(from: from, to: to, departure: departure, key: key, bus: bus)
        guard let (data, status) = try? await fetch(request) else {
            Log.error("routes: Google unreachable")
            return .unavailable
        }
        guard status == 200, let routes = Self.routes(in: data, bus: bus) else {
            Log.error("routes: Google answered \(status)")
            return .unavailable
        }
        return .routes(routes)
    }

    /// A transit request by subway alone, or with `bus` by subway and bus, with Google's
    /// alternatives, asking only for the rides' details (the field mask), which keeps it Google's
    /// cheapest kind of request.
    static func request(from: (Double, Double), to: (Double, Double), departure: Date, key: String,
                        bus: Bool = false) -> URLRequest {
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
            "transitPreferences": ["allowedTravelModes": bus ? ["SUBWAY", "BUS"] : ["SUBWAY"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return request
    }

    /// Each route's subway rides from Google's response, and with `bus` its bus rides; routes
    /// with none are left out. Nil if it isn't Google's response at all.
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
            let legs = (route.legs ?? []).flatMap { $0.steps ?? [] }.compactMap { step -> TransitRoute.Leg? in
                let type = step.transitDetails?.transitLine?.vehicle?.type
                let mode: TransitRoute.Mode
                switch type {
                case "SUBWAY", "METRO_RAIL": mode = .subway
                case "BUS" where bus: mode = .bus
                default: return nil
                }
                guard let details = step.transitDetails,
                      let line = details.transitLine?.nameShort ?? details.transitLine?.name,
                      let from = stop(details.stopDetails?.departureStop),
                      let to = stop(details.stopDetails?.arrivalStop) else { return nil }
                let time = { (text: String?) in text.flatMap(Web.date) }
                let seconds = time(details.stopDetails?.departureTime).flatMap { leaves in
                    time(details.stopDetails?.arrivalTime).map { Int($0.timeIntervalSince(leaves)) }
                }.flatMap { $0 >= 0 ? $0 : nil }
                return TransitRoute.Leg(line: line, from: from, to: to, headsign: details.headsign,
                                        stops: details.stopCount, mode: mode, seconds: seconds)
            }
            return legs.isEmpty ? nil : TransitRoute(legs: legs)
        }
    }

    /// Whether a point is in New York City, around its subway: trips elsewhere aren't asked of
    /// Google.
    static func isInCity(_ point: (Double, Double)) -> Bool {
        (40.45...40.95).contains(point.0) && (-74.30 ... -73.65).contains(point.1)
    }

    /// "40.6644,-73.9935" as a latitude and longitude.
    static func point(_ text: String?) -> (Double, Double)? {
        guard let parts = text?.split(separator: ","), parts.count == 2,
              let latitude = Double(parts[0]), let longitude = Double(parts[1]),
              latitude.isFinite, longitude.isFinite else { return nil }
        return (latitude, longitude)
    }
}
