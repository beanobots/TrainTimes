import AppIntents
import Foundation

/// One line at one platform, e.g. "Prospect Av: R to Manhattan": what a widget's
/// Edit menu or a shortcut is set to.
struct StopEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Train"
    static let defaultQuery = StopQuery()

    /// "R34:N:R": station, direction, line.
    let id: String
    let stationID: String
    let direction: Direction
    let route: String

    init(stationID: String, direction: Direction, route: String) {
        self.stationID = stationID
        self.direction = direction
        self.route = route
        id = "\(stationID):\(direction.rawValue):\(route)"
    }

    init?(id: String) {
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count == 3,
              let direction = Direction(rawValue: parts[1]),
              let station = StationDirectory.station(id: parts[0]),
              station.routes.contains(parts[2]) else { return nil }
        self.init(stationID: parts[0], direction: direction, route: parts[2])
    }

    var station: Station? { StationDirectory.station(id: stationID) }

    var displayRepresentation: DisplayRepresentation {
        let name = station?.name ?? stationID
        let line = LineStyle.of(route).label
        let heading = station?.directionLabel(direction) ?? ""
        return DisplayRepresentation(title: "\(name): \(line) \(heading)", subtitle: "\(station?.borough ?? "")")
    }

    /// The selection this stands for, keeping the app's other settings (walking time, elevator alerts).
    func selection(basedOn app: Selection) -> Selection {
        Selection(stationID: stationID, route: route, direction: direction, elevatorAlerts: app.elevatorAlerts, walkMinutes: app.walkMinutes)
    }

    /// Every line at every platform, both directions: about 1,500.
    static let all: [StopEntity] = StationDirectory.all.flatMap { station in
        station.routes.flatMap { route in
            Direction.allCases.map { StopEntity(stationID: station.id, direction: $0, route: route) }
        }
    }
}

struct StopQuery: EntityStringQuery {
    func entities(for identifiers: [StopEntity.ID]) async throws -> [StopEntity] {
        identifiers.compactMap { StopEntity(id: $0) }
    }

    /// Search by station and borough, e.g. "prospect" or "86 st brooklyn".
    func entities(matching string: String) async throws -> [StopEntity] {
        let words = string.lowercased().split(separator: " ")
        let matches = StopEntity.all.filter { stop in
            guard let station = stop.station else { return false }
            let text = "\(station.name) \(station.borough)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        return Array(matches.prefix(60))
    }

    /// The app's choice first, then the other lines and direction at that station.
    func suggestedEntities() async throws -> [StopEntity] {
        let app = SharedStore.load()
        guard let station = app.station else { return [] }
        let chosen = StopEntity(stationID: station.id, direction: app.direction, route: app.route)
        let others = station.routes.flatMap { route in
            Direction.allCases.map { StopEntity(stationID: station.id, direction: $0, route: route) }
        }
        return [chosen] + others.filter { $0.id != chosen.id }
    }
}
