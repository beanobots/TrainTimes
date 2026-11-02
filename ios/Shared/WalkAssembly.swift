import Foundation

/// A route the router found as a walk, turn by turn: the same as Apple Maps' walks once put on
/// the sidewalk (`Sidewalks.fit`), so everything that shows one shows this. Its path is the
/// route's own line, its crossings made of that path's points, each with its light and the
/// street it's over; steps go by the city's street names, each ending in what to do there.
extension WalkRouter {
    /// Metres of a street shorter than which it's not a step of its own: a bit of another
    /// street's name at a junction, walked as part of the one before.
    static let shortestStep = 20.0

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
        guard path.count >= 2 else {
            return Walk(steps: [], seconds: route.stats.seconds, meters: 0, crossings: [], lights: [])
        }
        let items = Self.items(of: pieces)

        var crossings: [[Walk.Point]] = []
        var lights: [Walk.Light] = []
        var streets: [String] = []
        for case let .crossing(over, light, from, to) in items where from < to {
            crossings.append(Array(path[from...to]))
            lights.append(light)
            streets.append(over ?? "")
        }

        let steps = steps(of: items, path: path, end: route.legs.last)
        var walk = Walk(steps: steps, seconds: route.stats.seconds, meters: Self.metres(path),
                        crossings: crossings, lights: lights, streets: streets)
        walk.addCrossingSteps()
        return walk
    }

    /// What a leg is: walking, by its street's name, or crossing one.
    private func kind(of leg: Leg) -> Kind {
        switch leg {
        case .access:
            return .walk(nil)
        case let .side(block, _, _, _, _, _):
            let flags = graph.flags(of: block)
            if flags.contains(.crosswalk) {
                let crossing = crosswalk(block)
                return .cross(Crossed(over: StreetNames.display(graph.name(of: block)), signal: crossing.signal,
                                      width: crossing.width, toRefuge: crossing.refuge, fromRefuge: crossing.refuge))
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

    /// The name a step along `block` goes by: its street's, or "the path" for a path with none;
    /// nil for a bit of sidewalk or a link with none, which goes by the street it's part of.
    private func stepName(of block: Int) -> String? {
        if let name = StreetNames.display(graph.name(of: block)) { return name }
        let flags = graph.flags(of: block)
        guard graph.class(of: block) == .path, !flags.contains(.osmSidewalk), !flags.contains(.connector) else { return nil }
        return "the path"
    }

    /// The pieces as walking and crossings, a crossing's pieces through a median or island one
    /// crossing: on to its next piece over, from a refuge, through the median between, or
    /// straight on over the same street.
    private static func items(of pieces: [Piece]) -> [Item] {
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
                index += 1
                while true {
                    var next = index
                    while next < pieces.count, case .inStreet = pieces[next].kind { next += 1 }
                    guard next < pieces.count, case let .cross(crossed) = pieces[next].kind, let last = parts.last else { break }
                    let between = next > index
                    let sameStreet = last.over == nil || crossed.over == nil || last.over == crossed.over
                    guard last.toRefuge || crossed.fromRefuge || between || sameStreet else { break }
                    parts.append(crossed)
                    end = pieces[next].to
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
        // Walking with no name goes by the street before it, or at the start the one after
        var walks: [(name: String, from: Int, to: Int, item: Int)] = []
        var pending: [(from: Int, to: Int, item: Int)] = []
        for (index, item) in items.enumerated() {
            guard case let .walk(name, from, to) = item else { continue }
            if let name = name ?? walks.last?.name {
                for walk in pending { walks.append((name, walk.from, walk.to, walk.item)) }
                pending = []
                walks.append((name, from, to, index))
            } else {
                pending.append((from, to, index))
            }
        }
        for walk in pending { walks.append(("", walk.from, walk.to, walk.item)) }

        // Runs of the same name, a short one at a junction part of the one before
        var runs: [(name: String, first: Int, last: Int)] = []
        for (index, walk) in walks.enumerated() {
            if let last = runs.last, last.name == walk.name {
                runs[runs.count - 1].last = index
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
            for index in runs.indices.dropFirst().dropLast() where length(runs[index]) < Self.shortestStep {
                runs[index - 1].last = runs[index].last
                runs.remove(at: index)
                // The one before and after the same street again: one step
                if runs[index - 1].name == runs[index].name {
                    runs[index - 1].last = runs[index].last
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
            for case let .crossing(over, _, from, to) in items[(afterItem + 1)..<nextItem] where from < to && over == run.name {
                end = from
                break
            }
            ends.append(end)
        }
        ends.append(path.count - 1)

        var steps: [Walk.Step] = []
        var start = 0
        for (run, end) in zip(runs, ends) where end > start || run.first == runs.last?.first {
            guard end > start else { continue }
            steps.append(Walk.Step(turn: .straight, instruction: "", meters: Self.metres(Array(path[start...end])),
                                   points: Array(path[start...end])))
            steps[steps.count - 1].instruction = run.name
            start = end
        }
        // Each step's turn onto the next, said; the last arriving
        for index in steps.indices {
            guard index < steps.count - 1 else { break }
            let turn = Walk.turn(from: steps[index].points, onto: steps[index + 1].points)
            steps[index].turn = turn
            steps[index].instruction = Self.instruction(turn, onto: steps[index + 1].instruction)
        }
        if let last = steps.indices.last {
            steps[last].turn = .arrive
            steps[last].instruction = Self.arrival(path: path, end: end)
        }
        return steps
    }

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
        default: return street.isEmpty ? "Continue" : "Continue onto \(street)"
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
