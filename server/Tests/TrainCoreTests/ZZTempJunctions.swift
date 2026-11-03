import Foundation
import Testing
@testable import TrainCore

// TEMPORARY probe (delete): junction points by the names of their streets.
@Suite struct ZZTempJunctions {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JUNCTIONS"] != nil)) func junctions() throws {
        let g = try #require(WalkGraphTests.graph)
        let wanted = (ProcessInfo.processInfo.environment["JUNCTIONS"] ?? "").split(separator: ";").map {
            Set($0.split(separator: "&").map { String($0) })
        }
        for node in 0..<g.nodeCount {
            let names = Set(g.arms(of: node).map { g.name(of: Int(g.armBlock[$0])) })
            for want in wanted where want.isSubset(of: names) {
                let p = g.point(ofNode: node)
                print("junction \(want.sorted()) \(p.lat),\(p.lon) arms \(names.sorted())")
            }
        }
    }
}
