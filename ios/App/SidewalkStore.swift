import Foundation
import SQLite3

/// The city's sidewalks, bundled as sidewalks.sqlite (`tools/make_sidewalks.py`), for putting
/// walks on them (`Sidewalks.fit`). Read only, opened the first time it's asked.
actor SidewalkStore {
    static let shared = SidewalkStore()

    private var database: OpaquePointer?
    private var opened = false
    /// Every signal in the city (`tools/make_signals.py`), read the first time they're asked;
    /// nil inside if the file has none to read.
    private var allSignals: [Sidewalks.Signal]??

    /// Metres round a walk to read sidewalks from: past the far side of the widest avenue.
    private static let margin = 60.0

    deinit {
        sqlite3_close(database)
    }

    /// `walk` on the sidewalks, from `start`'s side of the street to `end`'s, crossing at signals
    /// where it can (`Sidewalks.fit`); nil without the file or the sidewalks to go by.
    func fit(_ walk: Walk, from start: Walk.Point?, to end: Walk.Point?) -> Walk? {
        let points = walk.points + [start, end].compactMap { $0 }
        guard !points.isEmpty, let sidewalks = sidewalks(around: points) else { return nil }
        return Sidewalks.fit(walk, sidewalks: sidewalks, signals: signals(around: points), start: start, end: end)
    }

    /// The signals within `margin` of `points`' box. Nil, not none, if the file has none to
    /// read (built without `make_signals.py`, or cut short), so crossings aren't all "No light".
    private func signals(around points: [Walk.Point]) -> [Sidewalks.Signal]? {
        let lats = points.map(\.lat), lons = points.map(\.lon)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max(),
              let all = loadSignals() else { return nil }
        let dLat = Self.margin / Earth.metresPerDegree, dLon = Self.margin / (Earth.metresPerDegree * cos(minLat * .pi / 180))
        let lat = (minLat - dLat)...(maxLat + dLat), lon = (minLon - dLon)...(maxLon + dLon)
        return all.filter { lat.contains($0.at.lat) && lon.contains($0.at.lon) }
    }

    /// Every signal, from the file's one blob of them; nil without one that reads.
    private func loadSignals() -> [Sidewalks.Signal]? {
        if let allSignals { return allSignals }
        var found: [Sidewalks.Signal]?
        var statement: OpaquePointer?
        if let database = open(),
           sqlite3_prepare_v2(database, "SELECT points FROM signals", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            if count > 0, let bytes = sqlite3_column_blob(statement, 0) {
                found = Sidewalks.signals(from: UnsafeRawBufferPointer(start: bytes, count: count))
            }
        }
        sqlite3_finalize(statement)
        allSignals = .some(found)
        return found
    }

    /// Whether `point` and `other` are on different sidewalks, both on one: across the street
    /// from each other, or a block apart. False where either's off the sidewalks, in the street
    /// or a park, or without the file.
    func differentSidewalks(_ point: Walk.Point, _ other: Walk.Point) -> Bool {
        guard let mine = sidewalk(at: point), let theirs = sidewalk(at: other) else { return false }
        return mine != theirs
    }

    /// Whether `point` is inside a block, in from its sidewalk's building line by `margin` metres
    /// each way: in a building, as GPS puts you before you've come out. A block counts where
    /// its sidewalk rings it whole, a hole in it; false where the sidewalk's in pieces, or
    /// without the file.
    func isIndoors(_ point: Walk.Point, margin: Double = 3) -> Bool {
        guard let database = open() else { return false }
        let sql = """
            SELECT s.rings FROM sidewalk_boxes b JOIN sidewalks s ON s.id = b.id
            WHERE b.min_lat <= ? AND b.max_lat >= ? AND b.min_lon <= ? AND b.max_lon >= ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, point.lat)
        sqlite3_bind_double(statement, 2, point.lat)
        sqlite3_bind_double(statement, 3, point.lon)
        sqlite3_bind_double(statement, 4, point.lon)
        let plane = Sidewalks.Plane(origin: point)
        let probes = [Sidewalks.V(x: 0, y: 0), Sidewalks.V(x: margin, y: 0), Sidewalks.V(x: -margin, y: 0),
                      Sidewalks.V(x: 0, y: margin), Sidewalks.V(x: 0, y: -margin)]
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { continue }
            guard let rings = Sidewalks.rings(from: UnsafeRawBufferPointer(start: bytes, count: count)),
                  rings.count > 1, rings.count <= Self.mostBlockRings else { continue }
            // In one of its holes (rings after the curb), a block's size, not a park's
            for hole in rings.dropFirst().map({ $0.map(plane.xy) }) where Self.area(hole) <= Self.biggestBlock {
                let edges = Sidewalks.Edges([hole])
                if probes.allSatisfy(edges.inside) { return true }
            }
        }
        return false
    }

    /// Up to `most` sidewalks in the box, for Prototyping's map overlays, each with whether
    /// `isIndoors` counts each of its holes (rings after the curb) as a block.
    func sidewalks(south: Double, west: Double, north: Double, east: Double, most: Int)
        -> [(rings: Sidewalks.Rings, blocks: [Bool])] {
        guard let database = open() else { return [] }
        let sql = """
            SELECT s.rings FROM sidewalk_boxes b JOIN sidewalks s ON s.id = b.id
            WHERE b.min_lat <= ? AND b.max_lat >= ? AND b.min_lon <= ? AND b.max_lon >= ? LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, north)
        sqlite3_bind_double(statement, 2, south)
        sqlite3_bind_double(statement, 3, east)
        sqlite3_bind_double(statement, 4, west)
        sqlite3_bind_int64(statement, 5, Int64(most))
        var found: [(rings: Sidewalks.Rings, blocks: [Bool])] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 0),
                  let rings = Sidewalks.rings(from: UnsafeRawBufferPointer(start: bytes, count: count)),
                  let origin = rings.first?.first else { continue }
            let plane = Sidewalks.Plane(origin: origin)
            let counts = rings.count > 1 && rings.count <= Self.mostBlockRings
            found.append((rings, rings.dropFirst().map { counts && Self.area($0.map(plane.xy)) <= Self.biggestBlock }))
        }
        return found
    }

    /// Square metres of a block, at most, for `isIndoors`: a long Manhattan block's 22,000, not
    /// a block-sized park like Bryant Park's 39,000 (or superblocks, missed).
    private static let biggestBlock = 30_000.0
    /// Rings of a sidewalk round blocks, at most: more is a park's paths round its lawns.
    private static let mostBlockRings = 6

    /// Square metres `ring` closes in.
    private static func area(_ ring: [Sidewalks.V]) -> Double {
        abs(zip(ring, ring.dropFirst() + ring.prefix(1)).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
    }

    /// The sidewalk `point` is on, by its row; nil off them.
    private func sidewalk(at point: Walk.Point) -> Int64? {
        guard let database = open() else { return nil }
        let sql = """
            SELECT s.id, s.rings FROM sidewalk_boxes b JOIN sidewalks s ON s.id = b.id
            WHERE b.min_lat <= ? AND b.max_lat >= ? AND b.min_lon <= ? AND b.max_lon >= ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, point.lat)
        sqlite3_bind_double(statement, 2, point.lat)
        sqlite3_bind_double(statement, 3, point.lon)
        sqlite3_bind_double(statement, 4, point.lon)
        // Inside its curb and out of the building lines round its holes, as `Edges` counts it
        let plane = Sidewalks.Plane(origin: point)
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 1))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let blob = UnsafeRawBufferPointer(start: bytes, count: count)
            guard let rings = Sidewalks.rings(from: blob) else { continue }
            if Sidewalks.Edges(rings.map { $0.map(plane.xy) }).inside(Sidewalks.V(x: 0, y: 0)) {
                return sqlite3_column_int64(statement, 0)
            }
        }
        return nil
    }

    /// Those within `margin` of `points`' box.
    private func sidewalks(around points: [Walk.Point]) -> [Sidewalks.Rings]? {
        guard let database = open() else { return nil }
        let lats = points.map(\.lat), lons = points.map(\.lon)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let dLat = Self.margin / Earth.metresPerDegree, dLon = Self.margin / (Earth.metresPerDegree * cos(minLat * .pi / 180))
        let sql = """
            SELECT s.rings FROM sidewalk_boxes b JOIN sidewalks s ON s.id = b.id
            WHERE b.min_lat <= ? AND b.max_lat >= ? AND b.min_lon <= ? AND b.max_lon >= ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, maxLat + dLat)
        sqlite3_bind_double(statement, 2, minLat - dLat)
        sqlite3_bind_double(statement, 3, maxLon + dLon)
        sqlite3_bind_double(statement, 4, minLon - dLon)
        var found: [Sidewalks.Rings] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let blob = UnsafeRawBufferPointer(start: bytes, count: count)
            if let rings = Sidewalks.rings(from: blob) { found.append(rings) }
        }
        return found
    }

    /// The bundled file, read only and unchanging, if it's there and in the format this reads.
    private func open() -> OpaquePointer? {
        if opened { return database }
        opened = true
        guard let url = Bundle.main.url(forResource: "sidewalks", withExtension: "sqlite") else { return nil }
        var handle: OpaquePointer?
        // immutable: it's never written, so SQLite needn't lock it or look for a journal
        let uri = url.absoluteString + "?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        var statement: OpaquePointer?
        var format: String?
        if sqlite3_prepare_v2(handle, "SELECT value FROM info WHERE key = 'format'", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            format = String(cString: text)
        }
        sqlite3_finalize(statement)
        guard format == Sidewalks.format else {
            sqlite3_close(handle)
            return nil
        }
        database = handle
        return handle
    }
}
