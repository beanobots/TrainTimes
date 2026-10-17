import Foundation

enum Direction: String, Codable, CaseIterable, Sendable {
    /// The feeds name a platform by its station id plus N or S.
    case north = "N"
    case south = "S"

    var opposite: Direction { self == .north ? .south : .north }
}

/// One of a station's sets of tracks, as the MTA lists them: the D N R at
/// Atlantic Av-Barclays Ctr, say, apart from its B Q and its 2 3 4 5.
struct Platform: Codable, Hashable, Identifiable, Sendable {
    /// The GTFS stop id, e.g. "R34". The feeds add N or S for each direction's platform.
    let id: String
    let name: String
    /// A shorter name for where a train ends up, e.g. "Forest Hills" for "Forest Hills-71 Av".
    let short: String
    let borough: String
    /// Real-time route ids of the lines that stop here.
    let routes: [String]
    /// The MTA's names for the two directions; empty at the end of a line.
    let north: String
    let south: String
    let lat: Double
    let lon: Double
    /// The station complex: stations joined by passageways share one, and so do their elevators.
    let complex: String
    /// 0: not accessible, 1: accessible, 2: partly accessible (see `adaNotes`).
    let ada: Int
    /// Which part is accessible at a partly accessible station, e.g. "Manhattan-bound only".
    let adaNotes: String
    let entrances: [Station.Entrance]

    /// "Accessible", or nil for a platform without step-free access.
    var accessibility: String? {
        switch ada {
        case 1: "Accessible station"
        case 2: adaNotes.isEmpty ? "Partly accessible" : "Accessible: \(adaNotes)"
        default: nil
        }
    }

    func directionName(_ direction: Direction) -> String {
        direction == .north ? north : south
    }

    /// Where its first line comes in the MTA's order.
    fileprivate var rank: Int { routes.map(Lines.rank).min() ?? Int.max }
}

/// A station as riders know it: the platforms of one name that passageways
/// join, such as Atlantic Av-Barclays Ctr's D N R, B Q and 2 3 4 5, or just one.
struct Station: Hashable, Identifiable, Sendable {
    /// Its first platform's id; the others' find it too.
    let id: String
    let name: String
    let borough: String
    /// Real-time route ids of every line that stops here.
    let routes: [String]
    /// In the order of their lines.
    let platforms: [Platform]
    /// The station complex, whose elevators and escalators it shares.
    let complex: String
    /// Midway between its platforms.
    let lat: Double
    let lon: Double
    /// All its platforms' entrances.
    let entrances: [Entrance]

    struct Entrance: Codable, Hashable, Sendable {
        let lat: Double
        let lon: Double
        /// "Stair", "Elevator", "Escalator", "Station House", "Easement - Street", ...
        let type: String
        var exitOnly: Bool? = nil

        var isElevator: Bool { type.contains("Elevator") }
    }

    /// `platforms` share a name and a complex.
    init(platforms: [Platform]) {
        let platforms = platforms.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element)
        let first = platforms[0]
        id = first.id
        name = first.name
        borough = first.borough
        // One platform keeps the MTA's order for it (J M Z); several are put in the MTA's order of lines
        let routes = platforms.flatMap(\.routes)
        self.routes = platforms.count == 1 ? routes : routes.enumerated()
            .sorted { (Lines.rank($0.element), $0.offset) < (Lines.rank($1.element), $1.offset) }
            .map(\.element)
        self.platforms = platforms
        complex = first.complex
        lat = platforms.map(\.lat).reduce(0, +) / Double(platforms.count)
        lon = platforms.map(\.lon).reduce(0, +) / Double(platforms.count)
        // A complex's shared entrances can be listed under each of its platforms
        var seen = Set<Entrance>()
        entrances = platforms.flatMap(\.entrances).filter { seen.insert($0).inserted }
    }

    /// The platforms the lines of `routes` stop at.
    func platforms(serving routes: [String]) -> [Platform] {
        platforms.filter { $0.routes.contains(where: routes.contains) }
    }

    /// Where the lines of `routes` go in `direction`: "to Manhattan", or "Northbound"
    /// where the MTA gives no name. Platforms that name it differently are all named:
    /// "to Coney Island - Bay Ridge or Flatbush - New Lots".
    func directionLabel(_ direction: Direction, routes: [String]) -> String {
        Self.directionLabel(direction, on: platforms(serving: routes))
    }

    /// The MTA's name for where `route` goes in `direction` from here: "Manhattan",
    /// "Uptown & The Bronx"; empty at the end of the line.
    func directionName(_ direction: Direction, of route: String) -> String {
        platforms(serving: [route]).lazy.map { $0.directionName(direction) }.first { !$0.isEmpty } ?? ""
    }

    static func directionLabel(_ direction: Direction, on platforms: [Platform]) -> String {
        var names: [String] = []
        for name in platforms.map({ $0.directionName(direction) }) where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        if names.isEmpty { return direction == .north ? "Northbound" : "Southbound" }
        return "to " + names.joined(separator: " or ")
    }

    func serves(label: String) -> Bool {
        routes.contains { LineStyle.of($0).label == label }
    }
}

enum StationDirectory {
    /// Every subway and Staten Island Railway platform (stations.json is built by tools/make_stations.py).
    static let platforms: [Platform] = {
        guard let url = Bundle.main.url(forResource: "stations", withExtension: "json"),
              let platforms = try? load(from: url) else { return [] }
        return platforms
    }()

    /// Every station, in the list's order.
    static let all: [Station] = stations(from: platforms)

    /// Each station by each of its platforms' ids.
    private static let byID = Dictionary(uniqueKeysWithValues: all.flatMap { station in
        station.platforms.map { ($0.id, station) }
    })
    private static let platformsByID = Dictionary(uniqueKeysWithValues: platforms.map { ($0.id, $0) })

    static func load(from url: URL) throws -> [Platform] {
        try JSONDecoder().decode([Platform].self, from: Data(contentsOf: url))
    }

    /// Platforms with the same name in the same complex are one station, where
    /// the first of them is in the list.
    static func stations(from platforms: [Platform]) -> [Station] {
        var groups: [[Platform]] = []
        var index: [[String]: Int] = [:]
        for platform in platforms {
            let key = [platform.complex, platform.name]
            if let at = index[key] {
                groups[at].append(platform)
            } else {
                index[key] = groups.count
                groups.append([platform])
            }
        }
        return groups.map(Station.init(platforms:))
    }

    /// The station with this id, or with a platform that has it: "R31", "D24"
    /// and "235" are all Atlantic Av-Barclays Ctr.
    static func station(id: String) -> Station? {
        byID[id]
    }

    /// The short name of the station a platform id belongs to ("G08N" is Forest Hills).
    static func terminalName(forStop stop: String) -> String? {
        shortName(forStop: stop)
    }

    /// The short name of a stop on a train's way: "R45N" is Bay Ridge.
    static func shortName(forStop stop: String) -> String? {
        platform(forStop: stop)?.short
    }

    /// The borough of a stop on a train's way: "R45S" is in Brooklyn.
    static func borough(ofStop stop: String) -> String? {
        platform(forStop: stop)?.borough
    }

    private static func platform(forStop stop: String) -> Platform? {
        platformsByID[stop] ?? platformsByID[String(stop.dropLast())]
    }
}
