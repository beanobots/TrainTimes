import CoreLocation
import MapKit

/// Every bus line's each way, drawn on its own side of the street, and every stop on its line
/// (bus_network.json, made by tools/make_bus_network.py from the MTA's schedules and the city's
/// street centrelines): placed on the ground once, so the maps draw them as they are, never laid
/// out again as they zoom. Where lines run the same street the same way, they lie exactly over
/// each other, drawn as one.
enum BusNetwork {
    struct Way {
        /// Its place in the file, to tell the same way of two lines apart.
        let index: Int
        /// The lines along it, as `TrackShapes.busKey` has them.
        let lines: [String]
        /// In the order its buses go.
        let coordinates: [CLLocationCoordinate2D]
    }

    struct Stop {
        /// The MTA's stop code, as Bus Time and the stop's sign have it.
        let id: String
        /// On its line, where its mark sits.
        let coordinate: CLLocationCoordinate2D
        /// Degrees clockwise from north the way its buses go.
        let bearing: Double
        /// As `TrackShapes.busKey` has them.
        let lines: [String]

        /// `bearing` as map points have it (x east, y south), in radians.
        var angle: Double {
            let radians = bearing * .pi / 180
            return atan2(-cos(radians), sin(radians))
        }
    }

    /// Each line's ways, by `TrackShapes.busKey`.
    static let byLine: [String: [Way]] = {
        var byLine: [String: [Way]] = [:]
        for way in file.ways {
            for line in way.lines { byLine[line, default: []].append(way) }
        }
        return byLine
    }()

    /// Every stop, and each by its stop code.
    static var stops: [Stop] { file.stops }
    static let stopByID: [String: Stop] = Dictionary(file.stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// `lines`' ways, each piece once however many of them run along it.
    static func ways(of lines: [String]) -> [Way] {
        var seen: Set<Int> = []
        return Set(lines.map(TrackShapes.busKey)).sorted().flatMap { byLine[$0] ?? [] }
            .filter { seen.insert($0.index).inserted }
    }

    /// Metres a stop may be from its line's way to be ridden along it.
    private static let pathReach = 200.0

    /// The way `line` goes from `from` to `to`, along its street, or nil where none of its ways
    /// passes both in that order (a ride's drawn straight then). Express buses run miles between
    /// stops (a SIM's last Brooklyn stop to its first in Manhattan), so straight reads wrong.
    static func path(of line: String, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> [CLLocationCoordinate2D]? {
        let start = MKMapPoint(from), end = MKMapPoint(to)
        // Where on a way a point's nearest: its segment, how far along it, the point there and
        // metres away
        func nearest(_ p: MKMapPoint, on points: [MKMapPoint]) -> (segment: Int, t: Double, point: MKMapPoint, meters: Double) {
            var best = (segment: 0, t: 0.0, point: points[0], meters: Double.infinity)
            for i in 0..<(points.count - 1) {
                let a = points[i], b = points[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y
                let length2 = dx * dx + dy * dy
                let t = length2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2)) : 0
                let q = MKMapPoint(x: a.x + dx * t, y: a.y + dy * t)
                let meters = q.distance(to: p)
                if meters < best.meters { best = (i, t, q, meters) }
            }
            return best
        }
        var best: (meters: Double, path: [CLLocationCoordinate2D])?
        for way in byLine[TrackShapes.busKey(line)] ?? [] where way.coordinates.count > 1 {
            let points = way.coordinates.map(MKMapPoint.init)
            let on = nearest(start, on: points), off = nearest(end, on: points)
            guard on.meters <= pathReach, off.meters <= pathReach,
                  (on.segment, on.t) < (off.segment, off.t) else { continue }
            let meters = on.meters + off.meters
            guard best.map({ meters < $0.meters }) ?? true else { continue }
            let between = on.segment < off.segment ? Array(way.coordinates[(on.segment + 1)...off.segment]) : []
            best = (meters, [on.point.coordinate] + between + [off.point.coordinate])
        }
        return best?.path
    }

    private struct File: Decodable {
        let format: Int
        let lines: [String]
        let ways: [[Int]]
        let stops: [[Int]]
        let stopIDs: [String]
    }

    /// The format `make_bus_network.py` writes.
    private static let format = 2

    private static let file: (ways: [Way], stops: [Stop]) = {
        guard let url = Bundle.main.url(forResource: "bus_network", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data), file.format == format else { return ([], []) }
        let names = file.lines.map(TrackShapes.busKey)
        let line = { (index: Int) in names.indices.contains(index) ? names[index] : nil }
        let ways = file.ways.enumerated().compactMap { index, row -> Way? in
            guard let count = row.first, count > 0, row.count > count + 3 else { return nil }
            // Millionths of a degree, each point a change from the one before
            var latitude = 0, longitude = 0
            var coordinates: [CLLocationCoordinate2D] = []
            coordinates.reserveCapacity((row.count - count - 1) / 2)
            var at = count + 1
            while at + 1 < row.count {
                latitude += row[at]
                longitude += row[at + 1]
                coordinates.append(CLLocationCoordinate2D(latitude: Double(latitude) / 1e6, longitude: Double(longitude) / 1e6))
                at += 2
            }
            return Way(index: index, lines: row[1...count].compactMap(line), coordinates: coordinates)
        }
        let stops = zip(file.stops, file.stopIDs).compactMap { row, id -> Stop? in
            guard row.count > 3 else { return nil }
            return Stop(id: id, coordinate: CLLocationCoordinate2D(latitude: Double(row[0]) / 1e6, longitude: Double(row[1]) / 1e6),
                        bearing: Double(row[2]), lines: row.dropFirst(3).compactMap(line))
        }
        return (ways, stops)
    }()
}
