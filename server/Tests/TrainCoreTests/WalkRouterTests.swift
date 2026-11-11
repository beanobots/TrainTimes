import Foundation
import Testing
@testable import TrainCore

/// Walks routed on the bundled walking graph (`WalkRouter`), at the places the router was
/// made for: keeping off Hamilton Ave's ramps, over a bridge's walkway, through a park.
@Suite(.serialized) struct WalkRouterTests {
    /// One router for all the tests, on the bundled graph: its search scratch isn't shared
    /// between threads, and these tests run one at a time.
    nonisolated(unsafe) static let router: WalkRouter? = WalkGraphTests.graph.map(WalkRouter.init)

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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGS"] != nil)) func legsProbe() throws {
        let router = try router()
        // LEGS="lat,lon,lat,lon" for the walk to look at
        let c = (ProcessInfo.processInfo.environment["LEGS"] ?? "").split(separator: ",").compactMap { Double($0) }
        let (start, end) = c.count == 4 ? (Walk.Point(lat: c[0], lon: c[1]), Walk.Point(lat: c[2], lon: c[3]))
            : (Walk.Point(lat: 40.6628, lon: -73.9933), Walk.Point(lat: 40.6740, lon: -73.9960))
        let route = try #require(router.route(from: start, to: end))
        for leg in route.legs {
            switch leg {
            case let .access(a, b): print("access", Int(a.metres(to: b)))
            case let .side(block, left, from, to, fa, ta):
                print("side", router.graph.name(of: block), left ? "L" : "R", Int(from.metres(to: to)), "m", Int(fa), "->", Int(ta),
                      "len", Int(router.graph.length(of: block)), "class", router.graph.class(of: block), "deg", router.graph.arms(of: Int(router.graph.blockA[block])).count, router.graph.arms(of: Int(router.graph.blockB[block])).count)
            case let .cross(node, arm, from, to):
                let b = Int(router.graph.armBlock[arm])
                print("cross", router.graph.name(of: b), Int(from.metres(to: to)), "m", "deg", router.graph.arms(of: node).count,
                      "kinds", router.graph.kind(ofCorner: arm), "class", router.graph.class(of: b), "rw", router.graph.blockRW[b],
                      "level", router.graph.nodeLevel[node], "signal", router.graph.nodeSignal[node], "at", from,
                      "arms", router.graph.arms(of: node).map { router.graph.name(of: Int(router.graph.armBlock[$0])) })
            }
        }
    }

    /// Each preference's route for a walk (PREFS=lat,lon,lat,lon), or that there's none.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PREFS"] != nil)) func prefsProbe() throws {
        let router = try router()
        let c = (ProcessInfo.processInfo.environment["PREFS"] ?? "").split(separator: ",").compactMap { Double($0) }
        for preference in WalkPreference.allCases {
            for stepFree in [false, true] {
                print("PREF", preference, stepFree, describe("\(preference)", router.route(from: Walk.Point(lat: c[0], lon: c[1]), to: Walk.Point(lat: c[2], lon: c[3]), options: .init(preference: preference, stepFree: stepFree)), router))
            }
        }
    }

    /// The safety data costs what it should: a priority intersection, its crashes (capped), and
    /// no curb ramp only when step-free.
    @Test func safetyDataAddsToACrossing() throws {
        let router = try router()
        let plain = WalkRouter.Crossing(width: 10, lanes: 1, speed: 25, twoWay: false, flags: [], signal: .signal, fixed: WalkCosts.fixed)
        var priority = plain
        priority.priority = true
        var crashes = plain
        crashes.crashes = 100
        var noRamp = plain
        noRamp.noRamp = true
        let base = router.cost(of: plain, weight: 1)
        #expect(abs(router.cost(of: priority, weight: 1) - base - WalkCosts.priorityIntersection) < 0.01)
        #expect(abs(router.cost(of: crashes, weight: 1) - base
            - WalkCosts.perCrash * Double(WalkCosts.crashesAtMost)) < 0.01)
        #expect(router.cost(of: noRamp, weight: 1) == base)
        #expect(abs(router.cost(of: noRamp, weight: 1, stepFree: true) - base - WalkCosts.noRamp) < 0.01)
    }

    /// The safety data's in the graph: priority intersections, crashes, ramps at most corners,
    /// priority corridors.
    @Test func safetyDataIsThere() throws {
        let g = try router().graph
        let priority = (0..<g.nodeCount).filter { g.safety(ofNode: $0).contains(.priority) }.count
        let hurt = g.nodeCrashes.filter { $0 > 0 }.count
        let sidewalkCorners = (0..<g.armBlock.count).filter { g.kind(ofCorner: $0) == .sidewalk }
        let ramped = sidewalkCorners.filter(g.hasRamp).count
        let corridor = (0..<g.blockCount).filter { g.safety(of: $0).contains(.corridor) }.count
        print("safety: \(priority) priority junctions, \(hurt) with crashes, \(ramped)/\(sidewalkCorners.count) corners ramped, \(corridor) corridor blocks")
        #expect(priority > 300)
        #expect(hurt > 10_000)
        #expect(Double(ramped) > Double(sidewalkCorners.count) * 0.5)
        #expect(corridor > 10_000)
    }

    /// The night data's in the graph: crime over the neighbours' on blocks and corners at each
    /// part of the day, shops along streets, dark and park paths.
    @Test func nightDataIsThere() throws {
        let g = try router().graph
        let blocks = WalkGraph.Band.allCases.map { band in g.blockCrime[band.rawValue].filter { $0 > 0 }.count }
        let corners = WalkGraph.Band.allCases.map { band in g.nodeCrime[band.rawValue].filter { $0 > 0 }.count }
        let shops = g.blockShops.filter { $0 > 0 }.count
        let dark = (0..<g.blockCount).filter { g.night(of: $0).contains(.dark) }.count
        let parks = (0..<g.blockCount).filter { g.night(of: $0).contains(.park) }.count
        print("night: blocks over \(blocks), corners over \(corners), \(shops) with shops, \(dark) dark, \(parks) in parks")
        #expect(blocks.allSatisfy { $0 > 30_000 })
        #expect(corners.allSatisfy { $0 > 3_000 })
        #expect(shops > 50_000)
        #expect(dark > 10_000)
        #expect(parks > 10_000)
    }

    /// The parts of the day, by the hour in New York; parks shut 1–6.
    @Test func walkTimesByTheHour() throws {
        typealias Time = WalkRouter.Options.Time
        #expect(Time(hour: 7).band == .day && Time(hour: 17).band == .day)
        #expect(Time(hour: 18).band == .evening && Time(hour: 22).band == .evening)
        #expect(Time(hour: 23).band == .late && !Time(hour: 23).parksClosed)
        #expect(Time(hour: 2).band == .late && Time(hour: 2).parksClosed)
        #expect(Time(hour: 5).parksClosed && !Time(hour: 6).parksClosed)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let night = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 2)))
        #expect(Time(night) == Time(hour: 2))
    }

    /// A crossing's night risk adds to its cost as it is, whatever its light or refuge.
    @Test func nightRiskAddsToACrossing() throws {
        let router = try router()
        let plain = WalkRouter.Crossing(width: 10, lanes: 1, speed: 25, twoWay: false, flags: [], signal: .signal, fixed: WalkCosts.fixed)
        var refuge = plain
        refuge.refuge = true
        var night = refuge
        night.night = 12
        #expect(abs(router.cost(of: night, weight: 1) - router.cost(of: refuge, weight: 1) - 12) < 0.01)
        // After dark, one with no light costs more; one at a light the same
        var unlit = plain
        unlit.signal = []
        var unlitDark = unlit
        unlitDark.dark = true
        var litDark = plain
        litDark.dark = true
        #expect(router.cost(of: unlitDark, weight: 1) > router.cost(of: unlit, weight: 1))
        #expect(router.cost(of: litDark, weight: 1) == router.cost(of: plain, weight: 1))
    }

    /// Night costs leave Fastest as it is, keep Balanced and Safest within their budgets, and
    /// keep a walk out of Prospect Park while it's shut: Grand Army Plaza to Parkside Av.
    @Test func nightKeepsToTheBudgetAndOutOfShutParks() throws {
        let router = try router()
        let start = Walk.Point(lat: 40.6735, lon: -73.9701), end = Walk.Point(lat: 40.6551, lon: -73.9614)
        func walk(_ preference: WalkPreference, hour: Int) throws -> WalkRouter.Route {
            var options = WalkRouter.Options(preference: preference)
            options.time = .init(hour: hour)
            return try #require(router.route(from: start, to: end, options: options))
        }
        func inPark(_ route: WalkRouter.Route) -> Double {
            route.legs.reduce(0) { total, leg in
                guard case let .side(block, _, from, to, _, _) = leg, router.graph.night(of: block).contains(.park) else { return total }
                return total + from.metres(to: to)
            }
        }
        // The same time and risk: a walk with ties (either side of a block) may take either
        let fastLate = try walk(.fastest, hour: 2), fastNoon = try walk(.fastest, hour: 12)
        #expect(abs(fastLate.stats.seconds - fastNoon.stats.seconds) < 0.01)
        #expect(abs(fastLate.stats.risk - fastNoon.stats.risk) < 0.01)
        for preference in [WalkPreference.balanced, .safest] {
            let noon = try walk(preference, hour: 12), late = try walk(preference, hour: 2)
            print(describe("\(preference) noon, \(Int(inPark(noon))) m in the park", noon, router))
            print(describe("\(preference) 2 am, \(Int(inPark(late))) m in the park", late, router))
            #expect(late.stats.seconds <= WalkCosts.budget(preference, fastest: late.stats.fastestSeconds) + 1)
            #expect(inPark(late) < 50)
            // Said only after dark, and only where the night took it another way
            #expect(!noon.stats.saferAtNight)
            if preference == .safest { #expect(late.stats.saferAtNight) }
        }
        #expect(try !walk(.fastest, hour: 2).stats.saferAtNight)
        #expect(try !walk(.balanced, hour: 2).stats.saferAtNight)
    }


    /// Walking from `start` to `end` with `preference`.
    func route(_ router: WalkRouter, _ start: (Double, Double), _ end: (Double, Double),
               _ preference: WalkPreference = .balanced, stepFree: Bool = false) throws -> WalkRouter.Route {
        try #require(router.route(from: Walk.Point(lat: start.0, lon: start.1), to: Walk.Point(lat: end.0, lon: end.1),
                                  options: .init(preference: preference, stepFree: stepFree)))
    }

    /// From 19 St in South Slope to Smith–9 Sts: Apple Maps goes by 3 Av and Hamilton Ave, under
    /// the Gowanus and through its ramps. Balanced keeps clear of the interchange, a few minutes
    /// longer, within its budget: over wide streets at lights, narrow ones as they come.
    @Test func hamiltonAvenueIsKeptOffOf() throws {
        let router = try router()
        let fastest = try route(router, (40.6628, -73.9933), (40.6740, -73.9960), .fastest)
        let balanced = try route(router, (40.6628, -73.9933), (40.6740, -73.9960))
        #expect(balanced.stats.ramps == 0)
        #expect(balanced.stats.unsignalledWide == 0)
        #expect(!names(balanced, router).contains("HAMILTON AVE"))
        #expect(balanced.stats.seconds <= WalkCosts.budget(.balanced, fastest: fastest.stats.seconds) + 1)
    }

    /// Prospect Av station to Lowe's on 2nd Ave: up 4th Ave and along 12th St, not a staircase
    /// through the grid, every one about as long. Turns on OSM's sidewalks are made through
    /// their junctions and crosswalks, which once didn't count as turns.
    @Test func theGridIsNotZigzagged() throws {
        let router = try router()
        let walk = try route(router, (40.665299, -73.992729), (40.6718, -73.9957))
        var streets: [String] = []
        for case let .side(block, _, _, _, from, to) in walk.legs where abs(to - from) >= 30 {
            let name = router.graph.name(of: block)
            if streets.last != name { streets.append(name) }
        }
        #expect(streets == ["4 AVE", "12 ST"], "\(streets)")
    }

    /// Astoria, Broadway to 43rd St: found again to cross the street ahead first at its
    /// corners, along the same streets (`ordered`).
    @Test func theStreetAheadIsCrossedFirst() throws {
        let router = try router()
        let walk = try route(router, (40.762, -73.9253), (40.7568, -73.917))
        #expect(walk.stats.reordered)
    }

    /// Over the Brooklyn Bridge on its walkway, the way Apple Maps goes, with no road crossed on it.
    @Test func theBridgeIsWalkedOver() throws {
        let router = try router()
        let walk = try route(router, (40.6995, -73.9900), (40.7128, -74.0060))
        #expect(names(walk, router).contains { $0.contains("BROOKLYN BR") && $0.contains("PEDESTRIAN") })
        #expect(walk.stats.ramps == 0)
        #expect(abs(walk.stats.metres - 2148) < 2148 * 0.1)
    }

    /// On Roosevelt Island under the Queensboro Bridge: not started up on its walkway, 45 m
    /// over, with no way up, but on the island's own streets.
    @Test func aBridgeIsntStartedOnFromUnderIt() throws {
        let router = try router()
        let start = Walk.Point(lat: 40.7570, lon: -73.9540)
        let snaps = router.snaps(near: start)
        #expect(!snaps.isEmpty)
        for snap in snaps {
            #expect(router.graph.atGrade(snap.block, end: 0) || router.graph.atGrade(snap.block, end: 1),
                    "on \(router.graph.name(of: snap.block))")
            #expect(!router.graph.name(of: snap.block).contains("QUEENSBORO"))
        }
    }

    /// Fastest's walk is the quickest, as shown with its waits at the lights: not slower than
    /// Safest's for not counting the way round Columbus Circle, or a walk over a path's
    /// crossing, as Safest's did.
    @Test func fastestIsTheQuickest() throws {
        let router = try router()
        for (start, end) in [((40.7660, -73.9827), (40.7703, -73.9822)), ((40.7546, -73.9840), (40.7614, -73.9879))] {
            let fastest = try route(router, start, end, .fastest)
            let fastestWalk = router.walk(of: fastest)
            #expect(abs(fastestWalk.seconds - fastest.stats.seconds) < 0.01)
            #expect(abs(fastestWalk.meters - fastest.stats.metres) < fastest.stats.metres * 0.03 + 10,
                    "\(Int(fastestWalk.meters)) m drawn, \(Int(fastest.stats.metres)) m timed")
            for preference in [WalkPreference.balanced, .safest] {
                let other = try route(router, start, end, preference)
                #expect(fastest.stats.seconds <= other.stats.seconds + 0.5,
                        "\(preference) \(Int(other.stats.seconds)) s, fastest \(Int(fastest.stats.seconds)) s")
            }
        }
    }

    /// From out in the junction of 7 Av and 41 St in Times Square, toward 8 Av: off on the
    /// way there, not over 41 St and 7 Av from the far corner first.
    @Test func aStartInTheJunctionGoesTheWayThere() throws {
        let router = try router()
        let walk = router.walk(of: try route(router, (40.755290, -73.987495), (40.757308, -73.989735)))
        #expect(walk.steps.first?.turn != .cross, "\(walk.steps.map(\.instruction))")
        #expect(walk.crossings?.count ?? 0 <= 2)
    }

    /// Across Central Park on its paths (OpenStreetMap's), not round it.
    @Test func parksAreWalkedThrough() throws {
        let router = try router()
        let walk = try route(router, (40.76810, -73.98190), (40.77400, -73.97120))
        let osm = walk.legs.filter {
            if case let .side(block, _, _, _, _, _) = $0 { return router.graph.flags(of: block).contains(.fromOSM) }
            return false
        }
        #expect(osm.count >= 3)
        #expect(walk.stats.metres < 1379 * 1.1)
    }

    /// Each leg starts where the one before it ended, from the start to the end.
    @Test func legsJoinUp() throws {
        let router = try router()
        for (start, end) in [((40.6628, -73.9933), (40.6740, -73.9960)), ((40.72980, -73.86390), (40.73360, -73.85880)),
                             ((40.75500, -73.98800), (40.76050, -73.98450))] {
            let walk = try route(router, start, end)
            var last: Walk.Point?
            for leg in walk.legs {
                let (a, b): (Walk.Point, Walk.Point)
                switch leg {
                case let .access(x, y), let .cross(_, _, x, y): (a, b) = (x, y)
                case let .side(_, _, x, y, _, _): (a, b) = (x, y)
                }
                if let last { #expect(last.metres(to: a) < 1, "a gap of \(Int(last.metres(to: a))) m") }
                last = b
            }
            #expect(last.map { $0.metres(to: Walk.Point(lat: end.0, lon: end.1)) < 1 } ?? false)
        }
    }

    /// Step-free walks have no steps, where the walk otherwise would.
    @Test func stepFreeHasNoSteps() throws {
        let router = try router()
        func steps(_ walk: WalkRouter.Route) -> Int {
            walk.legs.filter {
                if case let .side(block, _, _, _, _, _) = $0 { return router.graph.flags(of: block).contains(.steps) }
                return false
            }.count
        }
        // Down from Riverside Dr to the park by its steps
        let start = (40.80020, -73.97000), end = (40.80100, -73.97230)
        let walk = try route(router, start, end)
        let stepFree = try route(router, start, end, stepFree: true)
        #expect(steps(stepFree) == 0)
        if steps(walk) == 0 { print("no steps on the ordinary walk: pick another") }
    }

    /// No light is less of a worry over a short crossing than a long one, and none over a
    /// wide one is the most.
    @Test func shortCrossingsWithNoLightCostLess() throws {
        #expect(WalkCosts.unsignalledShare(width: 8) == 0)
        #expect(WalkCosts.unsignalledShare(width: 12) > 0 && WalkCosts.unsignalledShare(width: 12) < 1)
        #expect(WalkCosts.unsignalledShare(width: 20) == 1)
    }

    /// A walk routed on only the tiles round it (as the app loads them) is the walk routed on
    /// the whole city's graph, from a small part of it.
    @Test func aWalksTilesRouteItAsTheCityDoes() throws {
        let router = try router()
        let database = try SQLite(path: WalkGraphTests.file.path)
        for (start, end) in [(Walk.Point(lat: 40.6628, lon: -73.9933), Walk.Point(lat: 40.6790, lon: -73.9990)),
                             (Walk.Point(lat: 40.6628, lon: -73.9933), Walk.Point(lat: 40.7486, lon: -73.9840))] {
            let city = try #require(router.route(from: start, to: end))
            let began = Date()
            let tiles = WalkGraph.tiles(along: start, to: end, metres: 1_500)
            #expect(tiles.count <= WalkGraph.tiles(around: [start, end], metres: 1_500).count)
            let graph = try WalkGraphTests.load(from: database, tiles: tiles)
            let loaded = Date()
            let local = try #require(WalkRouter(graph: graph).route(from: start, to: end))
            print("\(tiles.count) tiles, \(graph.nodeCount) junctions of \(router.graph.nodeCount): "
                  + "loaded in \(Int(loaded.timeIntervalSince(began) * 1000)) ms, routed in \(Int(Date().timeIntervalSince(loaded) * 1000)) ms")
            #expect(graph.nodeCount < router.graph.nodeCount / 2)
            #expect(abs(local.stats.metres - city.stats.metres) < city.stats.metres * 0.01)
            #expect(local.stats.crossings == city.stats.crossings)
            // Streets cut off at the tiles' edge aren't taken for ramps
            #expect(local.stats.ramps == city.stats.ramps)
        }
    }

    /// A street running off the loaded tiles can't be walked along off them, but it's
    /// crossed as the street it is, not as a highway's ramp.
    @Test func aStreetCutOffAtTheTilesIsStillAStreet() throws {
        let database = try SQLite(path: WalkGraphTests.file.path)
        let graph = try WalkGraphTests.load(from: database, tiles: [(x: 0, y: -2)])
        let cut = try #require(graph.blockCut.first { graph.crossingClass(of: $0) == .walk })
        #expect(graph.class(of: cut) == .arm)
        #expect(graph.crossingClass(of: cut) == .walk)
    }

    /// A diagonal walk across the city takes a band of tiles along it, far fewer than its box.
    @Test func aLongWalksTilesAreABandAlongIt() {
        let start = Walk.Point(lat: 40.6000, lon: -74.0200), end = Walk.Point(lat: 40.7800, lon: -73.8300)
        let along = WalkGraph.tiles(along: start, to: end, metres: 1_500)
        let box = WalkGraph.tiles(around: [start, end], metres: 1_500)
        #expect(along.count < box.count * 2 / 3)
    }

    /// Quick enough to route as a trip's picked: a couple of kilometres well under a second,
    /// even unoptimised; up to two with the other walking suites routing alongside.
    @Test func itsQuick() throws {
        let router = try router()
        let began = Date()
        _ = try route(router, (40.6628, -73.9933), (40.6790, -73.9990))
        #expect(Date().timeIntervalSince(began) < 2)
    }

    /// VIA="lat,lon,lat,lon,lat,lon": start, a point the walk must pass, and end; each half's
    /// crossings and costs, against the route chosen without it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIA"] != nil)) func viaProbe() throws {
        let router = try router()
        let c = (ProcessInfo.processInfo.environment["VIA"] ?? "").split(separator: ",").compactMap { Double($0) }
        let points = stride(from: 0, to: c.count - 1, by: 2).map { Walk.Point(lat: c[$0], lon: c[$0 + 1]) }
        let start = points[0], end = points[points.count - 1], vias = Array(points.dropFirst().dropLast())
        let options = WalkRouter.Options(preference: .balanced)
        func show(_ label: String, _ route: WalkRouter.Route) {
            print("\(label): \(Int(route.stats.metres)) m, \(Int(route.stats.seconds)) s, risk \(Int(route.stats.risk)), "
                  + "cost \(Int(route.stats.seconds + route.stats.risk)), \(route.stats.crossings) crossings, "
                  + "\(route.stats.unsignalled) no light, \(route.stats.ramps) ramps")
            for (leg, cost) in zip(route.legs, route.costs) {
                switch leg {
                case let .cross(node, arm, from, to):
                    let b = Int(router.graph.armBlock[arm])
                    guard router.graph.class(of: b) != .path else { continue }
                    print("   \(Int(cost)) s  cross \(router.graph.name(of: b)) [\(router.graph.class(of: b))] signal \(router.graph.nodeSignal[node]) "
                          + "\(Int(from.metres(to: to))) m")
                case let .side(block, left, _, _, fromAlong, toAlong):
                    let g = router.graph
                    print("   \(Int(cost)) s  along \(g.name(of: block)) \(Int(abs(toAlong - fromAlong))) m, sidewalk \(g.offset(of: block, left: left) > 0 ? "yes" : "NO"), "
                          + "flags \(g.blockFlags[block]), \(g.blockSpeed[block]) mph")
                case .access:
                    break
                }
            }
        }
        let chosen = try #require(router.route(from: start, to: end, options: options))
        show("chosen", chosen)
        // Through each point in turn
        var halves: [WalkRouter.Route] = []
        for (a, b) in zip([start] + vias, vias + [end]) {
            halves.append(try #require(router.route(from: a, to: b, options: options)))
        }
        for (i, half) in halves.enumerated() { show("part \(i + 1)", half) }
        let first = halves[0], second = WalkRouter.Route(legs: halves.dropFirst().flatMap(\.legs), stats: halves.dropFirst().reduce(into: WalkRouter.Stats()) {
            $0.metres += $1.stats.metres; $0.seconds += $1.stats.seconds; $0.crossings += $1.stats.crossings; $0.unsignalled += $1.stats.unsignalled
        })
        print("through the points: cost \(Int(halves.reduce(0) { $0 + $1.costs.reduce(0, +) })), chosen: cost \(Int(chosen.costs.reduce(0, +)))")
        #if canImport(MapKit) && canImport(AppKit)
        // Drawn as the bench draws: the chosen route blue, the one through the point green
        var stats = first.stats
        stats.metres += second.stats.metres
        stats.seconds += second.stats.seconds
        stats.crossings += second.stats.crossings
        stats.unsignalled += second.stats.unsignalled
        let through = WalkRouter.Route(legs: first.legs + second.legs, stats: stats)
        try FileManager.default.createDirectory(at: WalkBench.output, withIntermediateDirectories: true)
        try WalkBench.draw(.init(name: "via", note: "blue: chosen; green: through the point"), apple: nil,
                           routes: [(.balanced, chosen), (.safest, through)], router: router, start: start, end: end)
        #endif
    }

    /// SNAP="lat,lon": the sides a point snaps to, and their walkable part.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SNAP"] != nil)) func snapProbe() throws {
        let router = try router()
        let c = (ProcessInfo.processInfo.environment["SNAP"] ?? "").split(separator: ",").compactMap { Double($0) }
        let g = router.graph
        for snap in router.snaps(near: Walk.Point(lat: c[0], lon: c[1]), limit: 8) {
            print("snap \(g.name(of: snap.block)) [\(g.class(of: snap.block))] left \(snap.left) off \(Int(snap.off)) m "
                  + "part \(g.nodePart[Int(g.blockA[snap.block])]) flags \(g.blockFlags[snap.block])")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EXPLORE"] != nil)) func explore() throws {
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
