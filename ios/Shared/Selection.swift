import Foundation

/// The station, lines and direction the widget shows.
struct Selection: Codable, Hashable, Sendable {
    /// A `Station.id`, or in a choice saved before a station's platforms were
    /// joined up, the id of one of them.
    var stationID: String
    /// One or more real-time route ids, in the order of `Station.routes`.
    var routes: [String]
    var direction: Direction
    /// Whether the widget mentions an elevator out at the station (the app always lists them).
    var elevatorAlerts: Bool
    /// Whether the widget mentions the MTA's service alerts (the app always lists them).
    var serviceAlerts: Bool
    /// Minutes to walk to the station. Trains you can't reach in time are left out,
    /// and the widget counts down to when to leave.
    var walkMinutes: Int

    init(stationID: String, routes: [String], direction: Direction, elevatorAlerts: Bool = false, serviceAlerts: Bool = true, walkMinutes: Int = 0) {
        self.stationID = stationID
        self.routes = routes
        self.direction = direction
        self.elevatorAlerts = elevatorAlerts
        self.serviceAlerts = serviceAlerts
        self.walkMinutes = walkMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case stationID, routes, direction, elevatorAlerts, serviceAlerts, walkMinutes
        /// The one line chosen before more than one could be
        case route
    }

    /// Choices saved before `routes`, `elevatorAlerts`, `serviceAlerts` and `walkMinutes` existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stationID = try container.decode(String.self, forKey: .stationID)
        routes = try container.decodeIfPresent([String].self, forKey: .routes)
            ?? [container.decode(String.self, forKey: .route)]
        direction = try container.decode(Direction.self, forKey: .direction)
        elevatorAlerts = try container.decodeIfPresent(Bool.self, forKey: .elevatorAlerts) ?? false
        serviceAlerts = try container.decodeIfPresent(Bool.self, forKey: .serviceAlerts) ?? true
        walkMinutes = try container.decodeIfPresent(Int.self, forKey: .walkMinutes) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stationID, forKey: .stationID)
        try container.encode(routes, forKey: .routes)
        try container.encode(direction, forKey: .direction)
        try container.encode(elevatorAlerts, forKey: .elevatorAlerts)
        try container.encode(serviceAlerts, forKey: .serviceAlerts)
        try container.encode(walkMinutes, forKey: .walkMinutes)
    }

    /// The walking times the app lets you set, and a link can give.
    static let walkRange = 0...60

    /// The first chosen line, whose color stands for the choice.
    var firstRoute: String { routes.first ?? "" }

    /// "R", or "N/R" with more than one line chosen.
    var linesLabel: String { routes.map { LineStyle.of($0).label }.joined(separator: "/") }

    /// Its lines and where they go, as the app lists a train: "R Manhattan",
    /// "N and R Manhattan".
    var caption: String { "\(Lines.list(routes)) \(heading)" }

    /// Its station, direction and lines: which train this is, whatever the
    /// walking time. Also its `StopEntity` id.
    var trainID: String { Self.trainID(stationID: stationID, direction: direction, routes: routes) }

    /// "R34:N:R": station, direction, line; "R31:N:N,R" for more than one line.
    static func trainID(stationID: String, direction: Direction, routes: [String]) -> String {
        "\(stationID):\(direction.rawValue):\(routes.joined(separator: ","))"
    }

    /// When to set off to reach the platform as `train` arrives.
    func leaveTime(for train: Arrival) -> Date {
        train.time.addingTimeInterval(-TimeInterval(walkMinutes) * 60)
    }

    /// The last moment to set off and still catch `train`: `leaveTime(for:)`,
    /// or later for a train held at the platform, which leaves after it arrives.
    func lastLeaveTime(for train: Arrival) -> Date {
        train.leaves.addingTimeInterval(-TimeInterval(walkMinutes) * 60)
    }

    /// Trains of the chosen lines, and of any line that doesn't usually stop at
    /// their platform, which must be running on one of them: an N running local
    /// on the R. Lines that do usually stop there are left out unless chosen.
    func shows(_ train: Arrival) -> Bool {
        if routes.contains(train.route) { return true }
        let usual = platform(of: train)?.routes ?? station?.routes
        return !(usual?.contains(train.route) ?? true)
    }

    /// Whether a train needs its bullet beside it: always, unless just one line
    /// is chosen and the train is on it.
    func marksLine(of train: Arrival) -> Bool {
        routes != [train.route]
    }

    /// The trains you can still reach in time if you leave at or after `now`.
    func catchable(_ trains: [Arrival], now: Date) -> [Arrival] {
        trains.filter { lastLeaveTime(for: $0) > now }
    }

    /// With a change, the connections whose train at your station you can
    /// still reach in time if you leave at or after `now`.
    func catchable(_ connections: [Connection], now: Date) -> [Connection] {
        connections.filter { lastLeaveTime(for: $0.first) > now }
    }

    /// The first of `trains` you reach as it gets to the platform if you leave
    /// at or after `now`, not one you'd catch only while it's held there: the
    /// one the countdown starts on, as it counts down to arrivals.
    func firstReachable(_ trains: [Arrival], now: Date) -> Arrival? {
        trains.first { leaveTime(for: $0) > now }
    }

    /// With a change, the first connection whose train at your station you
    /// reach as it gets in: the one the Transfers widget counts down to, as
    /// its walk button's countdown does.
    func firstReachable(_ connections: [Connection], now: Date) -> Connection? {
        connections.first { leaveTime(for: $0.first) > now }
    }

    /// Prospect Av, R, toward Manhattan: what the widget shows until you choose.
    static let fallback = Selection(stationID: "R34", routes: ["R"], direction: .north)

    var station: Station? { StationDirectory.station(id: stationID) }

    /// The platforms of the chosen lines: one, unless they stop on different
    /// ones, like the N and the 2 at Atlantic Av-Barclays Ctr.
    var platforms: [Platform] { station?.platforms(serving: routes) ?? [] }

    /// Where the chosen lines' trains stop, as the feeds name it: "R31N".
    var stopIDs: [String] { platforms.map { $0.id + direction.rawValue } }

    /// Where the chosen lines go: "Manhattan".
    var heading: String { station?.directionLabel(direction, routes: routes) ?? "" }

    /// Where `train` goes from its platform, which is just one of `heading`'s names
    /// where the chosen lines' platforms name the direction differently.
    func heading(of train: Arrival) -> String {
        guard let platform = platform(of: train) else { return heading }
        return Station.directionLabel(direction, on: [platform], routes: [train.route])
    }

    private func platform(of train: Arrival) -> Platform? {
        station?.platforms.first { $0.id + direction.rawValue == train.stop }
    }

    /// A saved choice that no longer matches the station list falls back to the
    /// default; a line the station has lost is just dropped. One saved when its
    /// platform was a station of its own moves to the station it's part of.
    func validated() -> Selection {
        guard let station else { return .fallback }
        var selection = self
        selection.stationID = station.id
        selection.routes = station.routes.filter(routes.contains)
        return selection.routes.isEmpty ? .fallback : selection
    }

    /// As `validated()`, but nil rather than the default where the station is
    /// gone or has lost every line chosen: for a train that isn't the app's
    /// own choice, such as a link's, a favorite's or a shortcut's.
    func validatedIfKnown() -> Selection? {
        guard let station, station.routes.contains(where: routes.contains) else { return nil }
        return validated()
    }
}

extension Selection {
    /// Opens the app at this train's alerts, from a widget showing one:
    /// "traintimes://alerts?station=R34&lines=R&direction=N&elevators=0". A
    /// widget's train can be other than the app's, so it goes along.
    var alertsURL: URL { link(to: "alerts") }

    /// Opens the app at this train's times, from a row of the Nearby widget:
    /// "traintimes://train?station=R33&lines=R&direction=N&elevators=0".
    var trainURL: URL { link(to: "train") }

    /// Opens the app at the times of this train and of the lines it changes to,
    /// from the Transfers widget: "traintimes://transfer?station=R33&lines=R&
    /// direction=N&elevators=0&walk=4&change=R31&to=D,N&going=N". The walking
    /// time goes along so the page leaves out the trains the widget does.
    func transferURL(changingAt change: Change) -> URL {
        link(to: "transfer", adding: [
            URLQueryItem(name: "walk", value: String(walkMinutes)),
            URLQueryItem(name: "change", value: change.stationID),
            URLQueryItem(name: "to", value: AppLink.list(change.routes)),
            URLQueryItem(name: "going", value: change.departureDirection(for: self).rawValue),
        ])
    }

    /// The train and change a `transferURL` is for, or nil for any other link
    /// or a change that's no longer on the train's way.
    static func transfer(from url: URL) -> (selection: Selection, change: Change)? {
        guard var selection = Selection(link: url, to: "transfer"),
              let query = AppLink.query(of: url, to: "transfer"),
              let stationID = query["change"], let routes = query.list("to"),
              let change = Change(stationID: stationID, routes: routes,
                                  direction: query["going"].flatMap(Direction.init(rawValue:)))
                  .validated(for: selection) else { return nil }
        // As the app could set it, so a link made up with a huge one can't overflow
        let walk = query["walk"].flatMap(Int.init) ?? 0
        selection.walkMinutes = min(max(walk, walkRange.lowerBound), walkRange.upperBound)
        return (selection, change)
    }

    /// A link to the app's `host` page for this train, with `extra` after its own query.
    private func link(to host: String, adding extra: [URLQueryItem] = []) -> URL {
        AppLink.url(to: host, query: [
            URLQueryItem(name: "station", value: stationID),
            URLQueryItem(name: "lines", value: AppLink.list(routes)),
            URLQueryItem(name: "direction", value: direction.rawValue),
            URLQueryItem(name: "elevators", value: elevatorAlerts ? "1" : "0"),
        ] + extra) ?? URL(string: "\(AppLink.scheme)://\(host)")!
    }

    /// The train an `alertsURL` is for, or nil for any other link.
    init?(alertsURL url: URL) {
        self.init(link: url, to: "alerts")
    }

    /// The train a `trainURL` is for, or nil for any other link.
    init?(trainURL url: URL) {
        self.init(link: url, to: "train")
    }

    private init?(link url: URL, to host: String) {
        guard let query = AppLink.query(of: url, to: host),
              let station = query["station"], let lines = query.list("lines"),
              let direction = query["direction"].flatMap(Direction.init(rawValue:)) else { return nil }
        // Not the fallback train, as validated() would give for a station
        // that's gone or lines it doesn't have: that's not the widget's train
        guard let known = Selection(stationID: station, routes: lines, direction: direction,
                                    elevatorAlerts: query["elevators"] == "1")
            .validatedIfKnown() else { return nil }
        self = known
    }
}

/// The app's own links, which the widgets open it with:
/// "traintimes://train?station=R33&lines=R&direction=N&elevators=0".
enum AppLink {
    static let scheme = "traintimes"

    /// A link to the app's `host` page with `query`; nil should they not make one.
    static func url(to host: String, query: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = query
        return components.url
    }

    /// The query of `url`, where it's a link to the app's `host` page; nil
    /// for any other link.
    static func query(of url: URL, to host: String) -> Query? {
        guard url.scheme == scheme, url.host == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return Query(items: items)
    }

    /// A list as a link gives it, in one value: "N,R".
    static func list(_ values: [String]) -> String {
        values.joined(separator: ",")
    }

    /// A link's values, by name.
    struct Query {
        let items: [URLQueryItem]

        /// The value named `name`; the first, should there be more.
        subscript(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        /// The list named `name`, written as `AppLink.list` writes it.
        func list(_ name: String) -> [String]? {
            self[name].map { $0.split(separator: ",").map(String.init) }
        }
    }
}
