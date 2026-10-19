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

        /// About how long it takes to walk there: 3 mph, and a fifth more for
        /// streets that don't go straight there. Never less than a minute.
        var walkMinutes: Int {
            max(1, Int((meters * 1.2 / 80).rounded()))
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
        results(near: location, among: stations)
            .filter { $0.meters <= range }
            .sorted { $0.meters < $1.meters }
            .prefix(limit)
            .map { $0 }
    }

    /// The closest station of all, however far: for saying how far the subway is.
    static func nearest(to location: CLLocation) -> Result? {
        results(near: location, among: StationDirectory.all).min { $0.meters < $1.meters }
    }

    private static func results(near location: CLLocation, among stations: [Station]) -> [Result] {
        stations.map { Result(station: $0, meters: location.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon))) }
    }

    /// The Nearby widget's kind, for the app to reload it when location is turned on.
    static let widgetKind = "NearbyWidget"

    /// Opens the app at the Live tab, which finds you again: a tap on the Nearby widget.
    static let url = URL(string: "traintimes://nearby")!

    /// Opens the app to let it have your location: it asks the first time,
    /// and once location's been turned off, opens Settings.
    static let allowURL = URL(string: "traintimes://nearby/allow")!

    /// Opens the app at a station's every line both ways, from a station's
    /// name on the Nearby widget: "traintimes://station?id=R33". With `first`,
    /// those lines are at the top, as for "4 more lines":
    /// "traintimes://station?id=R33&first=N,Q".
    static func stationURL(_ station: Station, first: [String] = []) -> URL {
        var components = URLComponents()
        components.scheme = "traintimes"
        components.host = "station"
        components.queryItems = [URLQueryItem(name: "id", value: station.id)]
        if !first.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "first", value: first.joined(separator: ",")))
        }
        return components.url ?? url
    }

    /// The station a `stationURL` is for, and the lines to put first, or nil
    /// for any other link.
    static func station(from url: URL) -> (station: Station, first: [String])? {
        guard url.scheme == "traintimes", url.host == "station",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "id" })?.value,
              let station = StationDirectory.station(id: id) else { return nil }
        let first = items.first(where: { $0.name == "first" })?.value?
            .split(separator: ",").map(String.init) ?? []
        return (station, first)
    }
}
