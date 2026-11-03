import Foundation
import simd

/// The city's protected bike lanes and paths (bike_lanes.json, made by tools/make_bike_lanes.py
/// from NYC DOT's bike route map), for how much of a Citi Bike ride runs on them. Only shown, not
/// routed by: the ride's still Apple Maps' own.
enum BikeLanes {
    /// Meters the ride may be from a lane's line and be on it: DOT's lines and Apple Maps' both
    /// run down the street, a wide avenue's lane off to its side, and the next street over is
    /// 80 m or more.
    private static let reach: Double = 20
    /// Degrees the ride may turn from the lane's way and still be along it, not across it.
    private static let turn: Double = 30
    /// Meters between the points of the ride tried.
    private static let step: Double = 10
    /// Meters each side of the grid's squares.
    private static let cell: Double = 100

    private struct Lane {
        let from: SIMD2<Double>
        let to: SIMD2<Double>
        /// Whether it's only ridden the way it's drawn.
        let oneWay: Bool
    }

    private struct Index {
        let lanes: [Lane]
        /// The lanes passing within `reach` of each square.
        let cells: [Int64: [Int32]]
    }

    private static let index: Index = load()

    /// How much of `path` runs on a protected lane or path, 0 to 1; nil if it's too short to say.
    static func protectedShare(of path: [Walk.Point]) -> Double? {
        let points = path.map(flat)
        var total = 0.0, protected = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let length = simd_length(b - a)
            guard length > 0 else { continue }
            let way = (b - a) / length
            // Each `step` of the segment, tried at its middle
            let steps = max(1, Int((length / step).rounded()))
            let each = length / Double(steps)
            for index in 0..<steps {
                let point = a + way * (each * (Double(index) + 0.5))
                total += each
                if isOnLane(point, way: way) { protected += each }
            }
        }
        return total >= step ? protected / total : nil
    }

    private static func isOnLane(_ point: SIMD2<Double>, way: SIMD2<Double>) -> Bool {
        let minimum = cos(turn * .pi / 180)
        for number in index.cells[key(point)] ?? [] {
            let lane = index.lanes[Int(number)]
            let along = lane.to - lane.from
            let length = simd_length(along)
            guard length > 0 else { continue }
            let laneWay = along / length
            let alike = simd_dot(way, laneWay)
            guard (lane.oneWay ? alike : abs(alike)) >= minimum else { continue }
            let part = min(max(simd_dot(point - lane.from, laneWay), 0), length)
            if simd_length(point - (lane.from + laneWay * part)) <= reach { return true }
        }
        return false
    }

    // MARK: The lanes

    /// Where the city's measured from, and meters to a degree there.
    private static let origin = (lat: 40.7, lon: -74.0)
    private static let metersPerLat = 111_000.0
    private static let metersPerLon = 111_000.0 * cos(40.7 * .pi / 180)

    private static func flat(_ point: Walk.Point) -> SIMD2<Double> {
        SIMD2((point.lon - origin.lon) * metersPerLon, (point.lat - origin.lat) * metersPerLat)
    }

    private static func key(_ point: SIMD2<Double>) -> Int64 {
        key(Int64((point.x / cell).rounded(.down)), Int64((point.y / cell).rounded(.down)))
    }

    private static func key(_ x: Int64, _ y: Int64) -> Int64 { x << 32 | (y & 0xFFFF_FFFF) }

    private static func load() -> Index {
        guard let url = Bundle.main.url(forResource: "bike_lanes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let encoded = try? JSONDecoder().decode([String: [[Int]]].self, from: data)
        else { return Index(lanes: [], cells: [:]) }
        var lanes: [Lane] = []
        var cells: [Int64: [Int32]] = [:]
        for (kind, shapes) in encoded {
            for shape in shapes {
                let points = decode(shape)
                for (a, b) in zip(points, points.dropFirst()) {
                    let number = Int32(lanes.count)
                    lanes.append(Lane(from: a, to: b, oneWay: kind == "along"))
                    // Each square its box, out to `reach`, touches
                    let low = simd_min(a, b) - reach, high = simd_max(a, b) + reach
                    for x in Int64((low.x / cell).rounded(.down))...Int64((high.x / cell).rounded(.down)) {
                        for y in Int64((low.y / cell).rounded(.down))...Int64((high.y / cell).rounded(.down)) {
                            cells[key(x, y), default: []].append(number)
                        }
                    }
                }
            }
        }
        return Index(lanes: lanes, cells: cells)
    }

    /// `flat`'s latitudes and longitudes as make_shapes.py encodes them, as meters from `origin`.
    private static func decode(_ flat: [Int]) -> [SIMD2<Double>] {
        var latitude = 0, longitude = 0
        return stride(from: 0, to: flat.count - 1, by: 2).map { index in
            latitude += flat[index]
            longitude += flat[index + 1]
            return self.flat(Walk.Point(lat: Double(latitude) / 1e5, lon: Double(longitude) / 1e5))
        }
    }
}
