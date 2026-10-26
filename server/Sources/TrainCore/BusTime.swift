import Foundation

/// The next buses at a stop from MTA Bus Time, for the bus rides `GET /routes` gives with `bus`
/// (`GET /buses`). Google names a ride's line and where it boards, not Bus Time's stop, so the
/// stop is found first, with OneBusAway's stops-for-location, then its buses read with SIRI
/// StopMonitoring. Both are kept a while (`stopLifetime`, `arrivalsLifetime`), and asked of Bus
/// Time once however many ask at the same time, so phones asking together don't add to what Bus
/// Time is asked, and to daily limits, each client's and everyone's, on what is asked of it. The
/// key stays here, as the app can't keep one secret.
actor BusTime {
    typealias Fetch = Web.Fetch

    /// A Bus Time stop.
    struct Stop: Codable, Equatable, Sendable {
        /// The MTA's stop code, as on the stop's sign: "308209".
        var id: String
        var name: String
        var latitude: Double
        var longitude: Double
        /// Which way buses leave it, as a compass point: "N", "SW".
        var direction: String?
    }

    /// One bus on its way to the stop.
    struct Arrival: Codable, Equatable, Sendable {
        /// The line as the bus shows it: "B63", "M15-SBS".
        var line: String
        var destination: String?
        /// When Bus Time expects it at the stop, from where it is now.
        var expected: Date?
        /// When the timetable has it there: all there is for a bus yet to leave its terminal.
        var aimed: Date?
        /// Stops it has yet to make before this one.
        var stopsAway: Int?
        /// Bus Time's words for how far it is: "approaching", "1.2 miles away".
        var distance: String?
    }

    struct Arrivals: Codable, Equatable, Sendable {
        var stop: Stop
        var arrivals: [Arrival]
    }

    /// One way the buses near you go, for the app's Nearby (`GET /buses/nearby`): the closest
    /// stop that way and its next buses, every line.
    struct Way: Codable, Equatable, Sendable {
        var stop: Stop
        /// From where it was asked.
        var meters: Double
        var arrivals: [Arrival]
    }

    enum Outcome: Equatable, Sendable {
        case arrivals(Arrivals)
        /// No stop for the line near there.
        case noStop
        /// Over a daily limit, until the counts start again.
        case limited(retryAfter: Int)
        /// Bus Time refused or couldn't be reached.
        case unavailable

        init(_ failure: Failure) {
            switch failure {
            case .limited(let retryAfter): self = .limited(retryAfter: retryAfter)
            case .unavailable: self = .unavailable
            }
        }
    }

    /// Why Bus Time wasn't asked, or couldn't say.
    enum Failure: Error, Equatable, Sendable {
        case limited(retryAfter: Int)
        case unavailable
    }

    /// A stop near a point, with the lines that stop there, as stops-for-location gives them.
    struct Candidate: Equatable, Sendable {
        var stop: Stop
        var lines: [Line]

        struct Line: Equatable, Sendable {
            /// Bus Time's id for it, SIRI's LineRef: "MTA NYCT_B63".
            var ref: String
            var name: String
        }
    }

    static let base = URL(string: "https://bustime-classic.mta.info")!
    /// How long a stop found for a line and place is kept, and not finding one.
    static let stopLifetime: TimeInterval = 86400
    static let noStopLifetime: TimeInterval = 3600
    /// How long a stop's next buses are kept. Buses report where they are every 30 seconds or
    /// so, so asking more often would mostly give the same.
    static let arrivalsLifetime: TimeInterval = 30
    /// Meters the stop may be from where Google has the ride board.
    static let matchRange: Double = 150
    /// Meters Nearby's stops may be from you: a quarter mile, as its stations may.
    static let nearbyRange: Double = 0.25 * 1_609.344
    /// Kept stops and arrivals, each, before the ones gone stale are cleared.
    static let maxKept = 5000

    private let key: String
    private let fetch: Fetch
    /// What's asked of Bus Time each day, for each client and for everyone: only what isn't
    /// kept, nor under way for another, counts.
    private let perClient: DailyLimiter
    private let everyone: DailyLimiter
    private var stops: [String: (found: (stop: Stop, lineRef: String)?, until: Date)] = [:]
    /// Stops around a point to three decimals, about 100 meters, for Nearby; kept as long as a
    /// line's stop is.
    private var areas: [String: (candidates: [Candidate], until: Date)] = [:]
    private var kept: [String: (arrivals: [Arrival], until: Date)] = [:]
    /// Requests to Bus Time under way, by URL, for others asking the same to wait for.
    private var asking: [String: Task<Result<Data, Failure>, Never>] = [:]

    init(key: String, perClientPerDay: Int = Limits().busTimePerIPPerDay, perDay: Int = Limits().busTimePerDay,
         fetch: Fetch? = nil) {
        self.key = key
        perClient = DailyLimiter(limit: perClientPerDay)
        everyone = DailyLimiter(limit: perDay)
        self.fetch = fetch ?? Web.fetch
    }

    /// The next buses on `line` (Google's name for it) at its stop nearest `point`, soonest first,
    /// for `client`.
    func arrivals(line: String, near point: (Double, Double), client: String, now: Date = .now) async -> Outcome {
        let wanted = Self.canonical(line)
        let place = "\(wanted) " + String(format: "%.4f,%.4f", point.0, point.1)
        let found: (stop: Stop, lineRef: String)
        if let cached = stops[place], cached.until > now {
            guard let stop = cached.found else { return .noStop }
            found = stop
        } else {
            let data: Data
            do { data = try await get(Self.stopsRequest(near: point, key: key), for: client, now: now) }
            catch { return Outcome(error) }
            guard let candidates = Self.candidates(in: data) else { return .unavailable }
            let nearest = Self.nearest(serving: wanted, to: point, in: candidates)
            if stops.count >= Self.maxKept { stops = stops.filter { $0.value.until > now } }
            if stops.count >= Self.maxKept { stops.removeAll() }
            stops[place] = (nearest, now.addingTimeInterval(nearest == nil ? Self.noStopLifetime : Self.stopLifetime))
            guard let nearest else { return .noStop }
            found = nearest
        }
        do {
            let arrivals = try await arrivals(at: found.stop.id, lineRef: found.lineRef, client: client, now: now)
            return .arrivals(Arrivals(stop: found.stop, arrivals: arrivals))
        } catch {
            return Outcome(error)
        }
    }

    /// The stops around `point`, kept for the area (to about 100 m) for `stopLifetime`.
    private func candidates(around point: (Double, Double), client: String, now: Date) async throws(Failure) -> [Candidate] {
        let rounded = ((point.0 * 1000).rounded() / 1000, (point.1 * 1000).rounded() / 1000)
        let area = String(format: "%.3f,%.3f", rounded.0, rounded.1)
        if let cached = areas[area], cached.until > now { return cached.candidates }
        let data = try await get(Self.stopsRequest(near: rounded, key: key, nearby: true), for: client, now: now)
        guard let read = Self.candidates(in: data) else { throw .unavailable }
        if areas.count >= Self.maxKept { areas = areas.filter { $0.value.until > now } }
        if areas.count >= Self.maxKept { areas.removeAll() }
        areas[area] = (read, now.addingTimeInterval(Self.stopLifetime))
        return read
    }

    /// The next buses at stop `id`, on the line `lineRef` or every line, soonest first, kept
    /// `arrivalsLifetime`.
    private func arrivals(at id: String, lineRef: String?, client: String, now: Date) async throws(Failure) -> [Arrival] {
        let visit = "\(id) \(lineRef ?? "*")"
        let arrivals: [Arrival]
        if let cached = kept[visit], cached.until > now {
            arrivals = cached.arrivals
        } else {
            let data = try await get(Self.arrivalsRequest(stop: id, lineRef: lineRef, key: key), for: client, now: now)
            guard let read = Self.arrivals(in: data) else { throw .unavailable }
            if kept.count >= Self.maxKept { kept = kept.filter { $0.value.until > now } }
            if kept.count >= Self.maxKept { kept.removeAll() }
            kept[visit] = (read, now.addingTimeInterval(Self.arrivalsLifetime))
            arrivals = read
        }
        // Not a bus that's been and gone since they were read
        return arrivals.filter { ($0.expected ?? $0.aimed ?? now) > now.addingTimeInterval(-60) }
    }

    /// Meters a stop may be from the one across from it, its other way.
    static let pairRange: Double = 200

    /// Nearby's bus places in `candidates`, for the app's grid: up to `limit`, nearest first,
    /// each a stop within `nearbyRange` of `point` and, within `pairRange` of it, the stop its
    /// lines go the other way from. One whose lines a nearer place has all of is left out.
    static func places(near point: (Double, Double), in candidates: [Candidate],
                       limit: Int = 3) -> [[(stop: Stop, meters: Double)]] {
        let close = candidates.filter { !$0.lines.isEmpty }
            .map { ($0, meters(from: point, to: ($0.stop.latitude, $0.stop.longitude))) }
            .filter { $0.1 <= nearbyRange }
            .sorted { $0.1 < $1.1 }
        var claimed = Set<String>()
        var shown = Set<String>()
        var places: [[(stop: Stop, meters: Double)]] = []
        for (stop, distance) in close where places.count < limit && !claimed.contains(stop.stop.id) {
            claimed.insert(stop.stop.id)
            let lines = Set(stop.lines.map(\.ref))
            guard !lines.isSubset(of: shown) else { continue }
            let other = close.first { candidate, _ in
                !claimed.contains(candidate.stop.id)
                    && candidate.lines.contains { lines.contains($0.ref) }
                    && opposite(stop.stop.direction, candidate.stop.direction)
                    && meters(from: (stop.stop.latitude, stop.stop.longitude),
                              to: (candidate.stop.latitude, candidate.stop.longitude)) <= pairRange
            }
            var place = [(stop.stop, distance)]
            if let other {
                claimed.insert(other.0.stop.id)
                place.append((other.0.stop, other.1))
                shown.formUnion(other.0.lines.map(\.ref))
            }
            shown.formUnion(lines)
            places.append(place)
        }
        return places
    }

    /// `places(near:in:)` near `point`, each stop with its next buses, every line, for `client`.
    func nearbyPlaces(_ point: (Double, Double), client: String, now: Date = .now) async throws(Failure) -> [[Way]] {
        let candidates = try await candidates(around: point, client: client, now: now)
        let picked = Self.places(near: point, in: candidates)
        // Every stop's buses asked of Bus Time together
        let read = await withTaskGroup(of: (String, Result<[Arrival], Failure>).self) { group in
            for id in picked.flatMap({ $0.map(\.stop.id) }) {
                group.addTask {
                    do throws(Failure) {
                        return (id, .success(try await self.arrivals(at: id, lineRef: nil, client: client, now: now)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            var read: [String: Result<[Arrival], Failure>] = [:]
            for await (id, arrivals) in group { read[id] = arrivals }
            return read
        }
        var places: [[Way]] = []
        for place in picked {
            var ways: [Way] = []
            for pick in place {
                ways.append(Way(stop: pick.stop, meters: pick.meters, arrivals: try read[pick.stop.id]?.get() ?? []))
            }
            places.append(ways)
        }
        return places
    }

    /// Whether buses leaving stops headed `one` and `other` ("N", "SW") go opposite ways, give
    /// or take a turn of the road. Either unknown, it could be.
    static func opposite(_ one: String?, _ other: String?) -> Bool {
        let points = ["N": 0.0, "NE": 45, "E": 90, "SE": 135, "S": 180, "SW": 225, "W": 270, "NW": 315]
        guard let one = one.flatMap({ points[$0.uppercased()] }),
              let other = other.flatMap({ points[$0.uppercased()] }) else { return true }
        let apart = abs(one - other)
        return min(apart, 360 - apart) >= 135
    }

    /// The body Bus Time answers `request` with, one request at a time for each URL; for
    /// `client`, whose limit, and everyone's, it counts toward unless it's already under way.
    private func get(_ request: URLRequest, for client: String, now: Date) async throws(Failure) -> Data {
        let id = request.url?.absoluteString ?? ""
        if let under = asking[id] { return try await under.value.get() }
        guard await perClient.take(client, now: now), await everyone.take("everyone", now: now) else {
            throw .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now))
        }
        // Asked for by another while counting
        if let under = asking[id] { return try await under.value.get() }
        let fetch = self.fetch
        let task = Task { () -> Result<Data, Failure> in
            guard let (data, status) = try? await fetch(request) else {
                Log.error("buses: Bus Time unreachable")
                return .failure(.unavailable)
            }
            guard status == 200 else {
                Log.error("buses: Bus Time answered \(status)")
                return .failure(.unavailable)
            }
            return .success(data)
        }
        asking[id] = task
        let data = await task.value
        asking[id] = nil
        return try data.get()
    }

    /// A line's name as Bus Time's and Google's both come to: "M15-SBS", "M15 SBS" and "M15+"
    /// are all "M15+", Select Bus Service.
    static func canonical(_ line: String) -> String {
        var name = line.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        if name.hasSuffix("SBS") { name = String(name.dropLast(3)) + "+" }
        return name
    }

    /// `line` if it could be a bus line's name: letters, digits, spaces, "-" and "+", 16 at most.
    static func validLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard (1...16).contains(trimmed.count),
              trimmed.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || " -+".contains($0) }),
              !canonical(trimmed).isEmpty else { return nil }
        return trimmed
    }

    /// The stop in `candidates` nearest `point` that a line named `wanted` (`canonical`) stops at,
    /// within `matchRange`, with Bus Time's id for the line.
    static func nearest(serving wanted: String, to point: (Double, Double),
                        in candidates: [Candidate]) -> (stop: Stop, lineRef: String)? {
        candidates.compactMap { candidate -> (Stop, String, Double)? in
            guard let line = candidate.lines.first(where: {
                canonical($0.name) == wanted || canonical(Self.bare($0.ref)) == wanted
            }) else { return nil }
            let distance = meters(from: point, to: (candidate.stop.latitude, candidate.stop.longitude))
            return distance <= matchRange ? (candidate.stop, line.ref, distance) : nil
        }
        .min { $0.2 < $1.2 }
        .map { ($0.0, $0.1) }
    }

    /// Meters between two nearby points.
    static func meters(from a: (Double, Double), to b: (Double, Double)) -> Double {
        let north = (b.0 - a.0) * 111_000
        let east = (b.1 - a.1) * 111_000 * cos((a.0 + b.0) / 2 * .pi / 180)
        return (north * north + east * east).squareRoot()
    }

    /// "MTA NYCT_B63" as "B63", "MTA_308209" as "308209".
    private static func bare(_ id: String) -> String {
        id.split(separator: "_").last.map(String.init) ?? id
    }

    /// Stops within about 200 meters of `point`; with `nearby`, about 500, for `nearbyRange` from
    /// anywhere `point` was rounded from.
    static func stopsRequest(near point: (Double, Double), key: String, nearby: Bool = false) -> URLRequest {
        request("api/where/stops-for-location.json", [
            ("lat", String(point.0)), ("lon", String(point.1)),
            ("latSpan", nearby ? "0.009" : "0.004"), ("lonSpan", nearby ? "0.011" : "0.005"),
            ("key", key),
        ])
    }

    /// The next few buses at one stop, on one line or (`lineRef` nil) every line.
    static func arrivalsRequest(stop: String, lineRef: String?, key: String) -> URLRequest {
        request("api/siri/stop-monitoring.json", [
            ("key", key), ("version", "2"), ("MonitoringRef", stop),
        ] + (lineRef.map { [("LineRef", $0)] } ?? []) + [
            ("MaximumStopVisits", "6"), ("MaximumNumberOfCallsOnwards", "1"),
        ])
    }

    /// A GET of `path` with `query`, each part escaped but for letters, digits and "-._~":
    /// URLComponents leaves "+" alone, which Bus Time would read as a space, and "M15+" as the
    /// M15.
    private static func request(_ path: String, _ query: [(String, String)]) -> URLRequest {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let escape = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let text = query.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = text
        var request = URLRequest(url: components?.url ?? base)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The stops in a stops-for-location answer, each with its lines: inline, as MTA Bus Time
    /// gives them, or as route ids looked up in its references, as other OneBusAway servers do.
    /// Nil if it isn't such an answer, or an error.
    static func candidates(in data: Data) -> [Candidate]? {
        struct Response: Decodable {
            var data: Body?
            struct Body: Decodable {
                var stops: [Stop]?
                var list: [Stop]?
                var references: References?
            }
            struct References: Decodable { var routes: [Route]? }
            struct Stop: Decodable {
                var id: String
                var code: String?
                var name: String?
                var lat: Double
                var lon: Double
                var direction: String?
                var routes: [Route]?
                var routeIds: [String]?
            }
            struct Route: Decodable {
                var id: String
                var shortName: String?
            }
        }
        guard let body = (try? JSONDecoder().decode(Response.self, from: data))?.data else { return nil }
        let named = Dictionary((body.references?.routes ?? []).map { ($0.id, $0) }) { first, _ in first }
        return (body.stops ?? body.list ?? []).map { stop in
            let routes = stop.routes ?? (stop.routeIds ?? []).map { named[$0] ?? Response.Route(id: $0) }
            return Candidate(
                stop: Stop(id: stop.code ?? bare(stop.id), name: stop.name ?? "", latitude: stop.lat,
                           longitude: stop.lon, direction: stop.direction),
                lines: routes.map { Candidate.Line(ref: $0.id, name: $0.shortName ?? bare($0.id)) }
            )
        }
    }

    /// The buses in a StopMonitoring answer, soonest first, from SIRI's version 1 or 2 (which
    /// gives names as lists). Nil if it isn't such an answer, or an error with no buses.
    static func arrivals(in data: Data) -> [Arrival]? {
        // SIRI's names start with a capital: ServiceDelivery, MonitoredCall
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int?
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
        }
        /// One name, or version 2's list of them.
        struct Name: Decodable {
            var text: String?
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                text = (try? container.decode(String.self)) ?? (try? container.decode([String].self))?.first
            }
        }
        struct Response: Decodable {
            var siri: Siri
            struct Siri: Decodable { var serviceDelivery: Delivery }
            struct Delivery: Decodable { var stopMonitoringDelivery: [Monitoring]? }
            struct Monitoring: Decodable {
                var monitoredStopVisit: [Visit]?
                var errorCondition: Problem?
            }
            struct Problem: Decodable {}
            struct Visit: Decodable { var monitoredVehicleJourney: Journey? }
            struct Journey: Decodable {
                var publishedLineName: Name?
                var destinationName: Name?
                var monitoredCall: Call?
            }
            struct Call: Decodable {
                var expectedArrivalTime: String?
                var aimedArrivalTime: String?
                var arrivalProximityText: String?
                var numberOfStopsAway: Int?
                var extensions: Extensions?
            }
            struct Extensions: Decodable { var distances: Distances? }
            struct Distances: Decodable {
                var presentableDistance: String?
                var stopsFromCall: Int?
            }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let name = path.last?.stringValue ?? ""
            return Key(stringValue: name.prefix(1).lowercased() + name.dropFirst())
        }
        guard let deliveries = (try? decoder.decode(Response.self, from: data))?.siri.serviceDelivery
            .stopMonitoringDelivery else { return nil }
        let visits = deliveries.flatMap { $0.monitoredStopVisit ?? [] }
        if visits.isEmpty, deliveries.contains(where: { $0.errorCondition != nil }) { return nil }
        let date = { (text: String?) in text.flatMap(Web.date) }
        return visits.compactMap { visit -> Arrival? in
            guard let journey = visit.monitoredVehicleJourney, let call = journey.monitoredCall else { return nil }
            let distances = call.extensions?.distances
            return Arrival(line: journey.publishedLineName?.text ?? "", destination: journey.destinationName?.text,
                           expected: date(call.expectedArrivalTime), aimed: date(call.aimedArrivalTime),
                           stopsAway: call.numberOfStopsAway ?? distances?.stopsFromCall,
                           distance: call.arrivalProximityText ?? distances?.presentableDistance)
        }
        .sorted { ($0.expected ?? $0.aimed ?? .distantFuture) < ($1.expected ?? $1.aimed ?? .distantFuture) }
    }
}
