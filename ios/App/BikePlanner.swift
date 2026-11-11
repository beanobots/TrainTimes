import CoreLocation
import MapKit

/// New Trip's trips with a Citi Bike (`BikeTrip`): riding from a dock near the start to one near
/// the end, to a dock by a station further along and the train from there, or the train to a
/// station and a bike from a dock by it. Docks are picked by what they have now: of the few
/// nearest each end with a bike of the kind asked for to take, or a free dock to leave it in,
/// those soonest there, however few (the trip says so where they're few, `CitiBike.few`).
/// Trains are timed by the
/// timetable (`TripPlanner`); the rides of those offered by Apple Maps' cycling directions, and
/// none offered whose ride it has no route for (or only by ferry), or times too long.
enum BikePlanner {
    /// Unlocking a bike and docking it again.
    private static let dockSeconds: TimeInterval = 2 * 60
    /// An e-bike's ride, of a classic bike's: Citi Bike's assist goes to 18 mph.
    private static let eBikeFactor = 0.7
    /// Meters a second a ride's guessed at, as the crow flies, before Apple Maps times it: about
    /// 9 mph on a classic bike, plus 30% for streets. Apple Maps' cycling times of a dozen rides
    /// across the city came to 0.26 to 0.44 seconds a meter as the crow flies, 0.32 the middle.
    private static let guessSpeed = 4.1
    /// The longest ride to or from a train.
    private static let longestRide: TimeInterval = 20 * 60
    /// The longest ride all the way. Longer than Citi Bike's 45 minutes for members, past which
    /// it charges by the minute: chosen so.
    private static let longestRideAllTheWay: TimeInterval = 60 * 60
    /// Meters a dock may be from the station it's ridden to or from.
    private static let dockReach: Double = 350
    /// Meters a station may be from the start (or end) to bike to it (or from it) rather than walk,
    /// and from the end (or start) to take a train from it (or to it) rather than ride on.
    private static let leastRide: Double = 700
    /// Of how far a ride to (or from) a train goes, the least it's to bring you nearer the end
    /// (or take you from the start): a ride across to a line, not away from where you're going.
    private static let leastNearer = 0.5
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

    /// Why `planned` found no trip, for No Trip Found to say.
    enum NoBike: Hashable, Sendable {
        /// Riding all the way takes longer than `longestRideAllTheWay`; for a classic bike, about
        /// how long an e-bike's ride would be, if it's no longer.
        case rideTooLong(eBikeMinutes: Int?)
        /// No dock within your walk of the start with a bike, or of the end with room for one.
        case noDock(atStart: Bool)
        /// Apple Maps couldn't time the rides: throttling the app's asks, or out of reach.
        case maps(MapsTrouble)
    }

    /// Trips from `start` to `end` with a bike of `kind`, soonest there first: all the way, and
    /// with the subway too if `subway`. None walks more than `walkRange` to or from a dock (or a
    /// train). None if Citi Bike's feed can't be had.
    static func plan(from start: CLLocation, to end: CLLocation, kind: CitiBike.Kind, subway: Bool,
                     walkRange: Double, at now: Date = AppClock.now) async -> [BikeTrip] {
        await planned(from: start, to: end, kind: kind, subway: subway, walkRange: walkRange, at: now).trips
    }

    /// `plan`'s trips, and where there are none, why, if it's that there's no dock or the ride's
    /// too long.
    static func planned(from start: CLLocation, to end: CLLocation, kind: CitiBike.Kind, subway: Bool,
                        walkRange: Double, at now: Date = AppClock.now) async -> (trips: [BikeTrip], none: NoBike?) {
        guard let docks = await CitiBike.docks() else { return ([], nil) }
        let timetable = subway ? TimetableStore.load(now: now) : nil
        let pickups = docksToTry(docks, near: start, within: walkRange) { $0.available(kind) }
        let dropoffs = docksToTry(docks, near: end, within: walkRange) { $0.free }
        // The shortest ride all the way left out as too long, for saying so
        var tooLong: TimeInterval?

        var found: [Found] = []
        // All the way
        if let best = soonest(pickups, dropoffs, kind: kind, longest: longestRideAllTheWay, seconds: { pickup, dropoff, ride in
            let seconds = allTheWay(start, end, pickup, dropoff, ride: ride)
            return worthRiding(start, end, pickup, dropoff, seconds: seconds) ? seconds : nil
        }) {
            found.append(Found(pickup: best.pickup, dropoff: best.dropoff, bikeFirst: true, arrives: best.seconds))
        } else if let shortest = pickups.flatMap({ pickup in
            dropoffs.filter { $0.id != pickup.id }.map { guess(from: pickup, to: $0, kind: kind) }
        }).min(), shortest > longestRideAllTheWay {
            tooLong = shortest
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

        // Each ride along the streets, asked for together (`Routes`, a few at a time), and why
        // Apple Maps couldn't answer, if it failed any
        let (rides, trouble) = await withTaskGroup(of: (Int, Routes.Ride?, MapsTrouble?).self) { group in
            for (index, trip) in found.enumerated() {
                group.addTask {
                    let answer = await Routes.shared.ride(from: trip.pickup, to: trip.dropoff)
                    return (index, answer.ride, answer.trouble)
                }
            }
            var rides: [Int: Routes.Ride] = [:]
            var trouble: MapsTrouble?
            for await (index, ride, failed) in group {
                if let ride { rides[index] = ride }
                trouble = trouble ?? failed
            }
            return (rides, trouble)
        }

        // Each with its ride timed, but none Apple Maps had no route for: a guess across the
        // river isn't a ride. Nor any timed longer than it may be, or no better than walking
        let timed = found.indices.reduce(into: [Int: BikeTrip]()) { timed, index in
            let trip = found[index]
            guard let route = rides[index] else { return }
            let ride = route.seconds * (kind == .eBike ? eBikeFactor : 1)
            guard ride <= (trip.train == nil ? longestRideAllTheWay : longestRide) else {
                if trip.train == nil { tooLong = min(tooLong ?? ride, ride) }
                return
            }
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
                guard worthRiding(start, end, trip.pickup, trip.dropoff, seconds: arrives) else { return }
            }
            timed[index] = BikeTrip(kind: kind, pickup: trip.pickup, dropoff: trip.dropoff, path: route.points,
                                    rideMinutes: Int(((dockSeconds + ride) / 60).rounded()),
                                    protectedShare: BikeLanes.protectedShare(of: route.points),
                                    train: trip.train?.option, bikeFirst: trip.bikeFirst,
                                    minutes: Int((arrives / 60).rounded(.up)))
        }
        // Each found with its fuller docks to switch to, if any; none whose own ride's left out
        let trips = found.indices.filter { found[$0].fullerFor == nil }.compactMap { index -> BikeTrip? in
            guard var trip = timed[index] else { return nil }
            let others = found.indices.filter { found[$0].fullerFor == index }.compactMap { timed[$0] }
            if !others.isEmpty { trip.dockChoices = [trip] + others }
            return trip
        }
        guard trips.isEmpty else { return (trips.sorted { $0.minutes < $1.minutes }, nil) }
        if pickups.isEmpty || dropoffs.isEmpty { return ([], .noDock(atStart: pickups.isEmpty)) }
        guard let tooLong else { return ([], trouble.map { .maps($0) }) }
        // An e-bike's ride the same way, unlocking and docking it too, where it's not too long
        let eBike = kind == .eBike ? nil : dockSeconds + tooLong * eBikeFactor
        return ([], .rideTooLong(eBikeMinutes: eBike.flatMap { $0 <= longestRideAllTheWay ? Int(($0 / 60).rounded()) : nil }))
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
            let walk = WalkReach.From(area.place)
            return docks.filter { area.place.distance(from: $0.location) <= area.reach && count($0) >= CitiBike.few }
                .compactMap { dock in walk.meters(to: dock.location).map { (dock, $0) } }
                .filter { $0.1 <= area.reach }
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
            guard found.train != nil || worthRiding(start, end, other.pickup, other.dropoff, seconds: other.arrives)
            else { return nil }
            return other
        }
    }

    /// Bike to a station further along, then the train: from the stations a ride away, not a
    /// ride from the end, and nearer it by `leastNearer` of the way there, each with a free dock
    /// by it, those likeliest soonest there tried, the best `offered` each by different lines.
    private static func bikeFirst(from start: CLLocation, to end: CLLocation, pickups: [CitiBike.Dock],
                                  docks: [CitiBike.Dock], kind: CitiBike.Kind, walkRange: Double,
                                  now: Date, timetable: Timetable) -> [Found] {
        let straight = start.distance(from: end)
        let candidates = Nearby.stations(near: start, limit: 40).compactMap { near -> (Found, Station, Double)? in
            let location = near.station.location
            let left = location.distance(from: end)
            guard near.meters >= leastRide, left >= leastRide, straight - left >= near.meters * leastNearer,
                  let best = soonest(pickups, docksToTry(docks, near: location, within: dockReach) { $0.free }, kind: kind,
                                     longest: longestRide, seconds: { pickup, dropoff, ride in
                                         walkSeconds(start, pickup.location) + dockSeconds + ride + walkSeconds(dropoff.location, location)
                                     }) else { return nil }
            let found = Found(pickup: best.pickup, dropoff: best.dropoff, bikeFirst: true, station: location, arrives: best.seconds)
            return (found, near.station, best.seconds + left / guessTrainSpeed)
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
            let gone = start.distance(from: location)
            guard near.meters >= leastRide, gone >= leastRide, straight - gone >= near.meters * leastNearer,
                  let best = soonest(docksToTry(docks, near: location, within: dockReach) { $0.available(kind) }, dropoffs,
                                     kind: kind, longest: longestRide, seconds: { pickup, dropoff, ride in
                                         walkSeconds(location, pickup.location) + dockSeconds + ride + walkSeconds(dropoff.location, end)
                                     }) else { return nil }
            let found = Found(pickup: best.pickup, dropoff: best.dropoff, bikeFirst: false, station: location, arrives: best.seconds)
            return (found, near.station, gone / guessTrainSpeed + best.seconds)
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

    /// The docks within a walk of `meters` from `location` to try, nearest first: the
    /// `docksTried` nearest with any of what `count` counts (bikes to take, or free docks),
    /// however few. None across the water but over a bridge you can walk (`WalkReach`).
    private static func docksToTry(_ docks: [CitiBike.Dock], near location: CLLocation, within meters: Double,
                                   count: (CitiBike.Dock) -> Int) -> [CitiBike.Dock] {
        let walk = WalkReach.From(location)
        return docks.compactMap { dock -> (dock: CitiBike.Dock, meters: Double)? in
            // The walk's never shorter than the crow flies, so only those that close are walked
            guard location.distance(from: dock.location) <= meters, count(dock) > 0,
                  let distance = walk.meters(to: dock.location), distance <= meters else { return nil }
            return (dock, distance)
        }
        .sorted { $0.meters < $1.meters }
        .prefix(docksTried).map(\.dock)
    }

    /// Of each of `pickups` to each of `dropoffs`, the pair soonest there by `seconds` (given
    /// the pickup, the dropoff and the ride's guessed seconds; nil for a pair not to take), its
    /// ride no longer than `longest`.
    private static func soonest(_ pickups: [CitiBike.Dock], _ dropoffs: [CitiBike.Dock], kind: CitiBike.Kind,
                                longest: TimeInterval,
                                seconds: (CitiBike.Dock, CitiBike.Dock, TimeInterval) -> TimeInterval?)
        -> (pickup: CitiBike.Dock, dropoff: CitiBike.Dock, seconds: TimeInterval)? {
        var best: (pickup: CitiBike.Dock, dropoff: CitiBike.Dock, seconds: TimeInterval)?
        for pickup in pickups {
            for dropoff in dropoffs where dropoff.id != pickup.id {
                let ride = guess(from: pickup, to: dropoff, kind: kind)
                guard ride <= longest, let total = seconds(pickup, dropoff, ride) else { continue }
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

    /// Whether riding all the way from `pickup` to `dropoff` is worth it: the walks to and from
    /// them together no more than half as far as straight there, so the ride's most of the way,
    /// and the trip (`seconds`) sooner than walking straight there. Not a block's ride the wrong
    /// way, nor any from where you're going.
    private static func worthRiding(_ start: CLLocation, _ end: CLLocation, _ pickup: CitiBike.Dock,
                                    _ dropoff: CitiBike.Dock, seconds: TimeInterval) -> Bool {
        start.distance(from: pickup.location) + dropoff.location.distance(from: end) <= start.distance(from: end) / 2
            && seconds < walkSeconds(start, end)
    }

    /// The walk from `a` to `b` (`WalkReach`); infinite if there's none, so it's never picked.
    private static func walkSeconds(_ a: CLLocation, _ b: CLLocation) -> TimeInterval {
        WalkReach.meters(from: a, to: b).map(TripPlanner.walkSeconds) ?? .infinity
    }
    /// A ride's seconds guessed from how far apart its docks are, to pick what to time.
    private static func guess(from pickup: CitiBike.Dock, to dropoff: CitiBike.Dock, kind: CitiBike.Kind) -> TimeInterval {
        pickup.location.distance(from: dropoff.location) * 1.3 / guessSpeed * (kind == .eBike ? eBikeFactor : 1)
    }

    /// Apple Maps' cycling routes between docks, each asked for once for both kinds (an e-bike's
    /// ride is a classic's, quicker) and kept a while for the next plan, a few asked at a time:
    /// Apple Maps throttles an app asking for many at once. Throttled, one's asked again once it
    /// says it'll stop (or after a second, then two), if that's within `longestWait`; one it
    /// failed otherwise is asked again once, after a second. None it couldn't answer is kept.
    private actor Routes {
        static let shared = Routes()
        static let log = AppLog(category: "BikeRoutes")

        /// A ride along the streets, dock to dock, and its seconds on a classic bike.
        struct Ride: Sendable {
            var points: [Walk.Point]
            var seconds: TimeInterval
        }
        /// What Apple Maps answered: a ride, none (or only by ferry), or nothing, failing, and
        /// why where it's throttling or out of reach.
        private enum Answer: Sendable {
            case ride(Ride)
            case none
            case failed(MapsTrouble?)
        }

        /// Asked at once, at most.
        private static let atOnce = 4
        /// Seconds a route's kept.
        private static let kept: TimeInterval = 10 * 60
        /// Seconds before asking again for one that failed, or was throttled with no time said
        /// till it stops: doubled each time it's throttled again.
        private static let retryAfter: TimeInterval = 1
        /// Seconds a ride may wait, all told, to be asked again: past that it's left out, so New
        /// Trip isn't kept waiting. Apple Maps' throttling lasts up to a minute.
        private static let longestWait: TimeInterval = 5

        private var known: [String: (at: Date, ride: Ride?)] = [:]
        /// Till when Apple Maps said it's throttling, for all asked: none's asked before, and none
        /// waits for it if it's past their `longestWait`.
        private var throttledUntil: Date?
        private var asking: [String: Task<Answer, Never>] = [:]
        private var busy = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []

        /// The ride from `pickup` to `dropoff`; nil if Apple Maps has none without a ferry, or
        /// couldn't answer, and then why, if it's throttling or out of reach (`trouble`).
        func ride(from pickup: CitiBike.Dock, to dropoff: CitiBike.Dock) async -> (ride: Ride?, trouble: MapsTrouble?) {
            let key = "\(pickup.id) \(dropoff.id)"
            if let known = known[key], Date.now.timeIntervalSince(known.at) < Self.kept { return (known.ride, nil) }
            let task = asking[key] ?? Task { await self.answer(from: pickup.location, to: dropoff.location) }
            asking[key] = task
            let answer = await task.value
            asking[key] = nil
            switch answer {
            case .ride(let ride):
                known[key] = (.now, ride)
                return (ride, nil)
            case .none:
                known[key] = (.now, nil)
                return (nil, nil)
            case .failed(let trouble):
                return (nil, trouble)
            }
        }

        private func answer(from start: CLLocation, to end: CLLocation) async -> Answer {
            let giveUp = Date.now.addingTimeInterval(Self.longestWait)
            var wait = Self.retryAfter
            var failed = false
            while true {
                // Not while throttled, nor at all if it's throttled too long
                if let until = throttledUntil, until > .now {
                    guard until <= giveUp else { return .failed(.busy) }
                    try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
                }
                await take()
                let request = MKDirections.Request()
                request.source = MKMapItem(location: start, address: nil)
                request.destination = MKMapItem(location: end, address: nil)
                request.transportType = .cycling
                request.requestsAlternateRoutes = true
                let routes: [MKRoute]
                do {
                    #if DEBUG
                    if let failure = Failing.shared.next(start, end) { throw failure }
                    #endif
                    routes = try await MKDirections(request: request).calculate().routes
                } catch MKError.directionsNotFound {
                    routes = []
                } catch let error as MKError where error.code == .loadingThrottled {
                    give()
                    let until = Date.now.addingTimeInterval(Self.timeUntilReset(error) ?? wait)
                    wait *= 2
                    throttledUntil = max(throttledUntil ?? until, until)
                    Self.log.notice("Throttled for \(Int(until.timeIntervalSinceNow.rounded())) s\(until <= giveUp ? ", asking again" : ", left out")")
                    guard until <= giveUp else { return .failed(.busy) }
                    continue
                } catch {
                    give()
                    // Once more if there's time: a server hiccup, or the network dropping out
                    Self.log.notice("Failed\(failed ? " again, left out" : ""): \(error.localizedDescription)")
                    guard !failed, Date.now.addingTimeInterval(Self.retryAfter) <= giveUp else {
                        return .failed(MapsTrouble(error))
                    }
                    failed = true
                    try? await Task.sleep(for: .seconds(Self.retryAfter))
                    continue
                }
                give()
                // Apple Maps' cycling directions may take a ferry (to Governors Island, or across
                // the Hudson): a ride that isn't, timed waits and all
                guard let route = routes.first(where: { !Self.takesFerry($0) }) else { return .none }
                let polyline = route.polyline
                var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
                polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
                return .ride(Ride(points: coordinates.map(Walk.Point.init), seconds: route.expectedTravelTime))
            }
        }

        /// Seconds till Apple Maps stops throttling, if it says: not documented, but a throttled
        /// error has GeoServices' own details, "timeUntilReset" among them (20 of a 60 s window).
        private static func timeUntilReset(_ error: MKError) -> TimeInterval? {
            let details = error.userInfo["MKErrorGEOErrorUserInfo"] as? [String: Any]
            return (details?["timeUntilReset"] as? NSNumber).map(\.doubleValue).map { max($0, 0) }
        }

        /// Whether `route` takes a ferry, by its words: MapKit says so only in its steps ("Take
        /// the … Ferry") and notices ("Ferry required."), in English as the app is.
        private static func takesFerry(_ route: MKRoute) -> Bool {
            route.advisoryNotices.contains { $0.localizedCaseInsensitiveContains("ferry") }
                || route.steps.contains { $0.instructions.localizedCaseInsensitiveContains("ferry") }
        }

        /// Waits for a turn to ask, `atOnce` at a time, and hands it on after.
        private func take() async {
            guard busy >= Self.atOnce else {
                busy += 1
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }
        private func give() {
            if waiting.isEmpty { busy -= 1 } else { waiting.removeFirst().resume() }
        }
    }

    #if DEBUG
    /// For trying how rides fare when Apple Maps fails: LEEWAY_FAIL_BIKE_ROUTES in the scheme's
    /// environment, "pairs,times,kind[,seconds]", makes the first `pairs` dock pairs asked for
    /// each fail their first `times` asks, `kind` being throttled, server or none (no route). With
    /// `seconds`, throttled as Apple Maps does: only for that long from the first, saying how
    /// long's left. Unset, nothing fails.
    private final class Failing: @unchecked Sendable {
        static let shared = Failing()

        private let pairs: Int
        private let times: Int
        private let code: MKError.Code
        private let seconds: Double?
        private let lock = NSLock()
        private var asked: [String: Int] = [:]
        private var first: Date?

        private init() {
            let parts = (ProcessInfo.processInfo.environment["LEEWAY_FAIL_BIKE_ROUTES"] ?? "").split(separator: ",")
            pairs = parts.first.flatMap { Int($0) } ?? 0
            times = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            code = switch parts.count > 2 ? parts[2] : "throttled" {
            case "server": .serverFailure
            case "none": .directionsNotFound
            default: .loadingThrottled
            }
            seconds = parts.count > 3 ? Double(parts[3]) : nil
        }

        /// The failure for this ask from `start` to `end`, if it's to fail.
        func next(_ start: CLLocation, _ end: CLLocation) -> Error? {
            let key = "\(start.coordinate.latitude) \(start.coordinate.longitude) \(end.coordinate.latitude) \(end.coordinate.longitude)"
            lock.lock()
            defer { lock.unlock() }
            guard asked[key] != nil || asked.count < pairs else { return nil }
            let count = asked[key, default: 0] + 1
            asked[key] = count
            guard count <= times else { return nil }
            let first = first ?? .now
            self.first = first
            let left = seconds.map { $0 - Date.now.timeIntervalSince(first) }
            guard left ?? 1 > 0 else { return nil }
            // As Apple Maps says it, GeoServices' details and all
            Routes.log.notice("LEEWAY_FAIL_BIKE_ROUTES: \(key) ask \(count) fails, \(code.rawValue)")
            return MKError(code, userInfo: ["MKErrorGEOError": -3,
                                            "MKErrorGEOErrorUserInfo": left.map { ["timeUntilReset": $0.rounded(.up)] } ?? [:]])
        }
    }
    #endif
}

/// Your own bike, picked in Settings' Biking: none, or the bike or e-bike New Trip rides in
/// place of a Citi Bike.
enum OwnBike: String, CaseIterable {
    case none
    case bike
    case eBike

    /// Where the pick is kept.
    static let key = "ownBike"

    /// The kind it rides as: an e-bike's quicker, as a Citi e-bike is.
    var kind: CitiBike.Kind? {
        switch self {
        case .none: nil
        case .bike: .bike
        case .eBike: .eBike
        }
    }
}

/// What your own bike does on a trip with a train, picked in Settings' Biking (With Transit):
/// never with one, taken on it, locked at the station ridden to, or each, the sooner offered.
enum BikeCarry: String, CaseIterable {
    case none
    case bring
    case leave
    case all

    /// Where the pick is kept.
    static let key = "bikeCarry"

    var name: String {
        switch self {
        case .none: "Don't Combine"
        case .bring: "Bring on Transit"
        case .leave: "Leave at Station"
        case .all: "All Combinations"
        }
    }

    /// Whether it's taken on the train, or may be left at the station.
    var brings: Bool { self == .bring || self == .all }
    var leaves: Bool { self == .leave || self == .all }
}

/// New Trip's trips on your own bike (`BikeTrip.owned`): from your door all the way, to a
/// station and locked there (`BikeCarry.leaves`), or taken on the train (`BikeCarry.brings`),
/// ridden again after it where the end's a ride from its last station, or ridden only after
/// a walk to a train. No docks to find, so none's short; rides timed as a Citi Bike's are.
extension BikePlanner {
    /// Finding somewhere to lock your bike at the station, and locking it.
    private static let lockSeconds: TimeInterval = TimeInterval(lockMinutes * 60)
    /// The same in minutes, as a trip says it.
    static let lockMinutes = 3
    /// Taking your bike into the station and onto the train, and out at the other end: the
    /// stairs and the service gate.
    private static let carrySeconds: TimeInterval = 2 * 60

    /// A trip on your own bike found, before its rides are timed along the streets.
    private struct OwnFound {
        var from: CitiBike.Dock
        var to: CitiBike.Dock
        var train: TripPlanner.Trip?
        var bikeFirst: Bool
        var carried: Bool
        /// The station ridden to (bike first) or from (train first).
        var station: CLLocation?
        /// A carried bike's ride after the train, from its last station to the end.
        var after: (from: CitiBike.Dock, to: CitiBike.Dock)?
        /// When it gets there, in seconds from now.
        var arrives: TimeInterval
    }

    /// Trips from `start` to `end` (`endName`) on your own bike of `kind`, soonest there first:
    /// all the way, and with the subway too if `subway`, as `carry` says. None walks more than
    /// `walkRange` to or from a train. Where there are none, why, if it's that Apple Maps couldn't
    /// time the rides (`NoBike.maps`).
    static func plannedOwn(from start: CLLocation, to end: CLLocation, endName: String, kind: CitiBike.Kind,
                           carry: BikeCarry, subway: Bool, walkRange: Double,
                           at now: Date = AppClock.now) async -> (trips: [BikeTrip], none: NoBike?) {
        let home = CitiBike.Dock.place("Start", start)
        let there = CitiBike.Dock.place(endName, end)
        var found: [OwnFound] = []
        // All the way, if it's more than a walk
        if start.distance(from: end) >= leastRide {
            found.append(OwnFound(from: home, to: there, bikeFirst: true, carried: false,
                                  arrives: guess(from: home, to: there, kind: kind)))
        }
        if subway, carry != .none, let timetable = TimetableStore.load(now: now) {
            if carry.leaves {
                found += ownBikeFirst(from: start, to: end, home: home, there: there, kind: kind, carried: false,
                                      walkRange: walkRange, now: now, timetable: timetable)
            }
            if carry.brings {
                found += ownBikeFirst(from: start, to: end, home: home, there: there, kind: kind, carried: true,
                                      walkRange: walkRange, now: now, timetable: timetable)
                found += ownTrainFirst(from: start, to: end, there: there, kind: kind, walkRange: walkRange,
                                       now: now, timetable: timetable)
            }
        }
        // Each ride along the streets, and a carried bike's ride after, asked for together
        let (rides, trouble) = await withTaskGroup(of: (Int, Bool, Routes.Ride?, MapsTrouble?).self) { group in
            for (index, trip) in found.enumerated() {
                group.addTask {
                    let answer = await Routes.shared.ride(from: trip.from, to: trip.to)
                    return (index, false, answer.ride, answer.trouble)
                }
                if let after = trip.after {
                    group.addTask {
                        let answer = await Routes.shared.ride(from: after.from, to: after.to)
                        return (index, true, answer.ride, answer.trouble)
                    }
                }
            }
            var rides: [Int: (ride: Routes.Ride?, after: Routes.Ride?)] = [:]
            var trouble: MapsTrouble?
            for await (index, isAfter, ride, failed) in group {
                if isAfter { rides[index, default: (nil, nil)].after = ride } else { rides[index, default: (nil, nil)].ride = ride }
                trouble = trouble ?? failed
            }
            return (rides, trouble)
        }
        let factor = kind == .eBike ? eBikeFactor : 1
        let timetable = subway ? TimetableStore.load(now: now) : nil
        let trips = found.indices.compactMap { index -> BikeTrip? in
            let trip = found[index]
            // None Apple Maps had no route for, nor any too long
            guard let route = rides[index]?.ride else { return nil }
            let ride = route.seconds * factor
            guard ride <= (trip.train == nil ? longestRideAllTheWay : longestRide) else { return nil }
            var afterRide: BikeTrip.Ride?
            var arrives = trip.arrives
            if let train = trip.train, let station = trip.station {
                if trip.bikeFirst {
                    // The train again, from when you're there by the ride as timed
                    let atStation = now.addingTimeInterval(ride + (trip.carried ? carrySeconds : lockSeconds))
                    if let after = trip.after {
                        guard let afterRoute = rides[index]?.after, afterRoute.seconds * factor <= longestRide,
                              let timetable,
                              let off = TripPlanner.arrival(of: train, from: station, to: after.from.location,
                                                            at: atStation, timetable: timetable) else { return nil }
                        let afterSeconds = afterRoute.seconds * factor
                        arrives = off.timeIntervalSince(now) + carrySeconds + afterSeconds
                        afterRide = BikeTrip.Ride(from: after.from, to: after.to, path: afterRoute.points,
                                                  minutes: Int((afterSeconds / 60).rounded()))
                    } else if let timetable,
                              let arrival = TripPlanner.arrival(of: train, from: station, to: end, at: atStation,
                                                                timetable: timetable) {
                        arrives = arrival.timeIntervalSince(now)
                    } else {
                        // No train timed from then: the guessed ride's arrival, by the real ride
                        arrives += ride - guess(from: trip.from, to: trip.to, kind: kind)
                    }
                } else {
                    arrives += ride - guess(from: trip.from, to: trip.to, kind: kind)
                }
            } else {
                arrives = ride
                // Not when walking's as quick
                guard arrives < walkSeconds(start, end) else { return nil }
            }
            return BikeTrip(kind: kind, pickup: trip.from, dropoff: trip.to, path: route.points,
                            rideMinutes: Int((ride / 60).rounded()), protectedShare: BikeLanes.protectedShare(of: route.points),
                            train: trip.train?.option, bikeFirst: trip.bikeFirst, minutes: Int((arrives / 60).rounded(.up)),
                            owned: true, carried: trip.carried, rideAfter: afterRide)
        }
        return (trips.sorted { $0.minutes < $1.minutes }, trips.isEmpty ? trouble.map { .maps($0) } : nil)
    }

    /// Your bike to a station further along, then the train: from the stations as `bikeFirst`
    /// picks them, locked there or `carried` on, and if carried, ridden again from its last
    /// station where the end's a ride from it. The best `offered` each by different lines.
    private static func ownBikeFirst(from start: CLLocation, to end: CLLocation, home: CitiBike.Dock,
                                     there: CitiBike.Dock, kind: CitiBike.Kind, carried: Bool, walkRange: Double,
                                     now: Date, timetable: Timetable) -> [OwnFound] {
        let straight = start.distance(from: end)
        let candidates = Nearby.stations(near: start, limit: 40).compactMap { near -> (OwnFound, Station, Double)? in
            let location = near.station.location
            let left = location.distance(from: end)
            let station = CitiBike.Dock.place(near.station.name, location)
            let ride = guess(from: home, to: station, kind: kind)
            guard near.meters >= leastRide, left >= leastRide, straight - left >= near.meters * leastNearer,
                  ride <= longestRide else { return nil }
            let arrives = ride + (carried ? carrySeconds : lockSeconds)
            let found = OwnFound(from: home, to: station, bikeFirst: true, carried: carried, station: location, arrives: arrives)
            return (found, near.station, arrives + left / guessTrainSpeed)
        }
        var trips: [OwnFound] = []
        for (found, station, _) in candidates.sorted(by: { $0.2 < $1.2 }).prefix(tried) {
            guard let location = found.station else { continue }
            let at = now.addingTimeInterval(found.arrives)
            let best = TripPlanner.plan(from: location, to: end, at: at, timetable: timetable, walkRange: walkRange,
                                        startRange: stationReach)
                .filter { $0.selection.station?.complex == station.complex }
                .compactMap { trip -> (TripPlanner.Trip, TimeInterval, (CitiBike.Dock, CitiBike.Dock)?)? in
                    // Carried, ridden again from the last station if the end's a ride from it
                    let last = trip.change?.destination ?? trip.destination
                    if carried, last.location.distance(from: end) >= leastRide {
                        let off = CitiBike.Dock.place(last.name, last.location)
                        guard let arrival = TripPlanner.arrival(of: trip, from: location, to: last.location, at: at,
                                                                timetable: timetable) else { return nil }
                        let seconds = arrival.timeIntervalSince(now) + carrySeconds + guess(from: off, to: there, kind: kind)
                        return (trip, seconds, (off, there))
                    }
                    return TripPlanner.arrival(of: trip, from: location, to: end, at: at, timetable: timetable)
                        .map { (trip, $0.timeIntervalSince(now), nil) }
                }
                .min { $0.1 < $1.1 }
            guard let best else { continue }
            var trip = found
            trip.train = best.0
            trip.arrives = best.1
            trip.after = best.2.map { (from: $0.0, to: $0.1) }
            trips.append(trip)
        }
        return firstByLines(trips)
    }

    /// A walk to the train with your bike, the train to a station short of the end, and your bike
    /// from there: as `trainFirst`, with no docks.
    private static func ownTrainFirst(from start: CLLocation, to end: CLLocation, there: CitiBike.Dock,
                                      kind: CitiBike.Kind, walkRange: Double, now: Date,
                                      timetable: Timetable) -> [OwnFound] {
        let straight = start.distance(from: end)
        let candidates = Nearby.stations(near: end, limit: 40).compactMap { near -> (OwnFound, Station, Double)? in
            let location = near.station.location
            let gone = start.distance(from: location)
            let station = CitiBike.Dock.place(near.station.name, location)
            let ride = guess(from: station, to: there, kind: kind)
            guard near.meters >= leastRide, gone >= leastRide, straight - gone >= near.meters * leastNearer,
                  ride <= longestRide else { return nil }
            let found = OwnFound(from: station, to: there, bikeFirst: false, carried: true, station: location,
                                 arrives: carrySeconds + ride)
            return (found, near.station, gone / guessTrainSpeed + found.arrives)
        }
        var trips: [OwnFound] = []
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
            trip.arrives = best.1 + found.arrives
            trips.append(trip)
        }
        return firstByLines(trips)
    }

    /// The soonest `offered` of `trips`, each by different lines.
    private static func firstByLines(_ trips: [OwnFound]) -> [OwnFound] {
        var seen = Set<String>()
        return trips.sorted { $0.arrives < $1.arrives }
            .filter { seen.insert($0.train.map { "\($0.selection.routes) \($0.change?.routes ?? [])" } ?? "").inserted }
            .prefix(offered)
            .map { $0 }
    }
}
