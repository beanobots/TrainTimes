import CoreLocation

/// Works out the subway trip for shared directions from where they start and end: the train
/// from a station near the start to one near the end, the way that gets there, with a change
/// if no line goes straight there. Maps links don't say which lines the directions take.
enum TripPlanner {
    /// A train and, if needed, a change, with the stations it was matched to.
    struct Trip: Equatable {
        var selection: Selection
        var change: Change?
        /// The station nearest the directions' end.
        var destination: Station
    }

    /// Meters; stations further from either end aren't considered.
    static let walkRange: Double = 1_200
    /// Meters of walking a change is worth avoiding: a direct train from a station this much
    /// further away comes first.
    private static let changePenalty: Double = 800

    /// The most trips offered.
    static let maxOptions = 4

    /// Trips from `start` to `end` leaving at `now`, to choose from, best first: by when they get
    /// there, with the downloaded timetable (`plan(from:to:at:timetable:)`); without one, by
    /// least walking (`byWalking(from:to:)`).
    static func plan(from start: CLLocation, to end: CLLocation, at now: Date = .now) -> [Trip] {
        if let timetable = TimetableStore.load(now: now) {
            return plan(from: start, to: end, at: now, timetable: timetable)
        }
        return byWalking(from: start, to: end)
    }

    /// Trips from `start` to `end`, best (least walking) first, to choose from: each train once,
    /// and each way to the end once, from the station nearest it. None if either end is too far
    /// from the subway, or walking there is as quick.
    static func byWalking(from start: CLLocation, to end: CLLocation) -> [Trip] {
        let origins = Nearby.stations(near: start, limit: 6).filter { $0.meters <= walkRange }
        let destinations = Nearby.stations(near: end, limit: 6).filter { $0.meters <= walkRange }
        var found: [(trip: Trip, cost: Double)] = []
        for origin in origins {
            for destination in destinations where origin.station.complex != destination.station.complex {
                if let trip = direct(from: origin.station, to: destination.station) {
                    found.append((trip, origin.meters + destination.meters))
                }
            }
        }
        // Changes only from and to the nearest few
        for origin in origins.prefix(3) {
            for destination in destinations.prefix(3) where origin.station.complex != destination.station.complex {
                if let change = changing(from: origin.station, to: destination.station) {
                    found.append((change.trip, origin.meters + destination.meters + changePenalty + change.detour))
                }
            }
        }
        // Not if walking there is no further than to and from the stations
        let straight = start.distance(from: end)
        var trains = Set<String>()
        var ways = Set<String>()
        return found.filter { $0.cost < straight }
            .sorted { $0.cost < $1.cost }
            .map(\.trip)
            .filter { trip in
                let change = trip.change.map { "\($0.stationID) \($0.routes)" } ?? ""
                // The same train to another station, or the same lines there from further away
                let train = "\(trip.selection.trainID) \(change)"
                let way = "\(trip.selection.routes) \(change) \(trip.destination.complex)"
                return trains.insert(train).inserted && ways.insert(way).inserted
            }
            .prefix(maxOptions)
            .map { $0 }
    }

    /// The lines from `origin` (of `lines`, if given) that stop at `destination` (or a station
    /// joined to it), going there; nil if none do.
    static func direct(from origin: Station, lines: [String]? = nil, to destination: Station) -> Trip? {
        selection(from: origin, toward: StationDirectory.stations(inComplexOf: destination), among: lines)
            .map { Trip(selection: $0, destination: destination) }
    }

    /// `origin`'s lines (of `lines`, if given) that stop at one of `stations`, going there, as one
    /// train: those going the same way as `preferred` if it's one, else the first. Nil if none do.
    private static func selection(from origin: Station, toward stations: [Station],
                                  preferring preferred: String? = nil, among lines: [String]? = nil) -> Selection? {
        let ways = origin.routes.filter { lines?.contains($0) ?? true }.compactMap { route in
            direction(of: route, from: origin, to: stations).map { (route, $0) }
        }
        guard let first = ways.first(where: { $0.0 == preferred }) ?? ways.first else { return nil }
        return together(at: origin, ways.map(\.0), going: first.1, else: first.0) { route in
            ways.first { $0.0 == route }?.1
        }
    }

    /// `routes` from `origin` going `direction` as one train, keeping those that go there each
    /// going its own way of `ways` together: lines running opposite ways on a platform go
    /// together (`Selection.direction(of:)`). Just `fallback` if none do.
    static func together(at origin: Station, _ routes: [String], going direction: Direction, else fallback: String,
                         ways: (String) -> Direction?) -> Selection {
        let joint = Selection(stationID: origin.id, routes: routes, direction: direction)
        let kept = routes.filter { joint.direction(of: $0) == ways($0) }
        return Selection(stationID: origin.id, routes: kept.isEmpty ? [fallback] : kept, direction: direction)
    }

    /// The best change from `origin` to `destination`: along one of its lines (of `lines`, if
    /// given) to a station where another goes there. `detour`: meters the trip goes out of its
    /// way, straight line via the change against straight there.
    private static func changing(from origin: Station, to destination: Station,
                                 lines: [String]? = nil) -> (trip: Trip, detour: Double)? {
        let targets = StationDirectory.stations(inComplexOf: destination)
        let straight = distance(origin, destination)
        var best: (trip: Trip, detour: Double)?
        let here = Set(origin.platforms.map(\.id))
        for route in origin.routes where lines?.contains(route) ?? true {
            for direction in Direction.allCases {
                // Along each of its branches that way (`StationDirectory.branches(of:)`)
                for stop in StationDirectory.stops(of: route, from: here, going: direction) {
                    guard let station = StationDirectory.station(id: stop), station.complex != origin.complex else { continue }
                    let detour = distance(origin, station) + distance(station, destination) - straight
                    guard detour < best?.detour ?? .infinity,
                          let trip = trip(from: origin, on: route, among: lines, going: direction, changingAt: station,
                                          to: targets, destination: destination) else { continue }
                    best = (trip, detour)
                }
            }
        }
        return best
    }

    /// From `origin` on `route` (with others of `lines`, if given) going `direction`, changing at
    /// `station` (or one joined to it) to lines there that go to `targets`; nil if none do.
    private static func trip(from origin: Station, on route: String, among lines: [String]?, going direction: Direction,
                             changingAt station: Station, to targets: [Station], destination: Station) -> Trip? {
        // Your lines: those from here that stop at the change, going there
        guard var selection = self.selection(from: origin, toward: [station], preferring: route, among: lines),
              selection.routes.contains(route), selection.direction(of: route) == direction else { return nil }
        // Not lines that go there themselves, which needn't change (the M to Bryant Pk via Herald Sq)
        selection.routes = selection.routes.filter {
            selection.direction(of: $0) == selection.direction(of: route)
                && Self.direction(of: $0, from: origin, to: targets) == nil
        }
        guard !selection.routes.isEmpty else { return nil }
        let joined = StationDirectory.stations(inComplexOf: station)
        // Not to a line you could take from the start (riding the wrong way to meet the M at
        // Hewes St from Marcy Av, where it stops too)
        let here = Set(StationDirectory.stations(inComplexOf: origin).flatMap(\.routes))
        let onward = joined.compactMap { stop in self.selection(from: stop, toward: targets) }
            .map { next in
                var next = next
                next.routes = next.routes.filter { !here.contains($0) }
                return next
            }
            .filter { !$0.routes.isEmpty }
        guard let next = onward.first else { return nil }
        let change = Change(stationID: station.id, routes: next.routes, direction: next.direction,
                            destinationID: destination.id)
        guard let valid = change.validated(for: selection) else { return nil }
        return Trip(selection: selection, change: valid, destination: destination)
    }

    /// Which way `route` goes from `origin` to one of `stations`, by its stops north to south on
    /// one of its branches (`StationDirectory.direction(of:from:to:)`); nil if it doesn't stop at
    /// both, or not on one branch.
    private static func direction(of route: String, from origin: Station, to stations: [Station]) -> Direction? {
        StationDirectory.direction(of: route, from: Set(origin.platforms.map(\.id)),
                                   to: Set(stations.flatMap(\.platforms).map(\.id)))
    }

    private static func distance(_ a: Station, _ b: Station) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lon).distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
    }
}

// MARK: - Changing at several stations

extension TripPlanner {
    /// `trips` (best first) with each train's changes joined, as a widget changes at whichever
    /// station gets you on soonest (`Change.smartChanges(for:)`): a later trip on the same train
    /// to the same end that changes elsewhere, or to other lines, becomes more stations of the
    /// first one's change (`joining(_:into:)`). Then each change also gets your train's stops
    /// either side where a line across the platform goes to the end (`changingNearby(_:)`).
    static func joiningChanges(_ trips: [Trip]) -> [Trip] {
        var joined: [Trip] = []
        for trip in trips {
            if let index = joined.indices.first(where: { joining(trip, into: joined[$0]) != nil }),
               let both = joining(trip, into: joined[index]) {
                joined[index] = both
            } else {
                joined.append(trip)
            }
        }
        return joined.map(changingNearby)
    }

    /// `kept` with `trip`'s change stations added to its own, kept first, if both are the same
    /// train changing on to the same end: from an R toward Manhattan for 34 St-Herald Sq, the D
    /// or N at Atlantic Av-Barclays Ctr and the B or Q at DeKalb Av. Nil otherwise.
    static func joining(_ trip: Trip, into kept: Trip) -> Trip? {
        guard let change = trip.change, let keptChange = kept.change,
              trip.selection.trainID == kept.selection.trainID,
              trip.destination.complex == kept.destination.complex,
              let both = Change(stops: keptChange.stops + change.stops)?.validated(for: kept.selection) else { return nil }
        var joined = kept
        joined.change = both
        return joined
    }

    /// `trip` with its change at your train's stop before or after each station too, where a line
    /// across the platform there goes to the end (`Change.suggestions(for:)`): from an R toward
    /// Manhattan changing to the D or N at Atlantic Av-Barclays Ctr for 34 St-Herald Sq, the Q at
    /// DeKalb Av.
    static func changingNearby(_ trip: Trip) -> Trip {
        guard let change = trip.change else { return trip }
        let nearby = change.suggestions(for: trip.selection).map(\.change)
        guard !nearby.isEmpty, let more = Change(stops: change.stops + nearby)?.validated(for: trip.selection)
        else { return trip }
        var trip = trip
        trip.change = more
        return trip
    }

    /// Other changes `trip` could make, for New Trip to offer switched off: at each of its
    /// change's stations (or one joined to it), lines it doesn't change to there that leave its
    /// way and go to the end, often a walk away. From an R toward Manhattan changing to the D or N
    /// at Atlantic Av-Barclays Ctr for 34 St-Herald Sq, the B or Q there.
    static func otherChanges(for trip: Trip) -> [Change] {
        guard let change = trip.change else { return [] }
        var others: [Change] = []
        var complexes = Set<String>()
        for stop in change.stops {
            guard let station = stop.station, complexes.insert(station.complex).inserted else { continue }
            let taken = Set(change.stops.filter { $0.station?.complex == station.complex }.flatMap(\.routes))
            var other = stop
            other.routes = Change.lines(at: station).filter { route in
                !taken.contains(route) && !trip.selection.routes.contains(route) && change.reachesDestination(route)
            }
            guard !other.routes.isEmpty, let valid = other.validated(for: trip.selection) else { continue }
            others += valid.stops
        }
        return others
    }
}
