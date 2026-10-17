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
    /// Elevator and escalator outages at the station, current ones first. Nil,
    /// as with `alerts`, when they weren't asked for or couldn't be had.
    var outages: [Outage]?

    /// The one thing the widget has room to mention, and how many more there are.
    func notice(includingElevators: Bool, includingAlerts: Bool = true,
                kinds: Set<ServiceAlert.Kind> = Set(ServiceAlert.Kind.allCases)) -> Notice? {
        var notices: [Notice] = []
        let elevatorsOut = (outages ?? []).filter { !$0.isPlanned && $0.isAccessibilityElevator }
        if includingElevators, let first = elevatorsOut.first {
            let label = elevatorsOut.count == 1 ? "Elevator out" : "\(elevatorsOut.count) elevators out"
            notices.append(Notice(kind: .elevator, label: label, text: first.serving, others: 0))
        }
        notices += (includingAlerts ? alerts ?? [] : [])
            .filter { kinds.contains($0.kind) }
            .map { Notice(kind: .alert($0.kind), label: $0.kind.label, text: $0.header, others: 0) }
        guard let first = notices.first else { return nil }
        return Notice(kind: first.kind, label: first.label, text: first.text, others: notices.count - 1)
    }

    /// What `selection`'s widget, countdown and Siri mention: its own choice of
    /// alerts and elevators, and only the kinds of alert chosen in Settings.
    func notice(for selection: Selection, settings: AppSettings) -> Notice? {
        notice(includingElevators: selection.elevatorAlerts, includingAlerts: selection.serviceAlerts,
               kinds: settings.alertKinds)
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
}

enum TrainService {
    /// Trains, alerts and (when asked for) elevator outages for `selection`, fetched
    /// together. Only the chosen lines' own train feeds are required: without the
    /// other lines' feeds there are just no rerouted trains, and without alerts or
    /// outages the board has nil for them. Without `includingAlerts`, it has neither.
    static func board(for selection: Selection, includingAlerts: Bool = true, includingOutages: Bool = true,
                      now: Date = Date()) async throws -> Board {
        let includingOutages = includingAlerts && includingOutages
        let feeds = Lines.feedURLs(sharingTracksWith: selection.routes)
        async let trainData = data(from: feeds.own)
        async let otherTrainData = optionalData(from: feeds.others)
        async let alertEntries = alertEntries(if: includingAlerts)
        async let outages = outages(for: selection, if: includingOutages)

        let stops = Set(selection.stopIDs)
        var arrivals: [Arrival] = []
        for data in try await trainData {
            arrivals += try SubwayFeed.arrivals(at: stops, in: data)
        }
        for data in await otherTrainData {
            arrivals += (try? SubwayFeed.arrivals(at: stops, in: data)) ?? []
        }
        let trains = arrivals.filter { $0.time > now && selection.shows($0) }.sorted { $0.time < $1.time }.oncePerTrip()
        let alerts = await alertEntries.map { AlertsFeed.alerts(for: selection, in: $0, now: now) }
        return Board(trains: trains, alerts: alerts, outages: await outages)
    }

    /// Just the alerts and (when asked for) outages for `selection`, as `board`
    /// has them, with no trains: for the alerts sheet, which needn't fail
    /// because a train feed did.
    static func notices(for selection: Selection, includingOutages: Bool = true, now: Date = Date()) async -> Board {
        async let alertEntries = alertEntries(if: true)
        async let outages = outages(for: selection, if: includingOutages)
        let alerts = await alertEntries.map { AlertsFeed.alerts(for: selection, in: $0, now: now) }
        return Board(trains: [], alerts: alerts, outages: await outages)
    }

    /// The outages at `selection`'s station: nil when not wanted or the feed
    /// couldn't be had or read.
    private static func outages(for selection: Selection, if wanted: Bool) async -> [Outage]? {
        guard wanted else { return nil }
        guard let complex = selection.station?.complex else { return [] }
        guard let data = await optionalData(from: OutagesFeed.url) else { return nil }
        return try? OutagesFeed.outages(atComplex: complex, in: data)
    }

    /// The trains of each of `selections`, by `Selection.trainID`, found as
    /// `board` finds them but fetching each feed just once, for the Live tab's
    /// lists. One whose own lines' feeds didn't come is left out. Without
    /// `includingOtherLines`, only the lines' own feeds are fetched, which is
    /// enough where only each line's own trains are shown.
    static func trains(for selections: [Selection], includingOtherLines: Bool = true,
                       now: Date = Date()) async -> [String: [Arrival]] {
        let feeds: [(own: [URL], others: [URL])] = selections.map { selection in
            let all = Lines.feedURLs(sharingTracksWith: selection.routes)
            return includingOtherLines ? all : (own: all.own, others: [])
        }
        let urls = Set(feeds.flatMap { $0.own + $0.others })
        let stops = Set(selections.flatMap(\.stopIDs))
        let arrivals = await withTaskGroup(of: (URL, [Arrival]?).self) { group in
            for url in urls {
                group.addTask {
                    guard let data = await optionalData(from: url) else { return (url, nil) }
                    return (url, try? SubwayFeed.arrivals(at: stops, in: data))
                }
            }
            var all: [URL: [Arrival]] = [:]
            for await (url, arrivals) in group {
                all[url] = arrivals
            }
            return all
        }
        var trains: [String: [Arrival]] = [:]
        for (selection, feeds) in zip(selections, feeds) where feeds.own.allSatisfy({ arrivals[$0] != nil }) {
            let stops = Set(selection.stopIDs)
            trains[selection.trainID] = (feeds.own + feeds.others)
                .flatMap { arrivals[$0] ?? [] }
                .filter { stops.contains($0.stop) && $0.time > now && selection.shows($0) }
                .sorted { $0.time < $1.time }
                .oncePerTrip()
        }
        return trains
    }

    private static let feeds = InFlight<Data>()
    private static let alertLists = InFlight<[AlertsFeed.Entry]>()

    /// The MTA's alerts, decoded once for every board (and the Nearby widget)
    /// that asks within 30 seconds: each widget would otherwise decode all of
    /// the feed's 1 MB itself. What's kept is the small part of it in effect
    /// around now. Nil when not wanted or the feed couldn't be had.
    static func alertEntries(if wanted: Bool = true) async -> [AlertsFeed.Entry]? {
        guard wanted else { return nil }
        return try? await alertLists.value(for: AlertsFeed.url, reusingFor: 30) {
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
            recent = recent.filter { now.timeIntervalSince($0.value.fetched) < window }
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

    private static func optionalData(from url: URL?) async -> Data? {
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
