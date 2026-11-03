import CoreLocation

/// Works out the subway trip for shared directions from where they start and end: the train
/// from a station near the start to one near the end, the way that gets there, with a change
/// if no line goes straight there. Maps links don't say which lines the directions take.
enum TripPlanner {
    /// A train and, if needed, a change, with the stations it was matched to.
    struct Trip: Equatable, Sendable {
        var selection: Selection
        var change: Change?
        /// The station nearest the directions' end.
        var destination: Station
    }

    /// Meters; stations further from either end aren't considered, unless a plan's asked for
    /// another walk (New Trip's Walk up to).
    static let walkRange: Double = 1_200
    /// Meters of walking a change is worth avoiding: a direct train from a station this much
    /// further away comes first.
    private static let changePenalty: Double = 800
    /// Meters a change station joined to others can take the trip out of its way, straight line
    /// via it against via the most direct of them, or half the straight line there if that's
    /// more (`joining(_:into:)`).
    private static let outOfWay: Double = 1_000

    /// The most trips offered.
    static let maxOptions = 4

    /// Trips from `start` to `end` leaving at `now`, to choose from, best first: by when they get
    /// there, with the downloaded timetable (`plan(from:to:at:timetable:)`); without one, by
    /// least walking (`byWalking(from:to:)`), as also when the timetable runs out before they'd
    /// get there (`runsOut`) and it has none. In step-free mode, only those `stepFree(_:)` keeps.
    static func plan(from start: CLLocation, to end: CLLocation, at now: Date = .now,
                     walkRange: Double = walkRange) -> [Trip] {
        planned(from: start, to: end, at: now, walkRange: walkRange).trips
    }

    /// `plan`'s trips, and where there are none, why not, as the planner that ran decided.
    static func planned(from start: CLLocation, to end: CLLocation, at now: Date = .now,
                        walkRange: Double = walkRange) -> (trips: [Trip], none: NoTrip?) {
        if let timetable = TimetableStore.load(now: now) {
            let planned = planned(from: start, to: end, at: now, timetable: timetable, walkRange: walkRange)
            if !planned.trips.isEmpty || timetable.ends.timeIntervalSince(now) > runsOut {
                return (withoutSlowerWalks(fromNearest(planned.trips, to: start), from: start, to: end, at: now,
                                           timetable: timetable), planned.none)
            }
        }
        let untimed = plannedByWalking(from: start, to: end, walkRange: walkRange)
        let trips = fromNearest(SharedStore.loadSettings().stepFree ? untimed.trips.compactMap(stepFree) : untimed.trips,
                                to: start)
        return (trips, trips.isEmpty ? untimed.none ?? .noTrain : nil)
    }

    /// How long before the timetable's last train a trip might not be in it: the longest wait
    /// and ride, by when its trains finish their runs.
    private static let runsOut: TimeInterval = 3 * 60 * 60

    /// `trips` (best first) without any whose lines all go the same way from a station nearer
    /// `start` too, changing to the same lines if either changes: the R from the station on your
    /// corner, not also from the next one along. One with more lines there stays: the D, N or R
    /// from Atlantic Av-Barclays Ctr, with just the R at Union St. From the same station to the
    /// same end, the first stays: the 2 or 3 from 96 St, not also the 1, 2 or 3 there.
    static func fromNearest(_ trips: [Trip], to start: CLLocation) -> [Trip] {
        func meters(_ trip: Trip) -> Double {
            trip.selection.station.map { start.distance(from: $0.location) }
                ?? .infinity
        }
        /// Whether `nearer` offers every line of `further`, the same way, and the same change.
        func covers(_ nearer: Trip, _ further: Trip) -> Bool {
            Set(nearer.change?.allRoutes ?? []) == Set(further.change?.allRoutes ?? [])
                && further.selection.routes.allSatisfy { route in
                    nearer.selection.routes.contains(route)
                        && nearer.selection.direction(of: route) == further.selection.direction(of: route)
                }
        }
        return trips.indices.filter { index in
            !trips.indices.contains { other in
                let (mine, theirs) = (meters(trips[index]), meters(trips[other]))
                return other != index && covers(trips[other], trips[index])
                    && (theirs < mine || theirs == mine && other < index && trips[other].destination.complex
                        == trips[index].destination.complex)
            }
        }
        .map { trips[$0] }
    }

    /// Trips from `start` to `end`, best (least walking) first, to choose from: each train once,
    /// and each way to the end once, from the station nearest it. None if either end is too far
    /// from the subway, or walking there is as quick.
    static func byWalking(from start: CLLocation, to end: CLLocation, walkRange: Double = walkRange) -> [Trip] {
        plannedByWalking(from: start, to: end, walkRange: walkRange).trips
    }

    /// `byWalking`'s trips, and where there are none, why not.
    static func plannedByWalking(from start: CLLocation, to end: CLLocation,
                                 walkRange: Double = walkRange) -> (trips: [Trip], none: NoTrip?) {
        let origins = Nearby.stations(near: start, limit: 6).filter { $0.meters <= walkRange }
        let destinations = Nearby.stations(near: end, limit: 6).filter { $0.meters <= walkRange }
        if let none = noStations(start: start, startRange: walkRange, startNear: !origins.isEmpty,
                                 end: end, endRange: walkRange, endNear: !destinations.isEmpty) {
            return ([], none)
        }
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
        let walk = WalkReach.meters(from: start, to: end) ?? .infinity
        guard !found.isEmpty else { return ([], .noTrain) }
        var trains = Set<String>()
        var ways = Set<String>()
        let trips = found.filter { $0.cost < walk }
            .sorted { $0.cost < $1.cost }
            .map(\.trip)
            .filter { trip in
                let change = trip.change.map { "\($0.stationID) \($0.routes)" } ?? ""
                // The same train to another station, or the same lines there from further away
                let train = "\(trip.selection.trainID) \(change)"
                let way = "\(trip.selection.routes) \(change) \(trip.destination.complex)"
                return trains.insert(train).inserted && ways.insert(way).inserted
            }
        guard !trips.isEmpty else { return ([], .walkingAsQuick) }
        return (Array(withoutDetours(trips, from: start, to: end, timetable: nil).prefix(maxOptions)), nil)
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

    /// Whether `trip` rides backwards to meet its change: a line it changes to then calls at its
    /// start, or where its own line gets to going the other way, before the end. From Prospect Av
    /// for 34 St-Herald Sq, the R down to 36 St for a D up through Atlantic Av-Barclays Ctr, when
    /// the R up gets there, to change to the same D. Maps apps suggest these.
    static func ridesBack(_ trip: Trip) -> Bool {
        guard let change = trip.change, let origin = trip.selection.station else { return false }
        let here = Set(origin.platforms.map(\.id))
        for route in trip.selection.routes {
            let behind = Set(StationDirectory.stops(of: route, from: here, going: trip.selection.direction(of: route).opposite)
                .compactMap { StationDirectory.station(id: $0)?.complex } + [origin.complex])
            for stop in change.stops {
                guard let station = stop.station else { continue }
                let end = (stop.destination ?? trip.destination).complex
                for onward in stop.routes {
                    let boards = Set(StationDirectory.stations(inComplexOf: station)
                        .flatMap { $0.platforms(serving: [onward]) }.map(\.id))
                    let going = stop.departureDirection(for: trip.selection)
                    // Branch by branch, as each gets to the end (or doesn't) on its own: the A from
                    // Rockaway Blvd to Lefferts Blvd, then to the Rockaways
                    let ahead = StationDirectory.branches(of: onward).compactMap { branch -> [String]? in
                        guard let here = branch.firstIndex(where: boards.contains) else { return nil }
                        let stops = going == .north ? Array(branch[..<here].reversed()) : Array(branch[(here + 1)...])
                        return stops.compactMap { StationDirectory.station(id: $0)?.complex }
                    }
                    // Up to the end on those that get there; all of each if none does
                    let toEnd = ahead.compactMap { complexes in complexes.firstIndex(of: end).map { complexes[..<$0] } }
                    let checked = toEnd.isEmpty ? ahead.map { $0[...] } : toEnd
                    if checked.contains(where: { $0.contains(where: behind.contains) }) { return true }
                }
            }
        }
        return false
    }

    /// Meters further from the end on foot a change station can be than where you boarded,
    /// for lines that curve on the way (`goesAway(_:)`).
    private static let awaySlack: Double = 150

    /// Whether `trip`'s change takes it away from the end: each of its stations further from
    /// where it gets off, on foot (`WalkReach`), than where it boards, by over `awaySlack`, and
    /// by over twice what the ride there heads toward the end, along the straight line from where
    /// it boards. From W 4 St-Wash Sq for 14 St-Union Sq, the D, F or M down to Broadway-Lafayette
    /// St for the 6 back up; not the A or E up to 14 St for the L, a little further but on the way.
    /// On foot, so round by the bridges: from Greenpoint for Stuy Town, the G down to
    /// Metropolitan Av is nearer by the Williamsburg Bridge, for the L under the river.
    static func goesAway(_ trip: Trip) -> Bool {
        guard let change = trip.change, let origin = trip.selection.station else { return false }
        let end = change.destination ?? trip.destination
        let from = WalkReach.From(end.location)
        let stations = change.stops.compactMap(\.station)
        guard let boarded = from.meters(to: origin), !stations.isEmpty else { return false }
        // On a flat plane, in meters from where it boards: near enough at this size
        let east = 111_320 * cos(origin.lat * .pi / 180), north = 111_320.0
        let toEnd = ((end.lon - origin.lon) * east, (end.lat - origin.lat) * north)
        let straight = hypot(toEnd.0, toEnd.1)
        return stations.allSatisfy { station in
            guard let further = from.meters(to: station).map({ $0 - boarded }) else { return true }
            let toStation = ((station.lon - origin.lon) * east, (station.lat - origin.lat) * north)
            let headway = straight > 0 ? (toStation.0 * toEnd.0 + toStation.1 * toEnd.1) / straight : 0
            return further > awaySlack && headway < further / 2
        }
    }

    /// Which way `route` goes from `origin` to one of `stations`, by its stops north to south on
    /// one of its branches (`StationDirectory.direction(of:from:to:)`); nil if it doesn't stop at
    /// both, or not on one branch.
    private static func direction(of route: String, from origin: Station, to stations: [Station]) -> Direction? {
        StationDirectory.direction(of: route, from: Set(origin.platforms.map(\.id)),
                                   to: Set(stations.flatMap(\.platforms).map(\.id)))
    }

    private static func distance(_ a: Station, _ b: Station) -> Double {
        a.location.distance(from: b.location)
    }
}

// MARK: - Changing at several stations

extension TripPlanner {
    /// `trips` (best first) with each train's changes joined, as a widget changes at whichever
    /// station gets you on soonest (`Change.smartChanges(for:)`): a later trip on the same train
    /// to the same end that changes elsewhere, or to other lines, becomes more stations of the
    /// first one's change (`joining(_:into:)`). Then each change also gets your train's stops
    /// either side where a line across the platform goes to the end (`changingNearby(_:)`).
    static func joiningChanges(_ trips: [Trip], at now: Date = .now) -> [Trip] {
        var joined: [Trip] = []
        for trip in trips {
            if let index = joined.indices.first(where: { joining(trip, into: joined[$0]) != nil }),
               let both = joining(trip, into: joined[index]) {
                joined[index] = both
            } else {
                joined.append(trip)
            }
        }
        return joined.map { changingNearby($0, at: now) }
    }

    /// `kept` with `trip`'s change stations added to its own, kept first, if both are the same
    /// train changing on to the same end: from an R toward Manhattan for 34 St-Herald Sq, the D
    /// or N at Atlantic Av-Barclays Ctr and the B or Q at DeKalb Av. Nil otherwise.
    ///
    /// Only stations on the way stay, not one ridden past the end to come back on another line
    /// (`outOfWay`): from W 4 St-Wash Sq for 14 St-Union Sq, the F to 14 St for the L, not also
    /// up to 34 St-Herald Sq for the R back down. And `trip`'s only where they add a line, or one
    /// across the platform that's a walk at the others: from a 3 that ends at Times Sq-42 St at
    /// night, the 1 or 2 there, not also the 2 at each stop before.
    static func joining(_ trip: Trip, into kept: Trip) -> Trip? {
        guard let change = trip.change, let keptChange = kept.change,
              trip.selection.trainID == kept.selection.trainID,
              trip.destination.complex == kept.destination.complex,
              let origin = kept.selection.station else { return nil }
        let selection = kept.selection
        let end = keptChange.destination ?? kept.destination
        func ride(_ stop: Change) -> Double {
            stop.station.map { distance(origin, $0) + distance($0, end) } ?? .infinity
        }
        let all = keptChange.stops + change.stops
        let shortest = all.map(ride).min() ?? .infinity
        let onTheWay = { (stop: Change) in ride(stop) <= shortest + max(outOfWay, distance(origin, end) / 2) }
        var stops = keptChange.stops.filter(onTheWay)
        for stop in change.stops where onTheWay(stop) {
            let adds = stop.routes.contains { route in
                !stops.contains { $0.routes.contains(route) && ($0.isAcross(route, from: selection) || !stop.isAcross(route, from: selection)) }
            }
            if adds { stops.append(stop) }
        }
        guard let both = Change(stops: stops)?.validated(for: selection) else { return nil }
        var joined = kept
        joined.change = both
        return joined
    }

    /// `trip` with its change at your train's stop before or after each station too, where a line
    /// across the platform there goes to the end (`Change.suggestions(for:)`): from an R toward
    /// Manhattan changing to the D or N at Atlantic Av-Barclays Ctr for 34 St-Herald Sq, the Q at
    /// DeKalb Av.
    static func changingNearby(_ trip: Trip) -> Trip {
        changingNearby(trip, at: .now)
    }

    /// `changingNearby(_:)` leaving at `now`: lines the timetable has no trains of there then
    /// aren't added (`running(_:for:at:)`), as the B isn't at weekends, nor lines at your own
    /// station, which you'd take from there (the B at W 4 St-Wash Sq for a D from 42 St-Bryant Pk).
    static func changingNearby(_ trip: Trip, at now: Date) -> Trip {
        guard let change = trip.change, let origin = trip.selection.station else { return trip }
        let here = Set(Change.lines(at: origin))
        let nearby = change.suggestions(for: trip.selection).map(\.change)
            .compactMap { suggestion -> Change? in
                var suggestion = suggestion
                suggestion.routes.removeAll(where: here.contains)
                return suggestion.routes.isEmpty ? nil : running(suggestion, for: trip.selection, at: now)
            }
            .flatMap(\.stops)
        guard !nearby.isEmpty, let more = Change(stops: change.stops + nearby)?.validated(for: trip.selection)
        else { return trip }
        var trip = trip
        trip.change = more
        return trip
    }

    /// Other changes `trip` could make, for New Trip to offer switched off: at each of its
    /// change's stations (or one joined to it), lines it doesn't change to there that leave its
    /// way and go to the end, often a walk away. From an R toward Manhattan changing to the D or N
    /// at Atlantic Av-Barclays Ctr for 34 St-Herald Sq, the B or Q there. Leaving at `now`, not
    /// lines the timetable has no trains of there then (`running(_:for:at:)`), nor in step-free
    /// mode changes that aren't step-free (`stepFree(_:)`).
    static func otherChanges(for trip: Trip, at now: Date = .now) -> [Change] {
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
            guard !other.routes.isEmpty, var valid = other.validated(for: trip.selection).flatMap({
                running($0, for: trip.selection, at: now)
            }) else { continue }
            if SharedStore.loadSettings().stepFree {
                var changed = trip
                changed.change = valid
                guard let stepFree = stepFree(changed)?.change else { continue }
                valid = stepFree
            }
            others += valid.stops
        }
        return others
    }
}

// MARK: - Step-free

extension TripPlanner {
    /// `trip` as Settings' step-free mode takes it: just its lines that board at a step-free
    /// platform (`Platform.isStepFree(going:)`), and its change stations where you change across
    /// the platform or between step-free ones, each to lines that get off at a step-free platform
    /// at the end. Not at Lexington Av/59 St for the N, R or W, whose platform has no elevator, nor
    /// to an E toward Queens at Court Sq-23 St, step-free toward Manhattan only. Nil if none are
    /// left. For trips from elsewhere (Google's) and without the timetable; the timed planner
    /// keeps to them itself.
    static func stepFree(_ trip: Trip) -> Trip? {
        guard let station = trip.selection.station else { return nil }
        let given = trip.selection
        func stepFree(_ route: String, going way: Direction, at station: Station) -> Bool {
            StationDirectory.stations(inComplexOf: station).flatMap { $0.platforms(serving: [route]) }
                .contains { $0.isStepFree(going: way) == true }
        }
        var kept = trip
        kept.selection.routes = given.routes.filter { route in
            let way = given.direction(of: route)
            return station.platforms(serving: [route]).contains { $0.isStepFree(going: way) == true }
                && (trip.change != nil || stepFree(route, going: way, at: trip.destination))
        }
        guard !kept.selection.routes.isEmpty else { return nil }
        guard let change = trip.change else { return kept }
        let selection = kept.selection
        let end = change.destination ?? trip.destination
        let stops = change.stops.compactMap { stop -> Change? in
            guard let at = stop.station else { return nil }
            let off = selection.routes.allSatisfy { route in
                at.platforms(serving: [route]).allSatisfy { $0.isStepFree(going: selection.direction(of: route)) == true }
            }
            var stop = stop
            stop.routes = stop.routes.filter { route in
                let way = stop.departureDirection(of: route, for: selection)
                return (stop.isAcross(route, from: selection) || off && stepFree(route, going: way, at: at))
                    && stepFree(route, going: way, at: end)
            }
            return stop.routes.isEmpty ? nil : stop
        }
        guard let valid = Change(stops: stops)?.validated(for: selection) else { return nil }
        kept.change = valid
        return kept
    }
}
