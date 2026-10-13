import Foundation

enum Direction: String, Codable, CaseIterable, Sendable {
    /// The feeds name a platform by its station id plus N or S.
    case north = "N"
    case south = "S"
}

struct Station: Codable, Hashable, Identifiable, Sendable {
    /// The GTFS stop id, e.g. "R34". Platforms add N or S.
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
    let entrances: [Entrance]

    struct Entrance: Codable, Hashable, Sendable {
        let lat: Double
        let lon: Double
        /// "Stair", "Elevator", "Escalator", "Station House", "Easement - Street", ...
        let type: String
        var exitOnly: Bool? = nil

        var isElevator: Bool { type.contains("Elevator") }
    }

    /// "Accessible", or nil for a station without step-free access.
    var accessibility: String? {
        switch ada {
        case 1: "Accessible station"
        case 2: adaNotes.isEmpty ? "Partly accessible" : "Accessible: \(adaNotes)"
        default: nil
        }
    }

    /// "to Manhattan", or "Northbound" where the MTA gives no name.
    func directionLabel(_ direction: Direction) -> String {
        let name = direction == .north ? north : south
        if !name.isEmpty { return "to \(name)" }
        return direction == .north ? "Northbound" : "Southbound"
    }

    func serves(label: String) -> Bool {
        routes.contains { LineStyle.of($0).label == label }
    }
}

enum StationDirectory {
    /// Every subway and Staten Island Railway station (stations.json is built by tools/make_stations.py).
    static let all: [Station] = {
        guard let url = Bundle.main.url(forResource: "stations", withExtension: "json"),
              let stations = try? load(from: url) else { return [] }
        return stations
    }()

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func load(from url: URL) throws -> [Station] {
        try JSONDecoder().decode([Station].self, from: Data(contentsOf: url))
    }

    static func station(id: String) -> Station? {
        byID[id]
    }

    /// The short name of the station a platform id belongs to ("G08N" is Forest Hills).
    static func terminalName(forStop stop: String) -> String? {
        (byID[stop] ?? byID[String(stop.dropLast())])?.short
    }
}
