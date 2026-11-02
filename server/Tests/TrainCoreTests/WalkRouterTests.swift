import Foundation
import Testing
@testable import TrainCore

/// Walks routed on the bundled walking graph (`WalkRouter`), at the places the router was
/// made for: keeping off Hamilton Ave's ramps, over a bridge's walkway, through a park.
@Suite(.serialized) struct WalkRouterTests {
    /// One router for all the tests, on the bundled graph.
    static let router: WalkRouter? = WalkGraphTests.graph.map(WalkRouter.init)

    func router() throws -> WalkRouter {
        try #require(Self.router, "ios/App/walkgraph.sqlite (tools/make_walk_graph.py)")
    }

    /// The blocks a route walks along or crosses, by name.
    func names(_ route: WalkRouter.Route, _ router: WalkRouter) -> [String] {
        route.legs.compactMap { leg -> String? in
            switch leg {
            case let .side(block, _, _, _, _, _): router.graph.name(of: block)
            case let .cross(_, arm, _, _): router.graph.name(of: Int(router.graph.armBlock[arm]))
            case .access: nil
            }
        }
    }

    func describe(_ label: String, _ route: WalkRouter.Route?, _ router: WalkRouter) -> String {
        guard let route else { return "\(label): no route" }
        let s = route.stats
        var streets: [String] = []
        for name in names(route, router) where streets.last != name { streets.append(name) }
        return "\(label): \(Int(s.metres)) m, \(Int(s.seconds / 60)) min (fastest \(Int(s.fastestSeconds / 60))), "
            + "\(s.crossings) crossings, \(s.unsignalled) unsignalled, \(s.unsignalledWide) wide, \(s.ramps) ramps, "
            + "weight \(s.weight) | \(streets.prefix(14).joined(separator: " > "))"
    }

    @Test func explore() throws {
        let router = try router()
        let walks: [(String, Walk.Point, Walk.Point)] = [
            ("19 St to Smith-9 Sts", Walk.Point(lat: 40.6628, lon: -73.9933), Walk.Point(lat: 40.6740, lon: -73.9960)),
            ("19 St to Carroll Gdns", Walk.Point(lat: 40.6628, lon: -73.9933), Walk.Point(lat: 40.6790, lon: -73.9990)),
            ("9 St to 4 Av stairs", Walk.Point(lat: 40.669173, lon: -73.986304), Walk.Point(lat: 40.670405, lon: -73.988487)),
            ("Brooklyn Bridge", Walk.Point(lat: 40.6995, lon: -73.9900), Walk.Point(lat: 40.7128, lon: -74.0060)),
            ("Central Park 72 St", Walk.Point(lat: 40.7730, lon: -73.9665), Walk.Point(lat: 40.7765, lon: -73.9760)),
        ]
        for (label, start, end) in walks {
            for preference in WalkPreference.allCases {
                let began = Date()
                let route = router.route(from: start, to: end, options: .init(preference: preference))
                print(describe("\(label) [\(preference)] \(Int(Date().timeIntervalSince(began) * 1000)) ms", route, router))
            }
        }
    }
}
