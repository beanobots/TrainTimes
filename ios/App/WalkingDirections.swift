import CoreLocation
import MapKit

/// Turn-by-turn walks for a trip: from the start to the entrance for its first train, down to it,
/// and up from the exit after its last to the end (`StationWays`), by Apple Maps' walking
/// directions. Maps apps give a trip's walk as one step; these give every turn.
enum WalkingDirections {
    /// A trip's two walks, and the ways in and out they go by.
    struct TripWalks: Codable, Hashable, Sendable {
        var boarding: StationWays.Way
        var toTrain: Walk
        var leaving: StationWays.Way
        var fromTrain: Walk

        /// Which third of the last train to ride in, for the exit (`StationWays.Way.part`).
        var part: Platform.TrainPart? { leaving.part }
    }

    /// `trip`'s walks from `start` and to `end`, both asked for at once. Nil if either station
    /// has no entrance listed; throws if Apple Maps can't route a walk.
    static func walks(for trip: TripPlanner.Trip, from start: CLLocation, to end: CLLocation) async throws -> TripWalks? {
        guard let boarding = StationWays.boarding(trip.selection, from: start),
              let leaving = StationWays.leaving(trip.selection, change: trip.change, at: trip.destination, toward: end)
        else { return nil }
        async let there = walk(from: start, to: boarding)
        async let away = walk(from: leaving, to: end)
        return try await TripWalks(boarding: boarding, toTrain: there, leaving: leaving, fromTrain: away)
    }

    /// The walk from `start` to `boarding`, its last step's arrival at the entrance the way down
    /// there.
    static func walk(from start: CLLocation, to boarding: StationWays.Way, along: [Walk.Point] = []) async throws -> Walk {
        var there = try await walk(from: start.coordinate, to: boarding.location.coordinate, along: along)
        if let last = there.steps.indices.last {
            let down = boarding.down
            there.steps[last].turn = down.turn
            there.steps[last].instruction = down.instruction
            there.steps[last].spoken = down.spoken
            there.steps[last].detail = down.detail
        } else {
            there.steps.append(boarding.down)
        }
        return there
    }

    /// The walk from `leaving` to `end`, the way up from the train first.
    static func walk(from leaving: StationWays.Way, to end: CLLocation) async throws -> Walk {
        var away = try await walk(from: leaving.location.coordinate, to: end.coordinate)
        away.steps.insert(leaving.up, at: 0)
        return away
    }

    /// Apple Maps' walk from `start` to `end`, without the way up from the train: for a walk
    /// out set again from wherever you've got to.
    static func walk(from start: CLLocation, to end: CLLocation, along: [Walk.Point] = []) async throws -> Walk {
        try await walk(from: start.coordinate, to: end.coordinate, along: along)
    }

    /// Longest of Apple Maps' walks fitted onto the sidewalks: one longer, from Riverdale to
    /// Coney Island say, would load most of the city's (hundreds of MB, seconds of work), holding
    /// up every other walk waiting on `SidewalkStore`.
    private static let longestFitted: Double = 8_000

    /// The walk from `start` to `end`: routed on the phone (`WalkRouting`) where it can be, else
    /// Apple Maps', each step with its turn (`Walk.turn(from:onto:)`). Cached
    /// for the session as the same walks are asked for again as trips are picked. `along`: the
    /// way a walk was going, routed again from off it, to rejoin (`WalkRouter.Options.along`).
    static func walk(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
                     along: [Walk.Point] = []) async throws -> Walk {
        // Not a place (NaN, kCLLocationCoordinate2DInvalid): no walk, rather than a crash
        // making its cache key
        guard CLLocationCoordinate2DIsValid(start), CLLocationCoordinate2DIsValid(end),
              start.latitude.isFinite, start.longitude.isFinite, end.latitude.isFinite, end.longitude.isFinite
        else { throw MKError(.directionsNotFound) }
        var options = WalkRouting.options
        options.along = along
        let key = CacheKey(start, end, along: along, routing: WalkRouting.cacheValue(options))
        if let walk = await Cache.shared.walk(for: key) {
            return walk
        }
        if let walk = await routed(from: Walk.Point(start), to: Walk.Point(end), options: options) {
            await Cache.shared.store(walk, for: key)
            return walk
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: start.latitude, longitude: start.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: end.latitude, longitude: end.longitude), address: nil)
        request.transportType = .walking
        // Failing, rather than a made-up walk: Go says it couldn't get one
        guard let route = try await MKDirections(request: request).calculate().routes.first else {
            throw MKError(.directionsNotFound)
        }
        // A ferry in Apple's walk: the walk over a bridge on the city's walking graph, however far
        // round (Roosevelt Island to Queens Plaza), where there is one, else none
        if rides(route) {
            guard let walk = await routed(from: Walk.Point(start), to: Walk.Point(end),
                                          options: options, anyWay: true) else {
                throw MKError(.directionsNotFound)
            }
            await Cache.shared.store(walk, for: key)
            return walk
        }
        var walk = walk(of: route)
        // On the sidewalk, not down the middle of the street, from your side of it to the
        // station's or the end's; as Apple Maps gave it where there are no sidewalks to go by.
        // Not a walk across the city (`longestFitted`): fitting loads every sidewalk in its box
        if walk.meters <= Self.longestFitted, !Task.isCancelled,
           let fitted = await SidewalkStore.shared.fit(walk, from: Walk.Point(start), to: Walk.Point(end)) {
            walk = fitted
        }
        await Cache.shared.store(walk, for: key)
        return walk
    }

    /// The walk routed on the city's walking graph (`WalkGraphStore`), already on the
    /// sidewalks; nil outside the city, without a route, or with one so far round that
    /// something's likely wrong, for Apple Maps' instead. `anyWay`: however far round, where
    /// Apple Maps' won't do.
    private static func routed(from start: Walk.Point, to end: Walk.Point, options: WalkRouter.Options,
                               anyWay: Bool = false) async -> Walk? {
        let began = ContinuousClock.now
        let walk: Walk
        switch await WalkGraphStore.store(from: start, to: end).walk(from: start, to: end, options: options) {
        case let .success(routed):
            walk = routed
        case let .failure(missed):
            WalkRouting.log.notice("Apple Maps' walk: \(missed.rawValue)")
            return nil
        }
        let straight = start.metres(to: end)
        let took = (ContinuousClock.now - began).components
        let ms = took.seconds * 1000 + took.attoseconds / 1_000_000_000_000_000
        guard anyWay || walk.meters <= straight * WalkRouting.furthestTimes + WalkRouting.furthestMore else {
            WalkRouting.log.notice("Apple Maps' walk: too far round, \(Int(walk.meters / max(straight, 1) * 100))% of straight")
            return nil
        }
        WalkRouting.log.info("Routed \(options.preference.rawValue)\(options.along.isEmpty ? "" : ", again") in \(ms) ms: "
                             + "\(walk.crossings?.count ?? 0) crossings, \(walk.lights?.filter { !$0.hasSignal }.count ?? 0) with no light")
        return walk
    }

    /// Whether Apple Maps' walk `route` rides something on the way: a ferry ("Take the Staten
    /// Island Ferry", then "Exit the ferry" over the water), its step not walked. Not a walk,
    /// timed and drawn as one: none, rather than the harbour walked over.
    static func rides(_ route: MKRoute) -> Bool {
        route.steps.contains { $0.distance >= 1 && !$0.transportType.contains(.walking) }
    }

    /// `route` as a walk. Apple Maps' steps each say what to do at the end of their path, the
    /// distance theirs ("Take a right onto W 43rd St", 70 m up Broadway to it), so each gets the
    /// turn from its path onto the next one's; the last arrives. Steps with nothing to walk
    /// ("Proceed to the route", "Start on Broadway") are left out.
    static func walk(of route: MKRoute) -> Walk {
        let walked = route.steps.filter { $0.distance >= 1 && !$0.instructions.isEmpty }
        let paths = walked.map { points(of: $0.polyline) }
        let steps = walked.indices.map { index in
            let turn = index == walked.count - 1 ? Walk.Turn.arrive
                : Walk.turn(from: paths[index], onto: paths[index + 1]).said(in: walked[index].instructions)
            return Walk.Step(turn: turn, instruction: walked[index].instructions, detail: walked[index].notice,
                             meters: walked[index].distance, points: paths[index])
        }
        return Walk(steps: steps, seconds: route.expectedTravelTime, meters: route.distance)
    }

    private static func points(of polyline: MKPolyline) -> [Walk.Point] {
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates.map(Walk.Point.init)
    }

    /// Drops walks cached over an hour ago.
    static func cleanupCache() async {
        await Cache.shared.cleanup()
    }

    /// Prototyping's Clear Caches: every walk cached, and how many there were.
    @discardableResult
    static func clearCache() async -> Int {
        await Cache.shared.removeAll()
    }

    /// How many walks are cached, for Prototyping's Clear Caches.
    static func cachedCount() async -> Int {
        await Cache.shared.count
    }

    /// A walk's place in `Cache`: where it goes from to the nearest metre or so, where to to the
    /// nearest 10 m or so, the way it's to rejoin (a re-route's `along`), and how it's routed.
    struct CacheKey: Hashable {
        let values: [Int]

        /// `routing`: how the walk's routed (`WalkRouting.cacheValue`).
        init(_ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D, along: [Walk.Point] = [], routing: Int) {
            // A re-route from where another was asked for, to rejoin another way, isn't that walk
            var rejoining = Hasher()
            rejoining.combine(along)
            values = [start.latitude, start.longitude].map { Int(($0 * 100_000).rounded()) }
                + [end.latitude, end.longitude].map { Int(($0 * 10_000).rounded()) } + [routing]
                + (along.isEmpty ? [] : [rejoining.finalize()])
        }
    }

    /// Walks asked for this session, by where they go from to the nearest metre or so, as the
    /// walk's fitted to the sidewalk you start on, and where to, to the nearest 10 m or so.
    private actor Cache {
        static let shared = Cache()
        
        /// Maximum number of cached walks to prevent memory bloat
        private static let maxCacheSize = 50

        private var walks: [CacheKey: Walk] = [:]
        /// Track when each entry was added for cache expiration
        private var timestamps: [CacheKey: Date] = [:]

        func walk(for key: CacheKey) -> Walk? { 
            // Check if entry exists and hasn't expired (1 hour)
            if let walk = walks[key], let timestamp = timestamps[key], Date().timeIntervalSince(timestamp) < 3600 {
                return walk
            } else {
                // Remove expired entry
                walks.removeValue(forKey: key)
                timestamps.removeValue(forKey: key)
                return nil
            }
        }

        func store(_ walk: Walk, for key: CacheKey) {
            // Limit cache size
            if walks.count >= Self.maxCacheSize {
                // Remove oldest entries
                let sortedKeys = timestamps.sorted { $0.value < $1.value }.prefix(Self.maxCacheSize / 2).map { $0.key }
                for key in sortedKeys {
                    walks.removeValue(forKey: key)
                    timestamps.removeValue(forKey: key)
                }
            }
            
            walks[key] = walk
            timestamps[key] = Date()
        }

        /// Remove expired entries
        func cleanup() {
            let now = Date()
            let expiredKeys = timestamps.compactMap { key, timestamp in
                now.timeIntervalSince(timestamp) >= 3600 ? key : nil
            }
            for key in expiredKeys {
                walks.removeValue(forKey: key)
                timestamps.removeValue(forKey: key)
            }
        }

        var count: Int { walks.count }

        func removeAll() -> Int {
            let count = walks.count
            walks = [:]
            timestamps = [:]
            return count
        }
    }
}

// MARK: With a bike

extension WalkingDirections {
    /// A trip with a bike, as Go follows it: riding all the way, a walk with the ride joined in
    /// (`Walk.joined`); with a train, the train's walks with the ride joined into the one before
    /// it or after.
    enum BikeWalks {
        case allTheWay(Walk)
        case withTrain(TripPlanner.Trip, TripWalks)
    }

    /// `bike`'s walks and rides turn by turn from `start` to `end`: to its pickup dock, the ride
    /// to its dropoff, and on, each leg's end a step of its own (`Walk.Turn.takeBike`,
    /// `.leaveBike`). Nil if a station of its train has no entrance listed; throws if Apple Maps
    /// can't route a walk.
    static func walks(for bike: BikeTrip, from start: CLLocation, to end: CLLocation) async throws -> BikeWalks? {
        let rideSeconds = TimeInterval(bike.rideMinutes * 60)
        guard let option = bike.train else {
            if bike.owned {
                let ride = await ride(from: start, to: end, planned: bike.path)
                return .allTheWay(Walk.joined([ride], rideSeconds: rideSeconds))
            }
            async let there = walk(from: start, toPickup: bike)
            async let ride = ride(of: bike)
            async let away = walk(from: bike.dropoff.location, to: end)
            return try await .allTheWay(Walk.joined([there, ride, away], rideSeconds: rideSeconds))
        }
        guard let destination = option.endStation else { return nil }
        let trip = TripPlanner.Trip(selection: option.selection, change: option.change, destination: destination)
        if bike.bikeFirst {
            // To the station's nearest way in from where the bike's left
            let from = bike.owned ? start : bike.dropoff.location
            guard let boarding = StationWays.boarding(trip.selection, from: from),
                  let leaving = StationWays.leaving(trip.selection, change: trip.change, at: destination, toward: end)
            else { return nil }
            async let away = walk(from: leaving, to: end, after: bike.rideAfter)
            let toTrain: Walk
            if bike.owned {
                var ride = await ride(from: start, to: boarding.location, planned: bike.path)
                let last = ride.steps.count - 1
                let down = boarding.down
                if bike.carried {
                    // Ridden up to the way down, and taken down it with you
                    ride.steps[last].turn = down.turn
                    ride.steps[last].instruction = down.instruction
                    ride.steps[last].spoken = down.spoken.map { "\($0), with your bike" }
                    ride.steps[last].detail = down.detail
                } else {
                    ride.steps[last].turn = .leaveBike
                    ride.steps[last].instruction = "Lock your bike at \(destinationName(of: trip))"
                    ride.steps.append(down)
                }
                toTrain = Walk.joined([ride], rideSeconds: rideSeconds)
            } else {
                async let there = walk(from: start, toPickup: bike)
                async let ride = ride(of: bike)
                async let away = walk(from: bike.dropoff.location, to: boarding)
                toTrain = try await Walk.joined([there, ride, away], rideSeconds: rideSeconds)
            }
            return try await .withTrain(trip, TripWalks(boarding: boarding, toTrain: toTrain, leaving: leaving, fromTrain: away))
        }
        // The train first: out toward the bike, then ridden on
        guard let boarding = StationWays.boarding(trip.selection, from: start),
              let leaving = StationWays.leaving(trip.selection, change: trip.change, at: destination,
                                                toward: bike.owned ? end : bike.pickup.location)
        else { return nil }
        async let there = walk(from: start, to: boarding)
        let fromTrain: Walk
        if bike.owned {
            var ride = await ride(from: leaving.location, to: end, planned: bike.path)
            ride.steps.insert(leaving.up, at: 0)
            fromTrain = Walk.joined([ride], rideSeconds: rideSeconds)
        } else {
            async let out = walk(from: leaving.location, to: bike.pickup.location)
            async let ride = ride(of: bike)
            async let away = walk(from: bike.dropoff.location, to: end)
            var toDock = try await out
            toDock.steps.insert(leaving.up, at: 0)
            toDock.steps[toDock.steps.count - 1] = takeStep(toDock.steps[toDock.steps.count - 1], bike: bike)
            fromTrain = try await Walk.joined([toDock, ride, away], rideSeconds: rideSeconds)
        }
        return try await .withTrain(trip, TripWalks(boarding: boarding, toTrain: there, leaving: leaving, fromTrain: fromTrain))
    }

    /// The way out from the train to `end`: walked, or a carried bike's ride `after` it.
    private static func walk(from leaving: StationWays.Way, to end: CLLocation, after: BikeTrip.Ride?) async throws -> Walk {
        guard let after else { return try await walk(from: leaving, to: end) }
        var ride = await ride(from: leaving.location, to: end, planned: after.path)
        ride.steps.insert(leaving.up, at: 0)
        return Walk.joined([ride], rideSeconds: TimeInterval(after.minutes * 60))
    }

    /// Metres from a dock that count as at it: no walk there.
    private static let atDock: CLLocationDistance = 20

    /// The station a bike's ridden to, by name.
    private static func destinationName(of trip: TripPlanner.Trip) -> String {
        trip.selection.station?.name ?? "the station"
    }

    /// The walk from `start` to `bike`'s pickup dock, ending at it with the bike taken. Just that
    /// step where you're at the dock already.
    private static func walk(from start: CLLocation, toPickup bike: BikeTrip) async throws -> Walk {
        let dock = bike.pickup.location
        guard start.distance(from: dock) > atDock else {
            let step = takeStep(Walk.Step(turn: .arrive, instruction: "", meters: start.distance(from: dock),
                                          points: [Walk.Point(start.coordinate), Walk.Point(dock.coordinate)]), bike: bike)
            return Walk(steps: [step], seconds: 0, meters: step.meters)
        }
        var walk = try await walk(from: start, to: dock)
        if let last = walk.steps.indices.last { walk.steps[last] = takeStep(walk.steps[last], bike: bike) }
        return walk
    }

    /// `step` as where the bike's taken: "Take an e-bike at W 4 St & 6 Ave".
    private static func takeStep(_ step: Walk.Step, bike: BikeTrip) -> Walk.Step {
        var step = step
        step.turn = .takeBike
        step.instruction = "Take \(bike.kind == .eBike ? "an e-bike" : "a bike") at \(bike.pickup.name)"
        step.spoken = "Take a Citi \(bike.kind == .eBike ? "e-bike" : "Bike") at \(bike.pickup.name)"
        step.detail = "\(bike.kind.count(bike.bikes)) there"
        return step
    }

    /// `bike`'s ride from its pickup dock to its dropoff, ending with the bike docked.
    private static func ride(of bike: BikeTrip) async -> Walk {
        var ride = await ride(from: bike.pickup.location, to: bike.dropoff.location, planned: bike.path)
        let last = ride.steps.count - 1
        ride.steps[last].turn = .leaveBike
        ride.steps[last].instruction = "Dock the bike at \(bike.dropoff.name)"
        ride.steps[last].detail = "\(bike.docks == 1 ? "1 dock" : "\(bike.docks) docks") free"
        return ride
    }

    /// Apple Maps' cycling directions from `start` to `end`, every step ridden (`Walk.Step.riding`),
    /// the last arriving. Not a ride by ferry. Where Apple Maps has none, the ride as `planned`,
    /// as one step, so Go still has the way to go.
    static func ride(from start: CLLocation, to end: CLLocation, planned: [Walk.Point]) async -> Walk {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: start, address: nil)
        request.destination = MKMapItem(location: end, address: nil)
        request.transportType = .cycling
        var ride: Walk
        if let route = try? await MKDirections(request: request).calculate().routes.first,
           !route.advisoryNotices.contains(where: { $0.localizedCaseInsensitiveContains("ferry") }),
           !route.steps.contains(where: { $0.instructions.localizedCaseInsensitiveContains("ferry") }) {
            ride = walk(of: route)
        } else {
            let points = planned.isEmpty ? [Walk.Point(start.coordinate), Walk.Point(end.coordinate)] : planned
            let metres = zip(points, points.dropFirst()).map { $0.metres(to: $1) }.reduce(0, +)
            ride = Walk(steps: [Walk.Step(turn: .arrive, instruction: "Ride there", meters: metres, points: points)],
                        seconds: metres / 4, meters: metres)
        }
        if ride.steps.isEmpty {
            ride.steps = [Walk.Step(turn: .arrive, instruction: "Ride there", meters: ride.meters,
                                    points: [Walk.Point(start.coordinate), Walk.Point(end.coordinate)])]
        }
        for index in ride.steps.indices { ride.steps[index].riding = true }
        return ride
    }
}

/// How walks are routed on the phone, on the city's walking graph (`WalkRouter`), rather than by
/// Apple Maps: for what, picked in Settings' Safer Walks.
enum WalkRouting {
    static let log = AppLog(category: "WalkRouting")
    static let preferenceKey = "walkPreference"

    /// A routed walk this many times the straight line, and `furthestMore` metres, is too far
    /// round to trust: Apple Maps' is used instead.
    static let furthestTimes = 1.6
    static let furthestMore = 300.0

    /// The router's options as set, step-free as the app is, for a walk now.
    static var options: WalkRouter.Options {
        let defaults = UserDefaults.standard
        var options = WalkRouter.Options()
        options.preference = defaults.string(forKey: preferenceKey).flatMap(WalkPreference.init(rawValue:)) ?? .balanced
        options.stepFree = SharedStore.loadSettings().stepFree
        options.time = WalkRouter.Options.Time(AppClock.now)
        return options
    }

    /// `options` as a number for a cache key: walks routed differently kept apart, by day and
    /// after dark too.
    static func cacheValue(_ options: WalkRouter.Options) -> Int {
        let time = options.time.band.rawValue + (options.time.parksClosed ? 1 : 0)
        return 1 + (WalkPreference.allCases.firstIndex(of: options.preference) ?? 0) * 2 + (options.stepFree ? 1 : 0)
            + time * 6
    }
}

/// The names of the streets a walk crosses (`Walk.crossings`), for their signs on the walking
/// map: Apple's reverse geocoder at each crossing's middle, which, out in the street crossed,
/// gives an address on it ("245–261 6th St, Brooklyn"). Kept for the session, by where they
/// are rather than exactly, so a walk opened again or re-routed doesn't ask again: geocoding's
/// limited per app.
actor CrossStreets {
    static let shared = CrossStreets()

    private struct Known {
        let middle: CLLocation
        /// Nil where there was none, or the geocoder failed.
        let name: String?
        let asked: Date
    }

    private var known: [Known] = []
    /// Lookups under way, so a crossing asked for twice at once (a re-route as its names come
    /// in) is asked of the geocoder once.
    private var asking: [(middle: CLLocation, task: Task<String?, Never>)] = []
    /// When the geocoder was last asked, to space its requests by `spacing`.
    private var lastAsked: ContinuousClock.Instant?
    /// Most asked at once: a long walk's crossings, without going past the geocoder's limit.
    private static let most = 24
    /// Between requests to the geocoder: 40 a minute, under its limit of 50, so a walk's crossings
    /// and a re-route's after them aren't throttled, failing (and cached as nameless) part way.
    private static let spacing: Duration = .milliseconds(1500)
    /// Meters apart two crossings' middles are taken to be the same crossing's: a re-routed
    /// walk's crossings move a little, but at a corner the other street's is further.
    private static let sameCrossing: Double = 6
    /// Seconds before a crossing with no name is asked again, as the geocoder may have been
    /// throttled or offline.
    private static let askAgain: TimeInterval = 300

    /// Each crossing's street, by the crossing's middle, as they come in; none where there's none.
    nonisolated func names(for crossings: [[Walk.Point]]) -> AsyncStream<(Walk.Point, String)> {
        AsyncStream { continuation in
            let task = Task {
                for crossing in crossings.prefix(Self.most) where !Task.isCancelled {
                    guard let middle = Self.middle(of: crossing), let name = await self.name(at: middle) else { continue }
                    continuation.yield((middle, name))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The street crossed at `middle`, as known or the geocoder gives it.
    private func name(at middle: Walk.Point) async -> String? {
        let place = CLLocation(latitude: middle.lat, longitude: middle.lon)
        if let found = known.first(where: { $0.middle.distance(from: place) < Self.sameCrossing }),
           found.name != nil || Date.now.timeIntervalSince(found.asked) < Self.askAgain {
            return found.name
        }
        if let under = asking.first(where: { $0.middle.distance(from: place) < Self.sameCrossing }) {
            return await under.task.value
        }
        guard !Task.isCancelled else { return nil }
        // Not cancelled with the walk that asked, as another may be waiting on it
        let task = Task { await self.geocode(place) }
        asking.append((place, task))
        let name = await task.value
        asking.removeAll { $0.task == task }
        return name
    }

    /// The geocoder's street at `place`, `spacing` after its last request; kept in `known`.
    private func geocode(_ place: CLLocation) async -> String? {
        let clock = ContinuousClock()
        if let lastAsked, clock.now < lastAsked + Self.spacing {
            // Taken now, as other lookups run while this one waits
            self.lastAsked = lastAsked + Self.spacing
            try? await clock.sleep(until: lastAsked + Self.spacing)
        } else {
            lastAsked = clock.now
        }
        guard let request = MKReverseGeocodingRequest(location: place) else { return nil }
        let name = Self.street(in: (try? await request.mapItems.first)?.address?.shortAddress)
        known.removeAll { $0.middle.distance(from: place) < Self.sameCrossing }
        known.append(Known(middle: place, name: name, asked: .now))
        return name
    }

    /// Halfway over a crossing.
    static func middle(of crossing: [Walk.Point]) -> Walk.Point? {
        guard let from = crossing.first, let to = crossing.last else { return nil }
        return Walk.Point(lat: (from.lat + to.lat) / 2, lon: (from.lon + to.lon) / 2)
    }

    /// The street in an address: "6th St" from "245–261 6th St, Brooklyn" or "37-12 82nd St".
    /// Nil where it's a park's or a place's name, not a street's ("Strawberry Fields").
    static func street(in address: String?) -> String? {
        guard let line = address?.split(separator: ",").first else { return nil }
        var words = line.split(separator: " ")
        // Its house numbers, if it starts with them: "245–261", "37-12", "12A"; not "5th" of 5th Ave
        if words.count > 1, words[0].wholeMatch(of: /[0-9]+([-–][0-9]+)*[A-Za-z]?/) != nil {
            words.removeFirst()
        }
        let name = words.joined(separator: " ")
        return StreetNames.isStreet(name) ? name : nil
    }
}

/// Why Apple Maps gave no walk or ride, where it's not that it has none: it's throttling the
/// app's asks, or couldn't be reached. Nil for no route (`MKError.directionsNotFound`) and
/// anything else, which No Trip Found says as no trip.
enum MapsTrouble: Hashable, Sendable {
    case busy
    case unreachable

    init?(_ error: Error) {
        if let error = error as? MKError {
            switch error.code {
            case .loadingThrottled:
                self = .busy
                return
            case .serverFailure:
                self = .unreachable
                return
            default:
                break
            }
        }
        // The network: URLError itself, or beneath MapKit's own error
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        guard error.domain == NSURLErrorDomain || underlying?.domain == NSURLErrorDomain else { return nil }
        self = .unreachable
    }

    /// As No Trip Found says it.
    var message: String {
        switch self {
        case .busy: "Apple Maps is busy. Try again in a minute."
        case .unreachable: "Couldn't reach Apple Maps. Check your connection."
        }
    }
}
