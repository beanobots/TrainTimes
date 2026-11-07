import CoreLocation
import Foundation

/// What a saved widget (a Saved Route) shows: a subway train, a bus, or a Citi Bike dock.
enum SavedRouteKind: String, Codable, CaseIterable, Hashable, Sendable {
    case subway, bus, bike

    var name: String {
        switch self {
        case .subway: "Subway"
        case .bus: "Bus"
        case .bike: "Citi Bike"
        }
    }

    var symbol: String {
        switch self {
        case .subway: "tram.fill"
        case .bus: "bus.fill"
        case .bike: "bicycle"
        }
    }
}

/// A saved bus widget's bus: a line at a stop, one way, or both.
struct BusChoice: Codable, Hashable, Sendable {
    /// "B63", "M15-SBS".
    var line: String
    /// The stop, the way its buses leave it.
    var stop: BusStopTimes.Stop
    /// Where its buses are going, as Bus Time writes it.
    var destination: String?
    /// The stop the other way, for both directions; nil if there's none.
    var otherStop: BusStopTimes.Stop? = nil
    var otherDestination: String? = nil
    /// Shows the other way beside this one.
    var bothWays = false

    /// "4 Av & 9 St".
    var stopName: String { BusStopTimes.readable(stop.name) }
    /// "Cobble Hill", or the stop's name without a destination.
    var wayName: String { destination.map(BusStopTimes.destination) ?? stopName }
    var otherWayName: String? { otherDestination.map(BusStopTimes.destination) ?? otherStop.map { BusStopTimes.readable($0.name) } }

    /// Where `BusTimes` looks for the stop.
    var place: BusRide.Place {
        BusRide.Place(name: stopName, latitude: stop.latitude, longitude: stop.longitude)
    }

    var otherPlace: BusRide.Place? {
        otherStop.map { BusRide.Place(name: BusStopTimes.readable($0.name), latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// The same bus the other way, if there's a stop for it.
    var otherWay: BusChoice? {
        guard let otherStop else { return nil }
        return BusChoice(line: line, stop: otherStop, destination: otherDestination, otherStop: stop,
                         otherDestination: destination)
    }
}

/// A saved Citi Bike widget's dock.
struct DockChoice: Codable, Hashable, Sendable {
    /// GBFS's station id.
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    init(id: String, name: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ dock: CitiBike.Dock) {
        self.init(id: dock.id, name: dock.name, latitude: dock.lat, longitude: dock.lon)
    }
}

/// Which Citi Bikes Settings counts (Settings → Biking), shared with the widgets.
enum SharedBikeKinds: String, Codable, Hashable, Sendable {
    case bikes, eBikes, both

    var showsBikes: Bool { self != .eBikes }
    var showsEBikes: Bool { self != .bikes }
}
