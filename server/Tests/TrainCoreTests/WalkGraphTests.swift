import Foundation
import Testing
@testable import TrainCore

/// The walking graph as the app bundles it (ios/App/walkgraph.sqlite, `tools/make_walk_graph.py`):
/// read whole, its conventions held everywhere, and the places checked by eye in its debug
/// maps as they were.
@Suite struct WalkGraphTests {
    /// The bundled graph, read once for all the tests.
    static let graph: WalkGraph? = {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ios/App/walkgraph.sqlite")
        guard let database = try? SQLite(path: file.path),
              let format = try? database.query("SELECT value FROM info WHERE key = 'format'").first?.first?.text,
              format == WalkGraph.format,
              let rows = try? database.query("SELECT name, data FROM arrays"),
              let labels = try? database.query("SELECT id, label FROM names") else { return nil }
        var arrays: [String: Data] = [:]
        for row in rows {
            if let name = row[0].text, let data = row[1].blob { arrays[name] = data }
        }
        var names: [Int: String] = [:]
        for row in labels {
            if let id = row[0].integer, let label = row[1].text { names[Int(id)] = label }
        }
        return try? WalkGraph(arrays: arrays, names: names)
    }()

    func graph() throws -> WalkGraph {
        try #require(Self.graph, "ios/App/walkgraph.sqlite in format \(WalkGraph.format) (tools/make_walk_graph.py)")
    }

    /// Metres east and north from `a` to `b`, as the graph's plane has them.
    func offset(_ a: Walk.Point, _ b: Walk.Point) -> (x: Double, y: Double) {
        ((b.lon - a.lon) * WalkGraph.metresEast, (b.lat - a.lat) * WalkGraph.metresNorth)
    }

    /// The junctions within `metres` of `point`.
    func nodes(_ graph: WalkGraph, near point: Walk.Point, within metres: Double) -> [Int] {
        (0..<graph.nodeCount).filter { graph.point(ofNode: $0).metres(to: point) <= metres }
    }

    /// The blocks named `name` with a point within `metres` of `point`.
    func blocks(_ graph: WalkGraph, named name: String, near point: Walk.Point, within metres: Double) -> [Int] {
        (0..<graph.blockCount).filter { block in
            graph.name(of: block) == name && graph.line(of: block).contains { $0.metres(to: point) <= metres }
        }
    }

    @Test func itReadsWhole() throws {
        let graph = try graph()
        #expect(graph.nodeCount > 100_000)
        #expect(graph.blockCount > 150_000)
        #expect(graph.armStart.count == graph.nodeCount + 1)
        #expect(graph.geomStart.count == graph.blockCount + 1)
        #expect(Int(graph.armStart.last!) == graph.armBlock.count)
        #expect(graph.cornerKind.count == graph.armBlock.count)
        // Every block is an arm at both its ends, in its slot
        for block in stride(from: 0, to: graph.blockCount, by: 97) {
            for end in 0...1 {
                let arm = graph.arm(of: block, end: end)
                #expect(Int(graph.armBlock[arm]) == block && Int(graph.armEnd[arm]) == end)
            }
        }
    }

    /// Each block's line starts at its first junction and ends at its second.
    @Test func linesRunFromJunctionToJunction() throws {
        let graph = try graph()
        for block in stride(from: 0, to: graph.blockCount, by: 53) {
            let line = graph.line(of: block)
            #expect(line.count >= 2)
            #expect(line[0].metres(to: graph.point(ofNode: Int(graph.blockA[block]))) < 0.3)
            #expect(line[line.count - 1].metres(to: graph.point(ofNode: Int(graph.blockB[block]))) < 0.3)
            let along = zip(line, line.dropFirst()).map { $0.metres(to: $1) }.reduce(0, +)
            #expect(abs(along - graph.length(of: block)) < max(1, along * 0.02))
        }
    }

    /// A street's left-side corners are on its left, its right-side ones on its right, going
    /// from its start to its end: the convention walking a side and crossing rest on.
    @Test func sidesAreOnTheirSides() throws {
        let graph = try graph()
        var checked = 0, wrong = 0
        for block in stride(from: 0, to: graph.blockCount, by: 11) where graph.class(of: block) == .walk {
            let line = graph.line(of: block)
            guard line.count >= 2, graph.length(of: block) > 20 else { continue }
            for left in [true, false] {
                let (from, to) = graph.sideCorners(of: block, left: left)
                for (corner, end) in [(from, 0), (to, 1)] where graph.kind(ofCorner: corner) == .sidewalk {
                    // Against the block's direction at that end
                    let a = end == 0 ? line[0] : line[line.count - 2], b = end == 0 ? line[1] : line[line.count - 1]
                    let along = offset(a, b), out = offset(end == 0 ? line[0] : line[line.count - 1], graph.corner(corner))
                    let cross = along.x * out.y - along.y * out.x
                    checked += 1
                    if (cross > 0) != left { wrong += 1 }
                }
            }
        }
        #expect(checked > 10_000)
        #expect(Double(wrong) < Double(checked) * 0.02, "\(wrong) of \(checked) corners on the wrong side")
    }

    /// Most corners between two streets are on a sidewalk.
    @Test func cornersAreOnSidewalks() throws {
        let graph = try graph()
        var between = 0, onSidewalk = 0
        for node in 0..<graph.nodeCount {
            for arm in graph.arms(of: node) {
                let next = graph.next(arm, at: node)
                guard arm != next, graph.class(of: Int(graph.armBlock[arm])) == .walk,
                      graph.class(of: Int(graph.armBlock[next])) == .walk else { continue }
                between += 1
                if graph.kind(ofCorner: arm) != .none { onSidewalk += 1 }
            }
        }
        #expect(Double(onSidewalk) > Double(between) * 0.85, "\(onSidewalk) of \(between) corners on a sidewalk or median")
    }

    /// 4 Av at 9 St in Park Slope: two halves either side of a median, each junction signalled,
    /// joined by a median link with refuges beside it.
    @Test func fourthAvenueIsDivided() throws {
        let graph = try graph()
        let corner = Walk.Point(lat: 40.670325, lon: -73.988647)
        let links = blocks(graph, named: "9 ST", near: corner, within: 40).filter { graph.flags(of: $0).contains(.median) }
        let link = try #require(links.first, "no median link on 9 St at 4 Av")
        for end in 0...1 {
            let arm = graph.arm(of: link, end: end)
            let node = graph.node(ofArm: arm)
            #expect(graph.nodeSignal[node] != 0, "4 Av at 9 St's not signalled")
            #expect(graph.arms(of: node).count == 4)
            #expect(graph.arms(of: node).contains { graph.name(of: Int(graph.armBlock[$0])) == "4 AVE" })
            // The corners beside the link are in the median
            #expect(graph.kind(ofCorner: arm) == .refuge || graph.kind(ofCorner: arm) == .sidewalk)
            #expect(graph.kind(ofCorner: graph.previous(arm, at: node)) != .none)
        }
    }

    /// The Gowanus Expressway: never walked along, not joined to the streets under it, and
    /// over 3 Av, whose halves are divided under it.
    @Test func theGowanusIsOverhead() throws {
        let graph = try graph()
        let under = Walk.Point(lat: 40.66164, lon: -74.00000)
        let expressway = blocks(graph, named: "GOWANUS EXPY", near: under, within: 60)
        #expect(!expressway.isEmpty)
        #expect(expressway.allSatisfy { graph.class(of: $0) == .arm })
        for block in expressway {
            for node in [Int(graph.blockA[block]), Int(graph.blockB[block])] {
                #expect(graph.arms(of: node).allSatisfy { graph.class(of: Int(graph.armBlock[$0])) == .arm },
                        "the expressway meets a street at \(graph.point(ofNode: node))")
            }
        }
        let thirdAvenue = blocks(graph, named: "3 AVE", near: under, within: 60)
        #expect(thirdAvenue.contains { graph.flags(of: $0).contains(.underElevated) })
    }

    /// Hamilton Ave's ramps onto the expressway are crossed, never walked along.
    @Test func rampsAreOnlyCrossed() throws {
        let graph = try graph()
        let ramps = (0..<graph.blockCount).filter { graph.blockRW[$0] == 9 }
        #expect(ramps.count > 2_000)
        #expect(ramps.allSatisfy { graph.class(of: $0) == .arm })
    }

    /// The Brooklyn Bridge's walkway is a path in the city's main walkable part, and so are
    /// Central Park's paths (from OSM).
    @Test func bridgesAndParksAreJoinedUp() throws {
        let graph = try graph()
        let walkway = (0..<graph.blockCount).filter { graph.name(of: $0) == "BROOKLYN BRIDGE PEDESTRIAN PATH" }
        #expect(!walkway.isEmpty)
        #expect(walkway.allSatisfy { graph.class(of: $0) == .path && graph.nodePart[Int(graph.blockA[$0])] == 0 })
        let bowBridge = Walk.Point(lat: 40.7758, lon: -73.9718)
        let park = nodes(graph, near: bowBridge, within: 150)
        #expect(park.contains { graph.nodePart[$0] == 0 && graph.arms(of: $0).contains {
            graph.flags(of: Int(graph.armBlock[$0])).contains(.fromOSM) } })
    }
}
