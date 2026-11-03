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

    /// `routes`' tracks and `busLines`' streets within `reach` of `points`.
    init(routes: [String], busLines: [String], around points: [CLLocationCoordinate2D]) {
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
        buses = Self.runs(of: busLines.map(TrackShapes.busKey), in: TrackShapes.byBusLine, box: box, acrossRoutes: true)
            .map { $0.points.map(\.coordinate) }
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

/// `lines` on a map: bus routes pale and thin under the subway's, each subway line its colour,
/// those side by side as far apart as they're wide at the map's zoom (`mapPointsPerPoint`, as
/// it last came to rest). `version` counts up with each new `lines`.
struct NearbyLinesLayer: MapContent {
    let lines: NearbyLines
    let version: Int
    let mapPointsPerPoint: Double

    /// A line on its own, each of two or more side by side, and a bus route.
    private static let lineWidth: CGFloat = 5
    private static let besideWidth: CGFloat = 4
    private static let busWidth: CGFloat = 3
    private static let busColor = BusBadge.blue.opacity(0.35)

    private struct Drawn: Identifiable {
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

    /// New lines for each zoom, as MapKit keeps a line's last shape while its id stays.
    private var drawn: [Drawn] {
        let metersPerPoint = mapPointsPerPoint / MKMapPointsPerMeterAtLatitude(lines.latitude)
        guard metersPerPoint <= Self.farthest else { return [] }
        let apart = Double(Self.besideWidth) * mapPointsPerPoint
        let zoom = mapPointsPerPoint > 0 ? Int((log2(mapPointsPerPoint) * 4).rounded()) : 0
        let buses = lines.buses.indices.map { index in
            Drawn(id: "bus-\(version)-\(index)", coordinates: lines.buses[index], color: Self.busColor, width: Self.busWidth)
        }
        let subway = lines.tracks.indices.map { index in
            let track = lines.tracks[index]
            return Drawn(id: "line-\(version)-\(zoom)-\(index)",
                         coordinates: TripMap.offset(track.coordinates, by: track.lanes.map { $0 * apart }),
                         color: LineStyle.of(track.route).swiftUIColor,
                         width: track.isBeside ? Self.besideWidth : Self.lineWidth)
        }
        return buses + subway
    }
}
