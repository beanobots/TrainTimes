import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension Way {
    /// Whether this gets there before `other`: none predicted last, the shorter walk on a tie.
    fileprivate func isSooner(than other: Way) -> Bool {
        let rank = { (way: Way) in (way.arrival?.time ?? .distantFuture, way.connection?.walk ?? 0) }
        return rank(self) < rank(other)
    }
}

extension Arrival {
    /// Without its stops or position, which the ways don't draw, to save the widget's memory.
    fileprivate var trimmed: Arrival {
        var arrival = self
        arrival.approach = []
        arrival.position = nil
        return arrival
    }
}

extension Connection {
    /// As `Arrival.trimmed`, for a way's change.
    fileprivate var trimmed: Connection {
        var connection = self
        connection.first = first.trimmed
        connection.arrival = arrival.trimmed
        connection.next = next?.trimmed
        connection.ways = nil
        return connection
    }
}

/// Everything shown for a selection: its trains, alerts and outages.
struct Board: Sendable {
    var trains: [Arrival]
    /// Alerts for the chosen lines, station and direction, most important first. Nil if not
    /// requested or unavailable, which differs from none.
    var alerts: [ServiceAlert]?
    /// Elevator/escalator outages serving the chosen lines' platforms, current first. Nil as for
    /// `alerts`.
    var outages: [Outage]?
    /// With a change, the `trains` that reach it, each with its first connection.
    var connections: [Connection] = []
    /// With a change, just your own train's alerts; `alerts` adds those of the lines changed to.
    var ownAlerts: [ServiceAlert]? = nil
    /// With a destination and no change, when each of `trains` gets there, by trip; trains not
    /// predicted there are missing.
    var destinationTimes: [String: Date] = [:]
    /// False if built without waiting for all other-line feeds, alerts or outages; see
    /// `TrainService.board`.
    var complete = true
    /// Lines whose own feed couldn't be had, so their trains are the timetable's (`TrainService.board`'s
    /// `fillingFrom`).
    var scheduledRoutes: [String] = []

    /// Step-free access elevators out now, as mentioned by widgets, the countdown and the alerts
    /// sheet.
    var elevatorsOut: [Outage] {
        (outages ?? []).filter { !$0.isPlanned && $0.isAccessibilityElevator }
    }

    /// As without a change, for Next train widgets showing the same train: just your own train's
    /// alerts, and no connections. A changed-to line's alert ("No D between…") isn't theirs.
    var withoutChange: Board {
        var board = self
        board.alerts = ownAlerts ?? alerts
        board.ownAlerts = nil
        board.connections = []
        return board
    }

    /// The single notice the widget has room for, with a count of the rest.
    func notice(includingElevators: Bool, includingAlerts: Bool = true,
                kinds: Set<ServiceAlert.Kind> = Set(ServiceAlert.Kind.allCases)) -> Notice? {
        var notices: [Notice] = []
        if includingElevators, let elevators = Notice(elevatorsOut: elevatorsOut) {
            notices.append(elevators)
        }
        notices += (includingAlerts ? alerts ?? [] : [])
            .filter { kinds.contains($0.kind) }
            .map { Notice($0) }
        guard let first = notices.first else { return nil }
        return Notice(kind: first.kind, label: first.label, text: first.text, others: notices.count - 1, brief: first.brief,
                      markedText: first.markedText)
    }

    /// The notice for `selection`'s widget, countdown and Siri: per its alert/elevator choices and
    /// Settings' alert kinds.
    func notice(for selection: Selection, settings: AppSettings) -> Notice? {
        notice(includingElevators: selection.elevatorAlerts, includingAlerts: selection.serviceAlerts,
               kinds: settings.alertKinds)
    }
}

extension Selection {
    /// Whether `Board.notice(for:settings:)` can be a service alert, so alerts are worth fetching.
    func mentionsAlerts(with settings: AppSettings) -> Bool {
        serviceAlerts && !settings.alertKinds.isEmpty
    }
}

struct Notice: Codable, Hashable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        case alert(ServiceAlert.Kind)
        case elevator
    }

    let kind: Kind
    /// "Delays", "Service change", "Elevator out"
    let label: String
    /// The alert's headline, or what the elevator serves.
    let text: String
    let others: Int
    /// For a delay, its lines and direction, shown by the banner instead of `text`.
    var brief: AlertBrief? = nil
    /// The headline with lines marked "[R]" for drawing as bullets; nil for elevators and older
    /// saves.
    var markedText: String? = nil
}

extension Notice {
    /// `alert` as widgets show it: kind and headline.
    init(_ alert: ServiceAlert) {
        self.init(kind: .alert(alert.kind), label: alert.kind.label, text: alert.header, others: 0,
                  brief: alert.brief, markedText: alert.markedHeader)
    }

    /// `Board.elevatorsOut` as widgets show it: the count and what the first serves. Nil if none.
    init?(elevatorsOut outages: [Outage]) {
        guard let first = outages.first else { return nil }
        self.init(kind: .elevator, label: Self.elevatorLabel(count: outages.count), text: first.serving, others: 0)
    }

    /// "Elevator out", or "2 elevators out".
    static func elevatorLabel(count: Int) -> String {
        count == 1 ? "Elevator out" : "\(count) elevators out"
    }
}

extension Notice.Kind {
    /// "Delays", "Elevator out".
    var label: String {
        switch self {
        case .alert(let kind): kind.label
        case .elevator: Notice.elevatorLabel(count: 1)
        }
    }

    /// A notice's kind from its label (the countdown stores labels); nil for other labels such as
    /// "No trains predicted".
    init?(label: String) {
        // "Elevator out" or "2 elevators out"
        let elevators = label == Notice.elevatorLabel(count: 1) ? 1 : Int(label.prefix(while: { $0.isNumber }))
        if let kind = ServiceAlert.Kind.allCases.first(where: { $0.label == label }) {
            self = .alert(kind)
        } else if let elevators, label == Notice.elevatorLabel(count: elevators) {
            self = .elevator
        } else {
            return nil
        }
    }
}

enum TrainService {
    /// Fetches trains, plus optional alerts and outages, for `selection` in parallel. Only the
    /// chosen lines' own feeds are required and must be fresh (`SubwayFeed.isStale`); missing
    /// other-line feeds just mean no rerouted trains, and missing alerts/outages are nil.
    /// `includingOtherLines: false` fetches only own feeds (faster, no rerouted trains).
    /// `waitingAfterOwnLines` caps the wait for the optional parts after own feeds arrive; any
    /// still missing are left out and the board isn't `complete`. With `destination`, also when
    /// each train gets there (`Board.destinationTimes`). With `timetable`, a line whose own feed
    /// can't be had, or has stopped updating, while another's is fine gets the timetable's times
    /// (`Board.scheduledRoutes`) rather than the whole board failing.
    static func board(for selection: Selection, arrivingAt destination: Station? = nil, includingAlerts: Bool = true,
                      includingOutages: Bool = true, includingOtherLines: Bool = true,
                      waitingAfterOwnLines grace: TimeInterval? = nil,
                      fillingFrom timetable: (@Sendable () -> Timetable?)? = nil, now: Date = Date()) async throws -> Board {
        let feeds = Lines.feedURLs(sharingTracksWith: selection.routes)
        let stops = Set(selection.stopIDs).union(destination.map(StationDirectory.stops(inComplexOf:)) ?? [])
        let own = Task { await optionalData(fromEach: feeds.own, part: FeedPart(stops: stops), priority: URLSessionTask.highPriority) }
        let extras = Extras(for: selection, otherFeeds: includingOtherLines ? feeds.others : [], stops: stops,
                            alertRoutes: Set(selection.routes), alerts: includingAlerts, outages: includingOutages,
                            after: own)
        let fetched = await own.value
        let unfetched = feeds.own.filter { fetched[$0] == nil }
        // Without some lines' feeds, only the timetable can fill them in, around the others'
        guard unfetched.isEmpty || (unfetched.count < feeds.own.count && timetable != nil) else {
            throw URLError(.cannotLoadFromNetwork)
        }
        let got = await extras.collect(by: grace.map { Date.now.addingTimeInterval($0) })
        // Those, and any that have stopped updating, judged against the newest of all as
        // `arrivals(at:own:others:now:)` does
        let newest = SubwayFeed.newest(feeds.own.compactMap { fetched[$0] } + got.others)
        let missing = feeds.own.filter { url in
            guard let data = fetched[url] else { return true }
            return SubwayFeed.made(data).map { SubwayFeed.isStale(made: $0, newest: newest, now: now) } ?? false
        }
        // Some lines' feeds but not all: theirs from the timetable, if there is one. Otherwise a
        // stale one fails the board (`FeedError.stale`)
        let filling = missing.isEmpty || missing.count == feeds.own.count ? nil : timetable?()
        guard unfetched.isEmpty || filling != nil else { throw URLError(.cannotLoadFromNetwork) }
        let scheduled = filling == nil ? [] : selection.routes.filter { route in
            Lines.feedURLs(sharingTracksWith: [route]).own.contains(where: missing.contains)
        }
        let used = feeds.own.filter { filling == nil || !missing.contains($0) }

        var board = try Self.board(for: selection, arrivingAt: destination, now: now) { stops in
            var arrivals = try Self.arrivals(at: stops, own: used.compactMap { fetched[$0] }, others: got.others, now: now)
            if let filling {
                arrivals += filling.arrivals(at: stops, from: now, to: now.addingTimeInterval(timetableAhead))
                    .filter { scheduled.contains($0.route) }
            }
            return arrivals
        }
        board.alerts = got.alerts.map { AlertsFeed.alerts(for: selection, in: $0, now: now) }
        board.outages = got.outages
        board.complete = got.complete
        board.scheduledRoutes = scheduled
        return board
    }

    /// How far ahead a board from the timetable lists trains: enough for the widget's next ten,
    /// even at night.
    static let timetableAhead: TimeInterval = 3 * 60 * 60

    /// `board`'s trains from `timetable`, for when the MTA can't be reached: no alerts or outages.
    static func board(for selection: Selection, arrivingAt destination: Station? = nil, from timetable: Timetable,
                      now: Date = Date()) -> Board {
        board(for: selection, arrivingAt: destination, now: now) {
            timetable.arrivals(at: $0, from: now, to: now.addingTimeInterval(timetableAhead))
        }
    }

    /// `board`'s trains, from `arrivals` at the stops asked for.
    private static func board(for selection: Selection, arrivingAt destination: Station?, now: Date,
                              arrivalsAt lookUp: (Set<String>) throws -> [Arrival]) rethrows -> Board {
        let origin = Set(selection.stopIDs)
        let there = destination.map(StationDirectory.stops(inComplexOf:)) ?? []
        let arrivals = try lookUp(origin.union(there))
        let trains = Self.trains(for: selection, in: there.isEmpty ? arrivals : arrivals.filter { origin.contains($0.stop) },
                                 now: now)
        var board = Board(trains: trains)
        if !there.isEmpty {
            // Each train's trip at the destination, after it's at your stop
            let atDestination = Dictionary(grouping: arrivals.filter { there.contains($0.stop) && !$0.trip.isEmpty },
                                           by: \.trip)
            for train in trains {
                if let time = atDestination[train.trip]?.map(\.time).filter({ $0 > train.time }).min() {
                    board.destinationTimes[train.trip] = time
                }
            }
        }
        return board
    }

    /// `board` plus connections at `change`, or the best at each of its stations
    /// (`Change.smartChanges(for:)`). Own and changed-to lines' feeds are required; the
    /// rest are waited for as in `board`.
    static func board(for selection: Selection, change: Change, includingAlerts: Bool = true,
                      includingOutages: Bool = true, waitingAfterOwnLines grace: TimeInterval? = nil,
                      now: Date = Date()) async throws -> Board {
        let routes = selection.routes + change.allRoutes.filter { !selection.routes.contains($0) }
        let feeds = Lines.feedURLs(sharingTracksWith: routes)
        let plan = ChangePlan(for: selection, change: change)
        let alertRoutes = Set(routes + change.alertSelections(for: selection).flatMap(\.routes))
        let fetching = Task { await optionalData(fromEach: feeds.own, part: FeedPart(stops: plan.stops), priority: URLSessionTask.highPriority) }
        let extras = Extras(for: selection, otherFeeds: feeds.others, stops: plan.stops, alertRoutes: alertRoutes,
                            alerts: includingAlerts, outages: includingOutages, after: fetching)
        let fetched = await fetching.value
        guard feeds.own.allSatisfy({ fetched[$0] != nil }) else { throw URLError(.cannotLoadFromNetwork) }
        let own = feeds.own.compactMap { fetched[$0] }
        let got = await extras.collect(by: grace.map { Date.now.addingTimeInterval($0) })

        var board = try Self.board(for: selection, change: change, now: now) {
            try Self.arrivals(at: $0, own: own, others: got.others, now: now)
        }
        // Your train's alerts, and those of the lines you change to, there and going their way
        board.alerts = got.alerts.map {
            AlertsFeed.alerts(for: [selection] + change.alertSelections(for: selection), in: $0, now: now)
        }
        board.ownAlerts = got.alerts.map { AlertsFeed.alerts(for: selection, in: $0, now: now) }
        board.outages = got.outages
        board.complete = got.complete
        return board
    }

    /// `board(for:change:)` from `timetable`, as `board(for:arrivingAt:from:now:)`.
    static func board(for selection: Selection, change: Change, from timetable: Timetable, now: Date = Date()) -> Board {
        board(for: selection, change: change, now: now) {
            timetable.arrivals(at: $0, from: now, to: now.addingTimeInterval(timetableAhead))
        }
    }

    /// The stops a board for `selection` asks its feeds for: with `change`, as `board(for:change:)`
    /// does; otherwise as `board(for:arrivingAt:)` does. For `sharingFeeds(atStops:_:)`.
    static func feedStops(for selection: Selection, change: Change?, destination: Station?) -> Set<String> {
        if let change { return ChangePlan(for: selection, change: change).stops }
        return Set(selection.stopIDs).union(destination.map(StationDirectory.stops(inComplexOf:)) ?? [])
    }

    /// The stops `board(for:change:)` looks up, and what each is for, worked out before
    /// fetching so the push server can send just those stops' trips.
    private struct ChangePlan {
        /// Each change with the train as just the lines it's for.
        let parts: [(change: Change, lines: [String], selection: Selection)]
        let origin: Set<String>
        /// Per part, where your train gets to the change.
        let arriving: [Set<String>]
        /// Where the changed-to lines leave from.
        let leaving: [String]
        /// Where the changed-to lines pass the change's own station, to compare stations by.
        let passing: Set<String>
        let destination: Set<String>
        var stops: Set<String> { origin.union(arriving.joined()).union(leaving).union(passing).union(destination) }

        init(for selection: Selection, change: Change) {
            parts = change.smartChanges(for: selection).map { (change: $0.change, lines: $0.lines,
                                                               selection: selection.only($0.lines)) }
            origin = Set(selection.stopIDs)
            arriving = parts.map { Set($0.change.arrivalStops(for: $0.selection)) }
            leaving = parts.flatMap { $0.change.departureStops(for: $0.selection) }
            var main = change.stops[0]
            main.routes = change.allRoutes
            passing = Set(parts.count > 1 ? main.departureStops(for: selection) : [])
            destination = change.destinationStops
        }
    }

    /// `board(for:change:)`'s trains and connections, from `arrivals` at the stops asked for.
    private static func board(for selection: Selection, change: Change, now: Date,
                              arrivalsAt lookUp: (Set<String>) throws -> [Arrival]) rethrows -> Board {
        let plan = ChangePlan(for: selection, change: change)
        let (parts, origin, arriving, passing) = (plan.parts, plan.origin, plan.arriving, plan.passing)
        let destination = plan.destination
        var arrivals = try lookUp(plan.stops)
        arrivals.sort { $0.time < $1.time }
        let trains = Self.trains(for: selection, in: arrivals.filter { origin.contains($0.stop) }, now: now)
        // Each change's trains leaving it and your trains getting there
        let legs = zip(parts, arriving).map { part, arriving in
            // Your train may end at the change, but the connection must leave from it
            (part: part,
             departures: arrivals
                .filter { part.change.departs($0, for: part.selection) && !$0.endsHere && $0.leaves > now }
                .oncePerTrip(),
             atChange: arrivals.filter { arriving.contains($0.stop) })
        }
        let options = legs.map { leg in
            // Its lines' trains, and any of another line (rerouted onto yours)
            let theirs = trains.filter { leg.part.lines.contains($0.route) || !selection.routes.contains($0.route) }
            return leg.part.change.connections(for: theirs, atChange: leg.atChange, departures: leg.departures,
                                               selection: leg.part.selection)
        }
        let passed = Dictionary(arrivals.filter { passing.contains($0.stop) && !$0.trip.isEmpty }.map { ($0.trip, $0.time) },
                                uniquingKeysWith: min)
        let there = Dictionary(grouping: arrivals.filter { destination.contains($0.stop) && !$0.trip.isEmpty }, by: \.trip)
        let connections = Connection.best(of: options, for: trains, passing: passed).map { connection in
            var connection = connection
            connection.ways = ways(for: connection.first, legs: legs, change: change, selection: selection, there: there)
            return connection
        }
        return Board(trains: trains, connections: connections)
    }

    /// Every way on from `train` (`Way`), soonest there first: for each line changed to, its first
    /// train `train` connects with, at whichever of `legs`' stations is sooner; and with a
    /// destination, staying on. With a destination, only lines stopping there count, each with
    /// its first train that's predicted to get there; `there` has the trips at the destination.
    static func ways(for train: Arrival, legs: [(part: (change: Change, lines: [String], selection: Selection),
                                                 departures: [Arrival], atChange: [Arrival])],
                     change: Change, selection: Selection, there: [String: [Arrival]]) -> [Way] {
        let timed = change.destinationID != nil
        // A trip at the destination after `train` was at its stop
        let atDestination = { (train: Arrival) in
            there[train.trip]?.filter { $0.time >= train.time }.min { $0.time < $1.time }
        }
        var ways: [Way] = []
        for leg in legs where leg.part.lines.contains(train.route) || !selection.routes.contains(train.route) {
            for route in leg.part.change.routes where !timed || change.reachesDestination(route) {
                let departures = leg.departures.filter { $0.route == route && (!timed || atDestination($0) != nil) }
                guard let connection = leg.part.change.connections(for: [train], atChange: leg.atChange,
                                                                   departures: departures, selection: leg.part.selection).first,
                      // Continuing as another changed-to line is that line's way
                      !connection.staysOn || connection.next?.route == route else { continue }
                let arrival = timed ? connection.next.flatMap(atDestination) : connection.next
                let way = Way(route: route, connection: connection.trimmed, arrival: arrival?.trimmed)
                // A line at two of the change's stations: the sooner there
                if let index = ways.firstIndex(where: { $0.route == route }) {
                    if way.isSooner(than: ways[index]) { ways[index] = way }
                } else {
                    ways.append(way)
                }
            }
        }
        if timed, let arrival = atDestination(train), !ways.contains(where: { $0.staysOn && $0.arrival?.trip == train.trip }) {
            ways.append(Way(route: train.route, arrival: arrival.trimmed))
        }
        return ways.sorted { $0.isSooner(than: $1) }
    }

    /// How long the own-line feeds have to themselves before the extras start: on a connection
    /// with little to spare, your own train's times come first. On a good one they're done
    /// sooner, and the extras start then.
    private static let ownHeadStart: TimeInterval = 1

    /// Optional fetches run alongside the own-line feeds, at low priority and after their head
    /// start (`ownHeadStart`): other lines' feeds (for rerouted trains), alerts and outages.
    /// `stops` and `alertRoutes` are what of the feeds is needed (`FeedPart`).
    private struct Extras {
        let others: Task<[Data], Never>
        let alerts: Task<[AlertsFeed.Entry]?, Never>
        let outages: Task<[Outage]?, Never>

        init<T: Sendable>(for selection: Selection, otherFeeds: [URL], stops: Set<String>, alertRoutes: Set<String>,
                          alerts wanted: Bool, outages wantedOutages: Bool, after own: Task<T, Never>) {
            let headStart = Task { _ = await TrainService.value(of: own, by: Date.now.addingTimeInterval(ownHeadStart)) }
            let low = URLSessionTask.lowPriority
            others = Task {
                await headStart.value
                return await TrainService.optionalData(from: otherFeeds, part: FeedPart(stops: stops), priority: low)
            }
            alerts = Task {
                await headStart.value
                return await TrainService.alertEntries(if: wanted, routes: alertRoutes)
            }
            outages = Task {
                await headStart.value
                return await TrainService.outages(for: selection, if: wantedOutages)
            }
        }

        /// Waits until `deadline` (nil: no limit); any missing by then are left out and the result
        /// isn't `complete`.
        func collect(by deadline: Date?) async -> (others: [Data], alerts: [AlertsFeed.Entry]?, outages: [Outage]?,
                                                   complete: Bool) {
            let others = await TrainService.value(of: others, by: deadline)
            let alerts = await TrainService.value(of: alerts, by: deadline)
            let outages = await TrainService.value(of: outages, by: deadline)
            return (others ?? [], alerts ?? nil, outages ?? nil, others != nil && alerts != nil && outages != nil)
        }
    }

    /// `task`'s value, or nil if not done by `deadline` (nil: no limit). The task isn't cancelled,
    /// as other fetches may share it (`InFlight`).
    static func value<T: Sendable>(of task: Task<T, Never>, by deadline: Date?) async -> T? {
        guard let deadline else { return await task.value }
        let wait = deadline.timeIntervalSinceNow
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            Task { once.resume(await task.value) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(wait, 0) * 1_000_000_000))
                once.resume(nil)
            }
        }
    }

    /// Resumes the continuation once, with whichever racing value comes first.
    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: T?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }

    /// Stations `selection`'s train calls at after yours, for picking a change
    /// (`stations(after:in:)`). Empty if none of its trains is running.
    static func stations(after selection: Selection) async throws -> [Station] {
        let feeds = Lines.feedURLs(sharingTracksWith: selection.routes)
        return try stations(after: selection, in: try await data(from: feeds.own))
    }

    /// Stations after yours in `feeds` (the selection's own lines'), merged across lines in the
    /// order your trains get to them. Each line uses its running trip with the most stops, so
    /// diverging branches are all included. Every line's order is kept: nothing comes before a
    /// station ahead of it on any line; otherwise the soonest reached (by ride time from yours,
    /// on any line) goes first. From 34 St-Herald Sq the D's W 4 St, the N and Q's 14 St-Union
    /// Sq, then the D's Broadway-Lafayette St, and so on. Stations without times keep the order
    /// of a first merge: starting from the longest list, each other station goes after its
    /// predecessor, or before the first shared one, or at the end.
    static func stations(after selection: Selection, in feeds: [Data]) throws -> [Station] {
        // Each line from its platform, going its own way (Marcy Av toward Manhattan: J M16S, M M16N)
        var ways: [(origin: Set<String>, routes: [String])] = []
        for way in [selection.direction, selection.direction.opposite] {
            let routes = selection.routes.filter { selection.direction(of: $0) == way }
            let platforms = selection.station?.platforms(serving: routes) ?? []
            if !routes.isEmpty { ways.append((Set(platforms.map { $0.id + way.rawValue }), routes)) }
        }
        var longest: [String: [(id: String, ride: TimeInterval?)]] = [:]
        for feed in feeds {
            for way in ways {
                for route in way.routes {
                    for stops in try SubwayFeed.timedStops(after: way.origin, on: [route], in: feed)
                    where stops.count > longest[route, default: []].count {
                        longest[route] = stops
                    }
                }
            }
        }
        // Each station once, excluding yours
        let yours = selection.station?.id
        let timed = selection.routes.compactMap { longest[$0] }.enumerated()
            .sorted { (-$0.element.count, $0.offset) < (-$1.element.count, $1.offset) }
            .map { $0.element.compactMap { stop in StationDirectory.station(forStop: stop.id).map { ($0, stop.ride) } }
                .filter { $0.0.id != yours } }
        let lists = timed.map { $0.map(\.0) }
        // The soonest any line gets to each station
        var soonest: [String: TimeInterval] = [:]
        for (station, ride) in timed.joined() {
            if let ride { soonest[station.id] = min(ride, soonest[station.id] ?? ride) }
        }
        var listed: [Station] = []
        for stations in lists {
            var at = stations.lazy.compactMap { station in listed.firstIndex { $0.id == station.id } }.first
                ?? listed.endIndex
            for station in stations {
                if let index = listed.firstIndex(where: { $0.id == station.id }) {
                    at = max(at, index + 1)
                } else {
                    listed.insert(station, at: at)
                    at += 1
                }
            }
        }
        // Topologically order: of those whose predecessors on every list are placed, the soonest
        // reached (those without a time last, in the first merge's order); on a cycle, the first
        var before: [String: Set<String>] = [:]
        for stations in lists {
            for (first, next) in zip(stations, stations.dropFirst()) where first.id != next.id {
                before[next.id, default: []].insert(first.id)
            }
        }
        var ordered: [Station] = []
        var placed: Set<String> = []
        while !listed.isEmpty {
            let ready = listed.indices.filter { before[listed[$0].id, default: []].isSubset(of: placed) }
            let index = ready.min { (soonest[listed[$0].id] ?? .infinity, $0) < (soonest[listed[$1].id] ?? .infinity, $1) }
                ?? listed.startIndex
            let station = listed.remove(at: index)
            ordered.append(station)
            placed.insert(station.id)
        }
        return ordered
    }

    /// Alerts and outages only, as in `board`, for the alerts sheet, so it needn't fail when a
    /// train feed does.
    static func notices(for selection: Selection, includingAlerts: Bool = true, includingOutages: Bool = true,
                        now: Date = Date()) async -> Board {
        async let alertEntries = alertEntries(if: includingAlerts, routes: Set(selection.routes))
        async let outages = outages(for: selection, if: includingOutages)
        let alerts = await alertEntries.map { AlertsFeed.alerts(for: selection, in: $0, now: now) }
        return Board(trains: [], alerts: alerts, outages: await outages)
    }

    /// `outages(for:in:)`, fetched; nil if not wanted or the feed is unavailable or unreadable.
    private static func outages(for selection: Selection, if wanted: Bool) async -> [Outage]? {
        guard wanted else { return nil }
        // No equipment serves its platforms: nothing to fetch
        guard EquipmentDirectory.hasEquipment(serving: selection.platforms) else { return [] }
        return outages(for: selection, in: await optionalData(from: OutagesFeed.url, priority: URLSessionTask.lowPriority))
    }

    /// Outages in `data` (the outages feed, fetched once by the push server for all countdowns) of
    /// equipment at the station that serves, or might serve, the selection's platforms. Empty if
    /// no equipment serves them; nil if the feed is unavailable or unreadable.
    static func outages(for selection: Selection, in data: Data?) -> [Outage]? {
        let platforms = selection.platforms
        guard let complex = platforms.first?.complex, EquipmentDirectory.hasEquipment(serving: platforms) else { return [] }
        guard let data else { return nil }
        return (try? OutagesFeed.outages(atComplex: complex, in: data))?.filter { $0.serves(anyOf: platforms) }
    }

    /// Trains for each of `selections`, keyed by `Selection.trainID`, as `board` finds them but
    /// fetching and decoding each feed once (for the Nearby tab and the push server). Selections
    /// whose own feeds are missing or stale are omitted. `includingOtherLines: false` fetches only
    /// own feeds; `ownLinesOnly` lists `Selection.trainID`s that need only their own.
    static func trains(for selections: [Selection], includingOtherLines: Bool = true, ownLinesOnly: Set<String> = [],
                       now: Date = Date()) async -> [String: [Arrival]] {
        // Dedupe: the push server has thousands of countdowns, many for the same train
        let unique = Array(Dictionary(selections.map { ($0.trainID, $0) }, uniquingKeysWith: { first, _ in first }).values)
        let feeds = unique.map { feedURLs(for: $0, includingOtherLines: includingOtherLines, ownLinesOnly: ownLinesOnly) }
        let urls = Set(feeds.flatMap { $0.own + $0.others })
        let stops = Set(unique.flatMap(\.stopIDs))
        let fetched = await withTaskGroup(of: (URL, Data?).self) { group in
            for url in urls {
                group.addTask { (url, await optionalData(from: url, part: FeedPart(stops: stops))) }
            }
            var all: [URL: Data] = [:]
            for await (url, data) in group {
                all[url] = data
            }
            return all
        }
        let arrivals = Self.arrivals(at: stops, in: fetched, now: now)
        return trains(for: unique, in: arrivals, includingOtherLines: includingOtherLines, ownLinesOnly: ownLinesOnly,
                      now: now)
    }

    /// As `trains(for:includingOtherLines:ownLinesOnly:now:)`, from `timetable`, for when the MTA
    /// can't be reached.
    static func trains(for selections: [Selection], from timetable: Timetable, now: Date = Date()) -> [String: [Arrival]] {
        var trains: [String: [Arrival]] = [:]
        for selection in selections where trains[selection.trainID] == nil {
            let arrivals = timetable.arrivals(at: Set(selection.stopIDs), from: now, to: now.addingTimeInterval(timetableAhead))
            trains[selection.trainID] = Self.trains(for: selection, in: arrivals, now: now)
        }
        return trains
    }

    /// The decoded half of `trains(for:includingOtherLines:ownLinesOnly:now:)`. `feeds` has each
    /// feed's arrivals at the selections' stops (missing if unavailable or unreadable). Indexed by
    /// stop, so it's linear in the number of selections.
    static func trains(for selections: [Selection], in feeds: [URL: [Arrival]], includingOtherLines: Bool = true,
                       ownLinesOnly: Set<String> = [], now: Date) -> [String: [Arrival]] {
        let byStop = feeds.mapValues { Dictionary(grouping: $0, by: \.stop) }
        var trains: [String: [Arrival]] = [:]
        for selection in selections {
            let urls = feedURLs(for: selection, includingOtherLines: includingOtherLines, ownLinesOnly: ownLinesOnly)
            guard urls.own.allSatisfy({ byStop[$0] != nil }) else { continue }
            let stopIDs = selection.stopIDs
            // Split up with explicit types: as one expression it strains the type checker
            let all: [URL] = urls.own + urls.others
            let arrivals = all.flatMap { (url: URL) -> [Arrival] in stopIDs.flatMap { byStop[url]?[$0] ?? [] } }
            trains[selection.trainID] = Self.trains(for: selection, in: arrivals, now: now)
        }
        return trains
    }

    /// The trains a board lists: those `selection` shows that haven't left and don't end here,
    /// soonest first, each trip once.
    static func trains(for selection: Selection, in arrivals: [Arrival], now: Date) -> [Arrival] {
        let station = selection.station
        return arrivals
            .filter { !$0.endsHere && $0.leaves > now && selection.shows($0, at: station) }
            .sorted { $0.time < $1.time }
            .oncePerTrip()
    }

    /// Arrivals at `stops`. `own` feeds must all decode and be fresh (else throws); bad `others`
    /// are skipped. Staleness is relative to the newest of all (`SubwayFeed.isStale`).
    static func arrivals(at stops: Set<String>, own: [Data], others: [Data], now: Date) throws -> [Arrival] {
        let newest = SubwayFeed.newest(own + others)
        var arrivals: [Arrival] = []
        for data in own {
            arrivals += try SubwayFeed.arrivals(at: stops, in: data, newest: newest, now: now)
        }
        for data in others {
            arrivals += (try? SubwayFeed.arrivals(at: stops, in: data, newest: newest, now: now)) ?? []
        }
        return arrivals
    }

    /// Each feed's arrivals at `stops`, omitting unreadable or stale ones (relative to the newest,
    /// `SubwayFeed.isStale`).
    static func arrivals(at stops: Set<String>, in feeds: [URL: Data], now: Date) -> [URL: [Arrival]] {
        let newest = SubwayFeed.newest(Array(feeds.values))
        return feeds.compactMapValues { try? SubwayFeed.arrivals(at: stops, in: $0, newest: newest, now: now) }
    }

    /// Feeds `selection`'s trains can be in; only its own lines' without `includingOtherLines` or
    /// if in `ownLinesOnly`.
    static func feedURLs(for selection: Selection, includingOtherLines: Bool,
                         ownLinesOnly: Set<String> = []) -> (own: [URL], others: [URL]) {
        let all = Lines.feedURLs(sharingTracksWith: selection.routes)
        return includingOtherLines && !ownLinesOnly.contains(selection.trainID) ? all : (own: all.own, others: [])
    }

    private static let feeds = InFlight<FeedKey, Data>()
    private static let alertLists = InFlight<FeedKey, [AlertsFeed.Entry]>()
    /// Seconds `alertEntries(if:routes:)` shares decoded alerts for.
    private static let alertsReuseWindow: TimeInterval = 30

    /// MTA alerts, decoded once and shared by every request within `alertsReuseWindow`, so widgets
    /// don't each decode the feed. Only entries in effect around now are kept, and with
    /// `routes`, only those that can be for them (all `alerts(for:in:now:)` needs for
    /// selections of those routes): the push server then sends a fraction of the ~1 MB feed.
    /// Nil if not wanted or unavailable.
    static func alertEntries(if wanted: Bool = true, routes: Set<String>? = nil) async -> [AlertsFeed.Entry]? {
        guard wanted else { return nil }
        let part = FeedPart(routes: routes)
        return try? await alertLists.value(for: FeedKey(url: AlertsFeed.url, part: part), reusingFor: alertsReuseWindow) {
            try AlertsFeed.entries(in: try await data(from: AlertsFeed.url, part: part, priority: URLSessionTask.lowPriority))
        }
    }

    /// How long the app reuses a fetched feed: foregrounding, refresh and the countdown can request
    /// the same feeds within moments, and the MTA updates only every ~30 s. The widget caches
    /// nothing (tight memory); widgets share boards via `SharedStore` instead, and alerts and
    /// outages via `sharedCache`.
    #if APP
    private static let reuseWindow: TimeInterval = 15
    #else
    private static let reuseWindow: TimeInterval = 0
    #endif

    /// What of a feed a fetch needs: a train feed's trips at `stops`, or the alerts for `routes`;
    /// nil for all of it. The push server sends only that (`relayed(_:via:for:)`), so a phone
    /// with little signal below ground has far less to download; the MTA sends everything,
    /// which reads the same.
    struct FeedPart: Hashable, Sendable {
        var stops: Set<String>? = nil
        var routes: Set<String>? = nil

        static let all = FeedPart()
    }

    /// A fetch, for joining one in flight: the same feed, for the same part of it.
    private struct FeedKey: Hashable, Sendable {
        let url: URL
        let part: FeedPart

        /// For `sharedCache`: the feed and part, which differ in what's sent.
        var name: String {
            let list = { (ids: Set<String>?) in ids.map { $0.sorted().joined(separator: ",") } ?? "all" }
            return "\(url.absoluteString) stops: \(list(part.stops)) routes: \(list(part.routes))"
        }
    }

    /// Where the app and widgets keep `sharedFeeds` for each other (`SharedStore.FeedCache`); set
    /// once at launch, before any fetch. Nil on the server, and until set: nothing's kept.
    nonisolated(unsafe) static var sharedCache: (any FeedCaching)?

    /// Feeds that change far less often than trains', so a widget reloading moments after
    /// another (or the app) needn't download them again.
    private static let sharedFeeds: Set<URL> = [AlertsFeed.url, OutagesFeed.url]

    /// How long `sharedFeeds` are kept in `sharedCache`.
    private static let sharedFor: TimeInterval = 3 * 60

    /// Joins any in-flight fetch of `url` for `part`: widgets reload together and share feeds,
    /// and the widget extension's memory can't hold a copy per widget. An MTA feed comes from
    /// the push server's copy (`relayed(_:via:for:)`) or the MTA, whichever comes first
    /// (`hedged`). `priority` is URLSessionTask's: a train's own feeds go ahead of the rest on
    /// a connection with little to spare.
    private static func data(from url: URL, part: FeedPart = .all,
                             priority: Float = URLSessionTask.defaultPriority) async throws -> Data {
        let batch = Self.batch
        // Without the push server (as on it), the whole feed, so fetches of it are shared. In a
        // batch, a train feed's trips at all the batch's stops, if it covers these, so every
        // board's fetch of it is the same one
        let part: FeedPart = relayURL == nil ? .all
            : batch.flatMap { batch in
                part.stops.flatMap { $0.isSubset(of: batch.stops) && part.routes == nil ? FeedPart(stops: batch.stops) : nil }
            } ?? part
        let key = FeedKey(url: url, part: part)
        let fetching = { @Sendable in
            try await feeds.value(for: key, reusingFor: reuseWindow) {
                let shared = sharedFeeds.contains(url) ? sharedCache : nil
                if let shared, let data = shared.data(for: key.name, within: sharedFor) { return data }
                let data: Data
                if let relayURL, let relayed = relayed(url, via: relayURL, for: part) {
                    data = try await hedged(relayed, mta: url, priority: priority)
                } else {
                    data = try await fetch(url, in: .shared, timeout: 15, priority: priority)
                }
                shared?.save(data, for: key.name)
                return data
            }
        }
        // A batch keeps what it's fetched until it's done, as its boards ask at different times
        guard let batch else { return try await fetching() }
        return try await batch.feeds.value(for: key, reusingFor: FeedBatch.life, fetch: fetching)
    }

    /// Boards fetched together, as Transit Directions' Trip preloads its journeys: each feed
    /// downloaded once for them all (`sharingFeeds(atStops:_:)`).
    private final class FeedBatch: Sendable {
        /// Every stop the boards ask for.
        let stops: Set<String>
        let feeds = InFlight<FeedKey, Data>()
        /// Longer than any batch, which ends with its boards.
        static let life: TimeInterval = 5 * 60

        init(stops: Set<String>) {
            self.stops = stops
        }
    }

    @TaskLocal private static var batch: FeedBatch?

    /// Runs `body`, whose boards' feeds are fetched once each for them all: a train feed for its
    /// trips at all of `stops` (`feedStops(for:change:destination:)` of each board), which a fetch
    /// for some of them shares. One asking for any other stops is fetched on its own. What's
    /// fetched is let go when `body` ends.
    static func sharingFeeds<T>(atStops stops: Set<String>, _ body: () async throws -> T) async rethrows -> T {
        try await $batch.withValue(FeedBatch(stops: stops)) { try await body() }
    }

    /// How long the push server's copy has before the MTA is asked too. Below ground a request
    /// can stall for seconds; rather than wait out the relay's timeout and then start over, the
    /// MTA is tried alongside it.
    private static let hedgeDelay: TimeInterval = 1.5

    private enum Attempt: Sendable {
        case relay(Data?)
        case hedge
        case mta(Result<Data, Error>)
    }

    /// `relay`'s data, or `mta`'s if the relay fails or hasn't answered within `hedgeDelay`:
    /// whichever arrives first; the other is cancelled.
    private static func hedged(_ relay: URL, mta: URL, priority: Float) async throws -> Data {
        try await withThrowingTaskGroup(of: Attempt.self) { group in
            group.addTask { .relay(try? await fetch(relay, in: relaySession, timeout: relayTimeout, priority: priority)) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(hedgeDelay * 1_000_000_000))
                return .hedge
            }
            var askedMTA = false
            var relayFailed = false
            var mtaError: Error?
            while let attempt = try await group.next() {
                switch attempt {
                case .relay(let data?):
                    group.cancelAll()
                    return data
                case .mta(.success(let data)):
                    group.cancelAll()
                    return data
                case .mta(.failure(let error)):
                    mtaError = error
                    if relayFailed { group.cancelAll() }
                case .relay(nil), .hedge:
                    if case .relay = attempt {
                        relayFailed = true
                        if mtaError != nil { group.cancelAll() }
                    }
                    guard !askedMTA else { continue }
                    askedMTA = true
                    group.addTask {
                        do {
                            return .mta(.success(try await fetch(mta, in: .shared, timeout: 15, priority: priority)))
                        } catch {
                            return .mta(.failure(error))
                        }
                    }
                }
            }
            throw mtaError ?? URLError(.cannotLoadFromNetwork)
        }
    }

    private static func fetch(_ url: URL, in session: URLSession, timeout: TimeInterval,
                              priority: Float) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        #if canImport(FoundationNetworking)
        let (data, response) = try await session.data(for: request)
        #else
        // The push server is behind Cloudflare, which speaks HTTP/3: QUIC is raced with TCP from
        // the first request, and copes better with lost packets and a switch between station
        // Wi-Fi and LTE
        request.assumesHTTP3Capable = session === relaySession
        let (data, response) = try await session.data(for: request, delegate: Prioritizing(priority: priority))
        #endif
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return data
    }

    #if !canImport(FoundationNetworking)
    /// Sets a task's priority as it's made, which the async `data(for:)` has no other way to.
    private final class Prioritizing: NSObject, URLSessionTaskDelegate, Sendable {
        let priority: Float

        init(priority: Float) {
            self.priority = priority
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            task.priority = priority
        }
    }
    #endif

    // MARK: The push server's copy of the feeds

    /// Info.plist's TrainTimesServerURL, whose `GET /feeds` passes on the MTA's feeds as it last
    /// read them. Nil on the server itself, whose bundle has none, so it reads the MTA.
    private static let relayURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "TrainTimesServerURL") as? String)
        .flatMap { URL(string: $0.hasSuffix("/") ? String($0.dropLast()) : $0) }

    /// Short, so a widget, which has seconds to draw, still has time for the MTA.
    private static let relayTimeout: TimeInterval = 4

    private static let relaySession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = relayTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Where the MTA's feeds are; each one's name follows ("nyct%2Fgtfs-nqrw").
    private static let mtaFeeds = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/"

    /// An MTA feed's name, as `GET /feeds` takes it: "nyct/gtfs-nqrw". Nil if not an MTA feed.
    static func feedName(of url: URL) -> String? {
        let address = url.absoluteString
        guard address.hasPrefix(mtaFeeds) else { return nil }
        return String(address.dropFirst(mtaFeeds.count)).removingPercentEncoding
    }

    /// The server's copy of `url`: `<server>/feeds?name=nyct/gtfs-nqrw`, plus `&stops=` or
    /// `&routes=` (sorted, comma-separated) for just `part` of it. Nil if not an MTA feed.
    static func relayed(_ url: URL, via server: URL, for part: FeedPart = .all) -> URL? {
        guard let name = feedName(of: url),
              var components = URLComponents(string: server.absoluteString + "/feeds") else { return nil }
        let list = { (field: String, ids: Set<String>?) in
            ids.map { [URLQueryItem(name: field, value: $0.sorted().joined(separator: ","))] } ?? []
        }
        components.queryItems = [URLQueryItem(name: "name", value: name)] + list("stops", part.stops)
            + list("routes", part.routes)
        return components.url
    }

    /// In-flight and recently finished fetches, by `Key`.
    private actor InFlight<Key: Hashable & Sendable, Value: Sendable> {
        private var fetches: [Key: Task<Value, Error>] = [:]
        private var recent: [Key: (value: Value, fetched: Date)] = [:]

        /// Reuses a value fetched under `window` seconds ago.
        func value(for key: Key, reusingFor window: TimeInterval,
                   fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
            let now = Date.now
            // Drop expired entries
            recent = recent.filter { $0.value.fetched.isWithin(window, before: now) }
            if let recent = recent[key] { return recent.value }
            if let fetch = fetches[key] { return try await fetch.value }
            let task = Task { try await fetch() }
            fetches[key] = task
            defer { fetches[key] = nil }
            let value = try await task.value
            if window > 0 { recent[key] = (value, .now) }
            return value
        }
    }

    /// Fetches in parallel; fails if any fails.
    private static func data(from urls: [URL], part: FeedPart = .all) async throws -> [Data] {
        try await withThrowingTaskGroup(of: Data.self) { group in
            for url in urls {
                group.addTask { try await data(from: url, part: part) }
            }
            var all: [Data] = []
            for try await data in group {
                all.append(data)
            }
            return all
        }
    }

    /// `data(from:part:priority:)`, or nil on failure.
    static func optionalData(from url: URL?, part: FeedPart = .all,
                             priority: Float = URLSessionTask.defaultPriority) async -> Data? {
        guard let url else { return nil }
        return try? await data(from: url, part: part, priority: priority)
    }

    /// Fetches in parallel, omitting failures.
    private static func optionalData(from urls: [URL], part: FeedPart = .all,
                                     priority: Float = URLSessionTask.defaultPriority) async -> [Data] {
        await Array(optionalData(fromEach: urls, part: part, priority: priority).values)
    }

    /// Fetches in parallel, by URL; those that fail are missing.
    private static func optionalData(fromEach urls: [URL], part: FeedPart = .all,
                                     priority: Float = URLSessionTask.defaultPriority) async -> [URL: Data] {
        await withTaskGroup(of: (URL, Data?).self) { group in
            for url in urls {
                group.addTask { (url, await optionalData(from: url, part: part, priority: priority)) }
            }
            var all: [URL: Data] = [:]
            for await (url, data) in group {
                all[url] = data
            }
            return all
        }
    }
}

/// Feeds kept across processes (`TrainService.sharedCache`), by `name`.
protocol FeedCaching: Sendable {
    /// `name`'s data if saved under `age` seconds ago.
    func data(for name: String, within age: TimeInterval) -> Data?
    func save(_ data: Data, for name: String)
}

private extension [Arrival] {
    /// Keeps each trip's first arrival (a trip can call at several of a station's platforms).
    /// Trips without an id are all kept.
    func oncePerTrip() -> [Arrival] {
        var seen = Set<String>()
        return filter { $0.trip.isEmpty || seen.insert($0.trip).inserted }
    }
}

extension Date {
    /// Whether it's less than `interval` before `now` (i.e. fresh). A date after `now` (clock set
    /// back) counts as old, or it would stay fresh until the clock caught up.
    func isWithin(_ interval: TimeInterval, before now: Date) -> Bool {
        let age = now.timeIntervalSince(self)
        return age >= 0 && age < interval
    }
}
