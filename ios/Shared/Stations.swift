import Foundation

enum Direction: String, Codable, CaseIterable, Sendable {
    /// The feeds name a platform by its station id plus N or S.
    case north = "N"
    case south = "S"

    var opposite: Direction { self == .north ? .south : .north }

    /// "Northbound" or "Southbound": what it's called where the MTA gives it no name.
    var compassName: String { self == .north ? "Northbound" : "Southbound" }

    /// The way a stop on a train's way is for, by the N or S the feeds add to
    /// its platform's id: "R31N" is north. Nil for a platform's id alone.
    init?(ofStop stop: String) {
        self.init(rawValue: String(stop.suffix(1)))
    }
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
    /// They're the way its first line goes: see `reversed`.
    let north: String
    let south: String
    /// Lines whose trains here go N the way `south` names, and S the way
    /// `north` does: the feeds give a trip one direction all along its line,
    /// so an M toward Middle Village is S at Marcy Av, whose south is
    /// "Manhattan" for the J. Nil for none.
    var reversed: [String]? = nil
    let lat: Double
    let lon: Double
    /// The station complex: stations joined by passageways share one, and so do their elevators.
    let complex: String
    /// 0: not accessible, 1: accessible, 2: partly accessible (see `adaNotes`).
    let ada: Int
    /// Which part is accessible at a partly accessible station, e.g. "Manhattan-bound only".
    let adaNotes: String
    let entrances: [Station.Entrance]
    /// Other ids the feeds give it: H19 at Broad Channel, the track the
    /// Rockaway Park Shuttle ends on. Nil for none.
    var aliases: [String]? = nil

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

    /// The MTA's name for where `route`'s trains going `direction` from here
    /// are headed: its name for the other way where the line is `reversed`.
    func directionName(_ direction: Direction, of route: String) -> String {
        directionName(side(of: route, going: direction))
    }

    /// The side `route`'s trains going `direction` stop on here, by the way
    /// whose name it has: the other way where the line is `reversed`. An M
    /// going N at Marcy Av stops on the side named S, "Manhattan", as a J
    /// going S does. Trains on one side are across the platform from each other.
    func side(of route: String, going direction: Direction) -> Direction {
        reversed?.contains(route) == true ? direction.opposite : direction
    }

    /// The feeds' N or S for `route`'s trains here going `direction` with the
    /// lines of `routes`, as a train or change of several lines goes:
    /// `direction`, but the other where the line is `reversed` and some of
    /// `routes` here aren't, so they all stop on the side `direction` names.
    /// A line alone, or with only lines `reversed` like it, goes by its own.
    func direction(_ direction: Direction, of route: String, with routes: [String]) -> Direction {
        let named = routes.contains { self.routes.contains($0) && reversed?.contains($0) != true }
        return named ? side(of: route, going: direction) : direction
    }

    /// Where the lines of `routes` call here going `direction` together
    /// (`direction(_:of:with:)`), as the feeds name it: "R31N"; going S from
    /// Marcy Av, the J's "M16S" and the M's "M16N", all toward Manhattan.
    /// `direction`'s first, which other lines' trains go by.
    func stops(of routes: [String], going direction: Direction) -> [String] {
        let ways = routes.filter(self.routes.contains).map { self.direction(direction, of: $0, with: routes) }
        return [direction, direction.opposite].filter { $0 == direction || ways.contains($0) }.map { id + $0.rawValue }
    }

    /// The one way a partly accessible platform is step-free, where `adaNotes`
    /// names it alone: "Downtown only", "Manhattan-bound only", "Southbound
    /// Only". Nil for any other platform, and where the notes name neither
    /// way or both, or only some of its trains ("Uptown & The Bronx local only").
    /// It's the way the MTA's names go by, which is every line's here:
    /// make_stations.py won't list a line as `reversed` on a partly accessible platform.
    var stepFreeWay: Direction? {
        guard ada == 2 else { return nil }
        let notes = adaNotes.lowercased()
        guard !notes.contains("local"), !notes.contains("express") else { return nil }
        let ways = Direction.allCases.filter { way in
            let name = directionName(way).lowercased()
            return notes.hasPrefix(way.compassName.lowercased()) || (!name.isEmpty && notes.hasPrefix(name))
        }
        return ways.count == 1 ? ways[0] : nil
    }

    /// Whether there's step-free access to it going `direction`, or with
    /// none, either way. Nil at a partly accessible platform where that
    /// can't be told: with no way given, or its notes don't say which.
    func isStepFree(going direction: Direction? = nil) -> Bool? {
        switch ada {
        case 1: true
        case 2: direction.flatMap { direction in stepFreeWay.map { $0 == direction } }
        default: false
        }
    }

    /// Where its first line comes in the MTA's order.
    fileprivate var rank: Int { routes.map(Lines.rank).min() ?? Int.max }
}

extension Array where Element == Platform {
    /// What step-free mode says of these platforms, going `direction` once
    /// it's chosen: nothing where every one is step-free; "No step-free
    /// access" where none is; a partly accessible one's own note, such as
    /// "Accessible: Downtown only", where it's the only one; and otherwise
    /// "Step-free on some platforms".
    func stepFreeNote(going direction: Direction? = nil) -> String? {
        let access = map { $0.isStepFree(going: direction) }
        if access.allSatisfy({ $0 == true }) { return nil }
        if access.allSatisfy({ $0 == false }) { return "No step-free access" }
        if count == 1 { return self[0].accessibility }
        return "Step-free on some platforms"
    }
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

    /// The lines that stop at `platform`, one of its own, in the station's order.
    func lines(on platform: Platform) -> [String] {
        routes.filter(platform.routes.contains)
    }

    /// Where the lines of `routes` go in `direction` together: "Manhattan", or
    /// "Northbound" where the MTA gives no name. Platforms that name it
    /// differently are all named: "Coney Island - Bay Ridge or Flatbush - New Lots".
    func directionLabel(_ direction: Direction, routes: [String]) -> String {
        Self.directionLabel(direction, on: platforms(serving: routes), routes: routes)
    }

    /// The MTA's name for where `route` goes in `direction` from here: "Manhattan",
    /// "Uptown & The Bronx"; empty at the end of the line.
    func directionName(_ direction: Direction, of route: String) -> String {
        platforms(serving: [route]).lazy.map { $0.directionName(direction, of: route) }.first { !$0.isEmpty } ?? ""
    }

    /// As `Platform.direction(_:of:with:)`, at the platform here `route` stops at.
    func direction(_ direction: Direction, of route: String, with routes: [String]) -> Direction {
        platforms(serving: [route]).first?.direction(direction, of: route, with: routes) ?? direction
    }

    /// The ways the lines of `routes` go from here: those the MTA names, or
    /// both where it names neither. One it gives no name, at the end of the
    /// line, has no trains.
    func directions(of routes: [String]) -> [Direction] {
        let serving = platforms(serving: routes)
        let named = Direction.allCases.filter { !Self.directionNames($0, on: serving, routes: routes).isEmpty }
        return named.isEmpty ? Direction.allCases : named
    }

    /// The ways trains of `routes` go on from here: `directions(of:)`, less
    /// any where every one of them ends its run by day though others go on,
    /// as the C does at 168 St, unless that leaves none.
    func onwardDirections(of routes: [String]) -> [Direction] {
        let named = directions(of: routes)
        let onward = named.filter { direction in
            routes.contains {
                !StationDirectory.line($0, endsAt: self, going: self.direction(direction, of: $0, with: routes))
            }
        }
        return onward.isEmpty ? named : onward
    }

    /// `directionNames`, joined by "or"; the compass name where there are none.
    static func directionLabel(_ direction: Direction, on platforms: [Platform], routes: [String]? = nil) -> String {
        let names = directionNames(direction, on: platforms, routes: routes)
        if names.isEmpty { return direction.compassName }
        return names.joined(separator: " or ")
    }

    /// The MTA's names for `direction` at `platforms`, each once: at each, for
    /// the lines of `routes` that stop there, going that way together
    /// (`Platform.direction(_:of:with:)`), or without any, as it names it.
    static func directionNames(_ direction: Direction, on platforms: [Platform], routes: [String]? = nil) -> [String] {
        var names: [String] = []
        for platform in platforms {
            let own = routes?.filter(platform.routes.contains) ?? []
            let named = own.isEmpty ? [platform.directionName(direction)]
                : own.map { platform.directionName(platform.direction(direction, of: $0, with: own), of: $0) }
            for name in named where !name.isEmpty && !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    func serves(label: String) -> Bool {
        routes.contains { LineStyle.of($0).label == label }
    }
}

/// One way a line goes from a station, as Trains near you and the app's
/// Nearby list show it: what it's called, and its trains.
struct LineWay {
    /// The line on its own, going this way.
    let selection: Selection
    /// "Manhattan", "Brooklyn", "Uptown"
    let label: String
    /// Its own trains still to leave, not those of another line running on
    /// its tracks, soonest first; nil when they couldn't be had.
    let trains: [Arrival]?

    var direction: Direction { selection.direction }
}

extension Station {
    /// Each of its lines on its own, both ways: what the Nearby lists fetch.
    var lineSelections: [Selection] {
        routes.flatMap { route in
            Direction.allCases.map { Selection(stationID: id, routes: [route], direction: $0) }
        }
    }

    /// `route`'s two ways from here, as Trains near you and the app's Nearby
    /// list show them, with its trains from `trains` (by `Selection.trainID`,
    /// as `TrainService.trains(for:)` has them) still to leave at `now`. From
    /// outside Manhattan the way toward it comes first; otherwise north, which
    /// in Manhattan is uptown. Nil for a way it doesn't go: one the MTA gives
    /// no name, at the end of the line, or where the line ends though others
    /// go on from here, unless some of its trains do too.
    func ways(of route: String, trains: [String: [Arrival]], now: Date) -> [LineWay?] {
        let goes = directions(of: [route])
        let towardManhattan = borough == "Manhattan" || !Lines.servesManhattan(route) ? nil
            : goes.first(where: { directionName($0, of: route).contains("Manhattan") })
        let order = towardManhattan.map { [$0, $0.opposite] } ?? [.north, .south]
        var found: [Direction: (selection: Selection, trains: [Arrival]?)] = [:]
        for direction in order where goes.contains(direction) {
            let selection = Selection(stationID: id, routes: [route], direction: direction)
            let own = trains[selection.trainID]?.filter { $0.route == route && $0.leaves > now }
            if StationDirectory.line(route, endsAt: self, going: direction), own?.isEmpty != false { continue }
            found[direction] = (selection, own)
        }
        let labels = wayLabels(of: route, trains: found.mapValues { $0.trains })
        return order.map { direction in
            found[direction].map { LineWay(selection: $0.selection, label: labels[direction] ?? "", trains: $0.trains) }
        }
    }

    /// What each of `route`'s ways from here is called, given their trains.
    /// In Manhattan, the MTA's name: "Uptown", "Downtown". From elsewhere,
    /// "Manhattan" for the way there, and for the other the borough its trains
    /// are headed for, or with none to go by, where the line ends. A line that
    /// stays in one borough, like the Staten Island Railway, goes by where its
    /// trains end up.
    private func wayLabels(of route: String, trains ways: [Direction: [Arrival]?]) -> [Direction: String] {
        // "Uptown & The Bronx" and "Uptown - Queens" are uptown
        func named(_ direction: Direction) -> String {
            var name = directionName(direction, of: route)
            // Where the lines here part, this one's way: "Broad St (JZ) - Uptown (M)" is uptown for the M
            let label = LineStyle.of(route).label
            if let own = name.components(separatedBy: " - ").first(where: {
                $0.hasSuffix(")") && ($0.components(separatedBy: "(").last ?? "").contains(label)
            }) {
                name = own.components(separatedBy: " (")[0]
            }
            name = name.components(separatedBy: " & ")[0]
            // Only those: "34 St - Hudson Yards" stays as it is
            let first = name.components(separatedBy: " - ")[0]
            if first == "Uptown" || first == "Downtown" { name = first }
            return name.isEmpty ? direction.compassName : name
        }
        var labels: [Direction: String] = [:]
        for (direction, trains) in ways {
            if borough == "Manhattan" {
                labels[direction] = named(direction)
            } else if Lines.servesManhattan(route) && directionName(direction, of: route).contains("Manhattan") {
                labels[direction] = "Manhattan"
            } else {
                labels[direction] = trains?.first.flatMap { StationDirectory.borough(ofStop: $0.lastStop) }
                    ?? StationDirectory.end(of: route, going: direction)?.borough ?? borough
            }
        }
        // Where its trains going `direction` end up, or with none to go by, where the line ends
        func ending(_ direction: Direction, _ trains: [Arrival]?) -> String? {
            trains?.first?.terminal ?? StationDirectory.end(of: route, going: direction)?.short
        }
        if labels.count == 2, Set(labels.values).count == 1 {
            for (direction, trains) in ways {
                labels[direction] = ending(direction, trains) ?? named(direction)
            }
        } else if labels.count == 1, let only = ways.first, !Lines.servesManhattan(route),
                  labels[only.key] == borough, let end = ending(only.key, only.value) {
            // The one way from the end of a line that stays in its borough, which the borough wouldn't say
            labels[only.key] = end
        }
        return labels
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

    /// Each station by each of its platforms' ids. Should stations.json list
    /// an id twice, the first is kept.
    private static let byID = Dictionary(all.flatMap { station in
        station.platforms.map { ($0.id, station) }
    }, uniquingKeysWith: { first, _ in first })
    /// Each platform by its id, and by any of its `aliases` no platform has as its id.
    private static let platformsByID: [String: Platform] = {
        let aliases = platforms.flatMap { platform in (platform.aliases ?? []).map { ($0, platform) } }
        return Dictionary(platforms.map { ($0.id, $0) } + aliases, uniquingKeysWith: { first, _ in first })
    }()

    /// Each complex's stations, in the list's order.
    private static let byComplex = Dictionary(grouping: all, by: \.complex)

    /// Each line's stops from its northern end south, by bullet label ("S" is
    /// every shuttle; lines.json is built by tools/make_lines.py).
    private static let lineStops: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "lines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let lines = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return lines
    }()

    /// `stations` in the order the line labeled `label` stops at them, north to
    /// south, with any it has no order for after the rest as they were.
    static func inLineOrder(_ stations: [Station], label: String) -> [Station] {
        guard let stops = lineStops[label] else { return stations }
        let position = Dictionary(stops.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        // A station joined from several platforms comes where the first of them does
        let ranked = stations.enumerated().map { offset, station in
            (station, station.platforms.compactMap { position[$0.id] }.min() ?? Int.max, offset)
        }
        return ranked.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }

    /// The stops of the line labeled `label` from its northern end south, by
    /// platform id; nil where lines.json has none.
    static func stops(onLine label: String) -> [String]? {
        lineStops[label]
    }

    /// `station`, then the stations passageways join it to, which are free to
    /// change to: 59 St's 4 5 6 for Lexington Av/59 St's N R W.
    static func stations(inComplexOf station: Station) -> [Station] {
        [station] + (byComplex[station.complex] ?? []).filter { $0.id != station.id }
    }

    /// Whether `route`'s line ends at `station` going `direction`, by day: it's
    /// the line's first stop north, or its last south. Where other lines go on,
    /// as the A does from the C's 168 St, the MTA still names the direction.
    static func line(_ route: String, endsAt station: Station, going direction: Direction) -> Bool {
        guard let stop = end(of: route, going: direction) else { return false }
        return station.platforms.contains { $0.id == stop.id }
    }

    /// Where `route`'s line ends going `direction`, by day: its first stop
    /// north, or its last south. Nil where lines.json has no order for it.
    static func end(of route: String, going direction: Direction) -> Platform? {
        // Just the route's own stops, as the three shuttles share the S's
        let stops = (lineStops[LineStyle.of(route).label] ?? []).filter { platformsByID[$0]?.routes.contains(route) == true }
        return (direction == .north ? stops.first : stops.last).flatMap { platformsByID[$0] }
    }

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

    /// The station of a stop on a train's way: "R31N" is Atlantic Av-Barclays Ctr.
    static func station(forStop stop: String) -> Station? {
        platform(forStop: stop).flatMap { byID[$0.id] }
    }

    /// The short name of a stop on a train's way: "R45N" is Bay Ridge.
    static func shortName(forStop stop: String) -> String? {
        platform(forStop: stop)?.short
    }

    /// The borough of a stop on a train's way: "R45S" is in Brooklyn.
    static func borough(ofStop stop: String) -> String? {
        platform(forStop: stop)?.borough
    }

    /// Whether two stops on trains' ways are one, though the feeds can give it
    /// another id: "H19N", where the H ends at Broad Channel, is "H04N".
    static func isSameStop(_ stop: String, _ other: String) -> Bool {
        guard stop != other else { return true }
        guard stop.last == other.last, let platform = platform(forStop: stop) else { return false }
        return platform.id == self.platform(forStop: other)?.id
    }

    private static func platform(forStop stop: String) -> Platform? {
        platformsByID[stop] ?? platformsByID[String(stop.dropLast())]
    }
}

/// A search for stations by name and borough, as the train picker and a
/// shortcut's train have it: "prospect", "86 st brooklyn", "34th street" or
/// "times square". Each of its words starts one of the station's, whatever
/// the case or punctuation, with the MTA's abbreviations ("St", "Av", "Sq")
/// standing for the words written out and a number for its ordinal ("34th").
struct StationSearch {
    private let words: [String]

    init(_ text: String) {
        words = Self.words(in: text)
    }

    /// Whether it finds `station`: every one, with nothing searched for.
    func matches(_ station: Station) -> Bool {
        guard !words.isEmpty else { return true }
        let forms = Self.formsByStation[station.id] ?? Self.forms(of: station)
        return words.allSatisfy { word in forms.contains { $0.hasPrefix(word) } }
    }

    /// Lowercased, apostrophes dropped ("St Mary's" is "st marys"), and split
    /// at anything else that isn't a letter or a digit.
    private static func words(in text: String) -> [String] {
        text.lowercased()
            .filter { $0 != "'" && $0 != "’" }
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// The MTA's abbreviations in station names, and the words they stand for.
    private static let abbreviations: [String: [String]] = [
        "st": ["street", "saint"], "sts": ["streets"], "av": ["avenue"], "avs": ["avenues", "aves"],
        "sq": ["square"], "blvd": ["boulevard"], "pkwy": ["parkway"], "rd": ["road"], "pl": ["place"],
        "pk": ["park"], "dr": ["drive"], "ln": ["lane"], "hwy": ["highway"], "tpke": ["turnpike"],
        "hts": ["heights"], "ctr": ["center", "centre"], "mt": ["mount"], "ft": ["fort"], "jct": ["junction"],
        "plz": ["plaza"], "e": ["east"], "w": ["west"], "n": ["north"], "wash": ["washington"],
    ]

    /// The other way round, for a name with the word written out: "Avenue H", "Fort Hamilton Pkwy".
    private static let shortenings: [String: [String]] = abbreviations.reduce(into: [:]) { shortenings, entry in
        for word in entry.value { shortenings[word, default: []].append(entry.key) }
    }

    /// Each word of a station's name and borough, as written, abbreviated or
    /// written out, and a number as its ordinal too: "34" is also "34th".
    private static func forms(of station: Station) -> [String] {
        words(in: "\(station.name) \(station.borough)").flatMap { word -> [String] in
            var forms = [word]
            forms += abbreviations[word] ?? []
            forms += shortenings[word] ?? []
            if let number = Int(word) { forms.append(ordinal(number)) }
            return forms
        }
    }

    /// "1st", "22nd", "103rd", "111th".
    private static func ordinal(_ number: Int) -> String {
        let suffix = (11...13).contains(number % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][number % 10] ?? "th"
        return "\(number)\(suffix)"
    }

    /// Every station's forms, by its id, worked out once.
    private static let formsByStation: [String: [String]] = Dictionary(
        StationDirectory.all.map { ($0.id, forms(of: $0)) }, uniquingKeysWith: { first, _ in first })
}
