import CoreLocation
import Foundation
import os

/// Trips planned on the phone (`TransitPlanner`) on the timetables it's downloaded
/// (`TimetableStore`), as the server's `GET /routes` would send them: no wait for the server, and
/// with no signal too. Only where the timetables for what's asked cover the trip: the buses'
/// isn't in widgets or the Share extension, nor downloaded in Low Data Mode, and then the server
/// plans it (`ServerRoutes.fetchRoutes`).
enum LocalRoutes {
    /// Trips from `start` to `end` leaving at `departure`, best first, by bus too with `buses`,
    /// and without trains with `subway` off; nil if a timetable that's needed isn't here or
    /// doesn't cover `departure`.
    static func routes(from start: CLLocation, to end: CLLocation, at departure: Date = AppClock.now,
                       buses: Bool = false, subway: Bool = true) async -> [ServerRoutes.Route]? {
        var modes: Set<TransitRoute.Mode> = subway || !buses ? [.subway] : []
        if buses { modes.insert(.bus) }
        guard let network = await networks.network(buses: modes.contains(.bus), subway: modes.contains(.subway),
                                                   at: departure) else { return nil }
        let from = (start.coordinate.latitude, start.coordinate.longitude)
        let to = (end.coordinate.latitude, end.coordinate.longitude)
        let clock = ContinuousClock()
        let started = clock.now
        let routes = await Task.detached(priority: .userInitiated) {
            TransitPlanner.routes(on: network, from: from, to: to, departure: departure, modes: modes)
        }.value
        log.info("planned \(routes.count) in \(clock.now - started, privacy: .public)")
        return routes.map(ServerRoutes.Route.init)
    }

    /// The network built for what's asked, ahead of planning on it: New Trip asks when it opens,
    /// so the first trip planned doesn't wait for it.
    static func prepare(buses: Bool, subway: Bool = true) async {
        _ = await networks.network(buses: buses, subway: subway || !buses, at: AppClock.now)
    }

    private static let networks = Networks()
    private static let log = Logger(subsystem: "dev.dctp.leeway", category: "LocalRoutes")

    /// The network for the timetables downloaded, built again once either is newer, and with the
    /// buses' only once a trip by bus is asked for: it's some 15 MB more to hold. A build takes
    /// a moment, so a plan meanwhile waits for it, and so does one asking at the same time.
    private actor Networks {
        private var built: TransitNetwork?
        private var building: (key: Key, task: Task<TransitNetwork?, Never>)?

        /// Which timetables a network's built from, by when each was made.
        private struct Key: Equatable {
            var subway: Date?
            var buses: Date?
        }

        /// The network with the subway's timetable for `subway` and the buses' for `buses`, each
        /// covering `date`; nil if one isn't here or doesn't.
        func network(buses: Bool, subway: Bool, at date: Date) async -> TransitNetwork? {
            let read = await Task.detached(priority: .userInitiated) {
                (subway ? TimetableStore.load(now: date) : nil, buses ? TimetableStore.buses.load(now: date) : nil)
            }.value
            guard !subway || read.0 != nil, !buses || read.1 != nil else { return nil }
            let wanted = Key(subway: read.0?.made, buses: read.1?.made)
            // One with more than's wanted will do: the buses' kept, once built, for the subway alone
            if let built, Self.covers(Key(subway: built.subwayMade, buses: built.busMade), wanted) { return built }
            if let building, Self.covers(building.key, wanted), let network = await building.task.value { return network }
            let (subwayTimetable, busTimetable) = read
            let task = Task.detached(priority: .userInitiated) { () -> TransitNetwork? in
                let clock = ContinuousClock()
                let started = clock.now
                let network = TransitNetwork(subway: subwayTimetable, buses: busTimetable)
                LocalRoutes.log.info("built \(network.stops.count) stops, \(network.patterns.count) patterns in \(clock.now - started, privacy: .public)")
                return network
            }
            building = (wanted, task)
            let network = await task.value
            if building?.task == task { building = nil }
            if let network { built = network }
            return network
        }

        /// Whether a network built from `have` has what `wanted` needs: the same timetables, or
        /// one more than's wanted.
        private static func covers(_ have: Key, _ wanted: Key) -> Bool {
            (wanted.subway == nil || have.subway == wanted.subway) && (wanted.buses == nil || have.buses == wanted.buses)
        }
    }
}

extension ServerRoutes.Route {
    /// A trip the phone planned, as the server would send it.
    init(_ route: TransitRoute) {
        let stop = { (stop: TransitRoute.Stop) in Stop(name: stop.name, latitude: stop.latitude, longitude: stop.longitude) }
        self.init(legs: route.legs.map { leg in
            Leg(line: leg.line, from: stop(leg.from), to: stop(leg.to), mode: leg.mode.rawValue, headsign: leg.headsign,
                stops: leg.stops, seconds: leg.seconds, leaves: leg.leaves)
        })
    }
}
