import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Everything shown for a selection: its trains, and what might get in the way.
struct Board: Sendable {
    var trains: [Arrival]
    /// Alerts in effect for the chosen lines at this station and direction, most
    /// important first. Nil when they weren't asked for or couldn't be had, which
    /// isn't the same as none.
    var alerts: [ServiceAlert]?
    /// Outages of the station's elevators and escalators that serve the chosen
    /// lines' platforms, current ones first. Nil, as with `alerts`, when they
    /// weren't asked for or couldn't be had.
    var outages: [Outage]?
    /// For a widget with a change, those of `trains` that get there, each with
    /// the first train there it can catch.
    var connections: [Connection] = []

    /// The elevators someone needs for step-free access that are out now: what
    /// the widgets, the countdown and the alerts sheet mention.
    var elevatorsOut: [Outage] {
        (outages ?? []).filter { !$0.isPlanned && $0.isAccessibilityElevator }
    }

    /// The one thing the widget has room to mention, and how many more there are.
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

    /// What `selection`'s widget, countdown and Siri mention: its own choice of
    /// alerts and elevators, and only the kinds of alert chosen in Settings.
    func notice(for selection: Selection, settings: AppSettings) -> Notice? {
        notice(includingElevators: selection.elevatorAlerts, includingAlerts: selection.serviceAlerts,
               kinds: settings.alertKinds)
    }
}

extension Selection {
    /// Whether what it mentions (`Board.notice(for:settings:)`) can be a
    /// service alert, so that they're worth fetching: it mentions them, and
    /// Settings has some kinds of alert on.
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
    /// For a delay, its lines and direction, which the banner shows in place of `text`.
    var brief: AlertBrief? = nil
    /// An alert's headline with its lines written "[R]", for the widget to draw
    /// them as bullets; nil for an elevator, or one saved before there was this.
    var markedText: String? = nil
}

extension Notice {
    /// `alert`, as the widgets mention it: its kind, and its headline.
    init(_ alert: ServiceAlert) {
        self.init(kind: .alert(alert.kind), label: alert.kind.label, text: alert.header, others: 0,
                  brief: alert.brief, markedText: alert.markedHeader)
    }

    /// The elevators out (`Board.elevatorsOut`), as the widgets mention them:
    /// how many, and what the first serves. Nil with none.
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
    /// What one of this kind is called: "Delays", "Elevator out".
    var label: String {
        switch self {
        case .alert(let kind): kind.label
        case .elevator: Notice.elevatorLabel(count: 1)
        }
    }

    /// The kind of a notice by its label, as the countdown keeps it: nil for
    /// one that's neither an alert's nor an elevator's, such as "No trains
    /// predicted".
    init?(label: String) {
        // "Elevator out", or how many: "2 elevators out"
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
    /// Trains, and when asked for, alerts and elevator outages for `selection`,
    /// fetched together. Only the chosen lines' own train feeds are required,
    /// and up to date (`SubwayFeed.isStale`): without the other lines' feeds
    /// there are just no rerouted trains, and without alerts or outages, or
    /// those not asked for, the board has nil for them. Without
    /// `includingOtherLines`, only the chosen lines' feeds are fetched, which
    /// is quicker, and there are no rerouted trains.
    static func board(for selection: Selection, includingAlerts: Bool = true, includingOutages: Bool = true,
                      includingOtherLines: Bool = true, now: Date = Date()) async throws -> Board {
        let feeds = Lines.feedURLs(sharingTracksWith: selection.routes)
        async let trainData = data(from: feeds.own)
        async let otherTrainData = optionalData(from: includingOtherLines ? feeds.others : [])
        async let alertEntries = alertEntries(if: includingAlerts)
        async let outages = outages(for: selection, if: includingOutages)

        let arrivals = try Self.arrivals(at: Set(selection.stopIDs), own: try await trainData,
                                         others: await otherTrainData, now: now)
        let trains = Self.trains(for: selection, in: arrivals, now: now)
        let alerts = await alertEntries.map { AlertsFeed.alerts(for: selection, in: $0, now: now) }
        return Board(trains: trains, alerts: alerts, outages: await outages)
    }

    /// For a widget with a change: `board`'s trains, alerts and outages, and
    /// those of the trains that get to the change, each with the first train
    /// there it can catch. The feeds of its own lines and of those changed to
    /// are required.
    static func board(for selection: Selection, change: Change, includingAlerts: Bool = true,
                      includingOutages: Bool = true, now: Date = Date()) async throws -> Board {
        let routes = selection.routes + change.routes.filter { !selection.routes.contains($0) }
        let feeds = Lines.feedURLs(sharingTracksWith: routes)
        async let trainData = data(from: feeds.own)
        async let otherTrainData = optionalData(from: feeds.others)
        async let alertEntries = alertEntries(if: includingAlerts)
        async let outages = outages(for: selection, if: includingOutages)

        let origin = Set(selection.stopIDs)
        let arriving = Set(change.arrivalStops(for: selection))
        let leaving = Set(change.departureStops(for: selection))
        let stops = origin.union(arriving).union(leaving)
        var arrivals = try Self.arrivals(at: stops, own: try await trainData, others: await otherTrainData, now: now)
        arrivals.sort { $0.time < $1.time }
        let trains = Self.trains(for: selection, in: arrivals.filter { origin.contains($0.stop) }, now: now)
        // Your train can end at the change, but the one changed to has to leave from it
        let departures = arrivals
            .filter { change.departs($0, for: selection) && !$0.endsHere && $0.leaves > now }
            .oncePerTrip()
        let connections = change.connections(for: trains, atChange: arrivals.filter { arriving.contains($0.stop) },
                                             departures: departures, selection: selection)
        let alerts = await alertEntries.map { AlertsFeed.alerts(for: selection, in: $0, now: now) }
        return Board(trains: trains, alerts: alerts, outages: await outages, connections: connections)
    }

    /// The stations `selection`'s train calls at after yours, for choosing
    /// where to change, from its lines' feeds (`stations(after:in:)`). Empty
    /// when none of its trains is running.
    static func stations(after selection: Selection) async throws -> [Station] {
        let feeds = Lines.feedURLs(sharingTracksWith: selection.routes)
        return try stations(after: selection, in: try await data(from: feeds.own))
    }

    /// The stations `selection`'s train calls at after yours in `feeds`, its
    /// lines' own: for each of its lines, those of its running trip that lists
    /// the most of them, so that where the lines part, each one's are there.
    /// Each line's stations keep their order: the longest list's, with each
    /// other's not yet listed put in after the one before them on its list,
    /// or before the first it shares, or where it shares none, at the end.
    /// So the 1's local stops from 96 St come between the 2's, and toward
    /// Manhattan from Marcy Av, the J's Bowery, Canal St, Chambers St, Fulton
    /// St and Broad St come after Delancey St-Essex St, then the M's on to Forest Hills.
    static func stations(after selection: Selection, in feeds: [Data]) throws -> [Station] {
        // Each line from where it calls going its own way: toward Manhattan
        // from Marcy Av, the J from M16S and the M from M16N
        var ways: [(origin: Set<String>, routes: [String])] = []
        for way in [selection.direction, selection.direction.opposite] {
            let routes = selection.routes.filter { selection.direction(of: $0) == way }
            let platforms = selection.station?.platforms(serving: routes) ?? []
            if !routes.isEmpty { ways.append((Set(platforms.map { $0.id + way.rawValue }), routes)) }
        }
        var longest: [String: [String]] = [:]
        for feed in feeds {
            for way in ways {
                for route in way.routes {
                    for stops in try SubwayFeed.stops(after: way.origin, on: [route], in: feed)
                    where stops.count > longest[route, default: []].count {
                        longest[route] = stops
                    }
                }
            }
        }
        let lists = selection.routes.compactMap { longest[$0] }.enumerated()
            .sorted { (-$0.element.count, $0.offset) < (-$1.element.count, $1.offset) }
        // A station once, and never yours
        let yours = selection.station?.id
        var listed: [Station] = []
        for (_, stops) in lists {
            let stations = stops.compactMap(StationDirectory.station(forStop:)).filter { $0.id != yours }
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
        return listed
    }

    /// Just the alerts and outages for `selection`, when asked for, as `board`
    /// has them, with no trains: for the alerts sheet, which needn't fail
    /// because a train feed did.
    static func notices(for selection: Selection, includingAlerts: Bool = true, includingOutages: Bool = true,
                        now: Date = Date()) async -> Board {
        async let alertEntries = alertEntries(if: includingAlerts)
        async let outages = outages(for: selection, if: includingOutages)
        let alerts = await alertEntries.map { AlertsFeed.alerts(for: selection, in: $0, now: now) }
        return Board(trains: [], alerts: alerts, outages: await outages)
    }

    /// The outages that matter to `selection`, as `outages(for:in:)` has them:
    /// nil when not wanted or the feed couldn't be had or read.
    private static func outages(for selection: Selection, if wanted: Bool) async -> [Outage]? {
        guard wanted else { return nil }
        // Where no elevators or escalators serve its platforms, there's nothing to fetch
        guard EquipmentDirectory.hasEquipment(serving: selection.platforms) else { return [] }
        return outages(for: selection, in: await optionalData(from: OutagesFeed.url))
    }

    /// The outages that matter to `selection` in `data`, the outages feed,
    /// which the push server fetches once for all its countdowns: those at its
    /// station of elevators and escalators that serve its lines' platforms, or
    /// might, so they go by the platforms alone. None where no elevators or
    /// escalators serve them; nil when the feed couldn't be had or read.
    static func outages(for selection: Selection, in data: Data?) -> [Outage]? {
        let platforms = selection.platforms
        guard let complex = platforms.first?.complex, EquipmentDirectory.hasEquipment(serving: platforms) else { return [] }
        guard let data else { return nil }
        return (try? OutagesFeed.outages(atComplex: complex, in: data))?.filter { $0.serves(anyOf: platforms) }
    }

    /// The trains of each of `selections`, by `Selection.trainID`, found as
    /// `board` finds them but fetching and reading each feed just once, for the
    /// Live tab's lists and the push server's countdowns. One whose own lines'
    /// feeds didn't come, or are out of date, is left out. Without
    /// `includingOtherLines`, only the lines' own feeds are fetched, which is
    /// enough where only each line's own trains are shown; `ownLinesOnly` are
    /// the `Selection.trainID`s of any others that need just those.
    static func trains(for selections: [Selection], includingOtherLines: Bool = true, ownLinesOnly: Set<String> = [],
                       now: Date = Date()) async -> [String: [Arrival]] {
        // Each train once: the push server has thousands of countdowns, many for the same one
        let unique = Array(Dictionary(selections.map { ($0.trainID, $0) }, uniquingKeysWith: { first, _ in first }).values)
        let feeds = unique.map { feedURLs(for: $0, includingOtherLines: includingOtherLines, ownLinesOnly: ownLinesOnly) }
        let urls = Set(feeds.flatMap { $0.own + $0.others })
        let stops = Set(unique.flatMap(\.stopIDs))
        let fetched = await withTaskGroup(of: (URL, Data?).self) { group in
            for url in urls {
                group.addTask { (url, await optionalData(from: url)) }
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

    /// `trains(for:includingOtherLines:ownLinesOnly:now:)` once the feeds are
    /// read: `feeds` has each one's arrivals at the selections' stops, and none
    /// for one that didn't come or couldn't be read. They're indexed by stop, so
    /// each selection looks only at its own: linear in the number of selections.
    static func trains(for selections: [Selection], in feeds: [URL: [Arrival]], includingOtherLines: Bool = true,
                       ownLinesOnly: Set<String> = [], now: Date) -> [String: [Arrival]] {
        let byStop = feeds.mapValues { Dictionary(grouping: $0, by: \.stop) }
        var trains: [String: [Arrival]] = [:]
        for selection in selections {
            let urls = feedURLs(for: selection, includingOtherLines: includingOtherLines, ownLinesOnly: ownLinesOnly)
            guard urls.own.allSatisfy({ byStop[$0] != nil }) else { continue }
            let stopIDs = selection.stopIDs
            // Typed a piece at a time: as one expression it's near too much for the type checker
            let all: [URL] = urls.own + urls.others
            let arrivals = all.flatMap { (url: URL) -> [Arrival] in stopIDs.flatMap { byStop[url]?[$0] ?? [] } }
            trains[selection.trainID] = Self.trains(for: selection, in: arrivals, now: now)
        }
        return trains
    }

    /// Of `arrivals`, the trains `selection` shows that are still to leave
    /// their stop and go on from it, soonest first and each trip once: what a
    /// board lists.
    static func trains(for selection: Selection, in arrivals: [Arrival], now: Date) -> [Arrival] {
        let station = selection.station
        return arrivals
            .filter { !$0.endsHere && $0.leaves > now && selection.shows($0, at: station) }
            .sorted { $0.time < $1.time }
            .oncePerTrip()
    }

    /// The arrivals at `stops` in the feeds of a selection's own lines, all of
    /// which have to be read and up to date, and of the other lines, any of
    /// which can be left out. How old each is goes by the newest of them all
    /// (`SubwayFeed.isStale`).
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

    /// Each of `feeds`' arrivals at `stops`, with none for one that can't be
    /// read or is out of date, which goes by the newest of them
    /// (`SubwayFeed.isStale`).
    static func arrivals(at stops: Set<String>, in feeds: [URL: Data], now: Date) -> [URL: [Arrival]] {
        let newest = SubwayFeed.newest(Array(feeds.values))
        return feeds.compactMapValues { try? SubwayFeed.arrivals(at: stops, in: $0, newest: newest, now: now) }
    }

    /// The feeds `selection`'s trains can be in; without `includingOtherLines`,
    /// or when it's one of `ownLinesOnly`, only its own lines'.
    static func feedURLs(for selection: Selection, includingOtherLines: Bool,
                         ownLinesOnly: Set<String> = []) -> (own: [URL], others: [URL]) {
        let all = Lines.feedURLs(sharingTracksWith: selection.routes)
        return includingOtherLines && !ownLinesOnly.contains(selection.trainID) ? all : (own: all.own, others: [])
    }

    private static let feeds = InFlight<Data>()
    private static let alertLists = InFlight<[AlertsFeed.Entry]>()

    /// The MTA's alerts, decoded once for every board (and the Nearby widget)
    /// that asks within `window` seconds: each widget would otherwise decode
    /// all of the feed's 1 MB itself. What's kept is the small part of it in
    /// effect around now. Nil when not wanted or the feed couldn't be had.
    /// The push server, which asks once a pass, keeps none (0): a pass due
    /// 30 seconds after the last would otherwise get that one's alerts.
    static func alertEntries(if wanted: Bool = true, reusingFor window: TimeInterval = 30) async -> [AlertsFeed.Entry]? {
        guard wanted else { return nil }
        return try? await alertLists.value(for: AlertsFeed.url, reusingFor: window) {
            try AlertsFeed.entries(in: try await data(from: AlertsFeed.url))
        }
    }

    /// How long the app goes by a feed it has just fetched rather than fetch it
    /// again: coming back to the app, a refresh and the countdown can all ask
    /// for the same feeds within moments, and the MTA updates them only every
    /// 30 seconds or so. The widget keeps nothing, having little memory to
    /// spare; its widgets share their boards through `SharedStore` instead.
    #if APP
    private static let reuseWindow: TimeInterval = 15
    #else
    private static let reuseWindow: TimeInterval = 0
    #endif

    /// Shared with any other fetch of `url` still under way: every widget
    /// reloads at once, and many go by the same feeds, which the widget's
    /// small memory allowance can't hold a copy of each of.
    private static func data(from url: URL) async throws -> Data {
        try await feeds.value(for: url, reusingFor: reuseWindow) {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    /// The fetches under way, and those just finished, by URL.
    private actor InFlight<Value: Sendable> {
        private var fetches: [URL: Task<Value, Error>] = [:]
        private var recent: [URL: (value: Value, fetched: Date)] = [:]

        /// One fetched less than `window` seconds ago comes back as it was.
        func value(for url: URL, reusingFor window: TimeInterval,
                   fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
            let now = Date.now
            // Ones too old to go by are let go
            recent = recent.filter { $0.value.fetched.isWithin(window, before: now) }
            if let recent = recent[url] { return recent.value }
            if let fetch = fetches[url] { return try await fetch.value }
            let task = Task { try await fetch() }
            fetches[url] = task
            defer { fetches[url] = nil }
            let value = try await task.value
            if window > 0 { recent[url] = (value, .now) }
            return value
        }
    }

    /// Fetched together; fails if any of them does.
    private static func data(from urls: [URL]) async throws -> [Data] {
        try await withThrowingTaskGroup(of: Data.self) { group in
            for url in urls {
                group.addTask { try await data(from: url) }
            }
            var all: [Data] = []
            for try await data in group {
                all.append(data)
            }
            return all
        }
    }

    /// A feed fetched as `data(from:)` fetches it, or nil when it couldn't be had.
    static func optionalData(from url: URL?) async -> Data? {
        guard let url else { return nil }
        return try? await data(from: url)
    }

    /// Fetched together; any that fail are left out.
    private static func optionalData(from urls: [URL]) async -> [Data] {
        await withTaskGroup(of: Data?.self) { group in
            for url in urls {
                group.addTask { await optionalData(from: url) }
            }
            var all: [Data] = []
            for await data in group {
                if let data { all.append(data) }
            }
            return all
        }
    }
}

private extension [Arrival] {
    /// The first time each trip comes, where it calls at more than one of a
    /// station's platforms. A trip without an id can't be told from another one.
    func oncePerTrip() -> [Arrival] {
        var seen = Set<String>()
        return filter { $0.trip.isEmpty || seen.insert($0.trip).inserted }
    }
}

extension Date {
    /// Whether it's less than `interval` before `now`, as times fetched or
    /// saved are when they're fresh. One after `now`, saved before the clock
    /// was set back, is taken to be old: it would otherwise stay fresh until
    /// the clock caught up.
    func isWithin(_ interval: TimeInterval, before now: Date) -> Bool {
        let age = now.timeIntervalSince(self)
        return age >= 0 && age < interval
    }
}
