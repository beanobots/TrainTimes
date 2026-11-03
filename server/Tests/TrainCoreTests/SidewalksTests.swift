import Foundation
import Testing
@testable import TrainCore

/// Walks put on the sidewalk (`Sidewalks.fit`), by the city's own sidewalks as the app bundles
/// them (ios/App/sidewalks.sqlite, `tools/make_sidewalks.py`), along 9 St in Park Slope from
/// 5 Av to the R's stairs at 4 Av: Apple Maps' walk down the middle of the street, as the city's
/// street centre line has it.
@Suite struct SidewalksTests {
    /// 9 St's middle at 5 Av, and at 4 Av (its northbound side's middle, where the stairs are).
    let fifth = Walk.Point(lat: 40.669173, lon: -73.986304)
    let fourth = Walk.Point(lat: 40.670325, lon: -73.988647)
    /// 4 Av's northbound side, a block up to 8 St.
    let eighth = Walk.Point(lat: 40.670928, lon: -73.988142)
    /// The stairs on the NE corner of 4 Av and 9 St, from the MTA's entrances.
    let stairs = Walk.Point(lat: 40.670405, lon: -73.988487)

    /// Half way along 9 St, `metres` to its north (positive) or south: a door on that side.
    func door(_ metres: Double) -> Walk.Point {
        let middle = Walk.Point(lat: (fifth.lat + fourth.lat) / 2, lon: (fifth.lon + fourth.lon) / 2)
        // 9 St runs 303° toward 4 Av; north of it is 33°
        let bearing = 33.0 * .pi / 180
        return Walk.Point(lat: middle.lat + metres * cos(bearing) / 111_320,
                          lon: middle.lon + metres * sin(bearing) / (111_320 * cos(middle.lat * .pi / 180)))
    }

    /// Apple Maps' walk along `legs`, each a step ending in its turn.
    func walk(_ legs: [[Walk.Point]], turns: [Walk.Turn]) -> Walk {
        let steps = zip(legs, turns).map { points, turn in
            Walk.Step(turn: turn, instruction: "", meters: zip(points, points.dropFirst()).map { $0.metres(to: $1) }.reduce(0, +),
                      points: points)
        }
        return Walk(steps: steps, seconds: 300, meters: steps.map(\.meters).reduce(0, +))
    }

    /// The city's sidewalks within 150 m of `points`, from the app's copy.
    func sidewalks(near points: [Walk.Point]) throws -> [Sidewalks.Rings] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ios/App/sidewalks.sqlite")
        try #require(FileManager.default.fileExists(atPath: file.path), "ios/App/sidewalks.sqlite (tools/make_sidewalks.py)")
        let database = try SQLite(path: file.path)
        let format = try database.query("SELECT value FROM info WHERE key = 'format'").first?.first?.text
        #expect(format == Sidewalks.format)
        let lats = points.map(\.lat), lons = points.map(\.lon)
        let margin = 150 / 111_320.0
        let rows = try database.query("""
            SELECT s.rings FROM sidewalk_boxes b JOIN sidewalks s ON s.id = b.id
            WHERE b.min_lat <= ? AND b.max_lat >= ? AND b.min_lon <= ? AND b.max_lon >= ?
            """, [.real(lats.max()! + margin), .real(lats.min()! - margin),
                  .real(lons.max()! + margin * 1.3), .real(lons.min()! - margin * 1.3)])
        return try rows.map { try #require($0.first?.blob.flatMap(Sidewalks.rings(from:))) }
    }

    /// Whether `point` is on one of `sidewalks`: inside a curb and outside any building line.
    func onSidewalk(_ point: Walk.Point, _ sidewalks: [Sidewalks.Rings]) -> Bool {
        let plane = Sidewalks.Plane(origin: point)
        return Sidewalks.Edges(sidewalks.flatMap { $0.map { $0.map(plane.xy) } }).inside(Sidewalks.V(x: 0, y: 0))
    }

    /// Metres from `point` to 9 St's middle.
    func offNinth(_ point: Walk.Point) -> Double { point.nearest(from: fifth, to: fourth).gap }

    // MARK: Inside

    /// A 10 m square from (0, 0), and another `east` metres east of it.
    func squares(east: Double) -> Sidewalks.Edges {
        func square(at x: Double) -> [Sidewalks.V] {
            [.init(x: x, y: 0), .init(x: x + 10, y: 0), .init(x: x + 10, y: 10), .init(x: x, y: 10), .init(x: x, y: 0)]
        }
        return Sidewalks.Edges([square(at: 0), square(at: east)])
    }

    @Test func insideCountsEdgesPastTwoKilometres() {
        // From the first square, out past the second 3 km east: not counted twice and flipped
        let edges = squares(east: 3_000)
        #expect(edges.inside(Sidewalks.V(x: 5, y: 5)))
        #expect(!edges.inside(Sidewalks.V(x: -5, y: 5)))
        #expect(edges.inside(Sidewalks.V(x: 3_005, y: 5)))
        // Between them, the ray ending inside the far square before 2 km would have said on
        #expect(!edges.inside(Sidewalks.V(x: 1_005, y: 5)))
    }

    @Test func insideLevelWithACornerCountsItOnce() {
        // A diamond's west tip level with the point: the ray grazes it, and is outside
        let diamond: [Sidewalks.V] = [.init(x: 10, y: 0), .init(x: 20, y: 10), .init(x: 30, y: 0),
                                      .init(x: 20, y: -10), .init(x: 10, y: 0)]
        let edges = Sidewalks.Edges([diamond])
        #expect(!edges.inside(Sidewalks.V(x: 0, y: 0)))
        #expect(edges.inside(Sidewalks.V(x: 15, y: 0)))
        // Level with the square's top corners, inside it: still in
        #expect(squares(east: 100).inside(Sidewalks.V(x: 5, y: 0)))
    }

    // MARK: The file

    @Test func aBlobReadsBackAsItsRings() throws {
        // One ring of three points, from (40.000001, -73.000002), as make_sidewalks.py writes it
        func varint(_ value: UInt64) -> [UInt8] {
            var value = value, out: [UInt8] = []
            repeat {
                let byte = UInt8(value & 0x7F)
                value >>= 7
                out.append(value > 0 ? byte | 0x80 : byte)
            } while value > 0
            return out
        }
        func zigzag(_ value: Int64) -> UInt64 { UInt64(bitPattern: (value << 1) ^ (value >> 63)) }
        let deltas: [Int64] = [40_000_001, -73_000_002, 10, -5, -10, 5]
        let blob = varint(1) + varint(3) + deltas.flatMap { varint(zigzag($0)) }
        let rings = try #require(Sidewalks.rings(from: blob))
        #expect(rings.count == 1)
        #expect(rings[0] == [Walk.Point(lat: 40.000001, lon: -73.000002), Walk.Point(lat: 40.000011, lon: -73.000007),
                             Walk.Point(lat: 40.000001, lon: -73.000002)])
        // Cut short
        #expect(Sidewalks.rings(from: blob.dropLast()) == nil)
    }

    // MARK: Fitting

    /// From a door on 9 St's north side to the stairs on that side of 4 Av: along the north
    /// sidewalk all the way, no street crossed.
    @Test func aWalkKeepsToTheSidewalkOnItsSide() throws {
        let start = door(14)
        let apple = walk([[fifth.middle(to: fourth), fourth]], turns: [.arrive])
        let found = try sidewalks(near: apple.points + [start, stairs])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: found, start: start, end: stairs))
        #expect(fitted.crossings == [])
        let points = fitted.steps[0].points
        // Every point between the ends on the sidewalk, off the street's middle, on its north side
        let between = points.dropFirst().dropLast()
        #expect(between.count > 10)
        let on = between.filter { onSidewalk($0, found) }.count
        #expect(Double(on) >= Double(between.count) * 0.9, "\(on) of \(between.count) on the sidewalk")
        for point in between where point.metres(to: stairs) > 20 {
            #expect(offNinth(point) > 5)
            #expect(Sidewalks.side(of: Sidewalks.Plane(origin: fifth).xy(point),
                                   at: sample(at: point)) == .right)
        }
        #expect(points.last == stairs)
        #expect(abs(fitted.meters - fitted.steps[0].meters) < 0.01)
    }

    /// From the south side to the stairs on the north: across 9 St once, at 4 Av, not along
    /// the block.
    @Test func theOtherSideIsCrossedAtTheCorner() throws {
        let start = door(-14)
        let apple = walk([[fifth.middle(to: fourth), fourth]], turns: [.arrive])
        let found = try sidewalks(near: apple.points + [start, stairs])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: found, start: start, end: stairs))
        let crossings = try #require(fitted.crossings)
        #expect(crossings.count == 1)
        for point in crossings.flatMap({ $0 }) {
            #expect(point.metres(to: fourth) < 30, "a crossing \(Int(point.metres(to: fourth))) m from the corner")
        }
        // Along the block on the south side
        for point in fitted.steps[0].points.dropFirst().dropLast() where point.metres(to: fourth) > 30 {
            #expect(Sidewalks.side(of: Sidewalks.Plane(origin: fifth).xy(point), at: sample(at: point)) == .left)
        }
    }

    /// Up 9 St's north side and right up 4 Av: round the inside of the corner, no street
    /// crossed, each step keeping its own part.
    @Test func aTurnGoesRoundTheInsideOfTheCorner() throws {
        let start = door(14)
        // A door on 4 Av's east side, half way up to 8 St
        let end = Walk.Point(lat: (fourth.lat + eighth.lat) / 2 + 0.00005, lon: (fourth.lon + eighth.lon) / 2 + 0.00009)
        let apple = walk([[fifth.middle(to: fourth), fourth], [fourth, eighth]], turns: [.right, .arrive])
        let found = try sidewalks(near: apple.points + [start, end])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: found, start: start, end: end))
        #expect(fitted.crossings == [])
        #expect(fitted.steps.count == 2)
        #expect(fitted.steps.allSatisfy { $0.points.count >= 2 })
        // The turn's where the first step ends: by the corner, on its sidewalk
        let corner = try #require(fitted.steps[0].points.last)
        #expect(corner.metres(to: fourth) < 25)
        #expect(onSidewalk(corner, found))
        #expect(abs(fitted.meters - fitted.steps.map(\.meters).reduce(0, +)) < 0.01)
    }

    /// A street east along y = 0, its sidewalks either side for 60 m, then 40 m with none, then
    /// 60 m more, in `plane`.
    func brokenStreet(_ plane: Sidewalks.Plane) -> [Sidewalks.Rings] {
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        /// A sidewalk from `x0` to `x1` east, `y0` to `y1` north.
        func sidewalk(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> Sidewalks.Rings {
            [[point(x0, y0), point(x1, y0), point(x1, y1), point(x0, y1), point(x0, y0)]]
        }
        return [sidewalk(0, 60, 6, 10), sidewalk(0, 60, -10, -6), sidewalk(100, 160, 6, 10), sidewalk(100, 160, -10, -6)]
    }

    /// Across a park between two blocks, with a turn in it, Apple Maps' way through the park
    /// stands, and the step ends at its turn: not a line cut straight from block to block, its
    /// turn left back at the start (as across J.J. Byrne Park in the simulator).
    @Test func aParkBetweenBlocksKeepsAppleMapsWayThrough() throws {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.67, lon: -73.99))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        // The 40 m between the blocks a park, Apple Maps' way off through it and back
        let apple = walk([[point(0, 0), point(60, 0), point(80, 25)], [point(80, 25), point(100, 0), point(160, 0)]],
                         turns: [.right, .arrive])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: brokenStreet(plane)))
        let turn = try #require(fitted.steps[0].points.last)
        #expect(turn.metres(to: point(80, 25)) < 6)
        // Off the park's path onto the block on its own side: no street crossed
        #expect(fitted.crossings == [])
        let offsets = fitted.points.map { plane.xy($0) }
        #expect(offsets.contains { $0.x > 70 && $0.x < 90 && $0.y > 15 })
        // Along the blocks, on a sidewalk
        #expect(offsets.filter { $0.x > 5 && $0.x < 55 }.allSatisfy { abs($0.y) > 6 && abs($0.y) < 10 })
    }

    /// Apple Maps' walk on the sidewalk already, as it draws Manhattan's, along one side of a
    /// street with a 20 m one across it: its way kept, and the street it goes over crossed
    /// (as from Grand Central to 33 St, left as it was, its crossings unknown).
    @Test func aWalkOnTheSidewalkAlreadyKeepsItsWayAndCrosses() throws {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.75, lon: -73.98))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        func sidewalk(_ x0: Double, _ x1: Double) -> Sidewalks.Rings {
            [[point(x0, 4), point(x1, 4), point(x1, 12), point(x0, 12), point(x0, 4)]]
        }
        let apple = walk([[point(0, 8), point(140, 8)]], turns: [.arrive])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: [sidewalk(0, 60), sidewalk(80, 140)], signals: []))
        let crossings = try #require(fitted.crossings)
        #expect(crossings.count == 1)
        let over = try #require(crossings.first).map { plane.xy($0) }
        #expect(over.allSatisfy { $0.x > 54 && $0.x < 86 })
        #expect(fitted.lights?.count == 1)
        #expect(fitted.points.map { plane.xy($0) }.allSatisfy { abs($0.y - 8) < 0.5 })
    }

    /// Over a street as wide as that gap, Apple Maps' way straight over it: on along the
    /// sidewalk's line, not out into the middle of the street and back (as over the avenues on
    /// the Upper West Side and in Chelsea), and crossed.
    @Test func aWideStreetIsCrossedOnTheSidewalksLine() throws {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.67, lon: -73.99))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        let apple = walk([[point(0, 0), point(160, 0)]], turns: [.arrive])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: brokenStreet(plane)))
        #expect(fitted.crossings?.count == 1)
        let offsets = fitted.points.map { plane.xy($0) }
        #expect(offsets.filter { $0.x > 5 && $0.x < 155 }.allSatisfy { abs($0.y) > 6 && abs($0.y) < 10 })
    }

    /// A sidewalk on the north side of a street east along y = 0, 6 to 10 m out, from `x0` to
    /// `x1` east.
    func northSide(_ plane: Sidewalks.Plane, _ x0: Double, _ x1: Double) -> Sidewalks.Rings {
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        return [[point(x0, 6), point(x1, 6), point(x1, 10), point(x0, 10), point(x0, 6)]]
    }

    /// With a sidewalk on only one side in reach, the far side's 56 m out (as across Queens Blvd,
    /// whose malls the city's map hasn't), the walk's on it: over the cross street, not the 3 m
    /// driveway the sidewalk stops for (as along Queens Blvd at 63rd Dr, left as it was, its
    /// crossings unknown).
    @Test func aSidewalkOnOneSideAloneIsWalkedOn() throws {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.73, lon: -73.87))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        let far: Sidewalks.Rings = [[point(0, -60), point(200, -60), point(200, -56), point(0, -56), point(0, -60)]]
        let sidewalks = [northSide(plane, 0, 70), northSide(plane, 82, 120), northSide(plane, 123, 200), far]
        let apple = walk([[point(0, 0), point(200, 0)]], turns: [.arrive])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: sidewalks, signals: []))
        let crossings = try #require(fitted.crossings).map { $0.map(plane.xy) }
        try #require(crossings.count == 1)
        #expect(crossings[0].allSatisfy { $0.x > 64 && $0.x < 88 })
        #expect(fitted.lights == [.unsignalled])
        let offsets = fitted.points.map { plane.xy($0) }
        #expect(offsets.filter { $0.x > 5 && $0.x < 195 }.allSatisfy { $0.y > 6 && $0.y < 10 })
    }

    /// Where the one side's sidewalk stops and the other's starts, it's crossed to, once.
    @Test func aSidewalkOnOneSideThenTheOtherIsCrossedTo() throws {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.73, lon: -73.87))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        let south: Sidewalks.Rings = [[point(108, -10), point(200, -10), point(200, -6), point(108, -6), point(108, -10)]]
        let apple = walk([[point(0, 0), point(200, 0)]], turns: [.arrive])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: [northSide(plane, 0, 96), south]))
        let crossings = try #require(fitted.crossings).map { $0.map(plane.xy) }
        try #require(crossings.count == 1)
        #expect(crossings[0].allSatisfy { $0.x > 90 && $0.x < 114 })
        let offsets = fitted.points.map { plane.xy($0) }
        #expect(offsets.filter { $0.x > 5 && $0.x < 90 }.allSatisfy { $0.y > 6 && $0.y < 10 })
        #expect(offsets.filter { $0.x > 114 && $0.x < 195 }.allSatisfy { $0.y > -10 && $0.y < -6 })
    }

    /// Along Queens Blvd's south side from 63rd Dr, Apple Maps' way down its service road and
    /// the north side's sidewalk 50 m off: on the south side's, over the one side street on the
    /// way and nothing else.
    @Test func queensBlvdIsWalkedOnItsNearSide() throws {
        let apple = walk([[Walk.Point(lat: 40.7324121, lon: -73.8680476), Walk.Point(lat: 40.7322764, lon: -73.8677751),
                           Walk.Point(lat: 40.7313087, lon: -73.8661751), Walk.Point(lat: 40.7311598, lon: -73.8658278)]],
                         turns: [.arrive])
        let found = try sidewalks(near: apple.points)
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: found, signals: []))
        let crossings = try #require(fitted.crossings)
        try #require(crossings.count == 1)
        let over = try #require(crossings[0].first).middle(to: try #require(crossings[0].last))
        #expect(over.metres(to: Walk.Point(lat: 40.73159, lon: -73.86683)) < 15)
        let between = fitted.steps[0].points.dropFirst().dropLast()
        let on = between.filter { onSidewalk($0, found) }.count
        #expect(Double(on) >= Double(between.count) * 0.9, "\(on) of \(between.count) on the sidewalk")
    }

    /// A street east along y = 0 in `plane` with three blocks, 0 to 60 m, 75 to 135 and 150 to
    /// 210, 12 m curb to curb but the middle block `middle`.
    func threeBlocks(_ plane: Sidewalks.Plane, middle: Double = 12, road: Double = 12) -> [Sidewalks.Rings] {
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        /// A block's sidewalks either side, from `x0` to `x1` east, `road` apart.
        func block(_ x0: Double, _ x1: Double, _ road: Double) -> [Sidewalks.Rings] {
            let curb = road / 2
            return [[curb, curb + 4], [-curb - 4, -curb]].map { ys -> Sidewalks.Rings in
                [[point(x0, ys[0]), point(x1, ys[0]), point(x1, ys[1]), point(x0, ys[1]), point(x0, ys[0])]]
            }
        }
        return block(0, 60, road) + block(75, 135, middle) + block(150, 210, road)
    }

    /// From the south side of `threeBlocks` to the north at its far end: where it crosses the
    /// street, in metres along it.
    func changeOfSides(middle: Double = 12, signals: [Sidewalks.V] = []) throws -> Double {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.67, lon: -73.99))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        let apple = walk([[point(2, 0), point(208, 0)]], turns: [.arrive])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: threeBlocks(plane, middle: middle),
                                                signals: signals.map { Sidewalks.Signal(at: plane.point($0), kind: .signal) },
                                                start: point(2, -8), end: point(208, 8)))
        let crossings = try #require(fitted.crossings).map { $0.map(plane.xy) }
        // Only one from one side to the other; the rest over the cross streets
        let over = crossings.filter { crossing in crossing.contains { $0.y < -3 } && crossing.contains { $0.y > 3 } }
        try #require(over.count == 1)
        return over[0].map(\.x).reduce(0, +) / Double(over[0].count)
    }

    /// With a narrower block, the street's crossed at its end, not at the wider ones'.
    @Test func theStreetIsCrossedWhereItsNarrowest() throws {
        let x = try changeOfSides(middle: 8)
        #expect(abs(x - 135) < 6, "crossed at \(Int(x)) m")
    }

    /// At a signal, wherever it is, rather than where there's none.
    @Test func theStreetIsCrossedAtASignal() throws {
        for corner in [60.0, 135] {
            let x = try changeOfSides(signals: [Sidewalks.V(x: corner + 7, y: 0)])
            #expect(abs(x - corner) < 6, "crossed at \(Int(x)) m, not the signal at \(Int(corner)) m")
        }
        // Even a wider block's end, with a signal, over a narrower one's without
        let x = try changeOfSides(middle: 10, signals: [Sidewalks.V(x: 67, y: 0)])
        #expect(abs(x - 60) < 6, "crossed at \(Int(x)) m")
    }

    /// The change of sides, which Apple Maps' walk doesn't say, a step of its own before the
    /// rest: to the near curb, then on over it to the end, the light there on it.
    @Test func theChangeOfSidesIsAStep() throws {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.67, lon: -73.99))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        let apple = walk([[point(2, 0), point(208, 0)]], turns: [.arrive])
        let signal = Sidewalks.Signal(at: point(67, 0), kind: [.signal, .leading])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: threeBlocks(plane), signals: [signal],
                                                start: point(2, -8), end: point(208, 8)))
        try #require(fitted.steps.count == 2)
        let cross = fitted.steps[0]
        #expect(cross.turn == .cross)
        #expect(cross.instruction == "Cross the street")
        #expect(cross.light == .leading)
        let curb = try #require(cross.points.last)
        #expect(cross.crossing?.first == curb)
        #expect(abs(plane.xy(curb).x - 60) < 6)
        #expect(fitted.steps[1].turn == .arrive)
        #expect(fitted.steps[1].points.first == curb)
        #expect(abs(fitted.steps.map(\.meters).reduce(0, +) - fitted.meters) < 0.01)
        // The cross streets' crossings, ahead: the one at that junction at its light, the
        // next with none
        #expect(fitted.lights?.count == fitted.crossings?.count)
        #expect(fitted.lights?.filter { $0 == .leading }.count == 2)
        #expect(fitted.lights?.filter { !$0.hasSignal }.count == 1)
    }

    /// With no light, a wide street's crossing warns more than a narrow one's.
    @Test func aWideStreetWithNoLightWarns() throws {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.67, lon: -73.99))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        let apple = walk([[point(2, 0), point(208, 0)]], turns: [.arrive])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: threeBlocks(plane, middle: 24, road: 24), signals: [],
                                                start: point(2, -14), end: point(208, 14)))
        let cross = try #require(fitted.steps.first { $0.turn == .cross })
        #expect(cross.light == .unsignalledWide)
        // By the street curb to curb, not the way over from one sidewalk's middle to the other's
        let over = [Sidewalks.V(x: 0, y: -8), Sidewalks.V(x: 0, y: 12)]
        #expect(Sidewalks.light(over: over, road: 10, signals: []) == .unsignalled)
        #expect(Sidewalks.light(over: over, road: 16, signals: []) == .unsignalledWide)
    }

    /// Without the signals' file, the lights aren't known: none said, rather than "No light"
    /// at every crossing. The change of sides is still a step.
    @Test func noSignalsKnownSaysNoLights() throws {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.67, lon: -73.99))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        let apple = walk([[point(2, 0), point(208, 0)]], turns: [.arrive])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: threeBlocks(plane), signals: nil,
                                                start: point(2, -8), end: point(208, 8)))
        #expect(fitted.lights == nil)
        let cross = try #require(fitted.steps.first { $0.turn == .cross })
        #expect(cross.light == nil)
    }

    /// Past the last block to the end, over the cross street between: that's a crossing, with
    /// its light. Ending on the other side, it's crossed straight over at the block's end, not
    /// on a slant through the junction.
    @Test func theWayToTheEndCrossesWhatsBetween() throws {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.67, lon: -73.99))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        let apple = walk([[point(2, 0), point(152, 0)]], turns: [.arrive])
        let same = try #require(Sidewalks.fit(apple, sidewalks: threeBlocks(plane), signals: [],
                                              start: point(2, 8), end: point(152, 8)))
        let crossings = try #require(same.crossings).map { $0.map(plane.xy) }
        #expect(crossings.contains { crossing in crossing.contains { $0.x < 136 } && crossing.contains { $0.x > 149 } },
                "no crossing over the street from 135 to 150 m: \(crossings)")
        #expect(same.lights?.count == same.crossings?.count)

        let other = try #require(Sidewalks.fit(apple, sidewalks: threeBlocks(plane), signals: [],
                                               start: point(2, 8), end: point(152, -8)))
        for crossing in try #require(other.crossings).map({ $0.map(plane.xy) }) {
            guard let first = crossing.first, let last = crossing.last else { continue }
            // Each straight over one street or the other, not both at once
            let dx = abs(last.x - first.x), dy = abs(last.y - first.y)
            #expect(dx < 4 || dy < 4, "a crossing on a slant: \(crossing)")
        }
    }

    /// An L: east along A, left up B, from A's north side to B's east side. B's crossed at the
    /// corner, not in the middle of the block where the walk ends.
    @Test func theEndsSideIsCrossedToAtACorner() throws {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.67, lon: -73.99))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        func box(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> Sidewalks.Rings {
            [[point(x0, y0), point(x1, y0), point(x1, y1), point(x0, y1), point(x0, y0)]]
        }
        // A along y = 0 to B along x = 100, both 12 m curb to curb, sidewalks 4 m
        let sidewalks = [box(0, 94, 6, 10), box(0, 94, -10, -6), box(106, 200, 6, 10), box(106, 200, -10, -6),
                         box(90, 94, 16, 160), box(106, 110, 16, 160)]
        let apple = walk([[point(2, 0), point(100, 0)], [point(100, 0), point(100, 150)]], turns: [.left, .arrive])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: sidewalks, signals: [],
                                                start: point(2, 8), end: point(108, 150)))
        let crossings = try #require(fitted.crossings).map { $0.map(plane.xy) }
        // One over B, by the corner
        let overB = crossings.filter { crossing in crossing.contains { $0.x < 96 } && crossing.contains { $0.x > 104 } }
        #expect(overB.count == 1)
        #expect(overB.allSatisfy { $0.allSatisfy { $0.y < 30 } }, "B crossed away from the corner: \(overB)")
    }

    /// A step with nothing to walk, at the curb where the street's crossed (Apple Maps'
    /// "Continue onto" at the corner), comes before the crossing: the way doesn't go over the
    /// street, back, and over again, and the steps add up to the walk.
    @Test func aCrossingAfterAnEmptyStepDoesntDoubleBack() throws {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.67, lon: -73.99))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        let apple = walk([[point(2, 0), point(136, 0)], [point(136, 0), point(140, 0)], [point(140, 0), point(146, 0)]],
                         turns: [.straight, .straight, .arrive])
        let fitted = try #require(Sidewalks.fit(apple, sidewalks: threeBlocks(plane), signals: [Sidewalks.Signal(at: point(140, 0), kind: .signal)],
                                                start: point(2, -8), end: point(146, 8)))
        // Their paths do; a crossing whose path is the way over says none, done where it starts
        let paths = fitted.steps.map { zip($0.points, $0.points.dropFirst()).map { $0.metres(to: $1) }.reduce(0, +) }
        #expect(abs(paths.reduce(0, +) - fitted.meters) < 0.01)
        for step in fitted.steps where step.turn == .cross && step.points.last == step.crossing?.last {
            #expect(step.meters == 0)
        }
        // No point gone back to
        let path = fitted.points.reduce(into: [Walk.Point]()) { if $0.last != $1 { $0.append($1) } }
        #expect(Set(path).count == path.count, "the way doubles back: \(path.map(plane.xy))")
    }

    @Test func streetsAreReadFromInstructions() {
        #expect(Walk.street(in: "Take a left onto 4th Ave") == "4th Ave")
        #expect(Walk.street(in: "Continue on Ocean Pkwy toward Coney Island") == "Ocean Pkwy")
        #expect(Walk.street(in: "Head north on Broadway, then turn") == "Broadway")
        #expect(Walk.street(in: "The destination is on your left") == nil)
        #expect(Walk.street(in: "Arrive at the destination") == nil)
    }

    /// The street a turn's crossing is over, by the step before: none before the first, or
    /// past the last.
    @Test func theStreetTurnedOffIsTheStepBefores() {
        let walk = walk([[fifth, fourth], [fourth, eighth]], turns: [.left, .arrive])
        var named = walk
        named.steps[0].instruction = "Take a left onto 4th Ave"
        #expect(named.streetTurnedOff(at: 1) == "4th Ave")
        #expect(named.streetTurnedOff(at: 0) == nil)
        #expect(named.streetTurnedOff(at: 9) == nil)
    }

    /// Two narrow streets at signals are better crossed than a wide one with none, and one
    /// street than two; a walk signal first, or all the cars stopped, better still.
    @Test func crossingsCostByWidthAndSignal() {
        let signal = Sidewalks.cost(width: 10, signal: .signal)
        #expect(Sidewalks.cost(width: 10, signal: []) > signal)
        #expect(Sidewalks.cost(width: 20, signal: .signal) > signal)
        #expect(Sidewalks.cost(width: 30, signal: []) > 2 * signal)
        #expect(Sidewalks.cost(width: 40, signal: .signal) < 2 * Sidewalks.cost(width: 6, signal: .signal))
        #expect(Sidewalks.cost(width: 10, signal: [.signal, .leading]) < signal)
        #expect(Sidewalks.cost(width: 10, signal: [.signal, .exclusive])
                < Sidewalks.cost(width: 10, signal: [.signal, .leading]))
    }

    @Test func signalsReadBackFromTheirBlob() throws {
        func varint(_ value: UInt64) -> [UInt8] {
            var value = value, out: [UInt8] = []
            repeat {
                let byte = UInt8(value & 0x7F)
                value >>= 7
                out.append(value > 0 ? byte | 0x80 : byte)
            } while value > 0
            return out
        }
        func zigzag(_ value: Int64) -> UInt64 { UInt64(bitPattern: (value << 1) ^ (value >> 63)) }
        // Two, as make_signals.py writes them: a plain one, then one with a leading interval
        let values: [UInt64] = [2, zigzag(40_000_001), zigzag(-73_000_002), 1, zigzag(-10), zigzag(5), 3]
        let blob = values.flatMap(varint)
        let signals = try #require(Sidewalks.signals(from: blob))
        #expect(signals == [Sidewalks.Signal(at: Walk.Point(lat: 40.000001, lon: -73.000002), kind: .signal),
                            Sidewalks.Signal(at: Walk.Point(lat: 39.999991, lon: -72.999997), kind: [.signal, .leading])])
        #expect(Sidewalks.signals(from: blob.dropLast()) == nil)
    }

    /// The app's copy has the city's signals, among them leading intervals and Barnes Dances.
    @Test func theFileHasTheSignals() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ios/App/sidewalks.sqlite")
        let database = try SQLite(path: file.path)
        let blob = try #require(try database.query("SELECT points FROM signals").first?.first?.blob)
        let signals = try #require(Sidewalks.signals(from: blob))
        #expect(signals.count > 50_000)
        #expect(signals.allSatisfy { $0.kind.contains(.signal) })
        #expect(signals.contains { $0.kind.contains(.leading) })
        #expect(signals.contains { $0.kind.contains(.exclusive) })
        // Some at 4 Av and 9 St, the stairs' corner
        #expect(signals.contains { $0.at.metres(to: fourth) < 40 })
    }

    /// Up an avenue over a cross street, then right round the outside of the next corner, over
    /// the avenue: only the cross street's named on a sign, not the avenue just turned off.
    @Test func onlyStreetsAheadGetSigns() {
        let plane = Sidewalks.Plane(origin: Walk.Point(lat: 40.67, lon: -73.99))
        func point(_ x: Double, _ y: Double) -> Walk.Point { plane.point(Sidewalks.V(x: x, y: y)) }
        let crossStreet = [point(0, 50), point(0, 65)]
        let avenue = [point(0, 115), point(15, 115)]
        var walk = walk([[point(0, 0), point(0, 50), point(0, 65), point(0, 115)], [point(15, 115), point(65, 115)]],
                        turns: [.right, .arrive])
        walk.crossings = [crossStreet, avenue]
        #expect(walk.crossStreets == [crossStreet])
    }

    /// Far from any sidewalk the city has (out at sea), Apple Maps' walk stands.
    @Test func noSidewalksLeavesTheWalkAlone() throws {
        let sea = [Walk.Point(lat: 40.55, lon: -73.70), Walk.Point(lat: 40.551, lon: -73.701)]
        let found = try sidewalks(near: sea)
        #expect(Sidewalks.fit(walk([sea], turns: [.arrive]), sidewalks: found) == nil)
    }

    /// The sample on 9 St nearest `point`, for which side of it `point` is.
    func sample(at point: Walk.Point) -> Sidewalks.Sample {
        let plane = Sidewalks.Plane(origin: fifth)
        let a = plane.xy(fifth), b = plane.xy(fourth)
        let along = (b - a) * (1 / (b - a).length)
        let t = (plane.xy(point) - a).dot(along)
        return Sidewalks.Sample(at: a + along * t, direction: along, step: 0)
    }
}

private extension Walk.Point {
    func middle(to other: Walk.Point) -> Walk.Point { Walk.Point(lat: (lat + other.lat) / 2, lon: (lon + other.lon) / 2) }
}
