import CoreLocation
import Foundation
import SwiftUI
import WidgetKit

// Buses, for New Trip's trips with a bus (Settings › Include buses) and Transit Directions' boards
// for them: the badge that stands in for a line's bullet, a trip's bus ride, the push server's
// MTA Bus Time arrivals (`GET /buses`), and the bus trip shown on Transit Directions.

/// A bus line's badge, the height of the bullet it stands in for: "B63" on the MTA's bus blue,
/// Select Bus Service's ("M86-SBS", "M86+") as "M86" on its lighter blue.
struct BusBadge: View {
    let line: String
    let size: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    /// The MTA's bus blue, and Select Bus Service's.
    static let blue = Color(hex: 0x0039A6)
    static let sbsBlue = Color(hex: 0x0078C6)

    var body: some View {
        let label = Text(Self.label(line))
            .font(.system(size: size * 0.5, weight: .bold))
            .padding(.horizontal, size * 0.22)
            .frame(height: size)
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Group {
            if renderingMode == .fullColor {
                label
                    .foregroundStyle(.white)
                    .background(shape.fill(Self.isSBS(line) ? Self.sbsBlue : Self.blue))
            } else {
                // One colour, as on tinted Home Screens: an outline, as LineBullet's
                label
                    .overlay(shape.stroke(lineWidth: 1.5))
                    .widgetAccentable()
            }
        }
        .fixedSize()
        .accessibilityLabel(Self.spokenName(line))
    }

    /// Whether `line` is Select Bus Service: "M86-SBS", "M86 SBS", "M86+".
    static func isSBS(_ line: String) -> Bool {
        let name = line.uppercased().replacingOccurrences(of: " ", with: "")
        return name.hasSuffix("SBS") || name.hasSuffix("+")
    }

    /// The line without its Select Bus Service mark: "M86".
    static func label(_ line: String) -> String {
        var name = line.trimmingCharacters(in: .whitespaces)
        for mark in ["-SBS", " SBS", "SBS", "+"] where name.uppercased().hasSuffix(mark) {
            name = String(name.dropLast(mark.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return name.isEmpty ? line : name
    }

    /// "B63 bus", "M86 Select Bus".
    static func spokenName(_ line: String) -> String {
        isSBS(line) ? "\(label(line)) Select Bus" : "\(label(line)) bus"
    }
}

/// A trip's bus ride, as Google's route gives it (`ServerRoutes`).
struct BusRide: Codable, Hashable, Sendable {
    /// Google's name for the line: "B63", "M86-SBS".
    var line: String
    var from: Place
    var to: Place
    /// Where the bus is going, as on its sign.
    var headsign: String?
    /// Stops ridden, counting the last.
    var stops: Int?
    /// How long the ride takes by Google's timetable, for timing what comes after it.
    var seconds: Int?

    struct Place: Codable, Hashable, Sendable {
        var name: String
        var latitude: Double
        var longitude: Double

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    /// The ride's time, or about 2 minutes a stop without one.
    var duration: TimeInterval {
        seconds.map(TimeInterval.init) ?? TimeInterval((stops ?? 5) * 120)
    }
}

/// A trip with a bus: the bus alone, or with a train before or after it, which is a trip of its
/// own (`SharedTrip.Option`) to or from where the bus is changed for.
struct BusTrip: Codable, Hashable, Sendable {
    var bus: BusRide
    /// The train: ridden to its `destinationID` after the bus, or before it to where the bus
    /// boards.
    var train: SharedTrip.Option?
    /// Whether the bus comes first; for a bus alone, true.
    var busFirst: Bool

    /// The least a change between the bus and the train takes.
    private static let leastWalk: TimeInterval = 60

    /// Where it starts and ends, by name.
    var startName: String { busFirst ? bus.from.name : train?.selection.station?.name ?? bus.from.name }
    var endName: String { busFirst ? train?.endStation?.name ?? bus.to.name : bus.to.name }

    /// The walk between the bus stop and the station (`TripPlanner.walkSeconds(_:)`), at least
    /// `leastWalk`; none for a bus alone.
    var walk: TimeInterval {
        guard let train else { return 0 }
        let station = busFirst ? train.selection.station : train.endStation
        guard let station else { return Self.leastWalk }
        let stop = busFirst ? bus.to : bus.from
        let meters = stop.location.distance(from: CLLocation(latitude: station.lat, longitude: station.lon))
        return max(Self.leastWalk, TripPlanner.walkSeconds(meters).rounded())
    }
}

/// The next buses at a stop, from the push server's `GET /buses` (MTA Bus Time).
struct BusStopTimes: Codable, Hashable, Sendable {
    var stop: Stop
    var arrivals: [BusArrival]

    struct Stop: Codable, Hashable, Sendable {
        /// The MTA's stop code, as on the stop's sign.
        var id: String
        var name: String
        var latitude: Double
        var longitude: Double
        /// Which way buses leave it, as a compass point.
        var direction: String?
    }
}

extension BusStopTimes {
    /// Bus Time's capitals as a sign has them: "7 AV/9 ST" as "7 Av & 9 St", "via" kept small.
    static func readable(_ name: String) -> String {
        name.capitalized
            .replacingOccurrences(of: " Via ", with: " via ")
            .replacingOccurrences(of: "/", with: " & ")
    }
}

/// A bus line near you, picked from Transit Directions' Nearby: its stop and next buses each way
/// it goes, to pick one, or both, to show.
struct NearbyBusPick: Codable, Hashable, Sendable {
    var line: String
    /// Up to two: the closest stop each way with this line's next buses there.
    var ways: [Way]

    struct Way: Codable, Hashable, Sendable {
        var stop: BusStopTimes.Stop
        /// Where its buses are going, as Bus Time writes it.
        var destination: String?
        /// This line's next buses there, soonest first.
        var arrivals: [BusArrival]

        /// "Pier 6", or the stop's name without a destination.
        var name: String { destination.map(BusStopTimes.readable) ?? BusStopTimes.readable(stop.name) }

        /// As a trip's bus ride, from this stop.
        func ride(line: String) -> BusRide {
            let place = BusRide.Place(name: BusStopTimes.readable(stop.name), latitude: stop.latitude, longitude: stop.longitude)
            return BusRide(line: line, from: place, to: place, headsign: destination.map(BusStopTimes.readable))
        }
    }

    /// The bus trip a tap on `way` shows; with `both`, the other way beside it.
    func shown(way index: Int, both: Bool, at date: Date = .now) -> SharedBusTrip? {
        guard ways.indices.contains(index) else { return nil }
        let other = both ? ways.indices.first { $0 != index }.map { ways[$0].ride(line: line) } : nil
        return SharedBusTrip(trip: BusTrip(bus: ways[index].ride(line: line), train: nil, busFirst: true),
                             shared: date, otherWay: other)
    }

    /// As an intent's parameter, which can't be a type of the app's own.
    var encoded: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    init(line: String, ways: [Way]) {
        self.line = line
        self.ways = ways
    }

    init?(encoded: String) {
        guard let pick = try? JSONDecoder().decode(NearbyBusPick.self, from: Data(encoded.utf8)) else { return nil }
        self = pick
    }

    /// The lines at `ways`' stops, soonest first, up to `limit`: each once, with its buses each way.
    static func lines(at ways: [(stop: BusStopTimes.Stop, arrivals: [BusArrival])], date: Date, limit: Int = 3) -> [NearbyBusPick] {
        let key = { (line: String) in BusBadge.label(line).uppercased() }
        let coming = ways.flatMap { way in way.arrivals.filter { ($0.time ?? .distantPast) > date } }
            .sorted { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
        var lines: [String] = []
        for bus in coming where !lines.map(key).contains(key(bus.line)) {
            lines.append(bus.line)
        }
        return lines.prefix(limit).map { line in
            NearbyBusPick(line: line, ways: ways.compactMap { way in
                let buses = way.arrivals.filter { key($0.line) == key(line) && ($0.time ?? .distantPast) > date }
                guard let first = buses.first else { return nil }
                return Way(stop: way.stop, destination: first.destination, arrivals: Array(buses.prefix(3)))
            })
        }
    }
}

/// A bus place near you, for Transit Directions' Nearby: a stop and the one across from it, its
/// other way, each with its next buses, every line. A card in Nearby's grid as a station is.
struct NearbyBusPlace: Codable, Hashable, Sendable {
    /// One or two: the nearest first.
    var ways: [NearbyBusPick.Way]
    /// From where you were, to the nearer stop.
    var meters: Double

    /// The nearer stop's name, as a sign has it: "5 Av & 9 St".
    var name: String { ways.first.map { BusStopTimes.readable($0.stop.name) } ?? "" }

    /// As `Nearby.Result.walkMinutes` works it out for a station.
    var walkMinutes: Int { max(1, Int((TripPlanner.walkSeconds(meters) / 60).rounded())) }

    /// Its lines, soonest first, each with its stop and buses each way.
    func lines(at date: Date) -> [NearbyBusPick] {
        NearbyBusPick.lines(at: ways.map { ($0.stop, $0.arrivals) }, date: date, limit: 9)
    }

    /// As an intent's parameter.
    var encoded: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    init(ways: [NearbyBusPick.Way], meters: Double) {
        self.ways = ways
        self.meters = meters
    }

    init?(encoded: String) {
        guard let place = try? JSONDecoder().decode(NearbyBusPlace.self, from: Data(encoded.utf8)) else { return nil }
        self = place
    }
}

/// One bus on its way to a stop.
struct BusArrival: Codable, Hashable, Sendable {
    /// The line as the bus shows it: "B63", "M15-SBS".
    var line: String
    var destination: String?
    /// When Bus Time expects it, from where the bus is now.
    var expected: Date?
    /// When the timetable has it: all there is for a bus yet to leave its terminal.
    var aimed: Date?
    /// Stops it has yet to make before this one.
    var stopsAway: Int?
    /// Bus Time's words for how far it is: "approaching", "1.2 miles away".
    var distance: String?

    /// When it's due: as expected, or by the timetable.
    var time: Date? { expected ?? aimed }
    /// A prediction from where the bus is, rather than the timetable's.
    var isLive: Bool { expected != nil }
}

enum BusTimes {
    /// The next buses on `line` at its stop where `place` is, soonest first, those still to come
    /// at `now`; nil if the server can't be reached, has no Bus Time key, or finds no stop.
    static func arrivals(line: String, at place: BusRide.Place, now: Date = .now) async -> BusStopTimes? {
        guard let baseURL = ServerRoutes.baseURL else { return nil }
        // "+" escaped too, which the server would read as a space ("M15+" as the M15)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,")
        let escape = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let stop = String(format: "%.6f,%.6f", place.latitude, place.longitude)
        var components = URLComponents(url: baseURL.appendingPathComponent("buses"), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = "line=\(escape(line))&stop=\(escape(stop))"
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              var times = try? JSONDecoder().decode(BusStopTimes.self, from: data) else { return nil }
        times.arrivals = times.arrivals
            .filter { ($0.time ?? .distantPast) > now }
            .sorted { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
        return times
    }
}

/// A trip with a bus picked in New Trip, which Transit Directions shows for an hour, as it does a
/// shared trip (`SharedTrip`); showing either replaces the other.
struct SharedBusTrip: Codable, Hashable, Sendable {
    var trip: BusTrip
    var shared: Date
    /// For a bus alone picked both ways on Nearby: the other way, shown beside it.
    var otherWay: BusRide? = nil

    var expires: Date { shared.addingTimeInterval(SharedTrip.duration) }

    /// Whether it's showing at `date`: not before it was shared (clock set back), as
    /// `SharedTrip.isActive(at:)`, as it would otherwise show until then.
    func isActive(at date: Date) -> Bool {
        shared <= date && date < expires
    }

    /// Shows it on Transit Directions for an hour from `shared`, in place of any other trip.
    func show() {
        SharedStore.saveSharedBusTrip(self)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.directions)
    }
}

extension SharedStore {
    private static let busTripFile = url(named: "shared-bus-trip.json")

    /// The bus trip, if it's still showing at `date`, with its train checked against the station
    /// list; nil if that train's gone.
    static func loadSharedBusTrip(at date: Date = .now) -> SharedBusTrip? {
        guard let busTripFile, let data = try? Data(contentsOf: busTripFile),
              var shown = try? JSONDecoder().decode(SharedBusTrip.self, from: data),
              shown.isActive(at: date) else { return nil }
        if let train = shown.trip.train {
            guard let valid = train.validated() else { return nil }
            shown.trip.train = valid
        }
        return shown
    }

    /// Replaces any trip shown, bus or not; nil ends it. A shared trip saved after it ends it too
    /// (`saveSharedTrip`).
    static func saveSharedBusTrip(_ shown: SharedBusTrip?) {
        guard let busTripFile else { return }
        guard let shown, let data = try? JSONEncoder().encode(shown) else {
            try? FileManager.default.removeItem(at: busTripFile)
            return
        }
        saveSharedTrip(nil)
        try? data.write(to: busTripFile, options: .atomic)
    }

    /// Ends the bus trip, for `saveSharedTrip`, which replaces it or ends both.
    static func removeSharedBusTrip() {
        guard let busTripFile else { return }
        try? FileManager.default.removeItem(at: busTripFile)
    }
}

/// Nearby's buses, with its "Bus" switch on: the bus places near you (a stop and the one across
/// from it) and their next buses, from the push server's `GET /buses/nearby` (server/README.md),
/// which keeps Bus Time's key. Drawn in Nearby's grid as stations are.
enum NearbyBuses {
    /// One stop, as the server sends it, with its next buses, every line.
    struct Way: Codable, Hashable, Sendable {
        /// Its name as Bus Time writes it: "7 AV/9 ST".
        var stop: BusStopTimes.Stop
        /// From where you were.
        var meters: Double
        var arrivals: [BusArrival]
    }

    /// The bus places near `location`, nearest first: none with no stop within a quarter mile;
    /// nil if the server can't be reached or has no Bus Time key. From a server that predates
    /// places, its one place's ways.
    static func places(near location: CLLocation) async -> [NearbyBusPlace]? {
        guard let baseURL = ServerRoutes.baseURL,
              var components = URLComponents(url: baseURL.appendingPathComponent("buses/nearby"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "at", value: String(format: "%.5f,%.5f", location.coordinate.latitude,
                                                                          location.coordinate.longitude))]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: wait)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        struct Response: Decodable { var ways: [Way]; var places: [[Way]]? }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return (decoded.places ?? [decoded.ways]).filter { !$0.isEmpty }.map(place)
    }

    /// The server's stops as a place.
    static func place(_ ways: [Way]) -> NearbyBusPlace {
        NearbyBusPlace(ways: ways.map { NearbyBusPick.Way(stop: $0.stop, destination: nil, arrivals: $0.arrivals) },
                       meters: ways.map(\.meters).min() ?? 0)
    }

    /// How long Nearby waits for its buses before drawing without them.
    static let wait: TimeInterval = 3
}

/// Nearby's buses, as found on its reload.
enum NearbyBusList: Hashable {
    /// Nearest first; none with no stop within a quarter mile.
    case places([NearbyBusPlace])
    /// The server couldn't say.
    case unavailable
    /// On Nearby's face, drawn at once on a tap, before they're fetched.
    case finding

    var places: [NearbyBusPlace] {
        if case .places(let places) = self { return places }
        return []
    }
}
