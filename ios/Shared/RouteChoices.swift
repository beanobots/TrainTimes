import Foundation

// Plain data and names only, with nothing of SwiftUI's, Bus Time's or Citi Bike's: the push server
// builds this file too, for `SavedWidget`. What needs those is in extensions beside them
// (`BusTrips.swift`, `CitiBike.swift`).

/// What a saved widget (a Saved Route) shows: a subway train, a bus, or a Citi Bike dock.
enum SavedRouteKind: String, Codable, CaseIterable, Hashable, Sendable {
    case subway, bus, bike

    var name: String {
        switch self {
        case .subway: "Subway"
        case .bus: "Bus"
        case .bike: "Citi Bike"
        }
    }

    var symbol: String {
        switch self {
        case .subway: "tram.fill"
        case .bus: "bus.fill"
        case .bike: "bicycle"
        }
    }
}

/// A bus stop, as Bus Time has it (`BusStopTimes.Stop`).
struct BusStop: Codable, Hashable, Sendable {
    /// The MTA's stop code, as on the stop's sign.
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    /// Which way buses leave it, as a compass point.
    var direction: String?
}

/// A saved bus widget's bus, or Settings' home stop when it's a bus: a line, or several, at a stop,
/// one way, or both.
struct BusChoice: Codable, Hashable, Sendable {
    /// "B63", "M15-SBS": the first of `allLines`.
    var line: String
    /// Every line ridden from the stop, `line` first, when there's more than one (a home stop's;
    /// a saved widget's is one); nil for just `line`.
    var lines: [String]? = nil
    /// The stop, the way its buses leave it.
    var stop: BusStop
    /// Where its buses are going, as Bus Time writes it.
    var destination: String?
    /// The stop the other way, for both directions; nil if there's none.
    var otherStop: BusStop? = nil
    var otherDestination: String? = nil
    /// Shows the other way beside this one.
    var bothWays = false
    /// Changes to a train further on, each an alternative: the medium and large widgets show the
    /// ways on, as a train's change does. Nil in saves from before.
    var changes: [BusChange]? = nil

    /// The lines ridden, `line` first.
    var allLines: [String] { lines.flatMap { $0.isEmpty ? nil : $0 } ?? [line] }

    /// "4 Av & 9 St".
    var stopName: String { BusNames.readable(stop.name) }
    /// "Cobble Hill", or the stop's name without a destination.
    var wayName: String { destination.map(BusNames.destination) ?? stopName }

    /// The same bus the other way, if there's a stop for it.
    var otherWay: BusChoice? {
        guard let otherStop else { return nil }
        return BusChoice(line: line, lines: lines, stop: otherStop, destination: otherDestination, otherStop: stop,
                         otherDestination: destination)
    }
}

extension BusChoice {
    /// As saved, but with lines named as Bus Time and the bus data now name them: saves from
    /// before named the Q6 to Q9 "Q06" to "Q09".
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        line = Self.unpadded(try values.decode(String.self, forKey: .line))
        lines = try values.decodeIfPresent([String].self, forKey: .lines)?.map(Self.unpadded)
        stop = try values.decode(BusStop.self, forKey: .stop)
        destination = try values.decodeIfPresent(String.self, forKey: .destination)
        otherStop = try values.decodeIfPresent(BusStop.self, forKey: .otherStop)
        otherDestination = try values.decodeIfPresent(String.self, forKey: .otherDestination)
        bothWays = try values.decodeIfPresent(Bool.self, forKey: .bothWays) ?? false
        changes = try values.decodeIfPresent([BusChange].self, forKey: .changes)
    }

    /// "Q06" as "Q6": the number without its leading zeros.
    private static func unpadded(_ line: String) -> String {
        let letters = line.prefix { $0.isLetter }
        return String(letters) + line.dropFirst(letters.count).drop { $0 == "0" }
    }
}

/// A change from a saved bus to a train (`BusChoice.changes`): where to get off, the timetable's
/// minutes there from the bus's stop, the walk, and the train.
struct BusChange: Codable, Hashable, Sendable {
    /// Where to get off.
    var stop: BusStop
    /// The timetable's minutes from boarding to `stop`.
    var minutes: Double
    var walkMinutes: Int
    /// The train changed to: its station, lines and way.
    var selection: Selection
}

/// A bus to change to from a train (`Change.buses`): a line at a stop near the change, going one
/// way, and the walk there.
struct BusLeg: Codable, Hashable, Sendable {
    var line: String
    var stop: BusStop
    /// Where its buses are going, as Bus Time writes it.
    var destination: String?
    var walkMinutes: Int

    /// A bus way's `Way.route`, which marks it a bus ("bus:B63"), not a line.
    var route: String { Self.prefix + line }

    static let prefix = "bus:"

    /// The bus line in a `Way.route` that's a bus's; nil for a train's.
    static func line(of route: String) -> String? {
        route.hasPrefix(prefix) ? String(route.dropFirst(prefix.count)) : nil
    }

    /// "4 Av & 9 St".
    var stopName: String { BusNames.readable(stop.name) }
    /// "Cobble Hill".
    var wayName: String { destination.map(BusNames.destination) ?? stopName }
}

/// A saved Citi Bike widget's dock.
struct DockChoice: Codable, Hashable, Sendable {
    /// GBFS's station id.
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double

    init(id: String, name: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Which Citi Bikes Settings counts (Settings → Biking), shared with the widgets.
enum SharedBikeKinds: String, Codable, Hashable, Sendable {
    case bikes, eBikes, both

    var showsBikes: Bool { self != .eBikes }
    var showsEBikes: Bool { self != .bikes }
}

/// Bus lines' and stops' names as signs have them.
enum BusNames {
    /// Whether `line` is Select Bus Service: "M86-SBS", "M86 SBS", "M86+".
    static func isSBS(_ line: String) -> Bool {
        let name = line.uppercased().replacingOccurrences(of: " ", with: "")
        return name.hasSuffix("SBS") || name.hasSuffix("+")
    }

    /// The line without its Select Bus Service mark: "M86".
    static func label(_ line: String) -> String {
        var name = line.trimmingCharacters(in: .whitespaces)
        for mark in ["-SBS", " SBS", "SBS", "+"] where name.uppercased().hasSuffix(mark) {
            name = String(name.dropLast(mark.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return name.isEmpty ? line : name
    }

    /// Bus Time's capitals, or Google's names, as a sign has them: "7 AV/9 ST" as "7 Av & 9 St",
    /// "via" and "at" kept small, "LGA/TERMINAL B" as "LGA & Terminal B".
    static func readable(_ name: String) -> String {
        name.capitalized
            .replacingOccurrences(of: "/", with: " & ")
            .split(separator: " ")
            .map { word in word == "Via" || word == "At" ? word.lowercased() : acronyms[String(word)] ?? String(word) }
            .joined(separator: " ")
    }

    /// Names in capitals on a sign, as `capitalized` writes them.
    private static let acronyms = ["Lga": "LGA", "Jfk": "JFK", "Lirr": "LIRR", "Cuny": "CUNY", "Suny": "SUNY",
                                   "Mta": "MTA", "Lic": "LIC", "Si": "SI"]

    /// Where a bus is going, as its sign has it: `readable`, without the service it's on, which
    /// its badge shows. "Select Bus La Guardia Airport" as "La Guardia Airport", "Rush Jamaica
    /// Lirr" as "Jamaica LIRR", "Sbs Wlmsbrg Brdg Plz via Nstrnd Via Rgrs" as "Wlmsbrg Brdg Plz
    /// via Nstrnd via Rgrs".
    static func destination(_ name: String) -> String {
        var shown = readable(name)
        while let service = services.first(where: { shown.hasPrefix($0 + " ") }) {
            shown = String(shown.dropFirst(service.count + 1))
        }
        return shown
    }

    /// How Bus Time and Google start a headsign with a bus's service, after `readable`.
    private static let services = ["Select Bus Service", "Select Bus", "Sbs", "+", "Limited", "Ltd", "Rush"]
}
