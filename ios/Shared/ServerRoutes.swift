import CoreLocation
import Foundation

/// Google's subway routes for shared directions, from the push server's `GET /routes`
/// (server/README.md), which keeps Google's key: the trains the maps apps recommend, as their
/// links don't say. Matched to the app's stations, lines and directions (`trips(from:)`).
enum ServerRoutes {
    /// One route's train rides, in order, as the server sends them.
    struct Route: Decodable, Equatable {
        var legs: [Leg]

        struct Leg: Decodable, Equatable {
            /// Google's short name for the line: "R", "6", "S", "B63".
            var line: String
            var from: Stop
            var to: Stop
            /// "subway" or "bus"; nil from a server that predates buses, which sends trains only.
            var mode: String? = nil
            /// Where it's going, as on its sign.
            var headsign: String? = nil
            /// Stops ridden, counting the last.
            var stops: Int? = nil
            /// How long the ride takes by Google's timetable.
            var seconds: Int? = nil

            var isBus: Bool { mode == "bus" }

            /// As a trip's bus ride.
            var busRide: BusRide {
                BusRide(line: line,
                        from: BusRide.Place(name: from.name, latitude: from.latitude, longitude: from.longitude),
                        to: BusRide.Place(name: to.name, latitude: to.latitude, longitude: to.longitude),
                        headsign: headsign, stops: stops, seconds: seconds)
            }
        }

        struct Stop: Decodable, Equatable {
            var name: String
            var latitude: Double
            var longitude: Double

            var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
        }
    }

    /// Info.plist's TrainTimesServerURL.
    static let baseURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "TrainTimesServerURL") as? String)
        .flatMap { URL(string: $0.hasSuffix("/") ? String($0.dropLast()) : $0) }

    /// Meters a stop Google names may be from the station it's matched to.
    private static let matchRange: Double = 400

    /// Google's routes from `start` to `end` leaving at `departure`, best first, by bus too with
    /// `buses`; nil if the server can't be reached, refuses (e.g. over its daily limit) or has no
    /// Google key.
    static func routes(from start: CLLocation, to end: CLLocation, at departure: Date = .now,
                       buses: Bool = false) async -> [Route]? {
        guard let baseURL, var components = URLComponents(url: baseURL.appendingPathComponent("routes"),
                                                          resolvingAgainstBaseURL: false) else { return nil }
        let point = { (location: CLLocation) in
            String(format: "%.6f,%.6f", location.coordinate.latitude, location.coordinate.longitude)
        }
        components.queryItems = [
            URLQueryItem(name: "from", value: point(start)),
            URLQueryItem(name: "to", value: point(end)),
            URLQueryItem(name: "at", value: String(Int(departure.timeIntervalSince1970))),
        ] + (buses ? [URLQueryItem(name: "bus", value: "1")] : [])
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        struct Response: Decodable { var routes: [Route] }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return decoded.routes
    }

    /// The most trips `plan` offers, Google's and the app's together.
    static let maxOptions = 6

    /// The trips from `start` to `end`: Google's routes, the trains the maps apps recommend, and
    /// the app's own (`TripPlanner`), each once, ranked together by when they get there with the
    /// timetable (`TripPlanner.ranked`). Google's come first where they tie, or with no timetable.
    /// The same train changing on to the same end is one trip, changing at each of their stations
    /// (`TripPlanner.joiningChanges(_:)`).
    static func plan(from start: CLLocation, to end: CLLocation) async -> [TripPlanner.Trip] {
        let google = await routes(from: start, to: end).map(trips(from:)) ?? []
        var seen = Set<String>()
        let planned = TripPlanner.joiningChanges(google + TripPlanner.plan(from: start, to: end)).filter { trip in
            seen.insert("\(trip.selection.trainID) \(trip.change.map { "\($0.stationID) \($0.routes)" } ?? "")").inserted
        }
        return Array(TripPlanner.ranked(planned, from: start, to: end).prefix(maxOptions))
    }

    /// A trip New Trip offers: by train, or with a bus.
    enum Choice: Hashable, Sendable {
        case train(SharedTrip.Option)
        case bus(BusTrip)
    }

    /// One of `planWithBuses`'s trips, with the train trip it is, for timing it by the timetable.
    struct Planned {
        var choice: Choice
        var trip: TripPlanner.Trip?
    }

    /// The trips from `start` to `end` with buses as well, for New Trip with Settings › Include
    /// buses: Google's routes by train, bus, or a bus and one train, in Google's order, then the
    /// app's own train trips (`TripPlanner`), each once. A route needing more than one change
    /// isn't offered, as a widget shows one. The same train changing on to the same end is one
    /// trip, changing at each of their stations, as in `plan`.
    static func planWithBuses(from start: CLLocation, to end: CLLocation) async -> [Planned] {
        let google = await routes(from: start, to: end, buses: true) ?? []
        var planned: [Planned] = []
        var seen = Set<String>()
        func add(_ trip: TripPlanner.Trip) {
            for index in planned.indices {
                guard let kept = planned[index].trip, let joined = TripPlanner.joining(trip, into: kept) else { continue }
                planned[index] = Planned(choice: .train(joined.option), trip: joined)
                return
            }
            guard seen.insert("\(trip.selection.trainID) \(trip.change.map { "\($0.stationID) \($0.routes)" } ?? "")").inserted
            else { return }
            planned.append(Planned(choice: .train(trip.option), trip: trip))
        }
        for route in google {
            if let trip = busTrip(from: route) {
                let key = "\(trip.bus.line) \(trip.bus.from.name) \(trip.train?.selection.trainID ?? "")"
                if seen.insert(key).inserted { planned.append(Planned(choice: .bus(trip))) }
            } else if !route.legs.contains(where: \.isBus), let trip = trips(from: [route]).first {
                add(trip)
            }
        }
        TripPlanner.ranked(TripPlanner.plan(from: start, to: end), from: start, to: end).forEach(add)
        return planned.prefix(maxOptions).map { planned in
            guard let trip = planned.trip.map(TripPlanner.changingNearby) else { return planned }
            return Planned(choice: .train(trip.option), trip: trip)
        }
    }

    /// `route` as a bus trip, if it has one bus ride and at most one train ride, which is matched
    /// to a station, line and direction; nil otherwise.
    static func busTrip(from route: Route) -> BusTrip? {
        let buses = route.legs.filter(\.isBus)
        guard buses.count == 1, let bus = buses.first, route.legs.count <= 2 else { return nil }
        guard route.legs.count == 2 else { return BusTrip(bus: bus.busRide, train: nil, busFirst: true) }
        let busFirst = route.legs[0].isBus
        guard let train = ride(route.legs[busFirst ? 1 : 0]) else { return nil }
        let option = SharedTrip.Option(selection: Selection(stationID: train.board.id, routes: [train.route],
                                                            direction: train.direction),
                                       destinationID: train.alight.id)
        return BusTrip(bus: bus.busRide, train: option, busFirst: busFirst)
    }

    /// `routes` as trips, in order, leaving out any whose rides can't all be matched: the first
    /// ride as the train, the second as its change, to where that ride ends. A third ride on
    /// isn't shown, as a widget has one change.
    static func trips(from routes: [Route]) -> [TripPlanner.Trip] {
        routes.compactMap { route in
            let rides = route.legs.compactMap(ride)
            guard rides.count == route.legs.count, let first = rides.first else { return nil }
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

    /// The app's route ids a line Google names could be: itself, as feeds name expresses ("6X"
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
            .map { ($0, location.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon))) }
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
