import CoreLocation

/// Trips for shared directions by when they get there, as maps apps rank them: the walk to a
/// station near the start, the timetable's next trains from it, at most one change, and the walk
/// from a station near the end. Without a timetable, `TripPlanner` ranks by walking instead.
extension TripPlanner {
    /// Seconds to walk `meters`: 80 a minute (3 mph), plus 20% for indirect streets. Every walk
    /// the app times goes by it: to and from stations, and between a bus and a train.
    static func walkSeconds(_ meters: Double) -> TimeInterval {
        meters * 1.2 / 80 * 60
    }

    /// Changing across the platform; to another platform, or a station joined to it, is
    /// `Change.defaultWalkMinutes`.
    private static let acrossSeconds: TimeInterval = 60
    /// What a change counts for in ranking trips, on top of its time, as maps apps rank them
    /// below ones without; and on foot to another platform, more again, so stepping across the
    /// platform at DeKalb Av beats walking between platforms at Atlantic Av for the same B.
    private static let changeCost: TimeInterval = 3 * 60
    private static let walkingChangeCost: TimeInterval = 3 * 60
    /// The longest wait for a train; one later isn't counted.
    private static let longestWait: TimeInterval = 30 * 60
    /// Trips ranked this much below the best aren't offered.
    private static let slowerBy: TimeInterval = 20 * 60
    /// Lines whose trips get there within this of each other are offered together, as one
    /// train ("D, N or R") or change.
    private static let together: TimeInterval = 4 * 60

    /// A way there: from `origin` on `route`, maybe changing at `change` to `onward`.
    private struct Journey {
        var arrives: TimeInterval
        /// What it's ranked by: `arrives`, plus `changeCost` and any `walkingChangeCost`.
        var cost: TimeInterval
        var origin: Station
        var route: String
        /// The feed's N or S where `route` is boarded.
        var direction: Direction
        var change: (station: Station, route: String, direction: Direction)?
        var destination: Station
    }

    /// The best trips from `start` to `end` leaving at `now`, best first (soonest there, counting
    /// changes against them as `changeCost` does): each way there once, with lines that get there
    /// about as soon offered together. None if either end is too
    /// far from the subway, or walking there is as quick.
    static func plan(from start: CLLocation, to end: CLLocation, at now: Date, timetable: Timetable) -> [Trip] {
        let origins = Nearby.stations(near: start, limit: 8).filter { $0.meters <= walkRange }
        let destinations = Nearby.stations(near: end, limit: 8).filter { $0.meters <= walkRange }
        let setOff = now.timeIntervalSince(timetable.base)

        // The stops near the end, and the trips that call at them
        var ends: [String: (station: Station, walk: TimeInterval)] = [:]
        for destination in destinations {
            for stop in stops(at: destination.station) {
                ends[stop] = (destination.station, walkSeconds(destination.meters))
            }
        }
        var ending: [Int: [(call: Int, stop: String)]] = [:]
        for stop in ends.keys {
            for (pattern, call) in timetable.calls(at: stop) {
                ending[pattern, default: []].append((call, stop))
            }
        }

        var journeys: [Journey] = []
        // Where each line from the start gets to soonest, for changing there
        var reached: [String: [String: Journey]] = [:]
        for origin in origins {
            let ready = setOff + walkSeconds(origin.meters)
            for stop in stops(at: origin.station) {
                guard let direction = Direction(ofStop: stop) else { continue }
                for (pattern, call) in timetable.calls(at: stop) {
                    guard let trip = departure(timetable, pattern: pattern, call: call, after: ready) else { continue }
                    let route = route(timetable, pattern)
                    let calls = timetable.patterns[pattern].calls
                    for next in calls.indices where next > call {
                        let at = timetable.stops[Int(calls[next].stop)]
                        let arrives = trip + TimeInterval(calls[next].arrives)
                        let ride = Journey(arrives: arrives, cost: arrives, origin: origin.station, route: route,
                                           direction: direction, destination: origin.station)
                        if let end = ends[at], end.station.complex != origin.station.complex {
                            var there = ride
                            there.arrives += end.walk
                            there.cost = there.arrives
                            there.destination = end.station
                            journeys.append(there)
                        }
                        if reached[at]?[route].map({ arrives < $0.arrives }) ?? true {
                            reached[at, default: [:]][route] = ride
                        }
                    }
                }
            }
        }

        // Then one change, to a train that calls near the end
        let startLines = Dictionary(uniqueKeysWithValues: origins.map { origin in
            (origin.station.id, Set(StationDirectory.stations(inComplexOf: origin.station).flatMap(\.routes)))
        })
        for (at, rides) in reached {
            guard let station = StationDirectory.station(forStop: at), Direction(ofStop: at) != nil else { continue }
            for joined in StationDirectory.stations(inComplexOf: station) {
                for board in stops(at: joined) {
                    guard let direction = Direction(ofStop: board) else { continue }
                    for (pattern, call) in timetable.calls(at: board) {
                        guard let calls = ending[pattern] else { continue }
                        let onward = route(timetable, pattern)
                        // Not to a line from the start, which could have been taken from there
                        for (route, ride) in rides where route != onward && ride.origin.complex != station.complex
                            && startLines[ride.origin.id]?.contains(onward) != true {
                            // Across the platform: off and on at the same side of it
                            let across = Change.isAcross(off: route, at: at, on: onward, at: board)
                            let change = across ? acrossSeconds : TimeInterval(Change.defaultWalkMinutes * 60)
                            guard let trip = departure(timetable, pattern: pattern, call: call, after: ride.arrives + change)
                            else { continue }
                            for (endCall, stop) in calls where endCall > call {
                                guard let end = ends[stop], end.station.complex != station.complex else { continue }
                                let arrives = trip + TimeInterval(timetable.patterns[pattern].calls[endCall].arrives)
                                let there = arrives + end.walk
                                journeys.append(Journey(arrives: there,
                                                        cost: there + changeCost + (across ? 0 : walkingChangeCost),
                                                        origin: ride.origin, route: route, direction: ride.direction,
                                                        change: (station, onward, direction), destination: end.station))
                            }
                        }
                    }
                }
            }
        }

        // Not changes off a train that goes there itself
        let direct = Set(journeys.filter { $0.change == nil }.map { "\($0.origin.id) \($0.route)" })
        journeys.removeAll { $0.change != nil && direct.contains("\($0.origin.id) \($0.route)") }
        // Not if walking there is as quick
        let walking = setOff + walkSeconds(start.distance(from: end))
        guard let soonest = journeys.map(\.arrives).min(), soonest < walking,
              let best = journeys.map(\.cost).min() else { return [] }
        let offered = journeys.filter { $0.cost <= best + slowerBy }.sorted { $0.cost < $1.cost }
        return Array(trips(from: offered).prefix(maxOptions))
    }

    /// What `trip` from `start` to `end` leaving at `now` is ranked by, as `plan` ranks its own:
    /// the walk to its station, the timetable's next train of its lines, any change (counted
    /// against it as `changeCost`, and `walkingChangeCost` off the platform), and the walk from
    /// where it ends. Nil if the timetable has none of its trains within `longestWait`. For
    /// trips from elsewhere (Google's), so they rank with the app's.
    static func cost(of trip: Trip, from start: CLLocation, to end: CLLocation, at now: Date,
                     timetable: Timetable) -> TimeInterval? {
        timing(of: trip, from: start, to: end, at: now, timetable: timetable).map { $0.arrives + $0.penalty }
    }

    /// When `trip` from `start` to `end` leaving at `now` gets there, walks included, as `cost`
    /// times it but without what a change counts against it; nil if the timetable can't time it.
    static func arrival(of trip: Trip, from start: CLLocation, to end: CLLocation, at now: Date,
                        timetable: Timetable) -> Date? {
        timing(of: trip, from: start, to: end, at: now, timetable: timetable)
            .map { timetable.base.addingTimeInterval($0.arrives) }
    }

    /// `trip`'s arrival, in the timetable's seconds, and what its change counts against it.
    private static func timing(of trip: Trip, from start: CLLocation, to end: CLLocation, at now: Date,
                               timetable: Timetable) -> (arrives: TimeInterval, penalty: TimeInterval)? {
        guard let origin = trip.selection.station else { return nil }
        let selection = trip.selection
        let ready = now.timeIntervalSince(timetable.base)
            + walkSeconds(start.distance(from: CLLocation(latitude: origin.lat, longitude: origin.lon)))
        let lastStation = trip.change?.destination ?? trip.destination
        let walkOff = walkSeconds(end.distance(from: CLLocation(latitude: lastStation.lat, longitude: lastStation.lon)))

        guard let change = trip.change else {
            let there = soonest(timetable, from: selection.stopIDs, routes: selection.routes, after: ready,
                                to: StationDirectory.stops(inComplexOf: trip.destination))
            return there.map { ($0.arrives + walkOff, 0) }
        }
        // At each of its stations, off there, then on to its lines there, across the platform or
        // a walk away; the best of them, as the widget changes wherever gets you on soonest
        let targets = change.destination.map(StationDirectory.stops(inComplexOf:))
            ?? StationDirectory.stops(inComplexOf: trip.destination)
        var best: (arrives: TimeInterval, penalty: TimeInterval)?
        for stop in change.stops {
            guard let off = soonest(timetable, from: selection.stopIDs, routes: selection.routes, after: ready,
                                    to: Set(stop.arrivalStops(for: selection))) else { continue }
            let boards = stop.departureStops(for: selection)
            // Across the platform, as `plan` counts it: a line changed to on the platform you're
            // off at, on the same side of it
            let across = boards.contains { board in
                stop.routes.contains { route in
                    StationDirectory.platform(forStop: board)?.routes.contains(route) == true
                        && Change.isAcross(off: off.route, at: off.stop, on: route, at: board)
                }
            }
            let changing = across ? acrossSeconds : TimeInterval(stop.walkMinutes * 60)
            guard let there = soonest(timetable, from: boards, routes: stop.routes, after: off.arrives + changing,
                                      to: targets) else { continue }
            let timing = (arrives: there.arrives + walkOff, penalty: changeCost + (across ? 0 : walkingChangeCost))
            if timing.arrives + timing.penalty < best.map({ $0.arrives + $0.penalty }) ?? .infinity {
                best = timing
            }
        }
        return best
    }

    /// `trips` best first by `cost(of:from:to:at:timetable:)`, leaving out those ranked over
    /// `slowerBy` below the best. Without a timetable, or for trips it can't time, they keep their
    /// order, after those it can.
    static func ranked(_ trips: [Trip], from start: CLLocation, to end: CLLocation, at now: Date = .now) -> [Trip] {
        guard let timetable = TimetableStore.load(now: now) else { return trips }
        let costs = trips.map { cost(of: $0, from: start, to: end, at: now, timetable: timetable) }
        guard let best = costs.compactMap({ $0 }).min() else { return trips }
        return trips.indices
            .filter { costs[$0].map { $0 <= best + slowerBy } ?? true }
            .sorted { (costs[$0] ?? .infinity, $0) < (costs[$1] ?? .infinity, $1) }
            .map { trips[$0] }
    }

    /// The soonest arrival at one of `targets` on `routes` boarding at one of `stops` at or after
    /// `time`, the stop it arrives at, and its line.
    private static func soonest(_ timetable: Timetable, from stops: [String], routes: [String], after time: TimeInterval,
                                to targets: Set<String>) -> (arrives: TimeInterval, stop: String, route: String)? {
        var best: (arrives: TimeInterval, stop: String, route: String)?
        for stop in stops {
            for (pattern, call) in timetable.calls(at: stop) {
                let route = route(timetable, pattern)
                guard routes.contains(route) else { continue }
                guard let trip = departure(timetable, pattern: pattern, call: call, after: time) else { continue }
                let calls = timetable.patterns[pattern].calls
                guard let next = calls.indices.first(where: { $0 > call && targets.contains(timetable.stops[Int(calls[$0].stop)]) })
                else { continue }
                let arrives = trip + TimeInterval(calls[next].arrives)
                if arrives < best?.arrives ?? .infinity {
                    best = (arrives, timetable.stops[Int(calls[next].stop)], route)
                }
            }
        }
        return best
    }

    /// `journeys` (best first) as trips: those from the same station the same way, with the
    /// same change and end, joined while about as soon, then each train's changes to the same
    /// end as one change at each of their stations (`joiningChanges(_:)`), and each way there once.
    private static func trips(from journeys: [Journey]) -> [Trip] {
        struct Group {
            var first: Journey
            var routes: [String: Direction]
            var onward: [String: Direction]
        }
        var groups: [Group] = []
        for journey in journeys {
            let index = groups.firstIndex { group in
                group.first.origin.id == journey.origin.id && group.first.direction == journey.direction
                    && group.first.change?.station.complex == journey.change?.station.complex
                    && group.first.change?.direction == journey.change?.direction
                    && group.first.destination.complex == journey.destination.complex
                    && journey.cost - group.first.cost <= together
            }
            if let index {
                if groups[index].routes[journey.route] == nil { groups[index].routes[journey.route] = journey.direction }
                if let change = journey.change, groups[index].onward[change.route] == nil {
                    groups[index].onward[change.route] = change.direction
                }
            } else {
                groups.append(Group(first: journey, routes: [journey.route: journey.direction],
                                    onward: journey.change.map { [$0.route: $0.direction] } ?? [:]))
            }
        }
        let built = groups.compactMap { group -> Trip? in
            let origin = group.first.origin
            let routes = origin.routes.filter { group.routes[$0] != nil }
            guard !routes.isEmpty else { return nil }
            let selection = together(at: origin, routes, going: group.first.direction, else: routes[0]) {
                group.routes[$0]
            }
            var change: Change?
            if let first = group.first.change {
                let onward = group.onward.keys.sorted { Lines.rank($0) < Lines.rank($1) }
                guard let valid = Change(stationID: first.station.id, routes: onward, direction: first.direction,
                                         destinationID: group.first.destination.id).validated(for: selection)
                else { return nil }
                change = valid
            }
            return Trip(selection: selection, change: change, destination: group.first.destination)
        }
        // The same train changing on to the same end, at another station or to other lines, as
        // one change at each; then the same train changing to the same lines for another station
        // near the end, or at the same station, just once
        var seen = Set<String>()
        return joiningChanges(built).filter { trip in
            let lines = "\(trip.selection.trainID) to \(trip.change?.allRoutes ?? [])"
            let place = "\(trip.selection.trainID) at \(trip.change?.station?.complex ?? "") for \(trip.destination.complex)"
            guard !seen.contains(lines), !seen.contains(place) else { return false }
            seen.formUnion([lines, place])
            return true
        }
    }

    /// Feed stop ids at `station`, both ways ("R31N", "R31S").
    private static func stops(at station: Station) -> [String] {
        station.platforms.flatMap { platform in Direction.allCases.map { platform.id + $0.rawValue } }
    }

    /// When the first trip of `pattern` leaving its `call`th stop at or after `time` starts,
    /// unless it's over `longestWait` away.
    private static func departure(_ timetable: Timetable, pattern: Int, call: Int, after time: TimeInterval) -> TimeInterval? {
        guard let start = timetable.firstStart(ofPattern: pattern, leaving: call, after: time) else { return nil }
        let stop = timetable.patterns[pattern].calls[call]
        let leaves = start + TimeInterval(stop.arrives) + TimeInterval(stop.waits)
        return leaves - time <= longestWait ? start : nil
    }

    private static func route(_ timetable: Timetable, _ pattern: Int) -> String {
        Lines.normalized(timetable.routes[Int(timetable.patterns[pattern].route)])
    }
}
