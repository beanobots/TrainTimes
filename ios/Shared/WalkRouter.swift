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
    /// Metres a second, walking: with `lightWait` at each light, Apple Maps' times for the
    /// bench's walks within about 4% (tools/walkbench).
    static let pace = 1.30
    /// Seconds a walk's time takes for each crossing at a light, waiting for it: the walk's
    /// time (`Stats.seconds`, which budgets are kept to), not its cost (`signalWait`), so
    /// waits don't send routes to crossings with none.
    static let lightWait = 12.0
    /// Of its cost, what a block along the way a walk was going costs, routed again.
    static let followShare = 0.85
    /// Metres from the way it was going a block's middle is to be along it.
    static let followNear = 10.0
    /// Seconds for a turn onto another street, so a route doesn't zigzag through the grid:
    /// every staircase across it is about as long, with as many crossings.
    static let turn = 10.0
    /// Metres a block must be to count as a stretch of sidewalk a turn's measured from.
    static let turnReach = 8.0
    /// Degrees a way turns before it's a turn.
    static let turning = 30.0
    /// Seconds for crossing both streets at a corner the street you're on first, when a route
    /// is found again to cross them the other way (`ordered`): the street ahead first is the
    /// way people do it, straight on and then turning to cross, so it's said simply. Not in
    /// the first search, where it'd send a walk down other streets instead.
    static let turnFirst = 10.0
    /// Seconds more a walk may take crossing the street ahead first at its corners.
    static let reorderSlack = 15.0
    /// Metres round the first route the search crossing the street ahead first keeps to, in
    /// the 100 m cells they reach: it's to keep to the same streets anyway.
    static let reorderBand = 30.0

    // A crossing, per carriageway crossed
    static let perMetreWide = 0.8
    /// More for each metre of a crossing past `longFrom`, light or no light: out in front of
    /// turning trucks and cars that much longer, a long crossing's worse than its length.
    static let perMetreLong = 2.0
    static let longFrom = 12.0
    static let perExtraLane = 3.0
    static let twoWay = 4.0
    static let truckLocal = 6.0
    static let truckThrough = 12.0
    static let bikeLane = 1.0
    /// For a crossing with no light: its risk this many times, plus `unsignalledExtra`, plus
    /// `unsignalledWideExtra` where it's wide or three lanes or more. A short one (`short` or
    /// less) only `unsignalledShortTimes` and `unsignalledShortExtra`, as it's soon over, the
    /// penalty growing with the width from there to `wide`.
    static let unsignalledTimes = 2.0
    static let unsignalledExtra = 10.0
    static let unsignalledShortTimes = 1.2
    static let unsignalledShortExtra = 3.0
    static let unsignalledWideExtra = 25.0
    /// Metres curb to curb up to which a crossing's short: a side street, a lane and parking
    /// each side.
    static let short = 9.0
    /// Metres curb to curb from which a street's wide.
    static let wide = 15.0

    /// How much of the full no-light penalty a crossing `width` metres over takes: none of
    /// it short, all of it wide.
    static func unsignalledShare(width: Double) -> Double {
        min(1, max(0, (width - short) / (wide - short)))
    }
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
    /// More for a crosswalk with no light and no markings either.
    static let unmarked = 5.0
    /// More for a crossing at one of Vision Zero's priority intersections, the city's worst
    /// for people walking.
    static let priorityIntersection = 8.0
    /// More for each pedestrian hurt at a crossing in five years (`WalkGraph.nodeCrashes`), up
    /// to `crashesAtMost` of them: a busy corner has more people to hurt, so it's capped.
    static let perCrash = 1.5
    static let crashesAtMost = 12
    /// Seconds more, step-free, for a crossing with no curb ramp at an end, on top of its cost:
    /// steered clear of, not ruled out, as the ramp list may have missed one.
    static let noRamp = 60.0
    /// Metres further a start or end is taken to be from a side with no sidewalk, so it's put
    /// on a real one nearby.
    static let noSidewalkSnap = 20.0
    /// Seconds for stepping between a city corner and its OSM sidewalk junction, besides the walk.
    static let link = 1.0
    /// More for crossing, at the city's corner, a street OSM maps the sidewalks and
    /// crosswalks of, where it has no crosswalk: most likely there's none.
    static let unmapped = 60.0
    /// Metres of a crossing's corner-to-corner line on the sidewalks either end.
    static let sidewalksAtEnds = 4.0
    /// The most times its street's width a crossing's taken to be, however far apart its corners.
    static let skewedAtMost = 1.2

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
    /// Along a Vision Zero priority corridor, per 100 m.
    static let besideCorridor = 4.0
    static let noSidewalk = 60.0
    /// A side the city has a sidewalk on but OSM, mapping all round, doesn't: likely none to walk.
    static let unmappedSide = 30.0
    static let alley = 10.0
    /// Steps take this much longer than the flat.
    static let stepsTimes = 1.5

    // Night: crime against people outdoors (`WalkGraph.crime`), dark paths and empty streets,
    // on Balanced and Safest only. A street's crime counts by how far over its neighbours'
    // it is, so a walk takes the better of the streets beside each other, not another way
    // round a part of town.
    /// Per crime per 100 m over the neighbours' in three years, walking along it, past
    /// `crimeFree` and up to `crimesAtMost`.
    static let perCrime = 15.0
    static let crimesAtMost = 8.0
    /// Per crime over the neighbours' at a junction's corners in three years, crossing there.
    static let perCornerCrime = 6.0
    static let cornerCrimesAtMost = 10.0
    /// Crimes over the neighbours' (per 100 m, or at a corner) that don't count: about one in
    /// three years, which says little about a street.
    static let crimeFree = 0.5
    /// How much crime counts at each part of the day: a little by day, most of all late.
    static func crimeShare(_ band: WalkGraph.Band) -> Double {
        switch band {
        case .day: 0.25
        case .evening: 0.75
        case .late: 1
        }
    }
    /// After dark (evening and late), per 100 m: a path away from the street lights.
    static let dark = 60.0
    /// 1–6, per 100 m: a path in a park, which is shut.
    static let parkClosed = 120.0
    /// After dark, per 100 m: a street with no shops, less with some, none from `busy` shops
    /// per 100 m, where there are people about.
    static let quiet = 10.0
    static let busy = 2.0
    /// After dark, a crossing with no light has its risk this many times: drivers see someone
    /// crossing less well, so a lit way's kept to rather than traded for a darker one.
    static let unsignalledDarkTimes = 1.5
    /// Seconds of night cost (unweighted) a walk must keep clear of, against the way it'd go
    /// without them, to be said to go "via safer streets": more than a short empty block.
    static let saferAtNight = 20.0

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
    /// The city corners linked to each OSM sidewalk junction (`WalkGraph.cornerLink`), the
    /// other way round.
    private var linkedCorners: [Int32: [Int32]] = [:]
    private static let cellSize = 100.0
    private static let origin = Walk.Point(lat: 40.7, lon: -74.0)

    private struct Cell: Hashable {
        let x: Int32, y: Int32
    }

    // The search's scratch, reused: by state (corner × how it was come to)
    private var cost: [Float] = []
    private var parent: [Int32] = []
    /// The arm the walk last came in along a stretch of sidewalk (`turnCost`), at the node
    /// it came to, or -1: carried over crossings, crosswalks and the short bits between, so a
    /// turn made through them is still a turn.
    private var heading: [Int32] = []
    /// Whether, since that stretch of sidewalk, the walk's crossed its street (`turnFirst`):
    /// carried as `heading` is.
    private var crossedAlong: [Bool] = []
    /// Whether the way to the state crossed a street it was on before the one ahead, at a corner.
    private var ownFirst: [Bool] = []
    /// `ownFirst` for the last search's route.
    private var foundOwnFirst = false
    private var stamp: [UInt32] = []
    private var generation: UInt32 = 0
    /// The blocks along the way a walk was going (`Options.along`), for this search.
    private var followed: Set<Int> = []
    /// When the walk's walked, for the night costs (`nightRisk`): nil while finding the fastest
    /// route, which they don't touch, and on Fastest.
    private var night: Options.Time?
    /// Each block's sides' metres as walked, corner to corner (`sideMetres`), by block × 2,
    /// and 1 more for its right; 0 till worked out.
    private var walkedMetres: [Float] = []

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
        walkedMetres = [Float](repeating: 0, count: graph.blockCount * 2)
        for (corner, node) in graph.cornerLink.enumerated() where node != WalkGraph.noLink {
            linkedCorners[Int32(node), default: []].append(Int32(corner))
        }
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
        /// The way a walk was going, routed again from off it: the blocks along it cost
        /// `WalkCosts.followShare` of what they would, so it's rejoined unless another way's
        /// clearly better, rather than a new one picked between two much the same.
        var along: [Walk.Point] = []
        /// When it's walked, for the night costs.
        var time = Time.midday

        /// When a walk's walked: crime counts for more after dark, dark paths and empty streets
        /// only then, and parks are shut 1–6.
        struct Time: Hashable, Sendable {
            var band: WalkGraph.Band
            var parksClosed: Bool
            static let midday = Time(hour: 12)

            init(hour: Int) {
                band = WalkGraph.Band(hour: hour)
                parksClosed = 1..<6 ~= hour
            }

            /// At `date`, in New York.
            init(_ date: Date) {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
                self.init(hour: calendar.component(.hour, from: date))
            }
        }
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
        /// After dark, whether the night costs took it another way, clear of more crime, dark
        /// paths or empty streets than `WalkCosts.saferAtNight` (`nightCost`): "via safer streets".
        var saferAtNight = false
        /// Whether it was found again to cross the street ahead first at its corners (`ordered`).
        var reordered = false
    }

    struct Route: Sendable {
        let legs: [Leg]
        let stats: Stats
        /// Each leg's cost, time and weighted risk, in seconds: what makes a route cost what it does.
        var costs: [Double] = []
    }

    // MARK: Routing

    /// The route from `start` to `end` for `options`, kept within its preference's budget of
    /// the fastest route's time. Nil where either's off the graph, or they aren't joined.
    func route(from start: Walk.Point, to end: Walk.Point, options: Options = Options()) -> Route? {
        followed = blocks(along: options.along)
        night = nil
        defer { followed = []; night = nil }
        // Where it starts and ends doesn't change with the weight: found once for every search
        let starts = snaps(near: start), ends = snaps(near: end)
        guard let fastest = ordered(from: start, to: end, starts: starts, ends: ends,
                                   weight: WalkCosts.weight(.fastest), options: options)
        else { return nil }
        if options.preference == .fastest { return finish(fastest, fastestSeconds: fastest.stats.seconds) }
        let budget = WalkCosts.budget(options.preference, fastest: fastest.stats.seconds)
        var weight = WalkCosts.weight(options.preference)
        night = options.time
        for _ in 0..<4 {
            if var route = ordered(from: start, to: end, starts: starts, ends: ends, weight: weight, options: options),
               route.stats.seconds <= budget {
                if options.time.band != .day {
                    // The way it'd go without the night costs, to say whether they changed it
                    night = nil
                    let without = ordered(from: start, to: end, starts: starts, ends: ends, weight: weight, options: options)
                    night = options.time
                    if let without, nightCost(of: without, options: options) - nightCost(of: route, options: options)
                        >= WalkCosts.saferAtNight {
                        var stats = route.stats
                        stats.saferAtNight = true
                        route = Route(legs: route.legs, stats: stats, costs: route.costs)
                    }
                }
                return finish(route, fastestSeconds: fastest.stats.seconds)
            }
            weight /= 2
        }
        return finish(fastest, fastestSeconds: fastest.stats.seconds)
    }

    /// The walkable blocks that run along `line`: their middle and both ends within
    /// `WalkCosts.followNear` of it.
    private func blocks(along line: [Walk.Point]) -> Set<Int> {
        guard line.count >= 2 else { return [] }
        let near = WalkCosts.followNear
        func off(_ p: Walk.Point) -> Double {
            zip(line, line.dropFirst()).map { p.nearest(from: $0, to: $1).gap }.min() ?? .infinity
        }
        var seen = Set<Int32>(), found = Set<Int>()
        for (a, b) in zip(line, line.dropFirst()) {
            for cell in Self.cells(from: Self.xy(a), to: Self.xy(b), pad: near) {
                for block in cells[cell] ?? [] where seen.insert(block).inserted {
                    let points = graph.line(of: Int(block))
                    guard let first = points.first, let last = points.last else { continue }
                    let middle = Self.point(along: points, metres: graph.length(of: Int(block)) / 2, offset: 0)
                    if off(middle) <= near, off(first) <= near * 1.5, off(last) <= near * 1.5 { found.insert(Int(block)) }
                }
            }
        }
        return found
    }

    /// What the night costs add to a route, unweighted (`night` as it is): its crime, dark
    /// paths, empty streets and unlit crossings after dark.
    private func nightCost(of route: Route, options: Options) -> Double {
        let saved = night
        defer { night = saved }
        func total() -> Double {
            route.legs.reduce(0) { sum, leg in
                switch leg {
                case let .side(block, left, _, _, fromAlong, toAlong):
                    let cost = sideCost(block: block, left: left, weight: 1, options: options)
                    guard cost.isFinite else { return sum }
                    return sum + cost * min(1, abs(toAlong - fromAlong) / max(graph.length(of: block), 1))
                case let .cross(node, arm, _, _):
                    // Between the corners either side of its arm, whichever way over
                    return sum + (crossCost(node: node, arm: arm, from: arm, to: graph.previous(arm, at: node), weight: 1,
                                            stepFree: options.stepFree) ?? 0)
                case .access:
                    return sum
                }
            }
        }
        let withNight = total()
        night = nil
        return withNight - total()
    }

    private func finish(_ route: Route, fastestSeconds: Double) -> Route {
        var stats = route.stats
        stats.fastestSeconds = fastestSeconds
        return Route(legs: route.legs, stats: stats, costs: route.costs)
    }

    /// A place a route can start or end: on a block's side, `along` metres from its start,
    /// `off` metres from that side's line.
    struct Snap {
        let block: Int
        let left: Bool
        let along: Double
        let off: Double
    }

    /// The walkable blocks' sides near `point`, nearest first: on its side of each street (both
    /// where it's in the middle of one), within 60 m, or 150 m of a path.
    func snaps(near point: Walk.Point, limit: Int = 4) -> [Snap] {
        let p = (Float((point.lon - Self.origin.lon) * WalkGraph.metresEast), Float((point.lat - Self.origin.lat) * WalkGraph.metresNorth))
        var found: [(Double, Snap)] = []
        // Those only across a street from it, for if there's nothing else
        var across: [(Double, Snap)] = []
        var seen = Set<Int32>()
        for cell in Self.cells(from: p, to: p, pad: 150) {
            for block in cells[cell] ?? [] where seen.insert(block).inserted {
                let b = Int(block)
                guard let nearest = nearestOnLine(of: b, to: point) else { continue }
                let isPath = graph.class(of: b) == .path
                // Not onto a crosswalk, in the street
                guard nearest.off <= (isPath ? 150 : 60), !graph.flags(of: b).contains(.crosswalk),
                      reachable(b, along: nearest.along, off: nearest.off) else { continue }
                let width = max(graph.width(of: b), 4)
                let sides: [Bool] = isPath ? [true] : abs(nearest.lateral) < min(width / 2 - 1, 2) ? [true, false] : [nearest.lateral > 0]
                for left in sides where isPath || !graph.isCovered(b, left: left) {
                    let lineOffset = isPath ? 0 : sideOffset(block: b, left: left)
                    let off = isPath ? nearest.off : abs((left ? 1 : -1) * nearest.lateral - lineOffset)
                    // Not across another street to it: that's crossing mid-block, unsaid
                    let at = Self.point(along: graph.line(of: b), metres: nearest.along, offset: left ? lineOffset : -lineOffset)
                    if crossesStreet(from: point, to: at, except: b) {
                        across.append((off, Snap(block: b, left: left, along: nearest.along, off: off)))
                        continue
                    }
                    // A side with no sidewalk (a median's) only where nothing's nearer by more
                    // than `noSidewalkSnap`
                    let bare = !isPath && graph.offset(of: b, left: left) == 0
                    found.append((off + (isPath ? 5 : 0) + (bare ? WalkCosts.noSidewalkSnap : 0),
                                  Snap(block: b, left: left, along: nearest.along, off: off)))
                }
            }
        }
        // Keep to the walkable part most of them are in
        let ranked = (found.isEmpty ? across : found).sorted { $0.0 < $1.0 }
        // Only those about as near as the nearest: a long way off one, straight, through
        // whatever's between, isn't a shortcut to take
        guard let nearest = ranked.first?.0 else { return [] }
        return Array(ranked.filter { $0.0 <= nearest + Self.snapSpread }.prefix(limit).map(\.1))
    }

    /// Metres further than the nearest side a walk may start or end on another.
    static let snapSpread = 15.0
    /// Metres off a bridge's deck (or a tunnel's way) a walk may start or end on it: on it, as
    /// near as GPS can tell. Further, it's under it or beside it, with no way up.
    static let onDeck = 10.0
    /// Metres along from its end on the ground a bridge's way may be started on: the foot of
    /// its ramp or stairs.
    static let deckFoot = 20.0

    /// Whether a walk can start or end `along` metres along `block`, `off` its line: on the
    /// ground, or up on a bridge (down in a tunnel) only nearly on it or by its foot. Not up
    /// onto the Queensboro Bridge from Roosevelt Island under it.
    private func reachable(_ block: Int, along: Double, off: Double) -> Bool {
        let a = graph.atGrade(block, end: 0), b = graph.atGrade(block, end: 1)
        if (a && b) || off <= Self.onDeck { return true }
        return (a && along <= Self.deckFoot) || (b && graph.length(of: block) - along <= Self.deckFoot)
    }

    /// Whether the straight way from `a` to `b` goes over a street's line, but `except`'s: from
    /// a sidewalk to the one across the street. Not a street `a` is standing in, within a metre
    /// of its line or half its width: from out in a junction (GPS in the middle of 7 Av and
    /// 41 St), every corner's over one street's line or another's.
    private func crossesStreet(from a: Walk.Point, to b: Walk.Point, except: Int) -> Bool {
        let pa = Self.xy(a), pb = Self.xy(b)
        let dx = pb.0 - pa.0, dy = pb.1 - pa.1
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1 else { return false }
        var seen = Set<Int32>()
        for cell in Self.cells(from: pa, to: pb) {
            for block in cells[cell] ?? [] where Int(block) != except && seen.insert(block).inserted {
                guard graph.class(of: Int(block)) == .walk else { continue }
                if let nearest = nearestOnLine(of: Int(block), to: a), nearest.off <= max(1, graph.width(of: Int(block)) / 2) {
                    continue
                }
                let line = graph.line(of: Int(block)).map(Self.xy)
                for (c, d) in zip(line, line.dropFirst()) {
                    let ex = d.0 - c.0, ey = d.1 - c.1
                    let den = dx * ey - dy * ex
                    guard abs(den) > 1e-6 else { continue }
                    let t = ((c.0 - pa.0) * ey - (c.1 - pa.1) * ex) / den
                    let u = ((c.0 - pa.0) * dy - (c.1 - pa.1) * dx) / den
                    if t * length > 1, t < 1, u >= 0, u <= 1 { return true }
                }
            }
        }
        return false
    }

    /// A point in the plane the router's cells are in: metres east and north of `origin`.
    private static func xy(_ p: Walk.Point) -> (Float, Float) {
        (Float((p.lon - origin.lon) * WalkGraph.metresEast), Float((p.lat - origin.lat) * WalkGraph.metresNorth))
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

    /// Metres walking a block's side from corner to corner, as its line's drawn (`points(of:)`):
    /// more than its street's line round the outside of a bend, and where its corners are far
    /// out from the line's ends (round Columbus Circle, a 2 m bit of it 56 m corner to corner).
    /// Never less than the line, so the search's estimate holds.
    func sideMetres(block: Int, left: Bool) -> Double {
        let slot = block * 2 + (left ? 0 : 1)
        if walkedMetres[slot] > 0 { return Double(walkedMetres[slot]) }
        let length = graph.length(of: block)
        let (from, to) = graph.sideCorners(of: block, left: left)
        let drawn = Self.metres(points(of: .side(block: block, left: left, from: corner(from), to: corner(to),
                                                 fromAlong: 0, toAlong: length)))
        let metres = max(length, drawn, 0.1)
        walkedMetres[slot] = Float(metres)
        return metres
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

    /// `search`; and where its route crosses the street it's on before the one ahead at a
    /// corner, found again with that costing `turnFirst`, its own sides (not crosswalks) at
    /// `followShare` to keep to its streets. That route if it does keep to them, no more than
    /// `reorderSlack` slower, with no more unsignalled crossings or ramps. Its risk and costs
    /// are as found, with its sides at `followShare`.
    private func ordered(from start: Walk.Point, to end: Walk.Point, starts: [Snap], ends: [Snap],
                         weight: Double, options: Options) -> Route? {
        guard let route = search(from: start, to: end, starts: starts, ends: ends, weight: weight, options: options)
        else { return nil }
        guard foundOwnFirst else { return route }
        let saved = followed
        defer { followed = saved }
        for case let .side(block, _, _, _, _, _) in route.legs where !graph.flags(of: block).contains(.crosswalk) {
            followed.insert(block)
        }
        let line = points(of: route).map(Self.xy)
        var band = Set<Cell>()
        for (a, b) in zip(line, line.dropFirst()) {
            band.formUnion(Self.cells(from: a, to: b, pad: WalkCosts.reorderBand))
        }
        guard let other = search(from: start, to: end, starts: starts, ends: ends, weight: weight, options: options,
                                 orderCost: WalkCosts.turnFirst, within: band),
              streets(of: other) == streets(of: route),
              other.stats.seconds <= route.stats.seconds + WalkCosts.reorderSlack,
              other.stats.unsignalled <= route.stats.unsignalled,
              other.stats.unsignalledWide <= route.stats.unsignalledWide,
              other.stats.ramps <= route.stats.ramps
        else { return route }
        var stats = other.stats
        stats.reordered = true
        return Route(legs: other.legs, stats: stats, costs: other.costs)
    }

    /// The streets a route walks along, in order: each block's name it walks 30 m or more of.
    private func streets(of route: Route) -> [UInt32] {
        var names: [UInt32] = []
        for case let .side(block, _, _, _, from, to) in route.legs where abs(to - from) >= 30 {
            let name = graph.blockName[block]
            if names.last != name { names.append(name) }
        }
        return names
    }

    /// The cheapest route, its crossings at corners in either order unless `orderCost`; only
    /// by corners in the cells `within`, if given.
    private func search(from start: Walk.Point, to end: Walk.Point, starts: [Snap], ends: [Snap],
                        weight: Double, options: Options, orderCost: Double = 0, within: Set<Cell>? = nil) -> Route? {
        // Both ends in one walkable part: of those both are near, the one they're nearest
        // (a start by a loose bit of park path still goes by the streets)
        func part(_ snap: Snap) -> UInt32 { graph.nodePart[Int(graph.blockA[snap.block])] }
        let shared = Set(starts.map(part)).intersection(ends.map(part))
        guard let chosen = shared.min(by: { a, b in
            let da = (starts.first { part($0) == a }?.off ?? .infinity) + (ends.first { part($0) == a }?.off ?? .infinity)
            let db = (starts.first { part($0) == b }?.off ?? .infinity) + (ends.first { part($0) == b }?.off ?? .infinity)
            return da < db
        }) else { return nil }
        let sources = starts.filter { part($0) == chosen }
        let targets = ends.filter { part($0) == chosen }

        let states = graph.armBlock.count * 3
        if cost.count != states {
            cost = [Float](repeating: .infinity, count: states)
            parent = [Int32](repeating: -1, count: states)
            heading = [Int32](repeating: -1, count: states)
            crossedAlong = [Bool](repeating: false, count: states)
            ownFirst = [Bool](repeating: false, count: states)
            stamp = [UInt32](repeating: 0, count: states)
            generation = 0
        }
        generation &+= 1
        if generation == 0 {
            stamp = [UInt32](repeating: 0, count: states)
            generation = 1
        }
        var heap = Heap<Entry>()
        let endXY = (Float((end.lon - Self.origin.lon) * WalkGraph.metresEast), Float((end.lat - Self.origin.lat) * WalkGraph.metresNorth))
        // Of a metre's time, the least it can cost: 0.9 for slack, and less along the way a
        // walk was going (`followShare`), so the estimate's never more than what's left
        let lowest = Float(0.9 * (followed.isEmpty ? 1 : WalkCosts.followShare))
        func h(_ corner: Int) -> Float {
            let dx = cornerX[corner] - endXY.0, dy = cornerY[corner] - endXY.1
            return (dx * dx + dy * dy).squareRoot() / Float(WalkCosts.pace) * lowest
        }
        func relax(_ state: Int, _ value: Double, from previous: Int32, _ move: Move, heading came: Int32,
                   crossed: Bool = false, late: Bool = false) {
            if let within {
                let corner = state / 3, size = Float(Self.cellSize)
                guard within.contains(Cell(x: Int32(cornerX[corner] / size), y: Int32(cornerY[corner] / size))) else { return }
            }
            let v = Float(value)
            if stamp[state] != generation || v < cost[state] {
                stamp[state] = generation
                cost[state] = v
                parent[state] = previous
                heading[state] = came
                crossedAlong[state] = crossed
                ownFirst[state] = late || (previous >= 0 && ownFirst[Int(previous)])
                heap.push(Entry(f: v + h(state / 3), state: Int32(state)))
            }
        }

        // Onto each start's side, to the corner at either end
        var startCost: [Int: (Double, Snap)] = [:]
        for snap in sources {
            let access = snap.off / WalkCosts.pace
            let length = graph.length(of: snap.block)
            let (from, to) = graph.sideCorners(of: snap.block, left: snap.left)
            let perMetre = sideCost(block: snap.block, left: snap.left, weight: weight, options: options) / max(length, 1)
            guard perMetre.isFinite else { continue }
            // Toward its end: arriving along its arm there; back toward its start, likewise
            let toState = to * 3 + (snap.left ? 0 : 1), fromState = from * 3 + (snap.left ? 1 : 0)
            let toCost = access + perMetre * (length - snap.along), fromCost = access + perMetre * snap.along
            if toCost < (startCost[toState]?.0 ?? .infinity) { startCost[toState] = (toCost, snap) }
            if fromCost < (startCost[fromState]?.0 ?? .infinity) { startCost[fromState] = (fromCost, snap) }
        }
        // Coming along the start's block: its arm at the corner, as `along` sets it
        for (state, (value, snap)) in startCost {
            let corner = state / 3
            let into = state % 3 == 0 ? corner : graph.next(corner, at: graph.node(ofArm: corner))
            relax(state, value, from: -1, .start, heading: Self.setsHeading(graph, snap.block) ? Int32(into) : -1)
        }

        // Off each end's side, from the corner at either end
        var exits: [Int: [(Double, Snap)]] = [:]
        for snap in targets {
            let access = snap.off / WalkCosts.pace
            let length = graph.length(of: snap.block)
            let (from, to) = graph.sideCorners(of: snap.block, left: snap.left)
            let perMetre = sideCost(block: snap.block, left: snap.left, weight: weight, options: options) / max(length, 1)
            guard perMetre.isFinite else { continue }
            exits[from, default: []].append((access + perMetre * snap.along, snap))
            exits[to, default: []].append((access + perMetre * (length - snap.along), snap))
        }
        // The same side as a start: straight along it
        var best: (cost: Double, state: Int32, exit: Snap, direct: Snap?)?
        for source in sources {
            for target in targets where target.block == source.block && target.left == source.left {
                let length = graph.length(of: source.block)
                let perMetre = sideCost(block: source.block, left: source.left, weight: weight, options: options) / max(length, 1)
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
            let into = heading[state]
            // Over the street come along at a corner, then the other: the street ahead first
            // instead (`orderCost`). A crossing over `name`, `metres` across, as a crosswalk or
            // at a junction: whether the street come along's crossed after it, whether this is
            // the street ahead after it, and the extra
            let along = into >= 0 ? graph.blockName[Int(graph.armBlock[Int(into)])] : 0
            let crossed = crossedAlong[state]
            func over(_ name: UInt32, metres: Double) -> (crossed: Bool, late: Bool, extra: Double) {
                guard metres >= 1, name != 0, along != 0 else { return (crossed, false, 0) }
                if name == along { return (true, false, 0) }
                return (crossed, crossed, crossed ? orderCost : 0)
            }
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
                var step = sideCost(block: block, left: leftOfBlock, weight: weight, options: options)
                guard step.isFinite else { continue }
                // A stretch of sidewalk turns from the last one; crosswalks and bits between
                // carry it on
                var onward = into
                var crossedOn = crossed, late = false
                if Self.setsHeading(graph, block) {
                    if into >= 0 { step += turnCost(into: Int(into), outOf: arm) }
                    onward = Int32(arrive == 0 ? destination : graph.next(destination, at: graph.node(ofArm: destination)))
                    crossedOn = false
                } else if graph.flags(of: block).contains(.crosswalk) {
                    let crossing = over(graph.blockName[block], metres: graph.length(of: block))
                    step += crossing.extra
                    crossedOn = crossing.crossed
                    late = crossing.late
                }
                relax(destination * 3 + arrive, g + step, from: Int32(state), move, heading: onward, crossed: crossedOn,
                      late: late)
            }
            // Between a city corner and its OSM sidewalk junction, either way
            let linked = graph.cornerLink[corner]
            if linked != WalkGraph.noLink {
                let step = linkCost(corner: corner, node: Int(linked))
                for arm in graph.arms(of: Int(linked)) {
                    relax(arm * 3 + 2, g + step, from: Int32(state), .start, heading: into, crossed: crossed)
                }
            }
            if let corners = linkedCorners[Int32(node)] {
                for other in corners {
                    relax(Int(other) * 3 + 2, g + linkCost(corner: Int(other), node: node), from: Int32(state), .start,
                          heading: into, crossed: crossed)
                }
            }
            // Over either arm, at a junction (or a signalled crosswalk mid-block)
            guard degree >= 3 || (degree == 2 && graph.nodeSignal[node] != 0) else { continue }
            for (arm, move) in [(own, Move.crossOwn), (next, Move.crossNext)] {
                let destination = move == .crossOwn ? graph.previous(own, at: node) : next
                guard destination != corner,
                      let step = crossCost(node: node, arm: arm, from: corner, to: destination, weight: weight,
                                           stepFree: options.stepFree)
                else { continue }
                let crossing = over(graph.blockName[Int(graph.armBlock[arm])], metres: crossingMetres(from: corner, to: destination))
                relax(destination * 3 + 2, g + step + crossing.extra, from: Int32(state), move, heading: into,
                      crossed: crossing.crossed, late: crossing.late)
            }
        }
        guard let best else { return nil }
        foundOwnFirst = best.state >= 0 && ownFirst[Int(best.state)]
        return reconstruct(best: best, sources: startCost, weight: weight, options: options, start: start, end: end)
    }

    /// Whether walking `block` is a stretch of sidewalk a turn's measured from (`heading`): not
    /// a crosswalk, named for the street it crosses, nor a connector or a bit shorter than
    /// `WalkCosts.turnReach`, as at a rounded corner.
    static func setsHeading(_ graph: WalkGraph, _ block: Int) -> Bool {
        let flags = graph.flags(of: block)
        return !flags.contains(.crosswalk) && !flags.contains(.connector) && graph.length(of: block) >= WalkCosts.turnReach
    }

    /// The turn penalty for coming into a junction along `into`'s street and leaving along `arm`'s.
    private func turnCost(into: Int, outOf arm: Int) -> Double {
        let a = Int(graph.armBlock[into]), b = Int(graph.armBlock[arm])
        // Along the same street isn't a turn, however it bends; unnamed paths might be anything
        guard graph.blockName[a] != graph.blockName[b] || graph.blockName[a] == 0 else { return 0 }
        let came = (Double(armBearing[into]) + 180).truncatingRemainder(dividingBy: 360)
        let degrees = abs((Double(armBearing[arm]) - came + 540).truncatingRemainder(dividingBy: 360) - 180)
        return degrees > WalkCosts.turning ? WalkCosts.turn : 0
    }

    /// Walking a block's side, end to end: its time, and its risk per 100 m weighted. Infinite
    /// where it can't be walked: steps when step-free, a street's side OSM's sidewalk takes.
    /// One of OSM's crosswalks costs what crossing its street does.
    func sideCost(block: Int, left: Bool, weight: Double, options: Options) -> Double {
        let cost = fullSideCost(block: block, left: left, weight: weight, options: options)
        return followed.contains(block) ? cost * WalkCosts.followShare : cost
    }

    /// `sideCost`, not taking the way it was going into account.
    private func fullSideCost(block: Int, left: Bool, weight: Double, options: Options) -> Double {
        let flags = graph.flags(of: block)
        if options.stepFree && flags.contains(.steps) { return .infinity }
        if flags.contains(.crosswalk) { return crosswalkCost(block: block, weight: weight, stepFree: options.stepFree) }
        let metres = sideMetres(block: block, left: left)
        var seconds = metres / WalkCosts.pace
        if flags.contains(.steps) { seconds *= WalkCosts.stepsTimes }
        let isStreet = graph.class(of: block) == .walk
        guard isStreet || flags.contains(.osmSidewalk) else { return seconds + weight * nightRisk(block: block) * metres / 100 }
        if isStreet && graph.isCovered(block, left: left) { return .infinity }
        var risk = WalkCosts.besideTraffic + nightRisk(block: block)
        if flags.contains(.truckLocal) || flags.contains(.truckThrough) { risk += WalkCosts.besideTruckRoute }
        risk += WalkCosts.speed(Int(graph.blockSpeed[block])).beside
        if graph.blockLanes[block] >= 4 { risk += WalkCosts.besideManyLanes }
        if flags.contains(.underElevated) { risk += WalkCosts.underElevated }
        if graph.safety(of: block).contains(.corridor) { risk += WalkCosts.besideCorridor }
        if flags.contains(.alley) { risk += WalkCosts.alley }
        // The bit of street through a median is the crosswalk, not a sidewalk
        if isStreet && graph.offset(of: block, left: left) == 0 && !flags.contains(.median) { risk += WalkCosts.noSidewalk }
        if isStreet && graph.isUnmapped(block, left: left) { risk += WalkCosts.unmappedSide }
        return seconds + weight * risk * metres / 100
    }

    /// A block's night risk per 100 m walked along it, at the walk's time (`night`): its crime,
    /// and after dark a dark path, a shut park, a street with nobody about.
    private func nightRisk(block: Int) -> Double {
        guard let night else { return 0 }
        let over = min(max(0, graph.crime(of: block, in: night.band) - WalkCosts.crimeFree), WalkCosts.crimesAtMost)
        var risk = WalkCosts.perCrime * over * WalkCosts.crimeShare(night.band)
        guard night.band != .day else { return risk }
        let path = graph.night(of: block)
        if path.contains(.dark) { risk += WalkCosts.dark }
        if path.contains(.park) && night.parksClosed { risk += WalkCosts.parkClosed }
        if graph.class(of: block) == .walk || graph.flags(of: block).contains(.osmSidewalk) {
            risk += WalkCosts.quiet * max(0, 1 - graph.shops(of: block) / WalkCosts.busy)
        }
        return risk
    }

    /// The night risk of crossing where there's been `crime` over the neighbours' at the corners.
    private func nightRisk(crossingCrime crime: Double) -> Double {
        guard let night else { return 0 }
        return WalkCosts.perCornerCrime * min(max(0, crime - WalkCosts.crimeFree), WalkCosts.cornerCrimesAtMost)
            * WalkCosts.crimeShare(night.band)
    }

    /// What's crossed: the street's measure and traffic, and what's there for someone on foot.
    struct Crossing {
        var width: Double
        var lanes: Int
        var speed: Int
        var twoWay: Bool
        var flags: WalkGraph.BlockFlags
        var signal: Sidewalks.Signal.Kind
        var ramp = false
        var unmarked = false
        /// A median or island to wait on partway.
        var refuge = false
        /// At a Vision Zero priority intersection.
        var priority = false
        /// Pedestrians hurt there in five years.
        var crashes = 0
        /// No curb ramp at an end.
        var noRamp = false
        /// Its night risk, from the crime at its corners (`nightRisk(crossingCrime:)`).
        var night = 0.0
        /// Crossed after dark (`WalkCosts.unsignalledDarkTimes`).
        var dark = false
        /// The fixed part of a crossing's cost to pay: all of it, or half from or to a median.
        var fixed: Double
    }

    /// A crossing's time and weighted risk (`WalkCosts`).
    func cost(of crossing: Crossing, weight: Double, stepFree: Bool = false) -> Double {
        let width = crossing.width, lanes = crossing.lanes, flags = crossing.flags, signal = crossing.signal
        var risk = WalkCosts.perMetreWide * width + WalkCosts.perMetreLong * max(0, width - WalkCosts.longFrom)
            + WalkCosts.perExtraLane * Double(max(0, lanes - 1))
        if crossing.twoWay { risk += WalkCosts.twoWay }
        risk += WalkCosts.speed(crossing.speed).crossing
        if flags.contains(.truckThrough) { risk += WalkCosts.truckThrough } else if flags.contains(.truckLocal) { risk += WalkCosts.truckLocal }
        if flags.contains(.bikeLane) { risk += WalkCosts.bikeLane }
        let isWide = width >= WalkCosts.wide || lanes >= 3
        var floor = 0.0
        if !signal.contains(.signal) {
            // Soon over where it's short; the full penalty from wide
            let share = WalkCosts.unsignalledShare(width: width)
            let times = WalkCosts.unsignalledShortTimes + (WalkCosts.unsignalledTimes - WalkCosts.unsignalledShortTimes) * share
            let extra = WalkCosts.unsignalledShortExtra + (WalkCosts.unsignalledExtra - WalkCosts.unsignalledShortExtra) * share
            risk = risk * times + extra
            if crossing.unmarked { risk += WalkCosts.unmarked }
            if crossing.dark { risk *= WalkCosts.unsignalledDarkTimes }
            if isWide {
                risk += WalkCosts.unsignalledWideExtra
                floor += WalkCosts.unsignalledWideExtra * 0.5
            }
        } else if signal.contains(.exclusive) {
            risk *= WalkCosts.exclusiveTimes
        } else if signal.contains(.leading) {
            risk *= WalkCosts.leadingTimes
        }
        if crossing.ramp {
            let ramp = signal.contains(.signal) ? WalkCosts.rampSignalled : WalkCosts.rampUnsignalled
            risk += ramp
            floor += ramp
        }
        // Where people walking have been hurt, light or no light
        if crossing.priority { risk += WalkCosts.priorityIntersection }
        risk += WalkCosts.perCrash * Double(min(crossing.crashes, WalkCosts.crashesAtMost))
        if crossing.refuge { risk *= WalkCosts.refugeShare }
        risk += crossing.night
        let wait = signal.contains(.signal) ? WalkCosts.signalWait : 0
        let ramp = stepFree && crossing.noRamp ? WalkCosts.noRamp : 0
        let seconds = width / WalkCosts.pace
        // Fastest still keeps off ramps and wide streets with no light
        let weighted = max(weight * risk, min(floor, risk))
        return seconds + wait + weighted + weight * crossing.fixed + ramp
    }

    /// One of OSM's crosswalks: as long as it really is, over the street it's over, with its
    /// own light and markings.
    func crosswalk(_ block: Int) -> Crossing {
        let flags = graph.flags(of: block), bits = graph.crossing(of: block)
        var signal = Sidewalks.Signal.Kind()
        if bits.contains(.signal) { signal.insert(.signal) }
        if bits.contains(.leading) { signal.insert(.leading) }
        if bits.contains(.exclusive) { signal.insert(.exclusive) }
        let refuge = bits.contains(.island)
        let safety = graph.safety(of: block)
        return Crossing(width: max(graph.length(of: block), 1), lanes: max(Int(graph.blockLanes[block]), 1),
                        speed: Int(graph.blockSpeed[block]), twoWay: !flags.contains(.oneWay) && graph.blockWidth[block] > 0,
                        flags: flags, signal: signal, ramp: bits.contains(.ramp), unmarked: bits.contains(.unmarked),
                        refuge: refuge, priority: safety.contains(.priority), crashes: Int(graph.blockCrashes[block]),
                        noRamp: !safety.contains(.rampAtStart) || !safety.contains(.rampAtEnd),
                        night: night.map { nightRisk(crossingCrime: graph.crime(of: block, in: $0.band)) } ?? 0,
                        dark: night.map { $0.band != .day } ?? false,
                        fixed: refuge ? WalkCosts.fixed / 2 : WalkCosts.fixed)
    }

    func crosswalkCost(block: Int, weight: Double, stepFree: Bool = false) -> Double {
        cost(of: crosswalk(block), weight: weight, stepFree: stepFree)
    }

    /// Crossing an arm at a junction, from one corner to the next: its time and weighted
    /// risk. A street OSM's sidewalks take a side of is crossed at OSM's crosswalks; at the
    /// city's corner only as a last resort (`unmapped` more), where OSM has none to get to.
    func crossCost(node: Int, arm: Int, from: Int, to: Int, weight: Double, stepFree: Bool = false) -> Double? {
        let block = Int(graph.armBlock[arm])
        let flags = graph.flags(of: block)
        let rw = graph.blockRW[block]
        // These cost no less than walking from corner to corner, which the search's estimate
        // (`h`) counts on: less, and it could settle on a route a few seconds worse
        let walking = crossingMetres(from: from, to: to) / WalkCosts.pace
        switch graph.crossingClass(of: block) {
        case .path:
            return max(0.5, walking)
        case .arm where rw == 8 || rw == 13:
            // A driveway, a U-turn through a median
            return max(2, walking)
        case .arm where graph.nodeLevel[node] != WalkGraph.grade:
            // Off the ground (a bridge's walkway touching its roadway): passed, not crossed
            return max(0.5, walking)
        default:
            break
        }
        // Either side: a divided road's half has its median side unmapped, but OSM's crosswalks
        // are still the way over it
        let unmapped = flags.contains(.coveredLeft) || flags.contains(.coveredRight) ? WalkCosts.unmapped : 0
        // Medians either end: a refuge halfway, and the crossing's fixed cost paid once
        let fromKind = graph.kind(ofCorner: from), toKind = graph.kind(ofCorner: to)
        var fixed = 0.0
        for kind in [fromKind, toKind] {
            switch kind {
            case .sidewalk, .path: fixed += WalkCosts.fixed / 2
            case .none: fixed += WalkCosts.noCorner
            case .refuge: break
            }
        }
        let crossing = Crossing(
            // As wide as the city says, or as far as it really is from corner to corner
            width: crossingWidth(block: block, from: from, to: to), lanes: Int(graph.blockLanes[block]),
            speed: Int(graph.blockSpeed[block]), twoWay: !flags.contains(.oneWay) && graph.crossingClass(of: block) == .walk,
            flags: flags, signal: Sidewalks.Signal.Kind(rawValue: Int(graph.nodeSignal[node])),
            ramp: graph.crossingClass(of: block) == .arm, refuge: fromKind == .refuge || toKind == .refuge,
            priority: graph.safety(ofNode: node).contains(.priority), crashes: Int(graph.nodeCrashes[node]),
            // Off a sidewalk corner with no ramp; a median's level with the street
            noRamp: (fromKind == .sidewalk && !graph.hasRamp(from)) || (toKind == .sidewalk && !graph.hasRamp(to)),
            night: night.map { nightRisk(crossingCrime: graph.crime(ofNode: node, in: $0.band)) } ?? 0,
            dark: night.map { $0.band != .day } ?? false,
            fixed: fixed)
        return cost(of: crossing, weight: weight, stepFree: stepFree) + unmapped
    }

    /// Metres over a street from one corner to another: its width as the city has it, or
    /// further where the corners are (a skewed crossing, round a slip lane), less the
    /// sidewalks either end, but not more than `skewedAtMost` times its width (corners far out
    /// in a sharp wedge, where the crosswalk's really nearer square).
    func crossingWidth(block: Int, from: Int, to: Int) -> Double {
        let listed = graph.width(of: block) > 0 ? graph.width(of: block) : WalkCosts.unknownWidth
        let corners = crossingMetres(from: from, to: to) - WalkCosts.sidewalksAtEnds
        return min(max(listed, corners), listed * WalkCosts.skewedAtMost)
    }

    /// Stepping between a city corner and an OSM sidewalk junction.
    func linkCost(corner: Int, node: Int) -> Double {
        let dx = Double(cornerX[corner] - nodeX[node]), dy = Double(cornerY[corner] - nodeY[node])
        return (dx * dx + dy * dy).squareRoot() / WalkCosts.pace + WalkCosts.link
    }

    /// Metres between two corners.
    func crossingMetres(from: Int, to: Int) -> Double {
        let dx = Double(cornerX[from] - cornerX[to]), dy = Double(cornerY[from] - cornerY[to])
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The route's legs and stats, from the search's last state back to its start.
    private func reconstruct(best: (cost: Double, state: Int32, exit: Snap, direct: Snap?),
                             sources: [Int: (Double, Snap)], weight: Double, options: Options,
                             start: Walk.Point, end: Walk.Point) -> Route {
        var stats = Stats()
        stats.weight = weight
        /// `metres` of its line along a block's side, walked as far as its side is (`sideMetres`).
        func addSide(block: Int, left: Bool, metres: Double) {
            let walked = metres * sideMetres(block: block, left: left) / max(graph.length(of: block), 0.1)
            stats.metres += walked
            stats.seconds += walked / WalkCosts.pace * (graph.flags(of: block).contains(.steps) ? WalkCosts.stepsTimes : 1)
            // One of OSM's crosswalks: a crossing, as one at a corner is
            guard graph.flags(of: block).contains(.crosswalk) else { return }
            let crossing = crosswalk(block)
            stats.crossings += 1
            if crossing.signal.contains(.signal) {
                stats.seconds += WalkCosts.lightWait
            } else {
                stats.unsignalled += 1
                if crossing.width >= WalkCosts.wide || crossing.lanes >= 3 { stats.unsignalledWide += 1 }
            }
            if crossing.ramp { stats.ramps += 1 }
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
            addSide(block: direct.block, left: direct.left, metres: abs(exit.along - direct.along))
            stats.metres += (direct.off + exit.off)
            stats.seconds += (direct.off + exit.off) / WalkCosts.pace
            stats.risk = best.cost - stats.seconds
            let length = max(graph.length(of: direct.block), 1)
            let along = sideCost(block: direct.block, left: direct.left, weight: weight, options: options)
                * abs(exit.along - direct.along) / length
            return Route(legs: [.access(start, a), .side(block: direct.block, left: direct.left, from: a, to: b,
                                                          fromAlong: direct.along, toAlong: exit.along), .access(b, end)],
                         stats: stats, costs: [direct.off / WalkCosts.pace, along, exit.off / WalkCosts.pace])
        }
        var chain: [Int] = []
        var state = Int(best.state)
        while state >= 0 {
            chain.append(state)
            state = Int(parent[state])
        }
        chain.reverse()
        var legs: [Leg] = []
        var costs: [Double] = []
        func partial(_ block: Int, _ left: Bool, _ metres: Double) -> Double {
            sideCost(block: block, left: left, weight: weight, options: options) * metres / max(graph.length(of: block), 1)
        }
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
            addSide(block: snap.block, left: snap.left, metres: towardStart ? snap.along : length - snap.along)
            costs += [snap.off / WalkCosts.pace, partial(snap.block, snap.left, towardStart ? snap.along : length - snap.along)]
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
                    addSide(block: block, left: leftOfBlock, metres: length)
                    costs.append(partial(block, leftOfBlock, length))
                    done = true
                    break
                }
            }
            if done { continue }
            // A step between a city corner and an OSM sidewalk junction
            if graph.node(ofArm: target) != node {
                let from = self.corner(corner), to = self.corner(target)
                legs.append(.access(from, to))
                let linked = graph.cornerLink[corner] != WalkGraph.noLink && Int(graph.cornerLink[corner]) == graph.node(ofArm: target)
                let step = linked ? linkCost(corner: corner, node: graph.node(ofArm: target))
                    : linkCost(corner: target, node: node)
                costs.append(step)
                stats.metres += from.metres(to: to)
                stats.seconds += from.metres(to: to) / WalkCosts.pace
                continue
            }
            let arm = target == next ? next : own
            legs.append(.cross(node: node, arm: arm, from: self.corner(corner), to: self.corner(target)))
            costs.append(crossCost(node: node, arm: arm, from: corner, to: target, weight: weight,
                                   stepFree: options.stepFree) ?? 0)
            let block = Int(graph.armBlock[arm])
            let width = crossingWidth(block: block, from: corner, to: target)
            if passes(node: node, block: block) {
                // Not a crossing, but still walked, corner to corner
                let metres = crossingMetres(from: corner, to: target)
                stats.metres += metres
                stats.seconds += metres / WalkCosts.pace
            } else {
                stats.metres += width
                stats.seconds += width / WalkCosts.pace
                // A divided road's halves count once, from the side it starts on
                if graph.kind(ofCorner: corner) != .refuge { stats.crossings += 1 }
                let signal = Sidewalks.Signal.Kind(rawValue: Int(graph.nodeSignal[node]))
                if signal.contains(.signal) {
                    if graph.kind(ofCorner: corner) != .refuge { stats.seconds += WalkCosts.lightWait }
                } else {
                    if graph.kind(ofCorner: corner) != .refuge { stats.unsignalled += 1 }
                    if width >= WalkCosts.wide || graph.blockLanes[block] >= 3 { stats.unsignalledWide += 1 }
                }
                if graph.crossingClass(of: block) == .arm { stats.ramps += 1 }
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
        addSide(block: exit.block, left: exit.left, metres: last == from ? exit.along : length - exit.along)
        legs.append(.access(p, end))
        costs += [partial(exit.block, exit.left, last == from ? exit.along : length - exit.along), exit.off / WalkCosts.pace]
        stats.metres += exit.off
        stats.seconds += exit.off / WalkCosts.pace
        stats.risk = max(0, best.cost - stats.seconds)
        return Route(legs: legs, stats: stats, costs: costs)
    }

    /// Whether going over `block` at `node` isn't crossing a street: a path, a driveway or
    /// U-turn, or a road met off the ground.
    func passes(node: Int, block: Int) -> Bool {
        graph.crossingClass(of: block) == .path
            || graph.crossingClass(of: block) == .arm && ([8, 13].contains(graph.blockRW[block]) || graph.nodeLevel[node] != WalkGraph.grade)
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
                return Walk.Point(lat: a.lat + y / WalkGraph.metresNorth, lon: a.lon + x / (Earth.metresPerDegree * cos(a.lat * .pi / 180)))
            }
            travelled += piece
        }
        return line.last ?? line[0]
    }

    /// A route's rough line, to draw: each side along its street's line moved out to the side,
    /// between its corners; each crossing straight over.
    func points(of route: Route) -> [Walk.Point] {
        var out: [Walk.Point] = []
        for leg in route.legs {
            for p in points(of: leg) where out.last.map({ $0.metres(to: p) >= 0.3 }) ?? true {
                out.append(p)
            }
        }
        return out
    }

    /// A leg's line: a side along its street's line moved out to the side, between its corners
    /// (or a start or end part way along); anything else straight from one end to the other.
    func points(of leg: Leg) -> [Walk.Point] {
        switch leg {
        case let .access(a, b), let .cross(_, _, a, b):
            return [a, b]
        case let .side(block, left, from, to, fromAlong, toAlong):
            let line = graph.line(of: block)
            let offset = graph.class(of: block) == .path ? 0 : sideOffset(block: block, left: left) * (left ? 1 : -1)
            var travelled = 0.0
            var inner: [Double] = []
            for (a, b) in zip(line, line.dropFirst()) {
                travelled += a.metres(to: b)
                if b != line.last { inner.append(travelled) }
            }
            let lo = min(fromAlong, toAlong), hi = max(fromAlong, toAlong)
            let between = inner.filter { $0 > lo + 1 && $0 < hi - 1 }
            return [from] + (fromAlong <= toAlong ? between : between.reversed()).map {
                Self.point(along: line, metres: $0, offset: offset)
            } + [to]
        }
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
