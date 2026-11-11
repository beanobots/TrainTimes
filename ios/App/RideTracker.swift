import CoreLocation
import Foundation
import Observation

/// Where the train you're on is, from its times rather than GPS, which can't be had underground:
/// its stops from the timetable, timed by the feed's live times as each refresh brings them, and
/// held to where the feed says the train is. While the app's open, a one-off fix as it should be
/// at each station (`check(_:)`) moves it to where it is if the times are out, as does where you
/// were when you got on, if that's along the line (`locate(_:)`). Only what the map shows: the
/// countdown keeps its own times.
@MainActor
@Observable
final class RideTracker {
    /// The train boarded, at the stop you got on.
    let train: Arrival
    /// Its stops from yours to where you get off it, once found (`build()`).
    private(set) var stops: [Stop] = []
    /// The feed's latest for the train at where you get off: its stops left, with their times,
    /// and where it is.
    private var live: Arrival?
    /// When `live` came: its train position only counts for `positionLasts` after.
    private var liveFetched = Date.now
    /// When the train gets to where you get off, if the feeds say: as the countdown has it.
    private var arrives: Date?
    /// Where a fix last found you: at `stops[index]` at `time`, or with `left`, between it and the
    /// next, having left it at `time`.
    private var fix: (index: Int, time: Date, left: Bool)?
    /// Stops already checked by a fix, by index, so each is checked once.
    private var checked: Set<Int> = []
    private let ends: Set<String>
    /// Where you were as you said you were on it, to place it by once its stops are found.
    private let boardedAt: CLLocation?

    /// A stop along the ride, and the track from it to the next.
    struct Stop: Sendable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        /// Seconds after the train leaves your stop that the timetable has it here.
        let scheduled: TimeInterval
        /// Seconds it's there for.
        let dwell: TimeInterval
        /// To the next stop; empty for the last.
        let track: [CLLocationCoordinate2D]
    }

    /// Where the train is, now.
    struct Place: Equatable {
        let coordinate: CLLocationCoordinate2D
        /// "At DeKalb Av", "Between DeKalb Av and Atlantic Av".
        let description: String

        static func == (lhs: Place, rhs: Place) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.description == rhs.description
        }
    }

    /// Seconds a train waits at a stop where the timetable doesn't say longer.
    nonisolated private static let dwell: TimeInterval = 20
    /// Metres a fix's accuracy may be: a station's Wi-Fi or a phone mast's, not just GPS.
    nonisolated private static let worstAccuracy: CLLocationAccuracy = 300
    /// Metres from a station that count as at it, if the fix isn't less accurate than that.
    private static let atStation: CLLocationDistance = 150
    /// Seconds after it's due at a station that a fix is taken: in the middle of its wait.
    private static let checkDelay: TimeInterval = 10
    /// Seconds the feed's train position holds after it's fetched: about a refresh.
    private static let positionLasts: TimeInterval = 45

    /// `boardedAt`: where you were as you said you were on it, if known.
    init(train: Arrival, to end: Station, live: Arrival?, arrives: Date?, boardedAt: CLLocation? = nil) {
        self.train = train
        self.ends = StationDirectory.stops(inComplexOf: end)
        self.live = live
        self.arrives = arrives
        self.boardedAt = boardedAt
    }

    /// Finds its stops and their track, off the main thread: the timetable's read from disk; then
    /// places it by where you got on, if that's along the line.
    func build() async {
        let train = train, ends = ends, live = live, arrives = arrives
        stops = await Task.detached(priority: .userInitiated) {
            Self.stops(of: train, to: ends, live: live, arrives: arrives)
        }.value
        if let boardedAt { locate(boardedAt) }
    }

    /// The ride's track, stop to stop, for drawing under the train.
    var path: [CLLocationCoordinate2D] { stops.flatMap(\.track) }

    /// The feeds' latest, from a refresh.
    func update(live: Arrival?, arrives: Date?) {
        if let live {
            self.live = live
            liveFetched = .now
        }
        if let arrives { self.arrives = arrives }
    }

    // MARK: Where it is

    /// Where the train is at `now`; nil until its stops are found.
    func place(at now: Date = AppClock.now) -> Place? {
        let times = times()
        guard let first = stops.first, !times.isEmpty else { return nil }
        // Not yet left, or there
        guard now >= times[0].leaves else { return Place(coordinate: first.coordinate, description: "At \(first.name)") }
        var index = times.lastIndex { $0.arrives <= now } ?? 0
        var atStop = now < times[index].leaves || index == stops.count - 1
        // Where the feed has the train, if a fix hasn't found you since: it's seen it. Only just
        // after it came, as the train's moved on since; underground, a refresh can be a while
        if let position = live?.position, now.timeIntervalSince(liveFetched) < Self.positionLasts,
           let fed = stops.firstIndex(where: { StationDirectory.isSameStop($0.id, position.stop) }),
           fed > fix?.index ?? -1 {
            if position.isStopped {
                index = fed
                atStop = true
            } else if fed > 0, index != fed - 1 || atStop {
                // On its way to `fed`: no further than just short of it, nor before the stop before
                let ahead = index >= fed
                index = fed - 1
                atStop = false
                let stop = stops[index]
                return Place(coordinate: Self.point(along: stop.track, at: ahead ? 0.9 : 0.1) ?? stop.coordinate,
                             description: "Between \(stop.name) and \(stops[fed].name)")
            }
        }
        let stop = stops[index]
        if atStop { return Place(coordinate: stop.coordinate, description: "At \(stop.name)") }
        let next = times[index + 1].arrives, left = times[index].leaves
        let part = next > left ? min(max(now.timeIntervalSince(left) / next.timeIntervalSince(left), 0), 1) : 1
        return Place(coordinate: Self.point(along: stop.track, at: part) ?? stop.coordinate,
                     description: "Between \(stop.name) and \(stops[index + 1].name)")
    }

    /// When the train gets to and leaves each of `stops`: the feed's times where it has them,
    /// your stop's as boarded, where you get off as the countdown has it, and between them the
    /// timetable's, stretched to fit; then moved to where a fix found you.
    func times() -> [(arrives: Date, leaves: Date)] {
        guard !stops.isEmpty else { return [] }
        // The feeds can still have the train to come at your stop, minutes off, once you're on it
        // (`train` then timed as you got on, `WalkSession.board()`): their times put sooner by as
        // much, until they have it gone from your stop
        let fedHere = live?.approach.first { StationDirectory.isSameStop($0.id, stops[0].id) }?.time
        let behind = max(fedHere.map { $0.timeIntervalSince(train.time) } ?? 0, 0)
        var known: [Date?] = Array(repeating: nil, count: stops.count)
        known[0] = train.time
        for stop in live?.approach ?? [] {
            if let index = stops.lastIndex(where: { StationDirectory.isSameStop($0.id, stop.id) }), index > 0 {
                known[index] = stop.time.addingTimeInterval(-behind)
            }
        }
        let last = stops.count - 1
        if last > 0, known[last] == nil { known[last] = arrives?.addingTimeInterval(-behind) }
        let dwells = stops.indices.map { $0 == 0 || $0 == last ? 0 : stops[$0].dwell }
        var times: [(arrives: Date, leaves: Date)] = []
        var previous: (index: Int, leaves: Date)?
        for index in stops.indices {
            var arrival: Date
            if index == 0 {
                arrival = train.time
            } else if let time = known[index] {
                arrival = time
            } else if let previous {
                // The timetable's share of the time between the stops either side that are known
                let after = (index + 1..<stops.count).first { known[$0] != nil }
                let from = stops[previous.index].scheduled + dwells[previous.index]
                let gone = stops[index].scheduled - from
                if let after, let then = known[after], stops[after].scheduled > from {
                    arrival = previous.leaves.addingTimeInterval(
                        gone / (stops[after].scheduled - from) * then.timeIntervalSince(previous.leaves))
                } else {
                    arrival = previous.leaves.addingTimeInterval(max(gone, 0))
                }
            } else {
                arrival = train.time
            }
            // Not before it's left the stop before
            if let previous { arrival = max(arrival, previous.leaves) }
            let leaves = index == 0 ? max(train.leaves, train.time) : arrival.addingTimeInterval(dwells[index])
            times.append((arrival, leaves))
            previous = (index, leaves)
        }
        // A fix at a stop sooner or later than it was due there moves it and those after; one
        // after it, as it left it then
        if let fix, fix.index < times.count {
            let due = times[fix.index]
            let shift = fix.left ? fix.time.timeIntervalSince(due.leaves)
                : fix.time < due.arrives ? fix.time.timeIntervalSince(due.arrives)
                : fix.time > due.leaves ? fix.time.timeIntervalSince(due.leaves) : 0
            if shift != 0 {
                for index in fix.index..<times.count {
                    times[index].arrives.addTimeInterval(shift)
                    times[index].leaves.addTimeInterval(shift)
                }
            }
        }
        return times
    }

    // MARK: Checking by a fix

    /// When to take a fix next: as the train should be waiting at the next station not yet
    /// checked and not yet left; nil once all are.
    func nextCheck(after now: Date = AppClock.now) -> (index: Int, time: Date)? {
        let times = times()
        let last = times.count - 1
        return times.indices.dropFirst()
            .first { !checked.contains($0) && $0 > fix?.index ?? 0 && ($0 == last || times[$0].leaves >= now) }
            .map { (index: $0, time: times[$0].arrives.addingTimeInterval(Self.checkDelay)) }
    }

    /// A fix taken for `stops[index]`: at whichever of the ride's stations it's at, if any, the
    /// train's put there. Too rough a fix, or one between stations, changes nothing.
    func check(_ location: CLLocation?, for index: Int) {
        checked.insert(index)
        guard let location, Self.isPlace(location), location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Self.worstAccuracy
        else { return }
        let reach = max(Self.atStation, location.horizontalAccuracy)
        let nearest = stops.indices.map { index in
            (index, location.distance(from: CLLocation(latitude: stops[index].coordinate.latitude,
                                                       longitude: stops[index].coordinate.longitude)))
        }.min { $0.1 < $1.1 }
        // Not back to a station already left
        guard let (found, meters) = nearest, meters <= reach, found >= fix?.index ?? 0 else { return }
        fix = (found, location.timestamp, false)
        checked.insert(found)
    }

    /// Where you were as you got on: at one of the ride's stations past yours, as a check finds
    /// it; else along the track between two, it's put that far along, out of the station before
    /// a matching while ago. Above ground, where a late tap still gets a fix. At your own
    /// station, or off the line, it's left to its times.
    func locate(_ location: CLLocation) {
        guard Self.isPlace(location), location.horizontalAccuracy >= 0, location.horizontalAccuracy <= Self.worstAccuracy,
              stops.count > 1 else { return }
        let reach = max(Self.atStation, location.horizontalAccuracy)
        let distances = stops.map { location.distance(from: CLLocation(latitude: $0.coordinate.latitude,
                                                                       longitude: $0.coordinate.longitude)) }
        if let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }), distances[nearest] <= reach {
            if nearest > 0 { check(location, for: nearest) }
            return
        }
        let along = stops.indices.dropLast().compactMap { index in
            Self.nearest(on: stops[index].track, to: location.coordinate).map { (index, $0.part, $0.meters) }
        }
        guard let (index, part, meters) = along.min(by: { $0.2 < $1.2 }), meters <= reach else { return }
        let times = times()
        let hop = max(times[index + 1].arrives.timeIntervalSince(times[index].leaves), 0)
        fix = (index, location.timestamp.addingTimeInterval(-part * hop), true)
        checked.formUnion(0...index)
    }

    /// Whether `location`'s somewhere: not NaN or infinite, which `CLLocation.distance` can't be
    /// trusted to rule out.
    nonisolated private static func isPlace(_ location: CLLocation) -> Bool {
        let coordinate = location.coordinate
        return coordinate.latitude.isFinite && coordinate.longitude.isFinite && CLLocationCoordinate2DIsValid(coordinate)
    }

    /// One fix, of up to `worstAccuracy`, or nil if none comes within `seconds`. From a location
    /// manager stopped then (`OneFix`): a task group racing `CLLocationUpdate.liveUpdates` against
    /// a timer waits for the cancelled loop, which only ends at its next update (`WalkFollower`),
    /// so underground, with none good enough, it went on, location with it.
    nonisolated static func fix(within seconds: TimeInterval = 15) async -> CLLocation? {
        await OneFix.get(within: seconds) { location in
            // Not one from before, cached
            location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= worstAccuracy
                && location.timestamp.timeIntervalSinceNow > -10
        }
    }

    // MARK: Its stops

    /// `train`'s stops from its own to where you get off, by the timetable's trips of its line
    /// that make them: the one calling at the stops the feed lists, taking about as long as the
    /// feed says, else just the two ends.
    nonisolated private static func stops(of train: Arrival, to ends: Set<String>, live: Arrival?,
                                          arrives: Date?) -> [Stop] {
        let ride = (arrives ?? live?.time).map { max($0.timeIntervalSince(train.leaves), 1) } ?? 1
        var calls = timetableCalls(of: train, to: ends, live: live, arrives: arrives)
            ?? lineCalls(of: train, to: ends, taking: ride) ?? []
        if calls.isEmpty {
            // Just the ends, the ride as long as the feed says
            let end = live?.stop ?? ends.sorted().first ?? train.stop
            calls = [(id: train.stop, scheduled: 0, waits: 0), (id: end, scheduled: ride, waits: 0)]
        }
        let places = calls.compactMap { call in
            StationDirectory.station(forStop: call.id).map { (call, $0) }
        }
        let centers = places.map { CLLocationCoordinate2D(latitude: $0.1.lat, longitude: $0.1.lon) }
        // Each stop to the next along the track, its corners curved as the trip map's are
        let tracks = centers.indices.map { index in
            guard index + 1 < centers.count else { return [CLLocationCoordinate2D]() }
            let here = centers[index], there = centers[index + 1]
            return TrackShapes.rounded(TrackShapes.track(of: train.route, from: here, to: there) ?? [here, there])
        }
        return places.indices.map { index in
            let (call, station) = places[index]
            // Where the track passes it, so the train's on the line at a station
            let onTrack = tracks[index].first ?? (index > 0 ? tracks[index - 1].last : nil) ?? centers[index]
            return Stop(id: call.id, name: StationDirectory.shortName(forStop: call.id) ?? station.name,
                        coordinate: onTrack, scheduled: call.scheduled, dwell: max(call.waits, dwell),
                        track: tracks[index])
        }
    }

    /// The timetable's calls from `train`'s stop to the first of `ends`, as seconds after leaving
    /// its stop; nil without a timetable or a trip of its line making both.
    nonisolated private static func timetableCalls(of train: Arrival, to ends: Set<String>, live: Arrival?,
                                                   arrives: Date?) -> [(id: String, scheduled: TimeInterval, waits: TimeInterval)]? {
        guard let timetable = TimetableStore.load() else { return nil }
        let fed = Set((live?.approach ?? []).map(\.id))
        let expected = (arrives ?? live?.time).map { $0.timeIntervalSince(train.leaves) }
        var best: (score: (Int, Double), calls: [(id: String, scheduled: TimeInterval, waits: TimeInterval)])?
        var seen: Set<[UInt16]> = []
        for (index, start) in timetable.calls(at: train.stop) {
            let pattern = timetable.patterns[index]
            guard Lines.normalized(timetable.routes[Int(pattern.route)]) == train.route,
                  let end = pattern.calls[(start + 1)...].firstIndex(where: { ends.contains(timetable.stops[Int($0.stop)]) })
            else { continue }
            let made = Array(pattern.calls[start...end])
            guard seen.insert(made.map(\.stop)).inserted else { continue }
            let leaves = TimeInterval(made[0].arrives) + TimeInterval(made[0].waits)
            let calls = made.map { call in
                (id: timetable.stops[Int(call.stop)], scheduled: TimeInterval(call.arrives) - leaves,
                 waits: TimeInterval(call.waits))
            }
            // Fewest of the feed's stops missed, then nearest the time it says
            let ids = calls.map(\.id)
            let missed = fed.filter { id in !ids.contains { StationDirectory.isSameStop($0, id) } }.count
            let off = expected.map { abs((calls.last?.scheduled ?? 0) - $0) } ?? 0
            if best.map({ (missed, off) < $0.score }) ?? true { best = ((missed, off), calls) }
        }
        return best?.calls
    }

    /// Without a timetable, the line's own stations from `train`'s stop to the first of `ends`
    /// (lines.json's order), the ride's `seconds` shared out by distance; nil if it doesn't make
    /// both along one branch.
    nonisolated private static func lineCalls(of train: Arrival, to ends: Set<String>, taking seconds: TimeInterval)
        -> [(id: String, scheduled: TimeInterval, waits: TimeInterval)]? {
        // Platform ids without the N or S, which the trip's own stop says
        let platform = { (stop: String) in stop.last == "N" || stop.last == "S" ? String(stop.dropLast()) : stop }
        let heading = train.stop.last.map(String.init) ?? ""
        let origin = platform(train.stop), targets = Set(ends.map(platform))
        for branch in StationDirectory.branches(of: train.route) {
            guard let from = branch.firstIndex(of: origin), let to = branch.firstIndex(where: targets.contains),
                  from != to else { continue }
            let ids = (from < to ? Array(branch[from...to]) : Array(branch[to...from].reversed())).map { $0 + heading }
            let places = ids.compactMap { StationDirectory.station(forStop: $0) }
                .map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
            guard places.count == ids.count else { return nil }
            let hops = zip(places, places.dropFirst()).map { $0.distance(from: $1) }
            let total = max(hops.reduce(0, +), 1)
            var gone: Double = 0
            return ids.enumerated().map { index, id in
                if index > 0 { gone += hops[index - 1] }
                return (id: id, scheduled: gone / total * seconds, waits: 0)
            }
        }
        return nil
    }

    /// The point of `path` nearest `point`: how far along it by distance, and its metres from
    /// `point`; nil for a path without a length. Flat, as a hop between stations is short.
    nonisolated private static func nearest(on path: [CLLocationCoordinate2D], to point: CLLocationCoordinate2D)
        -> (part: Double, meters: Double)? {
        // Its pieces' lengths, flat as `TrackShapes.nearest` takes them, for how far along it is
        let across = Earth.metresPerDegree * cos(point.latitude * .pi / 180)
        let lengths = zip(path, path.dropFirst()).map { a, b in
            hypot((b.longitude - a.longitude) * across, (b.latitude - a.latitude) * Earth.metresPerDegree)
        }
        let total = lengths.reduce(0, +)
        guard total > 0, let at = TrackShapes.nearest(point, on: path) else { return nil }
        let gone = lengths.prefix(at.segment).reduce(0, +) + at.along * lengths[at.segment]
        return (gone / total, at.meters)
    }

    /// The point `part` of the way along `path` by distance; nil for an empty path.
    nonisolated private static func point(along path: [CLLocationCoordinate2D], at part: Double) -> CLLocationCoordinate2D? {
        guard let first = path.first else { return nil }
        let locations = path.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let lengths = zip(locations, locations.dropFirst()).map { $0.distance(from: $1) }
        var left = lengths.reduce(0, +) * part
        for (index, length) in lengths.enumerated() {
            if left <= length, length > 0 {
                let a = path[index], b = path[index + 1], t = left / length
                return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                              longitude: a.longitude + (b.longitude - a.longitude) * t)
            }
            left -= length
        }
        return path.last ?? first
    }
}

/// One location from a location manager, the first `accepts` takes, or nil after `seconds`; the
/// manager's stopped there and then, however the fixes come or don't.
@MainActor
private final class OneFix: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let accepts: @Sendable (CLLocation) -> Bool
    private var waiting: CheckedContinuation<CLLocation?, Never>?

    private init(accepts: @escaping @Sendable (CLLocation) -> Bool) {
        self.accepts = accepts
    }

    static func get(within seconds: TimeInterval,
                    accepting accepts: @escaping @Sendable (CLLocation) -> Bool) async -> CLLocation? {
        // Prototyping's Pretend Location, while set
        if let pretend = PretendLocation.current { return accepts(pretend) ? pretend : nil }
        let fix = OneFix(accepts: accepts)
        return await withCheckedContinuation { continuation in
            fix.waiting = continuation
            fix.manager.delegate = fix
            // Fixes of up to `worstAccuracy` are taken: Wi-Fi and cell come sooner and cheaper
            // than GPS, which underground mostly can't get one at all
            fix.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            fix.manager.startUpdatingLocation()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                fix.finish(nil)
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        guard let waiting else { return }
        self.waiting = nil
        manager.stopUpdatingLocation()
        manager.delegate = nil
        waiting.resume(returning: location)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: accepts) else { return }
        Task { @MainActor in
            guard PretendLocation.shared.coordinate == nil else { return }
            self.finish(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
