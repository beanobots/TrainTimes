import AppIntents
import UIKit

// What a widget's Edit menu offers: a station, a line and a direction, chosen
// in any order. Choosing a line first narrows the stations to the ones it stops
// at; choosing a station first lists its lines by platform.

/// A station, as the Edit menu lists it: its name, with its lines and borough.
struct StationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Station"
    static let defaultQuery = StationQuery()

    /// A `Station.id`.
    let id: String

    var station: Station? { StationDirectory.station(id: id) }

    var displayRepresentation: DisplayRepresentation {
        guard let station else { return DisplayRepresentation(title: "\(id)") }
        // The three shuttles share the S
        var labels: [String] = []
        for label in station.routes.map({ LineStyle.of($0).label }) where !labels.contains(label) {
            labels.append(label)
        }
        return DisplayRepresentation(title: "\(station.name)", subtitle: "\(labels.joined(separator: " ")) · \(station.borough)")
    }
}

struct StationQuery: EntityStringQuery {
    @IntentParameterDependency<TrainWidgetIntent>(\.$line)
    var widget

    /// Every station, or with a line chosen, the ones it stops at.
    private var stations: [Station] {
        guard let routes = widget?.line.routes else { return StationDirectory.all }
        return StationDirectory.all.filter { $0.routes.contains(where: routes.contains) }
    }

    func entities(for identifiers: [StationEntity.ID]) async throws -> [StationEntity] {
        identifiers.compactMap { StationDirectory.station(id: $0).map { StationEntity(id: $0.id) } }
    }

    /// By station and borough, e.g. "prospect" or "86 st brooklyn".
    func entities(matching string: String) async throws -> IntentItemCollection<StationEntity> {
        let words = string.lowercased().split(separator: " ")
        let matches = stations.filter { station in
            words.allSatisfy { "\(station.name) \(station.borough)".lowercased().contains($0) }
        }
        return collection([ChoiceGroup(title: "Stations", items: matches.map { StationEntity(id: $0.id) })])
    }

    /// With a line chosen, its stations; otherwise the app's station first, then all of them.
    func suggestedEntities() async throws -> IntentItemCollection<StationEntity> {
        let all = stations.map { StationEntity(id: $0.id) }
        if let line = widget?.line {
            return collection([ChoiceGroup(title: "Stations on the \(line.title)", items: all)])
        }
        guard let app = SharedStore.load().station else {
            return collection([ChoiceGroup(title: "Stations", items: all)])
        }
        return collection([
            ChoiceGroup(title: "In the app", items: [StationEntity(id: app.id)]),
            ChoiceGroup(title: "Stations", items: all),
        ])
    }
}

/// One line, a platform's lines together, or every line at a station.
struct LineEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Line"
    static let defaultQuery = LineQuery()

    /// "R"; "D,N,R", one platform's lines together; or "all:2,3,4,5,B,D,N,Q,R",
    /// every line at a station of several platforms.
    let id: String
    /// Real-time route ids, in their station's order.
    let routes: [String]
    let isAll: Bool

    init(routes: [String], isAll: Bool = false) {
        self.routes = routes
        self.isAll = isAll
        id = (isAll ? "all:" : "") + routes.joined(separator: ",")
    }

    init?(id: String) {
        let isAll = id.hasPrefix("all:")
        let routes = id.dropFirst(isAll ? 4 : 0).split(separator: ",").map(String.init)
        guard !routes.isEmpty else { return nil }
        self.init(routes: routes, isAll: isAll)
    }

    /// "R", "42 St Shuttle", "D, N and R", "All 9 lines"
    var title: String { isAll ? "All \(routes.count) lines" : Lines.list(routes) }

    var displayRepresentation: DisplayRepresentation {
        var subtitle: LocalizedStringResource?
        if routes.count == 1, let ends = Self.shuttleEnds[routes[0]] {
            subtitle = "\(ends)"
        } else if isAll {
            subtitle = "Every platform at the station"
        } else if routes.count > 1 {
            subtitle = "Everything on this platform"
        }
        let image = BulletImage.data(for: routes).map { DisplayRepresentation.Image(data: $0) }
        return DisplayRepresentation(title: "\(title)", subtitle: subtitle, image: image)
    }

    /// Where each shuttle runs, since their bullets are all an S.
    private static let shuttleEnds = [
        "GS": "Times Sq-42 St to Grand Central",
        "FS": "Franklin Av to Prospect Park",
        "H": "Broad Channel to Rockaway Park",
    ]
}

struct LineQuery: EntityStringQuery {
    @IntentParameterDependency<TrainWidgetIntent>(\.$station)
    var widget

    /// At a station: each platform's lines, one at a time or all together, then
    /// every line there. Without one: every line, by the trunk it runs on.
    private var groups: [ChoiceGroup<LineEntity>] {
        guard let station = widget?.station.station else {
            return Lines.trunks.map { trunk in
                ChoiceGroup(title: trunk.name, items: trunk.routes.map { LineEntity(routes: [$0]) })
            }
        }
        var groups = station.platforms.map { platform in
            let routes = station.routes.filter(platform.routes.contains)
            var lines = routes.map { LineEntity(routes: [$0]) }
            if routes.count > 1 { lines.append(LineEntity(routes: routes)) }
            let labels = routes.map { LineStyle.of($0).label }.joined(separator: " ")
            return ChoiceGroup(title: "\(labels) platform", items: lines)
        }
        if station.platforms.count > 1 {
            groups.append(ChoiceGroup(title: "Every line", items: [LineEntity(routes: station.routes, isAll: true)]))
        }
        return groups
    }

    func entities(for identifiers: [LineEntity.ID]) async throws -> [LineEntity] {
        identifiers.compactMap(LineEntity.init(id:))
    }

    /// By a line's letter ("r"), a trunk's name ("broadway") or a shuttle's ("franklin").
    func entities(matching string: String) async throws -> IntentItemCollection<LineEntity> {
        let query = string.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = groups.compactMap { group -> ChoiceGroup<LineEntity>? in
            if query.count > 2 && group.title.lowercased().contains(query) { return group }
            let lines = group.items.filter { line in
                guard line.routes.count == 1 else { return false }
                return LineStyle.of(line.routes[0]).label.lowercased() == query
                    || (query.count > 2 && line.title.lowercased().contains(query))
            }
            return lines.isEmpty ? nil : ChoiceGroup(title: group.title, items: lines)
        }
        return collection(matches)
    }

    func suggestedEntities() async throws -> IntentItemCollection<LineEntity> {
        collection(groups)
    }
}

/// North or south, named by the station and lines it was chosen for where
/// they're known: "to Manhattan".
struct DirectionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Direction"
    static let defaultQuery = DirectionQuery()

    /// "N" or "S", then where known the station and lines that name it: "N:R31:N,R".
    let id: String
    let direction: Direction
    private let stationID: String?
    private let routes: [String]

    init(_ direction: Direction, station: Station? = nil, routes: [String] = []) {
        self.direction = direction
        stationID = station?.id
        self.routes = routes
        id = station.map { "\(direction.rawValue):\($0.id):\(routes.joined(separator: ","))" } ?? direction.rawValue
    }

    init?(id: String) {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let direction = Direction(rawValue: parts[0]) else { return nil }
        if parts.count == 3, let station = StationDirectory.station(id: parts[1]) {
            self.init(direction, station: station, routes: parts[2].split(separator: ",").map(String.init))
        } else {
            self.init(direction)
        }
    }

    private var bound: String { direction == .north ? "Northbound" : "Southbound" }

    /// "to Manhattan", or before there's a station and line, "Northbound".
    var label: String {
        guard let station = stationID.flatMap(StationDirectory.station(id:)), !routes.isEmpty else { return bound }
        return station.directionLabel(direction, routes: routes)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(label)",
            subtitle: label == bound ? nil : "\(bound)",
            image: DisplayRepresentation.Image(systemName: direction == .north ? "arrow.up" : "arrow.down")
        )
    }
}

struct DirectionQuery: EntityQuery {
    @IntentParameterDependency<TrainWidgetIntent>(\.$station)
    var stationChoice

    @IntentParameterDependency<TrainWidgetIntent>(\.$line)
    var lineChoice

    func entities(for identifiers: [DirectionEntity.ID]) async throws -> [DirectionEntity] {
        identifiers.compactMap(DirectionEntity.init(id:))
    }

    /// Named by the station's platforms once the station and line go together.
    func suggestedEntities() async throws -> [DirectionEntity] {
        let routes = lineChoice?.line.routes ?? []
        guard let station = stationChoice?.station.station, !routes.isEmpty, routes.allSatisfy(station.routes.contains) else {
            return Direction.allCases.map { DirectionEntity($0) }
        }
        return Direction.allCases.map { DirectionEntity($0, station: station, routes: routes) }
    }
}

/// A titled section of an Edit menu list.
struct ChoiceGroup<Item: AppEntity> {
    let title: String
    let items: [Item]
}

private func collection<Item: AppEntity>(_ groups: [ChoiceGroup<Item>]) -> IntentItemCollection<Item> {
    IntentItemCollection(sections: groups.map { group in
        IntentItemSection(LocalizedStringResource(stringLiteral: group.title), items: group.items)
    })
}

/// Line bullets as a picture, for the Edit menu's lists, which take an image
/// rather than a view: one, or several in about the room of one, as
/// `LineBullets` draws them.
enum BulletImage {
    private static let cache = NSCache<NSString, NSData>()

    static func data(for routes: [String]) -> Data? {
        let key = routes.joined(separator: ",") as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        let side: CGFloat = 60
        let gap: CGFloat = 3
        let count = routes.count
        let columns = count == 1 ? 1 : count <= 4 ? 2 : 3
        let rows = (count + columns - 1) / columns
        let across = CGFloat(max(columns, rows))
        let size = (side - gap * (across - 1)) / across
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let top = (side - CGFloat(rows) * size - CGFloat(rows - 1) * gap) / 2
            for (index, route) in routes.enumerated() {
                let style = LineStyle.of(route)
                let row = index / columns
                let inRow = CGFloat(min(columns, count - row * columns))
                let left = (side - inRow * size - (inRow - 1) * gap) / 2
                let circle = CGRect(x: left + CGFloat(index % columns) * (size + gap), y: top + CGFloat(row) * (size + gap), width: size, height: size)
                UIColor(
                    red: CGFloat((style.color >> 16) & 0xFF) / 255,
                    green: CGFloat((style.color >> 8) & 0xFF) / 255,
                    blue: CGFloat(style.color & 0xFF) / 255,
                    alpha: 1
                ).setFill()
                UIBezierPath(ovalIn: circle).fill()
                let font = UIFont.systemFont(ofSize: size * (style.label.count > 1 ? 0.45 : 0.62), weight: .bold)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: style.usesDarkText ? UIColor.black : UIColor.white,
                ]
                let label = style.label as NSString
                let width = label.size(withAttributes: attributes).width
                // Centred on its capitals, as LineBullet is
                label.draw(at: CGPoint(x: circle.midX - width / 2, y: circle.midY + font.capHeight / 2 - font.ascender), withAttributes: attributes)
            }
        }
        guard let png = image.pngData() else { return nil }
        cache.setObject(png as NSData, forKey: key)
        return png
    }
}
