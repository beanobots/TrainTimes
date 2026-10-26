import Foundation

/// The station, lines and direction the widget shows.
struct Selection: Codable, Hashable, Sendable {
    /// A `Station.id`; in older saves, possibly the id of one of its platforms.
    var stationID: String
    /// One or more real-time route ids, in the order of `Station.routes`.
    var routes: [String]
    /// The feed's N or S for the chosen lines. Where some run opposite to the rest on their
    /// platform (the M vs the J at Marcy Av), this is the rest's; see `direction(of:at:)`.
    var direction: Direction
    /// Whether the widget mentions an elevator out at the station (the app always lists them).
    var elevatorAlerts: Bool
    /// Whether the widget mentions the MTA's service alerts (the app always lists them).
    var serviceAlerts: Bool
    /// Minutes to walk to the station. Unreachable trains are hidden; the widget counts down to
    /// when to leave.
    var walkMinutes: Int

    init(stationID: String, routes: [String], direction: Direction, elevatorAlerts: Bool = false, serviceAlerts: Bool = true, walkMinutes: Int = 0) {
        self.stationID = stationID
        self.routes = routes
        self.direction = direction
        self.elevatorAlerts = elevatorAlerts
        self.serviceAlerts = serviceAlerts
        self.walkMinutes = walkMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case stationID, routes, direction, elevatorAlerts, serviceAlerts, walkMinutes
        /// Legacy single-line key, from before multiple lines
        case route
    }

    /// Older saves missing `routes`, `elevatorAlerts`, `serviceAlerts` or `walkMinutes` still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stationID = try container.decode(String.self, forKey: .stationID)
        routes = try container.decodeIfPresent([String].self, forKey: .routes)
            ?? [container.decode(String.self, forKey: .route)]
        direction = try container.decode(Direction.self, forKey: .direction)
        elevatorAlerts = try container.decodeIfPresent(Bool.self, forKey: .elevatorAlerts) ?? false
        serviceAlerts = try container.decodeIfPresent(Bool.self, forKey: .serviceAlerts) ?? true
        // Kept here, as the server reads it from registrations; the app drops a saved one
        // (`droppingSavedWalk`)
        walkMinutes = try container.decodeIfPresent(Int.self, forKey: .walkMinutes) ?? 0
    }

    /// The app's saved choices without their walking time to the station, which can no longer
    /// be set, so a saved one can't hide trains with no way to change it.
    var droppingSavedWalk: Selection {
        var selection = self
        selection.walkMinutes = 0
        return selection
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stationID, forKey: .stationID)
        try container.encode(routes, forKey: .routes)
        try container.encode(direction, forKey: .direction)
        try container.encode(elevatorAlerts, forKey: .elevatorAlerts)
        try container.encode(serviceAlerts, forKey: .serviceAlerts)
        try container.encode(walkMinutes, forKey: .walkMinutes)
    }

    /// The first chosen line; its color represents the selection.
    var firstRoute: String { routes.first ?? "" }

    /// "R", or "N/R" with more than one line chosen.
    var linesLabel: String { routes.map { LineStyle.of($0).label }.joined(separator: "/") }

    /// Lines and heading, as the app lists a train: "N and R Manhattan".
    var caption: String { "\(Lines.list(routes)) \(heading)" }

    /// Identifies the train by station, direction and lines (ignoring walk time). Also its
    /// `StopEntity` id.
    var trainID: String { Self.trainID(stationID: stationID, direction: direction, routes: routes) }

    /// "R34:N:R" (station:direction:lines), or "R31:N:N,R" for several lines.
    static func trainID(stationID: String, direction: Direction, routes: [String]) -> String {
        "\(stationID):\(direction.rawValue):\(routes.joined(separator: ","))"
    }

    /// When to set off to reach the platform as `train` arrives.
    func leaveTime(for train: Arrival) -> Date {
        train.time.addingTimeInterval(-TimeInterval(walkMinutes) * 60)
    }

    /// The latest you can set off and still catch `train`; later than `leaveTime(for:)` for a
    /// train held at the platform.
    func lastLeaveTime(for train: Arrival) -> Date {
        train.leaves.addingTimeInterval(-TimeInterval(walkMinutes) * 60)
    }

    /// Whether to show `train`: chosen lines, plus lines that don't usually stop at the platform
    /// (so must be rerouted onto a chosen one, e.g. an N running local on the R). Unchosen lines
    /// that usually stop there are hidden. Each line uses its own N/S (`direction(of:at:)`).
    /// Where a line runs opposite to the rest, trains on a track no chosen line uses are hidden
    /// (`Platform.carries(_:with:)`), e.g. an E with the G alone at Hoyt-Schermerhorn Sts.
    func shows(_ train: Arrival) -> Bool {
        shows(train, at: station)
    }

    /// `shows(_:)`, with `station` looked up once for many trains.
    func shows(_ train: Arrival, at station: Station?) -> Bool {
        let platform = station?.platforms.first { $0.id == train.stop.dropLast() }
        // Only reversed platforms have chosen lines at both N and S, or tracks none of them use
        if let platform, platform.reversed != nil,
           !train.stop.hasSuffix(direction(of: train.route, at: platform).rawValue)
               || !platform.carries(train.route, with: routes) { return false }
        if routes.contains(train.route) { return true }
        let usual = platform?.routes ?? station?.routes
        return !(usual?.contains(train.route) ?? true)
    }

    /// Whether to show the train's bullet: unless it's the only chosen line.
    func marksLine(of train: Arrival) -> Bool {
        routes != [train.route]
    }

    /// The trains you can still reach in time if you leave at or after `now`.
    func catchable(_ trains: [Arrival], now: Date) -> [Arrival] {
        trains.filter { lastLeaveTime(for: $0) > now }
    }

    /// Connections whose first train you can still reach if you leave at or after `now`.
    func catchable(_ connections: [Connection], now: Date) -> [Connection] {
        connections.filter { lastLeaveTime(for: $0.first) > now }
    }

    /// The first train you can reach by its arrival (not just while held there) if you leave at
    /// or after `now`. The countdown starts on it, since it counts down to arrivals.
    func firstReachable(_ trains: [Arrival], now: Date) -> Arrival? {
        trains.first { leaveTime(for: $0) > now }
    }

    /// The first connection whose first train you reach by its arrival. The Transfers widget's
    /// walk button counts down to it; it may not be the first one shown.
    func firstReachable(_ connections: [Connection], now: Date) -> Connection? {
        connections.first { leaveTime(for: $0.first) > now }
    }

    /// Default until you choose: Prospect Av, R, toward Manhattan.
    static let fallback = Selection(stationID: "R34", routes: ["R"], direction: .north)

    var station: Station? { StationDirectory.station(id: stationID) }

    /// The chosen lines' platforms; more than one if they differ (N and 2 at Atlantic Av).
    var platforms: [Platform] { station?.platforms(serving: routes) ?? [] }

    /// The feed's N or S for `route` at `platform`: `direction`, flipped where the line runs
    /// opposite to another chosen line there (`Platform.direction(_:of:with:)`), so all go the way
    /// `heading` names. Toward Manhattan from Marcy Av, the J and Z are S and the M is N.
    func direction(of route: String, at platform: Platform) -> Direction {
        platform.direction(direction, of: route, with: routes)
    }

    /// `direction(of:at:)` at the route's platform; constant along its line.
    func direction(of route: String) -> Direction {
        station?.direction(direction, of: route, with: routes) ?? direction
    }

    /// Feed stop ids for the chosen lines, e.g. "R31N". Includes both N and S where lines run
    /// opposite ways on a platform (Marcy Av: J "M16S", M "M16N"), or where a line runs opposite
    /// on another's track, since other trains there may use either (`Platform.sharesTrack`).
    var stopIDs: [String] {
        platforms.flatMap { platform -> [String] in
            let stops = platform.stops(of: routes, going: direction)
            guard platform.sharesTrack else { return stops }
            let both = [direction, direction.opposite].map { platform.id + $0.rawValue }
            return stops + both.filter { !stops.contains($0) }
        }
    }

    /// The same station and lines going the other way, for Next train showing both directions.
    var otherWay: Selection {
        var selection = self
        selection.direction = direction.opposite
        return selection
    }

    /// Where the chosen lines go: "Manhattan".
    var heading: String { station?.directionLabel(direction, routes: routes) ?? "" }

    /// Where `train` goes from its platform, by its own line's way; can be just one of `heading`'s
    /// names when platforms name it differently. A line that doesn't usually stop at the platform
    /// is labeled as the chosen lines going their way there (e.g. an F on the G's track at
    /// Hoyt-Schermerhorn Sts gets the G's "Church Av").
    func heading(of train: Arrival) -> String {
        guard let platform = platform(of: train), let way = Direction(ofStop: train.stop) else { return heading }
        let chosen = routes.filter(platform.routes.contains)
        if !platform.routes.contains(train.route), !chosen.isEmpty {
            return Station.directionLabel(direction, on: [platform], routes: chosen)
        }
        return Station.directionLabel(way, on: [platform], routes: [train.route])
    }

    private func platform(of train: Arrival) -> Platform? {
        station?.platforms.first { $0.id == train.stop.dropLast() }
    }

    /// Falls back to `fallback` if the station or all its lines are gone; drops lost lines; moves
    /// a saved platform id to its parent station.
    func validated() -> Selection {
        guard let station else { return .fallback }
        var selection = self
        selection.stationID = station.id
        selection.routes = station.routes.filter(routes.contains)
        return selection.routes.isEmpty ? .fallback : selection
    }

    /// `validated()`, but nil instead of the fallback. For trains not chosen in the app, such as
    /// from shortcuts.
    func validatedIfKnown() -> Selection? {
        guard let station, station.routes.contains(where: routes.contains) else { return nil }
        return validated()
    }
}

/// The app's URL scheme, for the Nearby widget's "allow location" link.
enum AppLink {
    static let scheme = "traintimes"
}
