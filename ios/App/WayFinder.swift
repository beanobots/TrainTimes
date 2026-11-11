import CoreLocation
import Foundation

/// Every way from one place to another in up to two changes, each ride a train or a bus, worked
/// out from the week's subway timetable (`Timetable`) and the bus lines' stops and minutes
/// (`BusRoutes`), for planning a saved route: which lines, where to change, when each way runs
/// and how long it takes then. A place is a station's complex (a change inside one is one
/// change) or a bus stop; changes may walk between a station and a stop, or two stops.
struct WayFinder: Sendable {
    /// Two changes at most: three rides.
    static let maxChanges = 2
    /// The longest walk between rides: a station and a bus stop, or two stops.
    static let changeWalk = 6
    static let stopToStopWalk = 3
    /// The longest walk from the last ride to where you're going.
    static let endWalk = 8
    /// Waiting for a bus, by guess: Bus Time has no week ahead to go by. Only for ranking.
    private static let busWait = 300

    /// A run of stops some trains of a line make, as the timetable has it, or a bus line's stops
    /// one way; each stop with its seconds from the first.
    struct Run: Sendable {
        /// A train's route, or a bus's marked as one ("bus:B63", `BusLeg.prefix`).
        var route: String
        /// A bus's headsign.
        var headsign: String?
        /// Feed stop ids ("R31N"), or bus stop codes.
        var stops: [String]
        /// Where each stop is: a complex, or a bus stop (`stopPlace`).
        var places: [String]
        var seconds: [Int]

        var isBus: Bool { headsign != nil }
    }

    let timetable: Timetable
    let runs: [Run]
    /// Each place's runs and where they call there.
    private let calling: [String: [(run: Int, index: Int)]]
    /// Each timetable pattern's calls as complexes, for timing.
    private let patternComplexes: [[String]]
    /// Per timetable pattern running on another line's stops (the N on the R's local stops late
    /// nights, the D there on weekends): that line, and the stretch of calls along its stops
    /// where the pattern's trains count as it, "R and trains running on the local track".
    private let standIns: [Int: [(line: String, calls: ClosedRange<Int>)]]

    /// Express buses (SIM, X, BM, QM, BxM): left out of planning, as their stops in the
    /// boroughs only pick up toward Manhattan and only let off away from it, which the bus data
    /// doesn't say, so they'd seem to run between any two of their stops.
    static func isExpress(_ line: String) -> Bool {
        let name = BusRoutes.key(line)
        return ["SIM", "BXM", "BM", "QM", "X"].contains { name.hasPrefix($0) && name.dropFirst($0.count).first?.isNumber == true }
    }

    /// A bus stop as a place.
    static func stopPlace(_ code: String) -> String { "b:" + code }

    /// The stop code of a place that's a bus stop; nil for a complex.
    static func stopCode(_ place: String) -> String? { place.hasPrefix("b:") ? String(place.dropFirst(2)) : nil }

    init(timetable: Timetable) {
        self.timetable = timetable
        var seen = Set<String>()
        var runs: [Run] = []
        let stopComplexes = timetable.stops.map { StationDirectory.station(forStop: $0)?.complex ?? $0 }
        patternComplexes = timetable.patterns.map { $0.calls.map { stopComplexes[Int($0.stop)] } }
        var standIns: [Int: [(line: String, calls: ClosedRange<Int>)]] = [:]
        for (index, pattern) in timetable.patterns.enumerated() {
            let route = Lines.normalized(timetable.routes[Int(pattern.route)])
            let stops = pattern.calls.map { timetable.stops[Int($0.stop)] }
            var places = patternComplexes[index]
            let seconds = pattern.calls.map { Int($0.arrives) }
            let stretches = Self.standInStretches(route: route, stops: stops)
            if !stretches.isEmpty {
                standIns[index] = stretches
                // Along another line's stops it's that line: its own isn't boarded or left there,
                // only ridden through
                for (call, stop) in stops.enumerated() where stretches.contains(where: { $0.calls.contains(call) }) {
                    if let platform = StationDirectory.platform(forStop: stop), !platform.routes.contains(route) {
                        places[call] = ""
                    }
                }
                let complexes = patternComplexes[index]
                for stretch in stretches {
                    let calls = Array(stretch.calls)
                    let key = stretch.line + " " + calls.map { stops[$0] }.joined(separator: ",")
                    guard seen.insert(key).inserted else { continue }
                    runs.append(Run(route: stretch.line, headsign: nil, stops: calls.map { stops[$0] },
                                    places: calls.map { complexes[$0] }, seconds: calls.map { seconds[$0] }))
                }
            }
            let key = route + " " + stops.joined(separator: ",") + (stretches.isEmpty ? "" : " via")
            guard seen.insert(key).inserted else { continue }
            runs.append(Run(route: route, headsign: nil, stops: stops, places: places, seconds: seconds))
        }
        self.standIns = standIns
        for (line, way) in BusRoutes.everyWay where way.stops.count > 1 && !Self.isExpress(line) {
            runs.append(Run(route: BusLeg.prefix + line, headsign: way.to, stops: way.stops.map(\.code),
                            places: way.stops.map { Self.stopPlace($0.code) }, seconds: way.minutes.map { Int($0 * 60) }))
        }
        self.runs = runs
        var calling: [String: [(run: Int, index: Int)]] = [:]
        for (index, run) in runs.enumerated() {
            for (position, place) in run.places.enumerated() where !place.isEmpty {
                calling[place, default: []].append((index, position))
            }
        }
        self.calling = calling
    }

    /// Where a `route` train calling at `stops` runs on another line's stops, as that line: each
    /// run of stops `route` doesn't usually make (as `Platform.routes` has it: a Q on the D N R's
    /// platform at Atlantic Av is off its own, though it stops in the station), widened along the
    /// line usually making them all to as far as that line's stops go on. The line is the one
    /// making most of the pattern's stops (R over W).
    private static func standInStretches(route: String, stops: [String]) -> [(line: String, calls: ClosedRange<Int>)] {
        let stations = stops.map(StationDirectory.platform(forStop:))
        let unusual = stations.indices.filter { stations[$0].map { !$0.routes.contains(route) } ?? false }
        guard !unusual.isEmpty else { return [] }
        // Unusual calls next to each other, together while one line makes them all: a W from
        // Sea Beach is on the N's stops, then the R's
        var groups: [(calls: [Int], common: Set<String>)] = []
        for call in unusual {
            let lines = Set(stations[call]?.routes ?? [])
            if let last = groups.last, last.calls.last == call - 1, !last.common.isDisjoint(with: lines) {
                groups[groups.count - 1].calls.append(call)
                groups[groups.count - 1].common.formIntersection(lines)
            } else {
                groups.append(([call], lines))
            }
        }
        var stretches: [(line: String, calls: ClosedRange<Int>)] = []
        for (group, common) in groups {
            let making = { (line: String) in stations.filter { $0?.routes.contains(line) == true }.count }
            guard let line = common.sorted().min(by: { making($0) > making($1) }) else { continue }
            var low = group[0]
            var high = group[group.count - 1]
            while low > 0, stations[low - 1]?.routes.contains(line) == true { low -= 1 }
            while high < stations.count - 1, stations[high + 1]?.routes.contains(line) == true { high += 1 }
            if !stretches.contains(where: { $0.line == line && $0.calls == low...high }) { stretches.append((line, low...high)) }
        }
        return stretches
    }

    // MARK: Places

    /// Each complex's stations, for where a complex is.
    private static let complexStations: [String: [Station]] = Dictionary(grouping: StationDirectory.all, by: \.complex)

    /// Bus stops by a grid of about 550 by 420 m cells, for those near a place.
    private static let stopGrid: [Cell: [BusRoutes.Stop]] = Dictionary(grouping: BusRoutes.allStops) {
        Cell(latitude: $0.latitude, longitude: $0.longitude)
    }

    private struct Cell: Hashable {
        var x: Int
        var y: Int

        init(latitude: Double, longitude: Double) {
            x = Int((latitude * 200).rounded(.down))
            y = Int((longitude * 200).rounded(.down))
        }

        init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    /// Where a place is.
    static func location(of place: String) -> CLLocation? {
        if let code = stopCode(place) { return BusRoutes.stopByCode[code]?.location }
        return complexStations[place]?.first.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
    }

    /// Bus stops within `minutes`' walk of `location`, with the walk.
    private static func stops(near location: CLLocation, within minutes: Int) -> [(code: String, walk: Int)] {
        let cell = Cell(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        var found: [(code: String, walk: Int)] = []
        for x in (cell.x - 2)...(cell.x + 2) {
            for y in (cell.y - 2)...(cell.y + 2) {
                for stop in stopGrid[Cell(x: x, y: y)] ?? [] {
                    let walk = TripPlanner.walkMinutes(stop.location.distance(from: location))
                    if walk <= minutes { found.append((stop.code, walk)) }
                }
            }
        }
        return found
    }

    /// Complexes with a station within `minutes`' walk of `location`, with the walk.
    private static func complexes(near location: CLLocation, within minutes: Int) -> [(complex: String, walk: Int)] {
        var best: [String: Int] = [:]
        for station in StationDirectory.all where abs(station.lat - location.coordinate.latitude) < 0.012
            && abs(station.lon - location.coordinate.longitude) < 0.016 {
            let walk = TripPlanner.walkMinutes(CLLocation(latitude: station.lat, longitude: station.lon).distance(from: location))
            if walk <= minutes, best[station.complex].map({ walk < $0 }) ?? true { best[station.complex] = walk }
        }
        return best.map { ($0.key, $0.value) }
    }

    /// Where you can board next after getting off at `place`, and the walk: there; and from a
    /// station, stops nearby; from a stop, stops and stations nearby.
    private static func transfers(from place: String) -> [(place: String, walk: Int)] {
        guard let location = location(of: place) else { return [(place, 0)] }
        var found: [(place: String, walk: Int)] = [(place, 0)]
        let isStop = stopCode(place) != nil
        for stop in stops(near: location, within: isStop ? stopToStopWalk : changeWalk) where stopPlace(stop.code) != place {
            found.append((stopPlace(stop.code), stop.walk))
        }
        if isStop {
            found += complexes(near: location, within: changeWalk).map { ($0.complex, $0.walk) }
        }
        return found
    }

    /// The places that count as getting to `target`, and the walk on from each.
    private static func ends(for target: String) -> [String: Int] {
        guard let location = location(of: target) else { return [target: 0] }
        var ends: [String: Int] = [target: 0]
        for stop in stops(near: location, within: endWalk) where ends[stopPlace(stop.code)] == nil {
            ends[stopPlace(stop.code)] = stop.walk
        }
        if stopCode(target) != nil {
            for complex in complexes(near: location, within: endWalk) where ends[complex.complex] == nil {
                ends[complex.complex] = complex.walk
            }
        }
        return ends
    }

    // MARK: Reach

    /// Places you can get to from `place` (a complex or a stop) in up to `maxChanges` changes,
    /// any time: complexes and stops (`stopPlace`).
    func reachable(from place: String) -> Set<String> {
        var reached: Set<String> = []
        var frontier: Set<String> = [place]
        for ride in 0...Self.maxChanges {
            var next: Set<String> = []
            // After the first ride, walking on to board the next
            let boarding = ride == 0 ? frontier : Set(frontier.flatMap { Self.transfers(from: $0).map(\.place) })
            for from in boarding {
                for call in calling[from] ?? [] {
                    for later in runs[call.run].places[(call.index + 1)...] where later != place && !later.isEmpty {
                        if reached.insert(later).inserted { next.insert(later) }
                    }
                }
            }
            frontier = next
        }
        return reached
    }

    // MARK: Ways

    /// A way there: the lines ridden in turn and, for each change, the places it can be at.
    struct Way: Identifiable, Hashable, Sendable {
        /// Each ride's lines, as good as each other: [["R"], ["N", "Q"]], a bus's as "bus:B63".
        var rides: [[String]]
        /// Per change, its places, best first.
        var changes: [[Option]]
        /// The first ride: a train from a station going one way, or a bus from a stop.
        var start: Start
        /// Off the last ride: a train at a station, or a bus at a stop, and the walk on.
        var end: End
        /// Minutes there by part of the week (`Part`), where it runs.
        var minutes: [Part: Int]
        /// Seconds riding and changing, the timetable's way, for ranking before timing.
        var typical: Int
        /// Rides (by index) whose train is at times another line's running on its stops: the R
        /// and trains running on the local track.
        var localTrack: Set<Int> = []

        struct Start: Hashable, Sendable {
            /// A train's station and way.
            var stationID: String?
            var direction: Direction = .north
            /// A bus's stop and headsign.
            var stop: BusRoutes.Stop?
            var headsign: String?

            /// The same for ways that can be taken together: from one station going one way, or
            /// one stop on one line one way.
            var id: String {
                stationID.map { "\($0) \(direction.rawValue)" } ?? "\(stop?.code ?? "") \(headsign ?? "")"
            }
        }

        struct End: Hashable, Sendable {
            var stationID: String?
            var stop: BusRoutes.Stop?
            var walk: Int
        }

        var id: String {
            rides.map { $0.joined(separator: "") }.joined(separator: ">") + " " + start.id
                + changes.map { $0.map(\.place).joined(separator: ",") }.joined(separator: "|")
        }

        /// Starting on a bus.
        var startsOnBus: Bool { start.stop != nil }

        /// Where a change can be: off the ride before (a train at a station, a bus at a stop),
        /// a walk, onto the next (a train at a station going one way, a bus at a stop).
        struct Option: Hashable, Sendable {
            /// Where the next ride's boarded, as a place: what tells options apart.
            var place: String
            var offStationID: String?
            var offStop: BusRoutes.Stop?
            var boardStationID: String?
            var direction: Direction = .north
            var boardStop: BusRoutes.Stop?
            var headsign: String?
            /// The next ride's lines boarded here, of those a merged way rides: the N and D at
            /// Atlantic Av, the Q and B at DeKalb Av. Empty for any of them.
            var lines: [String] = []
            var across: Bool
            var walkMinutes: Int
            /// Seconds there this way, the timetable's.
            var typical: Int

            /// The station's or stop's name where it's boarded.
            var name: String {
                if let boardStop { return BusNames.readable(boardStop.name) }
                return boardStationID.flatMap(StationDirectory.station(id:))?.name ?? ""
            }

            /// Where the ride before is left, as a place.
            var offPlace: String {
                if let offStop { return WayFinder.stopPlace(offStop.code) }
                return offStationID.flatMap(StationDirectory.station(id:))?.complex ?? place
            }
        }
    }

    /// Parts of the week a way is timed at.
    struct Part: Hashable, Sendable, Comparable, CaseIterable {
        enum Day: Int, CaseIterable, Sendable { case weekday, saturday, sunday }
        enum Time: Int, CaseIterable, Sendable { case rush, day, evening, night }
        var day: Day
        var time: Time

        static let allCases: [Part] = Day.allCases.flatMap { day in Time.allCases.map { Part(day: day, time: $0) } }

        static func < (lhs: Part, rhs: Part) -> Bool {
            (lhs.day.rawValue, lhs.time.rawValue) < (rhs.day.rawValue, rhs.time.rawValue)
        }

        /// Local hour and minute it's timed at; the night's is after midnight.
        var clock: (hour: Int, minute: Int) {
            switch time {
            case .rush: (8, 15)
            case .day: (12, 30)
            case .evening: (19, 30)
            case .night: (2, 30)
            }
        }
    }

    /// One way through the places: a run per ride, where each is boarded and left, the walk
    /// before each ride after the first, and the walk at the end.
    private struct Path: Sendable {
        var rides: [(run: Int, on: Int, off: Int)]
        var walks: [Int]
        var endWalk: Int

        func seconds(_ runs: [Run]) -> Int {
            rides.reduce(0) { total, ride in
                let run = runs[ride.run]
                return total + run.seconds[ride.off] - run.seconds[ride.on] + (run.isBus ? WayFinder.busWait : 0)
            } + (rides.count - 1) * 180 + walks.reduce(0, +) * 60 + endWalk * 60
        }
    }

    /// Every way from `from` to `to` (each a complex or a stop place), grouped by the lines
    /// ridden, those much slower than the best left out unless quickest at some part of the
    /// week, each timed.
    func ways(from origin: String, to target: String) -> (listed: [Way], more: [Way]) {
        let ends = Self.ends(for: target)
        // Backward from the destination: per place, the runs from it to near there
        var toTarget: [String: [(run: Int, on: Int, off: Int, walk: Int)]] = [:]
        var runsThere = Set<Int>()
        for place in ends.keys { for call in calling[place] ?? [] { runsThere.insert(call.run) } }
        for index in runsThere {
            let run = runs[index]
            var next: (off: Int, walk: Int)?
            // From the end back: each stop's first end after it
            for on in stride(from: run.places.count - 1, through: 0, by: -1) where !run.places[on].isEmpty {
                if let found = next, ends[run.places[on]] == nil {
                    toTarget[run.places[on], default: []].append((index, on, found.off, found.walk))
                }
                if let walk = ends[run.places[on]] { next = (on, walk) }
            }
        }
        var found: [String: (path: Path, seconds: Int)] = [:]
        func add(_ path: Path) {
            // No change onto a train making the same next stop: it's on the same track (R to W)
            for (before, after) in zip(path.rides, path.rides.dropFirst()) {
                let off = runs[before.run]
                let on = runs[after.run]
                if !off.isBus, !on.isBus, before.off + 1 < off.stops.count, after.on + 1 < on.stops.count,
                   off.stops[before.off + 1] == on.stops[after.on + 1] { return }
            }
            let key = path.rides.map { ride in "\(runs[ride.run].route)@\(runs[ride.run].places[ride.on])" }
                .joined(separator: ">") + ">" + runs[path.rides[0].run].stops[path.rides[0].on]
            let seconds = path.seconds(runs)
            if found[key].map({ seconds < $0.seconds }) ?? true { found[key] = (path, seconds) }
        }
        let starts = (calling[origin] ?? []).filter { !runs[$0.run].places[..<$0.index].contains(origin) }
        // First rides: to each place along them, the quickest per line, and straight there
        var firsts: [String: [String: (ride: (run: Int, on: Int, off: Int), seconds: Int)]] = [:]
        for start in starts {
            let run = runs[start.run]
            guard start.index + 1 < run.places.count else { continue }
            for off in (start.index + 1)..<run.places.count {
                let place = run.places[off]
                if place == origin { break }
                if place.isEmpty { continue }
                if let walk = ends[place] {
                    add(Path(rides: [(start.run, start.index, off)], walks: [], endWalk: walk))
                    break
                }
                let seconds = run.seconds[off] - run.seconds[start.index]
                if firsts[place]?[run.route].map({ seconds < $0.seconds }) ?? true {
                    firsts[place, default: [:]][run.route] = ((start.run, start.index, off), seconds)
                }
            }
        }
        var transfers: [String: [(place: String, walk: Int)]] = [:]
        func near(_ place: String) -> [(place: String, walk: Int)] {
            if let known = transfers[place] { return known }
            let found = Self.transfers(from: place)
            transfers[place] = found
            return found
        }
        // One change
        for (place, byLine) in firsts {
            for (route, first) in byLine {
                for to in near(place) {
                    for last in toTarget[to.place] ?? [] where runs[last.run].route != route {
                        add(Path(rides: [first.ride, (last.run, last.on, last.off)], walks: [to.walk], endWalk: last.walk))
                    }
                }
            }
        }
        // Two changes, no slower than the limit the quicker ways set
        let quickest = found.values.map(\.seconds).min()
        let limit = quickest.map { Double($0) * 1.35 + 300 } ?? 2 * 3600
        // Middle rides: to each place along them, the quickest per first line, middle line and change
        var seconds: [String: [String: (path: Path, seconds: Int)]] = [:]
        for (place, byLine) in firsts {
            for (route, first) in byLine where Double(first.seconds) < limit {
                for to in near(place) {
                    for middle in calling[to.place] ?? [] where runs[middle.run].route != route {
                        let run = runs[middle.run]
                        guard middle.index + 1 < run.places.count else { continue }
                        for off in (middle.index + 1)..<run.places.count {
                            let stop = run.places[off]
                            if stop == origin || stop == to.place || ends[stop] != nil { break }
                            if stop.isEmpty { continue }
                            let path = Path(rides: [first.ride, (middle.run, middle.index, off)], walks: [to.walk], endWalk: 0)
                            let riding = path.seconds(runs)
                            if Double(riding) > limit { break }
                            let key = "\(route)>\(run.route)@\(to.place)"
                            if seconds[stop]?[key].map({ riding < $0.seconds }) ?? true {
                                seconds[stop, default: [:]][key] = (path, riding)
                            }
                        }
                    }
                }
            }
        }
        for (place, byKey) in seconds {
            for (_, middle) in byKey {
                let used = Set(middle.path.rides.map { runs[$0.run].route })
                for to in near(place) {
                    for last in toTarget[to.place] ?? [] where !used.contains(runs[last.run].route) {
                        var path = middle.path
                        path.rides.append((last.run, last.on, last.off))
                        path.walks.append(to.walk)
                        path.endWalk = last.walk
                        if Double(path.seconds(runs)) <= limit { add(path) }
                    }
                }
            }
        }
        guard let best = found.values.map(\.seconds).min() else { return ([], []) }
        // Much slower than the best: not worth listing; straight there always worth a look
        let cutoff = Double(best) * 1.35 + 300
        let kept = found.values.filter { Double($0.seconds) <= cutoff || $0.path.rides.count == 1 }
            .sorted { $0.seconds < $1.seconds }
        let grouped = grouped(kept.map(\.path))
        let straight = grouped.filter { $0.changes.isEmpty }
        let others = grouped.filter { !$0.changes.isEmpty }.prefix(Self.timedWays)
        let ways = timed(Array(straight.prefix(4)) + others, to: target).filter { !$0.minutes.isEmpty }
        let listed = Self.worthListing(ways)
        let more = ways.filter { way in !listed.contains { $0.id == way.id } }
            .sorted { ($0.minutes.values.min() ?? .max) < ($1.minutes.values.min() ?? .max) }
        return (listed, more)
    }

    /// How many ways are timed, quickest by the timetable first.
    private static let timedWays = 14
    /// How many are listed, besides any that's quickest at some part of the week.
    private static let listedWays = 7

    /// The quickest at each part of the week, and the quickest overall, up to `listedWays`
    /// (more if more are quickest somewhere), quickest first. Two changes only where they beat
    /// every simpler way by a few minutes, or nothing simpler runs then.
    private static func worthListing(_ ways: [Way]) -> [Way] {
        let ways = ways.filter { way in
            guard way.changes.count >= 2 else { return true }
            return way.minutes.contains { part, minutes in
                let simpler = ways.filter { $0.changes.count < 2 }.compactMap { $0.minutes[part] }.min()
                return simpler.map { minutes <= $0 - 3 } ?? true
            }
        }
        var keep = Set<String>(ways.filter { $0.changes.isEmpty }.map(\.id))
        for part in Part.allCases {
            if let fastest = ways.filter({ $0.minutes[part] != nil }).min(by: { $0.minutes[part]! < $1.minutes[part]! }) {
                keep.insert(fastest.id)
            }
        }
        let byBest = ways.sorted { ($0.minutes.values.min() ?? .max) < ($1.minutes.values.min() ?? .max) }
        for way in byBest where keep.count < listedWays { keep.insert(way.id) }
        return byBest.filter { keep.contains($0.id) }
    }

    /// A run's line as a way's ride names it: a train's route, a bus's "bus:B63".
    private func line(_ ride: (run: Int, on: Int, off: Int)) -> String { runs[ride.run].route }

    /// `paths` as ways: one per lines ridden in turn (and a bus's way), each change's places its
    /// options.
    private func grouped(_ paths: [Path]) -> [Way] {
        var byLines: [String: Way] = [:]
        var order: [String] = []
        for path in paths {
            let first = runs[path.rides[0].run]
            let boardStop = first.stops[path.rides[0].on]
            let start: Way.Start
            if first.isBus {
                guard let stop = BusRoutes.stopByCode[boardStop] else { continue }
                start = Way.Start(stop: stop, headsign: first.headsign)
            } else {
                guard let station = StationDirectory.station(forStop: boardStop),
                      let direction = Direction(ofStop: boardStop) else { continue }
                start = Way.Start(stationID: station.id, direction: direction)
            }
            let rides = path.rides.map { [line($0)] }
            let key = path.rides.map { "\(line($0)) \(runs[$0.run].headsign ?? "")" }.joined(separator: ">") + " " + start.id
            let seconds = path.seconds(runs)
            var options: [Way.Option] = []
            for (index, ride) in path.rides.dropLast().enumerated() {
                let next = path.rides[index + 1]
                let before = runs[ride.run]
                let after = runs[next.run]
                let offStop = before.stops[ride.off]
                let onStop = after.stops[next.on]
                var option = Way.Option(place: after.places[next.on], lines: [after.route], across: false,
                                        walkMinutes: path.walks[index], typical: seconds)
                if before.isBus {
                    option.offStop = BusRoutes.stopByCode[offStop]
                } else {
                    option.offStationID = StationDirectory.station(forStop: offStop)?.id
                }
                if after.isBus {
                    option.boardStop = BusRoutes.stopByCode[onStop]
                    option.headsign = after.headsign
                } else {
                    option.boardStationID = StationDirectory.station(forStop: onStop)?.id
                    option.direction = Direction(ofStop: onStop) ?? .north
                    if !before.isBus {
                        option.across = Change.isAcross(off: before.route, at: offStop, on: after.route, at: onStop)
                        option.walkMinutes = option.across ? 0
                            : Change.walkMinutes(from: offStop, to: onStop, else: Change.defaultWalkMinutes)
                    }
                }
                guard (option.offStop != nil || option.offStationID != nil),
                      (option.boardStop != nil || option.boardStationID != nil) else { continue }
                options.append(option)
            }
            guard options.count == path.rides.count - 1 else { continue }
            let last = runs[path.rides[path.rides.count - 1].run]
            let offEnd = last.stops[path.rides[path.rides.count - 1].off]
            let end = last.isBus ? Way.End(stop: BusRoutes.stopByCode[offEnd], walk: path.endWalk)
                : Way.End(stationID: StationDirectory.station(forStop: offEnd)?.id, walk: path.endWalk)
            if var way = byLines[key] {
                for (index, option) in options.enumerated() {
                    if let found = way.changes[index].firstIndex(where: { $0.place == option.place }) {
                        if option.typical < way.changes[index][found].typical { way.changes[index][found] = option }
                    } else {
                        way.changes[index].append(option)
                    }
                }
                if seconds < way.typical { way.end = end }
                way.typical = min(way.typical, seconds)
                byLines[key] = way
            } else {
                order.append(key)
                byLines[key] = Way(rides: rides, changes: options.map { [$0] }, start: start, end: end, minutes: [:],
                                   typical: seconds)
            }
        }
        // Each change's places best first, the few within reach of the best
        let ways = order.compactMap { byLines[$0] }.map { way in
            var way = way
            way.changes = way.changes.map { options in
                let sorted = options.sorted { $0.typical < $1.typical }
                let best = sorted.first?.typical ?? 0
                return Array(sorted.filter { $0.typical <= best + 8 * 60 }.prefix(4))
            }
            return way
        }
        // Changed to the same way wherever both change: across the platform at both, or not. The
        // N and D are across from the R at Atlantic Av, the Q and B a walk through the station.
        func changedAlike(_ one: Way, _ other: Way) -> Bool {
            zip(one.changes, other.changes).allSatisfy { ours, theirs in
                theirs.allSatisfy { option in ours.first { $0.place == option.place }.map { $0.across == option.across } ?? true }
            }
        }
        // Train lines as good as each other, changed to at the same place and the same way: one
        // way ("R → N D"); with one change, at a place both can be, going on along the same
        // tracks ("R → Q B", from DeKalb Av). A change's places are then those of either; each
        // only takes the lines stopping there.
        var merged: [Way] = []
        for way in ways.sorted(by: { $0.typical < $1.typical }) {
            if let index = merged.firstIndex(where: { other in
                other.rides.count == way.rides.count && other.rides.count >= 2 && other.start == way.start
                    && other.rides[0] == way.rides[0] && Array(other.rides.dropFirst(2)) == Array(way.rides.dropFirst(2))
                    && BusLeg.line(of: other.rides[1][0]) == nil && BusLeg.line(of: way.rides[1][0]) == nil
                    && (other.changes.map { $0.first?.place } == way.changes.map { $0.first?.place }
                        || other.rides.count == 2
                            && !Set(other.changes[0].map(\.place)).isDisjoint(with: way.changes[0].map(\.place))
                            && headTogether(other, way))
                    && changedAlike(other, way)
                    && abs(other.typical - way.typical) <= 4 * 60
            }) {
                merged[index].rides[1] += way.rides[1].filter { !merged[index].rides[1].contains($0) }
                for (position, options) in way.changes.enumerated() {
                    for option in options {
                        if let found = merged[index].changes[position].firstIndex(where: { $0.place == option.place }) {
                            merged[index].changes[position][found].lines += option.lines.filter {
                                !merged[index].changes[position][found].lines.contains($0)
                            }
                        } else {
                            merged[index].changes[position].append(option)
                        }
                    }
                }
            } else {
                merged.append(way)
            }
        }
        // First train lines as good as each other from the same station, then the same: one way
        // ("F G → B57")
        var together: [Way] = []
        for way in merged {
            if let index = together.firstIndex(where: { other in
                other.start == way.start && other.rides.count == way.rides.count
                    && Array(other.rides.dropFirst()) == Array(way.rides.dropFirst())
                    && BusLeg.line(of: other.rides[0][0]) == nil && BusLeg.line(of: way.rides[0][0]) == nil
                    && other.changes.map { $0.first?.place } == way.changes.map { $0.first?.place }
                    && changedAlike(other, way)
                    && abs(other.typical - way.typical) <= 3 * 60
            }) {
                together[index].rides[0] += way.rides[0].filter { !together[index].rides[0].contains($0) }
                for (position, options) in way.changes.enumerated() {
                    for option in options where !together[index].changes[position].contains(where: { $0.place == option.place }) {
                        together[index].changes[position].append(option)
                    }
                }
            } else {
                together.append(way)
            }
        }
        return together
    }

    /// Whether two ways' second rides go on along the same tracks from where they're changed to:
    /// one of their next two stops in common (the D from Atlantic Av and B from DeKalb Av at
    /// Grand St, the N and Q at Canal St), not the 3 from Atlantic Av.
    private func headTogether(_ one: Way, _ other: Way) -> Bool {
        func ahead(_ way: Way) -> Set<String> {
            var found = Set<String>()
            for option in way.changes[0] where option.boardStationID != nil {
                for call in calling[option.place] ?? [] {
                    let run = runs[call.run]
                    guard way.rides[1].contains(run.route), Direction(ofStop: run.stops[call.index]) == option.direction else { continue }
                    found.formUnion(run.places[(call.index + 1)..<min(call.index + 3, run.places.count)].filter { !$0.isEmpty })
                }
            }
            return found
        }
        // Not where they're going: lines from all over meet there
        let ends = Set([one.end, other.end].compactMap { $0.stationID.flatMap(StationDirectory.station(id:))?.complex })
        return !ahead(one).subtracting(ends).isDisjoint(with: ahead(other))
    }

    // MARK: Timing

    private static let zone = TimeZone(identifier: "America/New_York") ?? .current

    /// When each part of the week is in the timetable: the next weekday, Saturday and Sunday.
    private func moments() -> [Part: TimeInterval] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone
        let start = max(timetable.base, AppClock.now.addingTimeInterval(-3600))
        var found: [Part: TimeInterval] = [:]
        for offset in 0..<9 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: start)) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let kind: Part.Day = weekday == 7 ? .saturday : weekday == 1 ? .sunday : .weekday
            for time in Part.Time.allCases {
                let part = Part(day: kind, time: time)
                guard found[part] == nil else { continue }
                let clock = part.clock
                // The night's is that day's service, after midnight
                guard let base = calendar.date(byAdding: .day, value: time == .night ? 1 : 0, to: day),
                      let moment = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: base),
                      moment > start, timetable.covers(moment.addingTimeInterval(3 * 3600)) else { continue }
                found[part] = moment.timeIntervalSince(timetable.base)
            }
        }
        return found
    }

    /// `ways` with their minutes at each part of the week they run, and each change's places
    /// cut to those that get there about as soon as any at some time.
    private func timed(_ ways: [Way], to target: String) -> [Way] {
        let moments = moments()
        let ends = Self.ends(for: target)
        return ways.map { way in
            var way = way
            var useful = Array(repeating: Set<String>(), count: way.changes.count)
            for (part, moment) in moments {
                // Two tries ten minutes apart; the quicker
                let tries = [moment, moment + 600].compactMap { trip(way, leaving: $0, ends: ends) }
                guard let quickest = tries.min(by: { $0.minutes < $1.minutes }) else { continue }
                way.minutes[part] = quickest.minutes
                for found in tries {
                    for (index, places) in found.useful.enumerated() { useful[index].formUnion(places) }
                    way.localTrack.formUnion(found.localTrack)
                }
            }
            way.changes = zip(way.changes, useful).map { options, useful in
                let kept = options.filter { useful.contains($0.place) }
                return kept.isEmpty ? Array(options.prefix(1)) : kept
            }
            // Each ride after a change, only the lines boarded at the places kept
            for (index, options) in way.changes.enumerated() {
                let boarded = Set(options.flatMap(\.lines))
                let kept = way.rides[index + 1].filter(boarded.contains)
                if !kept.isEmpty { way.rides[index + 1] = kept }
            }
            return way
        }
    }

    /// Minutes from the first train or bus leaving to getting there, for `way` leaving at or after
    /// `time` (seconds after the timetable's base), and per change the places within a couple of
    /// minutes of the best and the rides those take another line's train on (`Way.localTrack`);
    /// nil if it doesn't run then. Trains by the timetable; buses by their minutes, from when
    /// you're at the stop (Bus Time has no week ahead).
    private func trip(_ way: Way, leaving time: TimeInterval, ends: [String: Int])
        -> (minutes: Int, useful: [Set<String>], localTrack: Set<Int>)? {
        var done: [(through: [String], total: TimeInterval, localTrack: Set<Int>)] = []
        // Ride `index` boarded at `board` (a station or a stop), from `after`
        func go(ride index: Int, lines: Set<String>, board: (station: Station?, stop: BusRoutes.Stop?, headsign: String?),
                after: TimeInterval, wait: TimeInterval, left: TimeInterval?, through: [String], localTrack: Set<Int>) {
            let last = index == way.rides.count - 1
            let targets: [(place: String, option: Way.Option?)] = last
                ? ends.keys.map { ($0, nil) }
                : way.changes[index].map { ($0.offPlace, $0) }
            for target in targets {
                guard let rode = ride(lines: lines, board: board, to: target.place, after: after, within: wait) else { continue }
                let leftAt = left ?? rode.leaves
                let local = rode.standIn ? localTrack.union([index]) : localTrack
                guard let option = target.option else {
                    let walk = TimeInterval((ends[target.place] ?? 0) * 60)
                    done.append((through, rode.arrives + walk - leftAt, local))
                    continue
                }
                let walk = TimeInterval(option.across ? 30 : option.walkMinutes * 60)
                let next = (station: option.boardStationID.flatMap(StationDirectory.station(id:)), stop: option.boardStop,
                            headsign: option.headsign)
                // Only the lines boarded at this place: the Q isn't changed to at Atlantic Av
                // because the N and D across the platform are
                let onward = Set(option.lines.isEmpty ? way.rides[index + 1] : option.lines)
                go(ride: index + 1, lines: onward, board: next, after: rode.arrives + walk, wait: 60 * 60, left: leftAt,
                   through: through + [option.place], localTrack: local)
            }
        }
        let start = (station: way.start.stationID.flatMap(StationDirectory.station(id:)), stop: way.start.stop,
                     headsign: way.start.headsign)
        go(ride: 0, lines: Set(way.rides[0]), board: start, after: time, wait: 40 * 60, left: nil, through: [], localTrack: [])
        guard let best = done.map(\.total).min() else { return nil }
        var useful = Array(repeating: Set<String>(), count: way.changes.count)
        var localTrack = Set<Int>()
        for path in done where path.total <= best + 150 {
            for (index, place) in path.through.enumerated() { useful[index].insert(place) }
            localTrack.formUnion(path.localTrack)
        }
        return (Int((best / 60).rounded()), useful, localTrack)
    }

    /// Riding `lines` from `board` after `time` (within `wait` of it) to `place`: when it leaves
    /// and gets there, and whether that's another line's train on their stops (`standIns`). A
    /// train by the timetable's soonest; a bus by its minutes, leaving then.
    private func ride(lines: Set<String>, board: (station: Station?, stop: BusRoutes.Stop?, headsign: String?),
                      to place: String, after time: TimeInterval, within wait: TimeInterval)
        -> (leaves: TimeInterval, arrives: TimeInterval, standIn: Bool)? {
        if let stop = board.stop {
            guard let code = Self.stopCode(place), let line = lines.first.flatMap(BusLeg.line(of:)),
                  let minutes = BusRoutes.ahead(on: line, from: stop.code, toward: board.headsign)
                    .first(where: { $0.stop.code == code })?.minutes else { return nil }
            return (time, time + minutes * 60, false)
        }
        guard let station = board.station, Self.stopCode(place) == nil else { return nil }
        var best: (leaves: TimeInterval, arrives: TimeInterval, standIn: Bool)?
        for stop in StationDirectory.stops(inComplexOf: station) {
            for call in timetable.calls(at: stop) {
                let pattern = timetable.patterns[call.pattern]
                guard let off = patternComplexes[call.pattern][(call.call + 1)...].firstIndex(of: place) else { continue }
                let own = lines.contains(Lines.normalized(timetable.routes[Int(pattern.route)]))
                // Another line's train, along `lines`' stops both where it's boarded and left
                let standIn = !own && (standIns[call.pattern] ?? []).contains { stretch in
                    lines.contains(stretch.line) && stretch.calls.contains(call.call) && stretch.calls.contains(off)
                }
                guard own || standIn,
                      let start = timetable.firstStart(ofPattern: call.pattern, leaving: call.call, after: time) else { continue }
                let here = pattern.calls[call.call]
                let leaves = start + TimeInterval(here.arrives) + TimeInterval(here.waits)
                guard leaves - time <= wait else { continue }
                let arrives = start + TimeInterval(pattern.calls[off].arrives)
                if best.map({ arrives < $0.arrives }) ?? true { best = (leaves, arrives, standIn) }
            }
        }
        return best
    }
}
