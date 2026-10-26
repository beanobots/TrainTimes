import CoreLocation

/// The stations closest to where you are, for the top of the station lists.
enum Nearby {
    struct Result: Identifiable {
        let station: Station
        /// To the middle of its platforms.
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
            max(1, Int((TripPlanner.walkSeconds(meters) / 60).rounded()))
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

    /// Up to `limit` stations within `range`, nearest first.
    static func stations(near location: CLLocation, among stations: [Station] = StationDirectory.all, limit: Int = 5) -> [Result] {
        results(near: location, among: stations)
            .filter { $0.meters <= range }
            .sorted { $0.meters < $1.meters }
            .prefix(limit)
            .map { $0 }
    }

    /// The closest station at any distance, to say how far the subway is.
    static func nearest(to location: CLLocation) -> Result? {
        results(near: location, among: StationDirectory.all).min { $0.meters < $1.meters }
    }

    private static func results(near location: CLLocation, among stations: [Station]) -> [Result] {
        stations.map { Result(station: $0, meters: location.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon))) }
    }

    /// So the app can reload it when location is turned on.
    static let widgetKind = "NearbyWidget"

    /// Opens the app to grant location: it asks the first time, or opens Settings if it was
    /// turned off.
    static let allowURL = URL(string: "\(AppLink.scheme)://nearby/allow")!
}
