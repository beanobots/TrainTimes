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

    /// Whole minutes to walk `meters` (`walkSeconds`), to the nearest; at least 1, as shown
    /// beside a station, stop or dock.
    static func walkMinutes(_ meters: Double) -> Int {
        max(1, Int((walkSeconds(meters) / 60).rounded()))
    }

    /// Changing across the platform, as the widget counts it (`Change.canCatchAcross`): the
    /// timetable's times are arrivals, its doors open for `dwellSeconds` from then, so a train due
    /// from this long after yours can be caught. To another platform, or a station joined to it, is
    /// `Change.defaultWalkMinutes`, or the MTA's time for the walk where longer (`Platform.walks`).
    private static let acrossSeconds = Change.acrossSeconds - Change.dwellSeconds
    /// What a change on foot to another platform counts for in ranking trips, on top of its
    /// time, as maps apps rank them below ones without, and more again for the walk, so stepping
    /// across the platform at DeKalb Av beats walking between platforms at Atlantic Av for the
    /// same B. A change across the platform counts only its time.
    private static let changeCost: TimeInterval = 3 * 60
    private static let walkingChangeCost: TimeInterval = 3 * 60
    /// Arrivals this close count as the same time for a trip with a shorter walk at the ends
    /// (`withoutSlowerWalks`): the Q to W 8 St-NY Aquarium, not also the N or Q to Coney
    /// Island-Stillwell Av timed seconds sooner.
    private static let sameArrival: TimeInterval = 60
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
        /// What it's ranked by: `arrives`, plus `changeCost` and `walkingChangeCost` for a walk.
        var cost: TimeInterval
        var origin: Station
        var route: String
        /// The feed's N or S where `route` is boarded.
        var direction: Direction
        var change: (station: Station, route: String, direction: Direction)?
        var destination: Station
        /// Whether `change` is across the platform.
        var across = false
    }

    /// The best trips from `start` to `end` leaving at `now`, best first (soonest there, counting
    /// changes on foot against them as `changeCost` does): each way there once, with lines that get there
    /// about as soon offered together. None if either end is too
    /// far from the subway, or walking there is as quick. `startRange` and `endRange`, where
    /// given, are the walk at that end instead: a station biked to or from is the only one there.
    static func plan(from start: CLLocation, to end: CLLocation, at now: Date, timetable: Timetable,
                     walkRange: Double = walkRange, startRange: Double? = nil, endRange: Double? = nil) -> [Trip] {
        planned(from: start, to: end, at: now, timetable: timetable, walkRange: walkRange,
                startRange: startRange, endRange: endRange).trips
    }

    /// `plan(from:to:at:timetable:)`'s trips, and where there are none, why not: no station near
    /// an end, no train in the timetable, or walking as quick.
    static func planned(from start: CLLocation, to end: CLLocation, at now: Date, timetable: Timetable,
                        walkRange: Double = walkRange, startRange: Double? = nil,
                        endRange: Double? = nil) -> (trips: [Trip], none: NoTrip?) {
        let origins = stations(near: start, within: startRange ?? walkRange, nearest: 8)
        let destinations = stations(near: end, within: endRange ?? walkRange, nearest: 8)
        if let none = noStations(start: start, startRange: startRange ?? walkRange, startNear: !origins.isEmpty,
                                 end: end, endRange: endRange ?? walkRange, endNear: !destinations.isEmpty) {
            return ([], none)
        }
        let setOff = now.timeIntervalSince(timetable.base)
        // In step-free mode, on and off only at step-free platforms, and changing across the
        // platform or between them
        let stepFree = SharedStore.loadSettings().stepFree
        let usable = { (stop: String) in !stepFree || isStepFree(stop) }

        // The stops near the end, and the trips that call at them
        var ends: [String: (station: Station, walk: TimeInterval)] = [:]
        for destination in destinations {
            for stop in stops(at: destination.station) where usable(stop) {
                ends[stop] = (destination.station, walkSeconds(destination.meters))
            }
        }
        var ending: [Int: [(call: Int, stop: String)]] = [:]
        for stop in ends.keys {
            for (pattern, call) in timetable.calls(at: stop) {
                ending[pattern, default: []].append((call, stop))
            }
        }

        // And the stations joined to those near the start, walked to through them: Chambers St's J
        // by Brooklyn Bridge-City Hall
        var boarding = origins
        for origin in origins {
            for joined in StationDirectory.stations(inComplexOf: origin.station)
            where !boarding.contains(where: { $0.station.id == joined.id }) {
                let meters = max(origin.meters, start.distance(from: joined.location))
                if meters <= startRange ?? walkRange { boarding.append(.init(station: joined, meters: meters)) }
            }
        }

        var journeys: [Journey] = []
        // Where each line from the start gets to soonest, for changing there
        var reached: [String: [String: Journey]] = [:]
        for origin in boarding {
            let ready = setOff + walkSeconds(origin.meters)
            for stop in stops(at: origin.station) where usable(stop) {
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

        // Then one change, to a train that calls near the end, at the station, one joined to it,
        // or one a street walk away (`StationDirectory.changeStations(of:)`): off the L at Livonia
        // Av for the 3 at Junius St, the MTA's 5 minutes
        // When you could be at each stop near the start, walking there
        var boardable: [String: TimeInterval] = [:]
        for origin in boarding {
            for stop in stops(at: origin.station) where usable(stop) {
                boardable[stop] = min(boardable[stop] ?? .infinity, setOff + walkSeconds(origin.meters))
            }
        }
        // Where each line from the start goes the other way: a change whose onward train then
        // calls at one of them rode backwards to meet it (the 1 up from 66 St to 72 St for a 2
        // down through Times Sq), when the 1 down gets there, to change or stay on
        var otherWays: [String: Set<String>] = [:]
        func otherWay(of ride: Journey) -> Set<String> {
            let key = "\(ride.origin.id) \(ride.route) \(ride.direction.rawValue)"
            if let complexes = otherWays[key] { return complexes }
            let complexes = Set(StationDirectory.stops(of: ride.route, from: Set(ride.origin.platforms.map(\.id)),
                                                       going: ride.direction.opposite)
                .compactMap { StationDirectory.station(id: $0)?.complex })
            otherWays[key] = complexes
            return complexes
        }
        for (at, rides) in reached {
            guard let station = StationDirectory.station(forStop: at), Direction(ofStop: at) != nil else { continue }
            for joined in StationDirectory.changeStations(of: station) {
                for board in stops(at: joined) {
                    guard let direction = Direction(ofStop: board) else { continue }
                    for (pattern, call) in timetable.calls(at: board) {
                        guard let calls = ending[pattern] else { continue }
                        let onward = route(timetable, pattern)
                        for (route, ride) in rides where route != onward && ride.origin.complex != station.complex
                            && ride.origin.complex != joined.complex {
                            // Across the platform: off and on at the same side of it
                            let across = Change.isAcross(off: route, at: at, on: onward, at: board)
                            guard across || usable(at) && usable(board) else { continue }
                            let change = across ? acrossSeconds
                                : TimeInterval(Change.walkMinutes(from: at, to: board, else: Change.defaultWalkMinutes) * 60)
                            guard let trip = departure(timetable, pattern: pattern, call: call, after: ride.arrives + change)
                            else { continue }
                            let behind = otherWay(of: ride)
                            let onwardCalls = timetable.patterns[pattern].calls
                            // Not to a train you could walk to near the start and board in time: at
                            // the change (49 St's N to Times Sq-42 St for the Q there), before it, or
                            // further on (the A to Fulton St for a J that then calls at Chambers St)
                            let walkable = onwardCalls.indices.first { index in
                                let onwardCall = onwardCalls[index]
                                return boardable[timetable.stops[Int(onwardCall.stop)]].map { ready in
                                    ready <= trip + TimeInterval(onwardCall.arrives) + TimeInterval(onwardCall.waits)
                                } ?? false
                            }
                            for (endCall, stop) in calls where endCall > call && endCall <= walkable ?? .max {
                                guard let end = ends[stop], end.station.complex != station.complex else { continue }
                                // Not back past the start on it
                                let passes = onwardCalls[(call + 1)...endCall].contains { onwardCall in
                                    StationDirectory.station(forStop: timetable.stops[Int(onwardCall.stop)])
                                        .map { behind.contains($0.complex) } ?? false
                                }
                                guard !passes else { continue }
                                let arrives = trip + TimeInterval(timetable.patterns[pattern].calls[endCall].arrives)
                                let there = arrives + end.walk
                                journeys.append(Journey(arrives: there,
                                                        cost: there + (across ? 0 : changeCost + walkingChangeCost),
                                                        origin: ride.origin, route: route, direction: ride.direction,
                                                        change: (station, onward, direction), destination: end.station,
                                                        across: across))
                            }
                        }
                    }
                }
            }
        }

        // Not changes off a train that goes there itself, unless across the platform to one that
        // gets there sooner: from Prospect Av for 34 St-Herald Sq, the R to DeKalb Av for the Q,
        // offered as well as staying on the R
        var direct: [String: TimeInterval] = [:]
        for journey in journeys where journey.change == nil {
            let key = "\(journey.origin.id) \(journey.route)"
            direct[key] = min(direct[key] ?? .infinity, journey.arrives)
        }
        journeys.removeAll { journey in
            guard journey.change != nil, let stayingOn = direct["\(journey.origin.id) \(journey.route)"] else { return false }
            return !journey.across || journey.arrives >= stayingOn
        }
        // Not if walking there is as quick, round by a bridge if there's water between
        let walking = setOff + (WalkReach.meters(from: start, to: end).map(walkSeconds) ?? .infinity)
        guard let soonest = journeys.map(\.arrives).min(), let best = journeys.map(\.cost).min() else {
            return ([], .noTrain)
        }
        guard soonest < walking else { return ([], .walkingAsQuick) }
        let offered = journeys.filter { $0.cost <= best + slowerBy }.sorted { $0.cost < $1.cost }
        let trips = withoutDetours(trips(from: offered, at: now, goesThere: Set(direct.keys)), from: start, to: end, at: now, timetable: timetable)
        // Not cut to `maxOptions` here: `TripPlanner.planned` does once it's dropped duplicates
        return (trips, trips.isEmpty ? .noTrain : nil)
    }

    /// `trips` without any whose change takes it away from the end (`goesAway(_:)`) where
    /// another that doesn't gets there no more than `together` later, or, without the timetable
    /// to time them, where there's another at all. From W 4 St-Wash Sq for 14 St-Union Sq, not
    /// the D, F or M down to Broadway-Lafayette St for the 6 back up, when the F up to 14 St for
    /// the L is as soon; but from Ozone Park-Lefferts Blvd for Middle Village, the A to W 4 St-Wash
    /// Sq for the M, the one way with a single change.
    static func withoutDetours(_ trips: [Trip], from start: CLLocation, to end: CLLocation, at now: Date = .now,
                               timetable: Timetable?) -> [Trip] {
        let away = trips.map(goesAway)
        guard away.contains(true), away.contains(false) else { return trips }
        let arrivals = trips.map { trip in
            timetable.flatMap { timing(of: trip, from: start, to: end, at: now, timetable: $0)?.arrives }
        }
        return trips.indices.filter { index in
            guard away[index] else { return true }
            return !trips.indices.contains { other in
                guard !away[other] else { return false }
                // One the timetable can't time against one it can isn't another way there
                guard let theirs = arrivals[other] else { return arrivals[index] == nil }
                return arrivals[index].map { theirs <= $0 + together } ?? true
            }
        }
        .map { trips[$0] }
    }

    /// What `trip` from `start` to `end` leaving at `now` is ranked by, as `plan` ranks its own:
    /// the walk to its station, the timetable's next train of its lines, any change (counted
    /// against it as `changeCost` and `walkingChangeCost` off the platform), and the walk from
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
            + walkSeconds(start.distance(from: origin.location))
        let lastStation = trip.change?.destination ?? trip.destination
        let walkOff = walkSeconds(end.distance(from: lastStation.location))

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
            // Each platform it boards at by itself: one across from you doesn't make a walk to
            // another as quick
            for board in stop.departureStops(for: selection) {
                // Across the platform, as `plan` counts it: a line changed to on the platform
                // you're off at, on the same side of it
                let across = stop.routes.contains { route in
                    StationDirectory.platform(forStop: board)?.routes.contains(route) == true
                        && Change.isAcross(off: off.route, at: off.stop, on: route, at: board)
                }
                // The MTA's time for the walk where it's longer
                let walking = Change.walkMinutes(from: off.stop, to: board, else: stop.walkMinutes)
                let changing = across ? acrossSeconds : TimeInterval(walking * 60)
                guard let there = soonest(timetable, from: [board], routes: stop.routes, after: off.arrives + changing,
                                          to: targets) else { continue }
                let timing = (arrives: there.arrives + walkOff, penalty: across ? 0 : changeCost + walkingChangeCost)
                if timing.arrives + timing.penalty < best.map({ $0.arrives + $0.penalty }) ?? .infinity {
                    best = timing
                }
            }
        }
        return best
    }

    /// `trips` best first by `cost(of:from:to:at:timetable:)`, leaving out those ranked over
    /// `slowerBy` below the best, and those it can't time: the timetable has none of their trains
    /// then. Without a timetable, or if it can time none of them (as near its end), they keep
    /// their order. In step-free mode, each as `stepFree(_:)` takes it, if it can.
    static func ranked(_ trips: [Trip], from start: CLLocation, to end: CLLocation, at now: Date = .now) -> [Trip] {
        let trips = SharedStore.loadSettings().stepFree ? trips.compactMap(stepFree) : trips
        guard let timetable = TimetableStore.load(now: now) else { return trips }
        let costs = trips.map { cost(of: $0, from: start, to: end, at: now, timetable: timetable) }
        guard let best = costs.compactMap({ $0 }).min() else { return trips }
        return trips.indices
            .filter { costs[$0].map { $0 <= best + slowerBy } ?? false }
            .sorted { (costs[$0] ?? .infinity, $0) < (costs[$1] ?? .infinity, $1) }
            .map { trips[$0] }
    }

    /// `trips` without any that another on the same line, the same way, beats at both ends: it
    /// walks no more, to and from its stations, and gets there no later, one of them strictly (or
    /// it comes first: the 2 or 3 from 96 St, not also the 1, 2 or 3 timed the same). The R from
    /// the corner to the station by the end, not also the R from further along with a
    /// longer walk off. With a shorter walk, within `sameArrival` counts as no later. A direct trip isn't dropped for one with a change. Trips the timetable
    /// can't time, or without one, all stay.
    static func withoutSlowerWalks(_ trips: [Trip], from start: CLLocation, to end: CLLocation,
                                   at now: Date = .now, timetable: Timetable? = nil) -> [Trip] {
        guard let timetable = timetable ?? TimetableStore.load(now: now) else { return trips }
        let measured = trips.map { trip -> (arrives: TimeInterval, walk: Double)? in
            guard let origin = trip.selection.station,
                  let arrives = timing(of: trip, from: start, to: end, at: now, timetable: timetable)?.arrives
            else { return nil }
            let last = trip.change?.destination ?? trip.destination
            let walk = start.distance(from: origin.location)
                + end.distance(from: last.location)
            return (arrives, walk)
        }
        func sharesLine(_ a: Trip, _ b: Trip) -> Bool {
            a.selection.routes.contains { route in
                b.selection.routes.contains(route) && a.selection.direction(of: route) == b.selection.direction(of: route)
            }
        }
        return trips.indices.filter { index in
            guard let mine = measured[index] else { return true }
            let trip = trips[index]
            return !trips.indices.contains { other in
                guard other != index, let theirs = measured[other], sharesLine(trips[other], trip),
                      trips[other].change == nil || trip.change != nil else { return false }
                // On a tie, the first
                let noLater = theirs.arrives <= mine.arrives
                    || theirs.walk < mine.walk && theirs.arrives <= mine.arrives + sameArrival
                return theirs.walk <= mine.walk && noLater
                    && (theirs.walk < mine.walk || theirs.arrives < mine.arrives || other < index)
            }
        }
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
    private static func trips(from journeys: [Journey], at now: Date, goesThere: Set<String>) -> [Trip] {
        struct Group {
            var first: Journey
            var routes: [String: Direction]
            var onward: [String: Direction]
        }
        var groups: [Group] = []
        for journey in journeys {
            func isSameWay(_ group: Group) -> Bool {
                group.first.origin.id == journey.origin.id && group.first.direction == journey.direction
                    && group.first.change?.station.complex == journey.change?.station.complex
                    && group.first.change?.direction == journey.change?.direction
                    && group.first.destination.complex == journey.destination.complex
            }
            let index = groups.firstIndex { isSameWay($0) && journey.cost - $0.first.cost <= together }
            // A later train of lines already offered that way isn't another way there: not the 2
            // and 3 from 96 St, then the 1, 2 and 3
            if index == nil, groups.contains(where: { group in
                isSameWay(group) && group.routes[journey.route] != nil
                    && journey.change.map { group.onward[$0.route] != nil } ?? true
            }) { continue }
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
        // Off a train that goes there itself, changing only to an express (`expressOnly`): one the
        // timetable has going there, not just the line (the A to Rockaway Park only at rush hour)
        let express = joiningChanges(built, at: now).compactMap { trip -> Trip? in
            guard let change = trip.change else { return trip }
            guard trip.selection.routes.contains(where: { goesThere.contains("\(trip.selection.stationID) \($0)") })
            else { return trip }
            guard let kept = expressOnly(change, for: trip) else { return nil }
            var trip = trip
            trip.change = kept
            return trip
        }
        var seen = Set<String>()
        return express.filter { trip in
            let lines = "\(trip.selection.trainID) to \(trip.change?.allRoutes ?? [])"
            let place = "\(trip.selection.trainID) at \(trip.change?.station?.complex ?? "") for \(trip.destination.complex)"
            guard !seen.contains(lines), !seen.contains(place) else { return false }
            seen.formUnion([lines, place])
            return true
        }
    }

    /// Whether feed stop `stop` ("R11N") is step-free, the way its trains go
    /// (`Platform.isStepFree(going:)`); not where that can't be told.
    static func isStepFree(_ stop: String) -> Bool {
        StationDirectory.platform(forStop: stop)?.isStepFree(going: Direction(ofStop: stop)) == true
    }

    /// `change` with just the lines the timetable has a train of leaving each of its stations its
    /// way within `longestWait` of when `selection`'s first train from `now` gets there: not the B
    /// at weekends, nor the W late at night. A station where the timetable can't time your train
    /// stays as it is, as does all of it without a timetable for `now`. Nil if none are left.
    static func running(_ change: Change, for selection: Selection, at now: Date) -> Change? {
        guard let timetable = TimetableStore.load(now: now) else { return change }
        let setOff = now.timeIntervalSince(timetable.base)
        let stops = change.stops.compactMap { stop -> Change? in
            guard let off = soonest(timetable, from: selection.stopIDs, routes: selection.routes, after: setOff,
                                    to: Set(stop.arrivalStops(for: selection))) else { return stop }
            var stop = stop
            let boards = stop.departureStops(for: selection)
            stop.routes = stop.routes.filter { route in
                boards.contains { board in
                    timetable.calls(at: board).contains { pattern, call in
                        call < timetable.patterns[pattern].calls.count - 1 && self.route(timetable, pattern) == route
                            && departure(timetable, pattern: pattern, call: call, after: off.arrives) != nil
                    }
                }
            }
            return stop.routes.isEmpty ? nil : stop
        }
        return Change(stops: stops)?.validated(for: selection)
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
