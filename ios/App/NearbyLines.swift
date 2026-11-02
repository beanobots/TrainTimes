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

    /// Meters past the places, and the map's middle, lines are drawn.
    private static let reach: Double = 2500
    /// Meters from a line's track already drawn that another of its shapes (a branch, a
    /// late-night route) is taken to be on it, and not drawn again.
    private static let sameTrack: Double = 60

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
        buses = Self.runs(of: busLines.map(TrackShapes.busKey), in: TrackShapes.byBusLine, box: box)
            .map { $0.points.map(\.coordinate) }
    }

    /// The bus lines whose streets pass within `meters` of `point`, nearest first: those a few
    /// minutes' walk away, without asking Bus Time for its stops.
    static func busLines(near point: CLLocationCoordinate2D, within meters: Double) -> [String] {
        let here = MKMapPoint(point)
        let reach = meters * MKMapPointsPerMeterAtLatitude(point.latitude)
        let near = TrackShapes.byBusLine.compactMap { line, shapes -> (String, Double)? in
            let closest = shapes.lazy.flatMap { $0 }.map(MKMapPoint.init)
                .filter { abs($0.x - here.x) < reach && abs($0.y - here.y) < reach }
                .map { $0.distance(to: here) }.min()
            return closest.flatMap { $0 < meters ? (line, $0) : nil }
        }
        return near.sorted { $0.1 < $1.1 }.map(\.0)
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
    /// route's already drawn.
    private static func runs(of routes: [String], in shapes: [String: [[CLLocationCoordinate2D]]],
                             box: MKMapRect) -> [(route: String, points: [MKMapPoint])] {
        var runs: [(route: String, points: [MKMapPoint])] = []
        var seen: Set<String> = []
        for route in routes where seen.insert(route).inserted {
            var kept: [MKMapPoint] = []
            for shape in shapes[route] ?? [] {
                var run: [MKMapPoint] = []
                var last: MKMapPoint?
                func finish(at end: MKMapPoint?) {
                    // Joined to where it meets the track drawn, so a branch doesn't start apart
                    if let end, !run.isEmpty { run.append(end) }
                    if run.count > 1 { runs.append((route, run)) }
                    run = []
                }
                for point in TripMap.densified(shape).map(MKMapPoint.init) {
                    if !box.contains(point) {
                        finish(at: nil)
                    } else if kept.contains(where: { $0.distance(to: point) < sameTrack }) {
                        finish(at: point)
                    } else {
                        if run.isEmpty, let last, box.contains(last) { run.append(last) }
                        run.append(point)
                    }
                    last = point
                }
                finish(at: nil)
                kept = runs.filter { $0.route == route }.flatMap(\.points)
            }
        }
        return runs
    }
}
