import CoreLocation
import MapKit

/// New Trip's trips with a Citi Bike (`BikeTrip`): riding from a dock near the start to one near
/// the end, to a dock by a station further along and the train from there, or the train to a
/// station and a bike from a dock by it. Docks are picked by what they have now: of the few
/// nearest each end with a bike of the kind asked for to take, or a free dock to leave it in,
/// those soonest there, however few (the trip says so where they're few, `CitiBike.few`).
/// Trains are timed by the
/// timetable (`TripPlanner`); the rides of those offered by Apple Maps' cycling directions.
enum BikePlanner {
    /// Unlocking a bike and docking it again.
    private static let dockSeconds: TimeInterval = 2 * 60
    /// An e-bike's ride, of a classic bike's: Citi Bike's assist goes to 18 mph.
    private static let eBikeFactor = 0.7
    /// Meters a second a ride's guessed at, as the crow flies, before Apple Maps times it: about
    /// 8 mph on a classic bike, plus 30% for streets.
    private static let guessSpeed = 3.6
    /// The longest ride to or from a train.
    private static let longestRide: TimeInterval = 20 * 60
    /// The longest ride all the way.
    private static let longestRideAllTheWay: TimeInterval = 60 * 60
    /// Meters a dock may be from the station it's ridden to or from.
    private static let dockReach: Double = 350
    /// Meters a station may be from the start (or end) to bike to it (or from it) rather than walk.
    private static let leastRide: Double = 700
    /// Meters from a station biked to or from its platforms may be, joined stations and all: that
    /// station's trains, not those of others a walk from it.
    private static let stationReach: Double = 150
    /// Stations tried for each way with a train, the likeliest first.
    private static let tried = 8
    /// Trips offered each way with a train.
    private static let offered = 2
    /// Meters a second a train trip's guessed at, waits and all, to pick stations to try.
    private static let guessTrainSpeed = 7.0
    /// Docks tried at each end of a ride, the nearest first.
    private static let docksTried = 3

    /// A trip found, before its ride's timed along the streets.
    private struct Found {
        var pickup: CitiBike.Dock
        var dropoff: CitiBike.Dock
        var train: TripPlanner.Trip?
        var bikeFirst: Bool
        /// The station biked to, or from.
        var station: CLLocation?
        /// When it gets there, in seconds from now.
        var arrives: TimeInterval
        /// The trip found (its index) this is the same as from or to a fuller dock
        /// (`BikeTrip.dockChoices`); nil for one found itself.
        var fullerFor: Int?
    }

    /// Trips from `start` to `end` with a bike of `kind`, soonest there first: all the way, and
    /// with the subway too if `subway`. None walks more than `walkRange` to or from a dock (or a
    /// train). None if Citi Bike's feed can't be had.
    static func plan(from start: CLLocation, to end: CLLocation, kind: CitiBike.Kind, subway: Bool,
                     walkRange: Double, at now: Date = .now) async -> [BikeTrip] {
        guard let docks = await CitiBike.docks() else { return [] }
        let timetable = subway ? TimetableStore.load(now: now) : nil
        let pickups = docksToTry(docks, near: start, within: walkRange) { $0.available(kind) }
        let dropoffs = docksToTry(docks, near: end, within: walkRange) { $0.free }

        var found: [Found] = []
        // All the way
        if let best = soonest(pickups, dropoffs, kind: kind, longest: longestRideAllTheWay, seconds: { pickup, dropoff, ride in
            allTheWay(start, end, pickup, dropoff, ride: ride)
        }) {
            found.append(Found(pickup: best.pickup, dropoff: best.dropoff, bikeFirst: true, arrives: best.seconds))
        }
        if let timetable {
            // Both ways at once
            async let first = pickups.isEmpty ? [] : bikeFirst(from: start, to: end, pickups: pickups, docks: docks, kind: kind,
                                                               walkRange: walkRange, now: now, timetable: timetable)
            async let after = dropoffs.isEmpty ? [] : trainFirst(from: start, to: end, dropoffs: dropoffs, docks: docks, kind: kind,
                                                                 walkRange: walkRange, now: now, timetable: timetable)
            found += await first + after
        }
        // Where one's short, the same from or to the fuller dock nearest, timed alongside
        for index in found.indices {
            found += fuller(found[index], docks: docks, kind: kind, start: start, end: end, walkRange: walkRange)
                .map { other in
                    var other = other
                    other.fullerFor = index
                    return other
                }
        }

        // Each ride along the streets, all asked for at once
        let rides = await withTaskGroup(of: (Int, (points: [Walk.Point], seconds: TimeInterval)?).self) { group in
            for (index, trip) in found.enumerated() {
                group.addTask { (index, await route(from: trip.pickup.coordinate, to: trip.dropoff.coordinate, kind: kind)) }
            }
            var rides: [Int: (points: [Walk.Point], seconds: TimeInterval)] = [:]
            for await (index, ride) in group {
                if let ride { rides[index] = ride }
            }
            return rides
        }

        let timed = found.indices.map { index -> BikeTrip in
            let trip = found[index]
            let ride = rides[index]?.seconds ?? guess(from: trip.pickup, to: trip.dropoff, kind: kind)
            let points = rides[index]?.points ?? [Walk.Point(trip.pickup.coordinate), Walk.Point(trip.dropoff.coordinate)]
            var arrives = trip.arrives
            if let train = trip.train, let station = trip.station {
                if trip.bikeFirst {
                    // The train again, from when you're there by the ride as timed
                    let there = walkSeconds(start, trip.pickup.location) + dockSeconds + ride
                        + walkSeconds(trip.dropoff.location, station)
                    if let timetable, let arrival = TripPlanner.arrival(of: train, from: station, to: end,
                                                                        at: now.addingTimeInterval(there), timetable: timetable) {
                        arrives = arrival.timeIntervalSince(now)
                    }
                } else {
                    let guessed = guess(from: trip.pickup, to: trip.dropoff, kind: kind)
                    arrives += ride - guessed
                }
            } else {
                arrives = allTheWay(start, end, trip.pickup, trip.dropoff, ride: ride)
            }
            return BikeTrip(kind: kind, pickup: trip.pickup, dropoff: trip.dropoff, path: points,
                            rideMinutes: Int(((dockSeconds + ride) / 60).rounded()),
                            train: trip.train?.option, bikeFirst: trip.bikeFirst,
                            minutes: Int((arrives / 60).rounded(.up)))
        }
        // Each found with its fuller docks to switch to, if any
        let trips = found.indices.filter { found[$0].fullerFor == nil }.map { index in
            var trip = timed[index]
            let others = found.indices.filter { found[$0].fullerFor == index }.map { timed[$0] }
            if !others.isEmpty { trip.dockChoices = [trip] + others }
            return trip
        }
        return trips.sorted { $0.minutes < $1.minutes }
    }

    /// `found` from or to the fuller dock nearest (`CitiBike.few` or more) where its own is short,
    /// and from and to both where both are: in reach as its own are, its ride no longer, and when
    /// it gets there moved by the walks and ride it changes.
    private static func fuller(_ found: Found, docks: [CitiBike.Dock], kind: CitiBike.Kind,
                               start: CLLocation, end: CLLocation, walkRange: Double) -> [Found] {
        // Where the bike's taken from near, and left near, and how far from there a dock may be
        let from = found.bikeFirst ? (place: start, reach: walkRange) : (place: found.station ?? start, reach: dockReach)
        let to = found.train == nil || !found.bikeFirst ? (place: end, reach: walkRange)
            : (place: found.station ?? end, reach: dockReach)
        func nearestFuller(to area: (place: CLLocation, reach: Double), count: (CitiBike.Dock) -> Int) -> CitiBike.Dock? {
            docks.map { ($0, area.place.distance(from: $0.location)) }
                .filter { $0.1 <= area.reach && count($0.0) >= CitiBike.few }
                .min { $0.1 < $1.1 }?.0
        }
        let pickup = found.pickup.available(kind) < CitiBike.few ? nearestFuller(to: from) { $0.available(kind) } : nil
        let dropoff = found.dropoff.free < CitiBike.few ? nearestFuller(to: to) { $0.free } : nil
        var pairs: [(pickup: CitiBike.Dock, dropoff: CitiBike.Dock)] = []
        if let pickup { pairs.append((pickup, found.dropoff)) }
        if let dropoff { pairs.append((found.pickup, dropoff)) }
        if let pickup, let dropoff { pairs.append((pickup, dropoff)) }
        // The walks to and from the bike and its ride, which a fuller dock changes
        func legs(_ trip: Found) -> TimeInterval {
            walkSeconds(from.place, trip.pickup.location) + dockSeconds + guess(from: trip.pickup, to: trip.dropoff, kind: kind)
                + walkSeconds(trip.dropoff.location, to.place)
        }
        let longest = found.train == nil ? longestRideAllTheWay : longestRide
        return pairs.compactMap { pair in
            guard pair.pickup.id != pair.dropoff.id,
                  guess(from: pair.pickup, to: pair.dropoff, kind: kind) <= longest else { return nil }
            var other = found
            other.pickup = pair.pickup
            other.dropoff = pair.dropoff
            other.arrives = found.arrives - legs(found) + legs(other)
            return other
        }
    }

    /// Bike to a station further along, then the train: from the stations a ride away, each with
    /// a free dock by it, those likeliest soonest there tried, the best `offered` each by
    /// different lines.
    private static func bikeFirst(from start: CLLocation, to end: CLLocation, pickups: [CitiBike.Dock],
                                  docks: [CitiBike.Dock], kind: CitiBike.Kind, walkRange: Double,
                                  now: Date, timetable: Timetable) -> [Found] {
        let straight = start.distance(from: end)
        let candidates = Nearby.stations(near: start, limit: 40).compactMap { near -> (Found, Station, Double)? in
            let location = near.station.location
            guard near.meters >= leastRide, location.distance(from: end) < straight - 300,
                  let best = soonest(pickups, docksToTry(docks, near: location, within: dockReach) { $0.free }, kind: kind,
                                     longest: longestRide, seconds: { pickup, dropoff, ride in
                                         walkSeconds(start, pickup.location) + dockSeconds + ride + walkSeconds(dropoff.location, location)
                                     }) else { return nil }
            let found = Found(pickup: best.pickup, dropoff: best.dropoff, bikeFirst: true, station: location, arrives: best.seconds)
            return (found, near.station, best.seconds + location.distance(from: end) / guessTrainSpeed)
        }
        var trips: [Found] = []
        for (found, station, _) in candidates.sorted(by: { $0.2 < $1.2 }).prefix(tried) {
            guard let location = found.station else { continue }
            let at = now.addingTimeInterval(found.arrives)
            let best = TripPlanner.plan(from: location, to: end, at: at, timetable: timetable, walkRange: walkRange,
                                        startRange: stationReach)
                .filter { $0.selection.station?.complex == station.complex }
                .compactMap { trip in
                    TripPlanner.arrival(of: trip, from: location, to: end, at: at, timetable: timetable)
                        .map { (trip, $0.timeIntervalSince(now)) }
                }
                .min { $0.1 < $1.1 }
            guard let best else { continue }
            var trip = found
            trip.train = best.0
            trip.arrives = best.1
            trips.append(trip)
        }
        return bestByLines(trips)
    }

    /// The train to a station short of the end, then a bike from a dock by it: as `bikeFirst`,
    /// the other way round.
    private static func trainFirst(from start: CLLocation, to end: CLLocation, dropoffs: [CitiBike.Dock],
                                   docks: [CitiBike.Dock], kind: CitiBike.Kind, walkRange: Double,
                                   now: Date, timetable: Timetable) -> [Found] {
        let straight = start.distance(from: end)
        let candidates = Nearby.stations(near: end, limit: 40).compactMap { near -> (Found, Station, Double)? in
            let location = near.station.location
            guard near.meters >= leastRide, location.distance(from: start) < straight - 300,
                  let best = soonest(docksToTry(docks, near: location, within: dockReach) { $0.available(kind) }, dropoffs,
                                     kind: kind, longest: longestRide, seconds: { pickup, dropoff, ride in
                                         walkSeconds(location, pickup.location) + dockSeconds + ride + walkSeconds(dropoff.location, end)
                                     }) else { return nil }
            let found = Found(pickup: best.pickup, dropoff: best.dropoff, bikeFirst: false, station: location, arrives: best.seconds)
            return (found, near.station, start.distance(from: location) / guessTrainSpeed + best.seconds)
        }
        var trips: [Found] = []
        for (found, station, _) in candidates.sorted(by: { $0.2 < $1.2 }).prefix(tried) {
            guard let location = found.station else { continue }
            let best = TripPlanner.plan(from: start, to: location, at: now, timetable: timetable, walkRange: walkRange,
                                        endRange: stationReach)
                .filter { ($0.change?.destination ?? $0.destination).complex == station.complex }
                .compactMap { trip in
                    TripPlanner.arrival(of: trip, from: start, to: location, at: now, timetable: timetable)
                        .map { (trip, $0.timeIntervalSince(now)) }
                }
                .min { $0.1 < $1.1 }
            guard let best else { continue }
            var trip = found
            trip.train = best.0
            // Then the walk to the dock, the ride and the walk to the end
            trip.arrives = best.1 + found.arrives
            trips.append(trip)
        }
        return bestByLines(trips)
    }

    /// The soonest `offered` of `trips`, each by different lines.
    private static func bestByLines(_ trips: [Found]) -> [Found] {
        var seen = Set<String>()
        return trips.sorted { $0.arrives < $1.arrives }
            .filter { seen.insert($0.train.map { "\($0.selection.routes) \($0.change?.routes ?? [])" } ?? "").inserted }
            .prefix(offered)
            .map { $0 }
    }

    /// The docks within `meters` of `location` to try, nearest first: the `docksTried` nearest
    /// with any of what `count` counts (bikes to take, or free docks), however few.
    private static func docksToTry(_ docks: [CitiBike.Dock], near location: CLLocation, within meters: Double,
                                   count: (CitiBike.Dock) -> Int) -> [CitiBike.Dock] {
        docks.compactMap { dock -> (dock: CitiBike.Dock, meters: Double)? in
            let distance = location.distance(from: dock.location)
            return distance <= meters && count(dock) > 0 ? (dock, distance) : nil
        }
        .sorted { $0.meters < $1.meters }
        .prefix(docksTried).map(\.dock)
    }

    /// Of each of `pickups` to each of `dropoffs`, the pair soonest there by `seconds` (given
    /// the pickup, the dropoff and the ride's guessed seconds), its ride no longer than `longest`.
    private static func soonest(_ pickups: [CitiBike.Dock], _ dropoffs: [CitiBike.Dock], kind: CitiBike.Kind,
                                longest: TimeInterval,
                                seconds: (CitiBike.Dock, CitiBike.Dock, TimeInterval) -> TimeInterval)
        -> (pickup: CitiBike.Dock, dropoff: CitiBike.Dock, seconds: TimeInterval)? {
        var best: (pickup: CitiBike.Dock, dropoff: CitiBike.Dock, seconds: TimeInterval)?
        for pickup in pickups {
            for dropoff in dropoffs where dropoff.id != pickup.id {
                let ride = guess(from: pickup, to: dropoff, kind: kind)
                guard ride <= longest else { continue }
                let total = seconds(pickup, dropoff, ride)
                if total < best?.seconds ?? .infinity { best = (pickup, dropoff, total) }
            }
        }
        return best
    }

    /// Seconds door to door riding all the way.
    private static func allTheWay(_ start: CLLocation, _ end: CLLocation, _ pickup: CitiBike.Dock,
                                  _ dropoff: CitiBike.Dock, ride: TimeInterval) -> TimeInterval {
        walkSeconds(start, pickup.location) + dockSeconds + ride + walkSeconds(dropoff.location, end)
    }

    private static func walkSeconds(_ a: CLLocation, _ b: CLLocation) -> TimeInterval {
        TripPlanner.walkSeconds(a.distance(from: b))
    }
    /// A ride's seconds guessed from how far apart its docks are, to pick what to time.
    private static func guess(from pickup: CitiBike.Dock, to dropoff: CitiBike.Dock, kind: CitiBike.Kind) -> TimeInterval {
        pickup.location.distance(from: dropoff.location) * 1.3 / guessSpeed * (kind == .eBike ? eBikeFactor : 1)
    }

    /// Apple Maps' cycling route between two docks, and its seconds, quicker on an e-bike;
    /// nil if it has none.
    private static func route(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
                              kind: CitiBike.Kind) async -> (points: [Walk.Point], seconds: TimeInterval)? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: start.latitude, longitude: start.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: end.latitude, longitude: end.longitude), address: nil)
        request.transportType = .cycling
        guard let route = try? await MKDirections(request: request).calculate().routes.first else { return nil }
        let polyline = route.polyline
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return (coordinates.map(Walk.Point.init),
                route.expectedTravelTime * (kind == .eBike ? eBikeFactor : 1))
    }
}

private extension Station {
    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
}
