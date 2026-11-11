import Crypto
import Foundation

/// Citi Bike's docks from its public GBFS feed, for the app's Nearby and the Citi Bike and Nearby
/// widgets (`GET /docks`). GBFS gives the whole city's counts as one file of about 1 MB, which
/// each phone would otherwise download for the few docks it shows: here it's read at most every
/// `countsLifetime`, once however many ask at the same time, and where the docks are once a day.
/// A read that fails isn't tried again for a while (`countsFailedWait`, `placesFailedWait`),
/// the last copy served meanwhile.
actor CitiBikeDocks {
    typealias Fetch = Web.Fetch

    /// A dock with its counts now, as the app's `CitiBike.Dock` reads it.
    struct Dock: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var lat: Double
        var lon: Double
        /// Classic bikes to take.
        var bikes: Int
        var eBikes: Int
        /// Free docks to leave one in.
        var docks: Int
        var renting: Bool
        var returning: Bool
        /// When Citi Bike last heard from it, seconds since 1970 as GBFS has it; left out where
        /// it doesn't say, so older apps read the answer as before.
        var lastReported: Int? = nil
    }

    /// How long a dock may go without reporting before it's taken as out of service, its counts
    /// long gone: as the app's `CitiBike.staleAfter`.
    static let staleAfter: TimeInterval = 30 * 60

    /// Whether a dock last reporting at `lastReported` (seconds since 1970; nil or 0 for not
    /// said) has been silent over `staleAfter` at `date`.
    static func isStale(lastReported: Int?, at date: Date) -> Bool {
        guard let lastReported, lastReported > 0 else { return false }
        return date.timeIntervalSince1970 - TimeInterval(lastReported) > staleAfter
    }

    /// Which docks a request wants (`has=`).
    enum Has: String, Sendable {
        /// Every dock, in service or not.
        case any
        /// Taking or leaving bikes.
        case service
        /// With a classic bike to take, an e-bike, or either.
        case bike
        case ebike
        case either

        func admits(_ dock: Dock) -> Bool {
            switch self {
            case .any: true
            case .service: dock.renting || dock.returning
            case .bike: dock.renting && dock.bikes > 0
            case .ebike: dock.renting && dock.eBikes > 0
            case .either: dock.renting && dock.bikes + dock.eBikes > 0
            }
        }
    }

    /// The most docks one request gets, and the farthest it looks.
    static let maxLimit = 10
    static let maxWithin: Double = 2000

    /// Counts this recent are served again rather than read: GBFS's own ttl for them, as it
    /// makes them no more often. The app's Nearby asks every minute.
    static let countsLifetime: TimeInterval = 60
    /// Where the docks are, read this recently, is used rather than read again; sooner where the
    /// counts name a dock it doesn't have, but not more than every `newDockWait`.
    static let placesLifetime: TimeInterval = 24 * 60 * 60
    static let newDockWait: TimeInterval = 10 * 60
    /// How long after a failed read of the counts, or of where the docks are, to read again,
    /// rather than on every request while Citi Bike's down. Where the docks are with no copy
    /// at all, as after a restart, is tried again as soon as the counts.
    static let countsFailedWait: TimeInterval = 30
    static let placesFailedWait: TimeInterval = 10 * 60

    private static let base = URL(string: "https://gbfs.citibikenyc.com/gbfs/en/")!

    private struct Place { var name: String; var lat: Double; var lon: Double }

    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var places: (at: Date, byID: [String: Place])?
    private var counts: (at: Date, docks: [Dock])?
    /// When the last read of each failed, till one doesn't.
    private var countsFailed: Date?
    private var placesFailed: Date?
    /// The reads under way, for any asking meanwhile to wait for: the actor lets others in at
    /// each `await`.
    private var reading: Task<[Dock]?, Never>?
    private var readingPlaces: Task<[String: Place]?, Never>?
    /// `GET /docks?places=1`'s answer, made once for each read of where the docks are (`at`).
    private var placesAnswer: (at: Date, json: Data, etag: String)?

    init(fetch: @escaping Fetch = Web.fetch, now: @escaping @Sendable () -> Date = { .now }) {
        self.fetch = fetch
        self.now = now
    }

    /// Up to `limit` docks within `within` meters of `point` that `has` admits, nearest first;
    /// nil if Citi Bike can't be read.
    func nearest(to point: (lat: Double, lon: Double), limit: Int, within: Double, has: Has) async -> [Dock]? {
        guard let docks = await docks() else { return nil }
        return docks.filter(has.admits)
            .map { (dock: $0, meters: Self.meters(point, ($0.lat, $0.lon))) }
            .filter { $0.meters <= within }
            .sorted { $0.meters < $1.meters }
            .prefix(limit)
            .map(\.dock)
    }

    /// The docks of `ids` there are, in that order; nil if Citi Bike can't be read.
    func docks(ids: [String]) async -> [Dock]? {
        guard let docks = await docks() else { return nil }
        let byID = Dictionary(docks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Where every dock is, without counts, for the app's dock picker, as `GET /docks?places=1`
    /// sends it (`{"docks": [...]}`), with an ETag for a phone with it to get a 304: encoded
    /// once for each read of where the docks are, not for each request. Nil if it can't be read.
    func everyPlaceAnswer() async -> (json: Data, etag: String)? {
        // The copy as kept, which the answer's made from, once read if need be
        guard await placesNow() != nil, let places else { return nil }
        if let placesAnswer, placesAnswer.at == places.at { return (placesAnswer.json, placesAnswer.etag) }
        // Keys sorted, and the tag by what's in it, so the same places read again are the same tag
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let json = try? encoder.encode(["docks": Self.everyPlace(in: places.byID)]) else { return nil }
        let etag = "\"" + SHA256.hash(data: json).hex.prefix(32) + "\""
        placesAnswer = (places.at, json, etag)
        return (json, etag)
    }

    private static func everyPlace(in byID: [String: Place]) -> [Dock] {
        byID.map { Dock(id: $0.key, name: $0.value.name, lat: $0.value.lat, lon: $0.value.lon,
                        bikes: 0, eBikes: 0, docks: 0, renting: false, returning: false) }
            .sorted { $0.id < $1.id }
    }

    private func docks() async -> [Dock]? {
        if let counts, now().timeIntervalSince(counts.at) < Self.countsLifetime { return counts.docks }
        if let countsFailed, now().timeIntervalSince(countsFailed) < Self.countsFailedWait { return counts?.docks }
        if let reading { return await reading.value }
        let read = Task { await self.read() }
        reading = read
        defer { reading = nil }
        return await read.value
    }

    /// Where the docks are, read again once older than `maxAge`, once however many ask at the
    /// same time; the last copy if that fails, or failed within `placesFailedWait`.
    private func placesNow(maxAge: TimeInterval = placesLifetime) async -> [String: Place]? {
        if let places, now().timeIntervalSince(places.at) < maxAge { return places.byID }
        let wait = places == nil ? Self.countsFailedWait : Self.placesFailedWait
        if let placesFailed, now().timeIntervalSince(placesFailed) < wait { return places?.byID }
        if let readingPlaces { return await readingPlaces.value }
        let read = Task { () -> [String: Place]? in
            guard let read = await self.readPlaces() else { return await self.placesFailing() }
            return await self.keep(read)
        }
        readingPlaces = read
        defer { readingPlaces = nil }
        return await read.value
    }

    /// A read of where the docks are failed: the last copy, if any.
    private func placesFailing() -> [String: Place]? {
        placesFailed = now()
        return places?.byID
    }

    private func keep(_ read: [String: Place]) -> [String: Place] {
        places = (now(), read)
        placesFailed = nil
        return read
    }

    private func read() async -> [Dock]? {
        async let placesRead = placesNow()
        async let statusRead = readStatus()
        guard var byID = await placesRead, let status = await statusRead else {
            countsFailed = now()
            return counts?.docks
        }
        // A dock newer than the places read: read again, though not over and over for one GBFS lists badly
        if status.contains(where: { byID[$0.id] == nil }), let read = await placesNow(maxAge: Self.newDockWait) {
            byID = read
        }
        let docks = status.compactMap { count -> Dock? in
            guard let place = byID[count.id] else { return nil }
            var dock = count
            dock.name = place.name
            dock.lat = place.lat
            dock.lon = place.lon
            return dock
        }
        counts = (now(), docks)
        countsFailed = nil
        return docks
    }

    private func get(_ name: String) async -> Data? {
        var request = URLRequest(url: Self.base.appendingPathComponent(name), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, status) = try? await fetch(request), status == 200 else { return nil }
        return data
    }

    private func readPlaces() async -> [String: Place]? {
        struct Feed: Decodable {
            struct Data: Decodable { var stations: [Station] }
            struct Station: Decodable { var station_id: String; var name: String; var lat: Double; var lon: Double }
            var data: Data
        }
        guard let data = await get("station_information.json"),
              let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return nil }
        return Dictionary(feed.data.stations.map { ($0.station_id, Place(name: $0.name, lat: $0.lat, lon: $0.lon)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Each installed dock's counts, with no name or place yet.
    private func readStatus() async -> [Dock]? {
        struct Feed: Decodable {
            struct Data: Decodable { var stations: [Station] }
            struct Station: Decodable {
                var station_id: String
                var num_bikes_available: Int?
                var num_ebikes_available: Int?
                var num_docks_available: Int?
                var is_installed: Int?
                var is_renting: Int?
                var is_returning: Int?
                /// Seconds since 1970; a number, whole or not
                var last_reported: Double?
            }
            var data: Data
        }
        guard let data = await get("station_status.json"),
              let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return nil }
        let date = now()
        return feed.data.stations.filter { $0.is_installed != 0 }.map { station in
            // Never below 0: a negative e-bike count isn't more classic bikes
            let all = station.num_bikes_available ?? 0, eBikes = max(0, station.num_ebikes_available ?? 0)
            // Not one too big for an Int, which would trap
            let reported = station.last_reported.flatMap { $0.isFinite && abs($0) < 1e12 ? Int($0) : nil }
            // Silent too long: out of service, whatever it last said
            let stale = Self.isStale(lastReported: reported, at: date)
            return Dock(id: station.station_id, name: "", lat: 0, lon: 0, bikes: max(0, all - eBikes), eBikes: eBikes,
                        docks: max(0, station.num_docks_available ?? 0),
                        renting: station.is_renting != 0 && !stale, returning: station.is_returning != 0 && !stale,
                        lastReported: reported)
        }
    }

    /// Meters between two points, flat across a city's width.
    static func meters(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let metersPerDegree = 111_195.0
        let dy = (a.0 - b.0) * metersPerDegree
        let dx = (a.1 - b.1) * metersPerDegree * cos((a.0 + b.0) / 2 * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// A dock id as GBFS gives them: letters, digits, dashes and dots.
    static func validID(_ id: Substring) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" }
    }
}
