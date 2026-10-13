import Foundation

/// The station, line and direction the widget shows.
struct Selection: Codable, Hashable, Sendable {
    var stationID: String
    /// A real-time route id; see `Station.routes`.
    var route: String
    var direction: Direction
    /// Whether the widget mentions an elevator out at the station (the app always lists them).
    var elevatorAlerts: Bool

    init(stationID: String, route: String, direction: Direction, elevatorAlerts: Bool = false) {
        self.stationID = stationID
        self.route = route
        self.direction = direction
        self.elevatorAlerts = elevatorAlerts
    }

    /// Choices saved before `elevatorAlerts` existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stationID = try container.decode(String.self, forKey: .stationID)
        route = try container.decode(String.self, forKey: .route)
        direction = try container.decode(Direction.self, forKey: .direction)
        elevatorAlerts = try container.decodeIfPresent(Bool.self, forKey: .elevatorAlerts) ?? false
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
