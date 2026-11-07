import Foundation

/// Every way from one station to another in up to two changes, worked out from the week's
/// timetable (`Timetable`), for planning a saved route: which lines, where to change, when each
/// way runs and how long it takes then. Stations count as their complex, so a change inside a
/// complex is one change.
struct WayFinder: Sendable {
    /// Two changes at most: three rides.
    static let maxChanges = 2

    /// A run of stops some trains of a line make, as the timetable has it, each stop with its
    /// seconds from the first.
    struct Run: Sendable {
        var route: String
        var stops: [String]
        var complexes: [String]
        var seconds: [Int]
    }

    let timetable: Timetable
    let runs: [Run]
    /// Each complex's runs and where they call there, by complex.
    private let calling: [String: [(run: Int, index: Int)]]

    init(timetable: Timetable) {
        self.timetable = timetable
        var seen = Set<String>()
        var runs: [Run] = []
        for pattern in timetable.patterns {
            let route = Lines.normalized(timetable.routes[Int(pattern.route)])
            let stops = pattern.calls.map { timetable.stops[Int($0.stop)] }
            let key = route + " " + stops.joined(separator: ",")
            guard seen.insert(key).inserted else { continue }
            let complexes = stops.map { StationDirectory.station(forStop: $0)?.complex ?? $0 }
            runs.append(Run(route: route, stops: stops, complexes: complexes, seconds: pattern.calls.map { Int($0.arrives) }))
        }
        self.runs = runs
        var calling: [String: [(run: Int, index: Int)]] = [:]
        for (index, run) in runs.enumerated() {
            for (position, complex) in run.complexes.enumerated() {
                calling[complex, default: []].append((index, position))
            }
        }
        self.calling = calling
    }

    // MARK: Reach

    /// Complexes you can get to from `complex` in up to `maxChanges` changes, any time.
    func reachable(from complex: String) -> Set<String> {
        var reached: Set<String> = []
        var frontier: Set<String> = [complex]
        for _ in 0...Self.maxChanges {
            var next: Set<String> = []
            for place in frontier {
                for call in calling[place] ?? [] {
                    for later in runs[call.run].complexes[(call.index + 1)...] where later != complex {
                        if reached.insert(later).inserted { next.insert(later) }
                    }
                }
            }
            frontier = next
        }
        return reached
    }

    // MARK: Ways

    /// A way there: the lines ridden in turn and, for each change, the stations it can be at.
    struct Way: Identifiable, Hashable, Sendable {
        /// Each ride's lines, as good as each other, e.g. [["R"], ["N", "Q"]].
        var rides: [[String]]
        /// Per change, its stations, best first.
        var changes: [[Option]]
        /// The station the first ride leaves from, and which way.
        var fromStationID: String
        var direction: Direction
        /// Minutes there by part of the week (`Part`), where it runs.
        var minutes: [Part: Int]
        /// Seconds riding and changing, the timetable's way, for ranking before timing.
        var typical: Int

        var id: String {
            rides.map { $0.joined(separator: "") }.joined(separator: ">") + " " + fromStationID
                + changes.map { $0.map(\.complex).joined(separator: ",") }.joined(separator: "|")
        }

        /// Where a change can be: off the ride before at `stationID`, onto the next at `boardID`.
        struct Option: Hashable, Sendable {
            var complex: String
            var stationID: String
            var boardID: String
            /// The next lines leave going this way.
            var direction: Direction
            var across: Bool
            var walkMinutes: Int
            /// Seconds there this way, the timetable's.
            var typical: Int

            var name: String { StationDirectory.station(id: stationID)?.name ?? "" }
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

    /// One way through the stations: a run per ride, where each is boarded and left.
    private struct Path {
        var rides: [(run: Int, on: Int, off: Int)]

        func seconds(_ runs: [Run]) -> Int {
            rides.reduce(0) { $0 + runs[$1.run].seconds[$1.off] - runs[$1.run].seconds[$1.on] }
                + (rides.count - 1) * 180
        }
    }

    /// Every way from `from` to `to`, grouped by the lines ridden, those much slower than the
    /// best left out unless they're the only one at some part of the week, each timed.
    func ways(from: Station, to: Station) -> [Way] {
        let origin = from.complex
        let target = to.complex
        // Backward from the destination: per complex, the runs from it to there
        var toTarget: [String: [(run: Int, on: Int, off: Int)]] = [:]
        for call in calling[target] ?? [] {
            let run = runs[call.run]
            for on in 0..<call.index where run.complexes[on] != target {
                // The first time the run gets there after boarding
                guard let off = run.complexes[(on + 1)...].firstIndex(of: target), off == call.index else { continue }
                toTarget[run.complexes[on], default: []].append((call.run, on, off))
            }
        }
        var paths: [Path] = []
        for start in calling[origin] ?? [] {
            let first = runs[start.run]
            // Boarding where you are: not again later in the run
            guard first.complexes[..<start.index].contains(origin) == false else { continue }
            for off in (start.index + 1)..<first.complexes.count {
                let place = first.complexes[off]
                if place == origin { break }
                if place == target {
                    paths.append(Path(rides: [(start.run, start.index, off)]))
                    break
                }
                // One change: a run from here to there
                for last in toTarget[place] ?? [] where runs[last.run].route != first.route {
                    paths.append(Path(rides: [(start.run, start.index, off), last]))
                }
                // Two changes: a middle run to somewhere with a run there
                for middle in calling[place] ?? [] where runs[middle.run].route != first.route {
                    let run = runs[middle.run]
                    guard middle.index + 1 < run.complexes.count else { continue }
                    for second in (middle.index + 1)..<run.complexes.count {
                        let stop = run.complexes[second]
                        if stop == origin || stop == place || stop == target { break }
                        for last in toTarget[stop] ?? []
                        where runs[last.run].route != run.route && runs[last.run].route != first.route {
                            paths.append(Path(rides: [(start.run, start.index, off), (middle.run, middle.index, second), last]))
                        }
                    }
                }
            }
        }
        guard let best = paths.map({ $0.seconds(runs) }).min() else { return [] }
        // Much slower than the best by the timetable's running times: not worth listing
        let limit = Double(best) * 1.6 + 600
        let kept = paths.filter { Double($0.seconds(runs)) <= limit }
        return timed(grouped(kept))
    }

    /// `paths` as ways: one per lines ridden in turn, each change's stations its options.
    private func grouped(_ paths: [Path]) -> [Way] {
        var byLines: [String: Way] = [:]
        var order: [String] = []
        for path in paths {
            let rides = path.rides.map { [runs[$0.run].route] }
            let firstRun = runs[path.rides[0].run]
            let fromStop = firstRun.stops[path.rides[0].on]
            guard let fromStation = StationDirectory.station(forStop: fromStop),
                  let direction = Direction(ofStop: fromStop) else { continue }
            let key = rides.map { $0[0] }.joined(separator: ">") + " " + fromStation.id + direction.rawValue
            let seconds = path.seconds(runs)
            var options: [Way.Option] = []
            for (index, ride) in path.rides.dropLast().enumerated() {
                let next = path.rides[index + 1]
                let offStop = runs[ride.run].stops[ride.off]
                let onStop = runs[next.run].stops[next.on]
                guard let offStation = StationDirectory.station(forStop: offStop),
                      let onStation = StationDirectory.station(forStop: onStop),
                      let way = Direction(ofStop: onStop) else { continue }
                let across = Change.isAcross(off: runs[ride.run].route, at: offStop, on: runs[next.run].route, at: onStop)
                options.append(Way.Option(complex: offStation.complex, stationID: offStation.id, boardID: onStation.id,
                                          direction: way, across: across,
                                          walkMinutes: across ? 0 : Change.walkMinutes(from: offStop, to: onStop,
                                                                                        else: Change.defaultWalkMinutes),
                                          typical: seconds))
            }
            guard options.count == path.rides.count - 1 else { continue }
            if var way = byLines[key] {
                for (index, option) in options.enumerated() {
                    if let found = way.changes[index].firstIndex(where: { $0.complex == option.complex }) {
                        if option.typical < way.changes[index][found].typical { way.changes[index][found] = option }
                    } else {
                        way.changes[index].append(option)
                    }
                }
                way.typical = min(way.typical, seconds)
                byLines[key] = way
            } else {
                order.append(key)
                byLines[key] = Way(rides: rides, changes: options.map { [$0] }, fromStationID: fromStation.id,
                                   direction: direction, minutes: [:], typical: seconds)
            }
        }
        // Each change's stations best first, the few within reach of the best
        var ways = order.compactMap { byLines[$0] }.map { way in
            var way = way
            way.changes = way.changes.map { options in
                let sorted = options.sorted { $0.typical < $1.typical }
                let best = sorted.first?.typical ?? 0
                return Array(sorted.filter { $0.typical <= best + 8 * 60 }.prefix(4))
            }
            return way
        }
        // Lines as good as each other, changed to at the same station: one way ("R → N Q")
        var merged: [Way] = []
        for way in ways.sorted(by: { $0.typical < $1.typical }) {
            if let index = merged.firstIndex(where: { other in
                other.rides.count == way.rides.count && other.rides.count >= 2 && other.fromStationID == way.fromStationID
                    && other.rides[0] == way.rides[0] && Array(other.rides.dropFirst(2)) == Array(way.rides.dropFirst(2))
                    && other.changes.map { $0.first?.complex } == way.changes.map { $0.first?.complex }
                    && abs(other.typical - way.typical) <= 4 * 60
            }) {
                merged[index].rides[1] += way.rides[1].filter { !merged[index].rides[1].contains($0) }
                for (position, options) in way.changes.enumerated() {
                    for option in options where !merged[index].changes[position].contains(where: { $0.complex == option.complex }) {
                        merged[index].changes[position].append(option)
                    }
                }
            } else {
                merged.append(way)
            }
        }
        ways = merged
        return ways
    }

    // MARK: Timing

    private static let zone = TimeZone(identifier: "America/New_York") ?? .current

    /// When each part of the week is in the timetable: the next weekday, Saturday and Sunday.
    private func moments() -> [Part: TimeInterval] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone
        let start = max(timetable.base, Date.now.addingTimeInterval(-3600))
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

    /// `ways` with their minutes at each part of the week they run.
    private func timed(_ ways: [Way]) -> [Way] {
        let moments = moments()
        return ways.map { way in
            var way = way
            for (part, moment) in moments {
                // Two tries ten minutes apart; the quicker
                let tries = [moment, moment + 600].compactMap { trip(way, leaving: $0) }
                if let minutes = tries.min() { way.minutes[part] = minutes }
            }
            return way
        }
    }

    /// Minutes from the first train leaving to getting there, for `way` with its first train
    /// leaving at or after `time` (seconds after the timetable's base); nil if it doesn't run
    /// then: no train within 40 minutes, or a change with nothing on within an hour.
    private func trip(_ way: Way, leaving time: TimeInterval) -> Int? {
        guard let from = StationDirectory.station(id: way.fromStationID) else { return nil }
        // The complexes ridden between, in turn: each change's options, then the destination
        let targets = way.changes.map { Set($0.map(\.complex)) }
        var best: Int?
        // Each first-ride line's soonest train
        guard let first = ride(lines: Set(way.rides[0]), from: StationDirectory.stops(inComplexOf: from), going: way.direction,
                               to: targets.first ?? [destination(way)], after: time, within: 40 * 60) else { return nil }
        var at = first
        for (index, lines) in way.rides.enumerated().dropFirst() {
            let options = way.changes[index - 1].filter { $0.complex == at.complex }
            guard let option = options.first, let board = StationDirectory.station(id: option.boardID) else { return nil }
            let walk = TimeInterval(option.across ? 30 : option.walkMinutes * 60)
            let to = index < targets.count ? targets[index] : [destination(way)]
            guard let next = ride(lines: Set(lines), from: StationDirectory.stops(inComplexOf: board), going: option.direction,
                                  to: to, after: at.arrives + walk, within: 60 * 60) else { return nil }
            at = next
        }
        best = Int(((at.arrives - first.leaves) / 60).rounded())
        return best
    }

    /// The destination's complex, as ways are found for one.
    private func destination(_ way: Way) -> String { destinationComplex }

    /// Set by `ways(from:to:)` callers through `planning(to:)`.
    private var destinationComplex = ""

    /// This finder, timing ways to `station`.
    func planning(to station: Station) -> WayFinder {
        var finder = self
        finder.destinationComplex = station.complex
        return finder
    }

    /// The soonest a train of `lines` leaving `stops` (going `direction`) after `time` gets to
    /// any of `complexes`: when it leaves and gets there, and where.
    private func ride(lines: Set<String>, from stops: Set<String>, going direction: Direction, to complexes: Set<String>,
                      after time: TimeInterval, within wait: TimeInterval)
        -> (leaves: TimeInterval, arrives: TimeInterval, complex: String)? {
        var best: (leaves: TimeInterval, arrives: TimeInterval, complex: String)?
        for stop in stops where Direction(ofStop: stop) == direction || lines.count > 0 {
            for call in timetable.calls(at: stop) {
                let pattern = timetable.patterns[call.pattern]
                guard lines.contains(Lines.normalized(timetable.routes[Int(pattern.route)])) else { continue }
                // The first of `complexes` it gets to after here
                guard let off = pattern.calls[(call.call + 1)...].firstIndex(where: { called in
                    let id = timetable.stops[Int(called.stop)]
                    return complexes.contains(StationDirectory.station(forStop: id)?.complex ?? id)
                }) else { continue }
                guard let start = timetable.firstStart(ofPattern: call.pattern, leaving: call.call, after: time) else { continue }
                let here = pattern.calls[call.call]
                let leaves = start + TimeInterval(here.arrives) + TimeInterval(here.waits)
                guard leaves - time <= wait else { continue }
                let arrives = start + TimeInterval(pattern.calls[off].arrives)
                if best.map({ arrives < $0.arrives }) ?? true {
                    let id = timetable.stops[Int(pattern.calls[off].stop)]
                    best = (leaves, arrives, StationDirectory.station(forStop: id)?.complex ?? id)
                }
            }
        }
        return best
    }
}
