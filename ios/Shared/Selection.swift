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

    /// The first chosen line, whose color stands for the choice.
    var firstRoute: String { routes.first ?? "" }

    /// "R", or "N/R" with more than one line chosen.
    var linesLabel: String { routes.map { LineStyle.of($0).label }.joined(separator: "/") }

    /// When to set off to reach the platform as `train` arrives.
    func leaveTime(for train: Arrival) -> Date {
        train.time.addingTimeInterval(-TimeInterval(walkMinutes * 60))
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
        trains.filter { leaveTime(for: $0) > now }
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
        return Station.directionLabel(direction, on: [platform])
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
    /// direction=N&elevators=0&walk=4&change=R31&to=D,N". The walking time
    /// goes along so the page leaves out the trains the widget does.
    func transferURL(changingAt change: Change) -> URL {
        let base = link(to: "transfer")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        components.queryItems? += [
            URLQueryItem(name: "walk", value: String(walkMinutes)),
            URLQueryItem(name: "change", value: change.stationID),
            URLQueryItem(name: "to", value: change.routes.joined(separator: ",")),
        ]
        return components.url ?? base
    }

    /// The train and change a `transferURL` is for, or nil for any other link
    /// or a change that's no longer on the train's way.
    static func transfer(from url: URL) -> (selection: Selection, change: Change)? {
        guard var selection = Selection(link: url, to: "transfer"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let stationID = value("change"), let routes = value("to"),
              let change = Change(stationID: stationID, routes: routes.split(separator: ",").map(String.init))
                  .validated(for: selection) else { return nil }
        selection.walkMinutes = value("walk").flatMap(Int.init) ?? 0
        return (selection, change)
    }

    private func link(to host: String) -> URL {
        var components = URLComponents()
        components.scheme = "traintimes"
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "station", value: stationID),
            URLQueryItem(name: "lines", value: routes.joined(separator: ",")),
            URLQueryItem(name: "direction", value: direction.rawValue),
            URLQueryItem(name: "elevators", value: elevatorAlerts ? "1" : "0"),
        ]
        return components.url ?? URL(string: "traintimes://\(host)")!
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
        guard url.scheme == "traintimes", url.host == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let station = value("station"), let lines = value("lines"),
              let direction = value("direction").flatMap(Direction.init(rawValue:)) else { return nil }
        self.init(stationID: station, routes: lines.split(separator: ",").map(String.init),
                  direction: direction, elevatorAlerts: value("elevators") == "1")
        // Not the fallback train, as validated() would give for a station
        // that's gone or lines it doesn't have: that's not the widget's train
        guard let known = self.station, known.routes.contains(where: routes.contains) else { return nil }
        self = validated()
    }
}
