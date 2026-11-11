import Foundation
import Testing
@testable import TrainCore

/// Walks across the whole city at noon and at 11 pm, Balanced and Safest, to see what the
/// night costs do everywhere: how often a walk changes, how much longer it gets, and how much
/// crime, dark path and empty street it gets out of. tools/night_fairness.py groups them by
/// how much crime there is round each walk, to check no part of town is walked round.
///
///     NIGHTFAIR=1 swift test --filter NightFairness
///
/// walks.json goes to ~/Desktop/Leeway walk bench/night/fairness (or NIGHTFAIR_OUT).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NIGHTFAIR"] != nil))
struct NightFairness {
    static let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NIGHTFAIR_OUT"]
        ?? NSHomeDirectory() + "/Desktop/Leeway walk bench/night/fairness")
    static let count = ProcessInfo.processInfo.environment["NIGHTFAIR_COUNT"].flatMap(Int.init) ?? 400

    struct Result: Encodable {
        let from: [Double], to: [Double], preference: String
        let noon: Measure, late: Measure
        let changed: Bool
        /// Said to go "via safer streets" at 11 pm.
        let saferAtNight: Bool
    }

    /// A route as the night sees it, at 11 pm whenever it's walked.
    struct Measure: Encodable {
        let metres: Double, seconds: Double, unsignalled: Int
        /// Crimes over the neighbours' late, by metres walked (per 100 m × metres / 100), and
        /// at the corners crossed.
        let crime: Double, cornerCrime: Double
        let darkMetres: Double, quietMetres: Double
    }

    @Test func fairness() throws {
        let router = try #require(WalkRouterTests.router, "ios/App/walkgraph.sqlite")
        let g = router.graph
        // Starts at junctions on the ground in the city's one walkable whole, ends 500–2,000 m off
        let junctions = (0..<g.nodeCount).filter { g.nodeLevel[$0] == WalkGraph.grade && g.nodePart[$0] == 0 && g.arms(of: $0).count >= 3 }
        var seed: UInt64 = 20261109
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var results: [Result] = []
        var tries = 0
        while results.count < Self.count * 2 && tries < Self.count * 4 {
            tries += 1
            let start = g.point(ofNode: junctions[Int(random() * Double(junctions.count))])
            let metres = 500 + random() * 1500, bearing = random() * 2 * .pi
            let end = Walk.Point(lat: start.lat + metres * cos(bearing) / WalkGraph.metresNorth,
                                 lon: start.lon + metres * sin(bearing) / WalkGraph.metresEast)
            for preference in [WalkPreference.balanced, .safest] {
                var options = WalkRouter.Options(preference: preference)
                options.time = .init(hour: 12)
                guard let noon = router.route(from: start, to: end, options: options) else { continue }
                options.time = .init(hour: 23)
                guard let late = router.route(from: start, to: end, options: options) else { continue }
                results.append(Result(from: [start.lat, start.lon], to: [end.lat, end.lon], preference: preference.rawValue,
                                      noon: measure(noon, g), late: measure(late, g),
                                      changed: router.points(of: noon) != router.points(of: late),
                                      saferAtNight: late.stats.saferAtNight))
            }
        }
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try encoder.encode(results).write(to: Self.output.appendingPathComponent("walks.json"))
        print("night fairness: \(results.count) routes to \(Self.output.path)")
        #expect(results.count >= Self.count)
    }

    func measure(_ route: WalkRouter.Route, _ g: WalkGraph) -> Measure {
        var crime = 0.0, cornerCrime = 0.0, dark = 0.0, quiet = 0.0
        for leg in route.legs {
            switch leg {
            case let .side(block, _, from, to, _, _):
                let metres = from.metres(to: to)
                if g.flags(of: block).contains(.crosswalk) {
                    cornerCrime += g.crime(of: block, in: .late)
                    continue
                }
                crime += g.crime(of: block, in: .late) * metres / 100
                if g.night(of: block).contains(.dark) { dark += metres }
                if (g.class(of: block) == .walk || g.flags(of: block).contains(.osmSidewalk)) && g.shops(of: block) == 0 {
                    quiet += metres
                }
            case let .cross(node, _, _, _):
                cornerCrime += g.crime(ofNode: node, in: .late)
            case .access:
                break
            }
        }
        return Measure(metres: route.stats.metres, seconds: route.stats.seconds, unsignalled: route.stats.unsignalled,
                       crime: crime, cornerCrime: cornerCrime, darkMetres: dark, quietMetres: quiet)
    }
}
