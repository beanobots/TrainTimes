import CoreLocation

extension Station {
    /// The middle of its platforms, as a coordinate and as a location.
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
}

/// The stations closest to where you are, for the top of the station lists.
enum Nearby {
    struct Result: Identifiable {
        let station: Station
        /// To the middle of its platforms: the walk there (`WalkReach`), round by a bridge where
        /// there's water between; as the crow flies for `nearest(to:)`.
        let meters: Double

        var id: String { station.id }

        /// "0.3 mi" or "0.5 km" per locale; at least 0.1, never in feet.
        var distance: String {
            let unit: UnitLength = Locale.current.measurementSystem == .metric ? .kilometers : .miles
            let value = max(Measurement(value: meters, unit: UnitLength.meters).converted(to: unit).value, 0.1)
            return Measurement(value: value, unit: unit)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        }

        /// As `TripPlanner.walkSeconds(_:)` times it; at least 1.
        var walkMinutes: Int {
            TripPlanner.walkMinutes(meters)
        }
    }

    /// Meters; beyond this, no stations are listed.
    private static let range: Double = 5_000

    /// `range` in the phone's units: "3 miles" or "5 kilometers".
    static var rangeDescription: String {
        let unit: UnitLength = Locale.current.measurementSystem == .metric ? .kilometers : .miles
        return Measurement(value: range, unit: UnitLength.meters).converted(to: unit)
            .formatted(.measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// Up to `limit` stations within a walk of `range`, nearest by the walk first: none across
    /// the water but over a bridge you can walk (`WalkReach`).
    static func stations(near location: CLLocation, among stations: [Station] = StationDirectory.all, limit: Int = 5) -> [Result] {
        let from = WalkReach.From(location)
        // The walk's never shorter than the crow flies, so only those that close are walked
        return stations.filter { location.distance(from: $0.location) <= range }
            .compactMap { station in from.meters(to: station).map { Result(station: station, meters: $0) } }
            .filter { $0.meters <= range }
            .sorted { $0.meters < $1.meters }
            .prefix(limit)
            .map { $0 }
    }

    /// The closest station as the crow flies, at any distance, to say how far the subway is.
    static func nearest(to location: CLLocation) -> Result? {
        StationDirectory.all.map { Result(station: $0, meters: location.distance(from: $0.location)) }
            .min { $0.meters < $1.meters }
    }

    /// So the app can reload it when location is turned on.
    static let widgetKind = "NearbyWidget"

    /// Opens the app to grant location: it asks the first time, or opens Settings if it was
    /// turned off.
    static let allowURL = URL(string: "\(AppLink.scheme)://nearby/allow")!
}
