import AppIntents
import Foundation

/// One or more lines at one platform, e.g. "Prospect Av: R Manhattan": what a
/// widget's Edit menu or a shortcut is set to.
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

    /// Nil where the station's gone or has none of the lines left, as for any
    /// train that isn't the app's own. The lines are kept as they were, so the
    /// id stays the same; `selection(basedOn:)` leaves out any the station has lost.
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

    /// The selection this stands for, keeping the app's other settings (walking
    /// time, alerts). One set up when its platform was a station of its
    /// own is for the station it's part of.
    func selection(basedOn app: Selection) -> Selection {
        selection(keeping: app).validated()
    }

    /// The selection this stands for, with `app`'s walking time and alerts,
    /// before it's checked against the stations.
    func selection(keeping app: Selection) -> Selection {
        Selection(stationID: stationID, routes: routes, direction: direction, elevatorAlerts: app.elevatorAlerts,
                  serviceAlerts: app.serviceAlerts, walkMinutes: app.walkMinutes)
    }

    /// At `station`, both directions of each line on its own, of each platform's
    /// lines together, and of all its lines together, where those are more than one.
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

    /// Every choice at every station: about 2,000.
    static let all: [StopEntity] = StationDirectory.all.flatMap(choices(at:))
}

extension Selection {
    /// Its train and which alerts it mentions: whether its widgets' alert is
    /// open is kept by this, so a widget that leaves an alert out doesn't close
    /// it on another that mentions it.
    var alertID: String { "\(trainID) \(elevatorAlerts) \(serviceAlerts)" }

    /// What Siri and its countdown go by when no train is picked: the train
    /// the default widget shows at `date`, in its commuting hours theirs.
    static func defaultWidgetTrain(at date: Date = .now) -> Selection {
        SharedStore.loadWidgets().defaultWidget.shown(at: date).selection
    }
}

struct StopQuery: EntityStringQuery {
    func entities(for identifiers: [StopEntity.ID]) async throws -> [StopEntity] {
        identifiers.compactMap { StopEntity(id: $0) }
    }

    /// Search by station and borough, as the app's train picker does, e.g.
    /// "prospect", "86 st brooklyn" or "34th street".
    func entities(matching string: String) async throws -> [StopEntity] {
        let search = StationSearch(string)
        let stations = Set(StationDirectory.all.filter(search.matches).map(\.id))
        let matches = StopEntity.all.filter { stations.contains($0.stationID) }
        return Array(matches.prefix(60))
    }

    /// The default widget's train first, then the other lines and direction at that station.
    func suggestedEntities() async throws -> [StopEntity] {
        let app = Selection.defaultWidgetTrain()
        guard let station = app.station else { return [] }
        let chosen = StopEntity(stationID: station.id, direction: app.direction, routes: app.routes)
        return [chosen] + StopEntity.choices(at: station).filter { $0.id != chosen.id }
    }
}
