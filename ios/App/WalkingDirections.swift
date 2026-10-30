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
    static func walk(from start: CLLocation, to boarding: StationWays.Way) async throws -> Walk {
        var there = try await walk(from: start.coordinate, to: boarding.location.coordinate)
        if let last = there.steps.indices.last {
            let down = boarding.down
            there.steps[last].turn = down.turn
            there.steps[last].instruction = down.instruction
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
    static func walk(from start: CLLocation, to end: CLLocation) async throws -> Walk {
        try await walk(from: start.coordinate, to: end.coordinate)
    }

    /// Apple Maps' walk from `start` to `end`, each step with its turn (`Walk.turn(from:onto:)`),
    /// cached for the session as the same walks are asked for again as trips are picked.
    static func walk(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) async throws -> Walk {
        let key = Cache.Key(start, end)
        if let walk = await Cache.shared.walk(for: key) {
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
        let walk = walk(of: route)
        await Cache.shared.store(walk, for: key)
        return walk
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

    /// Walks asked for this session, by where they go from and to, to the nearest 10 m or so.
    private actor Cache {
        static let shared = Cache()
        
        /// Maximum number of cached walks to prevent memory bloat
        private static let maxCacheSize = 50

        struct Key: Hashable {
            let values: [Int]

            init(_ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D) {
                values = [start.latitude, start.longitude, end.latitude, end.longitude].map { Int(($0 * 10_000).rounded()) }
            }
        }

        private var walks: [Key: Walk] = [:]
        /// Track when each entry was added for cache expiration
        private var timestamps: [Key: Date] = [:]

        func walk(for key: Key) -> Walk? { 
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

        func store(_ walk: Walk, for key: Key) {
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
    }
}
