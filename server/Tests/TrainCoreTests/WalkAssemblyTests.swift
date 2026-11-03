import Foundation
import Testing
@testable import TrainCore

/// Routes as walks (`WalkRouter.walk(of:)`): every bench walk holds together as Apple Maps'
/// fitted walks do, for everything that shows one.
@Suite(.serialized) struct WalkAssemblyTests {
    /// This suite's own router: a router's search scratch isn't shared between threads, and
    /// `WalkRouterTests`' runs alongside this suite.
    nonisolated(unsafe) static let router: WalkRouter? = WalkGraphTests.graph.map(WalkRouter.init)

    struct Bench: Decodable {
        let name: String
        let from: [Double]
        let to: [Double]
    }

    static let benches: [Bench] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/walkbench/walks.json")
        return (try? JSONDecoder().decode([Bench].self, from: Data(contentsOf: url))) ?? []
    }()

    func walk(_ bench: Bench, _ router: WalkRouter) throws -> Walk {
        let start = Walk.Point(lat: bench.from[0], lon: bench.from[1]), end = Walk.Point(lat: bench.to[0], lon: bench.to[1])
        let route = try #require(router.route(from: start, to: end), "\(bench.name)")
        return router.walk(of: route)
    }

    /// Each walk's steps, to read over: STEPS=1 swift test --filter WalkAssemblyTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STEPS"] != nil)) func stepsProbe() throws {
        let router = try #require(Self.router)
        for bench in Self.benches {
            let walk = try walk(bench, router)
            print("\n## \(bench.name): \(Int(walk.meters)) m, \(Int(walk.seconds / 60)) min")
            for step in walk.steps {
                if ProcessInfo.processInfo.environment["STEPS"] == "points" {
                    print("    " + step.points.map { String(format: "%.6f,%.6f", $0.lat, $0.lon) }.joined(separator: " "))
                }
                let light = step.light.map { " [\($0.tag)]" } ?? ""
                print("  \(step.turn) \(Int(step.meters)) m: \(step.instruction)\(light)")
            }
            for (index, crossing) in (walk.crossings ?? []).enumerated() {
                let street = walk.streets?[index] ?? ""
                print("    crossing \(street.isEmpty ? "?" : street) \(Int(Self.metres(crossing))) m \(walk.lights?[index].tag ?? "")")
            }
        }
    }

    /// Jogs in each walk: a turn off the way, a few metres, and back to it (JOGS=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JOGS"] != nil)) func jogsProbe() throws {
        let router = try #require(Self.router)
        let g = router.graph
        for bench in Self.benches {
            let start = Walk.Point(lat: bench.from[0], lon: bench.from[1]), end = Walk.Point(lat: bench.to[0], lon: bench.to[1])
            let route = try #require(router.route(from: start, to: end))
            // Each point of the route's line, with the leg it's from
            var labelled: [(Walk.Point, String)] = []
            for leg in route.legs {
                let label: String
                switch leg {
                case .access: label = "access"
                case let .side(block, left, _, _, _, _):
                    let f = g.flags(of: block)
                    label = "side \(g.name(of: block)) \(left ? "L" : "R") \(g.class(of: block))\(f.contains(.osmSidewalk) ? " osmSidewalk" : "")\(f.contains(.crosswalk) ? " crosswalk" : "")\(f.contains(.median) ? " median" : "")\(f.contains(.island) ? " island" : "")\(f.contains(.connector) ? " connector" : "")"
                case let .cross(node, arm, _, _):
                    label = "cross \(g.name(of: Int(g.armBlock[arm]))) kind \(g.kind(ofCorner: arm)) deg \(g.arms(of: node).count)"
                }
                for p in router.points(of: leg) { labelled.append((p, label)) }
            }
            var path: [(Walk.Point, String)] = []
            for item in labelled where path.last.map({ $0.0.metres(to: item.0) >= 0.3 }) ?? true { path.append(item) }
            func turn(_ a: Double, _ b: Double) -> Double { abs((b - a + 540).truncatingRemainder(dividingBy: 360) - 180) }
            var found = 0
            for i in 0..<max(0, path.count - 3) {
                let a = path[i].0, b = path[i + 1].0, c = path[i + 2].0, d = path[i + 3].0
                guard a.metres(to: b) > 1, d.metres(to: c) > 3, b.metres(to: c) < 60, b.metres(to: c) > 3 else { continue }
                let h1 = a.heading(to: b), h2 = b.heading(to: c), h3 = c.heading(to: d)
                guard turn(h1, h2) > 45, turn(h1, h3) < 30 else { continue }
                found += 1
                print("\(bench.name) jog \(Int(b.metres(to: c))) m at \(String(format: "%.5f,%.5f", b.lat, b.lon)): "
                      + "[\(path[i].1)] -> [\(path[i + 1].1)] -> [\(path[i + 2].1)] -> [\(path[i + 3].1)]")
            }
            print("\(bench.name): \(found) jogs")
        }
    }

    /// Crossings through a median that don't go on by a crosswalk (MEDIANS=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEDIANS"] != nil)) func mediansProbe() throws {
        let router = try #require(Self.router)
        let g = router.graph
        for bench in Self.benches {
            let start = Walk.Point(lat: bench.from[0], lon: bench.from[1]), end = Walk.Point(lat: bench.to[0], lon: bench.to[1])
            let route = try #require(router.route(from: start, to: end))
            func describe(_ leg: WalkRouter.Leg) -> String {
                switch leg {
                case let .access(a, b): return "access \(Int(a.metres(to: b))) m"
                case let .side(block, left, a, b, _, _):
                    let f = g.flags(of: block)
                    return "side '\(g.name(of: block))' \(left ? "L" : "R") \(g.class(of: block)) \(Int(a.metres(to: b))) m offset \(g.offset(of: block, left: left)) corners \(g.kind(ofCorner: g.sideCorners(of: block, left: left).from))/\(g.kind(ofCorner: g.sideCorners(of: block, left: left).to)) from \(String(format: "%.6f,%.6f", a.lat, a.lon)) to \(String(format: "%.6f,%.6f", b.lat, b.lon))"
                        + (f.contains(.osmSidewalk) ? " sidewalk" : "") + (f.contains(.crosswalk) ? " CROSSWALK bits \(g.crossing(of: block).rawValue)" : "")
                        + (f.contains(.median) ? " median" : "") + (f.contains(.island) ? " island" : "")
                case let .cross(node, arm, a, b):
                    let block = Int(g.armBlock[arm])
                    return "CROSS '\(g.name(of: block))' \(g.class(of: block)) \(Int(a.metres(to: b))) m corners \(g.kind(ofCorner: g.previous(arm, at: node)))/\(g.kind(ofCorner: arm)) at \(String(format: "%.6f,%.6f", a.lat, a.lon)) signal \(g.nodeSignal[node]) covered \(g.flags(of: block).contains(.coveredLeft))/\(g.flags(of: block).contains(.coveredRight))"
                }
            }
            for (i, leg) in route.legs.enumerated() {
                guard case let .side(block, _, _, _, _, _) = leg, g.flags(of: block).contains(.crosswalk) else { continue }
                // The next few legs: another crosswalk soon, or not
                let after = route.legs[(i + 1)..<min(route.legs.count, i + 4)]
                let city = after.contains { if case let .cross(_, arm, a, b) = $0 { return g.class(of: Int(g.armBlock[arm])) != .path && a.metres(to: b) > 3 } else { return false } }
                guard city else { continue }
                print("\n\(bench.name):")
                for j in max(0, i - 1)..<min(route.legs.count, i + 4) { print("   \(describe(route.legs[j]))") }
            }
        }
    }

    /// The OSM crosswalks and islands near a place (NEAR=lat,lon): each one's ends and what's at them.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEAR"] != nil)) func nearProbe() throws {
        let router = try #require(Self.router)
        let g = router.graph
        let c = (ProcessInfo.processInfo.environment["NEAR"] ?? "").split(separator: ",").compactMap { Double($0) }
        let here = Walk.Point(lat: c[0], lon: c[1])
        for block in 0..<g.blockCount {
            let line = g.line(of: block)
            guard let first = line.first, first.metres(to: here) < 45 || (line.last?.metres(to: here) ?? 99) < 45 else { continue }
            let f = g.flags(of: block)
            guard f.contains(.crosswalk) || f.contains(.island) || f.contains(.connector) || f.contains(.osmSidewalk) || g.class(of: block) == .walk else { continue }
            func end(_ node: Int) -> String {
                let arms = g.arms(of: node).map { arm -> String in
                    let b = Int(g.armBlock[arm]); let bf = g.flags(of: b)
                    let kind = bf.contains(.crosswalk) ? "xw" : bf.contains(.osmSidewalk) ? "sw" : bf.contains(.connector) ? "conn" : bf.contains(.island) ? "isl" : "\(g.class(of: b))"
                    return "\(g.name(of: b))(\(kind))"
                }
                let linked = g.arms(of: node).filter { g.cornerLink[$0] != WalkGraph.noLink }.count
                return "n\(node) [\(arms.joined(separator: ", "))] links \(linked)"
            }
            if g.class(of: block) == .walk {
                for left in [true, false] {
                    let (from, to) = g.sideCorners(of: block, left: left)
                    print("    \(left ? "L" : "R") offset \(g.offset(of: block, left: left)) covered \(g.isCovered(block, left: left)) unmapped \(g.isUnmapped(block, left: left)) corners \(g.kind(ofCorner: from))/\(g.kind(ofCorner: to)) median \(f.contains(.median)) width \(g.width(of: block)) oneWay \(f.contains(.oneWay))")
                }
            }
            let kind = f.contains(.crosswalk) ? "CROSSWALK \(g.crossing(of: block).rawValue)" : f.contains(.island) ? "ISLAND" : f.contains(.connector) ? "CONNECTOR" : f.contains(.osmSidewalk) ? "sidewalk" : "street"
            print("b\(block) \(kind) '\(g.name(of: block))' \(Int(g.length(of: block))) m: \(String(format: "%.6f,%.6f", first.lat, first.lon)) \(end(Int(g.blockA[block]))) -> \(end(Int(g.blockB[block])))")
        }
    }

    /// Each bench walk's metres and crossings, routed Balanced, for fitting the pace to Apple's
    /// times (PACE=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACE"] != nil)) func paceProbe() throws {
        let router = try #require(Self.router)
        for bench in Self.benches {
            let start = Walk.Point(lat: bench.from[0], lon: bench.from[1]), end = Walk.Point(lat: bench.to[0], lon: bench.to[1])
            let route = try #require(router.route(from: start, to: end))
            let walk = router.walk(of: route)
            let lights = walk.lights ?? []
            print("PACE \(bench.name) \(Int(walk.meters)) \(lights.filter(\.hasSignal).count) \(lights.filter { !$0.hasSignal }.count)")
        }
    }

    /// Each junction near a place (CORNERS=lat,lon): its arms clockwise, and each one's corner.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORNERS"] != nil)) func cornersProbe() throws {
        let router = try #require(Self.router)
        let g = router.graph
        let c = (ProcessInfo.processInfo.environment["CORNERS"] ?? "").split(separator: ",").compactMap { Double($0) }
        let here = Walk.Point(lat: c[0], lon: c[1])
        for node in 0..<g.nodeCount where g.point(ofNode: node).metres(to: here) < 25 {
            let p = g.point(ofNode: node)
            guard g.arms(of: node).contains(where: { g.class(of: Int(g.armBlock[$0])) == .walk }) else { continue }
            print("node \(String(format: "%.6f,%.6f", p.lat, p.lon))")
            for arm in g.arms(of: node) {
                let b = Int(g.armBlock[arm]), q = g.corner(arm)
                let (e, n) = q.offset(from: p)
                print("   arm \(g.name(of: b)) \(g.class(of: b)) median \(g.flags(of: b).contains(.median)) -> corner \(g.kind(ofCorner: arm)) \(Int(e)) m east \(Int(n)) m north")
            }
        }
    }

    static func metres(_ points: [Walk.Point]) -> Double {
        zip(points, points.dropFirst()).map { $0.metres(to: $1) }.reduce(0, +)
    }

    @Test func benchWalksHoldTogether() throws {
        let router = try #require(Self.router, "ios/App/walkgraph.sqlite")
        #expect(Self.benches.count >= 20)
        for bench in Self.benches {
            let walk = try walk(bench, router)
            let path = walk.points
            let onPath = Set(path)
            let crossings = walk.crossings ?? []
            // A light and a street for each crossing, and every crossing on the path
            #expect(walk.lights?.count == crossings.count, "\(bench.name)")
            #expect(walk.streets?.count == crossings.count, "\(bench.name)")
            for crossing in crossings {
                #expect(crossing.count >= 2 && crossing.allSatisfy(onPath.contains), "\(bench.name): crossing off the path")
            }
            // As long as its path, and as long as its steps say
            #expect(abs(walk.meters - Self.metres(path)) < 1, "\(bench.name): \(walk.meters) vs \(Self.metres(path))")
            // (a crossing whose path is the way over has none: it's done where it starts)
            #expect(abs(walk.steps.map { Self.metres($0.points) }.reduce(0, +) - walk.meters) < 1, "\(bench.name)")
            for step in walk.steps where step.turn == .cross && step.points.last == step.crossing?.last {
                #expect(step.meters == 0, "\(bench.name): \(step.instruction) \(step.meters) m on")
            }
            // Each step joining on to the last, with something to walk
            for (step, next) in zip(walk.steps, walk.steps.dropFirst()) {
                #expect(step.points.last == next.points.first, "\(bench.name): steps apart at \(step.instruction)")
            }
            for step in walk.steps {
                #expect(step.points.count >= 2 && Self.metres(step.points) > 0.5, "\(bench.name): empty step \(step.instruction)")
            }
            // Turns onto a street by its name; the last arriving
            #expect(walk.steps.last?.turn == .arrive, "\(bench.name)")
            for step in walk.steps.dropLast() where step.turn != .cross {
                let onto = step.instruction.contains(" onto the path") || step.instruction.hasSuffix("the stairs")
                    || Walk.street(in: step.instruction) != nil
                #expect(onto || step.instruction == "Continue", "\(bench.name): \(step.instruction)")
            }
            for step in walk.steps where step.turn == .cross {
                #expect(step.instruction.hasPrefix("Cross ") && step.light != nil, "\(bench.name): \(step.instruction)")
            }
        }
    }

    /// 4th Ave's a divided road: crossing it, at 9th St on one crosswalk, at 17th St on two
    /// with an island between, is one crossing either way.
    @Test func aDividedRoadIsCrossedOnce() throws {
        let router = try #require(Self.router, "ios/App/walkgraph.sqlite")
        for (start, end) in [(Walk.Point(lat: 40.67065, lon: -73.98960), Walk.Point(lat: 40.67175, lon: -73.98700)),
                             (Walk.Point(lat: 40.6628, lon: -73.9933), Walk.Point(lat: 40.6740, lon: -73.9960))] {
            let walk = router.walk(of: try #require(router.route(from: start, to: end)))
            let overFourth = (walk.streets ?? []).filter { $0 == "4th Ave" }
            #expect(overFourth.count == 1, "\(walk.streets ?? [])")
        }
    }

    /// A turn's read past a jog at the corner with a longer reach, the same as before with the
    /// 5 m one Apple Maps' walks use.
    @Test func turnsLookPastAJog() {
        func p(_ east: Double, _ north: Double) -> Walk.Point {
            Walk.Point(lat: 40.7 + north / 111_320, lon: -74.0 + east / (111_320 * cos(40.7 * .pi / 180)))
        }
        // East 40 m, a 6 m jog south at the corner, then north
        let came = [p(-40, 0), p(0, 0)]
        let went = [p(0, 0), p(0, -6), p(0, 40)]
        #expect(Walk.turn(from: came, onto: went, reach: 20) == .left)
        #expect(Walk.turn(from: came, onto: went) == .right)
    }

    /// Every crossing goes straight over: never into a median and off at an angle from it.
    @Test func crossingsGoStraightOver() throws {
        let router = try #require(Self.router, "ios/App/walkgraph.sqlite")
        for bench in Self.benches {
            let walk = try walk(bench, router)
            for (index, crossing) in (walk.crossings ?? []).enumerated() {
                guard let first = crossing.first, let last = crossing.last, first != last else { continue }
                let off = crossing.map { $0.nearest(from: first, to: last).gap }.max() ?? 0
                #expect(off < 5, "\(bench.name): \(walk.streets?[index] ?? "?") bends \(Int(off)) m off its line")
            }
        }
    }

    /// Crossings meet the sidewalk square on the Prospect Av to Lowe's walk: off each end a
    /// corner and the sidewalk's line, never the bits at an angle between that OSM draws from
    /// its sidewalks' middles to its crosswalks.
    @Test func crossingsMeetTheSidewalkSquare() throws {
        let router = try #require(Self.router, "ios/App/walkgraph.sqlite")
        let walk = try walk(Bench(name: "lowes", from: [40.665299, -73.992729], to: [40.6718, -73.9957]), router)
        let path = walk.steps.flatMap(\.points).reduce(into: [Walk.Point]()) { if $0.last != $1 { $0.append($1) } }
        let onCrossings = Set((walk.crossings ?? []).flatMap { $0.map { "\($0.lat),\($0.lon)" } })
        for (index, crossing) in (walk.crossings ?? []).enumerated() {
            for end in [crossing.first, crossing.last].compactMap({ $0 }) {
                // Not by the walk's own ends, off the sidewalk to a station's stairs or a door
                guard let at = path.firstIndex(of: end), let first = path.first, let last = path.last,
                      end.metres(to: first) > 15, end.metres(to: last) > 15 else { continue }
                // Points off this end, away from the crossing, within 8 m of it and on none
                let away = crossing.first == end ? -1 : 1
                var near = 0
                var next = at + away
                while path.indices.contains(next), path[next].metres(to: end) < WalkRouter.cornerReach, !crossing.contains(path[next]) {
                    if !onCrossings.contains("\(path[next].lat),\(path[next].lon)") { near += 1 }
                    next += away
                }
                #expect(near <= 1, "\(walk.streets?[index] ?? "?"): \(near) bits off its end")
            }
        }
    }

    /// A walk starts on the sidewalk it starts on: not along a line through the block, or over
    /// the street to the other side.
    @Test func startsOnItsOwnSidewalk() throws {
        let router = try #require(Self.router, "ios/App/walkgraph.sqlite")
        // On 9th St's sidewalk, by 4th Ave
        let route = try #require(router.route(from: Walk.Point(lat: 40.67065, lon: -73.98960),
                                              to: Walk.Point(lat: 40.67175, lon: -73.98700)))
        guard case let .access(from, to) = route.legs.first else { Issue.record("starts \(String(describing: route.legs.first))"); return }
        #expect(from.metres(to: to) < 5)
    }

    /// Over the Brooklyn Bridge, its walkway named two ways (OSM's "Bridge", the city's
    /// "Brdg"): one step along it, by the name written out.
    @Test func aPathSpelledTwoWaysIsOneStep() throws {
        let router = try #require(Self.router, "ios/App/walkgraph.sqlite")
        let route = try #require(router.route(from: Walk.Point(lat: 40.7127, lon: -74.0059), to: Walk.Point(lat: 40.6994, lon: -73.9903)))
        let onto = router.walk(of: route).steps.compactMap { Walk.street(in: $0.instruction) }
        #expect(onto.filter { $0.hasPrefix("Brooklyn Br") } == ["Brooklyn Bridge Pedestrian Path"], "\(onto)")
    }

    /// Up the stairs from Broadway to Wadsworth Ter: a step of their own, as Apple Maps has.
    @Test func stairsAreSaid() throws {
        let router = try #require(Self.router, "ios/App/walkgraph.sqlite")
        let route = try #require(router.route(from: Walk.Point(lat: 40.8565, lon: -73.9340), to: Walk.Point(lat: 40.8545, lon: -73.9280)))
        let steps = router.walk(of: route).steps
        let stairs = try #require(steps.firstIndex { $0.instruction.hasSuffix("the stairs") }, "\(steps.map(\.instruction))")
        // The step after them up them, to the street at the top
        #expect(steps.indices.contains(stairs + 1))
        #expect(Walk.street(in: steps[stairs + 1].instruction) == "Wadsworth Ter")
    }

    /// Across Central Park, a crosswalk OSM names for Strawberry Fields isn't a street crossed.
    @Test func placesArentStreetsCrossed() throws {
        let router = try #require(Self.router, "ios/App/walkgraph.sqlite")
        let route = try #require(router.route(from: Walk.Point(lat: 40.7765, lon: -73.9760), to: Walk.Point(lat: 40.7728, lon: -73.9665)))
        let streets = router.walk(of: route).streets ?? []
        #expect(!streets.contains("Strawberry Fields"), "\(streets)")
        #expect(streets.contains("Central Park W"))
    }

    /// A route along one street and onto another: a step each, the turn said by name.
    @Test func turnsAreSaidByName() throws {
        let router = try #require(Self.router, "ios/App/walkgraph.sqlite")
        let bench = try #require(Self.benches.first { $0.name == "midtown" })
        let walk = try walk(bench, router)
        let streets = walk.steps.compactMap { Walk.street(in: $0.instruction) }
        #expect(!streets.isEmpty)
        #expect(streets.allSatisfy { $0.first?.isUppercase == true || $0.first?.isNumber == true })
        #expect(!streets.contains { $0.contains("AVE") || $0.contains(" ST") }, "names as read: \(streets)")
    }
}
