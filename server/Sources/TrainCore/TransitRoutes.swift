import Foundation

/// Trips between two places in the city (`GET /routes`), planned on the subway's and the
/// buses' timetables (`TransitPlanner`), keeping to daily limits so no one client can keep the
/// server busy: each client's, and everyone's together.
actor TransitRoutes {
    /// The network to plan on; nil while there's no timetable yet.
    typealias Network = @Sendable () async -> TransitNetwork?

    enum Outcome: Equatable, Sendable {
        case routes([TransitRoute])
        /// Over a daily limit, until the counts start again.
        case limited(retryAfter: Int)
        /// No timetable to plan on yet, or none for what's asked: buses, before the buses' is made.
        case unavailable
    }

    /// How long the routes for a trip are kept, for the same asked again (the Share extension
    /// and the app asking together, or asking again): timetables don't move in that time.
    static let keptFor: TimeInterval = 2 * 60
    /// Kept routes before the ones gone stale are cleared.
    static let maxKept = 1000

    private let perClient: DailyLimiter
    private let everyone: DailyLimiter
    private let network: Network
    /// Routes found, by `trip(from:to:departure:bus:subway:)`.
    private var kept: [String: (routes: [TransitRoute], until: Date)] = [:]

    init(perClientPerDay: Int, perDay: Int, network: @escaping Network) {
        perClient = DailyLimiter(limit: perClientPerDay, byAddress: true)
        everyone = DailyLimiter(limit: perDay)
        self.network = network
    }

    /// Planning on the timetables the server serves (`TransitNetworks`).
    init(perClientPerDay: Int, perDay: Int, subway: TimetableCopy, buses: TimetableCopy) {
        let networks = TransitNetworks(subway: subway, buses: buses)
        self.init(perClientPerDay: perClientPerDay, perDay: perDay) { await networks.current() }
    }

    /// Routes from `from` to `to` leaving at `departure`, best first, for `client`; by bus too
    /// with `bus`, or by bus alone without `subway`. Each counts toward the limits whether or not
    /// it finds a route, but one for the same trip (`trip`) as one kept (`keptFor`) counts toward
    /// nothing.
    func routes(from: (Double, Double), to: (Double, Double), departure: Date, client: String,
                bus: Bool = false, subway: Bool = true, now: Date = .now) async -> Outcome {
        let trip = Self.trip(from: from, to: to, departure: departure, bus: bus, subway: subway)
        if let found = kept[trip], found.until > now { return .routes(found.routes) }
        guard await perClient.take(client, now: now), await everyone.take("everyone", now: now) else {
            return .limited(retryAfter: DailyLimiter.secondsUntilReset(now: now))
        }
        var asked: Set<TransitRoute.Mode> = subway || !bus ? [.subway] : []
        if bus { asked.insert(.bus) }
        // By the modes it has timetables for: trains alone, if the buses' isn't made yet
        guard let network = await network() else { return .unavailable }
        var have: Set<TransitRoute.Mode> = []
        if network.subwayMade != nil { have.insert(.subway) }
        if network.busMade != nil { have.insert(.bus) }
        let modes = asked.intersection(have)
        guard !modes.isEmpty else { return .unavailable }
        // Off the actor: planning takes a moment, and others' asks shouldn't wait on it
        let routes = await Task.detached(priority: .userInitiated) {
            TransitPlanner.routes(on: network, from: from, to: to, departure: departure, modes: modes)
        }.value
        if kept.count >= Self.maxKept { kept = kept.filter { $0.value.until > now } }
        if kept.count >= Self.maxKept { kept.removeAll() }
        kept[trip] = (routes, now.addingTimeInterval(Self.keptFor))
        return .routes(routes)
    }

    /// What makes two asks the same trip: their places to 4 decimals (about 10 m), leaving in
    /// the same minute, by the same modes.
    static func trip(from: (Double, Double), to: (Double, Double), departure: Date, bus: Bool, subway: Bool) -> String {
        String(format: "%.4f,%.4f %.4f,%.4f ", from.0, from.1, to.0, to.1)
            + "\(Int((departure.timeIntervalSince1970 / 60).rounded(.down))) \(bus ? "bus" : "")\(subway ? "subway" : "")"
    }

    /// Whether a point is in New York City, around its subway: trips elsewhere aren't planned.
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

/// The network for the timetables the server serves (`TimetableCopy`), built again once either
/// is newer. A build takes a few seconds, so a request meanwhile waits for it, and so does one
/// asking at the same time.
actor TransitNetworks {
    private let subway: TimetableCopy
    private let buses: TimetableCopy
    private var built: TransitNetwork?
    private var building: (subway: Date?, buses: Date?, task: Task<TransitNetwork?, Never>)?

    init(subway: TimetableCopy, buses: TimetableCopy) {
        self.subway = subway
        self.buses = buses
    }

    /// The network, nil if neither timetable is made yet.
    func current() async -> TransitNetwork? {
        let subwayMade = await subway.made, busMade = await buses.made
        if let built, built.subwayMade == subwayMade, built.busMade == busMade { return built }
        guard subwayMade != nil || busMade != nil else { return nil }
        if let building, building.subway == subwayMade, building.buses == busMade { return await building.task.value }
        let subwayData = await subway.data, busData = await buses.data
        let task = Task.detached(priority: .utility) { () -> TransitNetwork? in
            let started = ContinuousClock.now
            let subway = subwayData.flatMap { try? Timetable(data: $0) }
            let buses = busData.flatMap { try? Timetable(data: $0) }
            guard subway != nil || buses != nil else { return nil }
            let network = TransitNetwork(subway: subway, buses: buses)
            Log.info("routes: planning on \(network.stops.count) stops, \(network.patterns.count) patterns, "
                + "built in \((ContinuousClock.now - started).components.seconds) s")
            return network
        }
        building = (subwayMade, busMade, task)
        let network = await task.value
        if building?.task == task { building = nil }
        if let network { built = network }
        return network ?? built
    }
}
