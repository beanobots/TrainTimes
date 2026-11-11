import CoreLocation
import Foundation

/// Citi Bike's docks, from its public GBFS feed: where each is, and how many bikes, e-bikes and
/// free docks it has now. For New Trip's Bike, which rides a Citi Bike to or from a train, or
/// all the way.
enum CitiBike {
    /// A classic bike, or an e-bike: which a trip's ride takes, and which docks have one.
    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case bike
        case eBike

        var name: String { self == .eBike ? "E-Bike" : "Bike" }
        /// "6 bikes", "1 e-bike".
        func count(_ number: Int) -> String {
            let noun = self == .eBike ? "e-bike" : "bike"
            return "\(number) \(noun)\(number == 1 ? "" : "s")"
        }
    }

    /// A dock, as it was when the trips were planned.
    struct Dock: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var lat: Double
        var lon: Double
        /// Classic bikes to take.
        var bikes: Int
        var eBikes: Int
        /// Free docks to leave one in.
        var docks: Int
        /// Whether bikes can be taken from it, and left in it, now.
        var renting: Bool
        var returning: Bool
        /// When Citi Bike last heard from it, seconds since 1970 as GBFS has it; nil where not
        /// said (an older server's answer).
        var lastReported: Int? = nil

        var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

        /// Bikes of `kind` to take; never below 0, as a feed's count can be.
        func available(_ kind: Kind) -> Int { renting ? max(0, kind == .eBike ? eBikes : bikes) : 0 }
        /// Docks to leave a bike in; never below 0.
        var free: Int { returning ? max(0, docks) : 0 }

        /// As it stands at `date`: silent for over `staleAfter`, out of service, as its counts
        /// may be long gone.
        func checked(at date: Date = .now) -> Dock {
            guard CitiBike.isStale(lastReported: lastReported, at: date) else { return self }
            var dock = self
            dock.renting = false
            dock.returning = false
            return dock
        }
    }

    /// Fewer bikes or docks than this, and a trip says so: they may be gone by the time you're there.
    static let few = 4
    /// A member's minutes a ride, included: past them Citi Bike charges by the minute (a single
    /// ride's 30).
    static let includedMinutes = 45

    private static let base = URL(string: "https://gbfs.citibikenyc.com/gbfs/en/")!

    /// Every dock with its counts now, the whole city's (about 1 MB): for New Trip, whose trips
    /// may ride from or to docks anywhere along them; elsewhere `docks(near:)`, which asks the
    /// push server for only those. Nil if the feed can't be had. Where the docks are is
    /// fetched once a day, kept in the App Group for the app and widgets alike (each widget
    /// reload is a new session), their counts each time (or within a minute of the last).
    static func docks() async -> [Dock]? {
        await Store.shared.docks()
    }

    /// Which docks `docks(near:)` wants, as the push server's `has=`.
    enum Has: String, Sendable {
        /// Every dock, in service or not.
        case any
        /// Taking or leaving bikes.
        case service
        /// With a classic bike to take, an e-bike, or either.
        case bike
        case ebike
        case either

        /// With the bikes Settings picks to take.
        init(taking kinds: SharedBikeKinds) {
            switch kinds {
            case .bikes: self = .bike
            case .eBikes: self = .ebike
            case .both: self = .either
            }
        }

        func admits(_ dock: Dock) -> Bool {
            switch self {
            case .any: true
            case .service: dock.renting || dock.returning
            case .bike: dock.available(.bike) > 0
            case .ebike: dock.available(.eBike) > 0
            case .either: dock.available(.bike) + dock.available(.eBike) > 0
            }
        }
    }

    /// How long a dock may go without reporting before it's taken as out of service: as the
    /// push server's `CitiBikeDocks.staleAfter`.
    static let staleAfter: TimeInterval = 30 * 60

    /// Whether a dock last reporting at `lastReported` (seconds since 1970; nil or 0 for not
    /// said) has been silent over `staleAfter` at `date`.
    static func isStale(lastReported: Int?, at date: Date) -> Bool {
        guard let lastReported, lastReported > 0 else { return false }
        return date.timeIntervalSince1970 - TimeInterval(lastReported) > staleAfter
    }

    /// The most docks the push server gives for one `docks(near:)`.
    static let mostAsked = 10

    /// Up to `limit` docks within `within` meters of `location` that `has` admits, nearest first;
    /// nil if they can't be had. From the push server's `GET /docks` (server/README.md), which
    /// sends only these rather than the whole city's counts; without it (unreachable, or older
    /// than the route), from the whole city's here.
    static func docks(near location: CLLocation, limit: Int = 5, within: Double = 800,
                      has: Has = .any) async -> [Dock]? {
        let at = String(format: "%.5f,%.5f", location.coordinate.latitude, location.coordinate.longitude)
        if let served = await served(["at": at, "limit": String(limit), "within": String(Int(within)),
                                      "has": has.rawValue]) {
            return served
        }
        return await docks()?.filter(has.admits)
            .map { (dock: $0, meters: $0.location.distance(from: location)) }
            .filter { $0.meters <= within }
            .sorted { $0.meters < $1.meters }
            .prefix(limit)
            .map(\.dock)
    }

    /// The docks of `ids` there are, in that order; nil if they can't be had. As `docks(near:)`.
    static func docks(ids: [String]) async -> [Dock]? {
        guard !ids.isEmpty else { return [] }
        if let served = await served(["ids": ids.joined(separator: ",")]) { return served }
        guard let docks = await docks() else { return nil }
        let byID = Dictionary(docks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Where every dock is, for picking one: counts all 0. As `docks()` keeps them: this
    /// process's copy, else the App Group's saved within a day, else the server's (which then
    /// needn't send counts), saved for both. Edit Widget asks on opening and at each letter typed.
    static func places() async -> [Dock]? {
        await Store.shared.allPlaces()
    }

    /// The push server's `GET /docks` with `query`; nil if it can't answer.
    private static func served(_ query: [String: String]) async -> [Dock]? {
        guard let baseURL = ServerRoutes.baseURL,
              var components = URLComponents(url: baseURL.appendingPathComponent("docks"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        return await Served.shared.docks(at: url)
    }

    /// The push server's `GET /docks`, each address asked once at a time: asked again while it's
    /// in flight, the same answer; failed, not asked again for `failedFor`. Nearby's load starts
    /// over as it finds you and again as it lists your stations, each start asking for the same
    /// docks, three at once, and again on each start while the server's unreachable.
    private actor Served {
        static let shared = Served()

        /// How long a failed address isn't asked again.
        static let failedFor: TimeInterval = 30

        private var asking: [URL: Task<[Dock]?, Never>] = [:]
        private var failed: [URL: Date] = [:]

        func docks(at url: URL) async -> [Dock]? {
            if let at = failed[url], Date.now.timeIntervalSince(at) < Self.failedFor { return nil }
            if let asking = asking[url] { return await asking.value }
            // Not the caller's own task: one cancelled as Nearby starts over isn't a failure, and
            // the next start joins it
            let ask = Task { await Self.fetch(url) }
            asking[url] = ask
            let docks = await ask.value
            asking[url] = nil
            failed = failed.filter { Date.now.timeIntervalSince($0.value) < Self.failedFor }
            failed[url] = docks == nil ? .now : nil
            return docks
        }

        private static func fetch(_ url: URL) async -> [Dock]? {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            struct Response: Decodable { var docks: [Dock] }
            let now = Date.now
            return await ServerRoutes.fetch(Response.self, with: request)?.docks.map { $0.checked(at: now) }
        }
    }

    private actor Store {
        static let shared = Store()

        private struct Place: Codable { var name: String; var lat: Double; var lon: Double }
        private struct Status {
            var bikes: Int; var eBikes: Int; var docks: Int; var renting: Bool; var returning: Bool; var lastReported: Int?
        }

        /// Where the docks are, as last fetched (about 1 MB as sent, much less as kept).
        private struct SavedPlaces: Codable { var saved: Date; var places: [String: Place] }

        private var places: [String: Place]?
        /// Whether `places` came from the saved file, and so may be missing docks new since.
        private var placesSaved = false
        private var status: (at: Date, docks: [Dock])?
        /// Counts this recent are used again rather than fetched.
        private static let fresh: TimeInterval = 60
        /// Where the docks are, saved this recently, is used rather than fetched.
        private static let placesLife: TimeInterval = 24 * 60 * 60
        /// In the container's Library/Caches, which iOS may clear.
        private static let placesFile = SharedStore.url(named: "Library/Caches/citibike-docks.json")

        /// The load under way, for any asking meanwhile to wait for rather than fetch again: the
        /// actor lets another in at each `await`.
        private var loading: Task<[Dock]?, Never>?
        /// As `loading`, for `allPlaces`.
        private var placesLoading: Task<[Dock]?, Never>?

        /// Where every dock is (`CitiBike.places()`), with no counts.
        func allPlaces() async -> [Dock]? {
            if places == nil, let saved = Self.savedPlaces() {
                places = saved
                placesSaved = true
            }
            if let places {
                return places.map { id, place in
                    Dock(id: id, name: place.name, lat: place.lat, lon: place.lon,
                         bikes: 0, eBikes: 0, docks: 0, renting: true, returning: true)
                }
            }
            if let placesLoading { return await placesLoading.value }
            let load = Task { await self.loadAllPlaces() }
            placesLoading = load
            defer { placesLoading = nil }
            return await load.value
        }

        /// The server's, kept and saved as `load` keeps Citi Bike's own; without it, `docks()`.
        private func loadAllPlaces() async -> [Dock]? {
            guard let served = await CitiBike.served(["places": "1"]) else { return await docks() }
            let loaded = Dictionary(served.map { ($0.id, Place(name: $0.name, lat: $0.lat, lon: $0.lon)) },
                                    uniquingKeysWith: { first, _ in first })
            if !loaded.isEmpty {
                places = loaded
                placesSaved = false
                Self.save(loaded)
            }
            return served
        }

        func docks() async -> [Dock]? {
            if let status, Date.now.timeIntervalSince(status.at) < Self.fresh { return status.docks }
            if let loading { return await loading.value }
            let load = Task { await self.load() }
            loading = load
            defer { loading = nil }
            return await load.value
        }

        private func load() async -> [Dock]? {
            if places == nil, let saved = Self.savedPlaces() {
                places = saved
                placesSaved = true
            }
            async let placesLoad = places == nil ? Self.loadPlaces() : nil
            async let statusLoad = Self.loadStatus()
            if let loaded = await placesLoad {
                places = loaded
                Self.save(loaded)
            }
            guard var places, let counts = await statusLoad else { return nil }
            // Saved without a dock that's new since: where they are fetched again, once
            if placesSaved, counts.keys.contains(where: { places[$0] == nil }) {
                placesSaved = false
                if let loaded = await Self.loadPlaces() {
                    places = loaded
                    self.places = loaded
                    Self.save(loaded)
                }
            }
            let docks = counts.compactMap { id, count -> Dock? in
                guard let place = places[id] else { return nil }
                return Dock(id: id, name: place.name, lat: place.lat, lon: place.lon,
                            // A negative e-bike count isn't more classic bikes
                            bikes: max(0, count.bikes - max(0, count.eBikes)), eBikes: max(0, count.eBikes),
                            docks: max(0, count.docks),
                            renting: count.renting, returning: count.returning, lastReported: count.lastReported)
                    .checked()
            }
            status = (.now, docks)
            return docks
        }

        private static func fetch(_ name: String) async -> Data? {
            var request = URLRequest(url: base.appendingPathComponent(name),
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }

        /// Where the docks are, if saved within `placesLife`.
        private static func savedPlaces() -> [String: Place]? {
            guard let placesFile, let data = try? Data(contentsOf: placesFile),
                  let saved = try? JSONDecoder().decode(SavedPlaces.self, from: data),
                  saved.saved.isWithin(placesLife, before: .now), !saved.places.isEmpty else { return nil }
            return saved.places
        }

        private static func save(_ places: [String: Place]) {
            guard let placesFile, let data = try? JSONEncoder().encode(SavedPlaces(saved: .now, places: places)) else { return }
            try? FileManager.default.createDirectory(at: placesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: placesFile, options: .atomic)
        }

        private static func loadPlaces() async -> [String: Place]? {
            struct Feed: Decodable {
                struct Data: Decodable { var stations: [Station] }
                struct Station: Decodable { var station_id: String; var name: String; var lat: Double; var lon: Double }
                var data: Data
            }
            guard let data = await fetch("station_information.json"),
                  let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return nil }
            return Dictionary(feed.data.stations.map { ($0.station_id, Place(name: $0.name, lat: $0.lat, lon: $0.lon)) },
                              uniquingKeysWith: { first, _ in first })
        }

        private static func loadStatus() async -> [String: Status]? {
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
            guard let data = await fetch("station_status.json"),
                  let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return nil }
            var status: [String: Status] = [:]
            for station in feed.data.stations where station.is_installed != 0 {
                status[station.station_id] = Status(bikes: station.num_bikes_available ?? 0,
                                                    eBikes: station.num_ebikes_available ?? 0,
                                                    docks: station.num_docks_available ?? 0,
                                                    renting: station.is_renting != 0,
                                                    returning: station.is_returning != 0,
                                                    // Not one too big for an Int, which would trap
                                                    lastReported: station.last_reported.flatMap {
                                                        $0.isFinite && abs($0) < 1e12 ? Int($0) : nil
                                                    })
            }
            return status
        }
    }
}

/// A New Trip trip with a Citi Bike: ridden from one dock to another all the way, or to a train
/// (`bikeFirst`), or from one.
struct BikeTrip: Codable, Hashable, Sendable {
    var kind: CitiBike.Kind
    /// Where the bike's taken from, and left.
    var pickup: CitiBike.Dock
    var dropoff: CitiBike.Dock
    /// The ride along the streets, dock to dock: Apple Maps' cycling route (a trip it had none
    /// for isn't planned).
    var path: [Walk.Point]
    /// The ride's minutes, unlocking and docking included.
    var rideMinutes: Int
    /// How much of `path` runs on a protected bike lane or path, 0 to 1 (`BikeLanes`); nil if
    /// it's not known.
    var protectedShare: Double? = nil
    /// The train ridden after the bike, or before it; nil riding all the way.
    var train: SharedTrip.Option?
    var bikeFirst: Bool
    /// Door to door, as planned.
    var minutes: Int
    /// Where it's short (`isShort`), the trip as planned and the same from or to the fuller dock
    /// nearest instead, each timed, in that order, for New Trip to switch between as it does a
    /// change's stations; whichever's switched to carries them all. Empty where it's not short,
    /// or there's no fuller dock.
    var dockChoices: [BikeTrip] = []
    /// Your own bike rather than a Citi Bike: `pickup` and `dropoff` are then where it's ridden
    /// from and to (`CitiBike.Dock.place`), with nothing to count, and `dockChoices` is empty.
    var owned = false
    /// With a train, your own bike taken on it with you, rather than locked at the station it's
    /// ridden to.
    var carried = false
    /// A carried bike's ride after the train, from its last station to the end; nil where
    /// there's none.
    var rideAfter: Ride? = nil

    /// A carried bike's second ride, after the train.
    struct Ride: Codable, Hashable, Sendable {
        var from: CitiBike.Dock
        var to: CitiBike.Dock
        var path: [Walk.Point]
        var minutes: Int
    }

    /// Whether `other` is this trip from and to the same docks: which of `dockChoices` it is.
    func sameDocks(as other: BikeTrip) -> Bool {
        pickup.id == other.pickup.id && dropoff.id == other.dropoff.id
    }

    /// Bikes to take where it starts, and docks to leave it where it ends.
    var bikes: Int { pickup.available(kind) }
    var docks: Int { dropoff.free }
    /// Whether either's few enough that they may be gone (`CitiBike.few`).
    var isShort: Bool { !owned && (bikes < CitiBike.few || docks < CitiBike.few) }
    /// Whether its ride's longer than a member's included (`CitiBike.includedMinutes`).
    var isOverIncluded: Bool { !owned && rideMinutes > CitiBike.includedMinutes }
}

extension CitiBike.Dock {
    /// A place your own bike's ridden from or to, as a dock with nothing to count: where you
    /// start, a station, or where you're going. Its id to about 11 m, as `BikePlanner` keeps
    /// rides by it: a new fix a few metres on is the same ride, not asked of Apple Maps again.
    static func place(_ name: String, _ location: CLLocation) -> CitiBike.Dock {
        let (lat, lon) = (location.coordinate.latitude, location.coordinate.longitude)
        return CitiBike.Dock(id: String(format: "place %.4f %.4f", lat, lon), name: name, lat: lat, lon: lon,
                             bikes: 0, eBikes: 0, docks: 0, renting: true, returning: true)
    }
}

extension DockChoice {
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    init(_ dock: CitiBike.Dock) {
        self.init(id: dock.id, name: dock.name, latitude: dock.lat, longitude: dock.lon)
    }
}
