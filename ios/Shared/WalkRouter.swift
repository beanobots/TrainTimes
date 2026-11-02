import Foundation

/// How much longer a walk may be to be safer: Fastest only keeps off ramps and highways,
/// Safest goes well out of its way for lights and narrow streets.
enum WalkPreference: String, Codable, CaseIterable, Sendable {
    case fastest, balanced, safest
}

/// What walking and crossing cost, in seconds: the time it takes, and its risk, weighted by
/// the preference. A crossing's risk grows with the street's width, lanes, traffic both ways,
/// speed and trucks; doubles without a light; shrinks with a walk signal first, or every car
/// stopped. Ramps onto highways cost most of all.
enum WalkCosts {
    /// Metres a second.
    static let pace = 1.33
    /// Seconds for a turn onto another street, so a route doesn't zigzag through the grid.
    static let turn = 3.0
    /// Degrees a way turns before it's a turn.
    static let turning = 30.0

    // A crossing, per carriageway crossed
    static let perMetreWide = 0.8
    static let perExtraLane = 3.0
    static let twoWay = 4.0
    static let truckLocal = 6.0
    static let truckThrough = 12.0
    static let bikeLane = 1.0
    /// For a crossing with no light: its risk this many times, plus `unsignalledExtra`, plus
    /// `unsignalledWideExtra` where it's wide or three lanes or more.
    static let unsignalledTimes = 2.0
    static let unsignalledExtra = 10.0
    static let unsignalledWideExtra = 25.0
    /// Metres curb to curb from which a street's wide.
    static let wide = 15.0
    static let leadingTimes = 0.8
    static let exclusiveTimes = 0.6
    /// A highway or ramp crossed at grade, on top of its risk.
    static let rampSignalled = 60.0
    static let rampUnsignalled = 240.0
    /// Every crossing, whatever the street: half at each end that's a sidewalk, so crossing a
    /// divided road through its median pays it once.
    static let fixed = 6.0
    /// Less for each carriageway crossed from or to a median.
    static let refugeShare = 0.8
    /// A corner off any sidewalk or median, crossed through.
    static let noCorner = 15.0
    /// The wait at a light, on average (in the cost, not the walk's time).
    static let signalWait = 8.0
    /// Metres curb to curb assumed where the city doesn't say.
    static let unknownWidth = 10.0

    /// Speed in miles per hour: risk per crossing, and per 100 m walked beside it.
    static func speed(_ mph: Int) -> (crossing: Double, beside: Double) {
        switch mph {
        case 40...: (30, 20)
        case 35...: (15, 10)
        case 30...: (6, 4)
        default: (0, 0)
        }
    }

    // Walking beside traffic, per 100 m
    static let besideTraffic = 2.0
    static let besideTruckRoute = 5.0
    static let besideManyLanes = 3.0
    static let underElevated = 15.0
    static let noSidewalk = 60.0
    static let alley = 10.0
    /// Steps take this much longer than the flat.
    static let stepsTimes = 1.5

    /// How much risk counts against time, by preference.
    static func weight(_ preference: WalkPreference) -> Double {
        switch preference {
        case .fastest: 0.2
        case .balanced: 1.0
        case .safest: 2.5
        }
    }

    /// The most a preference's walk may take, against the fastest: seconds.
    static func budget(_ preference: WalkPreference, fastest: Double) -> Double {
        switch preference {
        case .fastest: fastest
        case .balanced: fastest * 1.12 + 45
        case .safest: fastest * 1.30 + 120
        }
    }
}

/// Walks routed on the city's walking graph (`WalkGraph`): the streets, the side of each and
/// where to cross, together, for the least time and risk (`WalkCosts`). A search goes from
/// corner to corner: along a street's side to the corner at its other end, or over a street
/// to the corner across it.
final class WalkRouter {
    let graph: WalkGraph

    /// Each junction and corner in metres east and north of `origin`.
    private let nodeX: [Float], nodeY: [Float]
    private let cornerX: [Float], cornerY: [Float]
    /// Each arm's bearing out of its junction, over its block's first 10 m.
    private let armBearing: [Float]
    /// Walkable blocks by the 100 m cells their lines pass.
    private var cells: [Cell: [Int32]] = [:]
    private static let cellSize = 100.0
    private static let origin = Walk.Point(lat: 40.7, lon: -74.0)

    private struct Cell: Hashable {
        let x: Int32, y: Int32
    }

    // The search's scratch, reused: by state (corner × how it was come to)
    private var cost: [Float] = []
    private var parent: [Int32] = []
    private var stamp: [UInt32] = []
    private var generation: UInt32 = 0

    init(graph: WalkGraph) {
        self.graph = graph
        func plane(_ p: Walk.Point) -> (Float, Float) {
            (Float((p.lon - Self.origin.lon) * WalkGraph.metresEast), Float((p.lat - Self.origin.lat) * WalkGraph.metresNorth))
        }
        var nx = [Float](), ny = [Float]()
        nx.reserveCapacity(graph.nodeCount)
        ny.reserveCapacity(graph.nodeCount)
        for node in 0..<graph.nodeCount {
            let (x, y) = plane(graph.point(ofNode: node))
            nx.append(x)
            ny.append(y)
        }
        var cx = [Float](), cy = [Float](), bearings = [Float]()
        cx.reserveCapacity(graph.armBlock.count)
        cy.reserveCapacity(graph.armBlock.count)
        bearings.reserveCapacity(graph.armBlock.count)
        for arm in 0..<graph.armBlock.count {
            let node = graph.node(ofArm: arm)
            cx.append(nx[node] + Float(graph.cornerDX[arm]) / 10)
            cy.append(ny[node] + Float(graph.cornerDY[arm]) / 10)
            let block = Int(graph.armBlock[arm])
            var line = graph.line(of: block)
            if graph.armEnd[arm] == 1 { line.reverse() }
            bearings.append(Float(Self.bearing(along: line, reach: 10)))
        }
        nodeX = nx
        nodeY = ny
        cornerX = cx
        cornerY = cy
        armBearing = bearings
        for block in 0..<graph.blockCount where graph.class(of: block) != .arm {
            let line = graph.line(of: block).map(plane)
            var seen = Set<Cell>()
            for (a, b) in zip(line, line.dropFirst()) {
                for cell in Self.cells(from: a, to: b) where seen.insert(cell).inserted {
                    cells[cell, default: []].append(Int32(block))
                }
            }
        }
    }

    private static func cells(from a: (Float, Float), to b: (Float, Float), pad: Double = 0) -> [Cell] {
        let s = cellSize
        let x0 = Int32((Double(min(a.0, b.0)) - pad) / s), x1 = Int32((Double(max(a.0, b.0)) + pad) / s)
        let y0 = Int32((Double(min(a.1, b.1)) - pad) / s), y1 = Int32((Double(max(a.1, b.1)) + pad) / s)
        return (x0...x1).flatMap { x in (y0...y1).map { Cell(x: x, y: $0) } }
    }

    /// Degrees clockwise from north a line leaves its first point by, over `reach` metres.
    static func bearing(along line: [Walk.Point], reach: Double) -> Double {
        guard let first = line.first else { return 0 }
        var travelled = 0.0
        for (a, b) in zip(line, line.dropFirst()) {
            let piece = a.metres(to: b)
            if travelled + piece >= reach || b == line.last {
                return first.heading(to: b)
            }
            travelled += piece
        }
        return 0
    }

    // MARK: Options and results

    struct Options: Hashable, Sendable {
        var preference: WalkPreference = .balanced
        /// No steps or step streets.
        var stepFree = false
    }

    /// One piece of a route.
    enum Leg: Equatable, Sendable {
        /// From the start onto a side of a block, or from one onto the end.
        case access(Walk.Point, Walk.Point)
        /// Along a block's side between two corners (or a start or end part way along).
        case side(block: Int, left: Bool, from: Walk.Point, to: Walk.Point, fromAlong: Double, toAlong: Double)
        /// Over a block's arm at a junction, from one corner to the next.
        case cross(node: Int, arm: Int, from: Walk.Point, to: Walk.Point)
    }

    struct Stats: Sendable {
        var seconds = 0.0
        var metres = 0.0
        var risk = 0.0
        var crossings = 0
        var unsignalled = 0
        var unsignalledWide = 0
        var ramps = 0
        /// The safety weight the route was found with: the preference's, or less to keep in budget.
        var weight = 0.0
        /// The fastest route's seconds, for the budget.
        var fastestSeconds = 0.0
    }

    struct Route: Sendable {
        let legs: [Leg]
        let stats: Stats
    }

    // MARK: Routing

    /// The route from `start` to `end` for `options`, kept within its preference's budget of
    /// the fastest route's time. Nil where either's off the graph, or they aren't joined.
    func route(from start: Walk.Point, to end: Walk.Point, options: Options = Options()) -> Route? {
        guard let fastest = search(from: start, to: end, weight: WalkCosts.weight(.fastest), floors: true, options: options)
        else { return nil }
        if options.preference == .fastest { return finish(fastest, fastestSeconds: fastest.stats.seconds) }
        let budget = WalkCosts.budget(options.preference, fastest: fastest.stats.seconds)
        var weight = WalkCosts.weight(options.preference)
        for _ in 0..<4 {
            if let route = search(from: start, to: end, weight: weight, floors: true, options: options),
               route.stats.seconds <= budget {
                return finish(route, fastestSeconds: fastest.stats.seconds)
            }
            weight /= 2
        }
        return finish(fastest, fastestSeconds: fastest.stats.seconds)
    }

    private func finish(_ route: Route, fastestSeconds: Double) -> Route {
        var stats = route.stats
        stats.fastestSeconds = fastestSeconds
        return Route(legs: route.legs, stats: stats)
    }

    /// A place a route can start or end: on a block's side, `along` metres from its start,
    /// `off` metres from that side's line.
    struct Snap {
        let block: Int
        let left: Bool
        let along: Double
        let off: Double
        let point: Walk.Point
    }

    /// The walkable blocks' sides near `point`, nearest first: on its side of each street (both
    /// where it's in the middle of one), within 60 m, or 150 m of a path.
    func snaps(near point: Walk.Point, limit: Int = 4) -> [Snap] {
        let p = (Float((point.lon - Self.origin.lon) * WalkGraph.metresEast), Float((point.lat - Self.origin.lat) * WalkGraph.metresNorth))
        var found: [(Double, Snap)] = []
        var seen = Set<Int32>()
        for cell in Self.cells(from: p, to: p, pad: 150) {
            for block in cells[cell] ?? [] where seen.insert(block).inserted {
                let b = Int(block)
                guard let nearest = nearestOnLine(of: b, to: point) else { continue }
                let isPath = graph.class(of: b) == .path
                guard nearest.off <= (isPath ? 150 : 60) else { continue }
                let width = max(graph.width(of: b), 4)
                let sides: [Bool] = isPath ? [true] : abs(nearest.lateral) < min(width / 2 - 1, 2) ? [true, false] : [nearest.lateral > 0]
                for left in sides {
                    let lineOffset = isPath ? 0 : sideOffset(block: b, left: left)
                    let off = isPath ? nearest.off : abs((left ? 1 : -1) * nearest.lateral - lineOffset)
                    found.append((off + (isPath ? 5 : 0), Snap(block: b, left: left, along: nearest.along, off: off, point: point)))
                }
            }
        }
        // Keep to the walkable part most of them are in
        let ranked = found.sorted { $0.0 < $1.0 }.map(\.1)
        return Array(ranked.prefix(limit))
    }

    /// The nearest point on a block's line: metres along it, metres off it, and how far to its
    /// left (positive) or right.
    private func nearestOnLine(of block: Int, to point: Walk.Point) -> (along: Double, off: Double, lateral: Double)? {
        let line = graph.line(of: block)
        guard line.count >= 2 else { return nil }
        var best: (along: Double, off: Double, lateral: Double)?
        var travelled = 0.0
        for (a, b) in zip(line, line.dropFirst()) {
            let (dx, dy) = b.offset(from: a), (px, py) = point.offset(from: a)
            let length2 = dx * dx + dy * dy
            let t = length2 > 0 ? min(1, max(0, (px * dx + py * dy) / length2)) : 0
            let ex = px - t * dx, ey = py - t * dy
            let off = (ex * ex + ey * ey).squareRoot()
            let piece = length2.squareRoot()
            if best.map({ off < $0.off }) ?? true {
                let lateral = piece > 0 ? (dx * py - dy * px) / piece : 0
                best = (travelled + t * piece, off, lateral)
            }
            travelled += piece
        }
        return best
    }

    /// Metres from a street's line its side's way keeps: the sidewalk's middle, or its curb.
    func sideOffset(block: Int, left: Bool) -> Double {
        let baked = graph.offset(of: block, left: left)
        return baked > 0 ? baked : max(graph.width(of: block) / 2, 2)
    }

    // MARK: The search

    /// A move from a state: walking along a corner's own arm or the next, or crossing either.
    private enum Move: UInt8 {
        case alongOwn, alongNext, crossOwn, crossNext, start
    }

    private struct Entry: Comparable {
        let f: Float
        let state: Int32
        static func < (a: Entry, b: Entry) -> Bool { a.f < b.f }
    }

    private func search(from start: Walk.Point, to end: Walk.Point, weight: Double, floors: Bool, options: Options) -> Route? {
        let starts = snaps(near: start), ends = snaps(near: end)
        guard let first = starts.first else { return nil }
        // Both ends in the same walkable part: the first start's
        let part = graph.nodePart[Int(graph.blockA[first.block])]
        let sources = starts.filter { graph.nodePart[Int(graph.blockA[$0.block])] == part }
        let targets = ends.filter { graph.nodePart[Int(graph.blockA[$0.block])] == part }
        guard !sources.isEmpty, !targets.isEmpty else { return nil }

        let states = graph.armBlock.count * 3
        if cost.count != states {
            cost = [Float](repeating: .infinity, count: states)
            parent = [Int32](repeating: -1, count: states)
            stamp = [UInt32](repeating: 0, count: states)
            generation = 0
        }
        generation &+= 1
        if generation == 0 {
            stamp = [UInt32](repeating: 0, count: states)
            generation = 1
        }
        var moves = [Int32: Move]()
        var heap = Heap<Entry>()
        let endXY = (Float((end.lon - Self.origin.lon) * WalkGraph.metresEast), Float((end.lat - Self.origin.lat) * WalkGraph.metresNorth))
        func h(_ corner: Int) -> Float {
            let dx = cornerX[corner] - endXY.0, dy = cornerY[corner] - endXY.1
            return (dx * dx + dy * dy).squareRoot() / Float(WalkCosts.pace) * 0.9
        }
        func relax(_ state: Int, _ value: Double, from previous: Int32, _ move: Move) {
            let v = Float(value)
            if stamp[state] != generation || v < cost[state] {
                stamp[state] = generation
                cost[state] = v
                parent[state] = previous
                moves[Int32(state)] = move
                heap.push(Entry(f: v + h(state / 3), state: Int32(state)))
            }
        }

        // Onto each start's side, to the corner at either end
        var startCost: [Int: (Double, Snap)] = [:]
        for snap in sources {
            let access = snap.off / WalkCosts.pace
            let length = graph.length(of: snap.block)
            let (from, to) = graph.sideCorners(of: snap.block, left: snap.left)
            let perMetre = sideCost(block: snap.block, left: snap.left, weight: weight, floors: floors, options: options) / max(length, 1)
            guard perMetre.isFinite else { continue }
            // Toward its end: arriving along its arm there; back toward its start, likewise
            let toState = to * 3 + (snap.left ? 0 : 1), fromState = from * 3 + (snap.left ? 1 : 0)
            let toCost = access + perMetre * (length - snap.along), fromCost = access + perMetre * snap.along
            if toCost < (startCost[toState]?.0 ?? .infinity) { startCost[toState] = (toCost, snap) }
            if fromCost < (startCost[fromState]?.0 ?? .infinity) { startCost[fromState] = (fromCost, snap) }
        }
        for (state, (value, _)) in startCost { relax(state, value, from: -1, .start) }

        // Off each end's side, from the corner at either end
        var exits: [Int: [(Double, Snap)]] = [:]
        for snap in targets {
            let access = snap.off / WalkCosts.pace
            let length = graph.length(of: snap.block)
            let (from, to) = graph.sideCorners(of: snap.block, left: snap.left)
            let perMetre = sideCost(block: snap.block, left: snap.left, weight: weight, floors: floors, options: options) / max(length, 1)
            guard perMetre.isFinite else { continue }
            exits[from, default: []].append((access + perMetre * snap.along, snap))
            exits[to, default: []].append((access + perMetre * (length - snap.along), snap))
        }
        // The same side as a start: straight along it
        var best: (cost: Double, state: Int32, exit: Snap, direct: Snap?)?
        for source in sources {
            for target in targets where target.block == source.block && target.left == source.left {
                let length = graph.length(of: source.block)
                let perMetre = sideCost(block: source.block, left: source.left, weight: weight, floors: floors, options: options) / max(length, 1)
                let value = (source.off + target.off) / WalkCosts.pace + perMetre * abs(target.along - source.along)
                if value < (best?.cost ?? .infinity) { best = (value, -1, target, source) }
            }
        }

        while let entry = heap.pop() {
            let state = Int(entry.state)
            guard stamp[state] == generation, entry.f <= cost[state] + h(state / 3) + 0.001 else { continue }
            if let best, Double(entry.f) >= best.cost { break }
            let g = Double(cost[state])
            let corner = state / 3, came = state % 3
            if let out = exits[corner] {
                for (exitCost, snap) in out where g + exitCost < (best?.cost ?? .infinity) {
                    best = (g + exitCost, Int32(state), snap, nil)
                }
            }
            let node = graph.node(ofArm: corner)
            let own = corner, next = graph.next(corner, at: node)
            let degree = graph.arms(of: node).count
            // Along the corner's own arm's side, and the next arm's
            for (arm, move) in [(own, Move.alongOwn), (next, Move.alongNext)] {
                // Not straight back the way it came
                if (came == 0 && move == .alongOwn) || (came == 1 && move == .alongNext) { continue }
                let block = Int(graph.armBlock[arm])
                guard graph.class(of: block) != .arm else { continue }
                let end = Int(graph.armEnd[arm])
                // Going out along this arm, the corner is on its right (own) or left (next)
                let leftOfBlock = (move == .alongOwn) == (end == 1)
                let (from, to) = graph.sideCorners(of: block, left: leftOfBlock)
                let destination = end == 0 ? to : from
                let arrive = move == .alongOwn ? 1 : 0
                var step = sideCost(block: block, left: leftOfBlock, weight: weight, floors: floors, options: options)
                guard step.isFinite else { continue }
                if came < 2 {
                    let into = came == 0 ? own : next
                    step += turnCost(into: into, outOf: arm)
                }
                relax(destination * 3 + arrive, g + step, from: Int32(state), move)
            }
            // Over either arm, at a junction (or a signalled crosswalk mid-block)
            guard degree >= 3 || (degree == 2 && graph.nodeSignal[node] != 0) else { continue }
            for (arm, move) in [(own, Move.crossOwn), (next, Move.crossNext)] {
                let destination = move == .crossOwn ? graph.previous(own, at: node) : next
                guard destination != corner,
                      let step = crossCost(node: node, arm: arm, from: corner, to: destination, weight: weight, floors: floors)
                else { continue }
                relax(destination * 3 + 2, g + step, from: Int32(state), move)
            }
        }
        guard let best else { return nil }
        return reconstruct(best: best, sources: startCost, weight: weight, floors: floors, options: options, start: start, end: end)
    }

    /// The turn penalty for coming into a junction along `into`'s street and leaving along `arm`'s.
    private func turnCost(into: Int, outOf arm: Int) -> Double {
        let a = Int(graph.armBlock[into]), b = Int(graph.armBlock[arm])
        guard graph.name(of: a) != graph.name(of: b) || graph.name(of: a).isEmpty else { return 0 }
        let came = (Double(armBearing[into]) + 180).truncatingRemainder(dividingBy: 360)
        let degrees = abs((Double(armBearing[arm]) - came + 540).truncatingRemainder(dividingBy: 360) - 180)
        return degrees > WalkCosts.turning ? WalkCosts.turn : 0
    }

    /// Walking a block's side, end to end: its time, and its risk per 100 m weighted.
    /// Infinite where it can't be walked.
    func sideCost(block: Int, left: Bool, weight: Double, floors: Bool, options: Options) -> Double {
        let flags = graph.flags(of: block)
        if options.stepFree && flags.contains(.steps) { return .infinity }
        let metres = graph.length(of: block)
        var seconds = metres / WalkCosts.pace
        if flags.contains(.steps) { seconds *= WalkCosts.stepsTimes }
        guard graph.class(of: block) == .walk else { return seconds }
        var risk = WalkCosts.besideTraffic
        if flags.contains(.truckLocal) || flags.contains(.truckThrough) { risk += WalkCosts.besideTruckRoute }
        risk += WalkCosts.speed(Int(graph.blockSpeed[block])).beside
        if graph.blockLanes[block] >= 4 { risk += WalkCosts.besideManyLanes }
        if flags.contains(.underElevated) { risk += WalkCosts.underElevated }
        if flags.contains(.alley) { risk += WalkCosts.alley }
        // The bit of street through a median is the crosswalk, not a sidewalk
        if graph.offset(of: block, left: left) == 0 && !flags.contains(.median) { risk += WalkCosts.noSidewalk }
        return seconds + weight * risk * metres / 100
    }

    /// Crossing an arm at a junction, from one corner to the next: its time and weighted
    /// risk. Nil where there's nothing to cross (a path, a driveway) costs nothing.
    func crossCost(node: Int, arm: Int, from: Int, to: Int, weight: Double, floors: Bool) -> Double? {
        let block = Int(graph.armBlock[arm])
        let flags = graph.flags(of: block)
        let rw = graph.blockRW[block]
        switch graph.class(of: block) {
        case .path:
            return 0.5
        case .arm where rw == 8 || rw == 13:
            // A driveway, a U-turn through a median
            return 2
        default:
            break
        }
        let width = graph.width(of: block) > 0 ? graph.width(of: block) : WalkCosts.unknownWidth
        let lanes = Int(graph.blockLanes[block])
        let signal = Sidewalks.Signal.Kind(rawValue: Int(graph.nodeSignal[node]))
        var risk = WalkCosts.perMetreWide * width + WalkCosts.perExtraLane * Double(max(0, lanes - 1))
        if !flags.contains(.oneWay) && graph.class(of: block) == .walk { risk += WalkCosts.twoWay }
        risk += WalkCosts.speed(Int(graph.blockSpeed[block])).crossing
        if flags.contains(.truckThrough) { risk += WalkCosts.truckThrough } else if flags.contains(.truckLocal) { risk += WalkCosts.truckLocal }
        if flags.contains(.bikeLane) { risk += WalkCosts.bikeLane }
        let isWide = width >= WalkCosts.wide || lanes >= 3
        var floor = 0.0
        if !signal.contains(.signal) {
            risk = risk * WalkCosts.unsignalledTimes + WalkCosts.unsignalledExtra
            if isWide {
                risk += WalkCosts.unsignalledWideExtra
                if floors { floor += WalkCosts.unsignalledWideExtra * 0.5 }
            }
        } else if signal.contains(.exclusive) {
            risk *= WalkCosts.exclusiveTimes
        } else if signal.contains(.leading) {
            risk *= WalkCosts.leadingTimes
        }
        if graph.class(of: block) == .arm {
            let ramp = signal.contains(.signal) ? WalkCosts.rampSignalled : WalkCosts.rampUnsignalled
            risk += ramp
            if floors { floor += ramp }
        }
        // Medians either end: a refuge halfway, and the crossing's fixed cost paid once
        let fromKind = graph.kind(ofCorner: from), toKind = graph.kind(ofCorner: to)
        if fromKind == .refuge || toKind == .refuge { risk *= WalkCosts.refugeShare }
        var fixed = 0.0
        for kind in [fromKind, toKind] {
            switch kind {
            case .sidewalk, .path: fixed += WalkCosts.fixed / 2
            case .none: fixed += WalkCosts.noCorner
            case .refuge: break
            }
        }
        let wait = signal.contains(.signal) ? WalkCosts.signalWait : 0
        let seconds = width / WalkCosts.pace
        // Fastest still keeps off ramps and wide streets with no light
        let weighted = max(weight * risk, floors ? min(floor, risk) : 0)
        return seconds + wait + weighted + weight * fixed
    }

    /// The route's legs and stats, from the search's last state back to its start.
    private func reconstruct(best: (cost: Double, state: Int32, exit: Snap, direct: Snap?),
                             sources: [Int: (Double, Snap)], weight: Double, floors: Bool, options: Options,
                             start: Walk.Point, end: Walk.Point) -> Route {
        var stats = Stats()
        stats.weight = weight
        func addSide(block: Int, metres: Double) {
            stats.metres += metres
            stats.seconds += metres / WalkCosts.pace * (graph.flags(of: block).contains(.steps) ? WalkCosts.stepsTimes : 1)
        }
        func sidePoint(_ snap: Snap) -> Walk.Point {
            let line = graph.line(of: snap.block)
            let offset = graph.class(of: snap.block) == .path ? 0 : sideOffset(block: snap.block, left: snap.left)
            return Self.point(along: line, metres: snap.along, offset: snap.left ? offset : -offset)
        }
        // Straight along one side
        if let direct = best.direct {
            let exit = best.exit
            let a = sidePoint(direct), b = sidePoint(exit)
            addSide(block: direct.block, metres: abs(exit.along - direct.along))
            stats.metres += (direct.off + exit.off)
            stats.seconds += (direct.off + exit.off) / WalkCosts.pace
            stats.risk = best.cost - stats.seconds
            return Route(legs: [.access(start, a), .side(block: direct.block, left: direct.left, from: a, to: b,
                                                          fromAlong: direct.along, toAlong: exit.along), .access(b, end)],
                         stats: stats)
        }
        var chain: [Int] = []
        var state = Int(best.state)
        while state >= 0 {
            chain.append(state)
            state = Int(parent[state])
        }
        chain.reverse()
        var legs: [Leg] = []
        // From the start along its side to the first corner
        let first = chain[0]
        if let (_, snap) = sources[first] {
            let p = sidePoint(snap)
            legs.append(.access(start, p))
            let length = graph.length(of: snap.block)
            let (from, _) = graph.sideCorners(of: snap.block, left: snap.left)
            let towardStart = first / 3 == from
            legs.append(.side(block: snap.block, left: snap.left, from: p, to: corner(first / 3),
                              fromAlong: snap.along, toAlong: towardStart ? 0 : length))
            addSide(block: snap.block, metres: towardStart ? snap.along : length - snap.along)
            stats.metres += snap.off
            stats.seconds += snap.off / WalkCosts.pace
        }
        for (previous, state) in zip(chain, chain.dropFirst()) {
            let corner = previous / 3, node = graph.node(ofArm: corner)
            let next = graph.next(corner, at: node)
            let target = state / 3
            // Which move led here: find it again from the corners
            let own = corner
            var done = false
            for arm in [own, next] {
                let block = Int(graph.armBlock[arm])
                guard graph.class(of: block) != .arm else { continue }
                let end = Int(graph.armEnd[arm])
                let leftOfBlock = (arm == own) == (end == 1)
                let (from, to) = graph.sideCorners(of: block, left: leftOfBlock)
                if (end == 0 ? to : from) == target {
                    let length = graph.length(of: block)
                    legs.append(.side(block: block, left: leftOfBlock, from: self.corner(corner), to: self.corner(target),
                                      fromAlong: end == 0 ? 0 : length, toAlong: end == 0 ? length : 0))
                    addSide(block: block, metres: length)
                    done = true
                    break
                }
            }
            if done { continue }
            let arm = target == next ? next : own
            legs.append(.cross(node: node, arm: arm, from: self.corner(corner), to: self.corner(target)))
            let block = Int(graph.armBlock[arm])
            let width = graph.width(of: block) > 0 ? graph.width(of: block) : WalkCosts.unknownWidth
            if graph.class(of: block) != .path && !(graph.class(of: block) == .arm && [8, 13].contains(graph.blockRW[block])) {
                stats.metres += width
                stats.seconds += width / WalkCosts.pace
                // A divided road's halves count once, from the side it starts on
                if graph.kind(ofCorner: corner) != .refuge { stats.crossings += 1 }
                let signal = Sidewalks.Signal.Kind(rawValue: Int(graph.nodeSignal[node]))
                if !signal.contains(.signal) {
                    if graph.kind(ofCorner: corner) != .refuge { stats.unsignalled += 1 }
                    if width >= WalkCosts.wide || graph.blockLanes[block] >= 3 { stats.unsignalledWide += 1 }
                }
                if graph.class(of: block) == .arm { stats.ramps += 1 }
            }
        }
        // From the last corner along the end's side, off to the end
        let exit = best.exit
        let p = sidePoint(exit)
        let last = chain[chain.count - 1] / 3
        let (from, _) = graph.sideCorners(of: exit.block, left: exit.left)
        let length = graph.length(of: exit.block)
        legs.append(.side(block: exit.block, left: exit.left, from: corner(last), to: p,
                          fromAlong: last == from ? 0 : length, toAlong: exit.along))
        addSide(block: exit.block, metres: last == from ? exit.along : length - exit.along)
        legs.append(.access(p, end))
        stats.metres += exit.off
        stats.seconds += exit.off / WalkCosts.pace
        stats.risk = max(0, best.cost - stats.seconds)
        return Route(legs: legs, stats: stats)
    }

    /// A corner's place.
    func corner(_ arm: Int) -> Walk.Point { graph.corner(arm) }

    /// The point `metres` along `line`, moved `offset` metres to its left (negative: right).
    static func point(along line: [Walk.Point], metres: Double, offset: Double) -> Walk.Point {
        var travelled = 0.0
        for (a, b) in zip(line, line.dropFirst()) {
            let piece = a.metres(to: b)
            if travelled + piece >= metres || b == line.last, piece > 0 {
                let t = min(1, max(0, (metres - travelled) / piece))
                let (dx, dy) = b.offset(from: a)
                let x = dx * t - dy / piece * offset, y = dy * t + dx / piece * offset
                return Walk.Point(lat: a.lat + y / WalkGraph.metresNorth, lon: a.lon + x / (111_320 * cos(a.lat * .pi / 180)))
            }
            travelled += piece
        }
        return line.last ?? line[0]
    }

    /// A route's rough line, to draw: each side along its street's line moved out to the side,
    /// between its corners; each crossing straight over.
    func points(of route: Route) -> [Walk.Point] {
        var out: [Walk.Point] = []
        func add(_ p: Walk.Point) {
            if let last = out.last, last.metres(to: p) < 0.3 { return }
            out.append(p)
        }
        for leg in route.legs {
            switch leg {
            case let .access(a, b), let .cross(_, _, a, b):
                add(a)
                add(b)
            case let .side(block, left, from, to, fromAlong, toAlong):
                add(from)
                let line = graph.line(of: block)
                let offset = graph.class(of: block) == .path ? 0 : sideOffset(block: block, left: left) * (left ? 1 : -1)
                var travelled = 0.0
                var inner: [(Double, Walk.Point)] = []
                for (a, b) in zip(line, line.dropFirst()) {
                    travelled += a.metres(to: b)
                    if b != line.last { inner.append((travelled, b)) }
                }
                let lo = min(fromAlong, toAlong), hi = max(fromAlong, toAlong)
                let between = inner.filter { $0.0 > lo + 1 && $0.0 < hi - 1 }
                for (metres, _) in (fromAlong <= toAlong ? between : between.reversed()) {
                    add(Self.point(along: line, metres: metres, offset: offset))
                }
                add(to)
            }
        }
        return out
    }
}

/// A binary min-heap.
struct Heap<Element: Comparable> {
    private var items: [Element] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ item: Element) {
        items.append(item)
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i] < items[parent] else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> Element? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var smallest = i
            if l < items.count, items[l] < items[smallest] { smallest = l }
            if r < items.count, items[r] < items[smallest] { smallest = r }
            if smallest == i { break }
            items.swapAt(i, smallest)
            i = smallest
        }
        return top
    }
}
