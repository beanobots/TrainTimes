import Foundation

// Timing a planned trip (`PlannedTrip`) for the widgets: each first train or bus is followed
// through every ride of every way, each ride a train or a bus, at whichever of each change's
// places gets there soonest. Trains by their trip in the feeds (or the timetable), buses by Bus
// Time where they're boarded and the timetable's minutes on (Bus Time has no times further on).
// The result is a change board (`Connection`, `Way`), so the boards draw it as any other.
// Not the push server's: it doesn't build Bus Time.

enum PlannedTrips {
    /// Trains and buses at every place the trip boards or leaves one.
    struct Times: Sendable {
        /// Soonest first.
        var trains: [Arrival]
        /// By `busKey`.
        var buses: [String: [BusArrival]]
    }

    /// How a bus boarded at a stop is found among the times.
    static func busKey(_ leg: BusLeg) -> String { "\(BusRoutes.key(leg.line)) \(leg.stop.id)" }

    private static func allRides(_ trip: PlannedTrip) -> [PlannedRide] {
        trip.ways.flatMap { $0.rides.joined() }
    }

    /// Every train line ridden.
    static func trainRoutes(_ trip: PlannedTrip) -> [String] {
        var routes: [String] = []
        for route in allRides(trip).compactMap(\.train).flatMap(\.routes) where !routes.contains(route) {
            routes.append(route)
        }
        return routes
    }

    /// Feed stops where trains are boarded or left, and at the destination: each a station's
    /// complex, both ways.
    static func trainStops(_ trip: PlannedTrip) -> Set<String> {
        var stations = allRides(trip).compactMap { $0.train?.station }
        stations += allRides(trip).compactMap { $0.offStationID.flatMap(StationDirectory.station(id:)) }
        if let destination = trip.destinationID.flatMap(StationDirectory.station(id:)) { stations.append(destination) }
        return Set(stations.flatMap(StationDirectory.stops(inComplexOf:)))
    }

    /// The trains and buses `trip` needs, from the feeds and Bus Time; nil if no train feed could
    /// be reached where trains are ridden.
    static func fetch(_ trip: PlannedTrip, now: Date = .now) async -> Times? {
        let routes = trainRoutes(trip)
        let stops = trainStops(trip)
        let buses = Array(Set(allRides(trip).compactMap(\.bus)))
        async let busTimes = withTaskGroup(of: (String, [BusArrival]).self) { group in
            for leg in buses {
                group.addTask {
                    let place = BusRide.Place(name: leg.stopName, latitude: leg.stop.latitude, longitude: leg.stop.longitude)
                    let times = await BusTimes.arrivals(lines: [leg.line], at: place, onlyAt: leg.stop.id, now: now)
                    return (busKey(leg), times?.arrivals ?? [])
                }
            }
            var found: [String: [BusArrival]] = [:]
            for await (key, arrivals) in group { found[key] = arrivals }
            return found
        }
        var trains: [Arrival] = []
        if !routes.isEmpty {
            let feeds = Lines.feedURLs(sharingTracksWith: routes)
            let part = FeedPart(stops: stops)
            let own = await withTaskGroup(of: Data?.self) { group in
                for url in feeds.own { group.addTask { await TrainService.optionalData(from: url, part: part) } }
                var all: [Data] = []
                for await data in group { if let data { all.append(data) } }
                return all
            }
            guard !own.isEmpty else { return nil }
            trains = ((try? TrainService.arrivals(at: stops, own: own, others: [], now: now)) ?? [])
                .sorted { $0.time < $1.time }
        }
        return Times(trains: trains, buses: await busTimes)
    }

    /// `trip`'s trains from `timetable`, for when the feeds can't be reached; no buses.
    static func times(_ trip: PlannedTrip, from timetable: Timetable, now: Date = .now) -> Times {
        let trains = timetable.arrivals(at: trainStops(trip), from: now, to: now.addingTimeInterval(3 * 3600))
            .sorted { $0.time < $1.time }
        return Times(trains: trains, buses: [:])
    }

    // MARK: Following

    /// The first rides from the start still to come after `now`: its trains or buses there.
    static func firsts(_ trip: PlannedTrip, times: Times, now: Date) -> [Arrival] {
        guard let start = trip.start else { return [] }
        if let bus = start.bus {
            return (times.buses[busKey(bus)] ?? []).compactMap { arrival -> Arrival? in
                guard let time = arrival.time, time > now else { return nil }
                return Arrival(route: bus.route, time: time, stop: BusLeg.prefix + bus.stop.id, lastStop: "",
                               isLive: arrival.isLive)
            }
        }
        guard let train = start.train else { return [] }
        // Every way's first lines from the start
        let lines = Set(trip.ways.compactMap { $0.rides.first?.first?.train?.routes }.joined())
        var selection = train
        selection.routes = Array(lines)
        let stops = Set(selection.stopIDs)
        return times.trains.filter {
            stops.contains($0.stop) && lines.contains($0.route) && $0.leaves > now && !$0.endsHere
        }.oncePerTrip()
    }

    /// Each of `trip`'s first rides with its ways on, each way's soonest there (`Way`, with its
    /// second change as `Way.then`); the connection is its soonest way's.
    static func connections(_ trip: PlannedTrip, times: Times, now: Date) -> [Connection] {
        firsts(trip, times: times, now: now).prefix(8).map { first in
            var ways: [Way] = []
            for way in trip.ways where way.rides.first?.first?.routes.contains(first.route) == true {
                if let found = follow(way, from: first, times: times) { ways.append(found) }
            }
            ways.sort { ($0.arrival?.time ?? .distantFuture) < ($1.arrival?.time ?? .distantFuture) }
            guard var connection = ways.first?.connection else {
                // Straight there, or nothing on predicted: the ride itself
                return Connection(first: first, arrival: ways.first?.arrival ?? first, next: ways.first?.arrival,
                                  ways: ways)
            }
            connection.ways = ways
            return connection
        }
    }

    /// One step of a way followed: off a ride, onto the next.
    private struct Step {
        var off: Arrival
        var on: Arrival
        var walk: TimeInterval
        var place: String
        var stationID: String?
    }

    /// `way` followed from `first`: at each change, the place whose next ride gets there soonest.
    /// Nil if it can't be followed to the end with the times there are.
    private static func follow(_ way: PlannedWay, from first: Arrival, times: Times) -> Way? {
        guard let start = way.rides.first?.first,
              let (steps, end) = best(way, ride: 0, spec: start, boarded: first, times: times) else { return nil }
        guard let firstStep = steps.first else {
            return Way(route: first.route, connection: nil, arrival: end)
        }
        let connection = Connection(first: first, arrival: firstStep.off, next: firstStep.on, walk: firstStep.walk,
                                    stationID: firstStep.stationID, place: firstStep.place)
        var found = Way(route: firstStep.on.route, connection: connection, arrival: end)
        if steps.count > 1 {
            let second = steps[1]
            found.then = Connection(first: firstStep.on, arrival: second.off, next: second.on, walk: second.walk,
                                    stationID: second.stationID, place: second.place)
        }
        return found
    }

    /// From ride `index` (`spec`, boarded as `boarded`) to the end: the steps and the arrival.
    private static func best(_ way: PlannedWay, ride index: Int, spec: PlannedRide, boarded: Arrival,
                             times: Times) -> (steps: [Step], end: Arrival)? {
        guard index + 1 < way.rides.count else {
            return end(of: way, spec: spec, boarded: boarded, times: times).map { ([], $0) }
        }
        var best: (steps: [Step], end: Arrival)?
        for next in way.rides[index + 1] {
            guard let off = alight(spec, boarded: boarded, toward: next, times: times),
                  let (on, walk) = board(next, after: off, times: times),
                  let rest = self.best(way, ride: index + 1, spec: next, boarded: on, times: times) else { continue }
            if best.map({ rest.end.time < $0.end.time }) ?? true {
                let step = Step(off: off, on: on, walk: walk, place: next.changePlace,
                                stationID: next.train?.stationID)
                best = ([step] + rest.steps, rest.end)
            }
        }
        return best
    }

    /// Getting off ride `spec` (boarded as `boarded`) to change to `next`: a train's trip at the
    /// station it's left at; a bus at the stop it's left at, by the timetable's minutes there.
    private static func alight(_ spec: PlannedRide, boarded: Arrival, toward next: PlannedRide, times: Times) -> Arrival? {
        if let bus = spec.bus {
            guard let off = next.offStop, let minutes = busMinutes(bus, to: off) else { return nil }
            return Arrival(route: bus.route, time: boarded.time.addingTimeInterval(minutes * 60),
                           stop: BusLeg.prefix + off.id, lastStop: "", isLive: boarded.isLive)
        }
        guard let station = (next.offStationID ?? next.train?.stationID).flatMap(StationDirectory.station(id:)) else {
            return nil
        }
        let stops = StationDirectory.stops(inComplexOf: station)
        return times.trains.first { $0.trip == boarded.trip && !boarded.trip.isEmpty && stops.contains($0.stop)
            && $0.time >= boarded.time }
    }

    /// Getting on `spec` after getting off as `off`: its first train or bus you can catch after
    /// the walk (across the platform, as a change's), and the walk.
    private static func board(_ spec: PlannedRide, after off: Arrival, times: Times) -> (Arrival, TimeInterval)? {
        if let bus = spec.bus {
            let walk = TimeInterval(spec.walkMinutes * 60)
            let ready = off.time.addingTimeInterval(walk)
            guard let next = (times.buses[busKey(bus)] ?? []).first(where: { ($0.time ?? .distantPast) >= ready }),
                  let time = next.time else { return nil }
            return (Arrival(route: bus.route, time: time, stop: BusLeg.prefix + bus.stop.id, lastStop: "",
                            isLive: next.isLive), walk)
        }
        guard let train = spec.train else { return nil }
        let stops = Set(train.stopIDs)
        let lines = Set(train.routes)
        let offTrain = BusLeg.line(of: off.route) == nil
        for departure in times.trains where stops.contains(departure.stop) && lines.contains(departure.route)
            && departure.trip != off.trip && !departure.endsHere {
            if offTrain, Change.isAcross(off: off.route, at: off.stop, on: departure.route, at: departure.stop) {
                if Change.canCatchAcross(departure, off: off) { return (departure, 0) }
                continue
            }
            let minutes = offTrain ? Change.walkMinutes(from: off.stop, to: departure.stop, else: spec.walkMinutes)
                : spec.walkMinutes
            let walk = TimeInterval(minutes * 60)
            if departure.leaves >= off.time.addingTimeInterval(walk) { return (departure, walk) }
        }
        return nil
    }

    /// Getting there on the last ride `spec`: a train's trip at the destination; a bus at the
    /// stop near it by the timetable's minutes, then the walk on.
    private static func end(of way: PlannedWay, spec: PlannedRide, boarded: Arrival, times: Times) -> Arrival? {
        if let bus = spec.bus {
            guard let stop = way.endStop, let minutes = busMinutes(bus, to: stop) else { return nil }
            return Arrival(route: bus.route,
                           time: boarded.time.addingTimeInterval(minutes * 60 + TimeInterval(way.endWalk * 60)),
                           stop: BusLeg.prefix + stop.id, lastStop: "", isLive: boarded.isLive)
        }
        // Without a station to go to (to a bus stop), the train as boarded
        guard let destination = way.endStation else { return boarded }
        let stops = StationDirectory.stops(inComplexOf: destination)
        return times.trains.first { $0.trip == boarded.trip && !boarded.trip.isEmpty && stops.contains($0.stop)
            && $0.time >= boarded.time }
    }

    /// The timetable's minutes on `bus` from where it's boarded to `stop`; nil if it doesn't get there.
    static func busMinutes(_ bus: BusLeg, to stop: BusStop) -> Double? {
        BusRoutes.ahead(on: bus.line, from: bus.stop.id, toward: bus.destination).first { $0.stop.code == stop.id }?.minutes
    }
}

extension PlannedWay {
    /// The station a train ride ends at: where the trip goes, kept by `PlannedTrips` as the last
    /// ride's own. Set by the planner on every way that ends on a train.
    var endStation: Station? { endStationID.flatMap(StationDirectory.station(id:)) }
}

extension PlannedRide {
    /// Where it's changed to: the stop's name off a bus or onto one, else the station's.
    var changePlace: String {
        if let bus { return bus.stopName }
        if let stop = offStop { return BusNames.readable(stop.name) }
        return (offStationID ?? train?.stationID).flatMap(StationDirectory.station(id:))?.name ?? placeName
    }
}
