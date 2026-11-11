import CoreLocation
import Foundation

/// The next buses by the timetable (`TimetableStore.buses`), for when Bus Time can't be reached:
/// each a `BusArrival` with only its `aimed` time, as Bus Time sends
/// for a bus yet to leave its terminal, so it's drawn as scheduled. The timetable's routes are
/// a line each way it goes, "B63\tPIER 6 BKLYN BRIDGE PK", and its stops have their places.
enum BusSchedule {
    /// How far from where it's asked a stop of the line can be: the server's is the stop itself.
    private static let stopReach = 150.0
    /// How far Nearby looks for stops, as the server does: a quarter mile.
    private static let nearbyReach = 400.0
    /// How far apart a stop and the one across from it can be, to be one place.
    private static let acrossReach = 90.0
    /// How far ahead buses are listed.
    private static let ahead: TimeInterval = 2 * 60 * 60

    /// The next buses on `line` at its nearest stop to `place`, soonest first; nil without the
    /// timetable or a stop of the line near enough.
    static func times(line: String, at place: BusRide.Place, now: Date = AppClock.now) -> BusStopTimes? {
        guard let timetable = TimetableStore.buses.load(now: now), let places = timetable.places else { return nil }
        let wanted = BusRoutes.key(line)
        let here = place.location
        let nearest = stops(near: here, within: stopReach, in: places)
            .first { lines(at: $0.index, in: timetable).contains(wanted) }
        guard let nearest else { return nil }
        let arrivals = Self.arrivals(at: nearest.index, in: timetable, now: now).filter { BusRoutes.key($0.line) == wanted }
        return BusStopTimes(stop: stop(nearest.index, in: timetable, places: places), arrivals: arrivals)
    }

    /// The bus places near `location`, nearest first, as `NearbyBuses.places` has the server's:
    /// each a stop and the nearest across from it that shares a line, with every line's next
    /// buses; nil without the timetable.
    static func places(near location: CLLocation, limit: Int = 6, now: Date = AppClock.now) -> [NearbyBusPlace]? {
        guard let timetable = TimetableStore.buses.load(now: now), let places = timetable.places else { return nil }
        var left = stops(near: location, within: nearbyReach, in: places)
        var found: [NearbyBusPlace] = []
        while let first = left.first, found.count < limit {
            left.removeFirst()
            let lines = lines(at: first.index, in: timetable)
            guard !lines.isEmpty else { continue }
            let firstPlace = places[first.index].location
            let across = left.firstIndex { other in
                places[other.index].location.distance(from: firstPlace) <= acrossReach
                    && !lines.isDisjoint(with: self.lines(at: other.index, in: timetable))
            }
            var ways = [first]
            if let across { ways.append(left.remove(at: across)) }
            found.append(NearbyBuses.place(ways.map { way in
                NearbyBuses.Way(stop: stop(way.index, in: timetable, places: places), meters: way.meters,
                                arrivals: arrivals(at: way.index, in: timetable, now: now))
            }))
        }
        return found
    }

    /// The stops within `reach` of `location`, nearest first, by their index.
    private static func stops(near location: CLLocation, within reach: Double,
                              in places: [Timetable.Place]) -> [(index: Int, meters: Double)] {
        // A box first, then the distance: some 13,000 stops
        let latitude = location.coordinate.latitude, longitude = location.coordinate.longitude
        let dLat = reach / 111_000, dLon = reach / (111_000 * cos(latitude * .pi / 180))
        return places.indices.compactMap { index -> (index: Int, meters: Double)? in
            let place = places[index]
            guard abs(place.latitude - latitude) <= dLat, abs(place.longitude - longitude) <= dLon else { return nil }
            let meters = place.location.distance(from: location)
            return meters <= reach ? (index, meters) : nil
        }
        .sorted { $0.meters < $1.meters }
    }

    /// The lines (`BusRoutes.key`) with buses leaving stop `index`: not where it's their last.
    private static func lines(at index: Int, in timetable: Timetable) -> Set<String> {
        Set(timetable.calls(at: timetable.stops[index]).compactMap { pattern, call in
            let calls = timetable.patterns[pattern].calls
            return call < calls.count - 1 ? BusRoutes.key(route(of: pattern, in: timetable).line) : nil
        })
    }

    /// Every line's buses leaving stop `index` within `ahead` of `now`, soonest first: not those
    /// ending there.
    private static func arrivals(at index: Int, in timetable: Timetable, now: Date) -> [BusArrival] {
        let id = timetable.stops[index]
        return timetable.arrivals(at: [id], from: now, to: now.addingTimeInterval(ahead))
            .filter { $0.lastStop != id }
            .compactMap { arrival -> BusArrival? in
                // "timetable <pattern> <start>", as `Timetable` names its trips
                guard let pattern = arrival.trip.split(separator: " ").dropFirst().first.flatMap({ Int($0) }),
                      timetable.patterns.indices.contains(pattern) else { return nil }
                let route = route(of: pattern, in: timetable)
                return BusArrival(line: route.line, destination: route.headsign, expected: nil, aimed: arrival.time)
            }
            .sorted { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
    }

    /// Pattern `index`'s line and where it's going, from its route's "B63\tPIER 6 ...".
    private static func route(of index: Int, in timetable: Timetable) -> (line: String, headsign: String?) {
        let route = timetable.routes[Int(timetable.patterns[index].route)]
        let parts = route.split(separator: "\t", maxSplits: 1)
        return (String(parts.first ?? ""), parts.count > 1 ? String(parts[1]) : nil)
    }

    private static func stop(_ index: Int, in timetable: Timetable, places: [Timetable.Place]) -> BusStop {
        let place = places[index]
        return BusStop(id: timetable.stops[index], name: place.name, latitude: place.latitude, longitude: place.longitude)
    }
}

extension Timetable.Place {
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}
