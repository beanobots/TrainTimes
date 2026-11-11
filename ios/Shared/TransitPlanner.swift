import Foundation

/// A trip's train rides, and with `bus` its bus rides, in order, for the app to match to its
/// stations: as the phone plans them (`LocalRoutes`), or the server's `GET /routes` sends them.
/// For New Trip, and trips shared from Apple Maps or Google Maps, whose links say only where they
/// start and end.
struct TransitRoute: Codable, Equatable, Sendable {
    var legs: [Leg]

    /// One train or bus ride.
    struct Leg: Codable, Equatable, Sendable {
        /// The line's short name: "R", "6", "GS", "B63".
        var line: String
        var from: Stop
        var to: Stop
        /// Where the train's going, e.g. "Forest Hills - 71 Av".
        var headsign: String?
        /// Stops ridden, counting the last.
        var stops: Int?
        var mode: Mode = .subway
        /// Seconds from boarding to getting off, by the timetable: for timing what comes
        /// after a bus, as Bus Time only says when it's due where you board.
        var seconds: Int? = nil
        /// When it leaves where it's boarded by the timetable, in seconds since 1970: for
        /// timing a trip with a bus, which the app's timetable doesn't have.
        var leaves: Int? = nil
    }

    enum Mode: String, Codable, Sendable {
        case subway, bus
    }

    struct Stop: Codable, Equatable, Sendable {
        var name: String
        var latitude: Double
        var longitude: Double
    }
}

/// The subway's and the buses' timetables as one network to plan trips on (`TransitPlanner`):
/// every stop with where it is, every pattern's calls laid end to end, the patterns calling at
/// each stop, and the walks between stops near each other. Built once for each pair of
/// timetables, on the phone (`LocalRoutes`) and on the server (`TransitNetworks`).
struct TransitNetwork: Sendable {
    struct Stop: Sendable {
        let latitude: Double
        let longitude: Double
        /// A station's name ("Atlantic Av-Barclays Ctr") or the GTFS's for a bus stop ("5 AV/9 ST").
        let name: String
        /// The station's complex, for a subway stop: changes inside one are timed as the MTA's.
        let complex: String?
        /// Its feed id, for a subway stop ("R31N"), for the MTA's timed walks (`Platform.walks`).
        let feedID: String?
        /// False for a stop the timetable has but stations.json doesn't place: ridden through,
        /// never boarded or left at.
        let isPlaced: Bool
    }

    /// A line one way: the subway's by its route ("R", "6X"), a bus's by its name and headsign.
    struct Line: Sendable {
        let name: String
        let headsign: String?
        let mode: TransitRoute.Mode
    }

    struct Pattern: Sendable {
        let line: Int32
        /// Where its calls start in `callStops`, `callArrives` and `callLeaves`, and how many.
        let firstCall: Int32
        let callCount: Int32
        /// Its timetable's `base`, in seconds since 1970: what `starts` count from.
        let base: Int
        /// Each trip's start, seconds after `base`, soonest first.
        let starts: [UInt32]
    }

    /// A walk from one stop to another, counting the time to change.
    struct Walk: Sendable {
        let to: Int32
        let seconds: Int32
    }

    let stops: [Stop]
    let lines: [Line]
    /// Each line's group, the same for the same name by the same mode: the 6 and the 6 express,
    /// a bus either way. No trip changes from one to another in it.
    let lineGroups: [Int32]
    let patterns: [Pattern]
    let callStops: [Int32]
    /// Seconds after a trip starts that it gets to each call, and that it leaves.
    let callArrives: [Int32]
    let callLeaves: [Int32]
    /// Each stop's calls, as (pattern, index of the call within it).
    let stopCalls: [[(pattern: Int32, call: Int32)]]
    let walks: [[Walk]]
    /// Stops by `cell(_:_:)`, for finding those near a place.
    let grid: [Int64: [Int32]]
    /// When the timetables it's built from were made, to tell when it's out of date.
    let subwayMade: Date?
    let busMade: Date?

    /// The furthest apart two stops are for a walk between them to count as a change.
    static let changeRange: Double = 400
    /// Seconds a change on foot takes on top of the walk: finding the stop, or going back
    /// through the fare gates.
    static let changeSeconds = 60
    /// A change between platforms in one complex, where the MTA doesn't time it longer, as the
    /// app counts one (`Change.defaultWalkMinutes`).
    static let complexChangeSeconds = Change.defaultWalkMinutes * 60
    /// The grid's cells, in degrees: about 550 m north to south.
    private static let cellSize = 0.005

    /// Seconds to walk `meters`: 80 a minute, plus 20% for indirect streets, as the app times
    /// every walk (`TripPlanner.walkSeconds`).
    static func walkSeconds(_ meters: Double) -> Int {
        Int((meters * 1.2 / 80 * 60).rounded())
    }

    /// Meters between two places, as the crow flies: near enough at a city's scale.
    static func meters(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let north = (b.0 - a.0) * Earth.metresPerDegree
        let east = (b.1 - a.1) * Earth.metresPerDegree * cos((a.0 + b.0) / 2 * .pi / 180)
        return (north * north + east * east).squareRoot()
    }

    private static func cell(_ latitude: Double, _ longitude: Double) -> Int64 {
        Int64((latitude / cellSize).rounded(.down)) << 32 | Int64(Int32((longitude / cellSize).rounded(.down))) & 0xFFFF_FFFF
    }

    /// The placed stops within `radius` meters of `point`, and how far each is.
    func stops(near point: (Double, Double), within radius: Double) -> [(stop: Int32, meters: Double)] {
        Self.stops(near: point, within: radius, of: stops, grid: grid)
    }

    private static func stops(near point: (Double, Double), within radius: Double, of stops: [Stop],
                              grid: [Int64: [Int32]]) -> [(stop: Int32, meters: Double)] {
        // None near a pole, where a degree east shrinks to nothing and the cells to look in grow
        // past counting (a shared link's "90,0"), nor a place that isn't one
        guard point.0.isFinite, point.1.isFinite, abs(point.0) < 85 else { return [] }
        let rows = Int((radius / Earth.metresPerDegree / cellSize).rounded(.up))
        let columns = Int((radius / (Earth.metresPerDegree * cos(point.0 * .pi / 180)) / cellSize).rounded(.up))
        let row = Int((point.0 / cellSize).rounded(.down)), column = Int((point.1 / cellSize).rounded(.down))
        var found: [(stop: Int32, meters: Double)] = []
        for r in (row - rows)...(row + rows) {
            for c in (column - columns)...(column + columns) {
                let key = Int64(r) << 32 | Int64(Int32(c)) & 0xFFFF_FFFF
                for stop in grid[key] ?? [] {
                    let place = stops[Int(stop)]
                    let meters = meters(point, (place.latitude, place.longitude))
                    if meters <= radius { found.append((stop, meters)) }
                }
            }
        }
        return found
    }

    /// From the subway's timetable, the buses' (whose stops are placed in it), or both.
    init(subway: Timetable?, buses: Timetable?) {
        var stops: [Stop] = []
        var lines: [Line] = []
        var patterns: [Pattern] = []
        var callStops: [Int32] = [], callArrives: [Int32] = [], callLeaves: [Int32] = []

        func add(_ timetable: Timetable, mode: TransitRoute.Mode, stop place: (Int) -> Stop) {
            let first = stops.count
            stops += timetable.stops.indices.map(place)
            var lineIndex: [Int: Int32] = [:]
            for (pattern, starts) in zip(timetable.patterns, timetable.starts) where !starts.isEmpty {
                let route = Int(pattern.route)
                let line: Int32
                if let known = lineIndex[route] {
                    line = known
                } else {
                    let parts = timetable.routes[route].split(separator: "\t", maxSplits: 1).map(String.init)
                    let name = mode == .subway ? Lines.normalized(parts.first ?? "") : parts.first ?? ""
                    line = Int32(lines.count)
                    lines.append(Line(name: name, headsign: parts.count > 1 ? parts[1] : nil, mode: mode))
                    lineIndex[route] = line
                }
                patterns.append(Pattern(line: line, firstCall: Int32(callStops.count), callCount: Int32(pattern.calls.count),
                                        base: Int(timetable.base.timeIntervalSince1970.rounded()), starts: starts))
                for call in pattern.calls {
                    callStops.append(Int32(first + Int(call.stop)))
                    callArrives.append(Int32(call.arrives))
                    callLeaves.append(Int32(call.arrives) + Int32(call.waits))
                }
            }
        }
        if let subway {
            add(subway, mode: .subway) { index in
                let id = subway.stops[index]
                guard let platform = StationDirectory.platform(forStop: id) else {
                    return Stop(latitude: 0, longitude: 0, name: id, complex: nil, feedID: id, isPlaced: false)
                }
                return Stop(latitude: platform.lat, longitude: platform.lon, name: platform.name,
                            complex: platform.complex, feedID: id, isPlaced: true)
            }
        }
        if let buses {
            add(buses, mode: .bus) { index in
                guard let place = buses.places?[index], place.latitude != 0 else {
                    return Stop(latitude: 0, longitude: 0, name: buses.stops[index], complex: nil, feedID: nil, isPlaced: false)
                }
                return Stop(latitude: place.latitude, longitude: place.longitude, name: place.name,
                            complex: nil, feedID: nil, isPlaced: true)
            }
        }

        var stopCalls = [[(pattern: Int32, call: Int32)]](repeating: [], count: stops.count)
        for (index, pattern) in patterns.enumerated() {
            for call in 0..<Int(pattern.callCount) {
                stopCalls[Int(callStops[Int(pattern.firstCall) + call])].append((Int32(index), Int32(call)))
            }
        }
        var grid: [Int64: [Int32]] = [:]
        for (index, stop) in stops.enumerated() where stop.isPlaced && !stopCalls[index].isEmpty {
            grid[Self.cell(stop.latitude, stop.longitude), default: []].append(Int32(index))
        }
        var groups: [String: Int32] = [:]
        lineGroups = lines.map { line in
            let key = "\(line.mode.rawValue) \(line.name)"
            if let group = groups[key] { return group }
            groups[key] = Int32(groups.count)
            return Int32(groups.count - 1)
        }
        self.stops = stops
        self.lines = lines
        self.patterns = patterns
        self.callStops = callStops
        self.callArrives = callArrives
        self.callLeaves = callLeaves
        self.stopCalls = stopCalls
        self.grid = grid
        subwayMade = subway?.made
        busMade = buses?.made

        // The walks between stops near each other. In a complex, the MTA's time for it or the
        // app's for any change there; the MTA's timed walks along the street between complexes
        // (Livonia Av to Junius St) too, however far
        var walks = [[Walk]](repeating: [], count: stops.count)
        var byFeedID: [String: Int32] = [:]
        for (index, stop) in stops.enumerated() {
            if let id = stop.feedID, stop.isPlaced { byFeedID[id] = Int32(index) }
        }
        for (index, stop) in stops.enumerated() where stop.isPlaced && !stopCalls[index].isEmpty {
            var seconds: [Int32: Int32] = [:]
            for (other, meters) in Self.stops(near: (stop.latitude, stop.longitude), within: Self.changeRange,
                                                     of: stops, grid: grid)
            where other != Int32(index) {
                let near = stops[Int(other)]
                let walk: Int
                if let complex = stop.complex, complex == near.complex, let from = stop.feedID, let to = near.feedID {
                    walk = Change.walkMinutes(from: from, to: to, else: Change.defaultWalkMinutes) * 60
                } else {
                    walk = Self.walkSeconds(meters) + Self.changeSeconds
                }
                seconds[other] = Int32(walk)
            }
            if let id = stop.feedID, let platform = StationDirectory.platform(forStop: id) {
                for (to, minutes) in platform.walks ?? [:] {
                    for direction in Direction.allCases {
                        guard let other = byFeedID[to + direction.rawValue], other != Int32(index) else { continue }
                        seconds[other] = min(seconds[other] ?? .max, Int32(minutes * 60))
                    }
                }
            }
            walks[index] = seconds.map { Walk(to: $0.key, seconds: $0.value) }.sorted { $0.to < $1.to }
        }
        self.walks = walks
    }
}

/// Plans trips from one place to another on the network (`TransitNetwork`) by RAPTOR: in rounds,
/// each riding every line from the stops the last round reached, and walking on to stops near
/// those, the earliest each stop can be got to with one ride, then two. A trip has at most two
/// rides, as the app offers no more (`ServerRoutes.trips(from:)`, `busTrip(from:)`). For other
/// trips than the quickest, it plans again by subway alone and by bus alone, and without each
/// line the trips found ride. The phone plans with it (`LocalRoutes`), and so does the server's
/// `GET /routes`, for phones without the buses' timetable.
enum TransitPlanner {
    /// Rides a trip may have.
    static let maxRides = 2
    /// Meters walked to the first stop and from the last, as the crow flies: the app's
    /// `TripPlanner.walkRange`, then, where that finds nothing, twice it.
    static let walkRange: Double = 1200
    static let longWalkRange: Double = 2400
    /// The longest wait at the stop for a first ride, in seconds: a later one isn't now's trip.
    /// The phone's own planner waits no longer (`TripPlanner.longestWait`).
    static let maxWait = 30 * 60
    /// How many times it plans, and how many trips it offers.
    static let maxPlans = 10
    static let maxRoutes = 8
    /// What a change counts for in ranking trips, on top of its time, as New Trip ranks them
    /// (`TripPlanner.changeCost(across:)`): across the platform `acrossChangeCost`, any other,
    /// to another platform or between a bus and a train or two buses, `walkingChangeCost`.
    static let acrossChangeCost = 1 * 60
    static let walkingChangeCost = 7 * 60
    /// How much of each second walked to the first stop and from the last counts against a trip
    /// in ranking, on top of its time (`TripPlanner.walkWeight`): of two getting there about
    /// the same time, the one with less walking first. A first wait doesn't count.
    static let walkWeight = 0.15
    /// Trips getting there more than this after the best aren't offered.
    static let slowerBy = 25 * 60

    /// A trip as found: its rides, and when it gets to the end.
    struct Journey: Equatable {
        struct Ride: Equatable {
            let pattern: Int32
            /// Index into the pattern's `starts`.
            let trip: Int
            let board: Int32
            let alight: Int32
        }
        let rides: [Ride]
        let arrival: Int
    }

    /// Trips from `from` to `to` leaving at `departure`, best first, by `modes`: none that gets
    /// there no sooner than walking straight there.
    static func routes(on network: TransitNetwork, from: (Double, Double), to: (Double, Double), departure: Date,
                       modes: Set<TransitRoute.Mode>) -> [TransitRoute] {
        // Nowhere (NaN, infinite, at a pole) has no stops near it, nor a walk to time
        guard [from.0, from.1, to.0, to.1].allSatisfy(\.isFinite), abs(from.0) < 85, abs(to.0) < 85 else { return [] }
        let leaving = Int(departure.timeIntervalSince1970.rounded())
        var found: [Journey] = []
        var keys = Set<String>()
        var asked = Set<[Int32]>()
        // Each plan: by which modes, without which lines
        var queue: [(modes: Set<TransitRoute.Mode>, without: Set<Int32>, range: Double)] = [(modes, [], walkRange)]
        if modes.count > 1 {
            queue += modes.sorted { $0.rawValue < $1.rawValue }.map { ([$0], [], walkRange) }
        }
        var plans = 0
        while !queue.isEmpty, plans < maxPlans {
            let plan = queue.removeFirst()
            plans += 1
            for journey in journeys(on: network, from: from, to: to, leaving: leaving, modes: plan.modes,
                                    without: plan.without, range: plan.range) {
                guard keys.insert(key(of: journey, on: network)).inserted else { continue }
                found.append(journey)
                // Then each of its lines left out, for trips riding others
                for ride in journey.rides {
                    let without = plan.without.union([network.lineGroups[Int(network.patterns[Int(ride.pattern)].line)]])
                    let sorted = without.sorted()
                    guard asked.insert(sorted + [plan.modes.contains(.bus) ? 1 : 0, plan.modes.contains(.subway) ? 1 : 0])
                        .inserted else { continue }
                    queue.append((plan.modes, without, plan.range))
                }
            }
            // Nothing within the usual walk: once more with a longer one
            if queue.isEmpty, found.isEmpty, plan.range < longWalkRange {
                queue.append((modes, [], longWalkRange))
            }
        }
        // Not one getting there no sooner than walking straight there, as the crow flies (none from a
        // place to itself)
        let walking = leaving + TransitNetwork.walkSeconds(TransitNetwork.meters(from, to))
        let worth = found.filter { $0.arrival < walking }
        let score = { (journey: Journey) in cost(of: journey, on: network, from: from, to: to) }
        guard let best = worth.map(score).min() else { return [] }
        return worth.filter { score($0) <= best + slowerBy }
            .sorted { score($0) < score($1) }
            .prefix(maxRoutes)
            .map { route(of: $0, on: network) }
    }

    /// What `journey` is ranked by: when it gets there, plus `acrossChangeCost` or
    /// `walkingChangeCost` for its change and `walkWeight` of its walks from `from` and to `to`.
    static func cost(of journey: Journey, on network: TransitNetwork, from: (Double, Double),
                     to: (Double, Double)) -> Int {
        func stop(_ ride: Journey.Ride, _ call: Int32) -> TransitNetwork.Stop {
            let pattern = network.patterns[Int(ride.pattern)]
            return network.stops[Int(network.callStops[Int(pattern.firstCall) + Int(call)])]
        }
        func line(_ ride: Journey.Ride) -> TransitNetwork.Line {
            network.lines[Int(network.patterns[Int(ride.pattern)].line)]
        }
        var cost = journey.arrival
        for (off, on) in zip(journey.rides, journey.rides.dropFirst()) {
            let offLine = line(off), onLine = line(on)
            // Across the platform, as the app tells it: subway to subway, the line changed to on
            // the platform you're off at, on the same side of it
            let across = offLine.mode == .subway && onLine.mode == .subway
                && stop(off, off.alight).feedID.flatMap { at in
                    stop(on, on.board).feedID.map { board in
                        Change.isAcross(off: offLine.name, at: at, on: onLine.name, at: board)
                    }
                } == true
            cost += across ? acrossChangeCost : walkingChangeCost
        }
        if let first = journey.rides.first, let last = journey.rides.last {
            let start = stop(first, first.board), end = stop(last, last.alight)
            let walked = TransitNetwork.walkSeconds(TransitNetwork.meters(from, (start.latitude, start.longitude)))
                + TransitNetwork.walkSeconds(TransitNetwork.meters((end.latitude, end.longitude), to))
            cost += Int((Double(walked) * walkWeight).rounded())
        }
        return cost
    }

    /// The same trip: the same lines from and to the same stops.
    private static func key(of journey: Journey, on network: TransitNetwork) -> String {
        journey.rides.map { ride in
            "\(network.patterns[Int(ride.pattern)].line) \(ride.board) \(ride.alight)"
        }.joined(separator: " ")
    }

    /// A journey as `GET /routes` sends it.
    static func route(of journey: Journey, on network: TransitNetwork) -> TransitRoute {
        TransitRoute(legs: journey.rides.map { ride in
            let pattern = network.patterns[Int(ride.pattern)]
            let line = network.lines[Int(pattern.line)]
            let first = Int(pattern.firstCall)
            let start = pattern.base + Int(pattern.starts[ride.trip])
            let leaves = start + Int(network.callLeaves[first + Int(ride.board)])
            let arrives = start + Int(network.callArrives[first + Int(ride.alight)])
            let stop = { (call: Int32) -> TransitRoute.Stop in
                let stop = network.stops[Int(network.callStops[first + Int(call)])]
                return TransitRoute.Stop(name: stop.name, latitude: stop.latitude, longitude: stop.longitude)
            }
            return TransitRoute.Leg(line: line.name, from: stop(ride.board), to: stop(ride.alight), headsign: line.headsign,
                                    stops: Int(ride.alight - ride.board), mode: line.mode,
                                    seconds: arrives - leaves, leaves: leaves)
        })
    }

    /// How a stop was got to in a round: copied from the round before, walked to from the start,
    /// ridden to, or walked to from a stop ridden to in the same round.
    private enum Label {
        case earlier
        case start
        case ride(Journey.Ride)
        case walk(from: Int32)
    }

    /// The quickest trip with one ride, and with two if that's quicker, from `from` to `to`
    /// leaving at `leaving` (seconds since 1970), by `modes`, riding none of `without`'s lines (by group),
    /// walking at most `range` meters to the first stop and from the last.
    static func journeys(on network: TransitNetwork, from: (Double, Double), to: (Double, Double), leaving: Int,
                         modes: Set<TransitRoute.Mode>, without: Set<Int32> = [],
                         range: Double = walkRange) -> [Journey] {
        let count = network.stops.count
        let never = Int.max
        var arrival = [[Int]](repeating: [Int](repeating: never, count: count), count: maxRides + 1)
        var labels = [[Label]](repeating: [Label](repeating: .earlier, count: count), count: maxRides + 1)
        var rides = [[Journey.Ride?]](repeating: [Journey.Ride?](repeating: nil, count: count), count: maxRides + 1)
        var best = [Int](repeating: never, count: count)
        var marked: [Int32] = []

        for (stop, meters) in network.stops(near: from, within: range) {
            let at = leaving + TransitNetwork.walkSeconds(meters)
            arrival[0][Int(stop)] = at
            labels[0][Int(stop)] = .start
            best[Int(stop)] = at
            marked.append(stop)
        }
        var ends: [Int32: Int] = [:]
        for (stop, meters) in network.stops(near: to, within: range) {
            ends[stop] = TransitNetwork.walkSeconds(meters)
        }
        guard !marked.isEmpty, !ends.isEmpty else { return [] }
        // The best arrival at the end so far: no stop is worth reaching later
        var target = never

        var queued = [Int32](repeating: -1, count: network.patterns.count)
        for round in 1...maxRides {
            arrival[round] = arrival[round - 1]
            // Each pattern from the earliest of its calls at a stop reached last round
            var scanning: [Int32] = []
            for stop in marked {
                for (pattern, call) in network.stopCalls[Int(stop)] {
                    let line = network.lines[Int(network.patterns[Int(pattern)].line)]
                    guard modes.contains(line.mode),
                          !without.contains(network.lineGroups[Int(network.patterns[Int(pattern)].line)]) else { continue }
                    if queued[Int(pattern)] < 0 {
                        scanning.append(pattern)
                        queued[Int(pattern)] = call
                    } else if call < queued[Int(pattern)] {
                        queued[Int(pattern)] = call
                    }
                }
            }
            var ridden: [Int32] = []
            for index in scanning {
                let pattern = network.patterns[Int(index)]
                let first = Int(pattern.firstCall)
                var trip: Int? = nil
                var start = 0
                var boarded: Int32 = 0
                for call in Int(queued[Int(index)])..<Int(pattern.callCount) {
                    let stop = Int(network.callStops[first + call])
                    if trip != nil {
                        let at = start + Int(network.callArrives[first + call])
                        if at < best[stop], at < target {
                            arrival[round][stop] = at
                            best[stop] = at
                            let ride = Journey.Ride(pattern: index, trip: trip!, board: boarded, alight: Int32(call))
                            labels[round][stop] = .ride(ride)
                            rides[round][stop] = ride
                            ridden.append(Int32(stop))
                            if let walk = ends[Int32(stop)] { target = min(target, at + walk) }
                        }
                    }
                    // A trip from here as early as could be caught, if earlier than the one ridden;
                    // not a change to the line just ridden (the 6 to the 6 express)
                    let ready = arrival[round - 1][stop]
                    guard ready != never, network.stops[stop].isPlaced,
                          round == 1 || reaching(Int32(stop), round: round - 1, labels: labels, rides: rides,
                                                 on: network) != network.lineGroups[Int(pattern.line)]
                    else { continue }
                    let leaves = Int(network.callLeaves[first + call])
                    if trip == nil || ready <= start + leaves {
                        let earliest = firstTrip(of: pattern, leaving: leaves, after: ready)
                        // A first ride leaving over `maxWait` after you're at its stop isn't now's:
                        // not the first train of a timetable that starts tomorrow
                        if earliest < pattern.starts.count, trip.map({ earliest < $0 }) ?? true,
                           round > 1 || pattern.base + Int(pattern.starts[earliest]) + leaves - ready <= maxWait {
                            trip = earliest
                            start = pattern.base + Int(pattern.starts[earliest])
                            boarded = Int32(call)
                        }
                    }
                }
                queued[Int(index)] = -1
            }
            // Then walking on from each stop ridden to
            var walked: [Int32] = []
            for stop in Set(ridden) {
                // When the ride gets there, not a walk there since
                guard let ride = rides[round][Int(stop)] else { continue }
                let at = alighting(ride, on: network)
                for walk in network.walks[Int(stop)] {
                    let then = at + Int(walk.seconds)
                    guard then < best[Int(walk.to)], then < target else { continue }
                    arrival[round][Int(walk.to)] = then
                    best[Int(walk.to)] = then
                    labels[round][Int(walk.to)] = .walk(from: stop)
                    walked.append(walk.to)
                    if let end = ends[walk.to] { target = min(target, then + end) }
                }
            }
            marked = ridden + walked
            if marked.isEmpty { break }
        }

        // The best way to the end with each number of rides, if it's the quickest so far
        var journeys: [Journey] = []
        var quickest = never
        for round in 1...maxRides {
            var end: (stop: Int32, at: Int)? = nil
            for (stop, walk) in ends {
                if case .earlier = labels[round][Int(stop)] { continue }
                let at = arrival[round][Int(stop)] + walk
                if at < end?.at ?? never { end = (stop, at) }
            }
            guard let end, end.at < quickest,
                  let traced = trace(from: end.stop, round: round, labels: labels, rides: rides, on: network) else { continue }
            quickest = end.at
            journeys.append(Journey(rides: traced, arrival: end.at))
        }
        return journeys
    }

    /// The rides that got to `stop` in `round`, first first; nil if they can't be told.
    private static func trace(from stop: Int32, round: Int, labels: [[Label]], rides: [[Journey.Ride?]],
                              on network: TransitNetwork) -> [Journey.Ride]? {
        var traced: [Journey.Ride] = []
        var stop = stop
        var round = round
        while round > 0 {
            switch labels[round][Int(stop)] {
            case .earlier:
                round -= 1
            case .start:
                return nil
            case .walk(let from):
                guard let ride = rides[round][Int(from)] else { return nil }
                traced.append(ride)
                stop = boardingStop(of: ride, on: network)
                round -= 1
            case .ride(let ride):
                traced.append(ride)
                stop = boardingStop(of: ride, on: network)
                round -= 1
            }
        }
        guard case .start = labels[0][Int(stop)] else { return nil }
        return traced.reversed()
    }

    /// When `ride` gets off, in seconds since 1970.
    private static func alighting(_ ride: Journey.Ride, on network: TransitNetwork) -> Int {
        let pattern = network.patterns[Int(ride.pattern)]
        return pattern.base + Int(pattern.starts[ride.trip])
            + Int(network.callArrives[Int(pattern.firstCall) + Int(ride.alight)])
    }

    /// The line (`TransitNetwork.lineGroups`) last ridden to `stop` by `round`; nil if it's walked
    /// to from the start.
    private static func reaching(_ stop: Int32, round: Int, labels: [[Label]], rides: [[Journey.Ride?]],
                                 on network: TransitNetwork) -> Int32? {
        var round = round
        while round > 0 {
            switch labels[round][Int(stop)] {
            case .earlier: round -= 1
            case .start: return nil
            case .ride(let ride): return network.lineGroups[Int(network.patterns[Int(ride.pattern)].line)]
            case .walk(let from):
                return rides[round][Int(from)].map { network.lineGroups[Int(network.patterns[Int($0.pattern)].line)] }
            }
        }
        return nil
    }

    private static func boardingStop(of ride: Journey.Ride, on network: TransitNetwork) -> Int32 {
        network.callStops[Int(network.patterns[Int(ride.pattern)].firstCall) + Int(ride.board)]
    }

    /// The index in `pattern.starts` of its first trip leaving the call `leaves` seconds into
    /// it at or after `time` (seconds since 1970); its count if none does.
    private static func firstTrip(of pattern: TransitNetwork.Pattern, leaving leaves: Int, after time: Int) -> Int {
        let starts = pattern.starts
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if pattern.base + Int(starts[middle]) + leaves < time { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
