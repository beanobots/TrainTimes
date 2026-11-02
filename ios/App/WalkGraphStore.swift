import Foundation
import SQLite3
import UIKit

/// The city's walking graph, bundled as walkgraph.sqlite (`tools/make_walk_graph.py`), for
/// routing walks on the phone, offline (`WalkRouter`). The file's in 2 km tiles: a walk reads
/// only those round it, and the graph's put together from them. Tiles read lately are kept, and
/// the last graph and its router, so a walk routed again as you go is quick; all dropped when
/// memory's short.
actor WalkGraphStore {
    static let shared = WalkGraphStore()

    private var database: OpaquePointer?
    private var opened = false
    /// Street names by id, read once.
    private var names: [Int: String] = [:]
    /// Tiles' arrays by "x,y", the most lately used last.
    private var tiles: [String: [String: Data]] = [:]
    private var used: [String] = []
    /// The last graph's router, and the tiles it's of.
    private var router: (tiles: [String], router: WalkRouter)?

    /// Most tiles kept: about 2 MB, a long walk's worth and then some.
    private static let mostTiles = 40
    /// Metres round a walk's ends to take tiles from, for its way round anything in between.
    private static let margin = 1_500.0

    deinit {
        sqlite3_close(database)
    }

    /// The walk from `start` to `end` routed on the graph, by `options`; nil without the file,
    /// outside the city, or with no route.
    func walk(from start: Walk.Point, to end: Walk.Point, options: WalkRouter.Options) -> Walk? {
        guard let router = router(around: [start, end]),
              let route = router.route(from: start, to: end, options: options) else { return nil }
        return router.walk(of: route)
    }

    /// Drops all but the file: the tiles, graph and router are made again when next needed.
    func drop() {
        tiles = [:]
        used = []
        router = nil
    }

    /// The router on the tiles round `points`, the last one again if it's on the same tiles.
    private func router(around points: [Walk.Point]) -> WalkRouter? {
        guard let database = open() else { return nil }
        let keys = WalkGraph.tiles(around: points, metres: Self.margin).map { "\($0.x),\($0.y)" }
        if let router, router.tiles == keys { return router.router }
        var arrays: [[String: Data]] = []
        for (key, (x, y)) in zip(keys, WalkGraph.tiles(around: points, metres: Self.margin)) {
            if let tile = tiles[key] ?? read(x: x, y: y, from: database) {
                remember(tile, as: key)
                arrays.append(tile)
            }
        }
        guard !arrays.isEmpty, let graph = try? WalkGraph(tiles: arrays, names: names) else { return nil }
        let made = WalkRouter(graph: graph)
        router = (keys, made)
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
            let bytes = sqlite3_column_blob(statement, 1)
            tile[String(cString: name)] = count > 0 && bytes != nil ? Data(bytes: bytes!, count: count) : Data()
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
        Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                await WalkGraphStore.shared.drop()
            }
        }
        return handle
    }
}
