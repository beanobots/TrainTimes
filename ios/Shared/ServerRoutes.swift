import CoreLocation
import Foundation
import os

/// Routes by subway and bus between two places, planned on the phone's timetables
/// (`LocalRoutes`) or by the push server's `GET /routes` (server/README.md) without them: for New
/// Trip, and shared directions, whose links don't say which trains. Matched to the app's stations,
/// lines and directions (`trips(from:)`).
enum ServerRoutes {
    /// One route's train rides, in order, as the server sends them.
    struct Route: Decodable, Equatable {
        var legs: [Leg]

        struct Leg: Decodable, Equatable {
            /// The line's short name: "R", "6", "GS", "B63".
            var line: String
            var from: Stop
            var to: Stop
            /// "subway" or "bus"; nil from a server that predates buses, which sends trains only.
            var mode: String? = nil
            /// Where it's going, as on its sign.
            var headsign: String? = nil
            /// Stops ridden, counting the last.
            var stops: Int? = nil
            /// How long the ride takes by the timetable.
            var seconds: Int? = nil
            /// When it leaves by the timetable, in seconds since 1970; nil from a server that
            /// predates it.
            var leaves: Int? = nil

            var isBus: Bool { mode == "bus" }

            /// As a trip's bus ride, its stops and where it's going named as Bus Time's are shown
            /// (`BusStopTimes.readable(_:)`, `BusStopTimes.destination(_:)`).
            var busRide: BusRide {
                let place = { (stop: Stop) in
                    BusRide.Place(name: BusStopTimes.readable(stop.name), latitude: stop.latitude, longitude: stop.longitude)
                }
                return BusRide(line: line, from: place(from), to: place(to), headsign: headsign.map(BusStopTimes.destination),
                               stops: stops, seconds: seconds,
                               leaves: leaves.map { Date(timeIntervalSince1970: TimeInterval($0)) })
            }

            /// How long the ride takes: the timetable's time, or about 2 minutes a stop without one.
            var duration: TimeInterval {
                seconds.map(TimeInterval.init) ?? TimeInterval((stops ?? 5) * 120)
            }
        }

        struct Stop: Decodable, Equatable {
            var name: String
            var latitude: Double
            var longitude: Double

            var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
        }

        /// Whether its first ride starts and its last ends within `meters` of `start` and `end`,
        /// as the crow flies.
        func walks(within meters: Double, from start: CLLocation, to end: CLLocation) -> Bool {
            guard let first = legs.first, let last = legs.last else { return false }
            return first.from.location.distance(from: start) <= meters && last.to.location.distance(from: end) <= meters
        }

        /// Ending at the first of its rides, from its first bus on, that ends within `meters` of
        /// `end` where walking the rest is no more than `changeWorth` slower than riding it by
        /// the timetable's times: a route can add a short second bus a walk would do (the Q17 to
        /// Jamaica, then the Q20 two stops). As it is with no bus, or none of them.
        func trimmed(within meters: Double, of end: CLLocation) -> Route {
            guard let firstBus = legs.firstIndex(where: \.isBus) else { return self }
            for index in legs.indices.dropLast() where index >= firstBus {
                let off = legs[index].to.location
                guard off.distance(from: end) <= meters,
                      TripPlanner.walkSeconds(off.distance(from: end)) <= secondsRiding(after: index, to: end) + Self.changeWorth
                else { continue }
                return Route(legs: Array(legs[...index]))
            }
            return self
        }

        /// What a change is worth avoiding, walking instead, as the timetable's trips count one
        /// on foot against them.
        private static let changeWorth: TimeInterval = 3 * 60

        /// Seconds from getting off ride `index` to `end` riding the rest, by the timetable's times
        /// where it gives them: each walk to the next ride, the wait for it, the ride, and the
        /// walk from the last.
        private func secondsRiding(after index: Int, to end: CLLocation) -> TimeInterval {
            var seconds: TimeInterval = 0
            var off = legs[index].leaves.map { TimeInterval($0) + legs[index].duration }
            for (before, ride) in zip(legs[index...], legs[(index + 1)...]) {
                let walk = BusTrip.change(from: before.to.location, to: ride.from.location)
                let leaves = ride.leaves.map(TimeInterval.init)
                if let off, let leaves, leaves >= off + walk {
                    seconds += leaves - off
                } else {
                    seconds += walk + BusTrip.wait
                }
                seconds += ride.duration
                off = leaves.map { $0 + ride.duration }
            }
            return seconds + TripPlanner.walkSeconds(legs[legs.count - 1].to.location.distance(from: end))
        }
    }

    /// Info.plist's TrainTimesServerURL (`TrainService.serverURL`).
    static var baseURL: URL? { TrainService.serverURL }

    /// `request`'s answer from the push server read as `T`; nil if there's none in time, it isn't
    /// a 200, or it doesn't read.
    static func fetch<T: Decodable>(_ type: T.Type, with request: URLRequest,
                                    decoder: JSONDecoder = JSONDecoder()) async -> T? {
        await fetched(type, with: request, decoder: decoder).value
    }

    /// `fetch`'s answer, and the status it came with (0 with none).
    static func fetched<T: Decodable>(_ type: T.Type, with request: URLRequest,
                                      decoder: JSONDecoder = JSONDecoder()) async -> (value: T?, status: Int) {
        // Only which of the server's paths it is in the log: not its query, which can say where
        // someone is or is going, nor the rest of its path, which can hold a push token
        let path = request.url.flatMap { $0.pathComponents.dropFirst().first }.map { "/" + $0 } ?? "?"
        let data: Data, response: URLResponse
        do {
            (data, response) = try await TrainService.serverSession.data(for: request)
        } catch {
            log.notice("\(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (nil, 0)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            log.notice("\(path, privacy: .public): status \(status)")
            return (nil, status)
        }
        do {
            return (try decoder.decode(type, from: data), status)
        } catch {
            log.error("\(path, privacy: .public): unreadable, \(error.localizedDescription, privacy: .public)")
            return (nil, status)
        }
    }

    /// The push server's failures, in the app, the widgets and the share sheet alike (the app's
    /// `AppLog` writes to a file only the app can, for diagnostics).
    private static let log = Logger(subsystem: "dev.dctp.leeway", category: "Server")

    /// Meters a route's stop may be from the station it's matched to.
    private static let matchRange: Double = 400

    /// Routes from `start` to `end` leaving at `departure`, best first, by bus too with `buses`,
    /// and without trains with `subway` off: planned on the phone (`LocalRoutes`), or without the
    /// timetables for it by the server; nil if neither can, as the server can't be reached or
    /// refuses (e.g. over its daily limit).
    static func routes(from start: CLLocation, to end: CLLocation, at departure: Date = AppClock.now,
                       buses: Bool = false, subway: Bool = true) async -> [Route]? {
        await fetchRoutes(from: start, to: end, at: departure, buses: buses, subway: subway).routes
    }

    /// `routes`, and whether the server refused them as over its daily limit (a 429).
    static func fetchRoutes(from start: CLLocation, to end: CLLocation, at departure: Date = AppClock.now,
                            buses: Bool = false, subway: Bool = true) async -> (routes: [Route]?, overLimit: Bool) {
        // Planned on the phone where its timetables cover the trip: no wait, and no signal needed
        if let planned = await LocalRoutes.routes(from: start, to: end, at: departure, buses: buses, subway: subway) {
            return (planned, false)
        }
        guard let baseURL, var components = URLComponents(url: baseURL.appendingPathComponent("routes"),
                                                          resolvingAgainstBaseURL: false) else { return (nil, false) }
        let point = { (location: CLLocation) in
            String(format: "%.6f,%.6f", location.coordinate.latitude, location.coordinate.longitude)
        }
        components.queryItems = [
            URLQueryItem(name: "from", value: point(start)),
            URLQueryItem(name: "to", value: point(end)),
            URLQueryItem(name: "at", value: String(Int(departure.timeIntervalSince1970))),
        ] + (buses ? [URLQueryItem(name: "bus", value: "1")] : [])
            // Only said when off, for servers from before it, which send trains always
            + (subway ? [] : [URLQueryItem(name: "subway", value: "0")])
        guard let url = components.url else { return (nil, false) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        struct Response: Decodable { var routes: [Route] }
        let answer = await fetched(Response.self, with: request)
        return (answer.value?.routes, answer.status == 429)
    }

    /// The most trips `plan` offers, the planned routes' and the app's own together.
    static let maxOptions = 6

    /// The trips from `start` to `end`: the planned routes (`routes`), and
    /// the app's own (`TripPlanner`), each once, ranked together by when they get there with the
    /// timetable (`TripPlanner.ranked`). The planned routes' come first where they tie, or with no timetable.
    /// The same train changing on to the same end is one trip, changing at each of their stations
    /// (`TripPlanner.joiningChanges(_:)`). Neither walks more than `walkRange` to or from a train.
    /// A trip whose lines another's include, from the same station to the same end, is that one
    /// (`covering(_:)`): the 5 and the 4 or 5 both there at 9:02 are the 4 or 5.
    static func plan(from start: CLLocation, to end: CLLocation,
                     walkRange: Double = TripPlanner.walkRange) async -> [TripPlanner.Trip] {
        await planned(from: start, to: end, walkRange: walkRange).trips
    }

    /// `plan`'s trips, and where there are none, why the app's planner found none
    /// (`TripPlanner.planned`), for No Trip Found to say.
    static func planned(from start: CLLocation, to end: CLLocation,
                        walkRange: Double = TripPlanner.walkRange) async -> (trips: [TripPlanner.Trip],
                                                                             none: TripPlanner.NoTrip?) {
        planned(await routes(from: start, to: end) ?? [], from: start, to: end, walkRange: walkRange)
    }

    /// `plan`'s trips with the planned `routes`, leaving at `now`.
    static func plan(_ routes: [Route], from start: CLLocation, to end: CLLocation,
                     walkRange: Double = TripPlanner.walkRange, at now: Date = AppClock.now) -> [TripPlanner.Trip] {
        planned(routes, from: start, to: end, walkRange: walkRange, at: now).trips
    }

    /// `planned`'s trips and why there are none, with the planned `routes`, leaving at `now`. Nor
    /// the routes' trips whose change takes them away from the end (`TripPlanner.withoutDetours`).
    static func planned(_ routes: [Route], from start: CLLocation, to end: CLLocation,
                        walkRange: Double = TripPlanner.walkRange,
                        at now: Date = AppClock.now) -> (trips: [TripPlanner.Trip], none: TripPlanner.NoTrip?) {
        let found = routes.filter { $0.walks(within: walkRange, from: start, to: end) }
        let google = trips(from: found).filter { !TripPlanner.ridesBack($0) }
        var seen = Set<String>()
        let own = TripPlanner.planned(from: start, to: end, at: now, walkRange: walkRange)
        let joined = TripPlanner.joiningChanges(google + own.trips)
        let planned = covering(joined).filter { trip in
            seen.insert("\(trip.selection.trainID) \(trip.change.map { "\($0.stationID) \($0.routes)" } ?? "")").inserted
        }
        let nearest = TripPlanner.withoutSlowerWalks(TripPlanner.fromNearest(planned, to: start), from: start, to: end, at: now)
        let direct = TripPlanner.withoutDetours(nearest, from: start, to: end, at: now,
                                                timetable: TimetableStore.load(now: now))
        let trips = Array(TripPlanner.ranked(direct, from: start, to: end, at: now).prefix(maxOptions))
        return (trips, trips.isEmpty ? own.none ?? .noTrain : nil)
    }

    /// `trips` with each that another covers (`covers(_:_:)`) left out, the one covering it in
    /// the first one's place.
    static func covering(_ trips: [TripPlanner.Trip]) -> [TripPlanner.Trip] {
        var kept: [TripPlanner.Trip] = []
        for trip in trips where !kept.contains(where: { covers($0, trip) }) {
            guard let index = kept.firstIndex(where: { covers(trip, $0) }) else {
                kept.append(trip)
                continue
            }
            kept[index] = trip
            kept = kept.enumerated().filter { $0.offset == index || !covers(trip, $0.element) }.map(\.element)
        }
        return kept
    }

    /// Whether `trip` takes all `other` does and maybe more: from the same station the same way
    /// to the same end, with its lines and maybe others, and changing, if they do, at each of its
    /// stations to its lines and maybe others.
    static func covers(_ trip: TripPlanner.Trip, _ other: TripPlanner.Trip) -> Bool {
        guard trip.selection.stationID == other.selection.stationID,
              trip.selection.direction == other.selection.direction,
              trip.destination.complex == other.destination.complex,
              Set(other.selection.routes).isSubset(of: trip.selection.routes) else { return false }
        switch (trip.change, other.change) {
        case (nil, nil):
            return true
        case let (change?, otherChange?):
            return change.direction == otherChange.direction
                && change.destination?.complex == otherChange.destination?.complex
                && otherChange.stops.allSatisfy { stop in
                    change.stops.contains { $0.stationID == stop.stationID && Set(stop.routes).isSubset(of: $0.routes) }
                }
        default:
            return false
        }
    }

    /// A trip New Trip offers: by train, with a bus, or walking all the way (Apple Maps' walk,
    /// which New Trip asks for itself).
    enum Choice: Hashable, Sendable {
        case train(SharedTrip.Option)
        case bus(BusTrip)
        case walk(Walk)
        /// With a Citi Bike (New Trip's Bike), which `BikePlanner` plans.
        case bike(BikeTrip)
    }

    /// One of `planWithBuses`'s trips, with the train trip it is, for timing it by the timetable.
    struct Planned {
        var choice: Choice
        var trip: TripPlanner.Trip?
    }

    /// The trips from `start` to `end` with buses as well, for New Trip with Settings › Include
    /// buses: the planned routes by train, bus, two buses, or a bus and one train, in their
    /// order, then the app's own train trips (`TripPlanner`), each once. A route needing more
    /// than one change isn't offered, as a widget shows one, unless it can end sooner a walk from
    /// the end (`Route.trimmed(within:of:)`). The same train changing on to the same end is one
    /// trip, changing at each of their stations, and one whose lines another's include is that
    /// one, as in `plan`. None walks more than `walkRange` to or from a ride, nor rides a train
    /// after its bus back past where it could have been walked to (`ridesBack(_:from:within:)`).
    static func planWithBuses(from start: CLLocation, to end: CLLocation,
                              walkRange: Double = TripPlanner.walkRange) async -> [Planned] {
        planWithBuses(await routes(from: start, to: end, buses: true) ?? [], from: start, to: end, walkRange: walkRange)
    }

    /// `planWithBuses`'s trips with the planned `routes`, leaving at `now`.
    static func planWithBuses(_ routes: [Route], from start: CLLocation, to end: CLLocation,
                              walkRange: Double = TripPlanner.walkRange, at now: Date = AppClock.now) -> [Planned] {
        let google = routes.map { $0.trimmed(within: walkRange, of: end) }
            .filter { $0.walks(within: walkRange, from: start, to: end) }
        var planned: [Planned] = []
        var seen = Set<String>()
        func add(_ trip: TripPlanner.Trip) {
            for index in planned.indices {
                guard let kept = planned[index].trip else { continue }
                // One it covers, or one that covers it, is the one that takes more
                if covers(kept, trip) { return }
                if covers(trip, kept) {
                    planned[index] = Planned(choice: .train(trip.option), trip: trip)
                    planned = planned.enumerated().filter { slot in
                        slot.offset == index || slot.element.trip.map { !covers(trip, $0) } ?? true
                    }.map(\.element)
                    return
                }
                guard let joined = TripPlanner.joining(trip, into: kept) else { continue }
                planned[index] = Planned(choice: .train(joined.option), trip: joined)
                return
            }
            guard seen.insert("\(trip.selection.trainID) \(trip.change.map { "\($0.stationID) \($0.routes)" } ?? "")").inserted
            else { return }
            planned.append(Planned(choice: .train(trip.option), trip: trip))
        }
        // In step-free mode, the routes' trains as `TripPlanner.stepFree(_:)` takes them, as the
        // app's own are; a bus is step-free itself
        let stepFree = SharedStore.loadSettings().stepFree
        for route in google {
            if let trip = busTrip(from: route) {
                guard !ridesBack(trip, from: start, within: walkRange) else { continue }
                if stepFree, let train = trip.train, let end = train.endStation,
                   TripPlanner.stepFree(TripPlanner.Trip(selection: train.selection, change: train.change,
                                                         destination: end)) == nil { continue }
                let key = "\(trip.bus.line) \(trip.bus.from.name) \(trip.train?.selection.trainID ?? "") \(trip.onward?.line ?? "")"
                if seen.insert(key).inserted { planned.append(Planned(choice: .bus(trip))) }
            } else if !route.legs.contains(where: \.isBus), let trip = trips(from: [route]).first,
                      !TripPlanner.ridesBack(trip) {
                guard let kept = stepFree ? TripPlanner.stepFree(trip) : trip else { continue }
                add(kept)
            }
        }
        TripPlanner.ranked(TripPlanner.plan(from: start, to: end, at: now, walkRange: walkRange), from: start, to: end, at: now)
            .forEach(add)
        // The same line from a further station than another trip's, the routes' or the app's, isn't
        // offered, nor one walking more to get there later than another on its line, nor one whose
        // change takes it away from the end (`TripPlanner.withoutDetours`)
        let nearest = TripPlanner.withoutDetours(
            TripPlanner.withoutSlowerWalks(TripPlanner.fromNearest(planned.compactMap(\.trip), to: start),
                                           from: start, to: end, at: now),
            from: start, to: end, at: now, timetable: TimetableStore.load(now: now))
        planned.removeAll { $0.trip.map { !nearest.contains($0) } ?? false }
        return planned.prefix(maxOptions).map { planned in
            guard let trip = planned.trip.map(TripPlanner.changingNearby) else { return planned }
            return Planned(choice: .train(trip.option), trip: trip)
        }
    }

    /// `route` as a bus trip, if it has a bus ride and at most one more ride: a train, which is
    /// matched to a station, line and direction, or another bus; nil otherwise.
    static func busTrip(from route: Route) -> BusTrip? {
        let legs = route.legs
        guard let first = legs.first, legs.contains(where: \.isBus), legs.count <= 2 else { return nil }
        guard legs.count == 2 else { return BusTrip(bus: first.busRide, train: nil, busFirst: true) }
        if legs.allSatisfy(\.isBus) {
            return BusTrip(bus: first.busRide, train: nil, busFirst: true, onward: legs[1].busRide)
        }
        let busFirst = first.isBus
        guard let train = ride(legs[busFirst ? 1 : 0]) else { return nil }
        let option = SharedTrip.Option(selection: Selection(stationID: train.board.id, routes: [train.route],
                                                            direction: train.direction),
                                       destinationID: train.alight.id)
        return BusTrip(bus: legs[busFirst ? 0 : 1].busRide, train: option, busFirst: busFirst)
    }

    /// Whether `trip`'s train, after its bus, calls on the way to its end at a station within
    /// `walkRange` of `start` and nearer it than where the train's boarded, which could have been
    /// walked to: from Park Slope, the B67 up to Atlantic Av-Barclays Ctr for an R back down
    /// through Union St. As `TripPlanner.ridesBack(_:)` is for a train changing to another.
    static func ridesBack(_ trip: BusTrip, from start: CLLocation, within walkRange: Double) -> Bool {
        guard trip.busFirst, let train = trip.train, let board = train.selection.station,
              let alight = train.endStation else { return false }
        let boarded = start.distance(from: board.location)
        let here = Set(board.platforms.map(\.id))
        let ends = Set(StationDirectory.stations(inComplexOf: alight).flatMap(\.platforms).map(\.id))
        for route in train.selection.routes {
            let going = train.selection.direction(of: route)
            for branch in StationDirectory.branches(of: route) {
                guard let from = branch.firstIndex(where: here.contains) else { continue }
                let ahead = going == .north ? Array(branch[..<from].reversed()) : Array(branch[(from + 1)...])
                guard let to = ahead.firstIndex(where: ends.contains) else { continue }
                let passes = ahead[..<to].compactMap(StationDirectory.station(id:)).contains { station in
                    let meters = start.distance(from: station.location)
                    return meters <= walkRange && meters < boarded
                }
                if passes { return true }
            }
        }
        return false
    }

    /// `routes` as trips, in order, leaving out any whose rides can't all be matched: the first
    /// ride as the train, the second as its change, to where that ride ends. Not one of three
    /// rides or more, as a widget has one change: cut short, it'd end at the second ride's stop,
    /// which may be well short of the end.
    static func trips(from routes: [Route]) -> [TripPlanner.Trip] {
        routes.compactMap { route in
            let rides = route.legs.compactMap(ride)
            guard rides.count == route.legs.count, rides.count <= 2, let first = rides.first else { return nil }
            let selection = Selection(stationID: first.board.id, routes: [first.route], direction: first.direction)
            guard rides.count > 1 else {
                return TripPlanner.Trip(selection: selection, destination: first.alight)
            }
            let second = rides[1]
            guard let change = Change(stationID: first.alight.id, routes: [second.route], direction: second.direction,
                                      destinationID: second.alight.id).validated(for: selection) else { return nil }
            return TripPlanner.Trip(selection: selection, change: change, destination: second.alight)
        }
    }

    /// A ride as the app's: its line, the stations it's matched to, and the way it goes.
    private static func ride(_ leg: Route.Leg) -> (route: String, board: Station, alight: Station, direction: Direction)? {
        for route in routeIDs(for: leg.line) {
            guard let board = station(near: leg.from, on: route), let alight = station(near: leg.to, on: route),
                  board.complex != alight.complex,
                  let direction = direction(of: route, from: board, to: alight) else { continue }
            return (route, board, alight, direction)
        }
        return nil
    }

    /// The app's route ids a route's line name could be: itself, as feeds name expresses ("6X"
    /// is the 6), and for "S", each shuttle (which of them is told by the stations).
    private static func routeIDs(for line: String) -> [String] {
        let name = line.trimmingCharacters(in: .whitespaces).uppercased()
        let ids = [name, Lines.normalized(name), name.hasSuffix("X") ? String(name.dropLast()) : name]
        let shuttles = name == "S" || name.hasSuffix(" SHUTTLE") ? ["GS", "FS", "H"] : []
        var seen = Set<String>()
        return (ids + shuttles + (name == "SIR" ? ["SI"] : [])).filter { seen.insert($0).inserted }
    }

    /// The station nearest `stop` that `route` stops at, within `matchRange`.
    private static func station(near stop: Route.Stop, on route: String) -> Station? {
        let location = stop.location
        return StationDirectory.all.filter { $0.routes.contains(route) }
            .map { ($0, location.distance(from: $0.location)) }
            .filter { $0.1 <= matchRange }
            .min { $0.1 < $1.1 }?.0
    }

    /// The feed's N or S for `route` from `origin` to `destination`, by its stops north to south
    /// on one of its branches (`StationDirectory.direction(of:from:to:)`); nil if it doesn't stop
    /// at both, or not on one branch.
    private static func direction(of route: String, from origin: Station, to destination: Station) -> Direction? {
        StationDirectory.direction(of: route, from: Set(origin.platforms.map(\.id)),
                                   to: Set(destination.platforms.map(\.id)))
    }
}

extension TripPlanner.Trip {
    /// As the trip New Trip and the Share sheet show.
    var option: SharedTrip.Option {
        SharedTrip.Option(selection: selection, change: change, destinationID: destination.id)
    }
}
