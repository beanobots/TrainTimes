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

        var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

        /// Bikes of `kind` to take.
        func available(_ kind: Kind) -> Int { renting ? (kind == .eBike ? eBikes : bikes) : 0 }
        /// Docks to leave a bike in.
        var free: Int { returning ? docks : 0 }
    }

    /// Fewer bikes or docks than this, and a trip says so: they may be gone by the time you're there.
    static let few = 4

    private static let base = URL(string: "https://gbfs.citibikenyc.com/gbfs/en/")!

    /// Every dock with its counts now; nil if the feed can't be had. Where the docks are is
    /// fetched once a session, their counts each time (or within a minute of the last).
    static func docks() async -> [Dock]? {
        await Store.shared.docks()
    }

    private actor Store {
        static let shared = Store()

        private struct Place { var name: String; var lat: Double; var lon: Double }
        private struct Status { var bikes: Int; var eBikes: Int; var docks: Int; var renting: Bool; var returning: Bool }

        private var places: [String: Place]?
        private var status: (at: Date, docks: [Dock])?
        /// Counts this recent are used again rather than fetched.
        private static let fresh: TimeInterval = 60

        func docks() async -> [Dock]? {
            if let status, Date.now.timeIntervalSince(status.at) < Self.fresh { return status.docks }
            async let placesLoad = places == nil ? Self.loadPlaces() : nil
            async let statusLoad = Self.loadStatus()
            if let loaded = await placesLoad { places = loaded }
            guard let places, let counts = await statusLoad else { return nil }
            let docks = counts.compactMap { id, count -> Dock? in
                guard let place = places[id] else { return nil }
                return Dock(id: id, name: place.name, lat: place.lat, lon: place.lon,
                            bikes: max(0, count.bikes - count.eBikes), eBikes: count.eBikes, docks: count.docks,
                            renting: count.renting, returning: count.returning)
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
                                                    returning: station.is_returning != 0)
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
    /// The ride along the streets, dock to dock: Apple Maps' cycling route, or straight across
    /// where it had none.
    var path: [Walk.Point]
    /// The ride's minutes, unlocking and docking included.
    var rideMinutes: Int
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

    /// Whether `other` is this trip from and to the same docks: which of `dockChoices` it is.
    func sameDocks(as other: BikeTrip) -> Bool {
        pickup.id == other.pickup.id && dropoff.id == other.dropoff.id
    }

    /// Bikes to take where it starts, and docks to leave it where it ends.
    var bikes: Int { pickup.available(kind) }
    var docks: Int { dropoff.free }
    /// Whether either's few enough that they may be gone (`CitiBike.few`).
    var isShort: Bool { bikes < CitiBike.few || docks < CitiBike.few }
}
