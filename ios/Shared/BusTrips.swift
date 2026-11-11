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
    static func isSBS(_ line: String) -> Bool { BusNames.isSBS(line) }

    /// The line without its Select Bus Service mark: "M86".
    static func label(_ line: String) -> String { BusNames.label(line) }

    /// "B63 bus", "M86 Select Bus".
    static func spokenName(_ line: String) -> String {
        isSBS(line) ? "\(label(line)) Select Bus" : "\(label(line)) bus"
    }
}

/// A trip's bus ride, as a planned route gives it (`ServerRoutes`).
struct BusRide: Codable, Hashable, Sendable {
    /// The line's name: "B63", "M86+".
    var line: String
    var from: Place
    var to: Place
    /// Where the bus is going, as on its sign.
    var headsign: String?
    /// Stops ridden, counting the last.
    var stops: Int?
    /// How long the ride takes by the timetable, for timing what comes after it.
    var seconds: Int?
    /// When it leaves by the timetable, for timing the trip in New Trip.
    var leaves: Date? = nil

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

/// A trip with a bus: the bus alone, with a train before or after it, which is a trip of its
/// own (`SharedTrip.Option`) to or from where the bus is changed for, or with a second bus.
struct BusTrip: Codable, Hashable, Sendable {
    var bus: BusRide
    /// The train: ridden to its `destinationID` after the bus, or before it to where the bus
    /// boards.
    var train: SharedTrip.Option?
    /// Whether the bus comes first; for a bus alone, true.
    var busFirst: Bool
    /// The bus changed to after `bus`, for a trip by two buses, without a train.
    var onward: BusRide? = nil

    /// The least a change between the bus and the train takes.
    private static let leastWalk: TimeInterval = 60
    /// The wait counted for a bus where the timetable doesn't say when it leaves, or it
    /// leaves before you can be there: about half the time between buses on most lines.
    static let wait: TimeInterval = 5 * 60

    /// Where it starts and ends, by name.
    var startName: String { busFirst ? bus.from.name : train?.selection.station?.name ?? bus.from.name }
    var endName: String { busFirst ? train?.endStation?.name ?? onward?.to.name ?? bus.to.name : bus.to.name }

    /// The walk between the bus stop and the station, or the second bus's stop (`change(from:to:)`);
    /// none for a bus alone.
    var walk: TimeInterval {
        if let onward { return Self.change(from: bus.to.location, to: onward.from.location) }
        guard let train else { return 0 }
        let station = busFirst ? train.selection.station : train.endStation
        guard let station else { return Self.leastWalk }
        return Self.change(from: (busFirst ? bus.to : bus.from).location, to: station.location)
    }

    /// The walk for a change from `off` to `on` (`TripPlanner.walkSeconds(_:)`), at least
    /// `leastWalk`.
    static func change(from off: CLLocation, to on: CLLocation) -> TimeInterval {
        max(leastWalk, TripPlanner.walkSeconds(off.distance(from: on)).rounded())
    }

    /// About when it gets from `start` to `end` leaving at `now`, walks included, for ranking
    /// it with the train trips: each bus when the timetable has it leave, or `wait` after
    /// you're at its stop, for the timetable's time for the ride (`BusRide.duration`); the train by the
    /// timetable (`TripPlanner.arrival`). Only an estimate, as Bus Time isn't asked; nil without a
    /// timetable to time its train by.
    func arrival(from start: CLLocation, to end: CLLocation, at now: Date, timetable: Timetable?) -> Date? {
        func ride(_ bus: BusRide, from ready: Date) -> Date {
            let leaves = bus.leaves.flatMap { $0 >= ready ? $0 : nil } ?? ready.addingTimeInterval(Self.wait)
            return leaves.addingTimeInterval(bus.duration)
        }
        let atStop = now.addingTimeInterval(TripPlanner.walkSeconds(start.distance(from: bus.from.location)))
        guard let train else {
            let off = ride(bus, from: atStop)
            guard let onward else { return off.addingTimeInterval(TripPlanner.walkSeconds(bus.to.location.distance(from: end))) }
            return ride(onward, from: off.addingTimeInterval(walk))
                .addingTimeInterval(TripPlanner.walkSeconds(onward.to.location.distance(from: end)))
        }
        guard let timetable, let station = train.selection.station, let last = train.endStation else { return nil }
        let trip = TripPlanner.Trip(selection: train.selection, destination: last)
        if busFirst {
            // From the bus stop, the walk to the station as the timetable's trips count it
            return TripPlanner.arrival(of: trip, from: bus.to.location, to: end, at: ride(bus, from: atStop),
                                       timetable: timetable)
        }
        let atStation = now.addingTimeInterval(TripPlanner.walkSeconds(start.distance(from: station.location)))
        guard let off = TripPlanner.arrival(of: trip, from: station.location, to: last.location, at: atStation,
                                            timetable: timetable) else { return nil }
        return ride(bus, from: off.addingTimeInterval(walk))
            .addingTimeInterval(TripPlanner.walkSeconds(bus.to.location.distance(from: end)))
    }

    /// `arrival`'s minutes from `now`, as New Trip shows a trip's.
    func minutes(from start: CLLocation, to end: CLLocation, at now: Date, timetable: Timetable?) -> Int? {
        arrival(from: start, to: end, at: now, timetable: timetable).map { Int($0.timeIntervalSince(now) / 60) }
    }

    /// What counts against it in ranking beside other trips, on top of its minutes, in seconds:
    /// the whole wait for a first bus (buses bunch and run late, so standing at the stop counts
    /// in full), a change on foot for changing to the train or second bus, and
    /// `TripPlanner.walkWeight` of the walks at the ends.
    func penalty(from start: CLLocation, to end: CLLocation, at now: Date, timetable: Timetable?) -> TimeInterval {
        let changing = train != nil || onward != nil ? TripPlanner.changeCost(across: false) : 0
        func walked(_ a: CLLocation, _ b: CLLocation) -> TimeInterval {
            TripPlanner.walkSeconds(a.distance(from: b)) * TripPlanner.walkWeight
        }
        guard busFirst else {
            // The train first: its penalty has the walk to it; then the bus's walk off
            let walkOff = walked(bus.to.location, end)
            guard let train, let timetable, let last = train.endStation else { return changing + walkOff }
            let trip = TripPlanner.Trip(selection: train.selection, destination: last)
            return changing + walkOff + (TripPlanner.penalty(of: trip, from: start, to: last.location, at: now,
                                                             timetable: timetable) ?? 0)
        }
        let atStop = now.addingTimeInterval(TripPlanner.walkSeconds(start.distance(from: bus.from.location)))
        let wait = bus.leaves.flatMap { $0 >= atStop ? $0.timeIntervalSince(atStop) : nil } ?? Self.wait
        let lastStop = train?.endStation?.location ?? onward?.to.location ?? bus.to.location
        return changing + wait + walked(start, bus.from.location) + walked(lastStop, end)
    }
}

/// The next buses at a stop, from the push server's `GET /buses` (MTA Bus Time).
struct BusStopTimes: Codable, Hashable, Sendable {
    var stop: Stop
    var arrivals: [BusArrival]

    typealias Stop = BusStop
}

extension BusStop {
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

extension BusChoice {
    /// Where `BusTimes` looks for the stop.
    var place: BusRide.Place {
        BusRide.Place(name: stopName, latitude: stop.latitude, longitude: stop.longitude)
    }
}

extension BusStopTimes {
    /// See `BusNames.readable(_:)`.
    static func readable(_ name: String) -> String { BusNames.readable(name) }

    /// See `BusNames.destination(_:)`.
    static func destination(_ name: String) -> String { BusNames.destination(name) }
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
        var name: String { destination.map(BusStopTimes.destination) ?? BusStopTimes.readable(stop.name) }

        /// As a trip's bus ride, from this stop.
        func ride(line: String) -> BusRide {
            let place = BusRide.Place(name: BusStopTimes.readable(stop.name), latitude: stop.latitude, longitude: stop.longitude)
            return BusRide(line: line, from: place, to: place, headsign: destination.map(BusStopTimes.destination))
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
        // Each line's label worked out once, not for every bus against every line: Nearby asks
        // this many times each time it's drawn
        var labels: [String: String] = [:]
        func key(_ line: String) -> String {
            if let label = labels[line] { return label }
            let label = BusBadge.label(line).uppercased()
            labels[line] = label
            return label
        }
        let coming = ways.flatMap { way in way.arrivals.filter { ($0.time ?? .distantPast) > date } }
            .sorted { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
        var lines: [String] = []
        var seen: Set<String> = []
        for bus in coming where seen.insert(key(bus.line)).inserted {
            lines.append(bus.line)
        }
        return lines.prefix(limit).map { line in
            let lineKey = key(line)
            return NearbyBusPick(line: line, ways: ways.compactMap { way in
                let buses = way.arrivals.filter { key($0.line) == lineKey && ($0.time ?? .distantPast) > date }
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
    var walkMinutes: Int { TripPlanner.walkMinutes(meters) }

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

    /// Seconds apart two of the same line's buses going the same way can be and still be one
    /// bus listed twice: Bus Time lists one now and then twice, and a line asked for under two
    /// names ("Q6", "Q06") comes back twice.
    static let sameBus: TimeInterval = 5

    /// `arrivals` (soonest first) without a bus listed again: the same line (`BusRoutes.key`),
    /// destination and live or not, due within `sameBus` of it. Bus Time gives no vehicle to tell
    /// them by; two real buses that close are the same bus.
    static func withoutRepeats(_ arrivals: [BusArrival]) -> [BusArrival] {
        var kept: [BusArrival] = []
        var keys: [String] = []
        for bus in arrivals {
            let key = BusRoutes.key(bus.line) + "|" + (bus.destination ?? "") + (bus.isLive ? "|live" : "")
            // Only those kept within `sameBus` before it, as they're soonest first
            let repeated = bus.time.map { time in
                kept.indices.reversed()
                    .prefix { kept[$0].time.map { time.timeIntervalSince($0) <= sameBus } ?? true }
                    .contains { keys[$0] == key && kept[$0].time.map { abs($0.timeIntervalSince(time)) <= sameBus } == true }
            } ?? false
            if repeated { continue }
            kept.append(bus)
            keys.append(key)
        }
        return kept
    }
}

enum BusTimes {
    /// `arrivals(line:at:now:)` for each of `lines`, merged soonest first; nil if none could be
    /// fetched. Each line's a request of its own, as the server takes one. With `stopID`, only
    /// lines found at that stop, not one whose nearest stop is across the street (as the push
    /// server counts down at the chosen stop alone).
    static func arrivals(lines: [String], at place: BusRide.Place, onlyAt stopID: String? = nil,
                         now: Date = AppClock.now) async -> BusStopTimes? {
        let atStop = { (times: BusStopTimes) in stopID.map { $0 == times.stop.id } ?? true }
        if lines.count < 2 {
            guard let line = lines.first, let times = await arrivals(line: line, at: place, now: now),
                  atStop(times) else { return nil }
            return times
        }
        let found = await withTaskGroup(of: BusStopTimes?.self) { group in
            for line in lines {
                group.addTask { await arrivals(line: line, at: place, now: now) }
            }
            var found: [BusStopTimes] = []
            for await times in group { if let times, atStop(times) { found.append(times) } }
            return found
        }
        guard let stop = found.first?.stop else { return nil }
        let merged = found.flatMap(\.arrivals).sorted { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
        return BusStopTimes(stop: stop, arrivals: BusArrival.withoutRepeats(merged))
    }

    /// The next buses on `line` at its stop where `place` is, soonest first, those still to come
    /// at `now`; nil if the server can't be reached, has no Bus Time key, or finds no stop. Without
    /// the server, the timetable's (`BusSchedule`).
    static func arrivals(line: String, at place: BusRide.Place, now: Date = AppClock.now) async -> BusStopTimes? {
        // Not Bus Time's real buses while Pretend Time is on (`AppClock`)
        if !AppClock.isPretending, let live = await liveArrivals(line: line, at: place, now: now) { return live }
        return BusSchedule.times(line: line, at: place, now: now)
    }

    /// Bus Time's, through the server.
    private static func liveArrivals(line: String, at place: BusRide.Place, now: Date) async -> BusStopTimes? {
        guard let baseURL = ServerRoutes.baseURL else { return nil }
        // "+" escaped too, which the server would read as a space ("M15+" as the M15)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,")
        let escape = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let stop = String(format: "%.6f,%.6f", place.latitude, place.longitude)
        var components = URLComponents(url: baseURL.appendingPathComponent("buses"), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = "line=\(escape(line))&stop=\(escape(stop))"
        guard let url = components?.url else { return nil }
        guard var times = await asked.times(from: url) else { return nil }
        times.arrivals = BusArrival.withoutRepeats(times.arrivals
            .filter { ($0.time ?? .distantPast) > now }
            .sorted { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) })
        return times
    }

    /// How long the push server keeps Bus Time's answer, so asking again sooner gets the same.
    static let reuse: TimeInterval = 30

    private static let asked = Asked()

    /// The server's answers this process has had, each kept `reuse`, and those on their way: a
    /// stop and line asked twice at once (a widget and its other way, or Nearby's) is asked once.
    private actor Asked {
        private var answers: [URL: (asked: Date, task: Task<BusStopTimes?, Never>)] = [:]

        func times(from url: URL) async -> BusStopTimes? {
            let now = Date.now
            answers = answers.filter { $0.value.asked.isWithin(BusTimes.reuse, before: now) }
            if let kept = answers[url] { return await kept.task.value }
            let task = Task { () -> BusStopTimes? in
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                return await ServerRoutes.fetch(BusStopTimes.self, with: request)
            }
            answers[url] = (now, task)
            let times = await task.value
            // A failure isn't kept: the next ask tries again
            if times == nil, answers[url]?.asked == now { answers[url] = nil }
            return times
        }
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
    /// places, its one place's ways. Waits `wait` for the server, which for a place it hasn't
    /// kept the stops of asks Bus Time twice in turn. Without the server, the timetable's
    /// (`BusSchedule`).
    static func places(near location: CLLocation, wait: TimeInterval = wait) async -> [NearbyBusPlace]? {
        if !AppClock.isPretending, let live = await livePlaces(near: location, wait: wait) { return live }
        return BusSchedule.places(near: location)
    }

    /// Bus Time's, through the server.
    private static func livePlaces(near location: CLLocation, wait: TimeInterval) async -> [NearbyBusPlace]? {
        guard let baseURL = ServerRoutes.baseURL,
              var components = URLComponents(url: baseURL.appendingPathComponent("buses/nearby"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "at", value: String(format: "%.5f,%.5f", location.coordinate.latitude,
                                                                          location.coordinate.longitude))]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: wait)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        struct Response: Decodable { var ways: [Way]; var places: [[Way]]? }
        guard let decoded = await ServerRoutes.fetch(Response.self, with: request) else { return nil }
        return (decoded.places ?? [decoded.ways]).filter { !$0.isEmpty }.map(place)
    }

    /// The server's stops as a place.
    static func place(_ ways: [Way]) -> NearbyBusPlace {
        NearbyBusPlace(ways: ways.map { NearbyBusPick.Way(stop: $0.stop, destination: nil, arrivals: $0.arrivals) },
                       meters: ways.map(\.meters).min() ?? 0)
    }

    /// How long the Nearby widget waits for its buses before drawing without them.
    static let wait: TimeInterval = 3
    /// How long the app's Nearby waits: its trains and docks draw meanwhile, and a place newly
    /// moved to can take the server longer than the widget's wait.
    static let appWait: TimeInterval = 12
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
