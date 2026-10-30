import CoreLocation

/// A walk to or from a train, turn by turn: Apple Maps' walking directions to the entrance
/// picked for the train (`StationWays`), with the way down to it, or from the exit picked, with
/// the way up.
struct Walk: Codable, Hashable, Sendable {
    var steps: [Step]
    /// Apple Maps' time for it.
    var seconds: TimeInterval
    var meters: Double

    /// Its whole path.
    var points: [Point] {
        steps.flatMap(\.points)
    }

    struct Step: Codable, Hashable, Sendable {
        var turn: Turn
        /// What to do at the end of its path: "Take a left onto 4th Ave", "Down the stairs at the
        /// NW corner of 4 Av & 9 St".
        var instruction: String
        /// More for the way down or up: "Manhattan-bound only".
        var detail: String? = nil
        /// Of its path.
        var meters: Double
        /// Its path, to where its instruction's done; one point for a way down or up, where it is.
        var points: [Point]
    }

    enum Turn: String, Codable, Hashable, Sendable {
        case straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn
        case stairsDown, stairsUp, elevatorDown, elevatorUp, arrive

        /// This turn, as the path's angles have it, put right by `instruction`'s words where they
        /// say otherwise: "continue straight" where Broadway's angle made it a right, "Take a
        /// left" a left, keeping how sharp the angles make it. Whole words only, so Lefferts Blvd
        /// and Brighton Beach Av don't say which way.
        func said(in instruction: String) -> Turn {
            let words = Set(instruction.lowercased().split { !$0.isLetter }.map(String.init))
            let left = words.contains("left"), right = words.contains("right")
            if !left && !right && (words.contains("straight") || words.contains("continue")) { return .straight }
            switch self {
            case .slightRight where left && !right: return .slightLeft
            case .right where left && !right, .straight where left && !right: return .left
            case .sharpRight where left && !right: return .sharpLeft
            case .slightLeft where right && !left: return .slightRight
            case .left where right && !left, .straight where right && !left: return .right
            case .sharpLeft where right && !left: return .sharpRight
            default: return self
            }
        }

        var systemImage: String {
            switch self {
            case .straight: "arrow.up"
            case .slightLeft: "arrow.up.left"
            case .left: "arrow.turn.up.left"
            case .sharpLeft: "arrow.down.left"
            case .slightRight: "arrow.up.right"
            case .right: "arrow.turn.up.right"
            case .sharpRight: "arrow.down.right"
            case .uTurn: "arrow.uturn.down"
            case .stairsDown, .stairsUp: "stairs"
            case .elevatorDown, .elevatorUp: "arrow.up.arrow.down.square"
            case .arrive: "mappin.and.ellipse"
            }
        }

        /// The turn from heading `before` to `after`, in degrees clockwise from north: within 20
        /// degrees is straight on, to 45 slight, to 135 a turn, to 170 sharp, past that back.
        init(from before: Double, to after: Double) {
            // -180 to 180, right positive
            let change = (after - before + 540).truncatingRemainder(dividingBy: 360) - 180
            let size = abs(change)
            let right = change > 0
            switch size {
            case ..<20: self = .straight
            case ..<45: self = right ? .slightRight : .slightLeft
            case ..<135: self = right ? .right : .left
            case ..<170: self = right ? .sharpRight : .sharpLeft
            default: self = .uTurn
            }
        }
    }

    struct Point: Codable, Hashable, Sendable {
        let lat: Double
        let lon: Double

        init(lat: Double, lon: Double) {
            self.lat = lat
            self.lon = lon
        }

        init(_ coordinate: CLLocationCoordinate2D) {
            self.init(lat: coordinate.latitude, lon: coordinate.longitude)
        }

        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

        /// Metres east and north of `origin`, near enough over a walk.
        func offset(from origin: Point) -> (east: Double, north: Double) {
            ((lon - origin.lon) * 111_320 * cos(origin.lat * .pi / 180), (lat - origin.lat) * 111_320)
        }

        func metres(to other: Point) -> Double {
            let (east, north) = other.offset(from: self)
            return (east * east + north * north).squareRoot()
        }

        /// How far it is from the line from `start` to `end`, and how far along that line its
        /// nearest point is, from 0 at `start` to 1 at `end`.
        func nearest(from start: Point, to end: Point) -> (gap: Double, along: Double) {
            let (dx, dy) = end.offset(from: start)
            let (px, py) = offset(from: start)
            let length = dx * dx + dy * dy
            let along = length > 0 ? min(1, max(0, (px * dx + py * dy) / length)) : 0
            let (ex, ey) = (px - along * dx, py - along * dy)
            return ((ex * ex + ey * ey).squareRoot(), along)
        }

        /// Degrees clockwise from north to `other`, near enough over a block.
        func heading(to other: Point) -> Double {
            let east = (other.lon - lon) * cos(lat * .pi / 180)
            let north = other.lat - lat
            return (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }
    }

    /// How far along it someone is: the step whose path they're on, whose instruction is next,
    /// and how far that is.
    struct Progress: Hashable, Sendable {
        /// The step whose path they're on.
        let step: Int
        /// Metres to the end of that step's path, where its instruction's done.
        let toTurn: Double
        /// Metres left to the end of the walk.
        let left: Double
        /// Metres they are from the path.
        let offPath: Double
    }

    /// Where `place` is along the walk, by the nearest point on its path at or after step
    /// `after` (a step back, for GPS that jumps), so a path that doubles back doesn't put
    /// someone back where they've been. Nil for a walk with no path.
    func progress(at place: Point, after: Int = 0) -> Progress? {
        // Each piece of the path with the step it's part of: from each point to the next, and
        // from a step's last point to the next step's first
        var pieces: [(step: Int, from: Point, to: Point)] = []
        var last: (step: Int, point: Point)?
        for (index, step) in steps.enumerated() {
            for point in step.points {
                if let last, last.point != point { pieces.append((last.step, last.point, point)) }
                last = (index, point)
            }
        }
        guard !pieces.isEmpty else { return nil }
        let lengths = pieces.map { $0.from.metres(to: $0.to) }
        let first = max(0, after - 1)
        var best: (index: Int, gap: Double, along: Double)?
        for (index, piece) in pieces.enumerated() where piece.step >= first {
            let (gap, along) = place.nearest(from: piece.from, to: piece.to)
            if best.map({ gap < $0.gap }) ?? true { best = (index, gap, along * lengths[index]) }
        }
        guard let best else { return nil }
        let step = pieces[best.index].step
        let rest = lengths[best.index] - best.along
        let after = pieces.indices.filter { $0 > best.index }
        let toTurn = rest + after.filter { pieces[$0].step == step }.map { lengths[$0] }.reduce(0, +)
        let left = rest + after.map { lengths[$0] }.reduce(0, +)
        return Progress(step: step, toTurn: toTurn, left: left, offPath: best.gap)
    }

    /// The last `metres` of its path, from the point that far from its end: what's left to walk.
    /// The whole path if it's no longer than that.
    func path(last metres: Double) -> [Point] {
        var points = self.points.reduce(into: [Point]()) { kept, point in
            if kept.last != point { kept.append(point) }
        }
        var left = metres
        var index = points.count - 1
        while index > 0 {
            let piece = points[index - 1].metres(to: points[index])
            if piece >= left {
                // Part way along this piece
                let from = points[index], to = points[index - 1]
                let along = piece > 0 ? left / piece : 0
                let start = Point(lat: from.lat + (to.lat - from.lat) * along, lon: from.lon + (to.lon - from.lon) * along)
                points = [start] + points[index...]
                return points
            }
            left -= piece
            index -= 1
        }
        return points
    }

    /// "250 ft", "0.3 mi", or "200 m" where the region's metric: feet to the nearest 50 under
    /// 1,000 (10 under 100), then tenths of a mile.
    static func distance(_ metres: Double, metric: Bool = Locale.current.measurementSystem == .metric) -> String {
        if metric {
            return metres < 1_000 ? "\(Int((metres / 10).rounded()) * 10) m" : String(format: "%.1f km", metres / 1_000)
        }
        let feet = metres * 3.28084
        if feet < 100 { return "\(max(10, Int((feet / 10).rounded()) * 10)) ft" }
        if feet < 1_000 { return "\(Int((feet / 50).rounded()) * 50) ft" }
        return String(format: "%.1f mi", metres / 1_609.344)
    }

    /// The turn onto a step whose path is `next`, from one whose path was `previous`: by the
    /// headings of the last bit of one and the first of the other at least 5 m long, as a path's
    /// ends can be a point or two right on top of each other. Straight on if either's too short.
    static func turn(from previous: [Point], onto next: [Point]) -> Turn {
        func heading(_ points: some Sequence<Point>) -> Double? {
            var iterator = points.makeIterator()
            guard let first = iterator.next() else { return nil }
            while let point = iterator.next() {
                let start = CLLocation(latitude: first.lat, longitude: first.lon)
                if start.distance(from: CLLocation(latitude: point.lat, longitude: point.lon)) >= 5 {
                    return first.heading(to: point)
                }
            }
            return nil
        }
        // Into the turn: the previous path backwards, so its heading turned round
        guard let back = heading(previous.reversed()), let ahead = heading(next) else { return .straight }
        return Turn(from: (back + 180).truncatingRemainder(dividingBy: 360), to: ahead)
    }
}

/// Which entrance to walk to for a train, and which exit to leave one by: the nearest that can be
/// used that way, to the train's side where a platform's sides aren't joined inside.
enum StationWays {
    /// An entrance or exit for a train of `route` going `direction` (its feed N or S) at `platform`.
    struct Way: Codable, Hashable, Sendable {
        let platform: Platform
        let entrance: Station.Entrance
        let route: String
        let direction: Direction

        /// Which third of the train stops by it (`Platform.part(of:going:by:)`).
        var part: Platform.TrainPart? { platform.part(of: route, going: direction, by: entrance) }

        /// Whether it's just for its train's side, the other side's being elsewhere.
        var isOneSide: Bool { platform.noCrossover == true && entrance.side != nil }

        /// The step down to the train: "Down the stairs at the NW corner of 4 Av & 9 St", or the
        /// elevator; "Manhattan-bound only" where it's just for that side.
        var down: Walk.Step {
            let elevator = entrance.isElevator
            let how = elevator ? "Take the elevator down" : entrance.type.contains("Escalator") ? "Down the escalator"
                : entrance.type.contains("Stair") ? "Down the stairs" : "Into the station"
            return Walk.Step(turn: elevator ? .elevatorDown : .stairsDown,
                             instruction: entrance.address.map { "\(how) at the \($0)" } ?? how,
                             detail: isOneSide ? "\(sideName) only" : nil, meters: 0,
                             points: [Walk.Point(lat: entrance.lat, lon: entrance.lon)])
        }

        /// The step up from the train: "Up the stairs to the NE corner of Broadway & 42 St".
        var up: Walk.Step {
            let elevator = entrance.isElevator
            let how = elevator ? "Take the elevator up" : entrance.type.contains("Escalator") ? "Up the escalator"
                : entrance.type.contains("Stair") ? "Up the stairs" : "Out of the station"
            return Walk.Step(turn: elevator ? .elevatorUp : .stairsUp,
                             instruction: entrance.address.map { "\(how) to the \($0)" } ?? "\(how) to the street",
                             meters: 0, points: [Walk.Point(lat: entrance.lat, lon: entrance.lon)])
        }

        /// "Manhattan-bound", or "Northbound" where the MTA gives no name.
        var sideName: String {
            let name = platform.directionName(direction, of: route)
            return name.isEmpty ? direction.compassName : "\(name)-bound"
        }

        var location: CLLocation { CLLocation(latitude: entrance.lat, longitude: entrance.lon) }
    }

    /// Where to go in for `selection`'s train, from `start`.
    static func boarding(_ selection: Selection, from start: CLLocation) -> Way? {
        let ways = selection.platforms.flatMap { platform in
            selection.routes.filter(platform.routes.contains).prefix(1).map { route in
                (platform, route, selection.direction(of: route, at: platform))
            }
        }
        return nearest(ways, to: start, entering: true)
    }

    /// Where to come out at `destination` after `selection`'s train, or the train of `change` from
    /// it, toward `end`.
    static func leaving(_ selection: Selection, change: Change?, at destination: Station, toward end: CLLocation) -> Way? {
        let routes = change?.routes ?? selection.routes
        let way = change?.departureDirection(for: selection) ?? selection.direction
        let ways = destination.platforms(serving: routes).flatMap { platform in
            routes.filter(platform.routes.contains).prefix(1).map { route in
                (platform, route, platform.direction(way, of: route, with: routes))
            }
        }
        return nearest(ways, to: end, entering: false)
    }

    /// The nearest of `ways`' platforms' entrances to `place` that can be gone in by (or left by,
    /// if not `entering`) and is on the train's side, where that's known; else the nearest of
    /// those whose side isn't. A platform whose sides are joined also has its station's other
    /// platforms' entrances, through the station, but not where they are along it: Times Sq-42
    /// St's R has only its 40 St stairs, its 42 St ones being the 1 2 3's.
    static func nearest(_ ways: [(Platform, String, Direction)], to place: CLLocation, entering: Bool) -> Way? {
        let all = ways.flatMap { platform, route, direction in
            let own = Set(platform.entrances.map(\.place))
            let station: [Station.Entrance] = platform.noCrossover == true ? []
                : StationDirectory.station(id: platform.id)?.entrances ?? []
            let others = station.filter { !own.contains($0.place) }.map { other in
                var entrance = other
                entrance.along = nil
                entrance.side = nil
                return entrance
            }
            return (platform.entrances + others)
                .filter { entering ? $0.exitOnly != true : $0.entryOnly != true }
                .map { Way(platform: platform, entrance: $0, route: route, direction: direction) }
        }
        let sided = all.filter { way in
            way.platform.noCrossover != true || way.entrance.side == way.platform.side(of: way.route, going: way.direction)
        }
        let usable = sided.isEmpty ? all.filter { $0.entrance.side == nil } : sided
        return usable.min { cost($0, to: place, entering: entering) < cost($1, to: place, entering: entering) }
    }

    /// Metres an entrance that can't be named by its streets, or an exit that can't be placed
    /// along the train, counts as further: one a little further that can wins, as saying where
    /// it is and where to ride is worth half a block.
    static let unknownCost: Double = 40

    /// How far `way` is from `place`, and `unknownCost` for each of those it can't say.
    private static func cost(_ way: Way, to place: CLLocation, entering: Bool) -> Double {
        var cost = way.location.distance(from: place)
        if way.entrance.address == nil { cost += unknownCost }
        if !entering, way.part == nil { cost += unknownCost }
        return cost
    }
}
