import Foundation

/// Where a saved widget's train is left for another: a station on its way, and
/// the lines there to change to, going the same way. The large widget pairs
/// each of its trains with the first train there it can catch.
struct Change: Codable, Hashable, Sendable {
    /// A `Station.id`.
    var stationID: String
    /// Real-time route ids of the lines to change to, in the station's order.
    var routes: [String]
    /// The longest wait, in minutes, that the large widget highlights.
    var quickMinutes: Int
    /// Minutes to walk to a line on another platform than the train's.
    var walkMinutes: Int

    static let defaultQuickMinutes = 2
    static let defaultWalkMinutes = 3

    init(stationID: String, routes: [String], quickMinutes: Int = Change.defaultQuickMinutes,
         walkMinutes: Int = Change.defaultWalkMinutes) {
        self.stationID = stationID
        self.routes = routes
        self.quickMinutes = quickMinutes
        self.walkMinutes = walkMinutes
    }

    var station: Station? { StationDirectory.station(id: stationID) }

    /// The station's platforms that `selection`'s train stops at.
    private func arrivalPlatforms(for selection: Selection) -> [Platform] {
        station?.platforms(serving: selection.routes) ?? []
    }

    /// Where `selection`'s train calls here, as the feeds name it: "R31N".
    func arrivalStops(for selection: Selection) -> [String] {
        arrivalPlatforms(for: selection).map { $0.id + selection.direction.rawValue }
    }

    /// Where the lines changed to call here, going `selection`'s way.
    func departureStops(for selection: Selection) -> [String] {
        (station?.platforms(serving: routes) ?? []).map { $0.id + selection.direction.rawValue }
    }

    /// Whether `route` stops at a platform `selection`'s train does here, so
    /// changing to it is across the platform.
    func isAcross(_ route: String, from selection: Selection) -> Bool {
        arrivalPlatforms(for: selection).contains { $0.routes.contains(route) }
    }

    /// Whether every line changed to is across the platform.
    func isAllAcross(from selection: Selection) -> Bool {
        routes.allSatisfy { isAcross($0, from: selection) }
    }

    /// Whether the lines changed to are an express for `selection`'s train:
    /// across the platform, and none of them stopping at its station.
    func isExpress(for selection: Selection) -> Bool {
        let stopping = selection.station?.routes ?? []
        return isAllAcross(from: selection) && !routes.contains(where: stopping.contains)
    }

    /// How long it takes to get from `selection`'s train to one of `route`.
    func walk(to route: String, from selection: Selection) -> TimeInterval {
        isAcross(route, from: selection) ? 0 : TimeInterval(walkMinutes * 60)
    }

    /// Lines no longer at the station are dropped, as are `selection`'s own;
    /// nil when none are left, or the station is gone or is `selection`'s.
    func validated(for selection: Selection) -> Change? {
        guard let station, station.id != selection.station?.id else { return nil }
        var change = self
        change.stationID = station.id
        change.routes = station.routes.filter { routes.contains($0) && !selection.routes.contains($0) }
        return change.routes.isEmpty ? nil : change
    }

    /// What its trains depend on, to keep them apart from another change's.
    var key: String { "\(stationID) \(routes.joined(separator: ",")) \(walkMinutes)" }

    /// `trains` (yours, at your station, soonest first) that get here, each with
    /// the first of `departures` (the lines changed to, here, soonest first) it
    /// can catch. `atChange` has the trips' arrivals here.
    func connections(for trains: [Arrival], atChange: [Arrival], departures: [Arrival],
                     selection: Selection) -> [Connection] {
        var byTrip: [String: Arrival] = [:]
        for arrival in atChange where !arrival.trip.isEmpty && byTrip[arrival.trip] == nil {
            byTrip[arrival.trip] = arrival
        }
        return trains.compactMap { train in
            guard !train.trip.isEmpty, let arrival = byTrip[train.trip], arrival.time >= train.time else { return nil }
            let next = departures.first { departure in
                departure.trip != train.trip
                    && departure.time >= arrival.time.addingTimeInterval(walk(to: departure.route, from: selection))
            }
            return Connection(first: train, arrival: arrival, next: next)
        }
    }
}

/// One of a widget's trains with a change: the train at your station, the same
/// train at the change, and the first train there it can catch.
struct Connection: Codable, Hashable, Sendable {
    /// At your station.
    var first: Arrival
    /// The same trip at the change, with its stops on the way there.
    var arrival: Arrival
    /// The train it can change to; nil when the feeds have none yet.
    var next: Arrival?

    /// From getting to the change to the next train leaving, any walk included.
    var wait: TimeInterval? { next.map { $0.time.timeIntervalSince(arrival.time) } }

    /// The wait in whole minutes, to the nearest.
    var waitMinutes: Int? { wait.map { Int(($0 / 60).rounded()) } }

    /// "1 min", "<1 min", or "–" with no train to change to.
    var waitLabel: String {
        guard let minutes = waitMinutes else { return "–" }
        return minutes < 1 ? "<1 min" : "\(minutes) min"
    }

    /// Whether the wait is short enough for the widget to highlight.
    func isQuick(within minutes: Int) -> Bool {
        guard let waitMinutes else { return false }
        return waitMinutes <= minutes
    }
}
