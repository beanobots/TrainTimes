import Foundation
import SQLite3
import UIKit

/// The city's walking graph, bundled as walkgraph.sqlite (`tools/make_walk_graph.py`), for
/// routing walks on the phone, offline (`WalkRouter`). The file's in 2 km tiles: a walk reads
/// only those along it, from its start to its end, and the graph's put together from them;
/// routed again as you go, only those along what's left. Tiles read lately are kept, and the
/// last few graphs' routers (a trip's walk to its train and from it are in different places),
/// so a walk routed again is quick; the least lately used let go, and all dropped when
/// memory's short.
actor WalkGraphStore {
    static let shared = WalkGraphStore()
    /// Long walks' own (walking all the way across town, seconds to route unoptimised), so
    /// the short ones to and from the trains, waited on by the map and Go, aren't behind them.
    static let long = WalkGraphStore()
    /// Metres straight from start to end past which a walk's routed on `long`.
    static let longWalk = 3_000.0

    /// The store for a walk from `start` to `end`.
    static func store(from start: Walk.Point, to end: Walk.Point) -> WalkGraphStore {
        start.metres(to: end) > longWalk ? long : shared
    }

    private var database: OpaquePointer?
    private var opened = false
    /// Street names by id, read once.
    private var names: [Int: String] = [:]
    /// Tiles' arrays by "x,y", the most lately used last.
    private var tiles: [String: [String: Data]] = [:]
    private var used: [String] = []
    /// The last few graphs' routers, by the tiles they're of, the most lately used last.
    private var routers: [(tiles: [String], router: WalkRouter)] = []

    /// Most tiles kept: about 2 MB, a long walk's worth and then some.
    private static let mostTiles = 40
    /// Most routers kept: a trip's two walks', and one more.
    private static let mostRouters = 3
    /// Metres either side of a walk's line to take tiles from, for its way round anything in
    /// the way; the second, wider, where there's no route in the first.
    private static let margins = [1_500.0, 3_000.0]
    /// Most tiles a walk's graph is made of: past it, it's a walk for Apple Maps, the phone
    /// spared putting so much together.
    private static let mostForAWalk = 40

    deinit {
        sqlite3_close(database)
    }

    /// Why a walk couldn't be routed.
    enum Missed: String, Error {
        /// No file in the format this reads.
        case noFile
        /// Nothing of the graph round the walk: outside the city.
        case noGraph
        /// Its ends not near enough the graph, or not joined on it.
        case noRoute
        /// So long it'd take too much of the graph to route.
        case tooFar
    }

    /// The walk from `start` to `end` routed on the graph, by `options`: on the tiles along
    /// it, then a wider band of them if there's no route in those.
    func walk(from start: Walk.Point, to end: Walk.Point, options: WalkRouter.Options) -> Result<Walk, Missed> {
        guard open() != nil else { return .failure(.noFile) }
        var missed = Missed.noGraph
        for margin in Self.margins {
            let along = WalkGraph.tiles(along: start, to: end, metres: margin)
            guard along.count <= Self.mostForAWalk else {
                // Wider's only more
                if missed == .noGraph { missed = .tooFar }
                break
            }
            guard let router = router(on: along) else { continue }
            if let route = router.route(from: start, to: end, options: options) {
                return .success(router.walk(of: route))
            }
            missed = .noRoute
        }
        return .failure(missed)
    }

    /// Drops all but the file: the tiles, graphs and routers are made again when next needed.
    func drop() {
        tiles = [:]
        used = []
        routers = []
    }

    /// The router on `wanted` tiles: one kept, if there's one on the same tiles, or made.
    private func router(on wanted: [(x: Int, y: Int)]) -> WalkRouter? {
        guard let database = open() else { return nil }
        let keys = wanted.map { "\($0.x),\($0.y)" }
        if let index = routers.firstIndex(where: { $0.tiles == keys }) {
            let kept = routers.remove(at: index)
            routers.append(kept)
            return kept.router
        }
        var arrays: [[String: Data]] = []
        for (key, (x, y)) in zip(keys, wanted) {
            if let tile = tiles[key] ?? read(x: x, y: y, from: database) {
                remember(tile, as: key)
                arrays.append(tile)
            }
        }
        guard !arrays.isEmpty, let graph = try? WalkGraph(tiles: arrays, names: names) else { return nil }
        let made = WalkRouter(graph: graph)
        routers.append((keys, made))
        if routers.count > Self.mostRouters { routers.removeFirst() }
        return made
    }

    /// Tile `key`'s arrays, kept as the latest used, the least lately used let go past `mostTiles`.
    private func remember(_ tile: [String: Data], as key: String) {
        tiles[key] = tile
        used.removeAll { $0 == key }
        used.append(key)
        while used.count > Self.mostTiles {
            tiles[used.removeFirst()] = nil
        }
    }

    /// Tile (`x`, `y`)'s arrays from the file; nil where it has none (out at sea, past the city).
    private func read(x: Int, y: Int, from database: OpaquePointer) -> [String: Data]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name, data FROM tiles WHERE x = ? AND y = ?", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(x))
        sqlite3_bind_int64(statement, 2, Int64(y))
        var tile: [String: Data] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            if count > 0, let bytes = sqlite3_column_blob(statement, 1) {
                tile[String(cString: name)] = Data(bytes: bytes, count: count)
            } else {
                tile[String(cString: name)] = Data()
            }
        }
        return tile.isEmpty ? nil : tile
    }

    /// The bundled file, read only and unchanging, if it's there and in the format this reads,
    /// with its street names read.
    private func open() -> OpaquePointer? {
        if opened { return database }
        opened = true
        guard let url = Bundle.main.url(forResource: "walkgraph", withExtension: "sqlite") else { return nil }
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
        guard format == WalkGraph.format else {
            sqlite3_close(handle)
            return nil
        }
        if sqlite3_prepare_v2(handle, "SELECT id, label FROM names", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let label = sqlite3_column_text(statement, 1) {
                    names[Int(sqlite3_column_int64(statement, 0))] = String(cString: label)
                }
            }
        }
        sqlite3_finalize(statement)
        database = handle
        // Let the tiles go when memory's short
        Task { @MainActor [self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                await self.drop()
            }
        }
        return handle
    }
}
