import CoreLocation
import MapKit
import SwiftUI

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
    /// Each bus line's streets, both ways once where they run the same street.
    let buses: [[CLLocationCoordinate2D]]
    /// Those of the bus lines not stopping at a stop opened on Nearby's map, drawn fainter.
    var fadedBuses: [[CLLocationCoordinate2D]] = []
    /// Which of `sides`' runs each of `buses` and `fadedBuses` is.
    var busRuns: [Int] = []
    var fadedRuns: [Int] = []
    /// Which side of its street a stop is on, and so which way its buses go, and where buses run
    /// both ways.
    var sides = BusSides.none
    /// For each of `sides`' runs' points, the subway lines drawn along it near enough to cover it
    /// zoomed out, for it to be drawn beside them (`busOut`).
    private var besideSubway: [[[SubwayBeside]]] = []

    /// A subway line along a bus street: how far its track is to the street's right (left, less
    /// than 0), how many lane widths it's drawn further right of that, and half its width.
    private struct SubwayBeside {
        let meters: Double
        let lanes: Double
        let halfWidth: CGFloat
    }

    static let none = NearbyLines(tracks: [], buses: [])

    /// Where they are, about: for meters a map point is there.
    var latitude: Double {
        (tracks.first?.coordinates.first ?? buses.first?.first)?.latitude ?? 40.7
    }

    /// Meters past the places, and the map's middle, lines are drawn.
    private static let reach: Double = 2500
    /// Meters from a line's track already drawn that another of its shapes (a branch, a
    /// late-night route) is taken to be on it, and not drawn again.
    private static let sameTrack: Double = 60
    /// Meters a shape must keep within `sameTrack` of one drawn to be taken to run along it,
    /// rather than cross it: more than it's that near crossing a street at a slant.
    private static let alongDrawn: Double = 200

    private init(tracks: [Track], buses: [[CLLocationCoordinate2D]]) {
        self.tracks = tracks
        self.buses = buses
    }

    /// `routes`' tracks and `busLines`' streets within `reach` of `points`; with `brightBusLines`
    /// (as `TrackShapes.busKey` has them), the other bus lines' streets faded.
    init(routes: [String], busLines: [String], brightBusLines: Set<String>? = nil, around points: [CLLocationCoordinate2D]) {
        guard let box = Self.box(around: points) else {
            self = .none
            return
        }
        let runs = Self.runs(of: routes, in: TrackShapes.byRoute, box: box)
        let coordinates = runs.map { $0.points.map(\.coordinate) }
        let lanes = TripMap.laneOffsets(coordinates, width: 1)
        tracks = runs.indices.map { index in
            Track(route: runs[index].route, coordinates: coordinates[index],
                  lanes: lanes.indices.contains(index) ? lanes[index] : [])
        }
        // A street once however many lines run along it, as two pale lines over each other
        // read darker
        // The bright ones first, for a street they share with faded ones to be drawn bright
        let keys = busLines.map(TrackShapes.busKey)
        let ordered = brightBusLines.map { bright in keys.filter(bright.contains) + keys.filter { !bright.contains($0) } } ?? keys
        let busRuns = Self.runs(of: ordered, in: TrackShapes.byBusLine, box: box, acrossRoutes: true)
        let isBright = { (route: String) in brightBusLines?.contains(route) ?? true }
        self.busRuns = busRuns.indices.filter { isBright(busRuns[$0].route) }
        fadedRuns = busRuns.indices.filter { !isBright(busRuns[$0].route) }
        buses = self.busRuns.map { busRuns[$0].points.map(\.coordinate) }
        fadedBuses = fadedRuns.map { busRuns[$0].points.map(\.coordinate) }
        sides = BusSides(runs: busRuns)
        besideSubway = Self.besideSubway(busRuns.map(\.points), tracks: tracks)
    }

    /// Meters off a bus street a subway line along it is looked for: as wide as the subway's
    /// widest drawn, zoomed out as far as the lines show.
    private static let subwayReach: Double = 120

    /// For each of `buses`' points, the subway lines running along it within `subwayReach`: of
    /// each, its nearest point, if it runs much the same way (not across it).
    private static func besideSubway(_ buses: [[MKMapPoint]], tracks: [Track]) -> [[[SubwayBeside]]] {
        guard !tracks.isEmpty, let somewhere = buses.first?.first else { return buses.map { $0.map { _ in [] } } }
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(somewhere.coordinate.latitude)
        let cell = subwayReach * pointsPerMeter
        let square = { (point: MKMapPoint) in SIMD2(Int((point.x / cell).rounded(.down)), Int((point.y / cell).rounded(.down))) }
        let trackPoints = tracks.map { $0.coordinates.map(MKMapPoint.init) }
        var grid: [SIMD2<Int>: [(track: Int, point: Int)]] = [:]
        for (track, points) in trackPoints.enumerated() {
            for (index, point) in points.enumerated() { grid[square(point), default: []].append((track, index)) }
        }
        // A line's way at a point, from its points either side
        func way(_ points: [MKMapPoint], _ index: Int) -> (x: Double, y: Double)? {
            let a = points[max(0, index - 1)], b = points[min(points.count - 1, index + 1)]
            let length = hypot(b.x - a.x, b.y - a.y)
            return length > 0 ? ((b.x - a.x) / length, (b.y - a.y) / length) : nil
        }
        return buses.map { points in
            points.indices.map { index in
                guard let along = way(points, index) else { return [] }
                // Right of the way the street's drawn: map points' y runs south
                let right = (x: -along.y, y: along.x)
                let point = points[index]
                var nearest: [Int: (meters: Double, beside: SubwayBeside)] = [:]
                let here = square(point)
                for dx in -1...1 {
                    for dy in -1...1 {
                        for (track, trackIndex) in grid[here &+ SIMD2(dx, dy)] ?? [] {
                            let trackPoint = trackPoints[track][trackIndex]
                            let meters = trackPoint.distance(to: point)
                            guard meters <= subwayReach, meters < nearest[track]?.meters ?? .infinity,
                                  let trackWay = way(trackPoints[track], trackIndex),
                                  // Much the same way, either way round, not crossing it, even at a slant
                                  abs(trackWay.x * along.x + trackWay.y * along.y) > 0.96 else { continue }
                            let across = ((trackPoint.x - point.x) * right.x + (trackPoint.y - point.y) * right.y) / pointsPerMeter
                            // Its lanes run to its own right, which is the street's right or left
                            let sameWay = trackWay.x * along.x + trackWay.y * along.y > 0
                            let lanes = tracks[track].lanes.indices.contains(trackIndex) ? tracks[track].lanes[trackIndex] : 0
                            let width = tracks[track].isBeside ? NearbyLinesLayer.besideWidth : NearbyLinesLayer.lineWidth
                            nearest[track] = (meters, SubwayBeside(meters: across, lanes: sameWay ? lanes : -lanes, halfWidth: width / 2))
                        }
                    }
                }
                return nearest.values.map(\.beside)
            }
        }
    }

    /// Points to the right of bus run `run`'s street (`sides`' runs) its line at `point` is drawn
    /// at a map `metersPerPoint`: its middle, or with `lane` 1 or -1 the way to its right or
    /// left, `NearbyLinesLayer.laneOut` off it; moved out past any subway lines drawn over it,
    /// one way's to its side of them, the middle's to the right. And whether any were.
    func busOut(run: Int, point: Int, lane: Int, metersPerPoint: Double) -> (points: CGFloat, moved: Bool) {
        let start = CGFloat(lane) * NearbyLinesLayer.laneOut
        guard metersPerPoint > 0, besideSubway.indices.contains(run), besideSubway[run].indices.contains(point) else {
            return (start, false)
        }
        // Each subway line's edges, in points right of the street
        let spans = besideSubway[run][point].map { line -> (low: CGFloat, high: CGFloat) in
            let middle = CGFloat(line.meters / metersPerPoint) + CGFloat(line.lanes) * NearbyLinesLayer.besideWidth
            return (middle - line.halfWidth, middle + line.halfWidth)
        }
        // A gap, and half the bus line's width
        let clear = 1.5 + NearbyLinesLayer.busWidth / 2
        // The subway lines over it, and those beside them, side by side as they're drawn
        var low = start, high = start, moved = false
        var changed = true
        while changed {
            changed = false
            for span in spans where span.high + clear > low && span.low - clear < high && (span.low < low || span.high > high) {
                low = min(low, span.low)
                high = max(high, span.high)
                moved = true
                changed = true
            }
        }
        guard moved else { return (start, false) }
        return (lane < 0 ? low - clear : high + clear, true)
    }

    /// How bus run `run`'s street (`sides`' runs) is drawn at `zoom`, a map `metersPerPoint`:
    /// for each point, whether it's a line each way (`both`); and in points to the right of the
    /// street, its line there (`middles`: its middle, or with `both` the way to its right), and
    /// the way to its left's (`lefts`, where `both`). Where buses run both ways, a line each way
    /// close in, and in between too where moved out from under the subway, as its stops the
    /// other side couldn't otherwise stem from it. Eased out and back over a few points, not in
    /// a jump, where the subway lines over it come and go or widen.
    func busDrawing(run: Int, zoom: BusZoom, metersPerPoint: Double) -> (both: [Bool], middles: [CGFloat], lefts: [CGFloat]) {
        let twoWay = sides.twoWay(run)
        let count = twoWay.count
        let middle = Self.along((0..<count).map { busOut(run: run, point: $0, lane: 0, metersPerPoint: metersPerPoint) },
                                unmoved: { _ in 0 })
        var both = (0..<count).map { index -> Bool in
            guard twoWay[index] else { return false }
            switch zoom {
            case .far: return false
            case .close: return true
            case .between: return middle[index].moved
            }
        }
        // Not off and on again for a point or two, as where the subway's lines part a moment
        Self.fillGaps(&both, upTo: Self.easing)
        let rights = Self.along((0..<count).map { busOut(run: run, point: $0, lane: both[$0] ? 1 : 0, metersPerPoint: metersPerPoint) },
                                unmoved: { both[$0] ? NearbyLinesLayer.laneOut : 0 })
        let lefts = Self.along((0..<count).map { busOut(run: run, point: $0, lane: -1, metersPerPoint: metersPerPoint) },
                               unmoved: { _ in -NearbyLinesLayer.laneOut })
        return (both, Self.eased(rights, out: 1), Self.eased(lefts, out: -1))
    }

    /// Points either way a bus line's eased out and back over, each up to 40 m (`TripMap.densified`).
    private static let easing = 2

    /// Points in a row a bus line must be under the subway to be moved out: along it, not
    /// crossing it at a slant.
    private static let alongPoints = 3

    /// `outs` moved only where they're moved for `alongPoints` in a row; elsewhere where each
    /// point's line is unmoved (`unmoved`, by its index).
    private static func along(_ outs: [(points: CGFloat, moved: Bool)],
                              unmoved: (Int) -> CGFloat) -> [(points: CGFloat, moved: Bool)] {
        var kept = outs
        var start = 0
        while start < outs.count {
            guard outs[start].moved else {
                start += 1
                continue
            }
            var end = start
            while end + 1 < outs.count, outs[end + 1].moved { end += 1 }
            if end - start + 1 < alongPoints {
                for index in start...end { kept[index] = (unmoved(index), false) }
            }
            start = end + 1
        }
        return kept
    }

    /// `flags` with runs of up to `most` false between trues made true.
    private static func fillGaps(_ flags: inout [Bool], upTo most: Int) {
        var last: Int?
        for index in flags.indices where flags[index] {
            if let last, index - last > 1, index - last - 1 <= most {
                for gap in (last + 1)..<index { flags[gap] = true }
            }
            last = index
        }
    }

    /// `outs` averaged over `easing` points either way, so a line moved out eases out and back;
    /// but where moved, never less far out than it must be, `out` the way it's moved (1 right,
    /// -1 left), to keep it clear of the subway.
    private static func eased(_ outs: [(points: CGFloat, moved: Bool)], out: CGFloat) -> [CGFloat] {
        outs.indices.map { index in
            let window = outs[max(0, index - easing)...min(outs.count - 1, index + easing)]
            let average = window.reduce(0) { $0 + $1.points } / CGFloat(window.count)
            guard outs[index].moved else { return average }
            return out > 0 ? max(average, outs[index].points) : min(average, outs[index].points)
        }
    }

    /// The bus lines stopping within `meters` of `point`, nearest stop first: those a few
    /// minutes' walk away, without asking Bus Time for its stops. By their stops (bus_stops.json),
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
            for line in stop.lines where TrackShapes.byBusLine[line] != nil {
                nearest[line] = min(nearest[line] ?? .infinity, distance)
            }
        }
        return nearest.sorted { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }.map(\.key)
    }

    /// `points`' bounds, `reach` round.
    private static func box(around points: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard let first = points.first else { return nil }
        let mapPoints = points.map(MKMapPoint.init)
        let xs = mapPoints.map(\.x), ys = mapPoints.map(\.y)
        let pad = reach * MKMapPointsPerMeterAtLatitude(first.latitude)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return MKMapRect(x: minX - pad, y: minY - pad,
                         width: (xs.max() ?? 0) - minX + pad * 2, height: (ys.max() ?? 0) - minY + pad * 2)
    }

    /// Each of `routes`' shapes, the longest first, where it's in `box` and not on one of its
    /// route's already drawn (`acrossRoutes`, any route's).
    private static func runs(of routes: [String], in shapes: [String: [[CLLocationCoordinate2D]]],
                             box: MKMapRect, acrossRoutes: Bool = false) -> [(route: String, points: [MKMapPoint])] {
        var runs: [(route: String, points: [MKMapPoint])] = []
        var seen: Set<String> = []
        // A little over `sameTrack` a cell, as map points a meter vary a little across the box
        let cell = sameTrack * 1.1 * MKMapPointsPerMeterAtLatitude(MKMapPoint(x: box.midX, y: box.midY).coordinate.latitude)
        for route in routes where seen.insert(route).inserted {
            var kept = PointGrid(acrossRoutes ? runs.flatMap(\.points) : [], cell: cell)
            for shape in shapes[route] ?? [] {
                var run: [MKMapPoint] = []
                var last: MKMapPoint?
                func finish(at end: MKMapPoint?) {
                    // Joined to where it meets the track drawn, so a branch doesn't start apart
                    if let end, !run.isEmpty { run.append(end) }
                    if run.count > 1 { runs.append((route, run)) }
                    run = []
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
                for (point, isDrawn) in zip(points, drawn) {
                    if !box.contains(point) {
                        finish(at: nil)
                    } else if isDrawn {
                        finish(at: point)
                    } else {
                        if run.isEmpty, let last, box.contains(last) { run.append(last) }
                        run.append(point)
                    }
                    last = point
                }
                finish(at: nil)
                kept = PointGrid(runs.filter { acrossRoutes || $0.route == route }.flatMap(\.points), cell: cell)
            }
        }
        return runs
    }

    /// Points by the square they're in, `cell` map points across, to tell whether one's near a
    /// point within a cell's width without looking at every one.
    private struct PointGrid {
        private let cell: Double
        private var cells: [SIMD2<Int>: [MKMapPoint]] = [:]

        init(_ points: [MKMapPoint], cell: Double) {
            self.cell = cell
            for point in points { cells[Self.square(of: point, cell: cell), default: []].append(point) }
        }

        private static func square(of point: MKMapPoint, cell: Double) -> SIMD2<Int> {
            SIMD2(Int((point.x / cell).rounded(.down)), Int((point.y / cell).rounded(.down)))
        }

        /// Whether one's within `meters` of `point`, `meters` no more than a cell across.
        func isNear(_ point: MKMapPoint, within meters: Double) -> Bool {
            let square = Self.square(of: point, cell: cell)
            for dx in -1...1 {
                for dy in -1...1 where cells[square &+ SIMD2(dx, dy)]?.contains(where: { $0.distance(to: point) < meters }) == true {
                    return true
                }
            }
            return false
        }
    }
}

/// Which side of its street a bus stop is on, from where it is off the street's line drawn, and
/// so which way its buses go there, as they keep right; and where a street drawn has stops on
/// both sides, so buses both ways, rather than one way (one of a one-way pair).
struct BusSides {
    struct Way: Equatable {
        /// The way its buses go, as map points have it (x east, y south), in radians.
        let angle: Double
        /// Whether buses run its street both ways there.
        let twoWay: Bool
        /// The stop's place on the street's line, for its mark to sit on or stem from.
        let onLine: CLLocationCoordinate2D
        /// The run it's along, the run's point nearest, and which side of the way it's drawn the
        /// stop is: 1 right, -1 left.
        let run: Int
        let point: Int
        let side: Int

        static func == (a: Way, b: Way) -> Bool {
            a.angle == b.angle && a.twoWay == b.twoWay && a.run == b.run && a.point == b.point && a.side == b.side
                && a.onLine.latitude == b.onLine.latitude && a.onLine.longitude == b.onLine.longitude
        }
    }

    private let runs: [(route: String, points: [MKMapPoint])]
    /// Each run's segments, by the square their middles are in.
    private let grid: [SIMD2<Int>: [(run: Int, segment: Int)]]
    private let cell: Double
    private let pointsPerMeter: Double
    private var twoWays: [[Bool]] = []

    static let none = BusSides(runs: [])

    /// Meters off a street's line a stop may be to be on it: past the kerb of a wide avenue; and
    /// on one of its own lines', past the far roadway of a boulevard drawn down the near one
    /// (Queens Blvd's), not as far as the next street over.
    private static let reach: Double = 35
    private static let ownReach: Double = 60
    /// Meters further its own lines' street may be than another's for a stop to be taken as on it.
    private static let ownBetter: Double = 15
    /// Meters off it a stop must be to tell its side: the line drawn strays a few from the street's middle.
    private static let leastOff: Double = 2
    /// Points either way along a run (each up to 40 m, `TripMap.densified`) a stop each side is
    /// looked for to take it as two-way: further than a stop each way is apart.
    private static let twoWayReach = 8

    init(runs: [(route: String, points: [MKMapPoint])]) {
        self.runs = runs
        let latitude = runs.first?.points.first?.coordinate.latitude ?? 40.7
        pointsPerMeter = MKMapPointsPerMeterAtLatitude(latitude)
        // Segments are no more than 40 m, so one within `reach` has its middle in the square
        // next to the stop's
        cell = (Self.ownReach + 25) * pointsPerMeter
        var grid: [SIMD2<Int>: [(run: Int, segment: Int)]] = [:]
        for (index, run) in runs.enumerated() {
            for segment in run.points.indices.dropLast() {
                let a = run.points[segment], b = run.points[segment + 1]
                grid[Self.square(MKMapPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), cell: cell), default: []]
                    .append((index, segment))
            }
        }
        self.grid = grid
        guard !runs.isEmpty else { return }
        // Each stop's side along the line it's on, for the runs with stops both sides
        let xs = runs.flatMap { $0.points.map(\.x) }, ys = runs.flatMap { $0.points.map(\.y) }
        let pad = Self.ownReach * pointsPerMeter
        let box = MKMapRect(x: (xs.min() ?? 0) - pad, y: (ys.min() ?? 0) - pad,
                            width: (xs.max() ?? 0) - (xs.min() ?? 0) + pad * 2,
                            height: (ys.max() ?? 0) - (ys.min() ?? 0) + pad * 2)
        var right = runs.map { $0.points.map { _ in 0 } }, left = right
        for stop in TrackShapes.busStops {
            let point = MKMapPoint(stop.coordinate)
            guard box.contains(point), let near = nearest(point, lines: Set(stop.lines), only: true),
                  abs(near.off) >= Self.leastOff else { continue }
            if near.off > 0 { right[near.run][near.segment] += 1 } else { left[near.run][near.segment] += 1 }
        }
        twoWays = runs.indices.map { run in
            let count = runs[run].points.count
            // How many each side up to each point, to count those near it without counting again
            let rights = right[run].reduce(into: [0]) { $0.append(($0.last ?? 0) + $1) }
            let lefts = left[run].reduce(into: [0]) { $0.append(($0.last ?? 0) + $1) }
            return (0..<count).map { index in
                let from = max(0, index - Self.twoWayReach), to = min(count, index + Self.twoWayReach + 1)
                return rights[to] - rights[from] > 0 && lefts[to] - lefts[from] > 0
            }
        }
    }

    /// For each of run `index`'s points, whether buses run its street both ways there.
    func twoWay(_ index: Int) -> [Bool] { twoWays.indices.contains(index) ? twoWays[index] : [] }

    /// Which way the buses at a stop at `coordinate` stopping for `lines` (as `TrackShapes.busKey`
    /// has them) go: along the street drawn for one of them it's on, else any it's on. Nil off
    /// any, or too near its middle to tell.
    func way(at coordinate: CLLocationCoordinate2D, lines: [String]) -> Way? {
        let point = MKMapPoint(coordinate)
        // Its own lines' street, unless another drawn is plainly nearer: where the street it's on
        // is drawn for another line, its own line's nearest may be round the corner
        let own = nearest(point, lines: Set(lines), only: true), any = nearest(point, lines: [], only: false)
        let chosen: (run: Int, segment: Int, off: Double, onLine: MKMapPoint)? = switch (own, any) {
        case let (own?, any?): own.onLine.distance(to: point) <= any.onLine.distance(to: point) + Self.ownBetter
            ? own : any
        case let (own?, nil): own
        case let (nil, any): any
        }
        guard let near = chosen, abs(near.off) >= Self.leastOff else { return nil }
        let a = runs[near.run].points[near.segment], b = runs[near.run].points[near.segment + 1]
        let angle = near.off > 0 ? atan2(b.y - a.y, b.x - a.x) : atan2(a.y - b.y, a.x - b.x)
        let twoWay = twoWays[near.run][near.segment] || twoWays[near.run][near.segment + 1]
        // The nearer end of its segment
        let nearer = a.distance(to: near.onLine) <= b.distance(to: near.onLine) ? near.segment : near.segment + 1
        return Way(angle: angle, twoWay: twoWay, onLine: near.onLine.coordinate, run: near.run, point: nearer,
                   side: near.off > 0 ? 1 : -1)
    }

    /// The segment nearest `point` within `reach`, of a run for one of `lines` within `ownReach` if `only`, meters
    /// `point` is to its right (left, less than 0), and the nearest point on it.
    private func nearest(_ point: MKMapPoint, lines: Set<String>, only: Bool)
        -> (run: Int, segment: Int, off: Double, onLine: MKMapPoint)? {
        let square = Self.square(point, cell: cell)
        var best: (run: Int, segment: Int, off: Double, onLine: MKMapPoint, meters: Double)?
        for dx in -1...1 {
            for dy in -1...1 {
                for (run, segment) in grid[square &+ SIMD2(dx, dy)] ?? [] where !only || lines.contains(runs[run].route) {
                    let a = runs[run].points[segment], b = runs[run].points[segment + 1]
                    let dx = b.x - a.x, dy = b.y - a.y
                    let length = (dx * dx + dy * dy).squareRoot()
                    guard length > 0 else { continue }
                    // How far along, held to the segment, and how far off it
                    let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / (length * length)))
                    let onLine = MKMapPoint(x: a.x + dx * t, y: a.y + dy * t)
                    let meters = hypot(point.x - onLine.x, point.y - onLine.y) / pointsPerMeter
                    guard meters <= (only ? Self.ownReach : Self.reach), meters < best?.meters ?? .infinity else { continue }
                    // Right of the way it's drawn: map points' y runs south, so east's right is south
                    let off = ((point.x - a.x) * -dy + (point.y - a.y) * dx) / length / pointsPerMeter
                    best = (run, segment, off, onLine, meters)
                }
            }
        }
        return best.map { ($0.run, $0.segment, $0.off, $0.onLine) }
    }

    private static func square(_ point: MKMapPoint, cell: Double) -> SIMD2<Int> {
        SIMD2(Int((point.x / cell).rounded(.down)), Int((point.y / cell).rounded(.down)))
    }
}

/// The map's zoom as lines side by side are drawn apart by it: map points a screen point is,
/// held to quarter-octave steps. Followed as the map moves (not only where it comes to rest), so
/// the lines stay about their width apart through a pinch, rather than bunching or splaying and
/// jumping into place at its end; redrawn only as it passes a step, not every frame.
enum LineScale {
    private static let stepsPerOctave = 4.0
    /// Steps past `current` the map must be before it moves on, so it doesn't flicker back and
    /// forth at a step's edge.
    private static let hold = 0.75

    /// `current`, or the step nearest `mapPointsPerPoint` once it's `hold` steps from it.
    static func step(_ mapPointsPerPoint: Double, from current: Double) -> Double {
        guard mapPointsPerPoint > 0, mapPointsPerPoint.isFinite else { return current }
        let level = log2(mapPointsPerPoint) * stepsPerOctave
        if current > 0, abs(level - log2(current) * stepsPerOctave) < hold { return current }
        return exp2(level.rounded() / stepsPerOctave)
    }

    /// Which step `scale` is, for lines' ids.
    static func id(of scale: Double) -> Int {
        scale > 0 ? Int((log2(scale) * stepsPerOctave).rounded()) : 0
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
    /// How near the map is for bus streets: a line each way past zoomed out (`NearbyLines.busLanes`).
    var zoom = BusZoom.far

    final class Cache {
        fileprivate var key: Key?
        fileprivate var drawn: [Drawn] = []

        fileprivate struct Key: Equatable {
            let version: Int
            let mapPointsPerPoint: Double
            let zoom: BusZoom
        }
    }

    /// Points either side of a two-way street's middle each way's line is drawn close in, and
    /// how wide.
    static let laneOut: CGFloat = 5
    private static let laneWidth: CGFloat = 2.5

    /// A line on its own, each of two or more side by side, and a bus route.
    static let lineWidth: CGFloat = 5
    static let besideWidth: CGFloat = 4
    static let busWidth: CGFloat = 3
    private static let busColor = BusBadge.blue.opacity(0.35)
    private static let fadedBusColor = BusBadge.blue.opacity(0.1)

    fileprivate struct Drawn: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let width: CGFloat
    }

    var body: some MapContent {
        ForEach(drawn) { line in
            MapPolyline(coordinates: line.coordinates)
                .stroke(line.color, style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round))
        }
    }

    /// Meters a point is, past which the map's zoomed out too far for the lines: their ends,
    /// `NearbyLines.reach` out, would show, stopping short in the middle of the map.
    private static let farthest: Double = 8

    /// The lines, from `cache` while they're the same lines at the same zoom.
    private var drawn: [Drawn] {
        let key = Cache.Key(version: version, mapPointsPerPoint: mapPointsPerPoint, zoom: zoom)
        if cache.key != key {
            cache.drawn = drawLines()
            cache.key = key
        }
        return cache.drawn
    }

    /// New lines for each zoom, as MapKit keeps a line's last shape while its id stays.
    private func drawLines() -> [Drawn] {
        let metersPerPoint = mapPointsPerPoint / MKMapPointsPerMeterAtLatitude(lines.latitude)
        guard metersPerPoint <= Self.farthest else { return [] }
        let apart = Double(Self.besideWidth) * mapPointsPerPoint
        let zoomStep = LineScale.id(of: mapPointsPerPoint)
        // Bus lines drawn once keep theirs across zooms; each way's, apart by points, don't
        // Moved out from under the subway by points, so new for each zoom
        let buses = busLines(lines.buses, runs: lines.busRuns, id: "bus-\(version)-\(zoomStep)-\(zoom)", color: Self.busColor)
        let faded = busLines(lines.fadedBuses, runs: lines.fadedRuns, id: "faded-bus-\(version)-\(zoomStep)-\(zoom)",
                             color: Self.fadedBusColor)
        let subway = lines.tracks.indices.map { index in
            let track = lines.tracks[index]
            return Drawn(id: "line-\(version)-\(zoomStep)-\(index)",
                         coordinates: TripMap.offset(track.coordinates, by: track.lanes.map { $0 * apart }),
                         color: LineStyle.of(track.route).swiftUIColor,
                         width: track.isBeside ? Self.besideWidth : Self.lineWidth)
        }
        return faded + buses + subway
    }

    /// Bus streets as drawn (`runs`, `lines.sides`' runs): once, or a line each way where
    /// `NearbyLines.busLanes` says, each way's to its right as buses keep; moved out from under
    /// any subway lines over them (`NearbyLines.busOut`).
    private func busLines(_ streets: [[CLLocationCoordinate2D]], runs: [Int], id: String, color: Color) -> [Drawn] {
        let metersPerPoint = mapPointsPerPoint / MKMapPointsPerMeterAtLatitude(lines.latitude)
        return streets.indices.flatMap { index -> [Drawn] in
            let street = streets[index]
            guard runs.indices.contains(index) else {
                return [Drawn(id: "\(id)-\(index)", coordinates: street, color: color, width: Self.busWidth)]
            }
            let drawing = lines.busDrawing(run: runs[index], zoom: zoom, metersPerPoint: metersPerPoint)
            guard drawing.both.count == street.count else {
                return [Drawn(id: "\(id)-\(index)", coordinates: street, color: color, width: Self.busWidth)]
            }
            let both = drawing.both
            // The way it's drawn, the whole street: its middle, or its way's line where there are two
            let middles = drawing.middles.map { Double($0) * mapPointsPerPoint }
            var drawn = [Drawn(id: "\(id)-\(index)", coordinates: TripMap.offset(street, by: middles), color: color,
                               width: both.contains(true) ? Self.laneWidth : Self.busWidth)]
            // The other way, only where there are two, joined to the one line either end
            var start = 0
            while start < both.count {
                guard both[start] else {
                    start += 1
                    continue
                }
                var end = start
                while end + 1 < both.count, both[end + 1] { end += 1 }
                let range = max(0, start - 1)...min(both.count - 1, end + 1)
                drawn.append(Drawn(id: "\(id)-\(index)-other-\(start)",
                                   coordinates: TripMap.offset(Array(street[range]), by: range.map { both[$0] ? Double(drawing.lefts[$0]) * mapPointsPerPoint : middles[$0] }),
                                   color: color, width: Self.laneWidth))
                start = end + 1
            }
            return drawn
        }
    }
}
