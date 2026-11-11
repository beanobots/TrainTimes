import CoreLocation
import Foundation
import SQLite3
import Testing
@testable import Leeway

// The data files the app ships, read through the app's own loaders: what the app sees. Where
// the data's known to break an invariant today, the test says so in `withKnownIssue`, with the
// entrances or lines it's known for, and fails if anything else turns up (or the issue's fixed).

// MARK: - Helpers

/// The city's bounds, a little past the subway's and buses' furthest stops, and a flat plane
/// over it in metres, as the app takes the earth over the city.
private enum BakedGeo {
    static let latitudes = 40.47...40.95
    static let longitudes = -74.28 ... -73.68
    static let metresEast = Earth.metresPerDegree * cos(40.7 * .pi / 180)

    static func contains(_ lat: Double, _ lon: Double) -> Bool {
        lat.isFinite && lon.isFinite && latitudes.contains(lat) && longitudes.contains(lon)
    }

    /// Metres east and north of (0, 0), near enough over the city.
    static func xy(_ lat: Double, _ lon: Double) -> SIMD2<Double> {
        SIMD2(lon * metresEast, lat * Earth.metresPerDegree)
    }

    static func xy(_ point: Walk.Point) -> SIMD2<Double> { xy(point.lat, point.lon) }

    static func xy(_ coordinate: CLLocationCoordinate2D) -> SIMD2<Double> { xy(coordinate.latitude, coordinate.longitude) }

    static func metres(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { norm(b - a) }

    /// Metres from `p` to the segment from `a` to `b`.
    static func metres(from p: SIMD2<Double>, toSegment a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = b - a
        let squared = (d * d).sum()
        let t = squared > 0 ? min(1, max(0, ((p - a) * d).sum() / squared)) : 0
        return norm(p - (a + d * t))
    }

    static func length(_ points: [SIMD2<Double>]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + metres($1.0, $1.1) }
    }

    private static func norm(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }
}

/// Segments by the square cells they pass through, for the nearest to a point.
private struct BakedSegmentGrid: Sendable {
    struct Segment: Sendable {
        let a: SIMD2<Double>
        let b: SIMD2<Double>
        let tag: Int
    }

    let cell: Double
    private(set) var cells: [SIMD2<Int>: [Segment]] = [:]

    init(cell: Double) { self.cell = cell }

    func key(_ p: SIMD2<Double>) -> SIMD2<Int> {
        SIMD2(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down)))
    }

    /// Into every cell its box touches, or only those of `only`.
    mutating func insert(_ a: SIMD2<Double>, _ b: SIMD2<Double>, tag: Int, only: Set<SIMD2<Int>>? = nil) {
        let low = key(SIMD2(min(a.x, b.x), min(a.y, b.y))), high = key(SIMD2(max(a.x, b.x), max(a.y, b.y)))
        for x in low.x...high.x {
            for y in low.y...high.y {
                let at = SIMD2(x, y)
                if let only, !only.contains(at) { continue }
                cells[at, default: []].append(Segment(a: a, b: b, tag: tag))
            }
        }
    }

    /// The nearest segment of those `including`, among those in `p`'s cell and the 8 round it:
    /// sure to be found within `cell` metres; nil if none is there.
    func nearest(to p: SIMD2<Double>, including: (Int) -> Bool = { _ in true }) -> (metres: Double, tag: Int)? {
        let at = key(p)
        var best: (metres: Double, tag: Int)?
        for dx in -1...1 {
            for dy in -1...1 {
                for segment in cells[at &+ SIMD2(dx, dy)] ?? [] where including(segment.tag) {
                    let metres = BakedGeo.metres(from: p, toSegment: segment.a, segment.b)
                    if metres < best?.metres ?? .infinity { best = (metres, segment.tag) }
                }
            }
        }
        return best
    }
}

/// The bundled files themselves, read as they are.
private enum BakedFiles {
    static func url(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle.main.url(forResource: name, withExtension: ext), "\(name).\(ext) isn't in the app bundle")
    }

    static func json(_ name: String, _ ext: String = "json") throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url(name, ext)))
    }

    /// A bundled SQLite file's `info` table.
    static func info(_ name: String) throws -> [String: String] {
        var found: [String: String] = [:]
        try rows(name, "SELECT key, value FROM info") { statement in
            if let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) {
                found[String(cString: key)] = String(cString: value)
            }
        }
        return found
    }

    /// Each row of `sql` on a bundled SQLite file, opened read only as the app opens it.
    static func rows(_ name: String, _ sql: String, _ each: (OpaquePointer) -> Void) throws {
        let uri = try url(name, "sqlite").absoluteString + "?immutable=1"
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        try #require(sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
        while sqlite3_step(statement) == SQLITE_ROW, let statement { each(statement) }
    }

    /// Each entrance once, by place, with the first platform listing it.
    static func entrances() -> [(platform: Platform, entrance: Station.Entrance)] {
        var seen = Set<Station.Entrance.Place>()
        return StationDirectory.platforms.flatMap { platform in platform.entrances.map { (platform, $0) } }
            .filter { seen.insert($0.entrance.place).inserted }
    }

    /// "R44 40.630230,-74.025458": an entrance's platform and place, to name it in known lists.
    static func tag(_ platform: Platform, _ entrance: Station.Entrance) -> String {
        "\(platform.id) " + String(format: "%.6f,%.6f", entrance.lat, entrance.lon)
    }
}

private extension Duration {
    var bakedSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

// MARK: - Stations, lines and equipment

@Suite("Baked data: stations, lines and equipment")
struct BakedStationTests {
    /// stations.json decodes, and the app's list isn't the empty one its loader falls back to.
    @Test func stationsDecode() throws {
        let platforms = try StationDirectory.load(from: BakedFiles.url("stations", "json"))
        #expect(platforms.count > 450)
        #expect(StationDirectory.platforms.count == platforms.count)
        #expect(StationDirectory.all.count > 400)
    }

    /// No platform id twice, no alias that's another's id, and no station id twice.
    @Test func idsAreUnique() {
        let ids = StationDirectory.platforms.map(\.id)
        #expect(Set(ids).count == ids.count)
        let aliases = StationDirectory.platforms.flatMap { $0.aliases ?? [] }
        #expect(Set(aliases).isDisjoint(with: ids))
        let stations = StationDirectory.all.map(\.id)
        #expect(Set(stations).count == stations.count)
    }

    /// Every platform, and so every station, has at least one entrance.
    @Test func everyPlatformHasAnEntrance() {
        let bare = StationDirectory.platforms.filter(\.entrances.isEmpty).map(\.id)
        #expect(bare.isEmpty, "no entrances: \(bare)")
        #expect(StationDirectory.all.allSatisfy { !$0.entrances.isEmpty })
    }

    /// Platforms and entrances are in the city, none NaN.
    @Test func coordinatesInTheCity() {
        let off = StationDirectory.platforms.filter { platform in
            !BakedGeo.contains(platform.lat, platform.lon) || platform.entrances.contains { !BakedGeo.contains($0.lat, $0.lon) }
        }.map(\.id)
        #expect(off.isEmpty, "outside the city: \(off)")
    }

    /// Entrances are within 400 m of their platform (Times Sq's furthest are 375 m off).
    @Test func entrancesNearTheirPlatform() {
        let far = StationDirectory.platforms.flatMap { platform in
            platform.entrances.filter { entrance in
                BakedGeo.metres(BakedGeo.xy(platform.lat, platform.lon), BakedGeo.xy(entrance.lat, entrance.lon)) > 400
            }.map { BakedFiles.tag(platform, $0) }
        }
        #expect(far.isEmpty, "far from their platform: \(far.sorted())")
    }

    /// 77 St (R43) has its exit-only stair at 4 Av & 76 St, which the MTA lists under 86 St (make_stations.py's `MOVED`).
    @Test func seventySeventhStreetHasItsStair() throws {
        let place = Station.Entrance.Place(lat: 40.63023, lon: -74.025458, type: "Stair")
        #expect(try #require(StationDirectory.platform(forStop: "R43")).entrances.contains { $0.place == place })
        #expect(try #require(StationDirectory.platform(forStop: "R44")).entrances.allSatisfy { $0.place != place })
    }

    /// Change walks, aliases and reversed lines refer to real platforms and their own lines.
    @Test func referencesResolve() {
        let ids = Set(StationDirectory.platforms.map(\.id))
        for platform in StationDirectory.platforms {
            for (other, minutes) in platform.walks ?? [:] {
                #expect(ids.contains(other), "\(platform.id) walks to unknown \(other)")
                #expect((1...15).contains(minutes), "\(platform.id) to \(other): \(minutes) min")
            }
            for alias in platform.aliases ?? [] {
                #expect(StationDirectory.platform(forStop: alias)?.id == platform.id)
            }
            #expect(Set(platform.reversed ?? []).isSubset(of: platform.routes), "\(platform.id) reverses a line not there")
            #expect(!platform.routes.isEmpty && !platform.complex.isEmpty && !platform.name.isEmpty)
            #expect((0...2).contains(platform.ada))
            #expect(platform.ada != 2 || !platform.adaNotes.isEmpty, "\(platform.id) partly accessible, no note")
            #expect(platform.heading.map { (0..<360).contains($0) } ?? true)
        }
    }

    /// lines.json lists only real platforms, every platform's on a line, and every line has two ends.
    @Test func linesListRealPlatforms() throws {
        let lines = try #require(try BakedFiles.json("lines") as? [String: [String]])
        let ids = Set(StationDirectory.platforms.map(\.id))
        let listed = Set(lines.values.joined())
        #expect(listed.isSubset(of: ids), "unknown stops: \(listed.subtracting(ids).sorted())")
        #expect(ids.isSubset(of: listed), "on no line: \(ids.subtracting(listed).sorted())")
        for label in lines.keys {
            #expect(StationDirectory.stops(onLine: label)?.isEmpty == false)
        }
        for route in NearbyLines.allRoutes {
            #expect(!StationDirectory.stops(of: route).isEmpty, "\(route) has no stops")
            #expect(StationDirectory.end(of: route, going: .north) != nil && StationDirectory.end(of: route, going: .south) != nil)
            #expect(!StationDirectory.branches(of: route).isEmpty)
        }
    }

    /// equipment.json decodes; every machine's complex and stops are real, and its stops in its complex.
    @Test func equipmentReferencesResolve() throws {
        let machines = try EquipmentDirectory.load(from: BakedFiles.url("equipment", "json"))
        #expect(machines.count > 500)
        #expect(EquipmentDirectory.all.count == machines.count)
        let complexes = Set(StationDirectory.platforms.map(\.complex))
        let byID = Dictionary(StationDirectory.platforms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var outside: [String] = []
        for (id, machine) in machines {
            #expect(complexes.contains(machine.complex), "\(id) in unknown complex \(machine.complex)")
            for stop in machine.stops ?? [] {
                let platform = byID[stop]
                #expect(platform != nil, "\(id) serves unknown stop \(stop)")
                if let platform, platform.complex != machine.complex { outside.append("\(id) \(stop)") }
            }
        }
        // Only the Dey St elevator: the MTA files it under Fulton St (628), and lists the R W
        // among its lines and R25 among its stops, by the passage to Cortlandt St (624), so it's
        // filed under both (`Machine.complexes`)
        #expect(outside == ["EL728X R25"], "stops outside their machine's complex: \(outside.sorted())")
    }

    /// Cortlandt St sees the Dey St elevator, and its outages, though the MTA files it at Fulton St.
    @Test func machineServesEveryComplexOfItsStops() throws {
        let machine = try #require(EquipmentDirectory.all["EL728X"])
        let cortlandt = try #require(StationDirectory.platform(forStop: "R25"))
        #expect(machine.complexes.contains(cortlandt.complex))
        #expect(machine.complexes.contains(machine.complex))
        #expect(EquipmentDirectory.hasEquipment(serving: [cortlandt]))
        let row = Data(#"[{"equipment":"EL728X","serving":"Dey St to Cortlandt St","outagedate":"11/10/2026 08:00:00 AM","isupcomingoutage":"N"}]"#.utf8)
        let outages = try OutagesFeed.outages(atComplex: cortlandt.complex, in: row)
        #expect(outages.map(\.id).first?.hasPrefix("EL728X") == true)
        #expect(try OutagesFeed.outages(atComplex: machine.complex, in: row).count == 1)
    }

    /// Streets are two distinct, trimmed names in the MTA's style ("E 14 St", "Av A"), corners one of four.
    @Test func entranceStreetsInTheAppsStyle() {
        let unstyled = #"\b(AVE|ST|BLVD|Ave|Street|Avenue|Boulevard|\d+(st|nd|rd|th))\b|  "#
        var bad: [String] = []
        for platform in StationDirectory.platforms {
            for entrance in platform.entrances {
                guard let streets = entrance.streets else {
                    #expect(entrance.corner == nil, "\(platform.id): a corner with no streets")
                    continue
                }
                let ok = streets.count == 2 && Set(streets).count == 2 && streets.allSatisfy { name in
                    !name.isEmpty && name == name.trimmingCharacters(in: .whitespaces)
                        && name.range(of: unstyled, options: .regularExpression) == nil
                        && name != name.uppercased()
                }
                if !ok { bad.append("\(platform.id) \(streets)") }
                if let corner = entrance.corner {
                    #expect(["NE", "NW", "SE", "SW"].contains(corner), "\(platform.id) corner \(corner)")
                }
                #expect(entrance.address?.contains(" & ") == true)
            }
        }
        #expect(bad.isEmpty, "unstyled streets: \(bad.prefix(10))")
        let named = StationDirectory.platforms.flatMap(\.entrances).filter { $0.streets != nil }.count
        #expect(Double(named) / Double(StationDirectory.platforms.flatMap(\.entrances).count) > 0.98)
    }

    /// An entrance's `side` is only given where the platform's sides aren't joined, and it lies
    /// on that side of the track: to the right of `south` trains for "S", the left for "N".
    @Test func entranceSidesMatchGeometry() {
        var wrong: [String] = []
        for platform in StationDirectory.platforms {
            for entrance in platform.entrances {
                guard let side = entrance.side else { continue }
                #expect(platform.noCrossover == true, "\(platform.id) has a side without noCrossover")
                guard let heading = platform.heading else { continue }
                let right = Double(heading + 90) * .pi / 180
                let toward = side == .south ? SIMD2(sin(right), cos(right)) : -SIMD2(sin(right), cos(right))
                let offset = BakedGeo.xy(entrance.lat, entrance.lon) - BakedGeo.xy(platform.lat, platform.lon)
                // Today every one is at least 4.6 m to its side
                if (offset * toward).sum() <= 0 { wrong.append(BakedFiles.tag(platform, entrance)) }
            }
        }
        #expect(wrong.isEmpty, "on the other side of the track: \(wrong)")
    }

    /// 1 Av (L06)'s north-side stairs and elevator (`side` N) are named for a north corner: those
    /// at Av A, between E 14 St's roadway and a Stuyvesant Town service road the city also calls
    /// E 14 St, are NW of Av A & E 14 St (make_entrances.py takes a divided road's main roadway).
    @Test func firstAvenueNorthStairsCornerAgreesWithSide() throws {
        let platform = try #require(StationDirectory.platform(forStop: "L06"))
        let north = platform.entrances.filter { $0.side == .north && $0.corner != nil }
        #expect(north.count >= 4)
        let mislabelled = north.filter { $0.corner?.first != "N" }
        #expect(mislabelled.isEmpty, "\(mislabelled.map { "\($0.streets ?? []) \($0.corner ?? "")" })")
        #expect(north.filter { $0.streets == ["Av A", "E 14 St"] && $0.corner == "NW" }.count == 3)
    }
}

// MARK: - The walk graph and sidewalks

/// The whole city's walk graph, loaded once for the tests that need it, and indexes round the
/// station entrances: walkable segments, and city streets' arms at each junction.
private struct BakedWalkCity: Sendable {
    struct Arm: Sendable {
        /// `StreetNames.key` of its street's name.
        let key: String
        /// A unit vector, east and north, out of the junction along it.
        let way: SIMD2<Double>
    }

    let graph: WalkGraph
    let loadSeconds: Double
    /// Walkable streets' and paths' segments (not highways, not crosswalks), by block.
    let walkable: BakedSegmentGrid
    /// City streets' arms by junction, near the entrances.
    let arms: [Int: [Arm]]
    /// Junctions near the entrances by street key.
    let junctions: [String: Set<Int>]

    static let shared = Task<BakedWalkCity?, Never> { await build() }

    static func build() async -> BakedWalkCity? {
        let start = ContinuousClock.now
        let corners = [Walk.Point(lat: 40.48, lon: -74.27), Walk.Point(lat: 40.93, lon: -73.68)]
        guard let graph = await WalkGraphStore().graph(around: corners, most: 2_000) else { return nil }
        let loadSeconds = (ContinuousClock.now - start).bakedSeconds
        var walkable = BakedSegmentGrid(cell: 100)
        // Cells within 300 m of an entrance
        var near = Set<SIMD2<Int>>()
        for (_, entrance) in BakedFiles.entrances() {
            let at = walkable.key(BakedGeo.xy(entrance.lat, entrance.lon))
            for dx in -3...3 { for dy in -3...3 { near.insert(at &+ SIMD2(dx, dy)) } }
        }
        let keys = graph.names.map(StreetNames.key)
        var arms: [Int: [Arm]] = [:]
        var junctions: [String: Set<Int>] = [:]
        func unit(_ v: SIMD2<Double>) -> SIMD2<Double>? {
            let length = (v * v).sum().squareRoot()
            return length > 0 ? v / length : nil
        }
        for block in 0..<graph.blockCount {
            let points = graph.line(of: block).map(BakedGeo.xy)
            guard points.count >= 2 else { continue }
            let flags = graph.flags(of: block)
            if graph.class(of: block) != .arm, !flags.contains(.crosswalk) {
                for (a, b) in zip(points, points.dropFirst()) { walkable.insert(a, b, tag: block, only: near) }
            }
            // Ordinary city streets, as make_entrances.py names corners by
            guard graph.crossingClass(of: block) == .walk, !graph.blockCut.contains(block),
                  flags.isDisjoint(with: [.fromOSM, .crosswalk, .connector]) else { continue }
            let name = Int(graph.blockName[block])
            guard keys.indices.contains(name), !keys[name].isEmpty else { continue }
            let key = keys[name]
            for (node, from, toward) in [(Int(graph.blockA[block]), points[0], points[1]),
                                          (Int(graph.blockB[block]), points[points.count - 1], points[points.count - 2])] {
                guard near.contains(walkable.key(BakedGeo.xy(graph.point(ofNode: node)))), let way = unit(toward - from) else { continue }
                arms[node, default: []].append(Arm(key: key, way: way))
                junctions[key, default: []].insert(node)
            }
        }
        return BakedWalkCity(graph: graph, loadSeconds: loadSeconds, walkable: walkable, arms: arms, junctions: junctions)
    }

    /// The nearest walkable segment's metres and block, within 100 m.
    func nearestWalkable(_ lat: Double, _ lon: Double) -> (metres: Double, block: Int)? {
        walkable.nearest(to: BakedGeo.xy(lat, lon)).map { ($0.metres, $0.tag) }
    }

    func part(ofBlock block: Int) -> UInt32 { graph.nodePart[Int(graph.blockA[block])] }
}

@Suite("Baked data: walk graph and sidewalks")
struct BakedWalkTests {
    /// walkgraph.sqlite is in the format the app reads, and every tile of it decodes into one graph.
    @Test func walkGraphLoadsWholeCity() async throws {
        let info = try BakedFiles.info("walkgraph")
        #expect(info["format"] == WalkGraph.format)
        let city = try #require(await BakedWalkCity.shared.value)
        #expect(city.graph.nodeCount == Int(info["nodes"] ?? ""))
        #expect(city.graph.blockCount == Int(info["blocks"] ?? ""))
        #expect(city.graph.armBlock.count == Int(info["arms"] ?? ""))
        let off = (0..<city.graph.nodeCount).lazy.map(city.graph.point(ofNode:)).filter { !BakedGeo.contains($0.lat, $0.lon) }
        #expect(off.isEmpty)
        print("walkgraph.sqlite: whole city decoded in \(String(format: "%.2f", city.loadSeconds)) s, \(city.graph.nodeCount) junctions")
        #expect(city.loadSeconds < 60)
    }

    /// Most of the graph is one walkable part, the Rockaways in it; the next three are Staten
    /// Island, Governors Island and a scrap (today 85.9%, then 97.1% with them; 10,437 parts in all).
    @Test func walkGraphMostlyConnected() async throws {
        let city = try #require(await BakedWalkCity.shared.value)
        var sizes: [UInt32: Int] = [:]
        for part in city.graph.nodePart { sizes[part, default: 0] += 1 }
        let total = Double(city.graph.nodeCount)
        let biggest = sizes.values.sorted(by: >)
        #expect(Double(sizes[0] ?? 0) == Double(biggest.first ?? 0), "part 0 is the biggest")
        #expect(Double(sizes[0] ?? 0) / total >= 0.85)
        #expect(Double(biggest.prefix(4).reduce(0, +)) / total >= 0.96)
    }

    /// Every entrance is within 50 m of a walkable street or path (median 1.8 m, 99th percentile 17 m).
    @Test func everyEntranceNearTheWalkGraph() async throws {
        let city = try #require(await BakedWalkCity.shared.value)
        // W 8 St-NY Aquarium's stair on the boardwalk side is 69 m from any walkable line
        let known: Set = ["D42 40.576464,-73.974862"]
        let far = BakedFiles.entrances().filter { platform, entrance in
            (city.nearestWalkable(entrance.lat, entrance.lon)?.metres ?? .infinity) > 50
        }.map { BakedFiles.tag($0.platform, $0.entrance) }
        #expect(Set(far).isSubset(of: known), "off the walk graph: \(Set(far).subtracting(known).sorted())")
        withKnownIssue("W 8 St-NY Aquarium (D42)'s stair at 40.576464,-73.974862 is 69 m from the graph") {
            #expect(far.isEmpty)
        }
    }

    /// Entrances snap into the main walkable part, or Staten Island's there: any station walks to any other.
    @Test func entrancesOnTheMainWalkablePart() async throws {
        let city = try #require(await BakedWalkCity.shared.value)
        let snapped = BakedFiles.entrances().compactMap { platform, entrance in
            city.nearestWalkable(entrance.lat, entrance.lon).map { (platform, entrance, city.part(ofBlock: $0.block)) }
        }
        let island = snapped.filter { $0.0.borough == "Staten Island" }
        let islandParts = Dictionary(grouping: island, by: { $0.2 }).mapValues(\.count)
        let islandPart = try #require(islandParts.max { $0.value < $1.value }?.key)
        #expect(islandPart != 0)
        let apart = snapped.filter { platform, _, part in
            part != (platform.borough == "Staten Island" ? islandPart : 0)
        }
        // Bay Terrace (S20)'s underpass is on a scrap of path joined to nothing. (The Rockaways
        // are joined by the Cross Bay and Marine Parkway bridges' walkways: make_walk_graph.py's
        // `WALKWAY_BRIDGES`.)
        let known = "S20 40.556028,-74.137569"
        let tags = apart.map { BakedFiles.tag($0.0, $0.1) }
        #expect(tags.allSatisfy { $0 == known }, "entrances off the main walkable parts: \(tags)")
        withKnownIssue("Bay Terrace (S20)'s underpass is on a path joined to nothing") {
            #expect(apart.isEmpty, "\(apart.count) entrances apart")
        }
    }

    /// An entrance's corner agrees with where it is round its two streets' crossing on the
    /// city's centrelines, as make_entrances.py works it out: skipped where the streets aren't
    /// matched near it, a divided road has two crossings within 60 m, or the streets meet at under
    /// 30°; flagged only 8 m or more onto the other side of a street.
    @Test func entranceCornersMatchStreetGeometry() async throws {
        let city = try #require(await BakedWalkCity.shared.value)
        var seen = Set<String>()
        var checked = 0
        var mismatched: [String] = []
        for platform in StationDirectory.platforms {
            for entrance in platform.entrances {
                guard let streets = entrance.streets, streets.count == 2, let corner = entrance.corner,
                      seen.insert("\(entrance.lat),\(entrance.lon),\(streets)").inserted else { continue }
                let ns = StreetNames.key(streets[0]), ew = StreetNames.key(streets[1])
                let here = BakedGeo.xy(entrance.lat, entrance.lon)
                let candidates = (city.junctions[ns] ?? []).intersection(city.junctions[ew] ?? [])
                    .map { ($0, BakedGeo.xy(city.graph.point(ofNode: $0))) }
                    .filter { BakedGeo.metres($0.1, here) < 150 }
                guard let nearest = candidates.min(by: { BakedGeo.metres($0.1, here) < BakedGeo.metres($1.1, here) }) else { continue }
                let (node, at) = nearest
                guard !candidates.contains(where: { $0.0 != node && BakedGeo.metres($0.1, at) < 60 }) else { continue }
                // Each street's way through the crossing: the north-south one pointed north, the other east
                func axis(_ key: String, north: Bool) -> SIMD2<Double>? {
                    let sum = (city.arms[node] ?? []).filter { $0.key == key }.reduce(SIMD2<Double>(0, 0)) { total, arm in
                        total + ((north ? arm.way.y < 0 : arm.way.x < 0) ? -arm.way : arm.way)
                    }
                    let length = (sum * sum).sum().squareRoot()
                    return length > 0 ? sum / length : nil
                }
                guard let up = axis(ns, north: true), let right = axis(ew, north: false) else { continue }
                let apart = acos(min(1, abs((up * right).sum()))) * 180 / .pi
                guard apart >= 30 else { continue }
                checked += 1
                let d = here - at
                let north = d.x * -right.y + d.y * right.x, east = d.x * up.y - d.y * up.x
                let actual = (north > 0 ? "N" : "S") + (east > 0 ? "E" : "W")
                let wrongNorth = corner.prefix(1) != actual.prefix(1) && abs(north) >= 8
                let wrongEast = corner.suffix(1) != actual.suffix(1) && abs(east) >= 8
                if wrongNorth || wrongEast {
                    mismatched.append("\(platform.id) \(platform.name): \(corner) of \(streets.joined(separator: " & ")) is \(actual)")
                }
            }
        }
        // make_entrances.py leaves out a corner that's the wrong side of its streets or
        // mid-block (`Streets.disagrees`): today about 1,470 checked, none off
        #expect(checked > 1_200)
        #expect(mismatched.isEmpty, "corners against the streets: \(mismatched)")
    }

    /// sidewalks.sqlite is in the format the app reads, and has sidewalks within about 100 m of every station.
    @Test func sidewalksNearEveryStation() async throws {
        let info = try BakedFiles.info("sidewalks")
        #expect(info["format"] == Sidewalks.format)
        let store = SidewalkStore()
        var bare: [String] = []
        for platform in StationDirectory.platforms {
            let lat = 0.001, lon = 0.001 / cos(platform.lat * .pi / 180)
            let found = await store.sidewalks(south: platform.lat - lat, west: platform.lon - lon,
                                              north: platform.lat + lat, east: platform.lon + lon, most: 1)
            let curb = found.first?.rings.first ?? []
            if curb.count < 3 { bare.append(platform.id) }
        }
        #expect(bare.isEmpty, "no sidewalk near: \(bare)")
    }

    /// The traffic signals decode, as many as the file says, all in the city.
    @Test func signalsDecode() throws {
        let info = try BakedFiles.info("sidewalks")
        var signals: [Sidewalks.Signal]?
        try BakedFiles.rows("sidewalks", "SELECT points FROM signals") { statement in
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return }
            signals = Sidewalks.signals(from: UnsafeRawBufferPointer(start: bytes, count: count))
        }
        let decoded = try #require(signals)
        #expect(decoded.count == Int(info["signals"] ?? ""))
        #expect(decoded.allSatisfy { BakedGeo.contains($0.at.lat, $0.at.lon) })
    }
}

// MARK: - Subway tracks

@Suite("Baked data: subway tracks")
struct BakedTrackTests {
    /// shapes.json decodes; every line that stops anywhere has a track, each of at least two points, in the city.
    @Test func everyRouteHasATrack() throws {
        let raw = try #require(try BakedFiles.json("shapes") as? [String: [[Int]]])
        #expect(TrackShapes.byRoute.count == raw.count)
        for route in NearbyLines.allRoutes {
            let shapes = TrackShapes.byRoute[route] ?? []
            #expect(!shapes.isEmpty, "\(route) has no track")
        }
        for (route, shapes) in TrackShapes.byRoute {
            for shape in shapes {
                #expect(shape.count >= 2, "\(route) shape of \(shape.count) points")
                #expect(shape.allSatisfy { BakedGeo.contains($0.latitude, $0.longitude) }, "\(route) leaves the city")
                #expect(BakedGeo.length(shape.map(BakedGeo.xy)) > 100)
            }
        }
    }

    /// Each platform is within 150 m of a track of each of its lines (96 St on the Q, past its end, is 104 m).
    @Test func platformsOnTheirTracks() {
        var off: [String] = []
        for platform in StationDirectory.platforms {
            let here = CLLocationCoordinate2D(latitude: platform.lat, longitude: platform.lon)
            for route in platform.routes {
                let metres = (TrackShapes.byRoute[route] ?? []).compactMap { TrackShapes.nearest(here, on: $0)?.meters }.min()
                if (metres ?? .infinity) > 150 { off.append("\(platform.id) \(route) \(Int(metres ?? -1)) m") }
            }
        }
        #expect(off.isEmpty, "off their tracks: \(off)")
    }

    /// Nearby's whole subway lays out: every line colour drawn, a lane per point, all in the city.
    @Test func nearbyTracksLayOut() {
        let tracks = NearbyLines.allTracks
        #expect(!tracks.isEmpty)
        for track in tracks {
            #expect(track.coordinates.count >= 2)
            #expect(track.lanes.count == track.coordinates.count, "\(track.route): \(track.lanes.count) lanes, \(track.coordinates.count) points")
            #expect(track.lanes.allSatisfy { $0.isFinite })
            #expect(track.coordinates.allSatisfy { BakedGeo.contains($0.latitude, $0.longitude) })
        }
        let drawn = Set(tracks.map { LineStyle.of($0.route).color })
        let wanted = Set(NearbyLines.allRoutes.map { LineStyle.of($0).color })
        #expect(wanted.isSubset(of: drawn), "colours not drawn: \(wanted.subtracting(drawn).map { String($0, radix: 16) })")
    }
}

// MARK: - Buses and bikes

@Suite("Baked data: buses and bike lanes")
struct BakedBusBikeTests {
    /// bus_network.json is in the format the app reads, and every row came through.
    @Test func busNetworkDecodes() throws {
        let raw = try #require(try BakedFiles.json("bus_network") as? [String: Any])
        #expect(raw["format"] as? Int == 2)
        let ids = try #require(raw["stopIDs"] as? [String])
        let ways = try #require(raw["ways"] as? [[Int]])
        #expect(BusNetwork.stops.count == ids.count)
        #expect(Set(BusNetwork.byLine.values.joined().map(\.index)).count == ways.count)
        #expect(BusNetwork.stopByID.count == BusNetwork.stops.count, "stop codes twice")
        #expect(BusNetwork.byLine.count > 300)
    }

    /// Every bus line has ways to draw and at least two stops on them; stops are in the city, bearings 0-360.
    @Test func busLinesHaveStops() {
        var stopsPerLine: [String: Int] = [:]
        for stop in BusNetwork.stops {
            #expect(BakedGeo.contains(stop.coordinate.latitude, stop.coordinate.longitude), "\(stop.id) outside")
            #expect((0...360).contains(stop.bearing), "\(stop.id) bearing \(stop.bearing)")
            #expect(!stop.lines.isEmpty, "\(stop.id) on no line")
            for line in stop.lines { stopsPerLine[line, default: 0] += 1 }
        }
        let few = BusNetwork.byLine.keys.filter { (stopsPerLine[$0] ?? 0) < 2 }
        #expect(few.isEmpty, "lines with under 2 stops: \(few.sorted())")
        #expect(Set(stopsPerLine.keys).isSubset(of: BusNetwork.byLine.keys))
    }

    /// Every way is a line of some length, in the city.
    @Test func busWaysNotDegenerate() {
        var degenerate: [String] = []
        var ways: [Int: BusNetwork.Way] = [:]
        for way in BusNetwork.byLine.values.joined() { ways[way.index] = way }
        for way in ways.values {
            #expect(way.coordinates.allSatisfy { BakedGeo.contains($0.latitude, $0.longitude) })
            if way.coordinates.count < 2 || BakedGeo.length(way.coordinates.map(BakedGeo.xy)) < 1 {
                degenerate.append("\(way.index) \(way.lines.joined(separator: ","))")
            }
        }
        #expect(degenerate.isEmpty, "degenerate ways: \(degenerate)")
    }

    /// Every stop is within 60 m of a way of each of its lines (make_bus_network.py draws none past 40 m).
    @Test func busStopsOnTheirLines() {
        var grid = BakedSegmentGrid(cell: 100)
        var linesOf: [Int: Set<String>] = [:]
        for way in BusNetwork.byLine.values.joined() where linesOf[way.index] == nil {
            linesOf[way.index] = Set(way.lines)
            let points = way.coordinates.map(BakedGeo.xy)
            for (a, b) in zip(points, points.dropFirst()) { grid.insert(a, b, tag: way.index) }
        }
        var off: [String] = []
        for stop in BusNetwork.stops {
            let here = BakedGeo.xy(stop.coordinate)
            for line in stop.lines {
                let metres = grid.nearest(to: here) { linesOf[$0]?.contains(line) == true }?.metres ?? .infinity
                if metres > 60 { off.append("\(stop.id) \(line)") }
            }
        }
        #expect(off.isEmpty, "stops off their line: \(off.prefix(20))")
    }

    /// bus_routes.json's patterns point at real stops (the loader would crash otherwise), with a time each.
    @Test func busRoutesPatternsWellFormed() throws {
        let raw = try #require(try BakedFiles.json("bus_routes", "json") as? [String: Any])
        let stops = try #require(raw["stops"] as? [[Any]])
        let lines = try #require(raw["lines"] as? [String: [[String: Any]]])
        for (line, patterns) in lines {
            #expect(!patterns.isEmpty, "\(line) has no patterns")
            for pattern in patterns {
                let indices = try #require(pattern["stops"] as? [Int])
                #expect(indices.allSatisfy { stops.indices.contains($0) }, "\(line) points past the stops")
            }
        }
        #expect(BusRoutes.lineNames.count == lines.count)
        for (line, way) in BusRoutes.everyWay {
            #expect(way.stops.count >= 2, "\(line) to \(way.to): \(way.stops.count) stops")
            #expect(way.minutes.count == way.stops.count, "\(line) to \(way.to): minutes for each stop")
            #expect(way.minutes.first == 0)
            #expect(zip(way.minutes, way.minutes.dropFirst()).allSatisfy { $0 <= $1 }, "\(line) to \(way.to): time goes back")
            #expect(!way.to.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        #expect(BusRoutes.stopByCode.count == BusRoutes.allStops.count)
        #expect(BusRoutes.allStops.allSatisfy { BakedGeo.contains($0.latitude, $0.longitude) && !$0.name.isEmpty })
        #expect(Set(BusRoutes.linesAtStop.keys).isSubset(of: BusRoutes.stopByCode.keys))
    }

    /// The drawn network and the timetabled routes have the same lines and the same stops.
    @Test func busFilesAgree() {
        let drawn = Set(BusNetwork.byLine.keys.map(BusRoutes.key))
        let timed = Set(BusRoutes.lineNames)
        #expect(drawn == timed, "drawn only: \(drawn.subtracting(timed).sorted()); timed only: \(timed.subtracting(drawn).sorted())")
        let drawnStops = Set(BusNetwork.stopByID.keys), timedStops = Set(BusRoutes.stopByCode.keys)
        let undrawn = timedStops.subtracting(drawnStops), untimed = drawnStops.subtracting(timedStops)
        // make_bus_network.py draws bus_routes.json's stops (`timetabled_stops`), and the
        // shapes they're on
        #expect(undrawn.isEmpty, "timetabled, not drawn: \(undrawn.sorted().prefix(20))")
        #expect(untimed.isEmpty, "drawn, not timetabled: \(untimed.sorted().prefix(20))")
    }

    /// bike_lanes.json decodes into lanes in the city, and a ride along one counts as on it.
    @Test func bikeLanes() throws {
        let raw = try #require(try BakedFiles.json("bike_lanes") as? [String: [[Int]]])
        #expect(Set(raw.keys) == ["both", "along"])
        func decode(_ flat: [Int]) -> [Walk.Point] {
            var lat = 0, lon = 0
            return stride(from: 0, to: flat.count - 1, by: 2).map { index in
                lat += flat[index]
                lon += flat[index + 1]
                return Walk.Point(lat: Double(lat) / 1e5, lon: Double(lon) / 1e5)
            }
        }
        var empty = 0
        for shape in raw.values.joined() {
            let points = decode(shape)
            #expect(shape.count % 2 == 0 && points.count >= 2)
            #expect(points.allSatisfy { BakedGeo.contains($0.lat, $0.lon) })
            if BakedGeo.length(points.map(BakedGeo.xy)) == 0 { empty += 1 }
        }
        withKnownIssue("2 bike lane shapes have no length") {
            #expect(empty == 0)
        }
        #expect(empty <= 2)
        let longest = try #require(raw["both"]?.map(decode).max { BakedGeo.length($0.map(BakedGeo.xy)) < BakedGeo.length($1.map(BakedGeo.xy)) })
        #expect((BikeLanes.protectedShare(of: longest) ?? 0) > 0.9)
        // Out in Jamaica Bay
        let bay = [Walk.Point(lat: 40.610, lon: -73.850), Walk.Point(lat: 40.615, lon: -73.850)]
        #expect(BikeLanes.protectedShare(of: bay) == 0)
    }
}

// MARK: - Size and load time

@Suite("Baked data: size and load time")
struct BakedBudgetTests {
    /// Bytes of each file on 2026-11-10, after the data fixes.
    static let sizes: [(name: String, ext: String, bytes: Int)] = [
        ("stations", "json", 417_466), ("lines", "json", 5_541), ("equipment", "json", 314_483),
        ("bus_routes", "json", 1_122_025), ("bus_network", "json", 2_105_530), ("shapes", "json", 32_049),
        ("bike_lanes", "json", 270_380), ("walkgraph", "sqlite", 18_432_000), ("sidewalks", "sqlite", 9_371_648),
    ]

    /// Each file within 10% of its size today, and all of them under 35.28 MB (32.07 MB today), so growth is noticed.
    @Test func bundledDataWithinBudget() throws {
        var total = 0
        for (name, ext, bytes) in Self.sizes {
            let url = try BakedFiles.url(name, ext)
            let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            print("\(name).\(ext): \(size) bytes")
            #expect(size <= bytes + bytes / 10, "\(name).\(ext) is \(size) bytes, budget \(bytes + bytes / 10)")
            total += size
        }
        print("bundled data: \(total) bytes")
        #expect(total <= 35_278_000)
    }

    /// The loaders decode within generous ceilings (a debug build in the simulator); times printed.
    /// Those read on first use time only the first use, which another test may already have made.
    @Test func loadersDecodeInTime() throws {
        let clock = ContinuousClock()
        func timed(_ name: String, ceiling: Double, _ body: () throws -> Void) rethrows {
            let seconds = try clock.measure(body).bakedSeconds
            print("\(name): \(String(format: "%.3f", seconds)) s")
            #expect(seconds < ceiling, "\(name) took \(seconds) s")
        }
        try timed("stations.json", ceiling: 3) {
            let platforms = try StationDirectory.load(from: BakedFiles.url("stations", "json"))
            _ = StationDirectory.stations(from: platforms)
        }
        try timed("equipment.json", ceiling: 3) {
            _ = try EquipmentDirectory.load(from: BakedFiles.url("equipment", "json"))
        }
        timed("shapes.json (first use)", ceiling: 3) { _ = TrackShapes.byRoute.count }
        timed("bus_network.json (first use)", ceiling: 10) { _ = BusNetwork.byLine.count }
        timed("bus_routes.json (first use)", ceiling: 10) {
            _ = BusRoutes.allStops.count
            _ = BusRoutes.stopByCode.count
            _ = BusRoutes.linesAtStop.count
        }
        timed("bike_lanes.json (first use)", ceiling: 10) {
            _ = BikeLanes.protectedShare(of: [Walk.Point(lat: 40.7, lon: -74), Walk.Point(lat: 40.701, lon: -74)])
        }
        timed("Nearby's whole subway (first use)", ceiling: 30) { _ = NearbyLines.allTracks.count }
    }
}
