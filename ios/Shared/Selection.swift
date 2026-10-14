import Foundation

/// The station, lines and direction the widget shows.
struct Selection: Codable, Hashable, Sendable {
    var stationID: String
    /// One or more real-time route ids, in the order of `Station.routes`.
    var routes: [String]
    var direction: Direction
    /// Whether the widget mentions an elevator out at the station (the app always lists them).
    var elevatorAlerts: Bool
    /// Minutes to walk to the station. Trains you can't reach in time are left out,
    /// and the widget counts down to when to leave.
    var walkMinutes: Int

    init(stationID: String, routes: [String], direction: Direction, elevatorAlerts: Bool = false, walkMinutes: Int = 0) {
        self.stationID = stationID
        self.routes = routes
        self.direction = direction
        self.elevatorAlerts = elevatorAlerts
        self.walkMinutes = walkMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case stationID, routes, direction, elevatorAlerts, walkMinutes
        /// The one line chosen before more than one could be
        case route
    }

    /// Choices saved before `routes`, `elevatorAlerts` and `walkMinutes` existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stationID = try container.decode(String.self, forKey: .stationID)
        routes = try container.decodeIfPresent([String].self, forKey: .routes)
            ?? [container.decode(String.self, forKey: .route)]
        direction = try container.decode(Direction.self, forKey: .direction)
        elevatorAlerts = try container.decodeIfPresent(Bool.self, forKey: .elevatorAlerts) ?? false
        walkMinutes = try container.decodeIfPresent(Int.self, forKey: .walkMinutes) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stationID, forKey: .stationID)
        try container.encode(routes, forKey: .routes)
        try container.encode(direction, forKey: .direction)
        try container.encode(elevatorAlerts, forKey: .elevatorAlerts)
        try container.encode(walkMinutes, forKey: .walkMinutes)
    }

    /// The first chosen line, whose color stands for the choice.
    var firstRoute: String { routes.first ?? "" }

    /// "R", or "N/R" with more than one line chosen.
    var linesLabel: String { routes.map { LineStyle.of($0).label }.joined(separator: "/") }

    /// When to set off to reach the platform as `train` arrives.
    func leaveTime(for train: Arrival) -> Date {
        train.time.addingTimeInterval(-TimeInterval(walkMinutes * 60))
    }

    /// Trains of the chosen lines, and of any line that doesn't usually stop here,
    /// which must be running on one of them: an N running local on the R. Lines
    /// that do usually stop here are left out unless chosen.
    func shows(_ train: Arrival) -> Bool {
        routes.contains(train.route) || !(station?.routes.contains(train.route) ?? true)
    }

    /// Whether a train needs its bullet beside it: always, unless just one line
    /// is chosen and the train is on it.
    func marksLine(of train: Arrival) -> Bool {
        routes != [train.route]
    }

    /// The trains you can still reach in time if you leave at or after `now`.
    func catchable(_ trains: [Arrival], now: Date) -> [Arrival] {
        trains.filter { leaveTime(for: $0) > now }
    }

    /// Prospect Av, R, toward Manhattan: what the widget shows until you choose.
    static let fallback = Selection(stationID: "R34", routes: ["R"], direction: .north)

    var stopID: String { stationID + direction.rawValue }
    var station: Station? { StationDirectory.station(id: stationID) }

    /// Moves to `station`, on `label`'s line if it has one, else the current lines
    /// it has, else its first.
    mutating func choose(_ station: Station, preferring label: String? = nil) {
        stationID = station.id
        if let label, let match = station.routes.first(where: { LineStyle.of($0).label == label }) {
            routes = [match]
        } else {
            let kept = station.routes.filter(routes.contains)
            routes = kept.isEmpty ? Array(station.routes.prefix(1)) : kept
        }
    }

    /// Adds `route` to the chosen lines, or takes it out unless it's the only one.
    mutating func toggle(_ route: String) {
        guard let station else { return }
        if routes.contains(route) {
            if routes.count > 1 { routes.removeAll { $0 == route } }
        } else {
            routes = station.routes.filter { routes.contains($0) || $0 == route }
        }
    }

    /// A saved choice that no longer matches the station list falls back to the
    /// default; a line the station has lost is just dropped.
    func validated() -> Selection {
        guard let station else { return .fallback }
        var selection = self
        selection.routes = station.routes.filter(routes.contains)
        return selection.routes.isEmpty ? .fallback : selection
    }
}
