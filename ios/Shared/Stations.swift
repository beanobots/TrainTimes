import Foundation

enum Direction: String, Codable, CaseIterable, Sendable {
    /// Feeds name a directional platform as station id plus N or S.
    case north = "N"
    case south = "S"

    var opposite: Direction { self == .north ? .south : .north }

    /// "Northbound" or "Southbound", used where the MTA gives no name.
    var compassName: String { self == .north ? "Northbound" : "Southbound" }

    /// From a feed stop id's suffix: "R31N" is north. Nil for a bare platform id.
    init?(ofStop stop: String) {
        self.init(rawValue: String(stop.suffix(1)))
    }
}

/// One set of tracks in a station, as the MTA lists them: e.g. the D N R at Atlantic Av-Barclays
/// Ctr, separate from its B Q and 2 3 4 5.
struct Platform: Codable, Hashable, Identifiable, Sendable {
    /// The GTFS stop id, e.g. "R34". Feeds add N or S per direction.
    let id: String
    let name: String
    /// Short terminal name, e.g. "Forest Hills" for "Forest Hills-71 Av".
    let short: String
    let borough: String
    /// Real-time route ids of the lines that stop here.
    let routes: [String]
    /// The MTA's names for the two directions; empty at the end of a line. They follow most of its
    /// lines (the first line's on a tie); see `reversed`.
    let north: String
    let south: String
    /// Lines whose N here goes the way `south` names, and S the way `north` does. Feeds keep one
    /// direction per trip along its whole line, so an M toward Middle Village is S at Marcy Av,
    /// where south is "Manhattan" for the J. Nil for none.
    var reversed: [String]? = nil
    let lat: Double
    let lon: Double
    /// The station complex, shared by stations joined by passageways and their elevators.
    let complex: String
    /// 0: not accessible, 1: accessible, 2: partly accessible (see `adaNotes`).
    let ada: Int
    /// Which part is accessible at a partly accessible station, e.g. "Manhattan-bound only".
    let adaNotes: String
    let entrances: [Station.Entrance]
    /// Other feed ids for it, e.g. H19 at Broad Channel (where the Rockaway Park Shuttle ends).
    /// Nil for none.
    var aliases: [String]? = nil

    /// The accessibility label, or nil without step-free access.
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

    /// The MTA's name for where `route` goes in `direction` (the other way's name if `reversed`).
    /// A name for several lines keeps only the parts this one goes to (`ownParts(of:for:going:)`).
    /// If that's "Manhattan" but the line never gets there (the H at Beach 90 St borrows the A's),
    /// uses the line's end instead ("Broad Channel"), or empty if it ends here. `whole` keeps a
    /// name for several lines whole, to match it with others on the platform.
    func directionName(_ direction: Direction, of route: String, whole: Bool = false) -> String {
        let named = directionName(side(of: route, going: direction))
        let name = whole ? named : ownParts(of: named, for: route, going: direction)
        guard name == "Manhattan", !Lines.servesManhattan(route),
              let end = StationDirectory.end(of: route, going: direction) else { return name }
        return end.id == id ? "" : end.short
    }

    /// `name` cut to the " - " parts `route` goes to in `direction` from here: the G's "Queens" of
    /// the F and G's "Manhattan - Queens", the R's "Bay Ridge" of the D N R's "Coney Island - Bay
    /// Ridge". Parts that together name one stop stay together ("34 St - Hudson Yards"). Of a part
    /// joined by "&", the places the line goes to stay if no other part is wholly its, unless
    /// that leaves only "Uptown" or "Downtown" (the F's "Uptown & The Bronx"). With no part the line's, its end that way (the
    /// 4's "Crown Hts" for "Flatbush - New Lots"), or else the whole name. Parts naming lines
    /// ("Broad St (JZ) - Uptown (M)") leave it whole.
    private func ownParts(of name: String, for route: String, going direction: Direction) -> String {
        guard name.contains(" - "), !name.contains("(") else { return name }
        func reaches(_ place: String) -> Bool {
            place == "Uptown" || place == "Downtown"
                || StationDirectory.goes(route, going: direction, from: id, toward: place)
        }
        let parts = name.components(separatedBy: " - ")
        var kept: [String] = []
        // Places from "&" parts the line goes only partly to, used if no part is wholly its
        var partly: [String] = []
        var index = 0
        while index < parts.count {
            // The longest run of parts that's one stop, as "Wakefield - 241 St" is Wakefield-241 St
            if let last = (index + 1 ..< parts.count).reversed().first(where: {
                StationDirectory.goes(route, going: direction, from: id, toward: parts[index ... $0].joined(separator: "-"))
            }) {
                kept.append(parts[index ... last].joined(separator: " - "))
                index = last + 1
                continue
            }
            let places = parts[index].components(separatedBy: " & ")
            let reached = places.filter(reaches)
            if reached.count == places.count {
                kept.append(parts[index])
            } else if reached.contains(where: { $0 != "Uptown" && $0 != "Downtown" }) {
                partly.append(reached.joined(separator: " & "))
            }
            index += 1
        }
        if !kept.isEmpty { return kept.joined(separator: " - ") }
        if !partly.isEmpty { return partly.joined(separator: " - ") }
        guard let end = StationDirectory.end(of: route, going: direction), end.id != id,
              StationDirectory.goes(route, going: direction, from: id, toward: end.name) else { return name }
        return end.short
    }

    /// The side (named by `north`/`south`) where `route` going `direction` stops: flipped if
    /// `isReversed(_:)`. An M going N at Marcy Av stops on the S ("Manhattan") side, like a J
    /// going S. Trains on the same side are across the platform from each other.
    func side(of route: String, going direction: Direction) -> Direction {
        isReversed(route) ? direction.opposite : direction
    }

    /// Whether `route` here follows the `reversed` lines' N/S: true for those lines, and for a line
    /// that doesn't stop here unless a non-reversed line here shares its trunk (bullet color).
    /// E.g. an F at the J's Delancey St-Essex St platform can only arrive via the M's Chrystie St
    /// connection, so it follows the M; a Z running local follows the J.
    func isReversed(_ route: String) -> Bool {
        guard let reversed else { return false }
        if routes.contains(route) { return reversed.contains(route) }
        let color = LineStyle.of(route).color
        return !routes.contains { !reversed.contains($0) && LineStyle.of($0).color == color }
    }

    /// The feed's N or S for `route` going `direction` together with `routes`, so all stop on one
    /// side: `direction`, flipped if the line is `reversed` and some of `routes` here aren't. A
    /// line alone, or only with lines reversed like it, keeps its own. Lines that don't stop here
    /// take that side by their own N/S (`isReversed(_:)`): with the M alone toward Manhattan from
    /// Flushing Av, an F is N like the M, and a Z running local is S like the J.
    func direction(_ direction: Direction, of route: String, with routes: [String]) -> Direction {
        let here = routes.filter(self.routes.contains)
        guard !here.isEmpty else { return direction }
        // The side they stop on; flipped if every one is `reversed`
        let side = here.allSatisfy { isReversed($0) } ? direction.opposite : direction
        // `route`'s N or S on that side
        return self.side(of: route, going: side)
    }

    /// Whether `route` here can be on a track of one of `routes`: it follows the same N/S as one of
    /// them stopping here (`isReversed(_:)`), or the reversed lines share track (`sharesTrack`).
    /// With the G alone at Hoyt-Schermerhorn Sts, an F on its track counts; an E doesn't.
    func carries(_ route: String, with routes: [String]) -> Bool {
        let theirs = isReversed(route)
        return routes.contains { self.routes.contains($0) && isReversed($0) == theirs } || sharesTrack
    }

    /// Whether `reversed` lines share track with the others, by lines.json order: a neighbouring
    /// stop is shared (Hewes St, Delancey St-Essex St for the M and J at Marcy Av). At
    /// Hoyt-Schermerhorn Sts the G and the A/C have separate tracks.
    var sharesTrack: Bool {
        guard let reversed else { return false }
        let others = Set(routes.filter { !reversed.contains($0) }.flatMap { neighbours(on: $0) })
        return routes.contains { reversed.contains($0) && !others.isDisjoint(with: neighbours(on: $0)) }
    }

    /// Adjacent stops on `route`'s line per lines.json; empty if not listed.
    private func neighbours(on route: String) -> [String] {
        guard let stops = StationDirectory.stops(onLine: LineStyle.of(route).label),
              let at = stops.firstIndex(of: id) else { return [] }
        return [at - 1, at + 1].filter(stops.indices.contains).map { stops[$0] }
    }

    /// Feed stop ids where `routes` call here going `direction` together (`direction(_:of:with:)`),
    /// `direction`'s first: e.g. "R31N", or at Marcy Av toward Manhattan, "M16S" and "M16N".
    func stops(of routes: [String], going direction: Direction) -> [String] {
        let ways = routes.filter(self.routes.contains).map { self.direction(direction, of: $0, with: routes) }
        return [direction, direction.opposite].filter { $0 == direction || ways.contains($0) }.map { id + $0.rawValue }
    }

    /// The single step-free way of a partly accessible platform, when `adaNotes` names exactly one
    /// ("Downtown only", "Southbound Only"). Nil otherwise, including notes about only some trains
    /// ("Uptown & The Bronx local only"). Safe for every line here: make_stations.py never marks
    /// a line `reversed` on a partly accessible platform.
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

    /// Whether it's step-free going `direction` (nil: either way). Nil for a partly accessible
    /// platform when that can't be told.
    func isStepFree(going direction: Direction? = nil) -> Bool? {
        switch ada {
        case 1: true
        case 2: direction.flatMap { direction in stepFreeWay.map { $0 == direction } }
        default: false
        }
    }

    /// Its first line's position in the MTA's order.
    fileprivate var rank: Int { routes.map(Lines.rank).min() ?? Int.max }
}

extension Array where Element == Platform {
    /// Step-free mode's note for these platforms, going `direction` if chosen: nil if all are
    /// step-free, "No step-free access" if none, a single platform's own label, else
    /// "Step-free on some platforms".
    func stepFreeNote(going direction: Direction? = nil) -> String? {
        let access = map { $0.isStepFree(going: direction) }
        if access.allSatisfy({ $0 == true }) { return nil }
        if access.allSatisfy({ $0 == false }) { return "No step-free access" }
        if count == 1 { return self[0].accessibility }
        return "Step-free on some platforms"
    }
}

/// A station as riders know it: one or more same-named platforms joined by passageways (e.g.
/// Atlantic Av-Barclays Ctr's D N R, B Q and 2 3 4 5).
struct Station: Hashable, Identifiable, Sendable {
    /// Its first platform's id; the other platform ids also look it up.
    let id: String
    let name: String
    let borough: String
    /// Real-time route ids of every line that stops here.
    let routes: [String]
    /// In the order of their lines.
    let platforms: [Platform]
    /// The station complex, sharing elevators and escalators.
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
        // One platform keeps its own order (J M Z); several are sorted in the MTA's line order
        let routes = platforms.flatMap(\.routes)
        self.routes = platforms.count == 1 ? routes : routes.enumerated()
            .sorted { (Lines.rank($0.element), $0.offset) < (Lines.rank($1.element), $1.offset) }
            .map(\.element)
        self.platforms = platforms
        complex = first.complex
        lat = platforms.map(\.lat).reduce(0, +) / Double(platforms.count)
        lon = platforms.map(\.lon).reduce(0, +) / Double(platforms.count)
        // Shared entrances may be listed under each platform
        var seen = Set<Entrance>()
        entrances = platforms.flatMap(\.entrances).filter { seen.insert($0).inserted }
    }

    func platforms(serving routes: [String]) -> [Platform] {
        platforms.filter { $0.routes.contains(where: routes.contains) }
    }

    /// The lines at `platform` (one of its own), in the station's order.
    func lines(on platform: Platform) -> [String] {
        routes.filter(platform.routes.contains)
    }

    /// Where `routes` go in `direction`: "Manhattan", or "Northbound" if unnamed. Differing
    /// platform names are joined: "Coney Island - Bay Ridge or Flatbush - New Lots".
    func directionLabel(_ direction: Direction, routes: [String]) -> String {
        Self.directionLabel(direction, on: platforms(serving: routes), routes: routes)
    }

    /// The MTA's name for `route`'s `direction` here ("Uptown & The Bronx"); empty at line's end.
    func directionName(_ direction: Direction, of route: String) -> String {
        platforms(serving: [route]).lazy.map { $0.directionName(direction, of: route) }.first { !$0.isEmpty } ?? ""
    }

    /// `Platform.direction(_:of:with:)` at `route`'s platform here.
    func direction(_ direction: Direction, of route: String, with routes: [String]) -> Direction {
        platforms(serving: [route]).first?.direction(direction, of: route, with: routes) ?? direction
    }

    /// Directions the MTA names for `routes` here, or both if it names neither. An unnamed
    /// direction (line's end) has no trains.
    func directions(of routes: [String]) -> [Direction] {
        let serving = platforms(serving: routes)
        let named = Direction.allCases.filter { !Self.directionNames($0, on: serving, routes: routes).isEmpty }
        return named.isEmpty ? Direction.allCases : named
    }

    /// `directions(of:)` minus any where all of `routes` end their daytime run though other lines
    /// continue (the C at 168 St), unless that leaves none.
    func onwardDirections(of routes: [String]) -> [Direction] {
        let named = directions(of: routes)
        let onward = named.filter { direction in
            routes.contains {
                !StationDirectory.line($0, endsAt: self, going: self.direction(direction, of: $0, with: routes))
            }
        }
        return onward.isEmpty ? named : onward
    }

    /// `directionNames` joined by "or"; the compass name if none.
    static func directionLabel(_ direction: Direction, on platforms: [Platform], routes: [String]? = nil) -> String {
        let names = directionNames(direction, on: platforms, routes: routes)
        if names.isEmpty { return direction.compassName }
        return names.joined(separator: " or ")
    }

    /// The MTA's distinct names for `direction` at `platforms`: per line of `routes` stopping
    /// there, going together (`Platform.direction(_:of:with:)`), or the platform's own name if none.
    /// `whole` keeps names for several lines whole (`Platform.directionName(_:of:whole:)`).
    static func directionNames(_ direction: Direction, on platforms: [Platform], routes: [String]? = nil,
                               whole: Bool = false) -> [String] {
        var names: [String] = []
        for platform in platforms {
            let own = routes?.filter(platform.routes.contains) ?? []
            var named = own.isEmpty ? [platform.directionName(direction)]
                : own.map { platform.directionName(platform.direction(direction, of: $0, with: own), of: $0, whole: whole) }
            // Lines that between them go every way a name says keep it whole: the J and M's
            // "Jamaica - Middle Village" at Marcy Av, not "Jamaica or Middle Village"
            let sides = Set(own.map { platform.side(of: $0, going: platform.direction(direction, of: $0, with: own)) })
            if !whole, own.count > 1, sides.count == 1, let side = sides.first {
                let name = platform.directionName(side)
                // Each part, or a place of an "&" part, is some line's: the C's "Euclid Av" and
                // the G's "Court Sq" cover "Euclid Av & Queens - Court Sq"
                func places(_ names: [String]) -> Set<String> {
                    Set(names.flatMap { $0.components(separatedBy: " - ") }.flatMap { $0.components(separatedBy: " & ") })
                }
                let ours = places(named)
                let covered = name.components(separatedBy: " - ").allSatisfy { part in
                    part.components(separatedBy: " & ").contains(where: ours.contains)
                }
                // Not where a line goes elsewhere: the H's "Broad Channel" with the A's "Manhattan"
                if name.contains(" - "), covered, ours.isSubset(of: places([name])) { named = [name] }
            }
            for name in named where !name.isEmpty && !names.contains(name) {
                names.append(name)
            }
        }
        // The F and G together go "Manhattan - Queens", not also the G's own "Queens"
        let parts = names.map { Set($0.components(separatedBy: " - ")) }
        return names.indices.filter { index in
            !parts.indices.contains { other in
                other != index && parts[index].isStrictSubset(of: parts[other])
            }
        }.map { names[$0] }
    }

    func serves(label: String) -> Bool {
        routes.contains { LineStyle.of($0).label == label }
    }
}

/// One direction of a line at a station, as Trains near you and the app's Nearby list show it.
struct LineWay {
    /// The line alone, going this way.
    let selection: Selection
    /// "Manhattan", "Brooklyn", "Uptown"
    let label: String
    /// Its own upcoming trains (not other lines on its tracks), soonest first; nil if unavailable.
    let trains: [Arrival]?

    var direction: Direction { selection.direction }
}

extension Station {
    /// Each line alone, both ways: what the Nearby lists fetch.
    var lineSelections: [Selection] {
        routes.flatMap { route in
            Direction.allCases.map { Selection(stationID: id, routes: [route], direction: $0) }
        }
    }

    /// `route`'s two directions here for the Nearby lists, with its trains from `trains` (keyed
    /// by `Selection.trainID`, from `TrainService.trains(for:)`) not yet left at `now`. Outside
    /// Manhattan, toward Manhattan comes first; otherwise north (uptown). Nil for a direction it
    /// doesn't go: unnamed (line's end), or where the line ends though others continue, unless
    /// some of its trains do.
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

    /// Labels for `route`'s directions here. In Manhattan, the MTA's name, cut to "Uptown" or
    /// "Downtown" when it starts with one (the L's are "8 Av" and "Brooklyn"). Elsewhere,
    /// "Manhattan" toward it, and for the other way the trains' destination borough (or the line
    /// end's). A single-borough line, like the Staten Island Railway, uses its trains' terminal.
    private func wayLabels(of route: String, trains ways: [Direction: [Arrival]?]) -> [Direction: String] {
        // "Uptown & The Bronx" and "Uptown - Queens" are uptown
        func named(_ direction: Direction) -> String {
            var name = directionName(direction, of: route)
            // Pick this line's part: "Broad St (JZ) - Uptown (M)" is Uptown for the M
            let label = LineStyle.of(route).label
            if let own = name.components(separatedBy: " - ").first(where: {
                $0.hasSuffix(")") && ($0.components(separatedBy: "(").last ?? "").contains(label)
            }) {
                name = own.components(separatedBy: " (")[0]
            }
            name = name.components(separatedBy: " & ")[0]
            // Only those two: "34 St - Hudson Yards" stays as is
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
        // The trains' terminal, or else the line's end
        func ending(_ direction: Direction, _ trains: [Arrival]?) -> String? {
            trains?.first?.terminal ?? StationDirectory.end(of: route, going: direction)?.short
        }
        if labels.count == 2, Set(labels.values).count == 1 {
            for (direction, trains) in ways {
                labels[direction] = ending(direction, trains) ?? named(direction)
            }
        } else if labels.count == 1, let only = ways.first, !Lines.servesManhattan(route),
                  labels[only.key] == borough, let end = ending(only.key, only.value) {
            // Single way from the end of a one-borough line: the borough would say nothing
            labels[only.key] = end
        }
        return labels
    }
}

enum StationDirectory {
    /// Every subway and Staten Island Railway platform (stations.json, from tools/make_stations.py).
    static let platforms: [Platform] = {
        guard let url = Bundle.main.url(forResource: "stations", withExtension: "json"),
              let platforms = try? load(from: url) else { return [] }
        return platforms
    }()

    /// Every station, in the list's order.
    static let all: [Station] = stations(from: platforms)

    /// Stations by each platform id; on duplicate ids, the first wins.
    private static let byID = Dictionary(all.flatMap { station in
        station.platforms.map { ($0.id, station) }
    }, uniquingKeysWith: { first, _ in first })
    /// Platforms by id, and by any `aliases` not already a platform id.
    private static let platformsByID: [String: Platform] = {
        let aliases = platforms.flatMap { platform in (platform.aliases ?? []).map { ($0, platform) } }
        return Dictionary(platforms.map { ($0.id, $0) } + aliases, uniquingKeysWith: { first, _ in first })
    }()

    /// Each complex's stations, in the list's order.
    private static let byComplex = Dictionary(grouping: all, by: \.complex)

    /// Each line's stops north to south, by bullet label ("S" covers all shuttles; lines.json is
    /// built by tools/make_lines.py).
    private static let lineStops: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "lines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let lines = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return lines
    }()

    /// `stations` sorted north to south along line `label`; unlisted ones last, in original order.
    static func inLineOrder(_ stations: [Station], label: String) -> [Station] {
        guard let stops = lineStops[label] else { return stations }
        let position = Dictionary(stops.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        // A multi-platform station sorts by its earliest platform
        let ranked = stations.enumerated().map { offset, station in
            (station, station.platforms.compactMap { position[$0.id] }.min() ?? Int.max, offset)
        }
        return ranked.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }

    /// Platform ids of line `label`, north to south; nil if not in lines.json.
    static func stops(onLine label: String) -> [String]? {
        lineStops[label]
    }

    /// `route`'s own platform ids, north to south as lines.json lists them, each branch after the
    /// stop it leaves from (`branches(of:)`); empty if not listed.
    static func stops(of route: String) -> [String] {
        routeStops[route] ?? []
    }

    /// Each way `route` runs from its north end to an end south (`branches(_:of:)`): the A's
    /// three, to Lefferts Blvd, Rockaway Park and Far Rockaway. Empty if not listed.
    static func branches(of route: String) -> [[String]] {
        routeBranches[route] ?? []
    }

    /// Each line's own stops (`stops(of:)`), worked out once: the three shuttles share "S".
    private static let routeStops: [String: [String]] = {
        let routes = Set(platforms.flatMap(\.routes))
        return Dictionary(uniqueKeysWithValues: routes.map { route in
            (route, (lineStops[LineStyle.of(route).label] ?? []).filter { platformsByID[$0]?.routes.contains(route) == true })
        })
    }()

    /// Each line's branches (`branches(of:)`), worked out once.
    private static let routeBranches: [String: [[String]]] = Dictionary(uniqueKeysWithValues: routeStops.map { route, stops in
        (route, branches(stops, of: route))
    })

    /// `stops` (`route`'s own, as lines.json lists them) as each way from the line's north end to
    /// an end south. lines.json puts a branch right after the stop it leaves from, then the rest
    /// of the line after the branch's end, which is a stop with no name going south: the A's
    /// Lefferts Blvd stops after Rockaway Blvd, then the Rockaways', with Rockaway Park's after
    /// Broad Channel and then Far Rockaway's. The stop a branch leaves from is the one before
    /// it whose name going south isn't the branch's own: its stops are all named for its end
    /// ("Lefferts Blvd"), the stop it leaves from for more ("Lefferts - Rockaways").
    static func branches(_ stops: [String], of route: String) -> [[String]] {
        func southName(_ id: String) -> String? {
            platformsByID[id].map { $0.directionName($0.side(of: route, going: .south)) }
        }
        var branches: [[String]] = []
        var path: [String] = []
        for (index, stop) in stops.enumerated() {
            path.append(stop)
            guard index < stops.count - 1, southName(stop)?.isEmpty == true else { continue }
            branches.append(path)
            // Back to the stop it left from, past the stops named for its end
            let name = path.count > 1 ? southName(path[path.count - 2]) : nil
            var from = path.count - 2
            while from >= 0, southName(path[from]) == name { from -= 1 }
            path = from >= 0 ? Array(path[...from]) : []
        }
        if !path.isEmpty { branches.append(path) }
        return branches
    }

    /// `route`'s stops after the first of `platformIDs` (a station's) going `direction`, nearest
    /// first, along each of its branches there (`branches(of:)`): south from Rockaway Blvd, the
    /// A's to Lefferts Blvd and to the Rockaways; from Beach 90 St, only Rockaway Park's. Empty if
    /// it doesn't stop there.
    static func stops(of route: String, from platformIDs: Set<String>, going direction: Direction) -> [String] {
        var ahead: [String] = []
        var seen = Set<String>()
        for branch in branches(of: route) {
            guard let here = branch.firstIndex(where: platformIDs.contains) else { continue }
            let stops = direction == .north ? Array(branch[..<here].reversed()) : Array(branch[(here + 1)...])
            ahead += stops.filter { seen.insert($0).inserted }
        }
        return ahead
    }

    /// `route`'s next stop after the first of `platformIDs` going `direction`; nil at the end of
    /// the line, if it doesn't stop there, or where its branches part (south from Rockaway Blvd).
    static func nextStop(of route: String, from platformIDs: Set<String>, going direction: Direction) -> String? {
        let next = Set(branches(of: route).compactMap { branch -> String? in
            guard let here = branch.firstIndex(where: platformIDs.contains) else { return nil }
            let index = here + (direction == .north ? -1 : 1)
            return branch.indices.contains(index) ? branch[index] : nil
        })
        return next.count == 1 ? next.first : nil
    }

    /// Which way `route` goes from the first of `origin`'s platform ids (a station's) to the
    /// first of `targets`, by its stops north to south along a branch with both; nil if it
    /// doesn't stop at both, or only on different branches (Beach 90 St and Beach 67 St, on the
    /// A's to Rockaway Park and to Far Rockaway).
    static func direction(of route: String, from origin: Set<String>, to targets: Set<String>) -> Direction? {
        for branch in branches(of: route) {
            guard let from = branch.firstIndex(where: origin.contains),
                  let to = branch.firstIndex(where: targets.contains), from != to else { continue }
            return to < from ? .north : .south
        }
        return nil
    }

    /// `station`, then stations joined to it by passageway (free transfer): e.g. 59 St's 4 5 6 for
    /// Lexington Av/59 St's N R W.
    static func stations(inComplexOf station: Station) -> [Station] {
        [station] + (byComplex[station.complex] ?? []).filter { $0.id != station.id }
    }

    /// Feed stop ids at `station` and stations joined to it, both ways, e.g. "D17N": where a
    /// train gets to a destination.
    static func stops(inComplexOf station: Station) -> Set<String> {
        Set(stations(inComplexOf: station).flatMap(\.platforms).flatMap { platform in
            Direction.allCases.map { platform.id + $0.rawValue }
        })
    }

    /// Whether `route`'s daytime line ends at `station` going `direction` (`end(of:going:)`).
    /// Where other lines continue (the A past the C's 168 St), the MTA still names the direction.
    static func line(_ route: String, endsAt station: Station, going direction: Direction) -> Bool {
        guard let stop = end(of: route, going: direction) else { return false }
        return station.platforms.contains { $0.id == stop.id }
    }

    /// `route`'s daytime terminal going `direction`: first stop north, last south. Nil if not in
    /// lines.json.
    static func end(of route: String, going direction: Direction) -> Platform? {
        let stops = Self.stops(of: route)
        return (direction == .north ? stops.first : stops.last).flatMap { platformsByID[$0] }
    }

    private static let boroughs = Set(platforms.map(\.borough))

    /// The way along `route`'s line from `platformIDs` (a station's) toward `place`, as an alert
    /// names it before "-bound": a station ("Crown Heights-Utica Av", "Flatbush Av" for
    /// Flatbush Av-Brooklyn College) or a borough ("Manhattan", "The Bronx"). A borough is the
    /// way to whichever end of the line is in it, if only one is; otherwise, as for a station,
    /// the way its stations are. Nil when the line doesn't stop here, has no such place, or has
    /// it both ways from here.
    static func direction(toward place: String, on route: String, from platformIDs: Set<String>) -> Direction? {
        let stops = Self.stops(of: route)
        guard let here = stops.firstIndex(where: platformIDs.contains) else { return nil }
        // A borough by its stations, not by names that start with it, as Brooklyn Bridge-City Hall does
        let named = place.hasPrefix("The ") ? String(place.dropFirst(4)) : place
        let isBorough = boroughs.contains(named)
        // A borough one end of the line is in, and the other isn't: from Canal St the J is
        // Manhattan-bound toward Broad St, as the other end is in Queens
        if isBorough, let north = stops.first.flatMap({ platformsByID[$0] }),
           let south = stops.last.flatMap({ platformsByID[$0] }), (north.borough == named) != (south.borough == named) {
            let toward: Direction = north.borough == named ? .north : .south
            // Not from the end itself, which nothing goes toward
            if stops[here] != (toward == .north ? stops.first : stops.last) { return toward }
        }
        let found = { (direction: Direction) in
            Self.stops(of: route, from: [stops[here]], going: direction).contains { id in
                guard let platform = platformsByID[id] else { return false }
                if isBorough { return platform.borough == named }
                return platform.name == place || platform.name.hasPrefix(place + "-") || platform.name.hasPrefix(place + " ")
            }
        }
        // Only one way along the line's branches from here
        let north = found(.north), south = found(.south)
        return north == south ? nil : north ? .north : .south
    }

    /// Whether `route` going `direction` from `platformID` gets to `place`, as the MTA names a
    /// direction: a borough with any of its stops that way, or a stop whose name has the place's
    /// words in it, give or take a plural or abbreviation ("Utica" for Crown Hts-Utica Av,
    /// "Rockaways" for Far Rockaway-Mott Av, "Eastchester Dyre Av" for Eastchester-Dyre Av).
    static func goes(_ route: String, going direction: Direction, from platformID: String, toward place: String) -> Bool {
        let ahead = stops(of: route, from: [platformID], going: direction).compactMap { platformsByID[$0] }
        let borough = place.hasPrefix("The ") ? String(place.dropFirst(4)) : place
        if boroughs.contains(borough) { return ahead.contains { $0.borough == borough } }
        let place = nameWords(place)
        // "Rockaways" is the area, as in Far Rockaway, not Rockaway Av
        let area = place.last?.hasSuffix("s") == true ? Array(place.dropLast()) + [String(place.last!.dropLast())] : nil
        let streets: Set = ["av", "avenue", "st", "sts", "blvd", "rd", "parkway", "pl"]
        return ahead.contains { platform in
            let words = nameWords(platform.name)
            func found(_ run: [String], unlessStreet: Bool) -> Bool {
                guard !run.isEmpty, words.count >= run.count else { return false }
                return (0 ... words.count - run.count).contains { start in
                    let after = start + run.count
                    return Array(words[start ..< after]) == run
                        && !(unlessStreet && after < words.count && streets.contains(words[after]))
                }
            }
            return found(place, unlessStreet: false) || area.map { found($0, unlessStreet: true) } == true
        }
    }

    /// A name's words for matching, lowercased, with "-" and "/" as spaces and abbreviations spelled out.
    private static func nameWords(_ name: String) -> [String] {
        let spelled = ["pkwy": "parkway", "hts": "heights"]
        return name.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
            .map { spelled[String($0)] ?? String($0) }
    }

    static func load(from url: URL) throws -> [Platform] {
        try JSONDecoder().decode([Platform].self, from: Data(contentsOf: url))
    }

    /// Groups same-named platforms in a complex into one station, placed at the first's position.
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

    /// By station or platform id: "R31", "D24" and "235" are all Atlantic Av-Barclays Ctr.
    static func station(id: String) -> Station? {
        byID[id]
    }

    /// By feed stop id: "R31N" is Atlantic Av-Barclays Ctr.
    static func station(forStop stop: String) -> Station? {
        platform(forStop: stop).flatMap { byID[$0.id] }
    }

    /// "R45N" is Bay Ridge.
    static func shortName(forStop stop: String) -> String? {
        platform(forStop: stop)?.short
    }

    /// "R45S" is in Brooklyn.
    static func borough(ofStop stop: String) -> String? {
        platform(forStop: stop)?.borough
    }

    /// Whether two feed stop ids are the same stop, allowing aliases: "H19N" (where the H ends at
    /// Broad Channel) is "H04N".
    static func isSameStop(_ stop: String, _ other: String) -> Bool {
        guard stop != other else { return true }
        guard stop.last == other.last, let platform = platform(forStop: stop) else { return false }
        return platform.id == self.platform(forStop: other)?.id
    }

    /// By feed stop id or platform id, allowing aliases: "R31N" and "R31" are the D N R's platform
    /// at Atlantic Av-Barclays Ctr.
    static func platform(forStop stop: String) -> Platform? {
        platformsByID[stop] ?? platformsByID[String(stop.dropLast())]
    }
}

/// Station search by name and borough (train picker, shortcuts): "86 st brooklyn", "34th street".
/// Each query word must prefix a station word, ignoring case and punctuation; MTA abbreviations
/// ("St", "Av", "Sq") match the full words, and numbers match ordinals ("34th").
struct StationSearch {
    private let words: [String]

    init(_ text: String) {
        words = Self.words(in: text)
    }

    /// An empty search matches every station.
    func matches(_ station: Station) -> Bool {
        guard !words.isEmpty else { return true }
        let forms = Self.formsByStation[station.id] ?? Self.forms(of: station)
        return words.allSatisfy { word in forms.contains { $0.hasPrefix(word) } }
    }

    /// Lowercased, apostrophes dropped ("St Mary's" is "st marys"), split on non-alphanumerics.
    private static func words(in text: String) -> [String] {
        text.lowercased()
            .filter { $0 != "'" && $0 != "’" }
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// MTA abbreviations in station names, and their full words.
    private static let abbreviations: [String: [String]] = [
        "st": ["street", "saint"], "sts": ["streets"], "av": ["avenue"], "avs": ["avenues", "aves"],
        "sq": ["square"], "blvd": ["boulevard"], "pkwy": ["parkway"], "rd": ["road"], "pl": ["place"],
        "pk": ["park"], "dr": ["drive"], "ln": ["lane"], "hwy": ["highway"], "tpke": ["turnpike"],
        "hts": ["heights"], "ctr": ["center", "centre"], "mt": ["mount"], "ft": ["fort"], "jct": ["junction"],
        "plz": ["plaza"], "e": ["east"], "w": ["west"], "n": ["north"], "wash": ["washington"],
    ]

    /// The reverse, for names with the word spelled out: "Avenue H", "Fort Hamilton Pkwy".
    private static let shortenings: [String: [String]] = abbreviations.reduce(into: [:]) { shortenings, entry in
        for word in entry.value { shortenings[word, default: []].append(entry.key) }
    }

    /// Each word of a station's name and borough, plus abbreviated/expanded forms and ordinals
    /// ("34" is also "34th").
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

    /// Every station's forms by id, computed once.
    private static let formsByStation: [String: [String]] = Dictionary(
        StationDirectory.all.map { ($0.id, forms(of: $0)) }, uniquingKeysWith: { first, _ in first })
}
