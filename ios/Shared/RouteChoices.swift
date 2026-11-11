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
    /// Planned From and To (`SavedWidget.trip`): the widget follows these ways rather than
    /// `changes`.
    var planned: PlannedTrip? = nil

    /// The lines ridden, `line` first.
    var allLines: [String] { lines.flatMap { $0.isEmpty ? nil : $0 } ?? [line] }

    /// As a countdown keeps it (`TrainActivityAttributes.bus`, the push server's sign-up): its
    /// stop and lines, without the changes and plan on that only widgets follow, which the
    /// server refuses and which can take the activity over iOS's limit.
    var forCountdown: BusChoice {
        var bus = self
        bus.changes = nil
        bus.planned = nil
        return bus
    }

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
        planned = try? values.decodeIfPresent(PlannedTrip.self, forKey: .planned)
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

    /// Bus Time's capitals, or the timetable's, as a sign has them: "7 AV/9 ST" as "7 Av & 9 St",
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
        // Not where what's left is only a service's name: "Select Bus Service" isn't "Service"
        while !services.contains(shown), let service = services.first(where: { shown.hasPrefix($0 + " ") }) {
            shown = String(shown.dropFirst(service.count + 1))
        }
        return shown
    }

    /// How Bus Time and the timetable start a headsign with a bus's service, after `readable`.
    private static let services = ["Select Bus Service", "Select Bus", "Sbs", "+", "Limited", "Ltd", "Rush"]
}

/// A saved route planned From and To (`SavedWidget.trip`): the ways there ticked, each up to
/// three rides, every one a train or a bus, and where it goes. The widgets follow each first
/// train or bus through every ride (`PlannedTrips`).
struct PlannedTrip: Codable, Hashable, Sendable {
    var ways: [PlannedWay]
    /// Where it goes: a station, or a bus stop.
    var destinationID: String?
    var destinationStop: BusStop?
    /// Ways from another start, taken only when no first train or bus of `ways` is coming: with
    /// no Manhattan-bound R at Prospect Av, the R the other way to 36 St, back on the D or N.
    var fallback: Fallback? = nil

    struct Fallback: Codable, Hashable, Sendable {
        var ways: [PlannedWay]
        /// When it's taken, as the widget says it: "No Manhattan-bound R".
        var when: String
        /// What it takes: "R to 36 St, back on the D or N".
        var takes: String
    }

    init(ways: [PlannedWay], destinationID: String? = nil, destinationStop: BusStop? = nil) {
        self.ways = ways
        self.destinationID = destinationID
        self.destinationStop = destinationStop
    }

    /// The first ride, which every way shares the start of.
    var start: PlannedRide? { ways.first?.rides.first?.first }

    /// The same for the same trip in the app and the widget, to tell trips' saved times apart.
    var key: String {
        Self.key(ways) + " to \(destinationID ?? destinationStop?.id ?? "")"
            + (fallback.map { " else " + Self.key($0.ways) } ?? "")
    }

    private static func key(_ ways: [PlannedWay]) -> String {
        ways.map { way in
            way.rides.map { options in
                options.map { ride in
                    (ride.train.map { "\($0.stationID) \($0.routes.joined(separator: ",")) \($0.direction.rawValue)" } ?? "")
                        + (ride.bus.map { "\($0.line) \($0.stop.id)" } ?? "")
                        + " \(ride.offStationID ?? ride.offStop?.id ?? "")"
                        + (ride.walkMinutes > 0 ? " walk \(ride.walkMinutes)" : "")
                }.joined(separator: " or ")
            }.joined(separator: " > ") + (way.endStop.map { " end \($0.id)" } ?? "")
                + (way.endStationID.map { " off \($0)" } ?? "") + (way.endWalk > 0 ? " walk \(way.endWalk)" : "")
        }.joined(separator: " | ")
    }
}

/// One way there: its rides in turn. After the first, each ride is any of several places to
/// change, any of which will do (the widget takes whichever gets there soonest).
struct PlannedWay: Codable, Hashable, Sendable {
    var rides: [[PlannedRide]]
    /// Off a last ride by bus: the stop to get off at near the destination, and the walk on.
    var endStop: BusStop? = nil
    var endWalk: Int = 0
    /// Off a last ride by train: the station it's left at (the destination, or one near a stop
    /// that's the destination).
    var endStationID: String? = nil

    init(rides: [[PlannedRide]], endStop: BusStop? = nil, endWalk: Int = 0, endStationID: String? = nil) {
        self.rides = rides
        self.endStop = endStop
        self.endWalk = endWalk
        self.endStationID = endStationID
    }

    private enum CodingKeys: String, CodingKey {
        case rides, endStop, endWalk, endStationID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rides = try container.decode([[PlannedRide]].self, forKey: .rides)
        endStop = try container.decodeIfPresent(BusStop.self, forKey: .endStop)
        endWalk = try container.decodeIfPresent(Int.self, forKey: .endWalk) ?? 0
        endStationID = try container.decodeIfPresent(String.self, forKey: .endStationID)
    }
}

/// A ride on a planned way: a train's lines from a station going one way, or a bus line from a
/// stop going one way; and for a ride after the first, how it's changed to.
struct PlannedRide: Codable, Hashable, Sendable {
    /// A train: its station, lines and way; nil for a bus.
    var train: Selection?
    /// A bus: its line, the stop it's boarded at and where it's going; nil for a train.
    var bus: BusLeg?
    /// Off the ride before, onto this: the walk, in minutes (none across the platform).
    var walkMinutes: Int = 0
    /// Off the ride before: the station its train is left at (nil: this train's own station),
    /// or the stop its bus is left at.
    var offStationID: String? = nil
    var offStop: BusStop? = nil
    /// A bus's timetable minutes from where it's boarded to each stop it's left at, by stop code,
    /// worked out when planned (`PlannedTrip.timingBuses()`) so widgets needn't load every bus
    /// route; nil for a train, and in saves from before (the widget then works them out).
    var busMinutes: [String: Double]? = nil

    init(train: Selection? = nil, bus: BusLeg? = nil, walkMinutes: Int = 0, offStationID: String? = nil,
         offStop: BusStop? = nil, busMinutes: [String: Double]? = nil) {
        self.train = train
        self.bus = bus
        self.walkMinutes = walkMinutes
        self.offStationID = offStationID
        self.offStop = offStop
        self.busMinutes = busMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case train, bus, walkMinutes, offStationID, offStop, busMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        train = try container.decodeIfPresent(Selection.self, forKey: .train)
        bus = try container.decodeIfPresent(BusLeg.self, forKey: .bus)
        walkMinutes = try container.decodeIfPresent(Int.self, forKey: .walkMinutes) ?? 0
        offStationID = try container.decodeIfPresent(String.self, forKey: .offStationID)
        offStop = try container.decodeIfPresent(BusStop.self, forKey: .offStop)
        busMinutes = try? container.decodeIfPresent([String: Double].self, forKey: .busMinutes)
    }

    /// Its lines as the boards mark them: a train's routes, or a bus's ("bus:B63").
    var routes: [String] { bus.map { [$0.route] } ?? train?.routes ?? [] }

    /// Where it's boarded: the station's name, or the stop's.
    var placeName: String {
        if let bus { return bus.stopName }
        return train?.station?.name ?? ""
    }
}
