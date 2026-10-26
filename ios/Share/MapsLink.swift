import Foundation

/// Directions shared from Apple Maps or Google Maps, as their links give them: a start (nil for
/// a place shared on its own, so from where you are) and an end.
struct MapsLink: Equatable {
    var app: MapsApp
    var origin: Place?
    var destination: Place

    /// One end of the directions.
    enum Place: Equatable {
        case coordinate(latitude: Double, longitude: Double, name: String?)
        case address(String)
        case currentLocation

        /// What the sheet calls it; nil for a bare coordinate.
        var name: String? {
            switch self {
            case .coordinate(_, _, let name): name
            case .address(let address): address.components(separatedBy: ",").first
            case .currentLocation: "Your location"
            }
        }

        /// From a link's "40.68,-73.97", "Current Location" or address.
        init(text: String, name: String? = nil) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || ["current location", "my location", "your location"].contains(text.lowercased()) {
                self = .currentLocation
            } else if let coordinate = Self.coordinate(in: text) {
                self = .coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude, name: name)
            } else {
                self = .address(text)
            }
        }

        /// "40.68,-73.97" as a latitude and longitude.
        static func coordinate(in text: String) -> (latitude: Double, longitude: Double)? {
            let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]),
                  abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
            return (latitude, longitude)
        }
    }

    /// Short links to expand before reading: Google's maps.app.goo.gl and goo.gl/maps, and Apple's
    /// maps.apple/p/.
    static func isShortLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "maps.app.goo.gl" || (host == "goo.gl" && url.path.hasPrefix("/maps"))
            || host == "maps.apple" || (host == "maps.apple.com" && url.path.hasPrefix("/p/"))
    }

    /// The directions in an Apple Maps or Google Maps link; nil for any other link.
    init?(url: URL) {
        guard let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { first, _ in first })
        if host == "maps.apple.com" || host == "maps.apple" {
            guard let found = Self.apple(query) else { return nil }
            self = found
        } else if host.hasPrefix("www.google.") || host.hasPrefix("google.") || host.hasPrefix("maps.google.") {
            guard components.path.hasPrefix("/maps") || host.hasPrefix("maps."),
                  let found = Self.google(path: components.percentEncodedPath, query: query) else { return nil }
            self = found
        } else {
            return nil
        }
    }

    private init(app: MapsApp, origin: Place?, destination: Place) {
        self.app = app
        self.origin = origin
        self.destination = destination
    }

    /// maps.apple.com/?saddr=…&daddr=…, its newer /directions?source=…&destination=…, or a place:
    /// ?ll=…&q=Name, /place?coordinate=…&name=…, ?address=….
    private static func apple(_ query: [String: String]) -> MapsLink? {
        let name = query["name"] ?? query["q"]
        let origin = (query["saddr"] ?? query["source"]).map { Place(text: $0) }
        let destination: Place? = (query["daddr"] ?? query["destination"]).map { Place(text: $0) }
            ?? (query["coordinate"] ?? query["ll"]).flatMap { Place.coordinate(in: $0) }
                .map { Place.coordinate(latitude: $0.latitude, longitude: $0.longitude, name: name) }
            ?? (query["address"] ?? query["q"]).map(Place.address)
        return destination.map { MapsLink(app: .apple, origin: origin, destination: $0) }
    }

    /// google.com/maps/dir/?api=1&origin=…&destination=…, /maps?saddr=…&daddr=…,
    /// /maps/dir/Start/End/@…/data=… (whose data has each place's coordinates as !1d<lon>!2d<lat>),
    /// or a place: /maps/place/Name/@lat,lon,z/data=…!3d<lat>!4d<lon>, /maps?q=….
    private static func google(path: String, query: [String: String]) -> MapsLink? {
        if let destination = query["destination"] ?? query["daddr"] {
            let origin = (query["origin"] ?? query["saddr"]).map { Place(text: $0) }
            return MapsLink(app: .google, origin: origin, destination: Place(text: destination))
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let data = parts.first { $0.hasPrefix("data=") } ?? ""
        if let dir = parts.firstIndex(of: "dir") {
            // The stops, up to the map's @ or data; an empty one is where you are
            let stops = parts[(dir + 1)...].prefix { !$0.hasPrefix("@") && !$0.hasPrefix("data=") }
                .map { decoded($0) }
            let trimmed = stops.last == "" && stops.count > 2 ? Array(stops.dropLast()) : Array(stops)
            guard trimmed.count >= 2 else { return nil }
            var places = trimmed.map { Place(text: $0) }
            // Coordinates in the data are for named places only, in order
            let named = places.indices.filter { if case .address = places[$0] { true } else { false } }
            let coordinates = matches(of: #"!1d(-?\d+\.\d+)!2d(-?\d+\.\d+)"#, in: data).map { ($0[1], $0[0]) }
            if coordinates.count == named.count {
                for (index, coordinate) in zip(named, coordinates) {
                    places[index] = .coordinate(latitude: coordinate.0, longitude: coordinate.1, name: places[index].name)
                }
            }
            return MapsLink(app: .google, origin: places[0], destination: places[places.count - 1])
        }
        if let place = parts.firstIndex(of: "place"), place + 1 < parts.count {
            let name = decoded(parts[place + 1])
            if let coordinate = matches(of: #"!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)"#, in: data).first {
                return MapsLink(app: .google, origin: nil,
                                destination: .coordinate(latitude: coordinate[0], longitude: coordinate[1], name: name))
            }
            if let at = parts.first(where: { $0.hasPrefix("@") }),
               let coordinate = Place.coordinate(in: at.dropFirst().split(separator: ",").prefix(2).joined(separator: ",")) {
                return MapsLink(app: .google, origin: nil,
                                destination: .coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude, name: name))
            }
            return MapsLink(app: .google, origin: nil, destination: .address(name))
        }
        if let search = query["q"] ?? query["query"], case let place = Place(text: search), place != .currentLocation {
            return MapsLink(app: .google, origin: nil, destination: place)
        }
        return nil
    }

    /// A path part, with + for spaces.
    private static func decoded(_ part: String) -> String {
        (part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? part)
    }

    /// Each match's captured numbers.
    private static func matches(of pattern: String, in text: String) -> [[Double]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).flatMap { Double(text[$0]) } }
        }
    }
}
