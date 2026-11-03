import Foundation

/// A route the router found as a walk, turn by turn: the same as Apple Maps' walks once put on
/// the sidewalk (`Sidewalks.fit`), so everything that shows one shows this. Its path is the
/// route's own line, its crossings made of that path's points, each with its light and the
/// street it's over; steps go by the city's street names, each ending in what to do there.
extension WalkRouter {
    /// Metres of a street shorter than which it's not a step of its own: a bit of another
    /// street's name at a junction, walked as part of the one before.
    static let shortestStep = 20.0
    /// Metres of another name between two bits of the same street shorter than which it's all
    /// the one street: round a little square, a jog at a junction.
    static let shortDetour = 60.0
    /// Degrees a crossing's next piece over may turn from the last, on an island, and still be
    /// the same crossing.
    static let islandTurn = 35.0
    /// What a step up or down steps goes by, however short: "Take the stairs", as Apple Maps
    /// says it.
    static let stairs = "the stairs"

    /// What a crossing piece is over.
    private struct Crossed {
        var over: String?
        var signal: Sidewalks.Signal.Kind
        var width: Double
        /// It ends on (starts from) a median or island: more of the same crossing follows (came before).
        var toRefuge = false
        var fromRefuge = false
    }

    private enum Kind {
        /// Walking along a street or path, by its name.
        case walk(String?)
        /// Through a median or across an island, between halves of a crossing.
        case inStreet(String?)
        case cross(Crossed)
    }

    /// A leg's part of the path, `from` and `to` indices into it.
    private struct Piece {
        var kind: Kind
        var from: Int
        var to: Int
    }

    /// One crossing, through any medians, or a walk along one street's name.
    private enum Item {
        case walk(name: String?, from: Int, to: Int)
        case crossing(over: String?, light: Walk.Light, from: Int, to: Int)
    }

    /// `route` as a walk: steps, crossings with their lights and streets, its time the
    /// route's. The crossings the way you go are left in their steps; those to the street's
    /// other side get steps of their own (`Walk.addCrossingSteps`).
    func walk(of route: Route) -> Walk {
        var path: [Walk.Point] = []
        // Each point added, or the one just before it where they're as good as the same: its index
        func add(_ points: [Walk.Point]) -> (from: Int, to: Int) {
            var first: Int?
            for point in points {
                if path.last.map({ $0.metres(to: point) >= 0.3 }) ?? true { path.append(point) }
                if first == nil { first = path.count - 1 }
            }
            return (first ?? max(path.count - 1, 0), max(path.count - 1, 0))
        }

        var pieces: [Piece] = []
        for leg in route.legs {
            let (from, to) = add(points(of: leg))
            pieces.append(Piece(kind: kind(of: leg), from: from, to: to))
        }
        Self.trimSpurs(&path, &pieces)
        Self.squareCorners(&path, &pieces)
        guard path.count >= 2 else {
            return Walk(steps: [], seconds: route.stats.seconds, meters: 0, crossings: [], lights: [])
        }
        let items = Self.items(of: pieces, path: path)

        var crossings: [[Walk.Point]] = []
        var lights: [Walk.Light] = []
        var streets: [String] = []
        for case let .crossing(over, light, from, to) in items where from < to {
            crossings.append(Array(path[from...to]))
            lights.append(light)
            streets.append(over ?? "")
        }

        let steps = steps(of: items, path: path, end: route.legs.last)
        // Walking, and waiting at the lights, as the route's budget was kept to
        var walk = Walk(steps: steps, seconds: route.stats.seconds, meters: Self.metres(path),
                        crossings: crossings, lights: lights, streets: streets)
        walk.addCrossingSteps()
        return walk
    }

    /// Metres out and back, no further, that's a spur off the walk to cut: the line out to a
    /// corner just past where it turns, and back.
    static let spur = 12.0

    /// The path without its spurs (`spur`), the pieces' indices into it moved to match. A
    /// crossing's ends are never cut.
    private static func trimSpurs(_ path: inout [Walk.Point], _ pieces: inout [Piece]) {
        var kept = [Bool](repeating: true, count: path.count)
        var fixed = Set<Int>()
        for piece in pieces {
            if case .cross = piece.kind { fixed.formUnion([piece.from, piece.to]) }
        }
        var cut = true
        while cut {
            cut = false
            let indices = path.indices.filter { kept[$0] }
            for (a, (b, c)) in zip(indices, zip(indices.dropFirst(), indices.dropFirst(2))) where !fixed.contains(b) {
                let out = path[a].metres(to: path[b]), back = path[b].metres(to: path[c])
                guard min(out, back) < spur, min(out, back) > 0 else { continue }
                let turned = abs((path[b].heading(to: path[c]) - path[a].heading(to: path[b]) + 540)
                    .truncatingRemainder(dividingBy: 360) - 180)
                if turned > 155 {
                    kept[b] = false
                    cut = true
                    break
                }
            }
        }
        // Each old index to the new one of it, or of the last point kept before it
        var moved = [Int](repeating: 0, count: path.count)
        var count = 0
        for index in path.indices {
            if kept[index] { count += 1 }
            moved[index] = max(count - 1, 0)
        }
        path = path.indices.filter { kept[$0] }.map { path[$0] }
        for index in pieces.indices {
            pieces[index].from = moved[pieces[index].from]
            pieces[index].to = moved[pieces[index].to]
        }
    }

    /// Metres from a crossing's end the bits joining it to the sidewalk may run, squared off
    /// into one corner (`squareCorners`).
    static let cornerReach = 8.0
    /// Metres into a crossing its end may move back to the corner.
    static let cornerInto = 4.0
    /// Metres to the side of the sidewalk's line a crosswalk straight on may be slid onto it:
    /// within a crosswalk's width.
    static let crosswalkAside = 3.0

    /// Each crossing's ends joined square to the sidewalk: OSM draws its sidewalks down their
    /// middles and its crosswalks to the curb, or just to one side, with short bits between at
    /// an angle, a kink at every corner. Turning there, the bits become the one point where the
    /// sidewalk's line and the crossing's meet; going straight on, the crossing's end slides
    /// onto the sidewalk's line; one crossing straight after another, the point their lines
    /// meet. Where the lines meet far off, or into a crossing more than `cornerInto`, the bits
    /// stay. A crossing stays as straight, at most a little shorter.
    private static func squareCorners(_ path: inout [Walk.Point], _ pieces: inout [Piece]) {
        guard path.count >= 3 else { return }
        let origin = path[0]
        let east = Earth.metresPerDegree * cos(origin.lat * .pi / 180), north = Earth.metresPerDegree
        func xy(_ p: Walk.Point) -> (x: Double, y: Double) { ((p.lon - origin.lon) * east, (p.lat - origin.lat) * north) }
        func point(_ v: (x: Double, y: Double)) -> Walk.Point {
            Walk.Point(lat: origin.lat + v.y / north, lon: origin.lon + v.x / east)
        }
        func unit(_ a: Walk.Point, _ b: Walk.Point) -> (x: Double, y: Double)? {
            let p = xy(a), q = xy(b), dx = q.x - p.x, dy = q.y - p.y, length = (dx * dx + dy * dy).squareRoot()
            return length > 1 ? (dx / length, dy / length) : nil
        }
        var fixed = Set<Int>()
        for piece in pieces {
            if case .cross = piece.kind { fixed.formUnion([piece.from, piece.to]) }
        }
        // Points `range` gives way to the corner, in order along the path
        var edits: [(range: Range<Int>, corner: Walk.Point)] = []

        /// The corner for the crossing end `end`, going on over it along `inward` (coming from
        /// it, against), with the sidewalk before it (`step` -1) or after (1).
        func corner(end: Int, inward: (x: Double, y: Double), step: Int) {
            // The first point the reach away along the sidewalk, not into another crossing;
            // the sidewalk's line is the way from it to the point before, toward the crossing
            var index = end + step
            while path.indices.contains(index), path[index].metres(to: path[end]) < cornerReach {
                if fixed.contains(index) { return }
                index += step
            }
            guard path.indices.contains(index), index - step != end,
                  let run = unit(path[index], path[index - step]) else { return }
            let s = xy(path[index]), e = xy(path[end])
            let wx = e.x - s.x, wy = e.y - s.y
            let dot = run.x * inward.x + run.y * inward.y
            // Straight on over it: the crossing's end slid onto the sidewalk's line, where it's
            // just off it, so the walk doesn't jog out to the crosswalk and back
            if abs(dot) > cos(20 * .pi / 180) {
                let ahead = wx * run.x + wy * run.y, aside = wx * run.y - wy * run.x
                guard ahead > 0, abs(aside) <= Self.crosswalkAside else { return }
                let slid = point((s.x + run.x * ahead, s.y + run.y * ahead))
                let range = step < 0 ? (index + 1)..<(end + 1) : end..<index
                if let last = edits.last, last.range.upperBound > range.lowerBound { return }
                edits.append((range, slid))
                return
            }
            // Else a turn there
            guard abs(dot) < cos(35 * .pi / 180) else { return }
            // Where the sidewalk's line (from `index`, along `run` toward the crossing) and the
            // crossing's (back from `end`, against `inward`) meet
            let cross = run.x * inward.y - run.y * inward.x
            let along = (wx * inward.y - wy * inward.x) / cross
            let back = (wx * run.y - wy * run.x) / cross
            let reach = cornerReach + 4
            // Before the crossing, or a little way into it where the crosswalk runs past the
            // sidewalk's middle (its end then the corner, the crossing a bit shorter but as straight)
            let over = path[end].metres(to: path[end - step])
            guard along > -1, along < path[index].metres(to: path[end]) + 4,
                  back > -reach, back < min(Self.cornerInto, over - 2) else { return }
            let meet = point((s.x + run.x * along, s.y + run.y * along))
            guard meet.metres(to: path[end]) <= reach else { return }
            let into = back > 0.3
            let range = step < 0 ? (index + 1)..<(into ? end + 1 : end) : (into ? end : end + 1)..<index
            if let last = edits.last, last.range.upperBound > range.lowerBound { return }
            edits.append((range, meet))
        }

        for piece in pieces {
            guard case .cross = piece.kind, piece.from < piece.to else { continue }
            if let over = unit(path[piece.from], path[piece.from + 1]) {
                corner(end: piece.from, inward: over, step: -1)
            }
            if let over = unit(path[piece.to - 1], path[piece.to]) {
                corner(end: piece.to, inward: (-over.x, -over.y), step: 1)
            }
        }
        // One crossing straight after another round a corner, a short bit between: the bit
        // the one point their lines meet, either's end moved to it a little way into it
        let crossings = pieces.filter {
            if case .cross = $0.kind { return $0.from < $0.to } else { return false }
        }
        for (first, second) in zip(crossings, crossings.dropFirst()) where first.to < second.from {
            let a = first.to, b = second.from
            guard WalkRouter.metres(Array(path[a...b])) < cornerReach,
                  let came = unit(path[a - 1], path[a]), let goes = unit(path[b], path[b + 1]) else { continue }
            let dot = came.x * goes.x + came.y * goes.y
            guard abs(dot) < cos(35 * .pi / 180) else { continue }
            // path[a] + came·t = path[b] + goes·u: t past the first's end, u before the second's start
            let p = xy(path[a]), q = xy(path[b])
            let wx = q.x - p.x, wy = q.y - p.y
            let cross = came.x * goes.y - came.y * goes.x
            let t = (wx * goes.y - wy * goes.x) / cross
            let u = (wx * came.y - wy * came.x) / cross
            let firstLength = path[a].metres(to: path[a - 1]), secondLength = path[b].metres(to: path[b + 1])
            guard t > -min(Self.cornerInto, firstLength - 2), t < cornerReach,
                  -u > -min(Self.cornerInto, secondLength - 2), -u < cornerReach else { continue }
            let meet = point((p.x + came.x * t, p.y + came.y * t))
            let range = (t < -0.3 ? a : a + 1)..<(u > 0.3 ? b + 1 : b)
            guard !edits.contains(where: { $0.range.overlaps(range) || $0.range.lowerBound == range.lowerBound }) else { continue }
            edits.append((range, meet))
        }
        guard !edits.isEmpty else { return }
        edits.sort { $0.range.lowerBound < $1.range.lowerBound }

        // The path again, each edit's points the corner; each old index to its new one
        var squared: [Walk.Point] = []
        var moved = [Int](repeating: 0, count: path.count)
        var next = 0
        for index in path.indices {
            while next < edits.count, edits[next].range.lowerBound == index {
                squared.append(edits[next].corner)
                next += 1
            }
            let inEdit = edits.contains { $0.range.contains(index) }
            if !inEdit { squared.append(path[index]) }
            moved[index] = squared.count - 1
        }
        path = squared
        for index in pieces.indices {
            pieces[index].from = moved[pieces[index].from]
            pieces[index].to = moved[pieces[index].to]
        }
    }

    /// What a leg is: walking, by its street's name, or crossing one.
    private func kind(of leg: Leg) -> Kind {
        switch leg {
        case .access:
            return .walk(nil)
        case let .side(block, _, _, _, _, _):
            let flags = graph.flags(of: block)
            if flags.contains(.crosswalk) {
                // OSM's crosswalk, named for what it's by: a park or a place's name isn't the street
                let crossing = crosswalk(block)
                let over = StreetNames.display(graph.name(of: block)).flatMap { StreetNames.isStreet($0) ? $0 : nil }
                return .cross(Crossed(over: over, signal: crossing.signal, width: crossing.width))
            }
            if flags.contains(.median) || flags.contains(.island) {
                return .inStreet(StreetNames.display(graph.name(of: block)))
            }
            return .walk(stepName(of: block))
        case let .cross(node, arm, _, to):
            let block = Int(graph.armBlock[arm])
            if passes(node: node, block: block) { return .walk(nil) }
            // Over arm `arm`, between the corner before it and its own
            let before = graph.previous(arm, at: node)
            let (fromCorner, toCorner) = graph.corner(arm) == to ? (before, arm) : (arm, before)
            return .cross(Crossed(over: StreetNames.display(graph.name(of: block)),
                                  signal: Sidewalks.Signal.Kind(rawValue: Int(graph.nodeSignal[node])),
                                  width: crossingWidth(block: block, from: fromCorner, to: toCorner),
                                  toRefuge: graph.kind(ofCorner: toCorner) == .refuge,
                                  fromRefuge: graph.kind(ofCorner: fromCorner) == .refuge))
        }
    }

    /// The name a step along `block` goes by: "the stairs" for steps, named or not; its
    /// street's, or "the path" for a path with none; nil for a bit of sidewalk or a link with
    /// none, which goes by the street it's part of.
    private func stepName(of block: Int) -> String? {
        let flags = graph.flags(of: block)
        if flags.contains(.steps) { return Self.stairs }
        if let name = StreetNames.display(graph.name(of: block)) { return name }
        guard graph.class(of: block) == .path, !flags.contains(.osmSidewalk), !flags.contains(.connector) else { return nil }
        return "the path"
    }

    /// The pieces as walking and crossings, a crossing's pieces through a median or island one
    /// crossing: on to its next piece over, from a refuge, through the median between, or
    /// straight on over the same street. Not on round a turn on the island, onto another arm
    /// of the junction, though it's the same street's name (two of Grand Army Plaza's).
    private static func items(of pieces: [Piece], path: [Walk.Point]) -> [Item] {
        /// Degrees clockwise from north piece `index` goes, end to end.
        func heading(_ index: Int) -> Double { path[pieces[index].from].heading(to: path[pieces[index].to]) }
        var items: [Item] = []
        var index = 0
        while index < pieces.count {
            let piece = pieces[index]
            switch piece.kind {
            case let .walk(name), let .inStreet(name):
                items.append(.walk(name: name, from: piece.from, to: piece.to))
                index += 1
            case let .cross(first):
                var parts = [first]
                var end = piece.to
                var lastPiece = index
                index += 1
                while true {
                    var next = index
                    while next < pieces.count, case .inStreet = pieces[next].kind { next += 1 }
                    guard next < pieces.count, case let .cross(crossed) = pieces[next].kind, let last = parts.last else { break }
                    let between = next > index
                    let sameStreet = last.over != nil && last.over == crossed.over
                    guard last.toRefuge || crossed.fromRefuge || between || sameStreet else { break }
                    // Over another street from an island, turning on it: a crossing of its own
                    if let over = last.over, let next = crossed.over, over != next { break }
                    let turned = abs((heading(next) - heading(lastPiece) + 540).truncatingRemainder(dividingBy: 360) - 180)
                    if turned > Self.islandTurn { break }
                    parts.append(crossed)
                    end = pieces[next].to
                    lastPiece = next
                    index = next + 1
                }
                items.append(.crossing(over: parts.lazy.compactMap(\.over).first, light: light(of: parts),
                                       from: piece.from, to: end))
            }
        }
        return items
    }

    /// A crossing's light, for all its parts: none if any part has none (wide by their widths
    /// together), else the least any part has.
    private static func light(of parts: [Crossed]) -> Walk.Light {
        if parts.contains(where: { !$0.signal.contains(.signal) }) {
            return parts.map(\.width).reduce(0, +) >= Walk.wideCrossing ? .unsignalledWide : .unsignalled
        }
        if parts.allSatisfy({ $0.signal.contains(.exclusive) }) { return .exclusive }
        if parts.allSatisfy({ $0.signal.contains(.leading) || $0.signal.contains(.exclusive) }) { return .leading }
        return .signal
    }

    /// The walk's steps: one per street along the way, each ending where you turn onto the
    /// next, or before you cross the street you're on to go along the next; the last arriving.
    private func steps(of items: [Item], path: [Walk.Point], end: Leg?) -> [Walk.Step] {
        // Walking with no name goes by the street before it, or at the start (or after stairs)
        // the one after
        var walks: [(name: String, from: Int, to: Int, item: Int)] = []
        var pending: [(from: Int, to: Int, item: Int)] = []
        for (index, item) in items.enumerated() {
            guard case let .walk(name, from, to) = item else { continue }
            if let name = name ?? walks.last.map(\.name).flatMap({ $0 == Self.stairs ? nil : $0 }) {
                for walk in pending { walks.append((name, walk.from, walk.to, walk.item)) }
                pending = []
                walks.append((name, from, to, index))
            } else {
                pending.append((from, to, index))
            }
        }
        for walk in pending { walks.append(("", walk.from, walk.to, walk.item)) }

        // Runs of the same name, however it's spelled (OSM's and the city's), a short one at a
        // junction part of the one before
        var runs: [(name: String, first: Int, last: Int)] = []
        /// Run `index` on to `last`, with the nicer spelling of its name and `other`'s.
        func extend(_ index: Int, to last: Int, _ other: String) {
            runs[index].last = last
            runs[index].name = StreetNames.nicer(runs[index].name, other)
        }
        for (index, walk) in walks.enumerated() {
            if let last = runs.last, StreetNames.same(last.name, walk.name) {
                extend(runs.count - 1, to: index, walk.name)
            } else {
                runs.append((walk.name, index, index))
            }
        }
        func length(_ run: (name: String, first: Int, last: Int)) -> Double {
            walks[run.first...run.last].map { Self.metres(Array(path[$0.from...$0.to])) }.reduce(0, +)
        }
        var merged = true
        while merged {
            merged = false
            // Off one street a little way and back onto it: all that street
            for index in runs.indices.dropFirst().dropLast()
            where StreetNames.same(runs[index - 1].name, runs[index + 1].name) && runs[index].name != Self.stairs
                && length(runs[index]) < Self.shortDetour {
                extend(index - 1, to: runs[index + 1].last, runs[index + 1].name)
                runs.removeSubrange(index...(index + 1))
                merged = true
                break
            }
            if merged { continue }
            for index in runs.indices.dropFirst().dropLast()
            where runs[index].name != Self.stairs && length(runs[index]) < Self.shortestStep {
                runs[index - 1].last = runs[index].last
                runs.remove(at: index)
                // The one before and after the same street again: one step
                if StreetNames.same(runs[index - 1].name, runs[index].name) {
                    extend(index - 1, to: runs[index].last, runs[index].name)
                    runs.remove(at: index)
                }
                merged = true
                break
            }
        }

        // Where each step ends: before crossing the street it's on to go along the next, or
        // where the next begins
        var ends: [Int] = []
        for (run, next) in zip(runs, runs.dropFirst()) {
            let afterItem = walks[run.last].item, nextItem = walks[next.first].item
            var end = walks[next.first].from
            for case let .crossing(over, _, from, to) in items[(afterItem + 1)..<nextItem]
            where from < to && StreetNames.same(over, run.name) {
                end = from
                break
            }
            ends.append(end)
        }
        ends.append(path.count - 1)

        var steps: [Walk.Step] = []
        var start = 0
        for (run, end) in zip(runs, ends) where end > start {
            // The street's name, for now: the step before's turn onto it says it
            steps.append(Walk.Step(turn: .straight, instruction: run.name, meters: Self.metres(Array(path[start...end])),
                                   points: Array(path[start...end])))
            start = end
        }
        // Each step's turn onto the next, said; the last arriving
        for index in steps.indices {
            guard index < steps.count - 1 else { break }
            let turn = Walk.turn(from: steps[index].points, onto: steps[index + 1].points, reach: Self.turnReach)
            steps[index].turn = turn
            steps[index].instruction = Self.instruction(turn, onto: steps[index + 1].instruction)
        }
        if let last = steps.indices.last {
            steps[last].turn = .arrive
            steps[last].instruction = Self.arrival(path: path, end: end)
        }
        return steps
    }

    /// Metres either side of a turn that say which way it goes, so a jog at the corner
    /// doesn't count.
    static let turnReach = 20.0

    /// What to do at a step's end, turning onto `street`: "Take a left onto 4th Ave".
    static func instruction(_ turn: Walk.Turn, onto street: String) -> String {
        let onto = street.isEmpty ? "" : " onto \(street)"
        switch turn {
        case .slightLeft: return "Take a slight left" + onto
        case .left: return "Take a left" + onto
        case .sharpLeft: return "Take a sharp left" + onto
        case .slightRight: return "Take a slight right" + onto
        case .right: return "Take a right" + onto
        case .sharpRight: return "Take a sharp right" + onto
        case .uTurn: return "Turn around" + onto
        default: return street.isEmpty ? "Continue" : street == stairs ? "Take the stairs" : "Continue onto \(street)"
        }
    }

    /// The last step's instruction: which side the destination's on, coming off the sidewalk
    /// to it, or just that you're there.
    private static func arrival(path: [Walk.Point], end: Leg?) -> String {
        guard case let .access(curb, destination) = end, curb.metres(to: destination) >= 3,
              let at = path.lastIndex(where: { $0.metres(to: curb) < 0.3 }), at > 0 else {
            return "Arrive at the destination"
        }
        // The way you came along the sidewalk, over the last few metres
        var back = at - 1
        while back > 0, path[back].metres(to: curb) < 5 { back -= 1 }
        let came = curb.offset(from: path[back]), off = destination.offset(from: curb)
        let left = came.east * off.north - came.north * off.east > 0
        return "The destination is on your \(left ? "left" : "right")"
    }

    /// A line's length in metres.
    static func metres(_ points: [Walk.Point]) -> Double {
        zip(points, points.dropFirst()).map { $0.metres(to: $1) }.reduce(0, +)
    }
}
