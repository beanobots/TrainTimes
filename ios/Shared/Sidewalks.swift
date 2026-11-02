import Foundation

/// Walks put on the sidewalk. Apple Maps' walking directions run down the middle of the street;
/// these move each block of a walk onto the sidewalk on one side, by the city's sidewalks (NYC's
/// Planimetric Database, `tools/make_sidewalks.py`), changing sides only at corners and as few
/// times as it can, starting on the start's side and ending on the end's.
enum Sidewalks {
    /// A sidewalk's rings: the first its curb, any others the building line round holes in it.
    typealias Rings = [[Walk.Point]]

    /// The blob layout `make_sidewalks.py` writes, and this reads.
    static let format = "1"

    // MARK: Reading

    /// A sidewalk's rings from its blob: how many rings, then each one's count of points and their
    /// latitude and longitude changes in millionths of a degree, zigzagged varints carrying on
    /// from the ring before. Nil if it's cut short.
    static func rings(from bytes: some Collection<UInt8>) -> Rings? {
        var iterator = bytes.makeIterator()
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while let byte = iterator.next() {
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        func signed() -> Int64? {
            varint().map { Int64(bitPattern: ($0 >> 1) ^ (0 &- ($0 & 1))) }
        }
        guard let count = varint(), count < 10_000 else { return nil }
        var rings: Rings = []
        var lat: Int64 = 0, lon: Int64 = 0
        for _ in 0..<count {
            guard let points = varint(), points < 1_000_000 else { return nil }
            var ring: [Walk.Point] = []
            ring.reserveCapacity(Int(points))
            for _ in 0..<points {
                guard let dLat = signed(), let dLon = signed() else { return nil }
                lat += dLat
                lon += dLon
                ring.append(Walk.Point(lat: Double(lat) / 1e6, lon: Double(lon) / 1e6))
            }
            rings.append(ring)
        }
        return rings
    }

    // MARK: Fitting

    /// Metres between the points it looks either side from, along the walk.
    static let spacing = 4.0
    /// Metres either side it looks for a sidewalk: past the middle of the widest avenues.
    static let reach = 40.0
    /// Metres the sidewalk's edge may move between one point and the next and still be the same
    /// block's: more is a corner, a bulb-out or a different street.
    static let jump = 4.0
    /// Fewest points in a row with a sidewalk on both sides for a block: fewer is a corner.
    static let shortest = 3
    /// Degrees the way turns between blocks to count as turning a corner, not going on across.
    static let turning = 35.0
    /// Metres wide a sidewalk can be before it's a plaza, where the line keeps near the curb.
    static let plaza = 10.0
    /// Share of a walk that must have sidewalks either side for it to be moved onto them.
    static let enough = 0.5

    /// `walk` on the sidewalks in `sidewalks`, from `start` (whose side of the street it starts
    /// on) to `end` (whose side it ends on), each step's instruction kept and its path and length
    /// those on the sidewalk; where it crosses a street, in `crossings`. Nil where too little of
    /// it has a sidewalk either side to go by: outside the city's data, or across a park.
    static func fit(_ walk: Walk, sidewalks: [Rings], start: Walk.Point? = nil, end: Walk.Point? = nil) -> Walk? {
        // Steps with somewhere to walk; the ways down and up are a point, at the station
        let walked = walk.steps.indices.filter { walk.steps[$0].points.count >= 2 }
        guard let origin = walked.first.flatMap({ walk.steps[$0].points.first }), !sidewalks.isEmpty else { return nil }
        let plane = Plane(origin: origin)
        let edges = Edges(sidewalks.flatMap { $0.map { $0.map(plane.xy) } })
        let samples = Self.samples(of: walk, steps: walked, plane: plane)
        guard samples.count >= 2 else { return nil }
        let sides = samples.map { sample -> Sides in
            if edges.inside(sample.at) { return Sides(onSidewalk: true) }
            return Sides(left: edges.sidewalk(from: sample.at, along: sample.left),
                         right: edges.sidewalk(from: sample.at, along: sample.left * -1))
        }
        let runs = Self.runs(sides)
        let paired = runs.reduce(0) { $0 + $1.count }
        guard !runs.isEmpty, Double(paired) >= Double(samples.count) * enough else { return nil }
        let chosen = choose(runs, samples: samples, sides: sides,
                            start: start.map(plane.xy), end: end.map(plane.xy))
        return path(walk, walked: walked, samples: samples, sides: sides, runs: runs, chosen: chosen,
                    edges: edges, plane: plane, start: walked.first.flatMap { walk.steps[$0].points.first },
                    end: walked.last.flatMap { walk.steps[$0].points.last })
    }

    /// A point along the walk: where, which way it's going, and the step it's part of.
    struct Sample {
        let at: V
        let direction: V
        let step: Int

        /// Its left, a metre long.
        var left: V { V(x: -direction.y, y: direction.x) }
    }

    /// The sidewalk's middle either side of a sample, or that it's on one already (Apple Maps'
    /// walk going along a path, through a plaza).
    struct Sides {
        var left: V?
        var right: V?
        var onSidewalk = false

        init(left: V? = nil, right: V? = nil, onSidewalk: Bool = false) {
            self.left = left
            self.right = right
            self.onSidewalk = onSidewalk
        }

        func side(_ side: Side) -> V? { side == .left ? left : right }
    }

    enum Side: Int, CaseIterable {
        case left, right

        var other: Side { self == .left ? .right : .left }
    }

    /// The walk's path every `spacing`, each point going the way the path goes there.
    static func samples(of walk: Walk, steps: [Int], plane: Plane) -> [Sample] {
        var samples: [Sample] = []
        for step in steps {
            let points = walk.steps[step].points.map(plane.xy)
            for (a, b) in zip(points, points.dropFirst()) {
                let piece = b - a
                let length = piece.length
                guard length > 0.01 else { continue }
                let direction = piece * (1 / length)
                var along = 0.0
                while along < length {
                    samples.append(Sample(at: a + direction * along, direction: direction, step: step))
                    along += spacing
                }
            }
        }
        if let lastStep = steps.last, let last = walk.steps[lastStep].points.last, let before = samples.last {
            samples.append(Sample(at: plane.xy(last), direction: before.direction, step: lastStep))
        }
        return samples
    }

    /// The blocks of the walk: runs of samples with a sidewalk both sides whose edges carry on
    /// from one to the next, `shortest` or longer. What's between them is a corner, or a piece
    /// with no sidewalk to go by.
    static func runs(_ sides: [Sides]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        func close(_ end: Int) {
            if let begun = start, end - begun >= shortest { runs.append(begun..<end) }
            start = nil
        }
        for index in sides.indices {
            let here = sides[index]
            guard !here.onSidewalk, let left = here.left, let right = here.right else {
                close(index)
                continue
            }
            if start != nil, let previousLeft = sides[index - 1].left, let previousRight = sides[index - 1].right,
               (left - previousLeft).length > jump || (right - previousRight).length > jump {
                close(index)
            }
            if start == nil { start = index }
        }
        close(sides.count)
        return runs
    }

    /// Which way the walk turns from the end of one block to the start of the next.
    enum Corner {
        case across, left, right

        init(from a: V, to b: V) {
            let degrees = atan2(a.cross(b), a.dot(b)) * 180 / .pi
            self = degrees > Sidewalks.turning ? .left : degrees < -Sidewalks.turning ? .right : .across
        }

        /// Streets crossed going from `a`'s side of one block to `b`'s of the next, beyond any the
        /// corner makes you cross whichever side you're on: none round the inside of a turn, two
        /// round its outside.
        func crossings(_ a: Side, _ b: Side) -> Int {
            switch self {
            case .across: a == b ? 0 : 1
            case .left: a.rawValue + b.rawValue
            case .right: 2 - a.rawValue - b.rawValue
            }
        }
    }

    /// Each block's side: the fewest streets crossed, starting on `start`'s side of the first
    /// block and ending on `end`'s of the last, where they're clearly on one side.
    static func choose(_ runs: [Range<Int>], samples: [Sample], sides: [Sides], start: V?, end: V?) -> [Side] {
        func sideOf(_ point: V?, at sample: Sample) -> Side? {
            guard let point else { return nil }
            let lateral = sample.direction.cross(point - sample.at)
            // In the street, or too far off to say
            guard abs(lateral) > 3, (point - sample.at).length < 80 else { return nil }
            return lateral > 0 ? .left : .right
        }
        let first = sideOf(start, at: samples[runs[0].lowerBound])
        let last = sideOf(end, at: samples[runs[runs.count - 1].upperBound - 1])
        let impossible = 1_000
        // The fewest crossings to each side of each block, and the side of the block before
        var cost: [[Int]] = [Side.allCases.map { first == nil || first == $0 ? 0 : impossible }]
        var from: [[Side]] = [[.left, .right]]
        for index in runs.indices.dropFirst() {
            let corner = Corner(from: samples[runs[index - 1].upperBound - 1].direction,
                                to: samples[runs[index].lowerBound].direction)
            var row: [Int] = []
            var back: [Side] = []
            for side in Side.allCases {
                let best = Side.allCases.min {
                    cost[index - 1][$0.rawValue] + corner.crossings($0, side)
                        < cost[index - 1][$1.rawValue] + corner.crossings($1, side)
                } ?? .left
                row.append(cost[index - 1][best.rawValue] + corner.crossings(best, side))
                back.append(best)
            }
            cost.append(row)
            from.append(back)
        }
        if let last { cost[cost.count - 1][last.other.rawValue] += impossible }
        let final = cost[cost.count - 1]
        var side: Side = final[Side.left.rawValue] <= final[Side.right.rawValue] ? .left : .right
        var chosen = [side]
        for index in runs.indices.dropFirst().reversed() {
            side = from[index][side.rawValue]
            chosen.append(side)
        }
        return chosen.reversed()
    }

    /// The walk along the chosen sides, with the corners between them, each point in the step its
    /// sample was; `start` and `end` as Apple Maps had them, at the door and the station.
    static func path(_ walk: Walk, walked: [Int], samples: [Sample], sides: [Sides], runs: [Range<Int>],
                     chosen: [Side], edges: Edges, plane: Plane, start: Walk.Point?, end: Walk.Point?) -> Walk {
        // Each point, its step, and whether the way to it crosses a street
        var out: [(at: V, step: Int, crossing: Bool)] = []
        func add(_ point: V, step: Int, crossing: Bool = false) {
            if let last = out.last, (last.at - point).length < 0.3 { return }
            out.append((point, step, crossing))
        }
        /// In the street, rather than on a sidewalk: the way from `a` to `b` crosses one.
        func crosses(_ a: V, _ b: V) -> Bool { !edges.inside((a + b) * 0.5) }

        if let start { add(plane.xy(start), step: samples[0].step) }
        for (index, run) in runs.enumerated() {
            let side = chosen[index]
            let points = Self.smoothed(run.compactMap { sides[$0].side(side) })
            if index > 0 {
                let previous = runs[index - 1], before = chosen[index - 1]
                let endSample = samples[previous.upperBound - 1], startSample = samples[run.lowerBound]
                guard let from = out.last?.at, let to = points.first else { continue }
                let between = (previous.upperBound..<run.lowerBound).filter { sides[$0].onSidewalk }
                if between.count >= shortest {
                    // A path between the blocks: Apple Maps' way along it
                    for sampleIndex in between { add(samples[sampleIndex].at, step: samples[sampleIndex].step) }
                } else {
                    switch Corner(from: endSample.direction, to: startSample.direction) {
                    case .across where before != side:
                        // Over this street at the corner, then on across the next
                        if let over = sides[previous.upperBound - 1].side(side) {
                            add(over, step: endSample.step, crossing: crosses(from, over))
                        }
                    case .left, .right:
                        // Round the corner where the two sidewalks' lines meet
                        if let corner = meeting(from, endSample.direction, to, startSample.direction) {
                            add(corner, step: endSample.step, crossing: crosses(out.last?.at ?? from, corner))
                        }
                    case .across:
                        break
                    }
                }
                if let last = out.last?.at {
                    add(to, step: startSample.step, crossing: crosses(last, to))
                }
            }
            for (offset, point) in points.enumerated() {
                add(point, step: samples[run.lowerBound + offset].step)
            }
        }
        if let end { add(plane.xy(end), step: samples[samples.count - 1].step) }

        // Back into steps, each beginning where the one before ended
        var fitted = walk
        var crossings: [[Walk.Point]] = []
        var total = 0.0
        var previous: V?
        for step in walked {
            let mine = out.enumerated().filter { $0.element.step == step }
            var points = mine.map { plane.point($0.element.at) }
            var meters = 0.0
            for (index, element) in mine {
                let from = index > 0 ? out[index - 1].at : previous ?? element.at
                meters += (element.at - from).length
            }
            if points.isEmpty, let previous { points = [plane.point(previous)] }
            if let last = mine.last { previous = last.element.at }
            fitted.steps[step].points = points
            fitted.steps[step].meters = meters
            total += meters
        }
        for index in out.indices.dropFirst() where out[index].crossing {
            let from = plane.point(out[index - 1].at), to = plane.point(out[index].at)
            if let last = crossings.last?.last, last == from {
                crossings[crossings.count - 1].append(to)
            } else {
                crossings.append([from, to])
            }
        }
        fitted.meters = total
        fitted.crossings = crossings
        return fitted
    }

    /// Where the line through `a` going `da` meets the one through `b` going `db`: ahead of `a`
    /// and behind `b`, within `reach` of both. Nil for lines near parallel.
    static func meeting(_ a: V, _ da: V, _ b: V, _ db: V) -> V? {
        let denominator = da.cross(db)
        guard abs(denominator) > 0.2 else { return nil }
        let t = (b - a).cross(db) / denominator
        let point = a + da * t
        guard t > -2, (b - point).dot(db) > -2, (point - a).length < reach, (point - b).length < reach else { return nil }
        return point
    }

    /// `points` with each the average of it and its neighbours, the ends kept: a line along the
    /// sidewalk without GPS-like wobble from its edges' small steps.
    static func smoothed(_ points: [V]) -> [V] {
        guard points.count > 2 else { return points }
        return points.indices.map { index in
            index == 0 || index == points.count - 1 ? points[index]
                : (points[index - 1] + points[index] + points[index + 1]) * (1.0 / 3)
        }
    }

    // MARK: Geometry

    /// Metres east and north.
    struct V: Equatable {
        var x: Double
        var y: Double

        static func + (a: V, b: V) -> V { V(x: a.x + b.x, y: a.y + b.y) }
        static func - (a: V, b: V) -> V { V(x: a.x - b.x, y: a.y - b.y) }
        static func * (a: V, k: Double) -> V { V(x: a.x * k, y: a.y * k) }
        func dot(_ other: V) -> Double { x * other.x + y * other.y }
        /// Positive when `other` is to the left.
        func cross(_ other: V) -> Double { x * other.y - y * other.x }
        var length: Double { (x * x + y * y).squareRoot() }
    }

    /// Latitude and longitude as metres east and north of `origin`, as `Walk.Point.offset` has it.
    struct Plane {
        let origin: Walk.Point
        let east: Double
        let north = 111_320.0

        init(origin: Walk.Point) {
            self.origin = origin
            east = 111_320 * cos(origin.lat * .pi / 180)
        }

        func xy(_ point: Walk.Point) -> V { V(x: (point.lon - origin.lon) * east, y: (point.lat - origin.lat) * north) }
        func point(_ v: V) -> Walk.Point { Walk.Point(lat: origin.lat + v.y / north, lon: origin.lon + v.x / east) }
    }

    /// The sidewalks' edges, curbs and building lines alike, in a grid to find those near a line.
    struct Edges {
        private var segments: [(V, V)] = []
        private var cells: [Cell: [Int]] = [:]
        private static let size = 10.0

        private struct Cell: Hashable {
            let x: Int
            let y: Int
        }

        init(_ rings: [[V]]) {
            for ring in rings {
                for (a, b) in zip(ring, ring.dropFirst()) where a != b {
                    let index = segments.count
                    segments.append((a, b))
                    for cell in Self.cells(from: a, to: b) { cells[cell, default: []].append(index) }
                }
            }
        }

        private static func cells(from a: V, to b: V) -> [Cell] {
            let x0 = Int((min(a.x, b.x) / size).rounded(.down)), x1 = Int((max(a.x, b.x) / size).rounded(.down))
            let y0 = Int((min(a.y, b.y) / size).rounded(.down)), y1 = Int((max(a.y, b.y) / size).rounded(.down))
            return (x0...x1).flatMap { x in (y0...y1).map { Cell(x: x, y: $0) } }
        }

        /// How far along the ray from `p` going `direction` (a metre long) it crosses an edge,
        /// nearest first, out to `distance`.
        func crossings(from p: V, along direction: V, upTo distance: Double) -> [Double] {
            let end = p + direction * distance
            var seen = Set<Int>()
            var hits: [Double] = []
            for cell in Self.cells(from: p, to: end) {
                for index in cells[cell] ?? [] where seen.insert(index).inserted {
                    let (a, b) = segments[index]
                    let edge = b - a
                    let denominator = direction.cross(edge)
                    guard abs(denominator) > 1e-9 else { continue }
                    let t = (a - p).cross(edge) / denominator
                    let u = (a - p).cross(direction) / denominator
                    if t >= 0, t <= distance, u >= 0, u < 1 { hits.append(t) }
                }
            }
            return hits.sorted()
        }

        /// Whether `p` is on a sidewalk: an odd number of edges to its east.
        func inside(_ p: V) -> Bool {
            crossings(from: p, along: V(x: 1, y: 0), upTo: 2_000).count % 2 == 1
        }

        /// The middle of the first sidewalk from `p` going `direction`, within `reach`; near its
        /// curb where it's wider than a sidewalk is.
        func sidewalk(from p: V, along direction: V) -> V? {
            var on = false
            var enter: Double?
            var exit: Double?
            for t in crossings(from: p, along: direction, upTo: Sidewalks.reach) {
                on.toggle()
                if on {
                    if enter == nil { enter = t }
                } else if enter != nil {
                    exit = t
                    break
                }
            }
            guard let enter else { return nil }
            let width = (exit ?? Sidewalks.reach) - enter
            let into = width > Sidewalks.plaza ? 2.5 : width / 2
            return p + direction * (enter + into)
        }
    }
}
