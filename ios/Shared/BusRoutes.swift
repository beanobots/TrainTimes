import CoreLocation
import Foundation

/// Each bus line's stops in order each way it runs, with their names and the timetable's minutes
/// between them (bus_routes.json, made by tools/make_bus_routes.py from the MTA's bus GTFS), for
/// changes between a bus and the subway: the stops along a bus ride to change at, the stops near
/// a station to change to, and when a bus gets to a stop further on. Read on first use.
enum BusRoutes {
    struct Stop: Hashable, Sendable {
        /// As on the stop's sign; Bus Time's stop code.
        var code: String
        var latitude: Double
        var longitude: Double
        /// As Bus Time writes it: "4 AV/9 ST".
        var name: String

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

        var busStop: BusStop { BusStop(id: code, name: name, latitude: latitude, longitude: longitude) }
    }

    /// One of a line's stop patterns, one way.
    struct Way: Hashable, Sendable {
        /// Its commonest headsign: "PIER 6 BKLYN BRIDGE PARK via 5 AV".
        var to: String
        var stops: [Stop]
        /// From the first stop, by the timetable, a tenth of a minute.
        var minutes: [Double]
    }

    /// A stop along a ride, with the timetable's minutes to it from where it's boarded.
    struct Ahead: Hashable, Sendable {
        var stop: Stop
        var minutes: Double
    }

    private struct File: Decodable {
        var stops: [[Value]]
        var lines: [String: [Pattern]]

        struct Pattern: Decodable {
            var to: String
            var stops: [Int]
            var minutes: [Double]
        }

        enum Value: Decodable {
            case number(Double)
            case text(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Double.self) {
                    self = .number(number)
                } else {
                    self = .text(try container.decode(String.self))
                }
            }

            var number: Double { if case .number(let value) = self { value } else { 0 } }
            var text: String { if case .text(let value) = self { value } else { "" } }
        }
    }

    private static let loaded: (stops: [Stop], lines: [String: [Way]]) = {
        guard let url = Bundle.main.url(forResource: "bus_routes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return ([], [:]) }
        let stops = file.stops.map { row in
            Stop(code: row[0].text, latitude: row[1].number / 1e5, longitude: row[2].number / 1e5, name: row[3].text)
        }
        let lines = file.lines.mapValues { patterns in
            patterns.map { Way(to: $0.to, stops: $0.stops.map { stops[$0] }, minutes: $0.minutes) }
        }
        return (stops, lines)
    }()

    /// A bus line's name as bus_routes.json is keyed: "M15-SBS" and "M15 SBS" are "M15+".
    static func key(_ line: String) -> String {
        var name = line.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        if name.hasSuffix("SBS") { name = String(name.dropLast(3)) + "+" }
        return name
    }

    static func ways(of line: String) -> [Way] {
        loaded.lines[key(line)] ?? []
    }

    /// The stops after boarding `line` at `code`, each with the timetable's minutes from there:
    /// along the way through it that goes on furthest, preferring one whose headsign starts as
    /// `destination` does.
    static func ahead(on line: String, from code: String, toward destination: String?) -> [Ahead] {
        let through = ways(of: line).compactMap { way -> (way: Way, at: Int)? in
            way.stops.firstIndex { $0.code == code }.map { (way, $0) }
        }
        let going = destination.map { key in through.filter { $0.way.to.hasPrefix(String(key.prefix(8))) } } ?? []
        guard let best = (going.isEmpty ? through : going).max(by: { $0.way.stops.count - $0.at < $1.way.stops.count - $1.at })
        else { return [] }
        let start = best.way.minutes[best.at]
        return best.way.stops.indices.dropFirst(best.at + 1).map { index in
            Ahead(stop: best.way.stops[index], minutes: best.way.minutes[index] - start)
        }
    }

    /// A bus that stops near a place: the line, which way (its headsign), and the nearest of its
    /// stops going that way, with the walk there.
    struct Nearby: Hashable, Sendable {
        var line: String
        var to: String
        var stop: Stop
        var meters: Double

        var walkMinutes: Int { TripPlanner.walkMinutes(meters) }
    }

    /// Every bus going each way with a stop within `walkMinutes`' walk of `location`, nearest
    /// first: each line and headsign once, at its nearest stop.
    static func nearby(_ location: CLLocation, walkMinutes: Int) -> [Nearby] {
        // A walk's minutes are never fewer than as the crow flies at walking pace allows
        let reach = Double(walkMinutes) * 90
        var best: [String: Nearby] = [:]
        for (line, ways) in loaded.lines {
            for way in ways {
                for stop in way.stops {
                    // Cheaply first: about 111 km a degree
                    guard abs(stop.latitude - location.coordinate.latitude) * 111_000 < reach,
                          abs(stop.longitude - location.coordinate.longitude) * 84_000 < reach else { continue }
                    let meters = stop.location.distance(from: location)
                    guard TripPlanner.walkMinutes(meters) <= walkMinutes else { continue }
                    let id = line + "|" + way.to
                    if best[id].map({ meters < $0.meters }) ?? true {
                        best[id] = Nearby(line: line, to: way.to, stop: stop, meters: meters)
                    }
                }
            }
        }
        return best.values.sorted { ($0.meters, $0.line, $0.to) < ($1.meters, $1.line, $1.to) }
    }
}
