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
            #expect(point.nearest(from: fifth, to: fourth).gap == offNinth(point))
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
