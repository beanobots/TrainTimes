import CoreLocation
import MapKit
import SwiftUI
import Synchronization

/// The lines round a place, for Nearby's and New Trip's maps: each subway line's track
/// (`TrackShapes`), beside the others where they run together as New Trip draws a trip's, and
/// each bus line's streets, drawn pale under them.
struct NearbyLines {
    struct Track {
        let route: String
        let coordinates: [CLLocationCoordinate2D]
        /// For each point, how many lane widths to its right it's drawn (`TripMap.laneOffsets`).
        let lanes: [Double]

        /// Whether it runs beside another anywhere, for drawing it the narrower width.
        var isBeside: Bool { lanes.contains { $0 != 0 } }
    }

    let tracks: [Track]
    /// Which laying out of the subway's tracks `tracks` is: the same while they are, however the
    /// bus lines change, for the map to keep them drawn (`NearbyLinesLayer`).
    private(set) var tracksID = 0
    /// Each bus line's each way, on its own side of the street (`BusNetwork`), whole.
    let buses: [[CLLocationCoordinate2D]]
    /// Those of the bus lines not stopping at a stop opened on Nearby's map, drawn fainter.
    var fadedBuses: [[CLLocationCoordinate2D]] = []
    /// Which way a stop's buses go, and its place on their line.
    var sides = BusSides.none

    static let none = NearbyLines(tracks: [], buses: [])

    /// Where they are, about: for meters a map point is there.
    var latitude: Double {
        (tracks.first?.coordinates.first ?? buses.first?.first)?.latitude ?? 40.7
    }

    /// Meters from a line's track already drawn that another of its shapes (a branch, a
    /// late-night route) is taken to be on it, and not drawn again.
    private static let sameTrack: Double = 60
    /// Meters a shape must keep within `sameTrack` of one drawn to be taken to run along it,
    /// rather than cross it: more than it's that near crossing a street at a slant.
    private static let alongDrawn: Double = 200
    /// Meters long, at most, a subway route's other shape may leave its line drawn and come back
    /// for that to be left out as a loop beside it rather than drawn as a branch.
    private static let loopLength: Double = 1_500

    private init(tracks: [Track], buses: [[CLLocationCoordinate2D]]) {
        self.tracks = tracks
        self.buses = buses
    }

    /// `routes`' tracks (round `points`, or every route's whole length, `allRoutes`) and
    /// `busLines`' ways; with `brightBusLines` (as `TrackShapes.busKey` has them), the other bus
    /// lines' faded. The whole subway's even with no place yet, as before you're found.
    init(routes: [String], busLines: [String], brightBusLines: Set<String>? = nil, around points: [CLLocationCoordinate2D]) {
        (tracks, tracksID) = Self.wholeTracks(of: routes, around: points)
        // Each line's ways whole, on its own side of each street: lines sharing a street the same
        // way lie exactly over each other there (`BusNetwork`), drawn the one solid colour
        let ways = BusNetwork.ways(of: busLines)
        // A piece bright if any line along it is
        let isBright = { (way: BusNetwork.Way) in brightBusLines.map { !$0.isDisjoint(with: way.lines) } ?? true }
        buses = ways.filter(isBright).map(\.coordinates)
        fadedBuses = ways.filter { !isBright($0) }.map(\.coordinates)
        sides = BusSides(ways: ways)
    }

    /// Meters past the places the subway's lines are drawn: their whole length, across the
    /// city, so they show however far out the map's zoomed.
    private static let wholeReach: Double = 60_000

    /// Every line the stations list: the whole subway, as Nearby's map draws it.
    static let allRoutes: [String] = Array(Set(StationDirectory.all.flatMap(\.routes))).sorted()

    /// `allRoutes`' tracks, laid out once (at launch, off the main thread): the same however the
    /// map's moved, and slow to lay out along their whole length.
    static let allTracks: [Track] = {
        let tracks = layOut(allRoutes, around: [CLLocationCoordinate2D(latitude: 40.73, longitude: -73.94)])
        allTracksLaidOut.store(true, ordering: .releasing)
        return tracks
    }()

    private static let allTracksLaidOut = Atomic(false)

    /// Whether `allTracks` is laid out, for the main thread not to wait on it, or lay it out.
    static var allTracksReady: Bool { allTracksLaidOut.load(ordering: .acquiring) }

    /// `allTracks`' `tracksID`; others' counted on from it.
    private static let allTracksID = 1

    /// The last other subway tracks laid out, by their routes, as `allTracks`, and their
    /// `tracksID`. Locked, as New Trip lays them out off the main thread.
    private static let lastTracks = Mutex<(routes: [String], tracks: [Track], id: Int)?>(nil)

    /// `routes`' whole tracks, beside each other where they run together; lines of a colour
    /// running together once, as one line, stretch by stretch (`runs`); and their `tracksID`.
    private static func wholeTracks(of routes: [String], around points: [CLLocationCoordinate2D]) -> ([Track], Int) {
        var seen: Set<String> = []
        let routes = routes.filter { seen.insert($0).inserted }.sorted()
        if routes.isEmpty { return ([], 0) }
        if routes == allRoutes { return (allTracks, allTracksID) }
        if let last = lastTracks.withLock({ $0 }), last.routes == routes { return (last.tracks, last.id) }
        let tracks = layOut(routes, around: points)
        return lastTracks.withLock { last in
            let id = max(last?.id ?? allTracksID, allTracksID) + 1
            last = (routes, tracks, id)
            return (tracks, id)
        }
    }

    /// `routes`' (sorted, once each) tracks within `wholeReach` of `points`, laid out side by side.
    private static func layOut(_ routes: [String], around points: [CLLocationCoordinate2D]) -> [Track] {
        guard let box = box(around: points, reach: wholeReach) else { return [] }
        let runs = runs(of: routes, in: TrackShapes.byRoute, box: box)
        let coordinates = runs.map { $0.points.map(\.coordinate) }
        let lanes = TripMap.laneOffsets(coordinates, colors: runs.map { LineStyle.of($0.route).color }, width: 1)
        let tracks = runs.indices.map { index in
            Track(route: runs[index].route, coordinates: coordinates[index],
                  lanes: lanes.indices.contains(index) ? lanes[index] : [])
        }
        return tracks
    }

    /// The bus lines stopping within `meters` of `point`, nearest stop first: those a few
    /// minutes' walk away, without asking Bus Time for its stops. By their stops (`TrackShapes.busStops`),
    /// as Nearby's are, not their streets: an express bus on a highway, or a line turning at the
    /// end of its route, passes near without stopping.
    static func busLines(near point: CLLocationCoordinate2D, within meters: Double) -> [String] {
        let here = CLLocation(latitude: point.latitude, longitude: point.longitude)
        let degrees = meters / Earth.metresPerDegree
        var nearest: [String: Double] = [:]
        for stop in TrackShapes.busStops
        where abs(stop.coordinate.latitude - point.latitude) < degrees
            && abs(stop.coordinate.longitude - point.longitude) < degrees * 1.4 {
            let distance = CLLocation(latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude).distance(from: here)
            guard distance < meters else { continue }
            // Only lines drawn (`BusNetwork`)
            for line in stop.lines where BusNetwork.byLine[line] != nil {
                nearest[line] = min(nearest[line] ?? .infinity, distance)
            }
        }
        return nearest.sorted { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }.map(\.key)
    }

    /// The lines stopping at the `nearestStops` bus stops nearest `place` within `busStopsReach`:
    /// those Nearby draws round where it is, and New Trip round From before it's planned.
    static func nearestStopsLines(near place: CLLocation?) -> Set<String> {
        guard let place else { return [] }
        let degrees = busStopsReach / Earth.metresPerDegree
        let near = TrackShapes.busStops
            .filter { abs($0.coordinate.latitude - place.coordinate.latitude) < degrees
                && abs($0.coordinate.longitude - place.coordinate.longitude) < degrees * 1.4 }
            .map { stop in
                (stop: stop, meters: CLLocation(latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude)
                    .distance(from: place))
            }
            .filter { $0.meters < busStopsReach }
            .sorted { $0.meters < $1.meters }
        return Set(near.prefix(nearestStops).flatMap(\.stop.lines))
    }

    /// Meters, and how many stops (about three places, a stop each way), whose lines are drawn.
    static let busStopsReach: Double = 400
    static let nearestStops = 6

    /// `points`' bounds, `reach` meters round.
    private static func box(around points: [CLLocationCoordinate2D], reach: Double) -> MKMapRect? {
        guard let first = points.first else { return nil }
        let mapPoints = points.map(MKMapPoint.init)
        let xs = mapPoints.map(\.x), ys = mapPoints.map(\.y)
        let pad = reach * MKMapPointsPerMeterAtLatitude(first.latitude)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return MKMapRect(x: minX - pad, y: minY - pad,
                         width: (xs.max() ?? 0) - minX + pad * 2, height: (ys.max() ?? 0) - minY + pad * 2)
    }

    /// A run's end joined onto a line drawn before it: that run, and its point.
    struct Join {
        let run: Int
        let point: Int
    }

    /// A stretch of a route's shape drawn, and the runs before it its ends are joined onto.
    struct Run {
        let route: String
        let points: [MKMapPoint]
        var start: Join?
        var end: Join?
    }

    /// Each of `routes`' shapes, the longest first, where it's in `box` and not on one of its
    /// colour's already drawn (the 4's for the 5 along Lexington Av, not where they part).
    private static func runs(of routes: [String], in shapes: [String: [[CLLocationCoordinate2D]]],
                             box: MKMapRect) -> [Run] {
        var runs: [Run] = []
        var seen: Set<String> = []
        // A little over `sameTrack` a cell, as map points a meter vary a little across the box
        let cell = sameTrack * 1.1 * MKMapPointsPerMeterAtLatitude(MKMapPoint(x: box.midX, y: box.midY).coordinate.latitude)
        for route in routes where seen.insert(route).inserted {
            let color = LineStyle.of(route).color
            let isKept = { (run: Run) in LineStyle.of(run.route).color == color }
            var kept = PointGrid(runs, where: isKept, cell: cell)
            for (shapeIndex, shape) in (shapes[route] ?? []).enumerated() {
                var run: [MKMapPoint] = []
                var last: MKMapPoint?
                // Whether the run began off the line drawn, rather than at the shape's start,
                // and where on it
                var startsJoined = false
                var startJoin: Join?
                func finish(at end: (point: MKMapPoint, join: Join?)?) {
                    // Joined to where it meets the track drawn, so a branch doesn't start apart
                    if let end, !run.isEmpty { run.append(end.point) }
                    let length = zip(run, run.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
                    // A subway route's other shape leaving its line drawn and back a little on (an
                    // R detour beside Broadway, Prince St to Canal St) isn't a branch but a loop
                    // beside it
                    let isLoop = shapeIndex > 0 && startsJoined && end != nil && length < Self.loopLength
                    if run.count > 1, !isLoop { runs.append(Run(route: route, points: run, start: startJoin, end: end?.join)) }
                    run = []
                    startsJoined = false
                    startJoin = nil
                }
                let points = TripMap.densified(shape).map(MKMapPoint.init)
                var drawn = points.map { point in
                    box.contains(point) && kept.isNear(point, within: sameTrack)
                }
                // Only where it runs along one drawn, not where it crosses one, which would
                // leave a gap either side of the street it crosses
                var start = 0
                while start < points.count {
                    guard drawn[start] else {
                        start += 1
                        continue
                    }
                    var end = start
                    while end + 1 < points.count, drawn[end + 1] { end += 1 }
                    let along = zip(points[start...end], points[start...end].dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
                    if along < alongDrawn {
                        for index in start...end { drawn[index] = false }
                    }
                    start = end + 1
                }
                // Its ends joined onto the line drawn, not where its own track is, up to
                // `sameTrack` off it: the 2 left loose beside the 1 at Chambers St
                let onDrawn = { (point: MKMapPoint) -> (point: MKMapPoint, join: Join?) in
                    kept.nearest(to: point, within: sameTrack).map { ($0.point, $0.join) } ?? (point, nil)
                }
                for (point, isDrawn) in zip(points, drawn) {
                    if !box.contains(point) {
                        finish(at: nil)
                    } else if isDrawn {
                        finish(at: onDrawn(point))
                    } else {
                        if run.isEmpty, let last, box.contains(last) {
                            let joined = onDrawn(last)
                            run.append(joined.point)
                            startJoin = joined.join
                            startsJoined = true
                        }
                        run.append(point)
                    }
                    last = point
                }
                finish(at: nil)
                kept = PointGrid(runs, where: isKept, cell: cell)
            }
        }
        return runs
    }

    /// Points by the square they're in, `cell` map points across, to tell whether one's near a
    /// point within a cell's width without looking at every one.
    private struct PointGrid {
        private let cell: Double
        private var cells: [SIMD2<Int>: [(point: MKMapPoint, join: Join)]] = [:]

        /// The points of `runs` that are `included`, each kept with its run and place on it.
        init(_ runs: [Run], where included: (Run) -> Bool, cell: Double) {
            self.cell = cell
            for (index, run) in runs.enumerated() where included(run) {
                for (place, point) in run.points.enumerated() {
                    cells[Self.square(of: point, cell: cell), default: []].append((point, Join(run: index, point: place)))
                }
            }
        }

        private static func square(of point: MKMapPoint, cell: Double) -> SIMD2<Int> {
            SIMD2(Int((point.x / cell).rounded(.down)), Int((point.y / cell).rounded(.down)))
        }

        /// Whether one's within `meters` of `point`, `meters` no more than a cell across.
        func isNear(_ point: MKMapPoint, within meters: Double) -> Bool {
            let square = Self.square(of: point, cell: cell)
            for dx in -1...1 {
                for dy in -1...1 where cells[square &+ SIMD2(dx, dy)]?.contains(where: { $0.point.distance(to: point) < meters }) == true {
                    return true
                }
            }
            return false
        }

        /// The nearest within `meters` of `point`, `meters` no more than a cell across, and where it is.
        func nearest(to point: MKMapPoint, within meters: Double) -> (point: MKMapPoint, join: Join)? {
            let square = Self.square(of: point, cell: cell)
            var best: (point: MKMapPoint, join: Join, meters: Double)?
            for dx in -1...1 {
                for dy in -1...1 {
                    for near in cells[square &+ SIMD2(dx, dy)] ?? [] {
                        let distance = near.point.distance(to: point)
                        if distance < meters, distance < best?.meters ?? .infinity { best = (near.point, near.join, distance) }
                    }
                }
            }
            return best.map { ($0.point, $0.join) }
        }
    }
}

/// Which way the buses at a stop go, and where on their line its mark sits: the nearest of its
/// lines' ways (`BusNetwork`), each drawn on its own side of the street the way its buses go, so
/// a stop at the kerb is nearest its own way's.
struct BusSides {
    struct Way: Equatable {
        /// The way its buses go, as map points have it (x east, y south), in radians.
        let angle: Double
        /// The stop's place on its way's line, for its mark to sit on.
        let onLine: CLLocationCoordinate2D

        static func == (a: Way, b: Way) -> Bool {
            a.angle == b.angle && a.onLine.latitude == b.onLine.latitude && a.onLine.longitude == b.onLine.longitude
        }
    }

    private let ways: [(lines: Set<String>, points: [MKMapPoint])]
    /// Each way's segments, by the square their middles are in.
    private let grid: [SIMD2<Int>: [(way: Int, segment: Int)]]
    private let cell: Double
    private let pointsPerMeter: Double

    static let none = BusSides(ways: [])

    /// Meters off its own lines' way a stop may be to be on it, past the far roadway of a
    /// boulevard (Queens Blvd's); and off another's, for a stop of a line not drawn.
    private static let ownReach: Double = 60
    private static let reach: Double = 30
    /// Meters further its own lines' way may be than another's for a stop to be taken as on it.
    private static let ownBetter: Double = 15
    /// Meters a way's segment is at most, for the grid's squares to hold all near a stop.
    private static let longest: Double = 400

    init(ways: [BusNetwork.Way]) {
        self.ways = ways.map { (Set($0.lines), $0.coordinates.map(MKMapPoint.init)) }
        let latitude = ways.first?.coordinates.first?.latitude ?? 40.7
        pointsPerMeter = MKMapPointsPerMeterAtLatitude(latitude)
        cell = (Self.ownReach + Self.longest / 2) * pointsPerMeter
        var grid: [SIMD2<Int>: [(way: Int, segment: Int)]] = [:]
        for (index, way) in self.ways.enumerated() {
            for segment in way.points.indices.dropLast() {
                let a = way.points[segment], b = way.points[segment + 1]
                // Long straight segments (simplified) in each square they cross, every half cell
                let steps = max(1, Int((a.distance(to: b) / (cell / 2)).rounded(.up)))
                var squares: Set<SIMD2<Int>> = []
                for step in 0...steps {
                    let t = Double(step) / Double(steps)
                    squares.insert(Self.square(MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), cell: cell))
                }
                for square in squares { grid[square, default: []].append((index, segment)) }
            }
        }
        self.grid = grid
    }

    /// Which way the buses at a stop at `coordinate` stopping for `lines` (as `TrackShapes.busKey`
    /// has them) go, and its place on their line: the nearest of its lines' ways, unless
    /// another's is plainly nearer. Nil off any.
    func way(at coordinate: CLLocationCoordinate2D, lines: [String]) -> Way? {
        let point = MKMapPoint(coordinate)
        let own = nearest(point, lines: Set(lines), only: true), any = nearest(point, lines: [], only: false)
        let chosen: (way: Int, segment: Int, onLine: MKMapPoint)? = switch (own, any) {
        case let (own?, any?): own.onLine.distance(to: point) <= any.onLine.distance(to: point) + Self.ownBetter * pointsPerMeter
            ? own : any
        case let (own?, nil): own
        case let (nil, any): any
        }
        guard let near = chosen else { return nil }
        let a = ways[near.way].points[near.segment], b = ways[near.way].points[near.segment + 1]
        return Way(angle: atan2(b.y - a.y, b.x - a.x), onLine: near.onLine.coordinate)
    }

    /// The segment nearest `point`, of a way of one of `lines` within `ownReach` if `only`, else
    /// any within `reach`, and the nearest point on it.
    private func nearest(_ point: MKMapPoint, lines: Set<String>, only: Bool) -> (way: Int, segment: Int, onLine: MKMapPoint)? {
        let square = Self.square(point, cell: cell)
        var best: (way: Int, segment: Int, onLine: MKMapPoint, meters: Double)?
        var seen: Set<SIMD2<Int>> = []
        for dx in -1...1 {
            for dy in -1...1 {
                for (way, segment) in grid[square &+ SIMD2(dx, dy)] ?? [] where !only || !lines.isDisjoint(with: ways[way].lines) {
                    guard seen.insert(SIMD2(way, segment)).inserted else { continue }
                    let a = ways[way].points[segment], b = ways[way].points[segment + 1]
                    let dx = b.x - a.x, dy = b.y - a.y
                    let length2 = dx * dx + dy * dy
                    guard length2 > 0 else { continue }
                    let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length2))
                    let onLine = MKMapPoint(x: a.x + dx * t, y: a.y + dy * t)
                    let meters = hypot(point.x - onLine.x, point.y - onLine.y) / pointsPerMeter
                    guard meters <= (only ? Self.ownReach : Self.reach), meters < best?.meters ?? .infinity else { continue }
                    best = (way, segment, onLine, meters)
                }
            }
        }
        return best.map { ($0.way, $0.segment, $0.onLine) }
    }

    private static func square(_ point: MKMapPoint, cell: Double) -> SIMD2<Int> {
        SIMD2(Int((point.x / cell).rounded(.down)), Int((point.y / cell).rounded(.down)))
    }
}

/// The map's zoom as lines side by side are drawn apart by it: map points a screen point is.
/// Only moved on where the map comes to rest, and only once it's well off: while the map moves,
/// the lines keep their shape on the ground, so they and their stations scale with the map as
/// one. Laid out again for each step through a pinch, MapKit re-added them a beat behind the map,
/// off their stations' dots.
enum LineScale {
    private static let stepsPerOctave = 4.0
    /// Octaves zoomed in, or out, past `current` before the lines are laid out again: zoomed in,
    /// lines side by side part a little; zoomed out, they're soon over each other.
    private static let holdIn = 1.0
    private static let holdOut = 0.5

    /// `current`, or `mapPointsPerPoint` once it's past the hold from it, or there's none yet.
    static func step(_ mapPointsPerPoint: Double, from current: Double) -> Double {
        guard mapPointsPerPoint > 0, mapPointsPerPoint.isFinite else { return current }
        guard current > 0 else { return mapPointsPerPoint }
        // More map points a point is zoomed out
        let octaves = log2(mapPointsPerPoint / current)
        return octaves > holdOut || octaves < -holdIn ? mapPointsPerPoint : current
    }

    /// Which step `scale` is, for lines' ids.
    static func id(of scale: Double) -> Int {
        scale > 0 ? Int((log2(scale) * stepsPerOctave).rounded()) : 0
    }
}

/// How finely the subway's lines are drawn for the map's zoom: every point close in (`full`);
/// further out, at each octave's step, only those keeping each line within `tolerance` of its
/// track, where more points than the eye can see were slow to draw. Laid out for the zoom the
/// map rests at, as the lines are, with 10% either way of each step so it doesn't flicker
/// between them.
enum SubwayDetail: Hashable {
    case full
    /// From `closest` meters a point times 2^step, for an octave.
    case simplified(step: Int)

    /// Meters a point within which the lines are drawn whole, and the steps out from there.
    static let closest: Double = 4
    static let steps = 6
    private static let margin = 1.1

    init(metersPerPoint: Double, from shown: SubwayDetail? = nil) {
        guard metersPerPoint.isFinite, metersPerPoint > 0 else {
            self = shown ?? .full
            return
        }
        let step = Int(floor(log2(metersPerPoint / Self.closest)))
        let new: SubwayDetail = step < 0 ? .full : .simplified(step: min(step, Self.steps - 1))
        // Kept while the map's within 10% of the zoom it was drawn for
        if let shown, shown != new, shown.closestMeters / Self.margin <= metersPerPoint,
           metersPerPoint < shown.farthestMeters * Self.margin {
            self = shown
        } else {
            self = new
        }
    }

    /// Meters a point at the closest and farthest of its zoom.
    private var closestMeters: Double {
        switch self {
        case .full: 0
        case .simplified(let step): Self.closest * pow(2, Double(step))
        }
    }

    private var farthestMeters: Double {
        switch self {
        case .full: Self.closest
        case .simplified(let step): step == Self.steps - 1 ? .infinity : Self.closest * pow(2, Double(step + 1))
        }
    }

    /// Meters a line may be off its track: a quarter of a point at the closest of its zoom, so
    /// still half a point an octave closer in, as the map's pinched in past it before the lines
    /// are laid out again where it rests (`LineScale` holds an octave in). Nil, whole.
    var tolerance: Double? {
        switch self {
        case .full: nil
        case .simplified: closestMeters / 4
        }
    }

    /// For lines' ids: nothing for `full`, as they always were.
    var idPart: String {
        switch self {
        case .full: ""
        case .simplified(let step): "d\(step)-"
        }
    }
}

/// `lines` on a map: bus routes pale and thin under the subway's, each subway line its colour,
/// those side by side as far apart as they're wide at the map's zoom (`mapPointsPerPoint`, a
/// `LineScale` step). `version` counts up with each new `lines`.
struct NearbyLinesLayer: MapContent {
    let lines: NearbyLines
    let version: Int
    let mapPointsPerPoint: Double
    /// The lines last drawn, kept by the map showing them, as the map's redrawn many times a
    /// second while it moves (for your dot and the marks), and they're slow to work out.
    let cache: Cache

    final class Cache {
        fileprivate var key: Key?
        fileprivate var drawn: [Drawn] = []
        /// The subway's lines apart, kept while they're the same tracks at the same zoom however
        /// the bus lines change: the whole city's, slow to offset and for MapKit to add again.
        fileprivate var subwayKey: SubwayKey?
        fileprivate var subway: [Drawn] = []
        /// Each track's strips, and its line at each detail it's been drawn at, for the tracks
        /// `laidOutFor`: worked out once each, not again as the map zooms back and forth.
        fileprivate var laidOutFor: Int?
        fileprivate var strips: [[Drawn]] = []
        fileprivate var linesByDetail: [SubwayDetail: [Drawn?]] = [:]

        fileprivate struct Key: Equatable {
            let version: Int
            /// Whether the bus lines show at the zoom (`farthest`): they don't change with it.
            let busesShown: Bool
        }

        fileprivate struct SubwayKey: Equatable {
            let tracksID: Int
            /// Whether the subway shows at the zoom, and how finely it's drawn there.
            let shown: Bool
            let detail: SubwayDetail
        }
    }

    /// How wide each way of a bus line is drawn.
    private static let laneWidth: CGFloat = 2.5

    /// A line on its own, each of two or more side by side, and a bus route.
    static let lineWidth: CGFloat = 5
    static let besideWidth: CGFloat = 4
    /// Bus blue at 35% (and 10%, faded) over the map, but solid, so lines sharing a lane, drawn
    /// over each other, don't read darker.
    private static let busColor = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.08, green: 0.16, blue: 0.32, alpha: 1)
            : UIColor(red: 0.62, green: 0.70, blue: 0.85, alpha: 1)
    })
    private static let fadedBusColor = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1)
            : UIColor(red: 0.88, green: 0.90, blue: 0.94, alpha: 1)
    })

    fileprivate struct Drawn: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let width: CGFloat
        /// A shape filled (a subway line's strip, `coordinates` its outline), not a line stroked.
        var filled = false
    }

    var body: some MapContent {
        ForEach(drawn) { line in
            if line.filled {
                MapPolygon(coordinates: line.coordinates)
                    .foregroundStyle(line.color)
            } else {
                MapPolyline(coordinates: line.coordinates)
                    .stroke(line.color, style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// Meters a point is, past which the map's zoomed out too far for the bus lines: a tangle of
    /// pale lines across the borough, under the subway's.
    private static let farthest: Double = 8
    /// And for the subway's, drawn their whole length: past the city, as far out as the maps go.
    private static let farthestSubway: Double = 150

    /// The lines, from `cache` while they're the same lines at the same zoom; the subway's
    /// while they're the same tracks.
    private var drawn: [Drawn] {
        let detail = SubwayDetail(metersPerPoint: metersPerPoint, from: cache.subwayKey?.detail)
        let subwayKey = Cache.SubwayKey(tracksID: lines.tracksID, shown: metersPerPoint <= Self.farthestSubway,
                                        detail: detail)
        let key = Cache.Key(version: version, busesShown: metersPerPoint <= Self.farthest)
        guard cache.key != key || cache.subwayKey != subwayKey else { return cache.drawn }
        if cache.subwayKey != subwayKey {
            cache.subway = drawSubway(detail: detail)
            cache.subwayKey = subwayKey
        }
        cache.drawn = drawBuses() + cache.subway
        cache.key = key
        return cache.drawn
    }

    /// Meters a point is at the map's zoom.
    private var metersPerPoint: Double {
        mapPointsPerPoint / MKMapPointsPerMeterAtLatitude(lines.latitude)
    }

    /// Meters apart side-by-side subway lines' middles are, on the ground, and about how long
    /// each piece of their strips is (`drawSubway`).
    static let subwaySpacing: Double = 6
    private static let pieceMeters: Double = 1609

    /// The subway's lines, each laid out once for its tracks (`NearbyLines.tracksID`), not for
    /// each zoom or each new `version`: side by side `subwaySpacing` apart on the ground, each a
    /// line a fixed width over a strip as wide as the spacing, so lines side by side touch close
    /// in and lie over each other further out, all scaling with the map as it zooms. The strips
    /// in pieces about a mile long: whole, MapKit drew them flickering; shorter, there were too
    /// many to draw smoothly. Each line with as many points as `detail` needs (`SubwayDetail`),
    /// each detail worked out once; the strips the same at every zoom, as they're under their
    /// lines past close in, and not added to the map again.
    private func drawSubway(detail: SubwayDetail) -> [Drawn] {
        guard metersPerPoint <= Self.farthestSubway else { return [] }
        if cache.laidOutFor != lines.tracksID {
            cache.strips = Self.strips(of: lines.tracks, tracksID: lines.tracksID, latitude: lines.latitude)
            cache.linesByDetail = [:]
            cache.laidOutFor = lines.tracksID
        }
        let drawnLines = cache.linesByDetail[detail] ?? Self.subwayLines(of: lines.tracks, tracksID: lines.tracksID,
                                                                       detail: detail, latitude: lines.latitude).map { line in
            line.map { Drawn(id: $0.id, coordinates: $0.coordinates, color: $0.color, width: $0.width) }
        }
        cache.linesByDetail[detail] = drawnLines
        // Each track's strips under its line, as they always were
        return lines.tracks.indices.flatMap { index in
            (cache.strips.indices.contains(index) ? cache.strips[index] : [])
                + (drawnLines.indices.contains(index) ? drawnLines[index].map { [$0] } ?? [] : [])
        }
    }

    /// Each of `tracks`' strips, in pieces (`drawSubway`).
    private static func strips(of tracks: [NearbyLines.Track], tracksID: Int, latitude: Double) -> [[Drawn]] {
        let perMeter = MKMapPointsPerMeterAtLatitude(latitude)
        let apart = subwaySpacing * perMeter
        // A hair wider than the spacing, so neighbouring strips show no seam
        let half = apart * 0.53
        let limit = pieceMeters * perMeter
        return tracks.enumerated().map { index, track in
            guard track.coordinates.count > 1 else { return [] }
            let middle = lanes(of: track).map { $0 * apart }
            let color = LineStyle.of(track.route).swiftUIColor
            let left = TripMap.offset(track.coordinates, by: middle.map { $0 - half })
            let right = TripMap.offset(track.coordinates, by: middle.map { $0 + half })
            guard left.count == right.count, left.count > 1 else { return [] }
            var drawn: [Drawn] = []
            let along = left.map(MKMapPoint.init)
            var start = 0, piece = 0
            while start < left.count - 1 {
                var end = start + 1
                var length = along[start].distance(to: along[end])
                while end < left.count - 1, length < limit {
                    length += along[end].distance(to: along[end + 1])
                    end += 1
                }
                drawn.append(Drawn(id: "strip-\(tracksID)-\(index)-\(piece)",
                                   coordinates: Array(left[start...end]) + Array(right[start...end]).reversed(),
                                   color: color, width: 0, filled: true))
                start = end
                piece += 1
            }
            return drawn
        }
    }

    /// A track's lanes, one for each of its points (none moved, if it has the wrong number).
    private static func lanes(of track: NearbyLines.Track) -> [Double] {
        track.lanes.count == track.coordinates.count ? track.lanes : Array(repeating: 0, count: track.coordinates.count)
    }

    /// A subway line as drawn: its id, its points moved out to its lane, its colour and width.
    struct SubwayLine {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let width: CGFloat
    }

    /// Each of `tracks`' lines at `detail`, nil for one too short to draw: moved out to its lane,
    /// then simplified (`simplified`), so it keeps within `tolerance` of where it's drawn whole,
    /// and two side by side within twice that of where they were apart. Simplified before
    /// they're moved out, keeping each point where a lane changes, too few were left out: lanes
    /// ease from one to the next over most of their points. Its id the same for the same tracks
    /// and detail; close in, as it always was.
    static func subwayLines(of tracks: [NearbyLines.Track], tracksID: Int, detail: SubwayDetail,
                            latitude: Double) -> [SubwayLine?] {
        let perMeter = MKMapPointsPerMeterAtLatitude(latitude)
        let apart = subwaySpacing * perMeter
        return tracks.enumerated().map { index, track in
            guard track.coordinates.count > 1 else { return nil }
            var coordinates = TripMap.offset(track.coordinates, by: lanes(of: track).map { $0 * apart })
            if let tolerance = detail.tolerance {
                coordinates = simplified(coordinates, tolerance: tolerance * perMeter)
            }
            return SubwayLine(id: "line-\(tracksID)-\(detail.idPart)\(index)", coordinates: coordinates,
                              color: LineStyle.of(track.route).swiftUIColor,
                              width: track.isBeside ? besideWidth : lineWidth)
        }
    }

    /// `coordinates` with only the points needed to keep within `tolerance` map points of the
    /// line through them all (Douglas–Peucker), its ends kept: its points along a straight
    /// stretch, every `TripMap.densified` step, aren't needed.
    static func simplified(_ coordinates: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
        let count = coordinates.count
        guard count > 2, tolerance > 0 else { return coordinates }
        let points = coordinates.map(MKMapPoint.init)
        var keep = Array(repeating: false, count: count)
        keep[0] = true
        keep[count - 1] = true
        // Between each two points kept, the farthest off the line between them kept, and so on
        // till none is more than `tolerance` off
        var stretches = [(0, count - 1)]
        while let (first, end) = stretches.popLast() {
            let a = points[first], b = points[end]
            let dx = b.x - a.x, dy = b.y - a.y
            let squared = dx * dx + dy * dy
            var farthest = 0.0, farthestIndex = first
            for index in (first + 1)..<end {
                let p = points[index]
                // How far `p` is from the segment a–b (from `a`, where they're the same point)
                let along = squared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared))
                let x = a.x + along * dx - p.x, y = a.y + along * dy - p.y
                let off = (x * x + y * y).squareRoot()
                if off > farthest {
                    farthest = off
                    farthestIndex = index
                }
            }
            guard farthest > tolerance else { continue }
            keep[farthestIndex] = true
            if farthestIndex - first > 1 { stretches.append((first, farthestIndex)) }
            if end - farthestIndex > 1 { stretches.append((farthestIndex, end)) }
        }
        return keep.indices.filter { keep[$0] }.map { coordinates[$0] }
    }

    /// An id for a line drawn `coordinates`, as `kind` (its colour and zoom): the same while its
    /// shape is, so a line that's the same as before keeps its place on the map, not taken off
    /// and added again each time the lines are laid out (each a costly change to MapKit's map,
    /// which flickered); new when its shape changes, as MapKit keeps a line's shape for its id.
    private static func shapeID(_ kind: String, _ coordinates: [CLLocationCoordinate2D]) -> String {
        var hasher = Hasher()
        for point in coordinates {
            hasher.combine(point.latitude)
            hasher.combine(point.longitude)
        }
        return "\(kind)-\(hasher.finalize())"
    }

    /// The bus lines, faded first, each way on its own side of the street as it's placed on
    /// the ground (`BusNetwork`): the same at every zoom, each kept on the map by its shape's id
    /// while it's drawn. Ways the same as another's (a line and its Select Bus Service on one
    /// lane) once.
    private func drawBuses() -> [Drawn] {
        guard metersPerPoint <= Self.farthest else { return [] }
        var seen: Set<String> = []
        let faded = lines.fadedBuses.map { (Self.shapeID("faded-bus", $0), $0, Self.fadedBusColor) }
        let bright = lines.buses.map { (Self.shapeID("bus", $0), $0, Self.busColor) }
        return (faded + bright).compactMap { id, coordinates, color in
            guard coordinates.count > 1, seen.insert(id).inserted else { return nil }
            return Drawn(id: id, coordinates: coordinates, color: color, width: Self.laneWidth)
        }
    }
}
