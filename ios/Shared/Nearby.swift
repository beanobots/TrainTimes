import CoreLocation

/// The stations closest to where you are, for the top of the station lists.
enum Nearby {
    struct Result: Identifiable {
        let station: Station
        /// From you to the middle of its platforms.
        let meters: Double

        var id: String { station.id }

        /// "0.3 mi", or "0.5 km" where the phone uses kilometres; never less
        /// than 0.1, and never in feet.
        var distance: String {
            let unit: UnitLength = Locale.current.measurementSystem == .metric ? .kilometers : .miles
            let value = max(Measurement(value: meters, unit: UnitLength.meters).converted(to: unit).value, 0.1)
            return Measurement(value: value, unit: unit)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        }
    }

    /// No further than this, so there's no list far from the subway.
    private static let range: Double = 5_000

    /// How far `range` is, in the phone's units: "3 miles" or "5 kilometers".
    static var rangeDescription: String {
        let unit: UnitLength = Locale.current.measurementSystem == .metric ? .kilometers : .miles
        return Measurement(value: range, unit: UnitLength.meters).converted(to: unit)
            .formatted(.measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// The closest few of `stations` to `location`, nearest first.
    static func stations(near location: CLLocation, among stations: [Station] = StationDirectory.all, limit: Int = 5) -> [Result] {
        stations
            .map { Result(station: $0, meters: location.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon))) }
            .filter { $0.meters <= range }
            .sorted { $0.meters < $1.meters }
            .prefix(limit)
            .map { $0 }
    }
}
