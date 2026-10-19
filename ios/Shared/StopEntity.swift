import AppIntents
import Foundation

/// One or more lines at one platform, e.g. "Prospect Av: R Manhattan": what a
/// widget's Edit menu or a shortcut is set to.
struct StopEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Train"
    static let defaultQuery = StopQuery()

    /// "R34:N:R": station, direction, line; "R31:N:N,R" for more than one line.
    let id: String
    let stationID: String
    let direction: Direction
    let routes: [String]

    init(stationID: String, direction: Direction, routes: [String]) {
        self.stationID = stationID
        self.direction = direction
        self.routes = routes
        id = "\(stationID):\(direction.rawValue):\(routes.joined(separator: ","))"
    }

    init?(id: String) {
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count == 3,
              let direction = Direction(rawValue: parts[1]),
              let station = StationDirectory.station(id: parts[0]) else { return nil }
        let routes = parts[2].split(separator: ",").map(String.init)
        guard !routes.isEmpty, routes.allSatisfy(station.routes.contains) else { return nil }
        self.init(stationID: parts[0], direction: direction, routes: routes)
    }

    var station: Station? { StationDirectory.station(id: stationID) }

    var displayRepresentation: DisplayRepresentation {
        let name = station?.name ?? stationID
        let lines = routes.map { LineStyle.of($0).label }.joined(separator: "/")
        let heading = station?.directionLabel(direction, routes: routes) ?? ""
        return DisplayRepresentation(title: "\(name): \(lines) \(heading)", subtitle: "\(station?.borough ?? "")")
    }

    /// The selection this stands for, keeping the app's other settings (walking
    /// time, alerts). One set up when its platform was a station of its
    /// own is for the station it's part of.
    func selection(basedOn app: Selection) -> Selection {
        Selection(stationID: stationID, routes: routes, direction: direction, elevatorAlerts: app.elevatorAlerts,
                  serviceAlerts: app.serviceAlerts, walkMinutes: app.walkMinutes)
            .validated()
    }

    /// At `station`, both directions of each line on its own, of each platform's
    /// lines together, and of all its lines together, where those are more than one.
    static func choices(at station: Station) -> [StopEntity] {
        var lines = station.routes.map { [$0] }
        let together = station.platforms.map { platform in station.routes.filter(platform.routes.contains) } + [station.routes]
        for routes in together where routes.count > 1 && !lines.contains(routes) {
            lines.append(routes)
        }
        return lines.flatMap { routes in
            Direction.allCases.map { StopEntity(stationID: station.id, direction: $0, routes: routes) }
        }
    }

    /// Every choice at every station: about 2,000.
    static let all: [StopEntity] = StationDirectory.all.flatMap(choices(at:))
}

extension Selection {
    /// Its station, direction and lines, as a `StopEntity` id: which train this is,
    /// whatever the walking time.
    var trainID: String { StopEntity(stationID: stationID, direction: direction, routes: routes).id }

    /// Its train and which alerts it mentions: whether its widgets' alert is
    /// open is kept by this, so a widget that leaves an alert out doesn't close
    /// it on another that mentions it.
    var alertID: String { "\(trainID) \(elevatorAlerts) \(serviceAlerts)" }
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
        let chosen = StopEntity(stationID: station.id, direction: app.direction, routes: app.routes)
        return [chosen] + StopEntity.choices(at: station).filter { $0.id != chosen.id }
    }
}
