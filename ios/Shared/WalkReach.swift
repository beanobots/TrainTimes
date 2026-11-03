import CoreLocation

/// How far you'd walk between two places, knowing the water: as the crow flies on the same
/// land, else by way of the bridges you can walk over (across the Williamsburg Bridge from
/// Greenpoint to Stuy Town), or no walk at all (off Rikers Island, or Hoboken to Midtown other
/// than over the George Washington Bridge). Cheap enough for every station and dock a plan
/// looks at, and offline, in widgets too: the city's shores (`shoreData`, from
/// tools/make_shores.py), and New Jersey, Westchester and the bridges by hand.
///
/// Water within a land isn't known: Flushing Bay, Newtown Creek and the Bronx's creeks are
/// walked straight over, as they've bridges near enough.
enum WalkReach {
    enum Land: Sendable {
        /// Brooklyn and Queens, and Nassau beyond: wherever no other land is.
        case longIsland
        /// The Bronx, Marble Hill and Westchester.
        case bronx
        case manhattan, statenIsland, newJersey, roosevelt, randalls, governors, rikers, northBrother,
             cityIsland, hart, broadChannel, rockaway, liberty, ellis
    }

    /// Where a walk starts, with the walks from it to each bridge worked out once for the many
    /// places it's measured to.
    struct From {
        let location: CLLocation
        let land: Land
        /// Meters to each of `ends`, to its far side, and on, by the bridges.
        private let toEnds: [Double]

        init(_ location: CLLocation) {
            self.location = location
            land = WalkReach.land(at: location.coordinate)
            let land = land
            let near = ends.map { $0.land == land ? location.distance(from: $0.location) : .infinity }
            toEnds = ends.indices.map { end in
                ends.indices.reduce(.infinity) { best, start in min(best, near[start] + between[start][end]) }
            }
        }

        /// Meters to walk to `place`: as the crow flies if it's on the same land, else by the
        /// bridges; nil if there's no walk there. `land` is `place`'s, where already known.
        func meters(to place: CLLocation, on land: Land? = nil) -> Double? {
            let land = land ?? WalkReach.land(at: place.coordinate)
            if land == self.land { return location.distance(from: place) }
            let meters = ends.indices.reduce(Double.infinity) { best, end in
                ends[end].land == land ? min(best, toEnds[end] + ends[end].location.distance(from: place)) : best
            }
            return meters.isFinite ? meters : nil
        }

        /// To `station`, as `meters(to:)`.
        func meters(to station: Station) -> Double? {
            meters(to: station.location, on: stationLands[station.id])
        }
    }

    /// Meters to walk from `start` to `end`, as `From.meters(to:)`; nil if there's no walk.
    static func meters(from start: CLLocation, to end: CLLocation) -> Double? {
        From(start).meters(to: end)
    }

    /// The land `coordinate` is on. In the water, the shore within `shoreReach`, else the
    /// side of the river it's on, as a pier is the land it's off.
    static func land(at coordinate: CLLocationCoordinate2D) -> Land {
        let lat = coordinate.latitude, lon = coordinate.longitude
        if let shore = shores.first(where: { $0.contains(lat, lon) }) { return shore.land }
        let near = shores.map { ($0.land, $0.meters(to: lat, lon, within: shoreReach)) }
            .min { $0.1 < $1.1 }
        if let near, near.1 <= shoreReach { return near.0 }
        if contains(newJersey, lat, lon) { return .newJersey }
        if contains(north, lat, lon) { return .bronx }
        return .longIsland
    }

    // MARK: Shores

    /// Meters off a shore that are still its land: a pier, or a corner the shore's cut.
    private static let shoreReach: Double = 60

    private struct Shore {
        let land: Land
        let lats: [Double]
        let lons: [Double]
        /// Its bounds, south, north, west and east.
        let box: (Double, Double, Double, Double)

        init(land: Land, data: String) {
            self.land = land
            var lats: [Double] = [], lons: [Double] = []
            var lat = 0, lon = 0
            for (index, change) in data.split(separator: ",").compactMap({ Int($0) }).enumerated() {
                if index.isMultiple(of: 2) {
                    lat += change
                    lats.append(Double(lat) / 1e5)
                } else {
                    lon += change
                    lons.append(Double(lon) / 1e5)
                }
            }
            self.lats = lats
            self.lons = lons
            box = (lats.min() ?? 0, lats.max() ?? 0, lons.min() ?? 0, lons.max() ?? 0)
        }

        func contains(_ lat: Double, _ lon: Double) -> Bool {
            lat >= box.0 && lat <= box.1 && lon >= box.2 && lon <= box.3
                && WalkReach.contains(lats, lons, lat, lon)
        }

        /// Meters from the nearest of its shore, if within about `within`; else infinity.
        func meters(to lat: Double, _ lon: Double, within: Double) -> Double {
            let margin = within / 80_000
            guard lat >= box.0 - margin, lat <= box.1 + margin, lon >= box.2 - margin, lon <= box.3 + margin
            else { return .infinity }
            // On a flat plane, in meters from (lat, lon): near enough at this size
            let east = 111_320 * cos(lat * .pi / 180), north = 111_320.0
            var nearest = Double.infinity
            var last = lats.count - 1
            for index in lats.indices {
                let ax = (lons[last] - lon) * east, ay = (lats[last] - lat) * north
                let bx = (lons[index] - lon) * east, by = (lats[index] - lat) * north
                let dx = bx - ax, dy = by - ay
                let length = dx * dx + dy * dy
                let along = length > 0 ? min(max(-(ax * dx + ay * dy) / length, 0), 1) : 0
                nearest = min(nearest, hypot(ax + along * dx, ay + along * dy))
                last = index
            }
            return nearest
        }
    }

    private static let shores = shoreData.map { Shore(land: $0.0, data: $0.1) }

    /// Whether (`lat`, `lon`) is inside the ring of `lats` and `lons`.
    private static func contains(_ lats: [Double], _ lons: [Double], _ lat: Double, _ lon: Double) -> Bool {
        var inside = false
        var last = lats.count - 1
        for index in lats.indices {
            if (lats[index] > lat) != (lats[last] > lat),
               lon < (lons[last] - lons[index]) * (lat - lats[index]) / (lats[last] - lats[index]) + lons[index] {
                inside.toggle()
            }
            last = index
        }
        return inside
    }

    private static func contains(_ ring: [(Double, Double)], _ lat: Double, _ lon: Double) -> Bool {
        contains(ring.map(\.0), ring.map(\.1), lat, lon)
    }

    /// New Jersey, as far as the middle of the Hudson, the Upper Bay and the Narrows; and Staten
    /// Island's water, as Staten Island's own shore is found first.
    private static let newJersey: [(Double, Double)] = [
        (41.05, -73.905), (40.95, -73.915), (40.90, -73.925), (40.87, -73.937), (40.85, -73.955),
        (40.82, -73.969), (40.80, -73.980), (40.77, -74.001), (40.75, -74.016), (40.73, -74.019),
        (40.71, -74.024), (40.70, -74.027), (40.69, -74.030), (40.675, -74.035), (40.66, -74.035),
        (40.645, -74.045), (40.625, -74.050), (40.605, -74.045), (40.58, -74.040), (40.55, -74.030),
        (40.40, -74.030), (40.40, -74.400), (41.05, -74.400),
    ]

    /// Westchester, and the Sound off it, beyond the Bronx's shore.
    private static let north: [(Double, Double)] = [
        (41.30, -73.905), (40.915, -73.912), (40.88, -73.790), (40.89, -73.700), (41.00, -73.600), (41.30, -73.600),
    ]

    // MARK: Bridges

    /// The ways over the water on foot, each end a little inland. Not the Verrazzano,
    /// Whitestone, Throgs Neck or Henry Hudson, nor to Rikers, North Brother, Hart or Governors
    /// Island, Liberty or Ellis: no one walks those.
    private static let crossings: [(Land, Double, Double, Land, Double, Double)] = [
        (.manhattan, 40.7127, -74.0043, .longIsland, 40.6990, -73.9900),  // Brooklyn Bridge
        (.manhattan, 40.7163, -73.9953, .longIsland, 40.6995, -73.9866),  // Manhattan Bridge
        (.manhattan, 40.7176, -73.9864, .longIsland, 40.7106, -73.9617),  // Williamsburg Bridge
        (.manhattan, 40.7608, -73.9605, .longIsland, 40.7515, -73.9397),  // Queensboro Bridge
        (.manhattan, 40.7863, -73.9397, .randalls, 40.7853, -73.9357),  // Wards Island Bridge, at 103 St
        (.manhattan, 40.8023, -73.9338, .randalls, 40.7980, -73.9255),  // RFK Bridge
        (.randalls, 40.7965, -73.9200, .bronx, 40.8040, -73.9180),  // RFK Bridge
        (.randalls, 40.7975, -73.9175, .bronx, 40.8015, -73.9140),  // Randall's Island Connector
        (.randalls, 40.7830, -73.9270, .longIsland, 40.7765, -73.9200),  // RFK Bridge, to Astoria
        (.manhattan, 40.8720, -73.9115, .bronx, 40.8758, -73.9100),  // Broadway Bridge
        (.manhattan, 40.8640, -73.9145, .bronx, 40.8625, -73.9105),  // University Heights Bridge
        (.manhattan, 40.8475, -73.9290, .bronx, 40.8458, -73.9210),  // Washington Bridge
        (.manhattan, 40.8430, -73.9330, .bronx, 40.8415, -73.9265),  // High Bridge
        (.manhattan, 40.8285, -73.9365, .bronx, 40.8295, -73.9305),  // Macombs Dam Bridge
        (.manhattan, 40.8200, -73.9355, .bronx, 40.8185, -73.9300),  // 145 St Bridge
        (.manhattan, 40.8145, -73.9350, .bronx, 40.8135, -73.9300),  // Madison Av Bridge
        (.manhattan, 40.8055, -73.9340, .bronx, 40.8095, -73.9290),  // Third Av Bridge
        (.manhattan, 40.8030, -73.9320, .bronx, 40.8075, -73.9255),  // Willis Av Bridge
        (.manhattan, 40.8500, -73.9440, .newJersey, 40.8531, -73.9633),  // George Washington Bridge
        (.roosevelt, 40.7640, -73.9475, .longIsland, 40.7623, -73.9405),  // Roosevelt Island Bridge
        (.bronx, 40.8580, -73.7975, .cityIsland, 40.8550, -73.7900),  // City Island Bridge
        (.longIsland, 40.6420, -73.8350, .broadChannel, 40.6340, -73.8260),  // North Channel Bridge
        (.broadChannel, 40.5975, -73.8195, .rockaway, 40.5865, -73.8155),  // Cross Bay Bridge
        (.longIsland, 40.5815, -73.8865, .rockaway, 40.5690, -73.8835),  // Marine Parkway Bridge
        (.rockaway, 40.5990, -73.7400, .longIsland, 40.6340, -73.7420),  // Far Rockaway, by land through Nassau
        (.statenIsland, 40.6385, -74.1420, .newJersey, 40.6500, -74.1425),  // Bayonne Bridge
        (.statenIsland, 40.6310, -74.1880, .newJersey, 40.6375, -74.2040),  // Goethals Bridge
    ]

    /// Both ends of every crossing.
    private static let ends: [(land: Land, location: CLLocation)] = crossings.flatMap { crossing in
        [(crossing.0, CLLocation(latitude: crossing.1, longitude: crossing.2)),
         (crossing.3, CLLocation(latitude: crossing.4, longitude: crossing.5))]
    }

    /// Meters from each of `ends` to each other, over as many bridges as it takes; infinity
    /// where there's no way.
    private static let between: [[Double]] = {
        var meters = ends.map { from in
            ends.map { to in from.land == to.land ? from.location.distance(from: to.location) : .infinity }
        }
        // Each crossing's two ends are side by side in `ends`
        for start in stride(from: 0, to: ends.count, by: 2) {
            let over = ends[start].location.distance(from: ends[start + 1].location)
            meters[start][start + 1] = over
            meters[start + 1][start] = over
        }
        for via in ends.indices {
            for from in ends.indices where meters[from][via].isFinite {
                for to in ends.indices {
                    meters[from][to] = min(meters[from][to], meters[from][via] + meters[via][to])
                }
            }
        }
        return meters
    }()

    /// Each station's land, worked out once.
    private static let stationLands: [String: Land] = Dictionary(
        StationDirectory.all.map { ($0.id, land(at: $0.coordinate)) }, uniquingKeysWith: { first, _ in first })
}
