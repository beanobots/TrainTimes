import Foundation

/// A transfer on a saved widget's trip: a station ahead, and the lines to change to there (or at a
/// station joined by passageway) going one way. The Transfers widget pairs each train with the
/// first connection it can catch.
struct Change: Codable, Hashable, Sendable {
    /// A `Station.id`: where you leave your train.
    var stationID: String
    /// Real-time route ids of the lines to change to, in the order of `lines(at:)`.
    var routes: [String]
    /// Which way they go; nil (older saves) means your train's way. N/S are per line, so the L's
    /// N at Broadway Junction (toward Manhattan) is the J's S. Lines running opposite ways on one
    /// platform go together as in `Selection.direction`.
    var direction: Direction?
    /// The longest wait, in minutes, once counted as a quick change for a widget to highlight.
    /// No widget highlights it now; kept so saves keep their choice.
    var quickMinutes: Int
    /// Minutes to walk to a line on a different platform.
    var walkMinutes: Int
    /// From older saves: whether to change a stop sooner or later where lines are across the
    /// platform there but a walk here. `validated(for:)` writes those stations out as
    /// `alternatives` and turns it off.
    var smartTransfer: Bool
    /// Other stations to change at instead, each with its lines: the widget pairs each train with
    /// whichever change gets it on soonest (`smartChanges(for:)`). They share this change's walk
    /// and destination.
    var alternatives: [Stop]
    /// A `Station.id` further on that the large widget times each way to (`Way`); nil to time
    /// each line changed to at the change.
    var destinationID: String?

    /// A station of `alternatives`, and the lines to change to there going `direction` (nil for
    /// your train's way), as in `Change`'s own.
    struct Stop: Codable, Hashable, Sendable {
        var stationID: String
        var routes: [String]
        var direction: Direction?
    }

    static let defaultQuickMinutes = 2
    static let defaultWalkMinutes = 3

    init(stationID: String, routes: [String], direction: Direction? = nil,
         quickMinutes: Int = Change.defaultQuickMinutes, walkMinutes: Int = Change.defaultWalkMinutes,
         smartTransfer: Bool = false, destinationID: String? = nil, alternatives: [Stop] = []) {
        self.stationID = stationID
        self.routes = routes
        self.direction = direction
        self.quickMinutes = quickMinutes
        self.walkMinutes = walkMinutes
        self.smartTransfer = smartTransfer
        self.destinationID = destinationID
        self.alternatives = alternatives
    }

    /// This change at each of `stops`, the first as its own station and the rest as
    /// `alternatives`; nil with none.
    init?(stops: [Change]) {
        guard var first = stops.first else { return nil }
        first.smartTransfer = false
        first.alternatives = stops.dropFirst().map { Stop(stationID: $0.stationID, routes: $0.routes, direction: $0.direction) }
        self = first
    }

    private enum CodingKeys: String, CodingKey {
        case stationID, routes, direction, quickMinutes, walkMinutes, smartTransfer, destinationID, alternatives
    }

    /// Older saves missing `direction`, `quickMinutes`, `walkMinutes`, `smartTransfer`,
    /// `destinationID` or `alternatives` still load with defaults. Any property added later needs
    /// a default here too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(stationID: try container.decode(String.self, forKey: .stationID),
                  routes: try container.decode([String].self, forKey: .routes),
                  direction: try container.decodeIfPresent(Direction.self, forKey: .direction),
                  quickMinutes: try container.decodeIfPresent(Int.self, forKey: .quickMinutes) ?? Change.defaultQuickMinutes,
                  walkMinutes: try container.decodeIfPresent(Int.self, forKey: .walkMinutes) ?? Change.defaultWalkMinutes,
                  smartTransfer: try container.decodeIfPresent(Bool.self, forKey: .smartTransfer) ?? false,
                  destinationID: try container.decodeIfPresent(String.self, forKey: .destinationID),
                  alternatives: try container.decodeIfPresent([Stop].self, forKey: .alternatives) ?? [])
    }

    /// As the synthesized encoding, leaving out `alternatives` when there are none so a change at
    /// one station saves as before.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stationID, forKey: .stationID)
        try container.encode(routes, forKey: .routes)
        try container.encodeIfPresent(direction, forKey: .direction)
        try container.encode(quickMinutes, forKey: .quickMinutes)
        try container.encode(walkMinutes, forKey: .walkMinutes)
        try container.encode(smartTransfer, forKey: .smartTransfer)
        try container.encodeIfPresent(destinationID, forKey: .destinationID)
        if !alternatives.isEmpty {
            try container.encode(alternatives, forKey: .alternatives)
        }
    }

    /// This change's station then each of `alternatives`, as changes of their own (with the same
    /// walk and destination, and no alternatives).
    var stops: [Change] {
        var main = self
        main.smartTransfer = false
        main.alternatives = []
        return [main] + alternatives.map { stop in
            var change = main
            change.stationID = stop.stationID
            change.routes = stop.routes
            change.direction = stop.direction
            return change
        }
    }

    /// Every line changed to at any of `stops`, each once.
    var allRoutes: [String] {
        var routes: [String] = []
        for route in stops.flatMap(\.routes) where !routes.contains(route) {
            routes.append(route)
        }
        return routes
    }

    var station: Station? { StationDirectory.station(id: stationID) }

    var destination: Station? { destinationID.flatMap(StationDirectory.station(id:)) }

    /// Feed stop ids at the destination and stations joined to it, both ways, e.g. "D17N".
    var destinationStops: Set<String> {
        destination.map(StationDirectory.stops(inComplexOf:)) ?? []
    }

    /// Whether `route` stops at the destination or a station joined to it.
    func reachesDestination(_ route: String) -> Bool {
        guard let destination else { return false }
        return StationDirectory.stations(inComplexOf: destination).contains { $0.routes.contains(route) }
    }

    /// The changes the widget pairs trains with, each with `lines`, those of your train's lines it's
    /// for. With `alternatives`, each of `stops` is for the lines that call there (a line calling
    /// at none uses the first): from an R toward Manhattan with the D or N at Atlantic Av-Barclays
    /// Ctr or the Q at DeKalb Av, both. An older save's `smartTransfer` is worked out as it was
    /// (`legacySmartChanges(for:)`). Otherwise just this one, for all of them.
    func smartChanges(for selection: Selection) -> [(change: Change, lines: [String])] {
        guard !alternatives.isEmpty else {
            return smartTransfer ? legacySmartChanges(for: selection) : [(self, selection.routes)]
        }
        let stops = self.stops
        var parts: [(change: Change, lines: [String])] = []
        for route in selection.routes {
            let calling = stops.filter { $0.station?.platforms(serving: [route]).isEmpty == false }
            for change in calling.isEmpty ? [stops[0]] : calling {
                if let index = parts.firstIndex(where: { $0.change == change }) {
                    parts[index].lines.append(route)
                } else {
                    parts.append((change, [route]))
                }
            }
        }
        return parts
    }

    /// An older save's `smartTransfer`, worked out for each of your lines
    /// (`smartChanges(onLine:)`) and the same changes joined: from a D, N or Q toward Coney Island
    /// changing to the R at Atlantic Av-Barclays Ctr, the D and N there (across the platform
    /// already) and the Q at DeKalb Av.
    private func legacySmartChanges(for selection: Selection) -> [(change: Change, lines: [String])] {
        var parts: [(change: Change, lines: [String])] = []
        for route in selection.routes {
            for change in smartChanges(onLine: selection.only([route])) {
                if let index = parts.firstIndex(where: { $0.change == change }) {
                    parts[index].lines.append(route)
                } else {
                    parts.append((change, [route]))
                }
            }
        }
        return parts.isEmpty ? [(self, selection.routes)] : parts
    }

    /// `smartChanges(for:)` for a train whose lines all make the same stops, in the order it
    /// reaches them: lines that are a walk here but across the platform at the stop before or
    /// after change there (`acrossNearby(for:)`), and the rest here. From an R toward Manhattan,
    /// D and N at Atlantic Av-Barclays Ctr then Q at DeKalb Av; from a Q toward Coney Island, the
    /// R at DeKalb Av rather than Atlantic Av-Barclays Ctr.
    private func smartChanges(onLine selection: Selection) -> [Change] {
        let nearby = acrossNearby(for: selection)
        let moved = [nearby.before, nearby.after].compactMap { $0 }
        guard !moved.isEmpty else { return [self] }
        var here = self
        here.routes = routes.filter { route in !moved.contains { $0.routes.contains(route) } }
        return [nearby.before, here.routes.isEmpty ? nil : here, nearby.after].compactMap { $0 }
    }

    /// Changes worth adding to `stops`: at your train's stop before or after each, lines across
    /// the platform there going the same way, that get to the destination (without one, that
    /// are a walk at that change), not already across the platform at a change for that line,
    /// nor chosen there. One per station, in the order of `stops`. From an R toward Manhattan
    /// changing to the D or N at Atlantic Av-Barclays Ctr, going to 34 St-Herald Sq, the B or Q
    /// at DeKalb Av.
    func suggestions(for selection: Selection) -> [ChangeSuggestion] {
        let stops = self.stops
        var found: [ChangeSuggestion] = []
        for route in selection.routes {
            let line = selection.only([route])
            let calling = stops.filter { $0.station?.platforms(serving: [route]).isEmpty == false }
            let across = calling.flatMap { stop in stop.routes.filter { stop.isAcross($0, from: line) } }
            for stop in calling {
                guard let station = stop.station else { continue }
                for onward in [false, true] {
                    guard let near = Self.stop(besides: station, for: line, onward: onward) else { continue }
                    let chosen = stops.filter { $0.stationID == near.id }.flatMap(\.routes)
                    var candidate = stop
                    candidate.stationID = near.id
                    candidate.routes = Self.lines(at: near).filter { route in
                        !chosen.contains(route) && !across.contains(route)
                            && (destination == nil ? !stop.isAcross(route, from: line) && stop.routes.contains(route)
                                                   : reachesDestination(route))
                    }
                    guard !candidate.routes.isEmpty, var there = candidate.validatedStop(for: line),
                          there.direction == stop.direction else { continue }
                    there.routes = there.routes.filter { there.isAcross($0, from: line) }
                    guard !there.routes.isEmpty else { continue }
                    if let index = found.firstIndex(where: { $0.change.stationID == there.stationID }) {
                        found[index].change.routes += there.routes.filter { !found[index].change.routes.contains($0) }
                    } else {
                        found.append(ChangeSuggestion(change: there, besides: stop, sooner: !onward))
                    }
                }
            }
        }
        return found
    }

    /// Whether the change is at more than one station, so each connection says where.
    func changesAtSeveral(for selection: Selection) -> Bool {
        Set(smartChanges(for: selection).map(\.change.stationID)).count > 1
    }

    /// This change at the station `connection` changes at (`Connection.stationID`).
    func at(_ connection: Connection) -> Change {
        var change = self
        change.stationID = connection.stationID ?? stationID
        return change
    }

    /// Where `smartChanges(for:)` change: "Atlantic Av / DeKalb Av", or one station's full name.
    func stationNames(for selection: Selection) -> String {
        var stations: [String] = []
        for name in smartChanges(for: selection).compactMap(\.change.station?.name) where !stations.contains(name) {
            stations.append(name)
        }
        return stations.count > 1 ? stations.map(\.mainStationName).joined(separator: " / ") : stations.first ?? ""
    }

    /// This change at your train's stop before and after this station, each with just the lines
    /// that are a walk here but across the platform there (the stop before first), running from
    /// the first station of the two to the second as your train does. For an R toward Manhattan
    /// changing to D, N or Q at Atlantic Av-Barclays Ctr, the Q at DeKalb Av after; for a Q toward
    /// Coney Island changing to the R there, the R at DeKalb Av before. The stop before must be
    /// after your station. Nil where there are none, or where lines.json doesn't know the stops.
    func acrossNearby(for selection: Selection) -> (before: Change?, after: Change?) {
        guard let here = validatedStop(for: selection), let station = here.station else { return (nil, nil) }
        var walking = here.routes.filter { !here.isAcross($0, from: selection) }
        // The change at `stop` for the walked-to lines running from `first` to `second`
        func across(at stop: Station?, from first: (Station) -> Station, to second: (Station) -> Station) -> Change? {
            guard let stop, !walking.isEmpty else { return nil }
            let moving = walking.filter { route in
                let platforms = { (station: Station) in
                    Set(StationDirectory.stations(inComplexOf: station).flatMap { $0.platforms(serving: [route]) }.map(\.id))
                }
                return StationDirectory.direction(of: route, from: platforms(first(stop)), to: platforms(second(stop)))
                    == here.departureDirection(of: route, for: selection)
            }
            var candidate = here
            candidate.stationID = stop.id
            candidate.routes = moving
            guard !moving.isEmpty, var there = candidate.validatedStop(for: selection),
                  there.direction == here.direction else { return nil }
            there.routes = there.routes.filter { there.isAcross($0, from: selection) }
            walking.removeAll(where: there.routes.contains)
            return there.routes.isEmpty ? nil : there
        }
        // Sooner first: there, then here
        let before = across(at: Self.stop(besides: station, for: selection, onward: false),
                            from: { $0 }, to: { _ in station })
        let after = across(at: Self.stop(besides: station, for: selection, onward: true),
                           from: { _ in station }, to: { $0 })
        return (before, after)
    }

    /// Your train's stop after `station` (`onward`) or before it, along its lines' own stops
    /// (`StationDirectory.nextStop(of:from:going:)`); nil at the end of the line, if unknown,
    /// where its branches part, or if its lines have different stops there.
    private static func stop(besides station: Station, for selection: Selection, onward: Bool) -> Station? {
        let stops = selection.routes.map { route -> String? in
            let way = selection.direction(of: route)
            return StationDirectory.nextStop(of: route, from: Set(station.platforms(serving: [route]).map(\.id)),
                                             going: onward ? way : way.opposite)
        }
        guard let id = stops.first ?? nil, stops.allSatisfy({ $0 == id }) else { return nil }
        return StationDirectory.station(id: id)
    }

    /// Which way the lines changed to go from `selection`'s train.
    func departureDirection(for selection: Selection) -> Direction {
        direction ?? selection.direction
    }

    /// The feed's N or S for `route`: `departureDirection(for:)`, flipped where the line runs
    /// opposite to another changed-to line on its platform (`Platform.direction(_:of:with:)`).
    func departureDirection(of route: String, for selection: Selection) -> Direction {
        let way = departureDirection(for: selection)
        return departurePlatforms.first { $0.routes.contains(route) }?.direction(way, of: route, with: routes) ?? way
    }

    /// The station's platforms that `selection`'s train stops at.
    private func arrivalPlatforms(for selection: Selection) -> [Platform] {
        station?.platforms(serving: selection.routes) ?? []
    }

    /// Feed stop ids where `selection`'s train calls here, e.g. "R31N". Each line uses its own N/S
    /// (`Selection.direction(of:)`): from Marcy Av toward Manhattan, J "M18S" and M "M18N".
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

    /// The lines changed to as trains to catch here, going their way: one selection per station
    /// of the complex they leave from, for matching their alerts as your own train's are.
    func departureSelections(for selection: Selection) -> [Selection] {
        guard let station else { return [] }
        let way = departureDirection(for: selection)
        return StationDirectory.stations(inComplexOf: station).compactMap { station in
            let lines = station.routes.filter(routes.contains)
            return lines.isEmpty ? nil : Selection(stationID: station.id, routes: lines, direction: way)
        }
    }

    /// `departureSelections(for:)` at each of `smartChanges(for:)`'s stations: the trains whose
    /// alerts a transfer's widget and countdown mention along with your own train's.
    func alertSelections(for selection: Selection) -> [Selection] {
        smartChanges(for: selection).flatMap { $0.change.departureSelections(for: selection.only($0.lines)) }
    }

    /// Feed stop ids of the changed-to lines here, going their way, e.g. "R31N".
    func departureStops(for selection: Selection) -> [String] {
        let direction = departureDirection(for: selection)
        return departurePlatforms.flatMap { $0.stops(of: routes, going: direction) }
    }

    /// Whether `train` here is a changed-to line going their way, each by its own N/S
    /// (`departureDirection(of:for:)`).
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

    /// Whether `route`, going this change's way, stops on the same side of every platform the
    /// train uses here (`Platform.side(of:going:)`): a cross-platform change on any of its lines.
    func isAcross(_ route: String, from selection: Selection) -> Bool {
        let platforms = arrivalPlatforms(for: selection)
        let way = departureDirection(for: selection)
        return !platforms.isEmpty && platforms.allSatisfy { platform in
            platform.routes.contains(route) && Self.isAcross(routes, going: way, at: platform, from: selection)
        }
    }

    /// Whether `selection`'s train and `routes` (going `direction`, per
    /// `Platform.direction(_:of:with:)`) all stop on the same side of `platform`. False if either
    /// doesn't stop there. N/S may differ: an M toward Manhattan is across from a J toward Broad St
    /// at Delancey St-Essex St.
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

    /// Whether the changed-to lines are an express for `selection`: all across the platform, and
    /// none stopping at its station.
    func isExpress(for selection: Selection) -> Bool {
        let stopping = selection.station?.routes ?? []
        return isAllAcross(from: selection) && !routes.contains(where: stopping.contains)
    }

    /// Whether `departure` stops on the same side of the same platform as `arrival`
    /// (`Platform.side(of:going:)`). Their N/S can differ where lines run opposite ways, as an M
    /// going N and a J going S at Delancey St-Essex St.
    func isAcross(from arrival: Arrival, to departure: Arrival) -> Bool {
        Self.isAcross(off: arrival.route, at: arrival.stop, on: departure.route, at: departure.stop)
    }

    /// Whether off `route` at feed stop `stop` and on `onward` at `board` is across the platform:
    /// the same platform, on the same side of it (`Platform.side(of:going:)`), though N/S may
    /// differ. A stop that isn't known counts only if it's the same stop.
    static func isAcross(off route: String, at stop: String, on onward: String, at board: String) -> Bool {
        guard stop.dropLast() == board.dropLast(), let platform = StationDirectory.platform(forStop: board),
              let arriving = Direction(ofStop: stop), let leaving = Direction(ofStop: board) else {
            return stop == board
        }
        return platform.side(of: route, going: arriving) == platform.side(of: onward, going: leaving)
    }

    /// Walk time from `arrival` to `departure`; zero across the platform.
    func walk(from arrival: Arrival, to departure: Arrival) -> TimeInterval {
        isAcross(from: arrival, to: departure) ? 0 : TimeInterval(walkMinutes * 60)
    }

    /// `validatedStop(for:order:)` at each of `stops`, dropping those that aren't valid; nil if
    /// none are. An older save's `smartTransfer` has its stations written out as `alternatives`.
    func validated(for selection: Selection,
                   order: (String) -> [String]? = StationDirectory.stops(onLine:)) -> Change? {
        let stops = smartTransfer && alternatives.isEmpty
            ? legacySmartChanges(for: selection).map(\.change).map { change in
                var change = change
                change.smartTransfer = false
                return change
            }
            : self.stops
        // One stop per station, its lines joined
        var kept: [Change] = []
        for stop in stops.compactMap({ $0.validatedStop(for: selection, order: order) }) {
            if let index = kept.firstIndex(where: { $0.stationID == stop.stationID && $0.direction == stop.direction }) {
                kept[index].routes += stop.routes.filter { !kept[index].routes.contains($0) }
            } else {
                kept.append(stop)
            }
        }
        return Change(stops: kept)
    }

    /// This change's own station, ignoring `alternatives`: drops lines no longer at the station,
    /// ending their run there this way, or `selection`'s own. Nil if none are left, or the station
    /// is gone, is `selection`'s, or is behind it (`isAhead(of:order:)`). A change with no saved
    /// `direction` whose lines only leave the other way (the G at Court Sq for a Flushing-bound 7)
    /// is switched to that way.
    private func validatedStop(for selection: Selection,
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

    /// Whether `selection`'s train reaches here after its own station. `order` gives each line's
    /// stops north to south, keyed by bullet label (from lines.json). Unknown order (e.g. a
    /// rerouted train) counts as ahead. A trip's N/S is constant, so each line is checked by its
    /// own direction (`Selection.direction(of:)`): an M toward Middle Village is S at Marcy Av
    /// even though the J's S there goes the other way.
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

    /// The default way to change, among those the lines leave by: the one named like where the
    /// train continues (the J's S, "Manhattan", for the L's N at Broadway Junction); else the one
    /// whose opposite is named like where it came from; else the train's own.
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

    /// Whether every changed-to platform names its way like where `selection`'s train continues,
    /// so the way is obvious (R to D at Atlantic Av, both toward Manhattan).
    func goesYourWay(from selection: Selection) -> Bool {
        let onward = Self.places(of: selection, on: arrivalPlatforms(for: selection))
        let names = Station.directionNames(departureDirection(for: selection), on: departurePlatforms, routes: routes,
                                           whole: true)
        return !names.isEmpty && names.allSatisfy { !Self.places([$0], for: routes).isDisjoint(with: onward) }
    }

    /// Places named in the MTA's direction labels for `routes` going `direction` on `platforms`,
    /// kept whole so lines sharing a platform side share its places.
    private static func places(_ direction: Direction, on platforms: [Platform], for routes: [String]) -> Set<String> {
        places(Station.directionNames(direction, on: platforms, routes: routes, whole: true), for: routes)
    }

    /// Places named in the direction labels for where `selection`'s train goes from `platforms`
    /// (or, with `back`, comes from), each line by its own way (`Selection.direction(of:)`).
    private static func places(of selection: Selection, on platforms: [Platform], back: Bool = false) -> Set<String> {
        let names = platforms.flatMap { platform in
            selection.routes.filter(platform.routes.contains).map { route in
                let way = selection.direction(of: route)
                return platform.directionName(back ? way.opposite : way, of: route, whole: true)
            }
        }
        return places(names, for: selection.routes)
    }

    /// Places in direction labels that apply to `routes`: "Uptown & The Bronx" is Uptown and
    /// The Bronx; "Broad St (JZ) - Uptown (M)" is Broad St for J/Z, Uptown for M.
    private static func places(_ names: [String], for routes: [String]) -> Set<String> {
        let labels = routes.map { LineStyle.of($0).label }
        let places = names.flatMap { name in
            name.replacingOccurrences(of: " & ", with: " - ").components(separatedBy: " - ").compactMap { part -> String? in
                let pieces = part.components(separatedBy: "(")
                // A place tagged with lines applies only to those lines
                if pieces.count > 1 && !labels.contains(where: { pieces[1].contains($0) }) { return nil }
                return pieces[0].trimmingCharacters(in: .whitespaces)
            }
        }
        return Set(places.filter { !$0.isEmpty })
    }

    /// Every line at `station` and its joined stations, deduplicated, the station's own first.
    static func lines(at station: Station) -> [String] {
        var lines: [String] = []
        for route in StationDirectory.stations(inComplexOf: station).flatMap(\.routes) where !lines.contains(route) {
            lines.append(route)
        }
        return lines
    }

    /// Lines you can change to at `station` from `selection`: those across the platform (in
    /// either way), and the rest. Lines that leave neither way are excluded.
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

    /// Whether `route` leaves `station` (or a joined station) going `direction` with `routes`
    /// (`Platform.direction(_:of:with:)`), rather than ending its run there (by day).
    static func leaves(_ route: String, from station: Station, going direction: Direction, with routes: [String] = []) -> Bool {
        StationDirectory.stations(inComplexOf: station).contains { stop in
            let way = stop.direction(direction, of: route, with: routes)
            return stop.routes.contains(route) && !stop.directionName(way, of: route).isEmpty
                && !StationDirectory.line(route, endsAt: stop, going: way)
        }
    }

    /// Identifies the inputs its trains depend on, to tell changes' trains apart.
    var key: String {
        "\(stationID) \(routes.joined(separator: ",")) \(walkMinutes)" + (direction.map { " \($0.rawValue)" } ?? "")
            + (smartTransfer ? " smart" : "") + (destinationID.map { " to \($0)" } ?? "")
            + alternatives.map { " or \($0.stationID) \($0.routes.joined(separator: ","))" + ($0.direction.map { " \($0.rawValue)" } ?? "") }
                .joined()
    }

    /// Pairs each of `trains` (at your station, soonest first) that reaches here with the first of
    /// `departures` (changed-to lines here, soonest first) it can catch, or itself if it continues
    /// as one of them. `atChange` has the trips' arrivals here.
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
                return Connection(first: train, arrival: arrival, next: arrival, stationID: stationID)
            }
            let next = departures.first { departure in
                departure.trip != train.trip
                    && departure.leaves >= arrival.time.addingTimeInterval(walk(from: arrival, to: departure))
            }
            return Connection(first: train, arrival: arrival, next: next,
                              walk: next.map { walk(from: arrival, to: $0) } ?? 0, stationID: stationID)
        }
    }
}

/// A change worth adding (`Change.suggestions(for:)`): `change`, at your train's stop before
/// (`sooner`) or after the station of `besides`, one of the change's `stops`.
struct ChangeSuggestion: Hashable, Sendable {
    var change: Change
    var besides: Change
    var sooner: Bool
}

/// A widget train with a change: at your station, at the change, and the first connection.
struct Connection: Codable, Hashable, Sendable {
    /// At your station.
    var first: Arrival
    /// The same trip at the change, with its stops on the way there.
    var arrival: Arrival
    /// The connection, or the same trip if it continues as a changed-to line; nil if none yet.
    var next: Arrival?
    /// Seconds to walk from your train to `next`: none across the platform.
    var walk: TimeInterval = 0
    /// The `Station.id` of the change, which may be one of its alternatives
    /// (`Change.smartChanges(for:)`); nil for the change's own station.
    var stationID: String? = nil
    /// Every way on from `first`, soonest there first (`TrainService.ways`); nil in older saves.
    var ways: [Way]? = nil

    private enum CodingKeys: String, CodingKey {
        case first, arrival, next, walk, stationID, ways
    }

    /// For each of `trains` with a connection in any of `options` (one list per change station,
    /// as from `Change.connections`), the best: staying on, else the train met that's soonest at
    /// the change as saved (`passing`, by trip; else its time where it's met), the shorter walk
    /// on a tie. Going by one station keeps a stop sooner from always looking soonest. In
    /// `trains`' order.
    static func best(of options: [[Connection]], for trains: [Arrival], passing: [String: Date] = [:]) -> [Connection] {
        guard options.count > 1 else { return options.first ?? [] }
        let all = options.joined()
        let rank = { (connection: Connection) -> (Int, Date, TimeInterval) in
            let next = connection.next
            return (connection.staysOn ? 0 : next == nil ? 2 : 1,
                    next.map { passing[$0.trip] ?? $0.time } ?? .distantFuture, connection.walk)
        }
        return trains.compactMap { train in
            all.filter { $0.first.trip == train.trip }.min { rank($0) < rank($1) }
        }
    }

    /// Whether your train continues as a changed-to line, so you stay on.
    var staysOn: Bool { next.map { !$0.trip.isEmpty && $0.trip == first.trip } ?? false }

    /// Time from reaching the change to `next` arriving, at least the walk (e.g. if `next` is
    /// already held at the platform).
    var wait: TimeInterval? { next.map { max(walk, $0.time.timeIntervalSince(arrival.time)) } }

    /// The wait, rounded to whole minutes.
    var waitMinutes: Int? { wait.map { Int(($0 / 60).rounded()) } }

    /// "1 min", "<1 min", "stay on", or "–" with no train to change to.
    var waitLabel: String {
        if staysOn { return "stay on" }
        guard let minutes = waitMinutes else { return "–" }
        return minutes < 1 ? "<1 min" : "\(minutes) min"
    }
}

extension Connection {
    /// Any property added later needs a default here so older saves still load. Defined in an
    /// extension to keep the memberwise init.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(first: try container.decode(Arrival.self, forKey: .first),
                  arrival: try container.decode(Arrival.self, forKey: .arrival),
                  next: try container.decodeIfPresent(Arrival.self, forKey: .next),
                  walk: try container.decodeIfPresent(TimeInterval.self, forKey: .walk) ?? 0,
                  stationID: try container.decodeIfPresent(String.self, forKey: .stationID),
                  ways: try container.decodeIfPresent([Way].self, forKey: .ways))
    }
}

/// One way on from your train for the large Transfers widget: the first train of a changed-to
/// line you can catch, or staying on your own. Timed to the change's destination, or without
/// one, to when the train changed to gets to the change.
struct Way: Codable, Hashable, Sendable {
    /// The line ridden on: the one changed to, or yours when staying on.
    var route: String
    /// The change, without its own `ways`; nil to stay on your train.
    var connection: Connection?
    /// The train ridden at the destination (without one, the train changed to at the change);
    /// nil if none is predicted yet.
    var arrival: Arrival?

    /// Whether this way is staying on your train, as it is or as it continues as another line.
    var staysOn: Bool { connection?.staysOn ?? true }
}

extension Selection {
    /// This train with just `routes` of its lines, for a change that applies to only some of them
    /// (`Change.smartChanges(for:)`).
    func only(_ routes: [String]) -> Selection {
        var selection = self
        selection.routes = self.routes.filter(routes.contains)
        return selection
    }
}
