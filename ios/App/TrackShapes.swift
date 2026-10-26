import CoreLocation
import Foundation

/// The MTA's track for each line (shapes.json, made by tools/make_shapes.py), for drawing New
/// Trip's rides along the track rather than straight from station to station.
enum TrackShapes {
    /// Each GTFS route id's shapes, the longest first.
    static let byRoute: [String: [[CLLocationCoordinate2D]]] = {
        guard let url = Bundle.main.url(forResource: "shapes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let encoded = try? JSONDecoder().decode([String: [[Int]]].self, from: data) else { return [:] }
        return encoded.mapValues { $0.map(decode) }
    }()

    /// Meters a station may be from a shape that's taken to pass it.
    private static let reach: CLLocationDistance = 250

    /// The stretch of `route`'s track from `start` to `end`: the shortest of the shapes that pass
    /// both, as a late-night or rerouted shape (the N through the Montague St tunnel rather than
    /// over the Manhattan Bridge) passes them as closely, the long way round. Nil if none passes
    /// both, or the stretch goes far out of the way, as along a branch.
    static func track(of route: String, from start: CLLocationCoordinate2D,
                      to end: CLLocationCoordinate2D) -> [CLLocationCoordinate2D]? {
        let direct = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        var best: (meters: Double, path: [CLLocationCoordinate2D])?
        for shape in byRoute[route] ?? [] where shape.count > 1 {
            guard let from = nearest(start, on: shape), let to = nearest(end, on: shape),
                  from.meters <= reach, to.meters <= reach else { continue }
            let path: [CLLocationCoordinate2D] = if (from.segment, from.along) <= (to.segment, to.along) {
                [from.point] + shape[(from.segment + 1)..<(to.segment + 1)] + [to.point]
            } else {
                [from.point] + shape[(to.segment + 1)..<(from.segment + 1)].reversed() + [to.point]
            }
            // Its length, and how far its ends are from `start` and `end`
            let meters = length(of: path) + from.meters + to.meters
            guard length(of: path) <= max(direct * 3, direct + 3_000), meters < best?.meters ?? .infinity else { continue }
            best = (meters, path)
        }
        return best?.path
    }

    /// The point on `path` closest to `coordinate`, to draw a station on its line rather than
    /// beside it; `coordinate` itself if `path` has no segments.
    static func snapped(_ coordinate: CLLocationCoordinate2D, to path: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard path.count > 1 else { return coordinate }
        return nearest(coordinate, on: path)?.point ?? coordinate
    }

    /// Meters of curve at most at each of a path's corners.
    private static let cornerRadius: CLLocationDistance = 200
    /// Points along each corner's curve.
    private static let cornerSteps = 12

    /// `path` with its corners curved, as the track runs, rather than the sharp turns where its
    /// simplified points meet: each corner's cut back along both sides, by `cornerRadius` or
    /// under half of the shorter side, and joined by a curve through where the corner was.
    static func rounded(_ path: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard path.count > 2 else { return path }
        func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
            CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        func toward(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D, _ part: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: from.latitude + (to.latitude - from.latitude) * part,
                                   longitude: from.longitude + (to.longitude - from.longitude) * part)
        }
        var result = [path[0]]
        for index in 1..<(path.count - 1) {
            let before = path[index - 1], corner = path[index], after = path[index + 1]
            let inLength = distance(before, corner), outLength = distance(corner, after)
            let cut = min(cornerRadius, inLength * 0.45, outLength * 0.45)
            guard cut > 1 else {
                result.append(corner)
                continue
            }
            let entry = toward(corner, before, cut / inLength)
            let exit = toward(corner, after, cut / outLength)
            // A quadratic curve from entry to exit, pulled toward the corner
            for step in 0...cornerSteps {
                let t = Double(step) / Double(cornerSteps)
                let a = toward(entry, corner, t), b = toward(corner, exit, t)
                result.append(toward(a, b, t))
            }
        }
        result.append(path[path.count - 1])
        return result
    }

    /// `flat`'s latitudes and longitudes, each after the first a change from the one before, in
    /// hundred-thousandths of a degree.
    private static func decode(_ flat: [Int]) -> [CLLocationCoordinate2D] {
        var latitude = 0, longitude = 0
        return stride(from: 0, to: flat.count - 1, by: 2).map { index in
            latitude += flat[index]
            longitude += flat[index + 1]
            return CLLocationCoordinate2D(latitude: Double(latitude) / 1e5, longitude: Double(longitude) / 1e5)
        }
    }

    /// Where on `shape` is closest to `coordinate`: the segment, how far along it (0 to 1), the
    /// point, and how many meters away.
    private static func nearest(_ coordinate: CLLocationCoordinate2D, on shape: [CLLocationCoordinate2D])
        -> (segment: Int, along: Double, point: CLLocationCoordinate2D, meters: Double)? {
        // Meters east and north of `coordinate`, near enough on a flat map at this scale
        let perDegree = 111_320.0
        let eastPerDegree = perDegree * cos(coordinate.latitude * .pi / 180)
        func flat(_ point: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((point.longitude - coordinate.longitude) * eastPerDegree, (point.latitude - coordinate.latitude) * perDegree)
        }
        var best: (segment: Int, along: Double, point: CLLocationCoordinate2D, meters: Double)?
        for segment in 0..<(shape.count - 1) {
            let a = flat(shape[segment]), b = flat(shape[segment + 1])
            let dx = b.x - a.x, dy = b.y - a.y
            let squared = dx * dx + dy * dy
            let along = squared == 0 ? 0 : max(0, min(1, -(a.x * dx + a.y * dy) / squared))
            let x = a.x + along * dx, y = a.y + along * dy
            let meters = (x * x + y * y).squareRoot()
            if meters < best?.meters ?? .infinity {
                let point = CLLocationCoordinate2D(latitude: coordinate.latitude + y / perDegree,
                                                   longitude: coordinate.longitude + x / eastPerDegree)
                best = (segment, along, point, meters)
            }
        }
        return best
    }

    private static func length(of path: [CLLocationCoordinate2D]) -> CLLocationDistance {
        zip(path, path.dropFirst()).reduce(0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }
}
