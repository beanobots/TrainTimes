import Foundation

/// The station, line and direction the widget shows.
struct Selection: Codable, Hashable, Sendable {
    var stationID: String
    /// A real-time route id; see `Station.routes`.
    var route: String
    var direction: Direction
    /// Whether the widget mentions an elevator out at the station (the app always lists them).
    var elevatorAlerts: Bool
    /// Minutes to walk to the station. Trains you can't reach in time are left out,
    /// and the widget counts down to when to leave.
    var walkMinutes: Int

    init(stationID: String, route: String, direction: Direction, elevatorAlerts: Bool = false, walkMinutes: Int = 0) {
        self.stationID = stationID
        self.route = route
        self.direction = direction
        self.elevatorAlerts = elevatorAlerts
        self.walkMinutes = walkMinutes
    }

    /// Choices saved before `elevatorAlerts` and `walkMinutes` existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stationID = try container.decode(String.self, forKey: .stationID)
        route = try container.decode(String.self, forKey: .route)
        direction = try container.decode(Direction.self, forKey: .direction)
        elevatorAlerts = try container.decodeIfPresent(Bool.self, forKey: .elevatorAlerts) ?? false
        walkMinutes = try container.decodeIfPresent(Int.self, forKey: .walkMinutes) ?? 0
    }

    /// When to set off to reach the platform as `train` arrives.
    func leaveTime(for train: Arrival) -> Date {
        train.time.addingTimeInterval(-TimeInterval(walkMinutes * 60))
    }

    /// Trains of this line, and of any line that doesn't usually stop here, which
    /// must be running on this one: an N running local on the R. Lines that do
    /// usually stop here are left out; they're the station's other choices.
    func shows(_ train: Arrival) -> Bool {
        train.route == route || !(station?.routes.contains(train.route) ?? true)
    }

    /// The trains you can still reach in time if you leave at or after `now`.
    func catchable(_ trains: [Arrival], now: Date) -> [Arrival] {
        trains.filter { leaveTime(for: $0) > now }
    }

    /// Prospect Av, R, toward Manhattan: what the widget shows until you choose.
    static let fallback = Selection(stationID: "R34", route: "R", direction: .north)

    var stopID: String { stationID + direction.rawValue }
    var station: Station? { StationDirectory.station(id: stationID) }

    /// Moves to `station`, on `label`'s line if it has one, else the current line, else its first.
    mutating func choose(_ station: Station, preferring label: String? = nil) {
        stationID = station.id
        if let label, let match = station.routes.first(where: { LineStyle.of($0).label == label }) {
            route = match
        } else if !station.routes.contains(route), let first = station.routes.first {
            route = first
        }
    }

    /// A saved choice that no longer matches the station list falls back to the default.
    func validated() -> Selection {
        guard let station, station.routes.contains(route) else { return .fallback }
        return self
    }
}
