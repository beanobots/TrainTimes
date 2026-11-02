import Foundation
import Testing
@testable import TrainCore

/// Routes as walks (`WalkRouter.walk(of:)`): every bench walk holds together as Apple Maps'
/// fitted walks do, for everything that shows one.
@Suite(.serialized) struct WalkAssemblyTests {
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
        let router = try #require(WalkRouterTests.router)
        for bench in Self.benches {
            let walk = try walk(bench, router)
            print("\n## \(bench.name): \(Int(walk.meters)) m, \(Int(walk.seconds / 60)) min")
            for step in walk.steps {
                let light = step.light.map { " [\($0.tag)]" } ?? ""
                print("  \(step.turn) \(Int(step.meters)) m: \(step.instruction)\(light)")
            }
            for (index, crossing) in (walk.crossings ?? []).enumerated() {
                let street = walk.streets?[index] ?? ""
                print("    crossing \(street.isEmpty ? "?" : street) \(Int(Self.metres(crossing))) m \(walk.lights?[index].tag ?? "")")
            }
        }
    }

    static func metres(_ points: [Walk.Point]) -> Double {
        zip(points, points.dropFirst()).map { $0.metres(to: $1) }.reduce(0, +)
    }

    @Test func benchWalksHoldTogether() throws {
        let router = try #require(WalkRouterTests.router, "ios/App/walkgraph.sqlite")
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
            #expect(abs(walk.steps.map(\.meters).reduce(0, +) - walk.meters) < 1, "\(bench.name)")
            // Each step joining on to the last, with something to walk
            for (step, next) in zip(walk.steps, walk.steps.dropFirst()) {
                #expect(step.points.last == next.points.first, "\(bench.name): steps apart at \(step.instruction)")
            }
            for step in walk.steps {
                #expect(step.points.count >= 2 && step.meters > 0.5, "\(bench.name): empty step \(step.instruction)")
            }
            // Turns onto a street by its name; the last arriving
            #expect(walk.steps.last?.turn == .arrive, "\(bench.name)")
            for step in walk.steps.dropLast() where step.turn != .cross {
                let onto = step.instruction.contains(" onto the path") || Walk.street(in: step.instruction) != nil
                #expect(onto || step.instruction == "Continue", "\(bench.name): \(step.instruction)")
            }
            for step in walk.steps where step.turn == .cross {
                #expect(step.instruction.hasPrefix("Cross ") && step.light != nil, "\(bench.name): \(step.instruction)")
            }
        }
    }

    /// 4th Ave's a divided road: crossing it, through its median, is one crossing, with one light.
    @Test func aDividedRoadIsCrossedOnce() throws {
        let router = try #require(WalkRouterTests.router, "ios/App/walkgraph.sqlite")
        // Along 9th St, west of 4th Ave to east of it
        let route = try #require(router.route(from: Walk.Point(lat: 40.67065, lon: -73.98960),
                                              to: Walk.Point(lat: 40.67175, lon: -73.98700)))
        let walk = router.walk(of: route)
        let overFourth = (walk.streets ?? []).filter { $0 == "4th Ave" }
        #expect(overFourth.count == 1, "\(walk.streets ?? [])")
        if let index = walk.streets?.firstIndex(of: "4th Ave"), let crossing = walk.crossings?[index] {
            #expect(crossing.count >= 3, "through the median")
            #expect(walk.lights?[index].hasSignal == true)
        }
    }

    /// A route along one street and onto another: a step each, the turn said by name.
    @Test func turnsAreSaidByName() throws {
        let router = try #require(WalkRouterTests.router, "ios/App/walkgraph.sqlite")
        let bench = try #require(Self.benches.first { $0.name == "parkslope-4av" })
        let walk = try walk(bench, router)
        let streets = walk.steps.compactMap { Walk.street(in: $0.instruction) }
        #expect(!streets.isEmpty)
        #expect(streets.allSatisfy { $0.first?.isUppercase == true || $0.first?.isNumber == true })
        #expect(!streets.contains { $0.contains("AVE") || $0.contains(" ST") }, "names as read: \(streets)")
    }
}
