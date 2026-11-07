import Foundation

/// Every MTA bus stop and the lines any of its trips stop there on (bus_stop_lines.json, which
/// tools/make_bus_routes.py writes from the bus GTFS), so a bus countdown at a stop there isn't,
/// asked of Bus Time every pass, can be refused when it's registered.
enum BusStops {
    /// Each stop's lines by its code, as `BusTime.canonical` has them: "M15+". Empty if the file
    /// couldn't be read, when every stop passes.
    static let lines: [String: Set<String>] = {
        guard let url = Bundle.main.url(forResource: "bus_stop_lines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            Log.error("bus_stop_lines.json couldn't be read: bus countdowns' stops aren't checked")
            return [:]
        }
        return file.mapValues(Set.init)
    }()

    /// Whether `bus`'s stop, and any across the street, are real stops, and at least one of its
    /// lines stops at one of them. Not every line: the app's are those Bus Time has coming there,
    /// which on a detour, or once the timetables change, may not be this file's.
    static func isReal(_ bus: BusChoice) -> Bool {
        guard !lines.isEmpty else { return true }
        let stops = [bus.stop] + (bus.otherStop.map { [$0] } ?? [])
        guard let served = try? stops.reduce(into: Set<String>(), { served, stop in
            guard let lines = lines[stop.id] else { throw CocoaError(.fileNoSuchFile) }
            served.formUnion(lines)
        }) else { return false }
        return bus.allLines.contains { served.contains(BusTime.canonical($0)) }
    }
}
