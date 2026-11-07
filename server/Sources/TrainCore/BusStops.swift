import Foundation

/// Every MTA bus stop and the lines any of its trips stop there on (bus_stop_lines.json, which
/// tools/make_bus_routes.py writes from the bus GTFS), so a bus countdown at a stop there isn't,
/// asked of Bus Time every pass, can be refused when it's registered.
enum BusStops {
    /// Each stop's lines by its code, as `BusTime.canonical` has them, unpadded: "M15+", "Q6"
    /// (the file's names, route_short_name; unpadded too for an older file's or app's "Q06").
    /// Empty if the file couldn't be read, when every stop passes.
    static let lines: [String: Set<String>] = {
        guard let url = Bundle.main.url(forResource: "bus_stop_lines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            Log.error("bus_stop_lines.json couldn't be read: bus countdowns' stops aren't checked")
            return [:]
        }
        return file.mapValues { Set($0.map { BusTime.unpadded(BusTime.canonical($0)) }) }
    }()

    /// Whether `bus`'s stop, and any across the street, are real stops, and at least one of its
    /// lines stops at one of them. Not every line: the app's are those Bus Time has coming there,
    /// which on a detour, or once the timetables change, may not be this file's.
    static func isReal(_ bus: BusChoice) -> Bool {
        refusal(of: bus) == nil
    }

    /// Why `bus` isn't real (`isReal`), with its stop codes and lines, for the log: a stop new in
    /// the GTFS isn't in the file until it's made again and the server redeployed
    /// (server/README.md); nil if it is real.
    static func refusal(of bus: BusChoice) -> String? {
        guard !lines.isEmpty else { return nil }
        let codes = [bus.stop.id] + (bus.otherStop.map { [$0.id] } ?? [])
        let named = "\(bus.allLines.joined(separator: ",")) at \(codes.joined(separator: "/"))"
        let unknown = codes.filter { lines[$0] == nil }
        guard unknown.isEmpty else {
            return "stop \(unknown.joined(separator: "/")) not in bus_stop_lines.json (\(named))"
        }
        let served = codes.reduce(into: Set<String>()) { $0.formUnion(lines[$1] ?? []) }
        guard bus.allLines.contains(where: { served.contains(BusTime.unpadded(BusTime.canonical($0))) }) else {
            return "no line stops there by bus_stop_lines.json (\(named))"
        }
        return nil
    }
}
