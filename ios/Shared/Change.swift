import Foundation

/// Where a saved widget's train is left for another: a station on its way, and
/// the lines to change to there, or at a station passageways join to it, going
/// one way. The Transfers widget pairs each of its trains with the first train
/// there it can catch.
struct Change: Codable, Hashable, Sendable {
    /// A `Station.id`: where you leave your train.
    var stationID: String
    /// Real-time route ids of the lines to change to, in the order of `lines(at:)`.
    var routes: [String]
    /// Which way they go; nil, as for a change saved before there was a choice,
    /// for your train's way. The feeds' N and S are each line's own, so from
    /// the L's N at Broadway Junction, toward Manhattan, it's the J's S. Lines
    /// that run opposite ways on one platform go together as a train's do
    /// (`Selection.direction`): toward Brooklyn at Delancey St-Essex St, the J's
    /// N and the M's S.
    var direction: Direction?
    /// The longest wait, in minutes, that the large widget highlights.
    var quickMinutes: Int
    /// Minutes to walk to a line on another platform than the train's.
    var walkMinutes: Int

    static let defaultQuickMinutes = 2
    static let defaultWalkMinutes = 3

    init(stationID: String, routes: [String], direction: Direction? = nil,
         quickMinutes: Int = Change.defaultQuickMinutes, walkMinutes: Int = Change.defaultWalkMinutes) {
        self.stationID = stationID
        self.routes = routes
        self.direction = direction
        self.quickMinutes = quickMinutes
        self.walkMinutes = walkMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case stationID, routes, direction, quickMinutes, walkMinutes
    }

    /// A change saved without a way, a quick change or a walk still loads,
    /// going your train's way with the default times. Any property added
    /// later needs a default here too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(stationID: try container.decode(String.self, forKey: .stationID),
                  routes: try container.decode([String].self, forKey: .routes),
                  direction: try container.decodeIfPresent(Direction.self, forKey: .direction),
                  quickMinutes: try container.decodeIfPresent(Int.self, forKey: .quickMinutes) ?? Change.defaultQuickMinutes,
                  walkMinutes: try container.decodeIfPresent(Int.self, forKey: .walkMinutes) ?? Change.defaultWalkMinutes)
    }

    var station: Station? { StationDirectory.station(id: stationID) }

    /// Which way the lines changed to go from `selection`'s train.
    func departureDirection(for selection: Selection) -> Direction {
        direction ?? selection.direction
    }

    /// The feeds' N or S for trains of `route`, one of the lines changed to,
    /// going their way from `selection`'s train: `departureDirection(for:)`,
    /// but the other where the line runs the other way to another changed to
    /// on its platform (`Platform.direction(_:of:with:)`).
    func departureDirection(of route: String, for selection: Selection) -> Direction {
        let way = departureDirection(for: selection)
        return departurePlatforms.first { $0.routes.contains(route) }?.direction(way, of: route, with: routes) ?? way
    }

    /// The station's platforms that `selection`'s train stops at.
    private func arrivalPlatforms(for selection: Selection) -> [Platform] {
        station?.platforms(serving: selection.routes) ?? []
    }

    /// Where `selection`'s train calls here, as the feeds name it: "R31N". Each
    /// of its lines goes by its own N or S all along (`Selection.direction(of:)`),
    /// so from Marcy Av toward Manhattan, the J's "M18S" and the M's "M18N".
    func arrivalStops(for selection: Selection) -> [String] {
        arrivalPlatforms(for: selection).flatMap { platform in
            let ways = selection.routes.filter(platform.routes.contains).map { selection.direction(of: $0) }
            return [selection.direction, selection.direction.opposite]
                .filter { $0 == selection.direction || ways.contains($0) }
                .map { platform.id + $0.rawValue }
        }
    }

    /// The platforms of the lines changed to, here or at a station joined to it.
    private var departurePlatforms: [Platform] {
        guard let station else { return [] }
        return StationDirectory.stations(inComplexOf: station).flatMap { $0.platforms(serving: routes) }
    }

    /// Where the lines changed to call here, going their way: "R31N", or from
    /// the L at Broadway Junction toward Manhattan, the J's "J27S".
    func departureStops(for selection: Selection) -> [String] {
        let direction = departureDirection(for: selection)
        return departurePlatforms.flatMap { $0.stops(of: routes, going: direction) }
    }

    /// Whether `train`, here, is one of the lines changed to going their way,
    /// each by its own N or S (`departureDirection(of:for:)`): toward Brooklyn
    /// at Delancey St-Essex St, a J at "M18N" or an M at "M18S".
    func departs(_ train: Arrival, for selection: Selection) -> Bool {
        let way = departureDirection(for: selection)
        return routes.contains(train.route) && departurePlatforms.contains { platform in
            train.stop == platform.id + platform.direction(way, of: train.route, with: routes).rawValue
        }
    }

    /// Where the lines changed to go: "Manhattan".
    func heading(for selection: Selection) -> String {
        Station.directionLabel(departureDirection(for: selection), on: departurePlatforms, routes: routes)
    }

    /// Whether `route` stops, going this change's way, at every platform the
    /// train does here, on the side it does (`Platform.side(of:going:)`), so
    /// changing to it is across the platform whichever of its lines you're on.
    func isAcross(_ route: String, from selection: Selection) -> Bool {
        let platforms = arrivalPlatforms(for: selection)
        let way = departureDirection(for: selection)
        return !platforms.isEmpty && platforms.allSatisfy { platform in
            platform.routes.contains(route) && Self.isAcross(routes, going: way, at: platform, from: selection)
        }
    }

    /// Whether `selection`'s train stops at `platform` on the side the lines of
    /// `routes` there do going `direction` together (`Platform.direction(_:of:with:)`),
    /// each of its own lines going its own way: across the platform from them.
    /// Not where it or none of them stop. An M toward Manhattan is across from
    /// a J toward Broad St at Delancey St-Essex St, though one is N and the other S.
    static func isAcross(_ routes: [String], going direction: Direction, at platform: Platform,
                         from selection: Selection) -> Bool {
        let theirs = routes.filter(platform.routes.contains)
        let yours = selection.routes.filter(platform.routes.contains)
        let sides = Set(theirs.map { platform.side(of: $0, going: platform.direction(direction, of: $0, with: routes)) }
                        + yours.map { platform.side(of: $0, going: selection.direction(of: $0)) })
        return !theirs.isEmpty && !yours.isEmpty && sides.count == 1
    }

    /// Whether every line changed to is across the platform.
    func isAllAcross(from selection: Selection) -> Bool {
        routes.allSatisfy { isAcross($0, from: selection) }
    }

    /// Whether the lines changed to are an express for `selection`'s train:
    /// across the platform, and none of them stopping at its station.
    func isExpress(for selection: Selection) -> Bool {
        let stopping = selection.station?.routes ?? []
        return isAllAcross(from: selection) && !routes.contains(where: stopping.contains)
    }

    /// Whether `departure`, a train changed to, stops across the platform from
    /// `arrival`, your train here: on the same side of the same platform
    /// (`Platform.side(of:going:)`), which is under the other N or S where one
    /// line runs the other way to the other there, as an M going N and a J
    /// going S do at Delancey St-Essex St.
    func isAcross(from arrival: Arrival, to departure: Arrival) -> Bool {
        let id = String(departure.stop.dropLast())
        guard String(arrival.stop.dropLast()) == id, let platform = departurePlatforms.first(where: { $0.id == id }),
              let arriving = Direction(ofStop: arrival.stop), let leaving = Direction(ofStop: departure.stop) else {
            return arrival.stop == departure.stop
        }
        return platform.side(of: arrival.route, going: arriving) == platform.side(of: departure.route, going: leaving)
    }

    /// How long it takes to get from `arrival`, your train here, to `departure`,
    /// a train changed to: nothing across the platform.
    func walk(from arrival: Arrival, to departure: Arrival) -> TimeInterval {
        isAcross(from: arrival, to: departure) ? 0 : TimeInterval(walkMinutes * 60)
    }

    /// Lines no longer at the station, or that end their run there going this
    /// change's way, are dropped, as are `selection`'s own; nil when none are
    /// left, or the station is gone, is `selection`'s, or is behind it (by
    /// `order`, as for `isAhead(of:order:)`). One saved before there was a
    /// way, to lines that leave from there only the other way from your
    /// train's, as the G does at Court Sq for a Flushing-bound 7, goes that way.
    func validated(for selection: Selection,
                   order: (String) -> [String]? = StationDirectory.stops(onLine:)) -> Change? {
        guard let station, station.id != selection.station?.id, isAhead(of: selection, order: order) else { return nil }
        var change = self
        change.stationID = station.id
        let kept = Self.lines(at: station).filter { routes.contains($0) && !selection.routes.contains($0) }
        let leaving = { (direction: Direction) in
            kept.filter { Self.leaves($0, from: station, going: direction, with: kept) }
        }
        change.routes = leaving(departureDirection(for: selection))
        if direction == nil, change.routes.isEmpty {
            change.routes = leaving(selection.direction.opposite)
            change.direction = selection.direction.opposite
        }
        return change.routes.isEmpty ? nil : change
    }

    /// Whether `selection`'s train gets here after its own station, by the order
    /// its lines stop in: `order` has each line's stops from its northern end
    /// south, by bullet label (lines.json's). Where that isn't known, as for a
    /// train rerouted off its line, it's taken to. A trip's N or S is the same
    /// at every stop, so a train going S runs down the list all the way, each
    /// line by its own (`Selection.direction(of:)`): an M toward Middle Village
    /// is S at Marcy Av too, though the MTA names the ways there for the J,
    /// whose S there goes the other way.
    func isAhead(of selection: Selection, order: (String) -> [String]? = StationDirectory.stops(onLine:)) -> Bool {
        guard let station, let origin = selection.station else { return true }
        var known = false
        for route in selection.routes {
            guard let stops = order(LineStyle.of(route).label) else { continue }
            let position = Dictionary(stops.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            // A station comes where the first of the train's platforms there does
            let place = { (station: Station) in
                station.platforms(serving: selection.routes).compactMap { position[$0.id] }.min()
            }
            guard let here = place(station), let start = place(origin) else { continue }
            if selection.direction(of: route) == .north ? here < start : here > start { return true }
            known = true
        }
        return !known
    }

    /// The way the lines changed to go to start with, from `selection`'s train,
    /// of those any of them leave by: the one named like where the train goes
    /// on to from here (the J's S, "Manhattan", for the L's N at Broadway
    /// Junction); else the one whose other way is named like where it came
    /// from; else the train's own.
    func suggestedDirection(for selection: Selection) -> Direction {
        guard let station else { return selection.direction }
        let ways = [selection.direction, selection.direction.opposite].filter { way in
            routes.contains { Self.leaves($0, from: station, going: way, with: routes) }
        }
        guard ways.count > 1 else { return ways.first ?? selection.direction }
        let arriving = arrivalPlatforms(for: selection)
        let onward = Self.places(of: selection, on: arriving)
        let back = Self.places(of: selection, on: arriving, back: true)
        let platforms = departurePlatforms
        let named = { (way: Direction) in Self.places(way, on: platforms, for: routes) }
        return ways.first { !named($0).isDisjoint(with: onward) }
            ?? ways.first { !named($0.opposite).isDisjoint(with: back) }
            ?? selection.direction
    }

    /// Whether each platform of the lines changed to names their way like
    /// where `selection`'s train goes on to from here, so it's plainly the way
    /// to go, as from the R to the D at Atlantic Av, both toward Manhattan.
    func goesYourWay(from selection: Selection) -> Bool {
        let onward = Self.places(of: selection, on: arrivalPlatforms(for: selection))
        let names = Station.directionNames(departureDirection(for: selection), on: departurePlatforms, routes: routes)
        return !names.isEmpty && names.allSatisfy { !Self.places([$0], for: routes).isDisjoint(with: onward) }
    }

    /// The places the MTA's names for where the lines of `routes` go in
    /// `direction` from `platforms` list for them (`places(_:for:)`).
    private static func places(_ direction: Direction, on platforms: [Platform], for routes: [String]) -> Set<String> {
        places(Station.directionNames(direction, on: platforms, routes: routes), for: routes)
    }

    /// The places the MTA's names for where `selection`'s train goes on to
    /// from `platforms`, or with `back` where it comes from, list for its
    /// lines: each line's name for its own way (`Selection.direction(of:)`).
    private static func places(of selection: Selection, on platforms: [Platform], back: Bool = false) -> Set<String> {
        let names = platforms.flatMap { platform in
            selection.routes.filter(platform.routes.contains).map { route in
                let way = selection.direction(of: route)
                return platform.directionName(back ? way.opposite : way, of: route)
            }
        }
        return places(names, for: selection.routes)
    }

    /// The places directions' names list for the lines of `routes`: "Uptown &
    /// The Bronx" is Uptown and The Bronx; "Broad St (JZ) - Uptown (M)" is
    /// Broad St for the J and Z, and Uptown for the M.
    private static func places(_ names: [String], for routes: [String]) -> Set<String> {
        let labels = routes.map { LineStyle.of($0).label }
        let places = names.flatMap { name in
            name.replacingOccurrences(of: " & ", with: " - ").components(separatedBy: " - ").compactMap { part -> String? in
                let pieces = part.components(separatedBy: "(")
                // A place named for some lines only is just theirs
                if pieces.count > 1 && !labels.contains(where: { pieces[1].contains($0) }) { return nil }
                return pieces[0].trimmingCharacters(in: .whitespaces)
            }
        }
        return Set(places.filter { !$0.isEmpty })
    }

    /// Every line at `station` and the stations joined to it, each once: the
    /// station's own, then the others'.
    static func lines(at station: Station) -> [String] {
        var lines: [String] = []
        for route in StationDirectory.stations(inComplexOf: station).flatMap(\.routes) where !lines.contains(route) {
            lines.append(route)
        }
        return lines
    }

    /// The lines you can change to at `station` from `selection`'s train: those
    /// across the platform from it, going the way that is, and the rest, on
    /// other platforms or at a station joined to it. Lines that leave from
    /// there neither way are left out.
    static func lines(at station: Station, from selection: Selection) -> (across: [String], others: [String]) {
        let all = Self.lines(at: station).filter { route in
            !selection.routes.contains(route) && Direction.allCases.contains { leaves(route, from: station, going: $0) }
        }
        let platforms = station.platforms(serving: selection.routes)
        let across = all.filter { route in
            !platforms.isEmpty && Direction.allCases.contains { way in
                leaves(route, from: station, going: way)
                    && platforms.allSatisfy { $0.routes.contains(route) && isAcross([route], going: way, at: $0, from: selection) }
            }
        }
        return (across, all.filter { !across.contains($0) })
    }

    /// Whether trains of `route` leave `station`, or a station joined to it,
    /// going `direction` with the lines of `routes` (`Platform.direction(_:of:with:)`),
    /// rather than end their run there (by day).
    static func leaves(_ route: String, from station: Station, going direction: Direction, with routes: [String] = []) -> Bool {
        StationDirectory.stations(inComplexOf: station).contains { stop in
            let way = stop.direction(direction, of: route, with: routes)
            return stop.routes.contains(route) && !stop.directionName(way, of: route).isEmpty
                && !StationDirectory.line(route, endsAt: stop, going: way)
        }
    }

    /// What its trains depend on, to keep them apart from another change's.
    var key: String {
        "\(stationID) \(routes.joined(separator: ",")) \(walkMinutes)" + (direction.map { " \($0.rawValue)" } ?? "")
    }

    /// `trains` (yours, at your station, soonest first) that get here, each with
    /// the first of `departures` (the lines changed to, here, soonest first) it
    /// can catch before it leaves, or itself where it goes on as one of them.
    /// `atChange` has the trips' arrivals here.
    func connections(for trains: [Arrival], atChange: [Arrival], departures: [Arrival],
                     selection: Selection) -> [Connection] {
        var byTrip: [String: Arrival] = [:]
        for arrival in atChange where !arrival.trip.isEmpty && byTrip[arrival.trip] == nil {
            byTrip[arrival.trip] = arrival
        }
        return trains.compactMap { train in
            guard !train.trip.isEmpty, let arrival = byTrip[train.trip], arrival.time >= train.time else { return nil }
            // An N running local on the R goes on from the change as an N: you stay on it
            if departs(arrival, for: selection) && !arrival.endsHere {
                return Connection(first: train, arrival: arrival, next: arrival)
            }
            let next = departures.first { departure in
                departure.trip != train.trip
                    && departure.leaves >= arrival.time.addingTimeInterval(walk(from: arrival, to: departure))
            }
            return Connection(first: train, arrival: arrival, next: next,
                              walk: next.map { walk(from: arrival, to: $0) } ?? 0)
        }
    }
}

/// One of a widget's trains with a change: the train at your station, the same
/// train at the change, and the first train there it can catch.
struct Connection: Codable, Hashable, Sendable {
    /// At your station.
    var first: Arrival
    /// The same trip at the change, with its stops on the way there.
    var arrival: Arrival
    /// The train it can change to, or the same trip where it goes on as one of
    /// the lines changed to; nil when the feeds have none yet.
    var next: Arrival?
    /// Seconds to walk from your train to `next`: none across the platform.
    var walk: TimeInterval = 0

    private enum CodingKeys: String, CodingKey {
        case first, arrival, next, walk
    }

    /// Whether your train goes on from the change as one of the lines changed
    /// to, so you stay on it.
    var staysOn: Bool { next.map { !$0.trip.isEmpty && $0.trip == first.trip } ?? false }

    /// From getting to the change to the next train getting there, any walk
    /// included; just the walk when it's there already, held at the platform.
    var wait: TimeInterval? { next.map { max(walk, $0.time.timeIntervalSince(arrival.time)) } }

    /// The wait in whole minutes, to the nearest.
    var waitMinutes: Int? { wait.map { Int(($0 / 60).rounded()) } }

    /// "1 min", "<1 min", "stay on", or "–" with no train to change to.
    var waitLabel: String {
        if staysOn { return "stay on" }
        guard let minutes = waitMinutes else { return "–" }
        return minutes < 1 ? "<1 min" : "\(minutes) min"
    }

    /// Whether the wait is short enough for the widget to highlight.
    func isQuick(within minutes: Int) -> Bool {
        guard let waitMinutes else { return false }
        return waitMinutes <= minutes
    }
}

extension Connection {
    /// Any property added later needs a default here, so connections saved
    /// before it still load. Here, not in the type, so it keeps its memberwise init.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(first: try container.decode(Arrival.self, forKey: .first),
                  arrival: try container.decode(Arrival.self, forKey: .arrival),
                  next: try container.decodeIfPresent(Arrival.self, forKey: .next),
                  walk: try container.decodeIfPresent(TimeInterval.self, forKey: .walk) ?? 0)
    }
}
