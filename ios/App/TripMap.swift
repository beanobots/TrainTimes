import MapKit
import SwiftUI

/// New Trip's trips on a map: the picked one in its lines' colours with its stations and each
/// line's bullet, any other trips faint and grey, a gap where it changes, and both ends. Rides
/// follow the MTA's track (`TrackShapes`), or go station to station where it can't be followed;
/// a bus goes straight from where it's boarded to where it's left.
struct TripMap: View {
    let options: [ServerRoutes.Choice]
    let picked: Int
    let start: CLLocationCoordinate2D?
    let end: CLLocationCoordinate2D?
    let endName: String

    @State private var position = MapCameraPosition.automatic
    /// Keeps the map to `area`, once it's framed there.
    @State private var bounds: MapCameraBounds?
    /// The map's height, for how many meters a point is when framed on `area`.
    @State private var height: CGFloat = 230
    /// The room over the map's top, under what's over it, which framing keeps the trips clear of.
    @State private var topInset: CGFloat = 0
    /// Map points the map shows top to bottom, once it's settled, to keep lines side by side the
    /// same points apart however far it's zoomed.
    @State private var shownHeight: Double?

    /// Each trip's rides and what the map covers, worked out once for each set of trips and ends
    /// rather than on every redraw, as following a ride's track (`TrackShapes`) takes a while.
    @State private var cache = Cache()

    /// The trips as drawn.
    private struct Drawn {
        var rides: [[SharedTrip.Option.Ride]]
        var otherChanges: [[SharedTrip.Option.OtherChange]]
        /// For each trip's other change stations' rides, one after another, where each's drawn
        /// (`Beside`).
        var beside: [[Beside]]
        /// Each ride's bullets' place, clear of its stations, the other change stations and both
        /// ends (`Ride.bulletAt(avoiding:)`).
        var bullets: [[Bullet?]]
        /// For each trip's rides, for each of its lines (`Ride.tracks`), points to the right of
        /// each of its points to draw it, beside the others where they run together.
        var laneOffsets: [[[[Double]]]]
        var area: MKMapRect
        /// Counts up with each new `Drawn`, to tell the map's lines from the last ones'.
        var version: Int
    }

    /// Holds the last `Drawn` and what it was for. Not observed: filling it in doesn't redraw.
    private final class Cache {
        private struct Key: Equatable {
            var options: [ServerRoutes.Choice]
            var start: [Double]?
            var end: [Double]?
        }

        private var key: Key?
        private var drawn: Drawn?
        private var version = 0

        func drawn(options: [ServerRoutes.Choice], start: CLLocationCoordinate2D?, end: CLLocationCoordinate2D?) -> Drawn {
            let key = Key(options: options, start: start.map { [$0.latitude, $0.longitude] },
                          end: end.map { [$0.latitude, $0.longitude] })
            if let drawn, key == self.key { return drawn }
            let rides = options.map(\.rides)
            // Points close enough together to move off the lines they run along smoothly
            let otherChanges = options.map(\.otherChanges).map { changes in
                changes.map { change in
                    var change = change
                    change.rides = change.rides.map { ride in
                        var ride = ride
                        ride.coordinates = TripMap.densified(ride.coordinates)
                        return ride
                    }
                    return change
                }
            }
            let beside = zip(rides, otherChanges).map { rides, changes in
                TripMap.beside(changes.map(\.rides), of: rides)
            }
            let ends = [start, end].compactMap { $0 }
            let bullets = zip(rides, otherChanges).map { rides, changes in
                rides.map { $0.bulletAt(avoiding: changes.map(\.coordinate) + ends) }
            }
            let laneOffsets = rides.map { rides in
                rides.map { TripMap.laneOffsets($0.tracks, width: Double(TripMap.sideBySideWidth)) }
            }
            version += 1
            let drawn = Drawn(rides: rides, otherChanges: otherChanges, beside: beside, bullets: bullets, laneOffsets: laneOffsets,
                              area: TripMap.area(rides: rides, otherChanges: otherChanges, start: start, end: end),
                              version: version)
            self.key = key
            self.drawn = drawn
            return drawn
        }
    }

    private var drawn: Drawn { cache.drawn(options: options, start: start, end: end) }

    /// What the trips are framed for: new trips, or the room over them changing.
    private struct Framing: Equatable {
        var options: [ServerRoutes.Choice]
        var topInset: CGFloat
    }

    /// Under the picked trip's lines, to lift them off the map's roads.
    private static let casing = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.6) : .white
    })

    /// The other trips: faint grey, a little stronger in dark mode, where grey sinks into the map.
    private static let alternative = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.35) : UIColor.gray.withAlphaComponent(0.35)
    })

    /// The walks: dots bold enough to see on the map, in a dark grey (light in dark mode).
    private static let walk = StrokeStyle(lineWidth: 5, lineCap: .round, dash: [0.5, 9])
    private static let walkColor = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .lightGray : .darkGray
    })

    /// Points between rides where it changes, so lines of one colour (the R to the Q) read as two.
    private static let gapPoints: Double = 9

    /// The picked trip's line, and each line's where it's one of two or more side by side.
    private static let lineWidth: CGFloat = 7
    private static let sideBySideWidth: CGFloat = 5
    /// The other change stations' rides' casing, and so how far apart they're drawn side by side.
    private static let dashedCasing: CGFloat = 5

    /// Meters from the trip's own lines another ride may be that's taken to run along them, as
    /// on tracks side by side.
    private static let alongside: Double = 80
    /// Points another ride moves out by each meter, coming off or going back to where it runs
    /// along another: a full move out over a few hundred meters.
    private static let besideSlope: Double = 0.03

    var body: some View {
        let drawn = drawn
        let rides = drawn.rides
        let pickedRides = rides.indices.contains(picked) ? rides[picked] : []
        let others = drawn.otherChanges.indices.contains(picked) ? drawn.otherChanges[picked] : []
        let otherRides = others.flatMap(\.rides)
        let gap = Self.gapPoints * Self.metersPerPoint(in: drawn.area, height: height)
        let mapPointsPerPoint = height > 0 ? (shownHeight ?? drawn.area.height) / Double(height) : 0
        let beside = drawn.beside.indices.contains(picked) ? drawn.beside[picked] : []
        let bullets = drawn.bullets.indices.contains(picked) ? drawn.bullets[picked] : []
        let laneOffsets = drawn.laneOffsets.indices.contains(picked) ? drawn.laneOffsets[picked] : []
        // New lines for new trips or another picked, rather than MapKit keeping the last ones'
        // colours for lines in the same place in the list
        let tag = "\(drawn.version)-\(picked)"
        // Each drawn in pieces, without where it'd only be drawn over a line already there, and
        // each moved out beside the lines it runs along
        let otherPieces = otherRides.indices.flatMap { index in
            let line = otherRides[index].coordinates
            guard beside.indices.contains(index), beside[index].out.count == line.count else {
                return [(ride: index, line: line)]
            }
            return Self.pieces(of: line.count, without: beside[index].hidden).map { run in
                (ride: index, line: Self.offset(Array(line[run]), by: beside[index].out[run].map { $0 * mapPointsPerPoint }))
            }
        }
        // Where each other change station's rides meet: the end of its first, which comes back
        // in to there
        let otherStops = others.map { $0.rides.first?.coordinates.last ?? $0.coordinate }
        // Each of its rides' lines, in one list rather than a list in each ride's, which MapKit
        // was slow to draw the first time: where any of two or more lines will do, each along
        // its own track, beside the others where they run together, as on the subway map; each
        // short of the change at either end of its ride
        let pickedLines = pickedRides.indices.flatMap { index in
            let ride = pickedRides[index], tracks = ride.tracks
            let offsets = laneOffsets.indices.contains(index) ? laneOffsets[index] : []
            return tracks.indices.map { lane in
                let track = offsets.indices.contains(lane)
                    ? Self.offset(tracks[lane], by: offsets[lane].map { $0 * mapPointsPerPoint }) : tracks[lane]
                return Line(id: "line-\(tag)-\(index)-\(lane)",
                            coordinates: Self.trimmed(track, start: index > 0 ? gap : 0,
                                                      end: index < pickedRides.count - 1 ? gap : 0),
                            color: ride.color(of: ride.routes.indices.contains(lane) ? ride.routes[lane] : ride.route),
                            width: tracks.count > 1 ? Self.sideBySideWidth : Self.lineWidth)
            }
        }
        Map(position: $position, bounds: bounds, interactionModes: [.pan, .zoom]) {
            ForEach(Self.keyed(rides.indices.filter { $0 != picked }, tag: "other-trip-\(tag)"), id: \.id) { keyed in
                let index = keyed.index
                ForEach(Self.keyed(rides[index].indices, tag: "other-trip-ride-\(tag)-\(index)"), id: \.id) { keyed in
                    let ride = keyed.index
                    MapPolyline(coordinates: rides[index][ride].coordinates)
                        .stroke(Self.alternative, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .mapOverlayLevel(level: .aboveRoads)
                }
            }
            // The walks to its first station, between platforms where it changes, and from its last
            if let start, let first = pickedRides.first?.coordinates.first {
                MapPolyline(coordinates: [start, first])
                    .stroke(Self.walkColor, style: Self.walk)
            }
            ForEach(Self.keyed(pickedRides.indices.dropFirst(), tag: "walk-\(tag)"), id: \.id) { keyed in
                let index = keyed.index
                if let off = pickedRides[index - 1].coordinates.last, let on = pickedRides[index].coordinates.first {
                    MapPolyline(coordinates: [off, on])
                        .stroke(Self.walkColor, style: Self.walk)
                }
            }
            if let end, let last = pickedRides.last?.coordinates.last {
                MapPolyline(coordinates: [last, end])
                    .stroke(Self.walkColor, style: Self.walk)
            }
            // Its other change stations' rides: thinner and dashed, as they're only taken when they
            // get you on sooner, and beside its own lines where they run along them
            ForEach(Self.keyed(otherPieces.indices, tag: "dashed-\(tag)"), id: \.id) { keyed in
                let index = keyed.index
                let piece = otherPieces[index]
                MapPolyline(coordinates: piece.line)
                    .stroke(Self.casing, style: StrokeStyle(lineWidth: Self.dashedCasing, lineCap: .round, lineJoin: .round))
                    // Under every line's colour: MapKit keeps no order to lines in one level once
                    // some come and go, and drew casings over colours
                    .mapOverlayLevel(level: .aboveRoads)
                MapPolyline(coordinates: piece.line)
                    .stroke(otherRides[piece.ride].color.opacity(0.8),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [6, 4]))
            }
            // Casings under all its lines, a level down, so none's drawn over another's colour
            ForEach(pickedLines, id: \.casingID) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(Self.casing, style: StrokeStyle(lineWidth: line.width + 4, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
            }
            ForEach(pickedLines) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(line.color, style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round))
            }
            // Its stations: small dots on the line, larger where it changes
            ForEach(Self.keyed(pickedRides.indices, tag: "station-ride-\(tag)"), id: \.id) { keyed in
                let index = keyed.index
                let stops = pickedRides[index].stops
                ForEach(Self.keyed(stops.indices, tag: "station-\(tag)-\(index)"), id: \.id) { keyed in
                    let stop = keyed.index
                    let changes = (stop == 0 && index > 0) || (stop == stops.count - 1 && index < pickedRides.count - 1)
                    Annotation("", coordinate: stops[stop]) {
                        if changes {
                            Circle().fill(.white).frame(width: 8, height: 8)
                                .overlay(Circle().stroke(.black.opacity(0.8), lineWidth: 2))
                        } else {
                            Circle().fill(.white).frame(width: 4, height: 4)
                        }
                    }
                }
            }
            // The other change stations, each named beside its dot ("or DeKalb Av")
            ForEach(Self.keyed(others.indices, tag: "other-stop-\(tag)"), id: \.id) { keyed in
                let index = keyed.index
                Annotation("", coordinate: otherStops[index]) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.black.opacity(0.8), lineWidth: 2))
                        .overlay(alignment: .leading) {
                            if let name = others[index].name {
                                Text("or \(name)")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.regularMaterial, in: Capsule())
                                    .fixedSize()
                                    .offset(x: 14)
                            }
                        }
                }
            }
            // Each ride's bullets between two of its stations, side by side where it's more than
            // one line
            ForEach(Self.keyed(pickedRides.indices, tag: "bullet-\(tag)"), id: \.id) { keyed in
                let index = keyed.index
                let ride = pickedRides[index]
                if let bullet = bullets.indices.contains(index) ? bullets[index] : nil {
                    Annotation("", coordinate: Self.place(of: bullet, mapPointsPerPoint: mapPointsPerPoint)) {
                        if ride.isBus {
                            BusBadge(line: ride.route, size: 20)
                                .overlay(RoundedRectangle(cornerRadius: 5.6, style: .continuous).stroke(.white, lineWidth: 2))
                                .shadow(radius: 1)
                        } else {
                            HStack(spacing: 2) {
                                ForEach(ride.routes, id: \.self) { route in
                                    LineBullet(route: route, size: 20)
                                        .overlay(Circle().stroke(.white, lineWidth: 2))
                                        .shadow(radius: 1)
                                }
                            }
                        }
                    }
                }
            }
            if let start {
                Annotation("", coordinate: start) {
                    Circle().fill(.blue).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(radius: 2)
                }
            }
            if let end {
                Marker(endName, systemImage: "mappin", coordinate: end)
                    .tint(.red)
                    .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        // The list says the same
        .accessibilityHidden(true)
        // New trips, or something opened or closed over them: frame them, wherever the map
        // was moved
        .task(id: Framing(options: options, topInset: topInset)) {
            bounds = nil
            withAnimation(.smooth) { position = .rect(drawn.area) }
        }
        // Once framed, it can be moved and zoomed in, but not out or away from the trips, so it
        // only ever loads the trips' area
        .onMapCameraChange(frequency: .onEnd) { context in
            shownHeight = context.rect.height
            let area = drawn.area
            guard bounds == nil,
                  context.rect.insetBy(dx: -area.width * 0.05, dy: -area.height * 0.05).contains(area) else { return }
            // A little further out than it's framed, to see past an end
            bounds = MapCameraBounds(centerCoordinateBounds: area, maximumDistance: context.camera.distance * 1.3)
        }
    }

    /// Where a ride's bullets go: on its line, with `room` meters from the nearest station
    /// or other dot, and the way to the line's left, to stand them beside it where that's too
    /// little for them.
    struct Bullet {
        var coordinate: CLLocationCoordinate2D
        var room: Double
        var left: (x: Double, y: Double)
    }

    /// Points of room a bullet needs either side of it on its line, about its own size.
    private static let bulletRoom: Double = 16
    /// Points from its line a bullet stands where it hasn't that room, clear of the line's casing.
    private static let bulletAside: Double = 17

    /// `bullet`'s place as drawn, at `mapPointsPerPoint`: on its line, or beside it, to the left
    /// (as other change stations' rides go to the right), where its stations are too close.
    private static func place(of bullet: Bullet, mapPointsPerPoint: Double) -> CLLocationCoordinate2D {
        let room = bullet.room * MKMapPointsPerMeterAtLatitude(bullet.coordinate.latitude) / mapPointsPerPoint
        guard mapPointsPerPoint > 0, room < bulletRoom else { return bullet.coordinate }
        let point = MKMapPoint(bullet.coordinate), aside = bulletAside * mapPointsPerPoint
        return MKMapPoint(x: point.x + bullet.left.x * aside, y: point.y + bullet.left.y * aside).coordinate
    }

    /// Meters apart a ride's lines may be that are taken to run together: wider than
    /// `alongside`, as express and local tracks' shapes part a little around stations.
    private static let lanesTogether: Double = 150

    /// Meters over which a line moves beside another, or back, where they meet or part.
    private static let laneBlend: Double = 300

    /// For each of `tracks` (a ride's lines), points to the right of each of its points to draw
    /// it: where some run together, each `width` from the next, centred on where they run; on its
    /// own, on its track; blending between over `laneBlend`.
    static func laneOffsets(_ tracks: [[CLLocationCoordinate2D]], width: Double) -> [[Double]] {
        let lines = tracks.map { $0.map(MKMapPoint.init) }
        guard lines.count > 1, let somewhere = lines.lazy.compactMap(\.first).first else {
            return lines.map { $0.map { _ in 0 } }
        }
        let perMeter = MKMapPointsPerMeterAtLatitude(somewhere.coordinate.latitude)
        let reach = lanesTogether * perMeter
        let grids = lines.map { SegmentGrid($0, cell: reach) }
        return lines.indices.map { lane in
            let points = lines[lane]
            // Where it'd be at each point: its place among the lines there
            let target = points.map { point -> Double in
                let together = lines.indices.filter { $0 == lane || grids[$0].isNear(point, within: reach) }
                let place = together.firstIndex(of: lane) ?? 0
                return (Double(place) - Double(together.count - 1) / 2) * width
            }
            // Blended: the mean over `laneBlend` meters around each point
            var along = [0.0]
            for (a, b) in zip(points, points.dropFirst()) { along.append(along[along.count - 1] + a.distance(to: b)) }
            var from = 0, to = 0, sum = 0.0
            return points.indices.map { index in
                while to < points.count, along[to] <= along[index] + laneBlend / 2 {
                    sum += target[to]
                    to += 1
                }
                while along[from] < along[index] - laneBlend / 2 {
                    sum -= target[from]
                    from += 1
                }
                return sum / Double(max(1, to - from))
            }
        }
    }

    /// One of the picked trip's lines as drawn.
    private struct Line: Identifiable {
        var id: String
        var coordinates: [CLLocationCoordinate2D]
        var color: Color
        var width: CGFloat

        /// Its casing's id, apart from its own, as MapKit tells all lines apart by id.
        var casingID: String { "casing-" + id }
    }

    /// An index for `ForEach`, its id also telling it from those of other trips (`tag`).
    private struct Keyed {
        var id: String
        var index: Int
    }

    private static func keyed(_ indices: some Sequence<Int>, tag: String) -> [Keyed] {
        indices.map { Keyed(id: "\(tag)-\($0)", index: $0) }
    }

    /// About how many meters a point is, framed on `area`; zoomed in, the gap at a change grows.
    private static func metersPerPoint(in area: MKMapRect, height: CGFloat) -> Double {
        guard height > 0, area.height.isFinite else { return 0 }
        return area.height / MKMapPointsPerMeterAtLatitude(area.origin.coordinate.latitude) / Double(height)
    }

    /// `line` with `start` meters cut off its start and `end` off its end; as it is if it's
    /// shorter than both.
    private static func trimmed(_ line: [CLLocationCoordinate2D], start: Double, end: Double) -> [CLLocationCoordinate2D] {
        func cut(_ line: [CLLocationCoordinate2D], by meters: Double) -> [CLLocationCoordinate2D] {
            var left = meters
            for index in 0..<max(0, line.count - 1) {
                let from = MKMapPoint(line[index]), to = MKMapPoint(line[index + 1])
                let length = from.distance(to: to)
                if length > left {
                    let along = left / length
                    let point = MKMapPoint(x: from.x + (to.x - from.x) * along, y: from.y + (to.y - from.y) * along)
                    return [point.coordinate] + line[(index + 1)...]
                }
                left -= length
            }
            return line
        }
        let total = zip(line, line.dropFirst()).reduce(0) { $0 + MKMapPoint($1.0).distance(to: MKMapPoint($1.1)) }
        guard total > start + end else { return line }
        return Array(cut(Array(cut(line, by: start).reversed()), by: end).reversed())
    }

    /// `line` moved `distance` map points to its right (left where it's negative), each point
    /// out along between its two sides' normals, so lines side by side stay apart round corners.
    private static func offset(_ line: [CLLocationCoordinate2D], by distance: Double) -> [CLLocationCoordinate2D] {
        guard distance != 0, distance.isFinite else { return line }
        return offset(line, by: Array(repeating: distance, count: line.count))
    }

    /// `line` with each point moved its own distance in `distances` (as many as its points) to
    /// its right, as `offset(_:by:)`.
    private static func offset(_ line: [CLLocationCoordinate2D], by distances: [Double]) -> [CLLocationCoordinate2D] {
        guard distances.count == line.count, distances.contains(where: { $0 != 0 }),
              distances.allSatisfy(\.isFinite) else { return line }
        // Without repeated points, which have no direction
        var points: [MKMapPoint] = []
        var moves: [Double] = []
        for (point, move) in zip(line.map(MKMapPoint.init), distances)
        where points.last.map({ $0.x != point.x || $0.y != point.y }) ?? true {
            points.append(point)
            moves.append(move)
        }
        guard points.count > 1 else { return line }
        // Each segment's right: map points' y runs south, so east's right is south
        let normals = zip(points, points.dropFirst()).map { a, b in
            let dx = b.x - a.x, dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            return (x: -dy / length, y: dx / length)
        }
        let moved = points.indices.map { index in
            let before = normals[max(0, index - 1)], after = normals[min(normals.count - 1, index)]
            var x = before.x + after.x, y = before.y + after.y
            let length = (x * x + y * y).squareRoot()
            if length > 0.001 {
                x /= length
                y /= length
            } else {
                // Turning right back: out along the way it came
                (x, y) = before
            }
            // Further out at a corner, to keep the line's width there, but not far past it
            let miter = min(2, 1 / max(0.5, x * before.x + y * before.y))
            let point = points[index], distance = moves[index]
            return MKMapPoint(x: point.x + x * distance * miter, y: point.y + y * distance * miter)
        }
        // Without points going back the way the line came, as on the inside of a curve tighter
        // than it's moved out, where they'd loop
        var kept = [0]
        for index in moved.indices.dropFirst() {
            let last = kept[kept.count - 1]
            let way = (x: points[index].x - points[last].x, y: points[index].y - points[last].y)
            let step = (x: moved[index].x - moved[last].x, y: moved[index].y - moved[last].y)
            if way.x * step.x + way.y * step.y > 0 { kept.append(index) }
        }
        return kept.map { moved[$0].coordinate }
    }

    /// Meters apart `densified(_:)` leaves points at most.
    private static let densestStep: Double = 40

    /// `line` with points added along it, so none are more than `densestStep` apart.
    static func densified(_ line: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard let first = line.first else { return line }
        var result = [first]
        for (a, b) in zip(line, line.dropFirst()) {
            let from = MKMapPoint(a), to = MKMapPoint(b)
            let steps = Int((from.distance(to: to) / densestStep).rounded(.up))
            if steps > 1 {
                for step in 1..<steps {
                    let t = Double(step) / Double(steps)
                    result.append(MKMapPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t).coordinate)
                }
            }
            result.append(b)
        }
        return result
    }

    /// Where another change station's ride is drawn: `out`, points to the right of each of its
    /// points; `hidden`, whether each is left out, as only over a line already drawn there.
    struct Beside {
        var out: [Double]
        var hidden: [Bool]
    }

    /// Where each ride of `changes` (each other change station's rides), one after another, is
    /// drawn: left out where it runs along one of `rides` on the same line, or along another
    /// station's ride on the same line before it, as the same track's drawn there already;
    /// otherwise clear of `rides`' lines (and their casing) where it runs along one, and of the
    /// other lines' rides before it where it runs along them too. It comes off and goes back
    /// gradually (`besideSlope`), and from its other change station's dot.
    static func beside(_ changes: [[SharedTrip.Option.Ride]], of rides: [SharedTrip.Option.Ride]) -> [Beside] {
        let others = changes.flatMap { $0 }
        // Which station each is to
        let station = changes.indices.flatMap { index in changes[index].map { _ in index } }
        // Each ride's half width, casing and all, as drawn
        let halves = rides.map { ride in
            let lanes = ride.routes.count
            return Double((lanes > 1 ? sideBySideWidth : lineWidth) * CGFloat(lanes) + 4) / 2
        }
        let otherPoints = others.map { $0.coordinates.map(MKMapPoint.init) }
        guard let somewhere = otherPoints.lazy.compactMap(\.first).first else {
            return otherPoints.map { Beside(out: $0.map { _ in 0 }, hidden: $0.map { _ in false }) }
        }
        let reach = alongside * MKMapPointsPerMeterAtLatitude(somewhere.coordinate.latitude)
        // Each of the trip's lines along its own track, with its ride
        let solids = rides.indices.flatMap { ride in
            rides[ride].tracks.indices.map { lane in
                (ride: ride, route: rides[ride].routes.indices.contains(lane) ? rides[ride].routes[lane] : rides[ride].route,
                 grid: SegmentGrid(rides[ride].tracks[lane].map(MKMapPoint.init), cell: reach))
            }
        }
        let otherGrids = otherPoints.map { SegmentGrid($0, cell: reach) }
        return otherPoints.indices.map { index in
            let points = otherPoints[index], route = others[index].route
            var hidden = points.map { _ in false }
            // How far out it'd be at each point
            var out = points.indices.map { point -> Double in
                let near = solids.filter { $0.grid.isNear(points[point], within: reach) }
                let dashed = otherGrids.indices.filter {
                    $0 < index && station[$0] != station[index] && otherGrids[$0].isNear(points[point], within: reach)
                }
                if near.contains(where: { $0.route == route })
                    || dashed.contains(where: { others[$0].route == route }) {
                    hidden[point] = true
                    return 0
                }
                let solid = near.map { halves[$0.ride] }.max()
                // One lane out at most, as further out they loop round tight curves
                let lines = min(1, Set(dashed.map { others[$0].route }).count)
                guard solid != nil || lines > 0 else { return 0 }
                return (solid.map { $0 + Double(dashedCasing) / 2 } ?? 0) + Double(lines) * Double(dashedCasing)
            }
            // Each moved out at most `besideSlope` a meter from the points around it
            if out.contains(where: { $0 > 0 }) {
                for index in out.indices.dropFirst() {
                    out[index] = max(out[index], out[index - 1] - points[index - 1].distance(to: points[index]) * besideSlope)
                }
                for index in out.indices.dropLast().reversed() {
                    out[index] = max(out[index], out[index + 1] - points[index].distance(to: points[index + 1]) * besideSlope)
                }
            }
            // From the station at either end of it, its other change station's dot or the trip's
            // end, rather than beside it, or across the lines there
            var along = 0.0
            for point in out.indices {
                if point > 0 { along += points[point - 1].distance(to: points[point]) }
                out[point] = min(out[point], along * besideSlope)
            }
            along = 0
            for point in out.indices.reversed() {
                if point < out.count - 1 { along += points[point].distance(to: points[point + 1]) }
                out[point] = min(out[point], along * besideSlope)
            }
            return Beside(out: out, hidden: hidden)
        }
    }

    /// The runs of a line's `count` points that aren't `hidden` (as many, or none for all of
    /// them), each of two points or more.
    private static func pieces(of count: Int, without hidden: [Bool]) -> [Range<Int>] {
        guard hidden.count == count else { return [0..<count] }
        var pieces: [Range<Int>] = []
        var start: Int?
        for index in 0...count {
            if index < count, !hidden[index] {
                if start == nil { start = index }
            } else if let from = start {
                if index - from > 1 { pieces.append(from..<index) }
                start = nil
            }
        }
        return pieces
    }

    /// A line's segments by the squares of a grid they cross, to find those near a point without
    /// going through them all.
    private struct SegmentGrid {
        private struct Square: Hashable {
            var x: Int
            var y: Int
        }

        private let points: [MKMapPoint]
        private let cell: Double
        private var squares: [Square: [Int]] = [:]

        /// `points`' segments, in squares `cell` map points on a side, at least.
        init(_ points: [MKMapPoint], cell: Double) {
            self.points = points
            self.cell = max(cell, 1)
            for index in 0..<max(0, points.count - 1) {
                let a = points[index], b = points[index + 1]
                let from = square(of: MKMapPoint(x: min(a.x, b.x), y: min(a.y, b.y)))
                let to = square(of: MKMapPoint(x: max(a.x, b.x), y: max(a.y, b.y)))
                for x in from.x...to.x {
                    for y in from.y...to.y {
                        squares[Square(x: x, y: y), default: []].append(index)
                    }
                }
            }
        }

        private func square(of point: MKMapPoint) -> Square {
            Square(x: Int((point.x / cell).rounded(.down)), y: Int((point.y / cell).rounded(.down)))
        }

        /// Whether `point` is within `reach` map points (at most a square's side) of the line.
        func isNear(_ point: MKMapPoint, within reach: Double) -> Bool {
            let squaredReach = reach * reach
            let center = square(of: point)
            for x in (center.x - 1)...(center.x + 1) {
                for y in (center.y - 1)...(center.y + 1) {
                    for index in squares[Square(x: x, y: y)] ?? [] {
                        let a = points[index], b = points[index + 1]
                        let dx = b.x - a.x, dy = b.y - a.y
                        let squared = dx * dx + dy * dy
                        let t = squared == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / squared))
                        let x = a.x + t * dx - point.x, y = a.y + t * dy - point.y
                        if x * x + y * y <= squaredReach { return true }
                    }
                }
            }
            return false
        }
    }

    /// Meters around the trips and both ends that the map shows, at least.
    private static let margin: Double = 400

    /// What the map covers: every trip's rides and both ends, a little beyond.
    private static func area(rides: [[SharedTrip.Option.Ride]], otherChanges: [[SharedTrip.Option.OtherChange]],
                             start: CLLocationCoordinate2D?, end: CLLocationCoordinate2D?) -> MKMapRect {
        let coordinates = (rides.joined() + otherChanges.joined().flatMap(\.rides)).flatMap(\.coordinates)
            + [start, end].compactMap { $0 }
        var rect = MKMapRect.null
        for coordinate in coordinates {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        guard !rect.isNull, let center = coordinates.first else { return .world }
        let margin = Self.margin * MKMapPointsPerMeterAtLatitude(center.latitude)
        let dx = max(rect.width * 0.08, margin)
        let dy = max(rect.height * 0.08, margin)
        // More above, where the end's pin stands over its point
        let top = max(rect.height * 0.15, margin * 2)
        return MKMapRect(x: rect.minX - dx, y: rect.minY - dy - top,
                         width: rect.width + dx * 2, height: rect.height + dy * 2 + top)
    }
}

extension SharedTrip.Option {
    /// One ride of a trip: its line, the track it runs along, and the stations it stops at.
    struct Ride {
        /// Trains' route ids, or a bus's line: more than one where any of them will do (the N
        /// or the R).
        var routes: [String]
        /// The first's track.
        var coordinates: [CLLocationCoordinate2D]
        var stops: [CLLocationCoordinate2D]
        var isBus = false
        /// With more than one line, each's own track, the first's first: the N over the
        /// Manhattan Bridge and the R through the Montague St tunnel, side by side where they run
        /// together. Empty with one.
        var lanes: [[CLLocationCoordinate2D]] = []

        /// Each line's track, as `lanes`, or the one line's.
        var tracks: [[CLLocationCoordinate2D]] { lanes.isEmpty ? [coordinates] : lanes }

        /// Where its bullets go: halfway along a stretch between two of its stations (or along
        /// it, without two), the stretch whose middle is furthest from them and `avoiding`.
        func bulletAt(avoiding: [CLLocationCoordinate2D]) -> TripMap.Bullet? {
            let points = coordinates.map(MKMapPoint.init)
            guard let first = points.first else { return nil }
            guard points.count > 1 else { return TripMap.Bullet(coordinate: first.coordinate, room: 0, left: (0, 0)) }
            // Map points along the line to the start of each segment
            var starts = [0.0]
            for (a, b) in zip(points, points.dropFirst()) {
                starts.append(starts[starts.count - 1] + a.distance(to: b))
            }
            // How far along the line a point beside it is: where it's closest
            func along(_ coordinate: CLLocationCoordinate2D) -> Double {
                let p = MKMapPoint(coordinate)
                var best = (distance: Double.infinity, along: 0.0)
                for index in 0..<(points.count - 1) {
                    let a = points[index], b = points[index + 1]
                    let dx = b.x - a.x, dy = b.y - a.y
                    let squared = dx * dx + dy * dy
                    let t = squared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared))
                    let x = a.x + t * dx, y = a.y + t * dy
                    let distance = (p.x - x) * (p.x - x) + (p.y - y) * (p.y - y)
                    if distance < best.distance {
                        best = (distance, starts[index] + t * (starts[index + 1] - starts[index]))
                    }
                }
                return best.along
            }
            // The point `distance` along the line, and the way to its left
            func point(at distance: Double) -> (point: MKMapPoint, left: (x: Double, y: Double)) {
                let index = max(0, min(points.count - 2, starts.lastIndex { $0 <= distance } ?? 0))
                let length = starts[index + 1] - starts[index]
                let t = length > 0 ? (distance - starts[index]) / length : 0
                let a = points[index], b = points[index + 1]
                let dx = b.x - a.x, dy = b.y - a.y, run = (dx * dx + dy * dy).squareRoot()
                let left = run > 0 ? (x: dy / run, y: -dx / run) : (x: 0.0, y: 0.0)
                return (MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), left)
            }
            let marks = stops.count > 1 ? stops.map(along).sorted() : [0, starts[starts.count - 1]]
            let avoided = avoiding.map(MKMapPoint.init)
            // Each stretch's middle, and how far it is from its ends and anything avoided
            let middles = zip(marks, marks.dropFirst()).map { from, to in
                let middle = point(at: (from + to) / 2)
                return TripMap.Bullet(coordinate: middle.point.coordinate,
                                      room: avoided.reduce((to - from) / 2) { min($0, $1.distance(to: middle.point)) },
                                      left: middle.left)
            }
            return middles.max { $0.room < $1.room }
        }

        /// The first line.
        var route: String { routes.first ?? "" }

        /// The first line's colour, or the bus's blue.
        var color: Color { color(of: route) }

        /// `route`'s colour, or the bus's blue.
        func color(of route: String) -> Color {
            isBus ? (BusBadge.isSBS(route) ? BusBadge.sbsBlue : BusBadge.blue) : LineStyle.of(route).swiftUIColor
        }
    }

    /// The trip's rides: its train to the change or its end, then any line changed to.
    var rides: [Ride] {
        guard let origin = selection.station, let route = selection.routes.first, let last = endStation else { return [] }
        guard let change, let at = StationDirectory.station(id: change.stationID), let onward = change.routes.first else {
            return [Self.ride(of: route, or: selection.routes, from: origin, to: last)]
        }
        return [Self.ride(of: route, or: selection.routes, from: origin, to: at),
                Self.ride(of: onward, or: change.routes, from: at, to: last)]
    }

    /// Another station the trip may change at (`Change.alternatives`): where, its name where it
    /// isn't the change's own station (or one joined to it), and the rides that way.
    struct OtherChange {
        var coordinate: CLLocationCoordinate2D
        var name: String?
        var rides: [Ride]
    }

    /// The trip's other change stations, each with your train's ride there and the line changed
    /// to there on to the end.
    var otherChanges: [OtherChange] {
        guard let origin = selection.station, let route = selection.routes.first, let last = endStation,
              let change else { return [] }
        let main = change.station?.complex
        return change.stops.dropFirst().compactMap { stop in
            guard let at = stop.station, let onward = stop.routes.first else { return nil }
            // One of your lines that stops there
            let line = selection.routes.first { !at.platforms(serving: [$0]).isEmpty } ?? route
            return OtherChange(coordinate: at.coordinate, name: at.complex == main ? nil : at.name.mainStationName,
                               rides: [Self.ride(of: line, from: origin, to: at), Self.ride(of: onward, from: at, to: last)])
        }
    }

    /// Meters between stations a line's stops may be: further, the slice likely runs from one
    /// branch to another (lines.json lists branches one after another).
    private static let longestHop: CLLocationDistance = 5_000

    /// `route` from `origin` to `destination`, each the station joined to it that `route` stops
    /// at: along its track where `TrackShapes` has it, otherwise through its stations, its corners
    /// curved, and its stations on it. With it, any of `others` that stop at both, as any of them
    /// will do.
    private static func ride(of route: String, or others: [String] = [], from origin: Station,
                             to destination: Station) -> Ride {
        let board = served(by: route, at: origin), alight = served(by: route, at: destination)
        let stations = stations(of: route, from: board, to: alight).map(\.coordinate)
        let line = TrackShapes.rounded(TrackShapes.track(of: route, from: board.coordinate, to: alight.coordinate) ?? stations)
        let also = others.filter { $0 != route && stops($0, at: origin) && stops($0, at: destination) }
        // Each other line along its own track, where it has one, from where it stops
        let lanes = also.isEmpty ? [] : [TripMap.densified(line)] + also.map { other in
            let board = served(by: other, at: origin), alight = served(by: other, at: destination)
            return TripMap.densified(TrackShapes.track(of: other, from: board.coordinate, to: alight.coordinate)
                .map(TrackShapes.rounded) ?? line)
        }
        return Ride(routes: [route] + also, coordinates: line, stops: stations.map { TrackShapes.snapped($0, to: line) },
                    lanes: lanes)
    }

    /// Whether `route` stops at `station` or a station joined to it.
    private static func stops(_ route: String, at station: Station) -> Bool {
        StationDirectory.stations(inComplexOf: station).contains { $0.routes.contains(route) }
    }

    /// The station joined to `station` that `route` stops at, or `station` itself.
    private static func served(by route: String, at station: Station) -> Station {
        StationDirectory.stations(inComplexOf: station).first { $0.routes.contains(route) } ?? station
    }

    /// `route`'s stations from `origin` to `destination` in order (lines.json); just the two
    /// where they can't be followed.
    private static func stations(of route: String, from origin: Station, to destination: Station) -> [Station] {
        let ends = [origin, destination]
        let stops = (StationDirectory.stops(onLine: LineStyle.of(route).label) ?? []).filter { id in
            StationDirectory.station(id: id)?.platforms.contains { $0.id == id && $0.routes.contains(route) } == true
        }
        let inComplex = { (station: Station) -> Set<String> in
            Set(StationDirectory.stations(inComplexOf: station).flatMap(\.platforms).map(\.id))
        }
        let origins = inComplex(origin)
        let destinations = inComplex(destination)
        guard let from = stops.firstIndex(where: origins.contains),
              let to = stops.firstIndex(where: destinations.contains), from != to else { return ends }
        let ids = from < to ? Array(stops[from...to]) : Array(stops[to...from].reversed())
        let stations = ids.compactMap(StationDirectory.station(id:))
        let locations = stations.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
        guard stations.count == ids.count,
              zip(locations, locations.dropFirst()).allSatisfy({ $0.distance(from: $1) <= longestHop }) else { return ends }
        return stations
    }
}

extension ServerRoutes.Choice {
    /// The trip's rides, in order: a train trip's (`SharedTrip.Option.rides`), or a bus trip's
    /// bus, straight from stop to stop, and its train before or after it.
    var rides: [SharedTrip.Option.Ride] {
        switch self {
        case .train(let option):
            return option.rides
        case .bus(let trip):
            let stops = [trip.bus.from, trip.bus.to].map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let bus = SharedTrip.Option.Ride(routes: [trip.bus.line], coordinates: stops, stops: stops, isBus: true)
            let train = trip.train?.rides ?? []
            return trip.busFirst ? [bus] + train : train + [bus]
        }
    }

    /// A train trip's other change stations (`SharedTrip.Option.otherChanges`); none by bus.
    var otherChanges: [SharedTrip.Option.OtherChange] {
        guard case .train(let option) = self else { return [] }
        return option.otherChanges
    }
}

private extension Station {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}
