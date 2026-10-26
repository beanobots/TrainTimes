import AppIntents
import Foundation

/// One or more lines at a platform, e.g. "Prospect Av: R Manhattan", for shortcuts and legacy
/// widget configs.
struct StopEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Train"
    static let defaultQuery = StopQuery()

    /// A `Selection.trainID`: "R34:N:R", or "R31:N:N,R" for more than one line.
    let id: String
    let stationID: String
    let direction: Direction
    let routes: [String]

    init(stationID: String, direction: Direction, routes: [String]) {
        self.stationID = stationID
        self.direction = direction
        self.routes = routes
        id = Selection.trainID(stationID: stationID, direction: direction, routes: routes)
    }

    /// Nil if the station is gone or has none of the lines left. Lines are kept as-is so the id
    /// is stable; `selection(basedOn:)` drops any the station has lost.
    init?(id: String) {
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count == 3, let direction = Direction(rawValue: parts[1]) else { return nil }
        let routes = parts[2].split(separator: ",").map(String.init)
        guard Selection(stationID: parts[0], routes: routes, direction: direction).validatedIfKnown() != nil else { return nil }
        self.init(stationID: parts[0], direction: direction, routes: routes)
    }

    var station: Station? { StationDirectory.station(id: stationID) }

    var displayRepresentation: DisplayRepresentation {
        let name = station?.name ?? stationID
        let train = Selection(stationID: stationID, routes: routes, direction: direction)
        return DisplayRepresentation(title: "\(name): \(train.linesLabel) \(train.heading)", subtitle: "\(station?.borough ?? "")")
    }

    /// The validated selection, with `app`'s walking time and alerts. A platform that was once
    /// its own station maps to the station it's now part of.
    func selection(basedOn app: Selection) -> Selection {
        selection(keeping: app).validated()
    }

    /// As `selection(basedOn:)`, unvalidated.
    func selection(keeping app: Selection) -> Selection {
        Selection(stationID: stationID, routes: routes, direction: direction, elevatorAlerts: app.elevatorAlerts,
                  serviceAlerts: app.serviceAlerts, walkMinutes: app.walkMinutes)
    }

    /// Both directions of each line, each multi-line platform, and all the station's lines.
    static func choices(at station: Station) -> [StopEntity] {
        var lines = station.routes.map { [$0] }
        let together = station.platforms.map(station.lines(on:)) + [station.routes]
        for routes in together where routes.count > 1 && !lines.contains(routes) {
            lines.append(routes)
        }
        return lines.flatMap { routes in
            Direction.allCases.map { StopEntity(stationID: station.id, direction: $0, routes: routes) }
        }
    }

    /// About 2,000.
    static let all: [StopEntity] = StationDirectory.all.flatMap(choices(at:))
}

extension Selection {
    /// For Siri and the countdown when no train is picked: Settings' default train.
    static var defaultTrain: Selection { SharedStore.defaultTrain }
}

struct StopQuery: EntityStringQuery {
    func entities(for identifiers: [StopEntity.ID]) async throws -> [StopEntity] {
        identifiers.compactMap { StopEntity(id: $0) }
    }

    /// Station and borough search, as in the app's picker, e.g. "86 st brooklyn".
    func entities(matching string: String) async throws -> [StopEntity] {
        let search = StationSearch(string)
        let stations = Set(StationDirectory.all.filter(search.matches).map(\.id))
        let matches = StopEntity.all.filter { stations.contains($0.stationID) }
        return Array(matches.prefix(60))
    }

    /// The default train, then the station's other choices.
    func suggestedEntities() async throws -> [StopEntity] {
        let app = Selection.defaultTrain
        guard let station = app.station else { return [] }
        let chosen = StopEntity(stationID: station.id, direction: app.direction, routes: app.routes)
        return [chosen] + StopEntity.choices(at: station).filter { $0.id != chosen.id }
    }
}
