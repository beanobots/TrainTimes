import Foundation

/// Walks put on the sidewalk. Apple Maps' walking directions run down the middle of the street;
/// these move each block of a walk onto the sidewalk on one side, by the city's sidewalks (NYC's
/// Planimetric Database, `tools/make_sidewalks.py`), changing sides only at corners and as few
/// times as it can, starting on the start's side and ending on the end's. Where it could cross
/// at one corner or another, it's the narrowest street with a signal (`tools/make_signals.py`).
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
        var reader = Varints(bytes)
        guard let count = reader.next(), count < 10_000 else { return nil }
        var rings: Rings = []
        var lat: Int64 = 0, lon: Int64 = 0
        for _ in 0..<count {
            guard let points = reader.next(), points < 1_000_000 else { return nil }
            var ring: [Walk.Point] = []
            ring.reserveCapacity(Int(points))
            for _ in 0..<points {
                guard let dLat = reader.signed(), let dLon = reader.signed() else { return nil }
                lat += dLat
                lon += dLon
                ring.append(Walk.Point(lat: Double(lat) / 1e6, lon: Double(lon) / 1e6))
            }
            rings.append(ring)
        }
        return rings
    }

    /// A traffic signal at a crosswalk or a junction (`tools/make_signals.py`), and what it does
    /// for someone crossing.
    struct Signal: Equatable {
        struct Kind: OptionSet, Equatable {
            let rawValue: Int
            /// Cars stop for a walk signal.
            static let signal = Kind(rawValue: 1)
            /// The walk signal comes on a few seconds before the cars' green (a leading
            /// pedestrian interval), so you're out in the crosswalk before anyone turns.
            static let leading = Kind(rawValue: 2)
            /// Every car stops while people cross, any way (a Barnes Dance).
            static let exclusive = Kind(rawValue: 4)
        }

        let at: Walk.Point
        let kind: Kind
    }

    /// The signals from their blob: how many, then each one's latitude and longitude changes in
    /// millionths of a degree, zigzagged varints carrying on from the one before, and its kind.
    /// Nil if it's cut short.
    static func signals(from bytes: some Collection<UInt8>) -> [Signal]? {
        var reader = Varints(bytes)
        guard let count = reader.next(), count < 10_000_000 else { return nil }
        var signals: [Signal] = []
        signals.reserveCapacity(Int(count))
        var lat: Int64 = 0, lon: Int64 = 0
        for _ in 0..<count {
            guard let dLat = reader.signed(), let dLon = reader.signed(), let kind = reader.next() else { return nil }
            lat += dLat
            lon += dLon
            signals.append(Signal(at: Walk.Point(lat: Double(lat) / 1e6, lon: Double(lon) / 1e6),
                                  kind: Signal.Kind(rawValue: Int(truncatingIfNeeded: kind))))
        }
        return signals
    }

    /// Varints one after another, as `make_sidewalks.py` writes them.
    struct Varints<Bytes: Collection<UInt8>> {
        private var iterator: Bytes.Iterator

        init(_ bytes: Bytes) { iterator = bytes.makeIterator() }

        mutating func next() -> UInt64? {
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

        /// The next, zigzagged: a signed number.
        mutating func signed() -> Int64? {
            next().map { Int64(bitPattern: ($0 >> 1) ^ (0 &- ($0 & 1))) }
        }
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
    /// Metres a sidewalk on one side alone must carry on for, over driveways and cross streets,
    /// to be blocks on that side: a street the city has none on across it, or one so wide, its
    /// malls not in the city's map, that the far side's out of `reach` (Queens Blvd). Shorter is
    /// a gap in the far side's, gone along between the blocks either side.
    static let oneSided = 60.0
    /// Degrees the way turns between blocks to count as turning a corner, not going on across.
    static let turning = 35.0
    /// Metres wide a sidewalk can be before it's a plaza, where the line keeps near the curb.
    static let plaza = 10.0
    /// Metres between blocks that are a corner to go round: longer, with no sidewalks to go
    /// by, is a park or a plaza, where Apple Maps' way through stands.
    static let corner = 30.0
    /// Metres Apple Maps' way between two blocks may stray from the street's line, or the line
    /// round the corner, and still be going over the street: further is through a park.
    static let stray = 15.0
    /// Metres between blocks too far for any crossing, however wide the street: a park.
    static let aside = 100.0
    /// Metres of a way off the sidewalks for it to be over a street, not round a curb's corner.
    static let roadway = 3.0
    /// Metres a sidewalk between blocks may be further out or in than theirs and still be the
    /// same side's, carrying on between them.
    static let lined = 1.5
    /// Degrees a way turns at a point to double back on itself.
    static let doubling = 120.0
    /// Metres out a hook goes before doubling back, at most: longer is a way really walked.
    static let hook = 6.0
    /// Share of a walk that must have sidewalks either side, or be on one already, for it to be
    /// moved onto them.
    static let enough = 0.5
    /// Metres of Apple Maps' way off the sidewalks, from one to the next, for it to be over a
    /// street: past the widest avenues, short of a park.
    static let widest = 60.0
    /// Metres of it off them, at least, to be over a street, curb to curb: the narrowest, a
    /// lane and a little; less is a corner cut, or a gap between a path's pieces.
    static let narrowest = 6.0

    /// What crossing a street costs, as metres of street: one crossing more than any street is
    /// wide, so none's added just to cross a narrower one, then its width, curb to curb.
    static let crossing = 50.0
    /// More for a street with no signal: this, and its width again, so crossing a wide one
    /// unsignalled is worse than crossing two narrow ones at signals.
    static let unsignalled = 15.0
    /// Less where the walk signal comes before the cars' green.
    static let leading = 5.0
    /// Less where every car stops while people cross.
    static let exclusive = 10.0
    /// Metres from a crossing a signal may be and still be its junction's: past the middle of
    /// a wide junction, short of the next one.
    static let signalled = 25.0
    /// More for crossing to the end's side where the walk ends, which may be the middle of the
    /// block, than for the same street at a corner, so a tie goes to the corner.
    static let midBlock = 10.0

    /// `walk` on the sidewalks in `sidewalks`, from `start` (whose side of the street it starts
    /// on) to `end` (whose side it ends on), each step's instruction kept and its path and length
    /// those on the sidewalk; where it crosses a street, in `crossings`, by the narrowest streets
    /// with `signals` where it has a choice, and each one's light. Nil `signals` where they're
    /// not known (no file of them): the lights too, rather than every one "No light". Where Apple
    /// Maps' walk is on the sidewalks already (it has Manhattan's), its way stands, crossing
    /// where it goes off one over the street to the next. Nil where too little of it has a
    /// sidewalk either side to go by, or is on one: outside the city's data, or across a park.
    static func fit(_ walk: Walk, sidewalks: [Rings], signals: [Signal]? = nil,
                    start: Walk.Point? = nil, end: Walk.Point? = nil) -> Walk? {
        // Steps with somewhere to walk; the ways down and up are a point, at the station
        let walked = walk.steps.indices.filter { walk.steps[$0].points.count >= 2 }
        guard let origin = walked.first.flatMap({ walk.steps[$0].points.first }), !sidewalks.isEmpty else { return nil }
        let plane = Plane(origin: origin)
        let edges = Edges(sidewalks.flatMap { $0.map { $0.map(plane.xy) } },
                          owners: sidewalks.indices.flatMap { index in sidewalks[index].map { _ in index } })
        let samples = Self.samples(of: walk, steps: walked, plane: plane)
        guard samples.count >= 2 else { return nil }
        let sides = samples.map { sample -> Sides in
            if edges.inside(sample.at) { return Sides(onSidewalk: true) }
            let left = edges.sidewalk(from: sample.at, along: sample.left)
            let right = edges.sidewalk(from: sample.at, along: sample.left * -1)
            return Sides(left: left?.middle, right: right?.middle,
                         road: left.flatMap { left in right.map { left.curb + $0.curb } })
        }
        let runs = Self.runs(sides, samples: samples)
        let paired = runs.reduce(0) { $0 + $1.count } + sides.filter(\.onSidewalk).count
        guard Double(paired) >= Double(samples.count) * enough else { return nil }
        let known = signals?.map { (at: plane.xy($0.at), kind: $0.kind) }
        let chosen = runs.isEmpty ? []
            : choose(runs, samples: samples, sides: sides, signals: known ?? [],
                     start: start.map(plane.xy), end: end.map(plane.xy))
        // From where you really are, and to the stairs or the door, not Apple Maps' points for
        // them, which it puts in the middle of the street
        var fitted = path(walk, walked: walked, samples: samples, sides: sides, runs: runs, chosen: chosen,
                          edges: edges, plane: plane, start: start ?? walked.first.flatMap { walk.steps[$0].points.first },
                          end: end ?? walked.last.flatMap { walk.steps[$0].points.last })
        if let known {
            fitted.lights = fitted.crossings?.map { crossing in
                let over = crossing.map(plane.xy)
                let road = zip(over, over.dropFirst()).map { roadway(from: $0, to: $1, edges: edges) }.reduce(0, +)
                return light(over: over, road: road, signals: known)
            }
        }
        fitted.addCrossingSteps()
        return fitted
    }

    /// The light at the crossing `over`, by the signals near its middle, and whether the
    /// `road` metres of it off the sidewalks, curb to curb, are wide.
    static func light(over: [V], road: Double, signals: [(at: V, kind: Signal.Kind)]) -> Walk.Light {
        guard let first = over.first, let last = over.last else { return .unsignalled }
        let there = kind(near: (first + last) * 0.5, in: signals)
        if there.contains(.exclusive) { return .exclusive }
        if there.contains(.leading) { return .leading }
        if there.contains(.signal) { return .signal }
        return road >= Walk.wideCrossing ? .unsignalledWide : .unsignalled
    }

    /// What the signals within `signalled` of `point` do, together.
    static func kind(near point: V, in signals: [(at: V, kind: Signal.Kind)]) -> Signal.Kind {
        signals.filter { ($0.at - point).length <= signalled }.reduce(Signal.Kind()) { $0.union($1.kind) }
    }

    /// Metres of the way from `a` to `b` off the sidewalks, in the street: every metre of it,
    /// not just its middle, which may be on an island in the street.
    static func roadway(from a: V, to b: V, edges: Edges) -> Double {
        let length = (b - a).length
        let count = max(Int(length.rounded(.up)), 1)
        let off = (0..<count).filter { !edges.inside(a + (b - a) * ((Double($0) + 0.5) / Double(count))) }.count
        return Double(off) * length / Double(count)
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
        /// Metres from one curb to the other: the street's width to cross.
        var road: Double?
        var onSidewalk = false

        init(left: V? = nil, right: V? = nil, road: Double? = nil, onSidewalk: Bool = false) {
            self.left = left
            self.right = right
            self.road = road
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
    /// from one to the next, `shortest` or longer; then, between them, runs with one side's
    /// along a street `oneSided` or longer. What's between them is a corner, or a piece with no
    /// sidewalk to go by.
    static func runs(_ sides: [Sides], samples: [Sample]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        func close(_ end: Int) {
            if let begun = start, end - begun >= shortest { runs.append(begun..<end) }
            start = nil
        }
        /// How far out the sidewalk's middle is either side of sample `index`.
        func out(_ index: Int) -> (left: Double, right: Double)? {
            guard let left = sides[index].left, let right = sides[index].right else { return nil }
            return ((left - samples[index].at).length, (right - samples[index].at).length)
        }
        for index in sides.indices {
            guard !sides[index].onSidewalk, let here = out(index) else {
                close(index)
                continue
            }
            if start != nil, let before = out(index - 1),
               abs(here.left - before.left) > jump || abs(here.right - before.right) > jump {
                close(index)
            }
            if start == nil { start = index }
        }
        close(sides.count)

        // Then one side's alone, where no block is: pieces `shortest` or longer, each carrying
        // on in line from the one before over a corner's worth or less (a driveway, a cross
        // street), `oneSided` or longer together; the longest first
        var taken = Set(runs.joined())
        var alone: [[Range<Int>]] = []
        /// Metres from the first piece's start to the last's end.
        func span(_ pieces: [Range<Int>]) -> Double {
            guard let first = pieces.first, let last = pieces.last else { return 0 }
            return Double(last.upperBound - first.lowerBound) * spacing
        }
        for side in Side.allCases {
            var pieces: [Range<Int>] = []
            var begun: Int?
            func end(_ index: Int) {
                if let begun, index - begun >= shortest { pieces.append(begun..<index) }
                begun = nil
            }
            for index in sides.indices {
                guard !taken.contains(index), !sides[index].onSidewalk, let point = sides[index].side(side) else {
                    end(index)
                    continue
                }
                if begun != nil, let before = sides[index - 1].side(side),
                   abs((point - samples[index].at).length - (before - samples[index - 1].at).length) > jump {
                    end(index)
                }
                if begun == nil { begun = index }
            }
            end(sides.count)
            /// How far out the sidewalk on this side is at sample `index`.
            func out(_ index: Int) -> Double { sides[index].side(side).map { ($0 - samples[index].at).length } ?? 0 }
            var joined: [[Range<Int>]] = []
            for piece in pieces {
                if let last = joined.last?.last, Double(piece.lowerBound - last.upperBound) * spacing <= corner,
                   abs(out(piece.lowerBound) - out(last.upperBound - 1)) <= jump,
                   !(last.upperBound..<piece.lowerBound).contains(where: taken.contains) {
                    joined[joined.count - 1].append(piece)
                } else {
                    joined.append([piece])
                }
            }
            alone += joined.filter { span($0) >= oneSided }
        }
        for pieces in alone.sorted(by: { span($0) > span($1) }) where !pieces.joined().contains(where: taken.contains) {
            runs += pieces
            taken.formUnion(pieces.joined())
        }
        return runs.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Which way the walk turns from the end of one block to the start of the next.
    enum Corner {
        case across, left, right

        init(from a: V, to b: V) {
            let degrees = atan2(a.cross(b), a.dot(b)) * 180 / .pi
            self = degrees > Sidewalks.turning ? .left : degrees < -Sidewalks.turning ? .right : .across
        }

        /// What the streets crossed going from `a`'s side of one block to `b`'s of the next
        /// cost, beyond any the corner makes you cross whichever side you're on, crossing the
        /// block's own street costing `this` and the next block's `next`: none round the inside
        /// of a turn, both round its outside, and only this one to change sides going across.
        func cost(_ a: Side, _ b: Side, this: Double, next: Double) -> Double {
            switch self {
            case .across: a == b ? 0 : this
            case .left: (a == .right ? this : 0) + (b == .right ? next : 0)
            case .right: (a == .left ? this : 0) + (b == .left ? next : 0)
            }
        }
    }

    /// What crossing a street `width` metres wide costs, with `signal` there.
    static func cost(width: Double, signal: Signal.Kind) -> Double {
        var cost = crossing + width
        if !signal.contains(.signal) { cost += unsignalled + width }
        if signal.contains(.exclusive) {
            cost -= exclusive
        } else if signal.contains(.leading) {
            cost -= leading
        }
        return cost
    }

    /// Which side of the street `point` is at `sample`; nil in the street, or too far off to say.
    static func side(of point: V?, at sample: Sample) -> Side? {
        guard let point else { return nil }
        let lateral = sample.direction.cross(point - sample.at)
        guard abs(lateral) > 3, (point - sample.at).length < 80 else { return nil }
        return lateral > 0 ? .left : .right
    }

    /// Each block's side: the fewest streets crossed, starting on `start`'s side of the first
    /// block, where it's clearly on one, as getting to the other would be across the middle of
    /// it. Ending on `end`'s side of the last is one street fewer, crossed where the walk ends,
    /// a little worse than at a corner (`midBlock`). Of ways crossing as many, the one over the
    /// narrowest streets, at `signals` (in the plane).
    static func choose(_ runs: [Range<Int>], samples: [Sample], sides: [Sides],
                       signals: [(at: V, kind: Signal.Kind)] = [], start: V?, end: V?) -> [Side] {
        let first = side(of: start, at: samples[runs[0].lowerBound])
        let last = side(of: end, at: samples[runs[runs.count - 1].upperBound - 1])
        let impossible = 1e9
        /// What crossing the street at sample `index` costs: its width there, and the signals
        /// near it.
        func street(_ index: Int) -> Double {
            Self.cost(width: sides[index].road ?? 0, signal: kind(near: samples[index].at, in: signals))
        }
        /// What being on `side` of block `index` costs beyond its streets: nothing, or, where
        /// it's a sidewalk on the other side alone, more even than starting on the wrong side.
        func open(_ index: Int, _ side: Side) -> Double {
            runs[index].allSatisfy { sides[$0].side(side) != nil } ? 0 : impossible * 2
        }
        // The least cost to each side of each block, and the side of the block before
        var cost: [[Double]] = [Side.allCases.map { (first == nil || first == $0 ? 0 : impossible) + open(0, $0) }]
        var from: [[Side]] = [[.left, .right]]
        for index in runs.indices.dropFirst() {
            let ending = runs[index - 1].upperBound - 1, starting = runs[index].lowerBound
            let corner = Corner(from: samples[ending].direction, to: samples[starting].direction)
            let this = street(ending), next = street(starting)
            var row: [Double] = []
            var back: [Side] = []
            for side in Side.allCases {
                let best = Side.allCases.min {
                    cost[index - 1][$0.rawValue] + corner.cost($0, side, this: this, next: next)
                        < cost[index - 1][$1.rawValue] + corner.cost($1, side, this: this, next: next)
                } ?? .left
                row.append(cost[index - 1][best.rawValue] + corner.cost(best, side, this: this, next: next) + open(index, side))
                back.append(best)
            }
            cost.append(row)
            from.append(back)
        }
        if let last {
            cost[cost.count - 1][last.other.rawValue] += street(runs[runs.count - 1].upperBound - 1) + midBlock
        }
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
        /// In the street, rather than on a sidewalk: the way from `a` to `b` crosses one, by how
        /// much of it is off the sidewalks.
        func crosses(_ a: V, _ b: V) -> Bool {
            Self.roadway(from: a, to: b, edges: edges) > roadway
        }
        /// From one block to the next, over a street only with `narrowest` of it or more off the
        /// sidewalks: less is a driveway the city's sidewalk stops for, or a corner cut.
        func overStreet(_ a: V, _ b: V) -> Bool {
            Self.roadway(from: a, to: b, edges: edges) >= narrowest
        }

        /// Apple Maps' own way through samples `range`, where there are no sidewalks to go by:
        /// across a park or a plaza, along a street the city has none on, or on a sidewalk
        /// already. Over a street where it goes off one sidewalk and onto another `widest` or
        /// less on, `narrowest` of it or more off them.
        func apple(_ range: Range<Int>) {
            // Samples since the last on a sidewalk, if there's been one
            var off: [Int] = []
            var leftOne = range.lowerBound > 0 && sides[range.lowerBound - 1].onSidewalk
            for index in range {
                guard sides[index].onSidewalk else {
                    off.append(index)
                    continue
                }
                // Onto another sidewalk: not round the corner of the same one, or a path's
                let over = leftOne && !off.isEmpty && Double(off.count + 1) * spacing <= widest && {
                    let way = ([off[0] - 1] + off + [index]).map { samples[$0].at }
                    return zip(way, way.dropFirst()).map { Self.roadway(from: $0, to: $1, edges: edges) }.reduce(0, +) >= narrowest
                        && edges.sidewalk(at: samples[off[0] - 1].at) != edges.sidewalk(at: samples[index].at)
                }()
                // Straight over, one crossing, however Apple Maps' way bends in the street
                if !over {
                    for skipped in off { add(samples[skipped].at, step: samples[skipped].step) }
                }
                add(samples[index].at, step: samples[index].step, crossing: over)
                off = []
                leftOne = true
            }
            for skipped in off { add(samples[skipped].at, step: samples[skipped].step) }
        }
        /// Whether samples `range` are more than a corner's worth to go round.
        func long(_ range: Range<Int>) -> Bool { Double(range.count) * spacing > corner }
        /// Whether Apple Maps' way through `gap`, between two blocks, goes off through a park or
        /// a plaza rather than over the street or round the corner between them: it strays from
        /// the street's line, or the one round the corner, or is longer than any crossing.
        /// Wide avenues and islands in the street make a long gap at a corner, but Apple Maps'
        /// way over it keeps to the street's line.
        func offTheStreet(_ gap: Range<Int>) -> Bool {
            guard let first = gap.first, let last = gap.last else { return false }
            if Double(gap.count) * spacing > aside { return true }
            let a = samples[max(first - 1, 0)], b = samples[min(last + 1, samples.count - 1)]
            var line = [a.at]
            if Corner(from: a.direction, to: b.direction) != .across,
               let turn = meeting(a.at, a.direction, b.at, b.direction) {
                line.append(turn)
            }
            line.append(b.at)
            return gap.contains { index in
                zip(line, line.dropFirst()).map { distance(from: samples[index].at, to: $0, $1) }.min() ?? 0 > stray
            }
        }

        if let start { add(plane.xy(start), step: samples[0].step) }
        if runs.isEmpty {
            // On the sidewalks already all the way
            apple(0..<samples.count)
            if let end { add(plane.xy(end), step: samples[samples.count - 1].step) }
        }
        if let first = runs.first, long(0..<first.lowerBound) { apple(0..<first.lowerBound) }
        for (index, run) in runs.enumerated() {
            let side = chosen[index]
            let points = Self.smoothed(run.compactMap { sides[$0].side(side) })
            if index > 0 {
                let previous = runs[index - 1], before = chosen[index - 1]
                let endSample = samples[previous.upperBound - 1], startSample = samples[run.lowerBound]
                guard let from = out.last?.at, let to = points.first else { continue }
                let gap = previous.upperBound..<run.lowerBound
                let between = gap.filter { sides[$0].onSidewalk }
                let throughPark = (long(gap) || between.count >= shortest) && offTheStreet(gap)
                var alongside = false
                if throughPark {
                    apple(gap)
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
                        // On along this side to the next block, wherever its sidewalk lines
                        // up with theirs: a stretch with none to go by on the other side, rather
                        // than a line cut through the street
                        /// Whether sample `index`'s sidewalk on `side` lines up with the blocks'.
                        func lines(_ index: Int, _ side: Side) -> Bool {
                            guard let point = sides[index].side(side) else { return false }
                            return [previous.upperBound - 1, run.lowerBound].contains { block in
                                sides[block].side(side).map {
                                    abs((point - samples[index].at).length - ($0 - samples[block].at).length) <= lined
                                } ?? false
                            }
                        }
                        // Longer than a corner, with the other side's sidewalk carrying on beside
                        // nearly all of it, there's no street to cross, just none on this side in
                        // the city's map. (Islands down an avenue's middle carry on over a corner.)
                        alongside = long(gap) && gap.filter { lines($0, side.other) }.count * 4 >= gap.count * 3
                        for index in gap where lines(index, side) {
                            guard let point = sides[index].side(side), let last = out.last?.at else { continue }
                            add(point, step: samples[index].step, crossing: !alongside && overStreet(last, point))
                        }
                    }
                }
                if let last = out.last?.at {
                    // Off a park's path onto the block: across the street only if the block's
                    // side is the other one; the ground between isn't sidewalk, but nor's it street
                    let across = throughPark ? Self.side(of: last, at: startSample).map { $0 != side } ?? false
                        : !alongside && overStreet(last, to)
                    add(to, step: startSample.step, crossing: across)
                }
            }
            for (offset, point) in points.enumerated() {
                add(point, step: samples[run.lowerBound + offset].step)
            }
        }
        if let last = runs.last, long(last.upperBound..<samples.count) {
            apple(last.upperBound..<samples.count)
            if let end { add(plane.xy(end), step: samples[samples.count - 1].step) }
        } else if let end, let last = runs.last, let lastSide = chosen.last {
            // Over the street straight across at the last block's end, if the end's on its
            // other side, not on a slant through the junction; then on to the end, over any
            // street between
            let point = plane.xy(end), lastSample = samples[last.upperBound - 1]
            let step = samples[samples.count - 1].step
            let otherSide = side(of: point, at: lastSample).map { $0 != lastSide } ?? false
            var crossed = false
            if otherSide, let from = out.last?.at, let over = sides[last.upperBound - 1].side(lastSide.other) {
                add(over, step: step, crossing: crosses(from, over))
                crossed = true
            }
            if let from = out.last?.at {
                // Over a street on the way, where the end's on a sidewalk to tell by; one off
                // them (a door in a building's outline, Apple Maps' point in the street) is
                // only across if it's on the other side and not crossed to yet
                let over = edges.inside(point) ? crosses(from, point) : otherSide && !crossed
                add(point, step: step, crossing: over)
            }
        }

        // No hooks back on itself, where a block's end runs on past its corner, or the corner's
        // a little behind it: each a short way out and back, the way to the point after crossing
        // a street if either part of it did
        var index = 1
        while index < out.count - 1 {
            let into = out[index].at - out[index - 1].at, onFrom = out[index + 1].at - out[index].at
            let degrees = abs(atan2(into.cross(onFrom), into.dot(onFrom))) * 180 / .pi
            if degrees > Self.doubling, min(into.length, onFrom.length) < Self.hook {
                out[index + 1].crossing = out[index + 1].crossing || out[index].crossing
                out.remove(at: index)
                index = max(index - 1, 1)
            } else {
                index += 1
            }
        }

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
            // One crossing for each street: a new one where the way over turns, round the
            // outside of a corner, so each has its own street's name
            let straightOn = index > 1 && out[index - 1].crossing
                && Corner(from: out[index - 1].at - out[index - 2].at, to: out[index].at - out[index - 1].at) == .across
            if straightOn, let last = crossings.last?.last, last == from {
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

    /// Metres from `p` to the nearest point between `a` and `b`.
    static func distance(from p: V, to a: V, _ b: V) -> Double {
        let ab = b - a
        let squared = ab.dot(ab)
        guard squared > 1e-9 else { return (p - a).length }
        let t = min(max((p - a).dot(ab) / squared, 0), 1)
        return (p - (a + ab * t)).length
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
        let north = Earth.metresPerDegree

        init(origin: Walk.Point) {
            self.origin = origin
            east = Earth.metresPerDegree * cos(origin.lat * .pi / 180)
        }

        func xy(_ point: Walk.Point) -> V { V(x: (point.lon - origin.lon) * east, y: (point.lat - origin.lat) * north) }
        func point(_ v: V) -> Walk.Point { Walk.Point(lat: origin.lat + v.y / north, lon: origin.lon + v.x / east) }
    }

    /// The sidewalks' edges, curbs and building lines alike, in a grid to find those near a line.
    struct Edges {
        private var segments: [(V, V)] = []
        /// The sidewalk each segment's ring is one of, where they were given.
        private var owner: [Int] = []
        private var cells: [Cell: [Int]] = [:]
        /// As far east as any edge reaches, for `inside`'s ray to go out past them all.
        private var east = -Double.infinity
        private static let size = 10.0

        private struct Cell: Hashable {
            let x: Int
            let y: Int
        }

        /// `owners`: the sidewalk each of `rings` is one of, for `sidewalk(at:)`.
        init(_ rings: [[V]], owners: [Int]? = nil) {
            for (ringIndex, ring) in rings.enumerated() {
                for (a, b) in zip(ring, ring.dropFirst()) where a != b {
                    let index = segments.count
                    segments.append((a, b))
                    owner.append(owners?[ringIndex] ?? 0)
                    east = max(east, a.x, b.x)
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

        /// Whether `p` is on a sidewalk: an odd number of edges to its east, out past them all,
        /// however far the sidewalks loaded go. An edge counts if one end's north of `p` and the
        /// other isn't, so a corner exactly level with `p` counts once where the ring goes on
        /// past it, and not at all where it turns back.
        func inside(_ p: V) -> Bool {
            var count = 0
            east(of: p) { _ in count += 1 }
            return count % 2 == 1
        }

        /// Which sidewalk `p` is on, by the owners given: the one with an odd number of its
        /// edges to its east. Nil off them.
        func sidewalk(at p: V) -> Int? {
            var counts: [Int: Int] = [:]
            east(of: p) { counts[owner[$0], default: 0] += 1 }
            return counts.filter { $0.value % 2 == 1 }.keys.min()
        }

        /// Each edge `inside` counts for `p`, by its index.
        private func east(of p: V, _ body: (Int) -> Void) {
            guard p.x <= east else { return }
            var seen = Set<Int>()
            for cell in Self.cells(from: p, to: V(x: east, y: p.y)) {
                for index in cells[cell] ?? [] where seen.insert(index).inserted {
                    let (a, b) = segments[index]
                    guard (a.y > p.y) != (b.y > p.y) else { continue }
                    if a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x) > p.x { body(index) }
                }
            }
        }

        /// The middle of the first sidewalk from `p` going `direction`, within `reach`, near its
        /// curb where it's wider than a sidewalk is; and metres to its curb.
        func sidewalk(from p: V, along direction: V) -> (middle: V, curb: Double)? {
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
            return (p + direction * (enter + into), enter)
        }
    }
}
