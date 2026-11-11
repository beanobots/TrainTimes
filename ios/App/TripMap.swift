import MapKit
import SwiftUI

/// New Trip's picked trip on a map, in its lines' colours with its stations and each line's
/// bullet, and both ends. Rides
/// follow the MTA's track (`TrackShapes`), or go station to station where it can't be followed;
/// a bus goes along its street (`BusNetwork.path`), or straight where its way isn't known.
struct TripMap: View {
    let options: [ServerRoutes.Choice]
    let picked: Int
    let start: CLLocationCoordinate2D?
    let end: CLLocationCoordinate2D?
    let endName: String
    /// Points over the bottom of the map's room, inside its safe area, that something's over (the
    /// trips and the bar): the trip's framed clear of it, while the map's logo and Legal stay
    /// under it.
    var covered: CGFloat = 0
    /// Where the map's put, New Trip's: framed on the ends by it before there are trips, and on
    /// the trips here once there are. One map for both, as a second map, made or shown as the
    /// trips came in, began blank and loaded all its tiles again.
    @Binding var position: MapCameraPosition
    /// Which way the compass turned the map, when not Settings' way, New Trip's to frame by too:
    /// framed that way after. Cleared as Settings changes.
    @Binding var keptHeading: Double?
    /// What's drawn before there are trips (`options` empty), with you.
    var before: Before
    /// Where the map last came to rest, for New Trip.
    var rested: (MapCamera) -> Void = { _ in }
    /// The picked train trip's walks as New Trip asks for them for Go, drawn rather than asked
    /// for again to other ends; and whether it asks, so none are asked for here meanwhile.
    var aheadWalks: Task<WalkingDirections.TripWalks?, Error>? = nil
    var asksWalks = false

    /// Before there are trips: the lines round From (`NearbyLines`), the city the map's kept to,
    /// and the room over the compass, as nothing pads the map's top before both ends.
    struct Before {
        var lines: NearbyLines
        var version: Int
        var cache: NearbyLinesLayer.Cache
        var bounds: MapCameraBounds
        var compassTop: CGFloat
        /// Where you are, by the app's own last fix (`NearbyLocation`), for your dot: not MapKit's,
        /// which kept best-accuracy GPS on the whole time the map showed.
        var you: CLLocationCoordinate2D? = nil
    }

    /// Whether there are trips to draw, rather than what's `before` them.
    private var hasTrips: Bool { !options.isEmpty }

    /// Keeps the map to `area`, once it's framed there.
    @State private var bounds: MapCameraBounds?
    /// The trips last framed, to tell new ones from the room changing round them.
    @State private var framedTrips: FramedTrips?
    /// The map's height, for how many meters a point is when framed on `area`.
    @State private var height: CGFloat = 230
    @State private var width: CGFloat = 400
    /// The room under the map's bottom, as `topInset`.
    @State private var bottomInset: CGFloat = 0
    /// The room either side, as `topInset`.
    @State private var sideInsets: CGFloat = 0
    /// The room over the map's top, under what's over it, which framing keeps the trips clear of.
    @State private var topInset: CGFloat = 0
    /// Map points a point is on the map as its lines are laid out: as framed for new trips, then
    /// moved on only where the map rests well off it (`LineScale`), so the lines keep their shape
    /// on the ground, with their stations, while it's moved.
    @State private var linesScale: Double?
    /// The zoom every frame, for the stations' dots alone.
    @State private var liveZoom = LiveZoom()
    @AppStorage(MapNorth.key) private var nyNorth = false
    /// Where the map last came to rest, for the compass to turn it there.
    @State private var shownCamera: MapCamera?
    /// Which way the map's turned as it moves, every 5° or so, for its compass alone: read only
    /// by it, so the map isn't redrawn as it turns.
    @State private var turned = Turned()

    /// Each trip's rides and what the map covers, worked out once for each set of trips and ends
    /// rather than on every redraw, as following a ride's track (`TrackShapes`) takes a while.
    @State private var cache = Cache()
    /// The picked trip's walks to its first station and from its last along the streets, by
    /// Apple Maps, once found; straight across until then.
    @State private var streetWalks: StreetWalks?

    /// Where the picked trip's walks go from and to, for finding them along the streets.
    private struct WalkEnds: Equatable {
        var start: [Double]?
        var firstStation: [Double]?
        var lastStation: [Double]?
        var end: [Double]?
    }

    /// What the picked trip's walks are found for: their ends, and New Trip's walks for it.
    private struct WalksKey: Equatable {
        var ends: WalkEnds
        var ahead: Task<WalkingDirections.TripWalks?, Error>?
        var asked: Bool
    }

    /// The picked trip's walks along the streets, and the ends they're for.
    private struct StreetWalks {
        var ends: WalkEnds
        var toTrain: [CLLocationCoordinate2D]?
        var fromTrain: [CLLocationCoordinate2D]?
    }

    /// The picked trip as drawn.
    private struct Drawn {
        var rides: [SharedTrip.Option.Ride]
        var otherChanges: [SharedTrip.Option.OtherChange]
        /// For its other change stations, your train's ride there, where it's drawn (`Beside`).
        var beside: [Beside]
        /// For its other change stations, for each of its rides, as `laneOffsets` and `stations`
        /// are for its own rides.
        var otherLaneOffsets: [[[[Double]]]]
        var otherStations: [[[StationStop]]]
        /// Each ride's bullets' place, clear of its stations, the other change stations and both
        /// ends (`Ride.bulletAt(avoiding:)`).
        var bullets: [Bullet?]
        /// For its rides, the lines changed to at other change stations drawn as it (`Beside.joins`),
        /// whose bullets go beside its own.
        var joinedRoutes: [[String]]
        /// For its rides, for each of its lines (`Ride.tracks`), points to the right of each of
        /// its points to draw it, beside the others where they run together.
        var laneOffsets: [[[Double]]]
        /// For its rides, its stations, each with where its lines stop there (`StationStop`),
        /// for its dot to reach across them all.
        var stations: [[StationStop]]
        /// What the map covers for it.
        var area: MKMapRect
        /// Counts up with each new `Drawn`, to tell the map's lines from the last ones'.
        var version: Int
    }

    /// Holds each trip's `Drawn` as it's picked, for the trips and ends they're for. Only the
    /// picked one's worked out, as only it's drawn: working out every trip's as they came in, on
    /// the main thread, hitched New Trip. Kept for the trips, so picking one again is instant.
    /// Not observed: filling it in doesn't redraw.
    private final class Cache {
        private struct Key: Equatable {
            var options: [ServerRoutes.Choice]
            var start: [Double]?
            var end: [Double]?
        }

        private var key: Key?
        private var drawn: [Int: Drawn] = [:]
        private var version = 0

        func drawn(options: [ServerRoutes.Choice], picked: Int, start: CLLocationCoordinate2D?,
                   end: CLLocationCoordinate2D?) -> Drawn {
            let key = Key(options: options, start: start.map { [$0.latitude, $0.longitude] },
                          end: end.map { [$0.latitude, $0.longitude] })
            if key != self.key {
                self.key = key
                drawn = [:]
            }
            if let known = drawn[picked] { return known }
            let option = options.indices.contains(picked) ? options[picked] : nil
            let rides = option?.rides ?? []
            // Points close enough together to move off the lines they run along smoothly
            let otherChanges = (option?.otherChanges ?? []).map { change in
                var change = change
                change.rides = change.rides.map { ride in
                    var ride = ride
                    ride.coordinates = TripMap.densified(ride.coordinates)
                    return ride
                }
                return change
            }
            // Each line of them on its own, for moving clear of the trip's own lines
            // and which are lines changed to, left out along the trip's own of the same line
            let beside = TripMap.beside(otherChanges.map { change in change.rides.flatMap(TripMap.lines(of:)) }, of: rides,
                                        onward: otherChanges.map { change in
                                            change.rides.indices.flatMap { index in
                                                change.rides[index].tracks.map { _ in index >= change.onTo }
                                            }
                                        })
            let otherLaneOffsets = otherChanges.map { change in
                change.rides.map { TripMap.laneOffsets($0.tracks, colors: $0.laneColors, width: Double(TripMap.sideBySideWidth)) }
            }
            let otherStations = otherChanges.map { $0.rides.map(TripMap.stationStops) }
            let ends = [start, end].compactMap { $0 }
            let bullets = rides.map { $0.bulletAt(avoiding: otherChanges.map(\.coordinate) + ends) }
            let lines = otherChanges.flatMap { change in change.rides.flatMap(TripMap.lines(of:)) }
            let joinedRoutes = rides.indices.map { index in
                zip(lines, beside).reduce(into: [String]()) { routes, pair in
                    if pair.1.joins == index, !rides[index].routes.contains(pair.0.route), !routes.contains(pair.0.route) {
                        routes.append(pair.0.route)
                    }
                }
            }
            let laneOffsets = rides.map { TripMap.laneOffsets($0.tracks, colors: $0.laneColors, width: Double(TripMap.sideBySideWidth)) }
            let stations = rides.map(TripMap.stationStops)
            // None picked (no trips): the whole world, as before
            let area = option == nil ? MKMapRect.world
                : TripMap.area(rides: [rides], otherChanges: [otherChanges], start: start, end: end)
            version += 1
            let made = Drawn(rides: rides, otherChanges: otherChanges, beside: beside, otherLaneOffsets: otherLaneOffsets,
                             otherStations: otherStations, bullets: bullets, joinedRoutes: joinedRoutes, laneOffsets: laneOffsets,
                             stations: stations, area: area, version: version)
            drawn[picked] = made
            return made
        }
    }

    private var drawn: Drawn { cache.drawn(options: options, picked: picked, start: start, end: end) }

    /// The picked trip's walk all the way, if it's that.
    private var pickedWalk: Walk? {
        guard options.indices.contains(picked), case .walk(let walk) = options[picked] else { return nil }
        return walk
    }

    /// The picked trip, if it's with a Citi Bike, for its docks.
    private var pickedBike: BikeTrip? {
        guard options.indices.contains(picked), case .bike(let trip) = options[picked] else { return nil }
        return trip
    }

    /// A dock's pin: how many bikes there (or e-bikes), or free docks, Citi Bike blue.
    private static func dockPin(_ count: Int, symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text("\(count)").font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.citiBike))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 1.5))
        .shadow(radius: 1)
    }

    /// Your dot before there are trips, Nearby's.
    private static var youDot: some View {
        MapYouDot(progress: 0, angle: .zero)
    }

    /// Where the picked trip's walks at either end go from and to.
    private var walkEnds: WalkEnds {
        let rides = drawn.rides
        let pair = { (coordinate: CLLocationCoordinate2D?) in coordinate.map { [$0.latitude, $0.longitude] } }
        return WalkEnds(start: pair(start), firstStation: pair(rides.first?.coordinates.first),
                        lastStation: pair(rides.last?.coordinates.last), end: pair(end))
    }

    /// Apple Maps' walk from `from` to `to`, joined to both, as it starts and ends on the nearest
    /// street; nil if it can't be had.
    private static func streetWalk(from: [Double]?, to: [Double]?) async -> [CLLocationCoordinate2D]? {
        guard let from, let to, from.count == 2, to.count == 2 else { return nil }
        let start = CLLocationCoordinate2D(latitude: from[0], longitude: from[1])
        let end = CLLocationCoordinate2D(latitude: to[0], longitude: to[1])
        // No walk to ask Apple Maps for where there's none, as your own bike's ride from your
        // door: drawn straight, without using up its directions for the trip's
        guard MKMapPoint(start).distance(to: MKMapPoint(end)) > 25,
              let walk = try? await WalkingDirections.walk(from: start, to: end) else { return nil }
        let points = walk.points.map(\.coordinate)
        return points.isEmpty ? nil : [start] + points + [end]
    }

    /// What the picked trip is framed for: new trips, another picked, or the room over it changing,
    /// as From and To over its bottom shrink to a line atop the trips or open again.
    private struct Framing: Equatable {
        var options: [ServerRoutes.Choice]
        var picked: Int
        var topInset: CGFloat
        var bottomInset: CGFloat
        var covered: CGFloat
        /// The map's size, as it's only measured once it's shown
        var width: CGFloat
        var height: CGFloat
    }

    /// The trips and the one picked, as last framed.
    private struct FramedTrips: Equatable {
        var options: [ServerRoutes.Choice]
        var picked: Int
    }

    /// What to frame for `area` to show clear of `covered`: `area`, in the room over it, with
    /// as much again under it as `covered` is of the map's safe area.
    private func framed(_ area: MKMapRect) -> MKMapRect {
        let safe = height - topInset - bottomInset, visible = safe - covered, wide = width - sideInsets
        guard covered > 0, wide > 0, visible > 0 else { return area }
        let scale = max(area.width / Double(wide), area.height / Double(visible))
        return MKMapRect(x: area.midX - Double(wide) * scale / 2, y: area.midY - Double(visible) * scale / 2,
                         width: Double(wide) * scale, height: Double(safe) * scale)
    }

    /// `area` framed clear of `covered`, turned Grid North if Settings says. A camera for the room
    /// as measured, north up too: as `.rect`, framing again for new room was the same rect, which
    /// MapKit never saw, so a map framed while the cards over it were still settling (with
    /// little room) stayed zoomed right out, Perth Amboy to Stamford.
    private func framing(_ area: MKMapRect) -> MapCameraPosition {
        let room = MapRoom(size: CGSize(width: width, height: height),
                           insets: EdgeInsets(top: topInset, leading: sideInsets / 2, bottom: bottomInset, trailing: sideInsets / 2))
        return MapNorth.position(fitting: area, heading: keptHeading ?? MapNorth.heading(ny: nyNorth), in: room, covered: covered,
                                 northUp: true)
            ?? .rect(framed(area))
    }

    /// What the map covers for the picked trip.
    private var area: MKMapRect {
        drawn.area
    }

    /// Map points a point is with the picked trip framed (`framed(_:)`), to lay its lines out
    /// for before the map gets there, so they're not laid out again once it has.
    private var framedScale: Double {
        let area = drawn.area
        let visible = height - topInset - bottomInset - covered, wide = width - sideInsets
        guard !area.isNull, visible > 0, wide > 0 else { return height > 0 ? area.height / Double(height) : 0 }
        return max(area.width / Double(wide), area.height / Double(visible))
    }

    /// Under the picked trip's lines, to lift them off the map's roads.
    private static let casing = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.6) : .white
    })

    /// The walks: dots bold enough to see on the map, in a dark grey (light in dark mode).
    private static let walk = StrokeStyle(lineWidth: 5, lineCap: .round, dash: [0.5, 9])
    private static let walkColor = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .lightGray : .darkGray
    })

    /// The picked trip's line, and each line's where it's one of two or more side by side, a few
    /// blocks across; thinner zoomed out (`Widths`).
    private static let lineWidth: CGFloat = 7
    private static let sideBySideWidth: CGFloat = 5
    /// Your train's ride on to another change station, casing and all, and so how far it's moved
    /// out beside the trip's other lines where it runs along them.
    private static let besideWidth: CGFloat = lineWidth + 4

    /// How wide lines are drawn at a zoom: as wide as `lineWidth` and `sideBySideWidth` a few
    /// blocks across, thinning to `zoomedOut` across a borough, so a trip framed whole isn't
    /// chunky. Lines side by side, and your train's ride moved out beside them, stay as far apart
    /// as they're wide.
    private struct Widths {
        /// Meters a point is, at most, with lines their widest, and at least with them thinnest.
        private static let widest: Double = 3
        private static let thinnest: Double = 20
        private static let zoomedOut = (line: 5.0, sideBySide: 4.0, casing: 3.0)

        var line: CGFloat
        var sideBySide: CGFloat
        var casing: CGFloat
        /// How much `sideBySideWidth` apart, as laid out, lines are drawn.
        var scale: Double { Double(sideBySide / TripMap.sideBySideWidth) }

        init(metersPerPoint: Double) {
            // Evenly by each doubling of the zoom
            let thin = metersPerPoint > 0
                ? max(0, min(1, log(metersPerPoint / Self.widest) / log(Self.thinnest / Self.widest))) : 0
            func blend(_ wide: CGFloat, _ narrow: Double) -> CGFloat { wide + (CGFloat(narrow) - wide) * CGFloat(thin) }
            line = blend(TripMap.lineWidth, Self.zoomedOut.line)
            sideBySide = blend(TripMap.sideBySideWidth, Self.zoomedOut.sideBySide)
            casing = blend(4, Self.zoomedOut.casing)
        }
    }

    /// Meters from the trip's own lines another ride may be that's taken to run along them, as
    /// on tracks side by side.
    private static let alongside: Double = 80
    /// Points another ride moves out by each meter, coming off or going back to where it runs
    /// along another: a full move out over a few hundred meters.
    private static let besideSlope: Double = 0.03
    /// How far out another ride may move, at most, for how far along it is from its nearer end.
    private static let besideReach: Double = 0.2

    var body: some View {
        let drawn = drawn
        let pickedRides = drawn.rides
        let others = drawn.otherChanges
        let area = drawn.area
        let mapPointsPerPoint = height > 0 ? linesScale ?? framedScale : 0
        let widths = Widths(metersPerPoint: mapPointsPerPoint / MKMapPointsPerMeterAtLatitude(area.origin.coordinate.latitude))
        let beside = drawn.beside
        let bullets = drawn.bullets
        let joinedRoutes = drawn.joinedRoutes
        let laneOffsets = drawn.laneOffsets
        let stationStops = drawn.stations
        let otherLaneOffsets = drawn.otherLaneOffsets
        let otherStations = drawn.otherStations
        // New lines for new trips or another picked, rather than MapKit keeping the last ones'
        // colours for lines in the same place in the list
        // and for each zoom, as lines side by side are moved apart by points: MapKit kept a line's
        // last shape while its id stayed, drawing it apart from the others' and its stations
        let zoom = LineScale.id(of: mapPointsPerPoint)
        let tag = "\(drawn.version)-\(picked)-\(zoom)"
        // Your train on to each other change station, moved out beside the trip's other lines it
        // runs along, and drawn in pieces, without where it'd only be drawn over itself
        let onTo = others.indices.flatMap { change in
            others[change].rides.indices.flatMap { ride in
                others[change].rides[ride].tracks.indices.map { lane in (change: change, ride: ride, lane: lane) }
            }
        }
        let otherPieces = onTo.indices.flatMap { index in
            let at = onTo[index], ride = others[at.change].rides[at.ride], line = ride.tracks[at.lane]
            let offsets = otherLaneOffsets.indices.contains(at.change) && otherLaneOffsets[at.change].indices.contains(at.ride)
                && otherLaneOffsets[at.change][at.ride].indices.contains(at.lane)
                ? otherLaneOffsets[at.change][at.ride][at.lane] : []
            let lanes = offsets.count == line.count ? offsets : line.map { _ in 0 }
            let color = ride.color(of: ride.routes.indices.contains(at.lane) ? ride.routes[at.lane] : ride.route)
            guard beside.indices.contains(index), beside[index].out.count == line.count else {
                return [(color: color, line: Self.offset(line, by: lanes.map { $0 * widths.scale * mapPointsPerPoint }))]
            }
            // Out by points, but no further than a fifth of the way back to either end: zoomed
            // out, a short ride's points out were longer than it, and it looped off round its curves
            let points = line.map(MKMapPoint.init)
            var along = [0.0]
            for (a, b) in zip(points, points.dropFirst()) { along.append(along[along.count - 1] + hypot(b.x - a.x, b.y - a.y)) }
            let total = along[along.count - 1]
            let outs = zip(zip(lanes, beside[index].out), along).map { pair, at in
                pair.0 * widths.scale * mapPointsPerPoint
                    + min(pair.1 * widths.scale * mapPointsPerPoint, min(at, total - at) * Self.besideReach)
            }
            return Self.pieces(of: line.count, without: beside[index].hidden).map { run in
                (color: color, line: Self.offset(Array(line[run]), by: Array(outs[run])))
            }
        }
        // Each of its rides' lines, in one list rather than a list in each ride's, which MapKit
        // was slow to draw the first time: where any of two or more lines will do, each along
        // its own track, beside the others where they run together, as on the subway map; each
        // up to its stations' dots at either end of its ride
        let pickedLines = pickedRides.indices.flatMap { index in
            let ride = pickedRides[index], tracks = ride.tracks
            let offsets = laneOffsets.indices.contains(index) ? laneOffsets[index] : []
            return tracks.indices.map { lane in
                let track = offsets.indices.contains(lane)
                    ? Self.offset(tracks[lane], by: offsets[lane].map { $0 * widths.scale * mapPointsPerPoint }) : tracks[lane]
                return Line(id: "line-\(tag)-\(index)-\(lane)",
                            coordinates: track,
                            color: ride.color(of: ride.routes.indices.contains(lane) ? ride.routes[lane] : ride.route),
                            width: ride.isSideBySide ? widths.sideBySide : widths.line)
            }
        }
        // Where it changes, from your train's end to where each line on leaves, once each
        let changeWalks = pickedRides.indices.dropFirst().flatMap { index -> [[CLLocationCoordinate2D]] in
            guard let off = pickedRides[index - 1].coordinates.last else { return [] }
            var ons: [CLLocationCoordinate2D] = []
            for on in pickedRides[index].tracks.compactMap(\.first)
            where !ons.contains(where: { MKMapPoint($0).distance(to: MKMapPoint(on)) < 1 }) {
                ons.append(on)
            }
            return ons.map { [off, $0] }
        }
        // Its stations' dots, where its lines are drawn, across those stopping there side by side
        let stations = Self.stationDots(of: pickedRides, laneOffsets: laneOffsets, stations: stationStops, endOnly: false,
                                        widths: widths, mapPointsPerPoint: mapPointsPerPoint, tag: "station-\(tag)")
        // The other change stations' dots, on your train's line, each named beside it ("or
        // DeKalb Av"): at the end of its ride on to it, or where your train passes it, rather than
        // again where the trip changes
        let mainComplex = pickedRides.count > 1 ? stationStops.first?.last(where: \.isEnd)?.complex : nil
        let otherDots = others.indices.flatMap { change -> [StationDot] in
            let onTo = others[change].onTo
            guard onTo > 0 else {
                guard others[change].complex != mainComplex, let first = pickedRides.first,
                      let stop = stationStops.first?.first(where: { $0.complex == others[change].complex }) else { return [] }
                var dots = Self.stationDots(of: [first], laneOffsets: Array(laneOffsets.prefix(1)), stations: [[stop]],
                                            endOnly: false, widths: widths, mapPointsPerPoint: mapPointsPerPoint,
                                            tag: "other-stop-\(tag)-\(change)")
                for index in dots.indices { dots[index].changes = true }
                if !dots.isEmpty { dots[dots.count - 1].name = others[change].name }
                return dots
            }
            // Only your train's ride on to it: the lines changed to there end where the trip does
            var dots = Self.stationDots(of: Array(others[change].rides.prefix(onTo)),
                                        laneOffsets: otherLaneOffsets.indices.contains(change)
                                            ? Array(otherLaneOffsets[change].prefix(onTo)) : [],
                                        stations: otherStations.indices.contains(change)
                                            ? Array(otherStations[change].prefix(onTo)) : [],
                                        endOnly: true, widths: widths, mapPointsPerPoint: mapPointsPerPoint,
                                        tag: "other-stop-\(tag)-\(change)")
            if !dots.isEmpty { dots[dots.count - 1].name = others[change].name }
            return dots
        }
        MapReader { proxy in
            // The bounds only for the trips they were found for: not for a moment on the next
            // trips', before they're let go (`.onChange(of: options)`)
            Map(position: $position, bounds: hasTrips ? (framedTrips?.options == options ? bounds : nil) : before.bounds,
                interactionModes: hasTrips ? [.pan, .zoom] : .all) {
                DebugOverlays(on: .newTrip)
                if !hasTrips {
                    NearbyLinesLayer(lines: before.lines, version: before.version, mapPointsPerPoint: linesScale ?? 0,
                                     cache: before.cache)
                    // You, as MapKit's dot looks, unless From's dot (where you are) is already there
                    if let you = before.you, start.map({ MKMapPoint($0).distance(to: MKMapPoint(you)) > 5 }) ?? true {
                        Annotation("", coordinate: you) {
                            Self.youDot
                        }
                    }
                }
                // The walks to its first station, between platforms where it changes, and from its last:
                // along the streets once Apple Maps has them, straight across until then
                let streets = streetWalks?.ends == walkEnds ? streetWalks : nil
                if let walk = pickedWalk, let start, let end {
                    // Walking all the way
                    MapPolyline(coordinates: [start] + walk.points.map(\.coordinate) + [end])
                        .stroke(Self.walkColor, style: Self.walk)
                }
                if let start, let first = pickedRides.first?.coordinates.first {
                    MapPolyline(coordinates: streets?.toTrain ?? [start, first])
                        .stroke(Self.walkColor, style: Self.walk)
                }
                // to each of the next ride's lines, as some may leave from another platform
                ForEach(Self.keyed(changeWalks.indices, tag: "walk-\(tag)"), id: \.id) { keyed in
                    MapPolyline(coordinates: changeWalks[keyed.index])
                        .stroke(Self.walkColor, style: Self.walk)
                }
                if let end, let last = pickedRides.last?.coordinates.last {
                    MapPolyline(coordinates: streets?.fromTrain ?? [last, end])
                        .stroke(Self.walkColor, style: Self.walk)
                }
                // Your train on to its other change stations, as its own line, beside its other lines
                // where it runs along them
                ForEach(Self.keyed(otherPieces.indices, tag: "on-to-\(tag)"), id: \.id) { keyed in
                    let piece = otherPieces[keyed.index]
                    MapPolyline(coordinates: piece.line)
                        .stroke(Self.casing, style: StrokeStyle(lineWidth: widths.line + widths.casing, lineCap: .round,
                                                                lineJoin: .round))
                        // Under every line's colour: MapKit keeps no order to lines in one level once
                        // some come and go, and drew casings over colours
                        .mapOverlayLevel(level: .aboveRoads)
                    MapPolyline(coordinates: piece.line)
                        .stroke(piece.color, style: StrokeStyle(lineWidth: widths.line, lineCap: .round, lineJoin: .round))
                }
                // Casings under all its lines, a level down, so none's drawn over another's colour
                ForEach(pickedLines, id: \.casingID) { line in
                    MapPolyline(coordinates: line.coordinates)
                        .stroke(Self.casing, style: StrokeStyle(lineWidth: line.width + widths.casing, lineCap: .round, lineJoin: .round))
                        .mapOverlayLevel(level: .aboveRoads)
                }
                ForEach(pickedLines) { line in
                    MapPolyline(coordinates: line.coordinates)
                        .stroke(line.color, style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round))
                }
                // Its stations: small dots on the line, larger where it changes, long across lines
                // side by side that stop there
                // and its other change stations' the same, named after (`named`)
                ForEach(stations + otherDots) { station in
                    Annotation("", coordinate: station.coordinate) {
                        StationDotView(dot: station, zoom: liveZoom, laidOutAt: mapPointsPerPoint)
                    }
                }
                // Each ride's bullets between two of its stations, side by side where it's more than
                // one line
                ForEach(Self.keyed(pickedRides.indices, tag: "bullet-\(tag)"), id: \.id) { keyed in
                    let index = keyed.index
                    let ride = pickedRides[index]
                    if let bullet = bullets.indices.contains(index) ? bullets[index] : nil {
                        // Centred on its line: pushed aside where its stations were close, it stood a
                        // fixed few points off, a mile or more zoomed out, nowhere near the line
                        Annotation("", coordinate: bullet.coordinate, anchor: .center) {
                            if ride.isBike {
                                BikeBullet(size: 20, electric: ride.route == CitiBike.Kind.eBike.rawValue, own: ride.isOwnBike)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                                    .shadow(radius: 1)
                            } else if ride.isBus {
                                BusBadge(line: ride.route, size: 20)
                                    .overlay(RoundedRectangle(cornerRadius: 5.6, style: .continuous).stroke(.white, lineWidth: 2))
                                    .shadow(radius: 1)
                            } else {
                                HStack(spacing: 2) {
                                    ForEach(ride.routes + (joinedRoutes.indices.contains(index) ? joinedRoutes[index] : []),
                                            id: \.self) { route in
                                        LineBullet(route: route, size: 20)
                                            .overlay(Circle().stroke(.white, lineWidth: 2))
                                            .shadow(radius: 1)
                                    }
                                }
                            }
                        }
                    }
                }
                // A Citi Bike trip's docks: the bikes to take where it starts, the free docks where it
                // ends. Your own bike has none
                if let bike = pickedBike, !bike.owned {
                    Annotation("", coordinate: bike.pickup.coordinate, anchor: .trailing) {
                        Self.dockPin(bike.bikes, symbol: bike.kind == .eBike ? "bolt.fill" : "bicycle")
                            .padding(.trailing, 6)
                    }
                    Annotation("", coordinate: bike.dropoff.coordinate, anchor: .leading) {
                        Self.dockPin(bike.docks, symbol: "parkingsign")
                            .padding(.leading, 6)
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
                // Each other change station's name beside its dot ("or DeKalb Av"), last, over
                // everything else
                ForEach(otherDots.filter { $0.name != nil }, id: \.nameID) { station in
                    Annotation("", coordinate: station.coordinate, anchor: .leading) {
                        StationNameView(dot: station, zoom: liveZoom, laidOutAt: mapPointsPerPoint)
                    }
                }
            }
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControlVisibility(.hidden)
            .turnsNorth($position, unless: keptHeading != nil)
            .onChange(of: nyNorth) { keptHeading = nil }
            // Back on Navigate after turning Nearby's map: turned the same way, where it was
            .onAppear {
                let heading = keptHeading ?? MapNorth.heading(ny: nyNorth)
                guard let shownCamera, MapNorth.isOff(shownCamera.heading, from: heading) else { return }
                position = .camera(MapCamera(centerCoordinate: shownCamera.centerCoordinate, distance: shownCamera.distance,
                                             heading: heading, pitch: shownCamera.pitch))
            }
            // New trips, or none while the next are planned: the last trips' bounds let go, so
            // the map isn't held to their area on its way to the new ones; and the last framed
            // forgotten, so the next are framed as new even if they're the same
            .onChange(of: options) { _, new in
                bounds = nil
                if new.isEmpty { framedTrips = nil }
            }
            // The whole map, its safe area too, which framing takes off
            .onGeometryChange(for: CGSize.self) { $0.wholeSize } action: { size in
                height = size.height
                width = size.width
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading + $0.safeAreaInsets.trailing } action: {
                sideInsets = $0
            }
            // With trips, the list says the same
            .accessibilityHidden(hasTrips)
            // New trips, or something opened or closed over them: frame them, wherever the map
            // was moved
            .task(id: Framing(options: options, picked: picked, topInset: topInset, bottomInset: bottomInset,
                              covered: covered, width: width, height: height)) {
                let trips = FramedTrips(options: options, picked: picked)
                // Only the room changed, as the cards over it measure and settle: framed once, when
                // they have, rather than an animation started afresh for each, the map never still
                // long enough to draw its tiles
                if trips == framedTrips {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                }
                // No trips yet, or while the next are planned: New Trip frames the ends
                let area = self.area
                guard hasTrips, !area.isNull else { return }
                // New trips' lines laid out for where they're framed, rather than where the map was
                if trips != framedTrips { linesScale = framedScale }
                framedTrips = trips
                bounds = nil
                // From the ends' framing, on the same map, so nothing to load again on the way
                withAnimation(.smooth) { position = framing(area) }
            }
            // The picked trip's walks along the streets, both asked for at once (cached for the
            // session, so picking a trip again is quick). A train trip's are New Trip's for Go,
            // once it's asked for them; here only if it has none
            .task(id: WalksKey(ends: walkEnds, ahead: aheadWalks, asked: asksWalks)) {
                let ends = walkEnds
                guard pickedWalk == nil, ends.firstStation != nil, !asksWalks || aheadWalks != nil else { return }
                if let aheadWalks, let walks = try? await aheadWalks.value {
                    guard !Task.isCancelled else { return }
                    let joined = { (points: [Walk.Point], from: [Double]?, to: [Double]?) -> [CLLocationCoordinate2D]? in
                        guard !points.isEmpty, let from, let to, from.count == 2, to.count == 2 else { return nil }
                        return [CLLocationCoordinate2D(latitude: from[0], longitude: from[1])] + points.map(\.coordinate)
                            + [CLLocationCoordinate2D(latitude: to[0], longitude: to[1])]
                    }
                    streetWalks = StreetWalks(ends: ends, toTrain: joined(walks.toTrain.points, ends.start, ends.firstStation),
                                              fromTrain: joined(walks.fromTrain.points, ends.lastStation, ends.end))
                    return
                }
                // Not for New Trip's let go, another trip picked
                guard !Task.isCancelled, aheadWalks?.isCancelled != true else { return }
                async let toTrain = Self.streetWalk(from: ends.start, to: ends.firstStation)
                async let fromTrain = Self.streetWalk(from: ends.lastStation, to: ends.end)
                let found = StreetWalks(ends: ends, toTrain: await toTrain, fromTrain: await fromTrain)
                guard !Task.isCancelled else { return }
                streetWalks = found
            }
            // Once framed, it can be moved and zoomed in, but not out or away from the trips, so it
            // only ever loads the trips' area
            .feedsOverlays(.newTrip)
            .onMapCameraChange(frequency: .continuous) { context in
                liveZoom.mapPointsPerPoint = measuredScale(proxy, context)
                if turned.heading.map({ abs(($0 - context.camera.heading + 540).truncatingRemainder(dividingBy: 360) - 180) > 5 })
                    ?? true {
                    turned.heading = context.camera.heading
                }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                // Laid out again only where it's come to rest well off the lines' zoom
                let now = measuredScale(proxy, context)
                liveZoom.mapPointsPerPoint = now
                let scale = LineScale.step(now, from: linesScale ?? framedScale)
                if scale != linesScale { linesScale = scale }
                shownCamera = context.camera
                turned.heading = context.camera.heading
                // Turned by hand: kept, for Nearby's map too, as the compass's turns are
                if position.positionedByUser {
                    let heading = context.camera.heading
                    keptHeading = MapNorth.isOff(heading, from: MapNorth.heading(ny: nyNorth)) ? heading : nil
                }
                rested(context.camera)
                let area = self.area
                guard hasTrips, bounds == nil, !area.isNull,
                      context.rect.insetBy(dx: -area.width * 0.05, dy: -area.height * 0.05).contains(area) else { return }
                // A little further out than it's framed, to see past an end
                bounds = MapCameraBounds(centerCoordinateBounds: area, maximumDistance: context.camera.distance * 1.3)
            }
            // Its own compass, always there; after the map's hiding, which the list stands in for
            .overlay(alignment: .topTrailing) {
                TurnedCompass(turned: turned, turn: turn)
                    .padding(.trailing, 12)
                    .padding(.top, hasTrips ? 0 : before.compassTop)
            }
        }
    }

    /// Map points per screen point on the map now, measured off the map, not from the camera's
    /// distance, which turned (Grid North, or by the compass) was about twice it.
    private func measuredScale(_ proxy: MapProxy, _ context: MapCameraUpdateContext) -> Double {
        MapNorth.mapPointsPerPoint(proxy, middle: CGPoint(x: width / 2, y: height / 2))
            ?? MapNorth.mapPointsPerPoint(context, height: height)
    }

    /// The compass tapped: the map turned `heading` where it is, and framed that way after.
    private func turn(to heading: Double) {
        guard let shownCamera else { return }
        keptHeading = MapNorth.isOff(heading, from: MapNorth.heading(ny: nyNorth)) ? heading : nil
        withAnimation(.smooth) {
            position = .camera(MapCamera(centerCoordinate: shownCamera.centerCoordinate, distance: shownCamera.distance,
                                         heading: heading, pitch: shownCamera.pitch))
        }
    }

    /// Where a ride's bullets go: on its line, with `room` meters from the nearest station
    /// or other dot.
    struct Bullet {
        var coordinate: CLLocationCoordinate2D
        var room: Double
    }

    /// Meters apart a ride's lines may be that are taken to run together: wider than
    /// `alongside`, as express and local tracks' shapes part a little around stations.
    private static let lanesTogether: Double = 150

    /// Meters over which a line moves beside another, or back, where they meet or part.
    private static let laneBlend: Double = 300

    /// For each of `tracks` (a ride's lines), points to the right of each of its points to draw
    /// it: where some run together, each `width` from the next, centred on where they run; on its
    /// own, on its track; blending between over `laneBlend`. Lines of one colour (`colors`, one
    /// for each, if given) aren't beside each other but one line where they run together, each
    /// placed as though the other weren't there, so drawn over each other.
    static func laneOffsets(_ tracks: [[CLLocationCoordinate2D]], colors: [UInt32] = [], width: Double) -> [[Double]] {
        let sameColor = { (a: Int, b: Int) in colors.count == tracks.count && colors[a] == colors[b] }
        let lines = tracks.map { $0.map(MKMapPoint.init) }
        guard lines.count > 1, let somewhere = lines.lazy.compactMap(\.first).first else {
            return lines.map { $0.map { _ in 0 } }
        }
        let perMeter = MKMapPointsPerMeterAtLatitude(somewhere.coordinate.latitude)
        let reach = lanesTogether * perMeter
        let grids = lines.map { SegmentGrid($0, cell: reach) }
        return lines.indices.map { lane in
            let points = lines[lane]
            // Where it'd be at each point: its place among the lines there, left to right as
            // their tracks are, so one whose track runs east of the others is drawn east of them
            // (by the list, the D was drawn west of the N and Q from DeKalb Av to Grand St, as
            // its track went east, and the lines crossed); on the same track, as listed
            let tie = 5 * perMeter
            let target = points.indices.map { index -> Double in
                let point = points[index]
                let before = points[max(0, index - 1)], after = points[min(points.count - 1, index + 1)]
                let dx = after.x - before.x, dy = after.y - before.y, run = hypot(dx, dy)
                var count = 1, place = 0
                for other in lines.indices where other != lane && !sameColor(other, lane) {
                    guard let near = grids[other].nearest(to: point, within: reach) else { continue }
                    count += 1
                    // How far to this line's right the other's track is
                    let right = run > 0 ? ((near.x - point.x) * -dy + (near.y - point.y) * dx) / run : 0
                    if right < -tie || (abs(right) <= tie && other < lane) { place += 1 }
                }
                return (Double(place) - Double(count - 1) / 2) * width
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

    /// Where one of a ride's lines stops at a station: its place in the ride's `tracks`, and
    /// where along its track, `t` of the way along its `segment`th segment.
    struct LaneStop {
        var lane: Int
        var segment: Int
        var t: Double
    }

    /// One of a ride's stations: where each of its lines stopping there stops, and whether the
    /// ride starts or ends there.
    struct StationStop {
        var complex: String
        var lanes: [LaneStop]
        var isStart: Bool
        var isEnd: Bool
    }

    /// `ride`'s stations, those of each of its lines (`Ride.laneStops`), each once with every line
    /// stopping there, the first line's in order first; its stops on its first line where its
    /// lines' stations aren't known, as on a bus.
    static func stationStops(_ ride: SharedTrip.Option.Ride) -> [StationStop] {
        let tracks = ride.tracks.map { $0.map(MKMapPoint.init) }
        let laneStops = ride.laneStops.isEmpty
            ? [ride.stops.map { SharedTrip.Option.Ride.Stop(complex: "\($0.latitude) \($0.longitude)", coordinate: $0) }]
            : ride.laneStops
        var order: [String] = []
        var lanes: [String: [LaneStop]] = [:]
        for lane in laneStops.indices where tracks.indices.contains(lane) {
            for stop in laneStops[lane] {
                guard let at = nearest(on: tracks[lane], to: MKMapPoint(stop.coordinate)) else { continue }
                if lanes[stop.complex] == nil { order.append(stop.complex) }
                lanes[stop.complex, default: []].append(LaneStop(lane: lane, segment: at.segment, t: at.t))
            }
        }
        let first = laneStops.first?.first?.complex, last = laneStops.first?.last?.complex
        return order.map { StationStop(complex: $0, lanes: lanes[$0] ?? [], isStart: $0 == first, isEnd: $0 == last) }
    }

    /// Where on `track` is nearest `point`: `t` of the way along its `segment`th segment.
    private static func nearest(on track: [MKMapPoint], to point: MKMapPoint) -> (segment: Int, t: Double)? {
        guard track.count > 1 else { return track.isEmpty ? nil : (0, 0) }
        var best = (distance: Double.infinity, segment: 0, t: 0.0)
        for index in 0..<(track.count - 1) {
            let a = track[index], b = track[index + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let squared = dx * dx + dy * dy
            let t = squared == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / squared))
            let x = a.x + t * dx - point.x, y = a.y + t * dy - point.y
            if x * x + y * y < best.distance { best = (x * x + y * y, index, t) }
        }
        return (best.segment, best.t)
    }

    /// Where `stop` is as its line's drawn, moved out by its `offsets` (points, one for each of
    /// `track`'s) at `mapPointsPerPoint`, and the way to the line's right there.
    private static func drawn(_ stop: LaneStop, on track: [CLLocationCoordinate2D], offsets: [Double],
                              mapPointsPerPoint: Double) -> (point: MKMapPoint, right: (x: Double, y: Double)) {
        let next = min(track.count - 1, stop.segment + 1)
        let a = MKMapPoint(track[stop.segment]), b = MKMapPoint(track[next])
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        // Map points' y runs south, so east's right is south
        let right = length > 0 ? (x: -dy / length, y: dx / length) : (x: 0.0, y: 0.0)
        let out = offsets.count == track.count
            ? (offsets[stop.segment] * (1 - stop.t) + offsets[next] * stop.t) * mapPointsPerPoint : 0
        return (MKMapPoint(x: a.x + dx * stop.t + right.x * out, y: a.y + dy * stop.t + right.y * out), right)
    }

    /// Points apart lines stopping at a station may be drawn that share its dot: side by side,
    /// with a little to spare. Further, as at platforms a walk apart, each has its own.
    private static let sharedDot: Double = Double(sideBySideWidth) * 1.6
    /// Meters apart lines may stop at a station and share its dot however far it's zoomed in, as
    /// at one platform.
    private static let platformMeters: Double = 25
    /// Points along their lines lines sharing a dot may stop apart.
    private static let sharedAlong: Double = 3

    /// A station's dots across `points` (where each line stopping there is drawn, and its right):
    /// one long across each run of lines side by side, round on a line by itself.
    private static func dots(across points: [(point: MKMapPoint, right: (x: Double, y: Double))], scale: Double,
                             mapPointsPerPoint: Double) -> [StationDot] {
        // Zoomed right in, lines at one platform, whose tracks' shapes start a few meters apart
        let perMeter = points.first.map { MKMapPointsPerMeterAtLatitude($0.point.coordinate.latitude) } ?? 0
        let reach = max(sharedDot * scale * mapPointsPerPoint, platformMeters * perMeter)
        let level = max(sharedAlong * mapPointsPerPoint, platformMeters / 2 * perMeter)
        // Side by side with one of a group's, and level with its first along its line, rather
        // than ahead or behind, where a dot across the line wouldn't reach it
        func joins(_ index: Int, _ group: [Int]) -> Bool {
            let first = points[group[0]], point = points[index].point
            let along = (point.x - first.point.x) * -first.right.y + (point.y - first.point.y) * first.right.x
            // In map points, as `reach` is: `MKMapPoint.distance(to:)` is meters
            return abs(along) <= level && group.contains {
                hypot(points[$0].point.x - point.x, points[$0].point.y - point.y) <= reach
            }
        }
        var groups: [[Int]] = []
        for index in points.indices {
            if let group = groups.firstIndex(where: { joins(index, $0) }) {
                groups[group].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups.map { group in
            // Across the first's line: how far out to its right each is
            let first = points[group[0]], right = first.right
            let outs = group.map { (points[$0].point.x - first.point.x) * right.x + (points[$0].point.y - first.point.y) * right.y }
            let low = outs.min() ?? 0, high = outs.max() ?? 0, middle = (low + high) / 2
            let center = MKMapPoint(x: first.point.x + right.x * middle, y: first.point.y + right.y * middle)
            return StationDot(id: "", coordinate: center.coordinate,
                              mapLength: high - low,
                              angle: atan2(right.y, right.x), changes: false)
        }
    }

    /// The dots of `rides`' stations (`stations`, each ride's), where their lines are drawn
    /// (`laneOffsets`, at `widths`): at each change, one across the lines in and those on, rather
    /// than one for each ride; with `endOnly`, just the one where the last ride ends, as a change.
    private static func stationDots(of rides: [SharedTrip.Option.Ride], laneOffsets: [[[Double]]],
                                    stations: [[StationStop]], endOnly: Bool, widths: Widths,
                                    mapPointsPerPoint: Double, tag: String) -> [StationDot] {
        func points(_ index: Int, _ stop: StationStop) -> [(point: MKMapPoint, right: (x: Double, y: Double))] {
            let offsets = laneOffsets.indices.contains(index) ? laneOffsets[index] : []
            return stop.lanes.map { at in
                drawn(at, on: rides[index].tracks[at.lane],
                      offsets: offsets.indices.contains(at.lane) ? offsets[at.lane] : [],
                      mapPointsPerPoint: mapPointsPerPoint * widths.scale)
            }
        }
        return rides.indices.flatMap { index in
            let stops = stations.indices.contains(index) ? stations[index] : []
            return stops.indices.flatMap { stop -> [StationDot] in
                // Where a ride after starts, with the one before's end
                if stops[stop].isStart && index > 0 { return [] }
                var across = points(index, stops[stop])
                let next = stations.indices.contains(index + 1) ? stations[index + 1].first(where: \.isStart) : nil
                if stops[stop].isEnd, let next { across += points(index + 1, next) }
                let end = stops[stop].isEnd && index == rides.count - 1
                guard !endOnly || end else { return [] }
                let changes = stops[stop].isEnd && (next != nil || endOnly)
                return dots(across: across, scale: widths.scale, mapPointsPerPoint: mapPointsPerPoint).enumerated().map { place in
                    // Each its own id, as one station's lines may stop apart (platforms a walk apart)
                    var dot = place.element
                    dot.id = "\(tag)-\(index)-\(stop)-\(place.offset)"
                    dot.changes = changes
                    return dot
                }
            }
        }
    }

    /// Each of `ride`'s lines as a ride of its own, along its track, as `beside` takes them.
    static func lines(of ride: SharedTrip.Option.Ride) -> [SharedTrip.Option.Ride] {
        ride.tracks.indices.map { lane in
            SharedTrip.Option.Ride(routes: [ride.routes.indices.contains(lane) ? ride.routes[lane] : ride.route],
                                   coordinates: ride.tracks[lane], stops: [], isBus: ride.isBus)
        }
    }

    /// A station's dot as drawn: on its line, or long across lines side by side stopping there.
    private struct StationDot: Identifiable {
        var id: String
        var coordinate: CLLocationCoordinate2D
        /// Map points from one end's middle to the other's, on the ground as the lines are, so it
        /// stays across them as the map's zoomed; none for one line.
        var mapLength: Double
        /// Its turn from lying east to west, as the map's always north up.
        var angle: Double
        var changes: Bool
        /// The other change station it's at, named beside it.
        var name: String?

        /// Its name's id, apart from its own, as MapKit tells all annotations apart by id.
        var nameID: String { "name-" + id }
    }

    /// The map's zoom right now, every frame it moves: map points a point is. Read only by the
    /// stations' dots and names, to keep them across the lines as the map's zoomed, so the map
    /// isn't redrawn for it.
    @Observable final class LiveZoom {
        var mapPointsPerPoint: Double = 0

        /// `mapLength` in points, at the zoom now, or `laidOutAt` before the map's moved.
        func points(_ mapLength: Double, laidOutAt: Double) -> CGFloat {
            let scale = mapPointsPerPoint > 0 ? mapPointsPerPoint : laidOutAt
            return scale > 0 ? CGFloat(mapLength / scale) : 0
        }
    }

    /// Which way the map's turned right now, every 5° or so: read only by its compass
    /// (`TurnedCompass`), as `LiveZoom` is by the dots.
    @Observable final class Turned {
        var heading: Double?
    }

    /// The map's compass, turned with it (`Turned`), Settings' way before it's moved.
    private struct TurnedCompass: View {
        let turned: Turned
        let turn: (Double) -> Void
        @AppStorage(MapNorth.key) private var nyNorth = false

        var body: some View {
            NorthButton(heading: turned.heading ?? MapNorth.heading(ny: nyNorth), turn: turn)
        }
    }

    /// A station's dot: small on the line, larger where it changes, long across lines side by
    /// side, kept across them as the map's zoomed.
    private struct StationDotView: View {
        let dot: StationDot
        let zoom: LiveZoom
        let laidOutAt: Double

        var body: some View {
            let size: CGFloat = dot.changes ? 8 : 4
            Capsule().fill(.white)
                .overlay {
                    if dot.changes { Capsule().stroke(.black.opacity(0.8), lineWidth: 2) }
                }
                .frame(width: size + zoom.points(dot.mapLength, laidOutAt: laidOutAt), height: size)
                .rotationEffect(.radians(dot.angle))
        }
    }

    /// An other change station's name ("or DeKalb Av"), from its dot's middle, clear of the dot
    /// however it's turned.
    private struct StationNameView: View {
        let dot: StationDot
        let zoom: LiveZoom
        let laidOutAt: Double

        var body: some View {
            let size: CGFloat = dot.changes ? 8 : 4
            let long = size + zoom.points(dot.mapLength, laidOutAt: laidOutAt)
            // Half the turned dot's width across the screen
            let half = (long * abs(cos(dot.angle)) + size * abs(sin(dot.angle))) / 2
            Text("or \(dot.name ?? "")")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .fixedSize()
                .padding(.leading, half + 6)
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

    /// `line` moved `distance` map points to its right (left where it's negative), each point
    /// out along between its two sides' normals, so lines side by side stay apart round corners.
    private static func offset(_ line: [CLLocationCoordinate2D], by distance: Double) -> [CLLocationCoordinate2D] {
        guard distance != 0, distance.isFinite else { return line }
        return offset(line, by: Array(repeating: distance, count: line.count))
    }

    /// `line` with each point moved its own distance in `distances` (as many as its points) to
    /// its right, as `offset(_:by:)`.
    static func offset(_ line: [CLLocationCoordinate2D], by distances: [Double]) -> [CLLocationCoordinate2D] {
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

    /// Where your train's ride on to another change station is drawn: `out`, points to the right of each of its
    /// points; `hidden`, whether each is left out, as only over a line already drawn there.
    struct Beside {
        var out: [Double]
        var hidden: [Bool]
        /// The trip's ride it's drawn as, where it's a line changed to of another colour's
        /// line (the N along the Q) and runs along that ride for most of its way: its bullet goes
        /// beside that ride's.
        var joins: Int? = nil
    }

    /// Where each ride of `changes` (each other change station's), one after another, is
    /// drawn: left out where it runs along another station's ride on the same line before it, as
    /// the same track's drawn there already;
    /// otherwise clear of `rides`' lines (and their casing) where it runs along one, and of the
    /// other lines' rides before it where it runs along them too. It comes off and goes back
    /// gradually (`besideSlope`), and from its other change station's dot. Those `onward` (for
    /// each station, each of its rides), a line changed to there, are left out too where they
    /// run along `rides`' own of the same line, as it's drawn there already, or of a train line
    /// the same colour (the N along the Q), as one line with both bullets.
    static func beside(_ changes: [[SharedTrip.Option.Ride]], of rides: [SharedTrip.Option.Ride],
                       onward: [[Bool]] = []) -> [Beside] {
        let others = changes.flatMap { $0 }
        let isOnward = changes.indices.flatMap { index in
            changes[index].indices.map { ride in onward.indices.contains(index) && onward[index].indices.contains(ride)
                && onward[index][ride] }
        }
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
        // Whether a line changed to is drawn as the trip's `solid` line: the same line, or a
        // train line the same colour. Buses are all one blue, so only the same bus
        func joins(_ other: SharedTrip.Option.Ride, _ solid: (ride: Int, route: String, grid: SegmentGrid)) -> Bool {
            other.route == solid.route
                || !other.isBus && !rides[solid.ride].isBus && !rides[solid.ride].isBike
                && LineStyle.of(other.route).color == LineStyle.of(solid.route).color
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
            // For each of the trip's rides, which of these points are drawn as it, another line's
            var drawnAs = rides.map { _ in Set<Int>() }
            // How far out it'd be at each point
            var out = points.indices.map { point -> Double in
                let near = solids.filter { $0.grid.isNear(points[point], within: reach) }
                let dashed = otherGrids.indices.filter {
                    $0 < index && station[$0] != station[index] && otherGrids[$0].isNear(points[point], within: reach)
                }
                // Not along the trip's own line of it, which it carries on from where that ends
                if dashed.contains(where: { others[$0].route == route }) {
                    hidden[point] = true
                    return 0
                }
                if isOnward[index], let solid = near.first(where: { joins(others[index], $0) }) {
                    if solid.route != route { drawnAs[solid.ride].insert(point) }
                    hidden[point] = true
                    return 0
                }
                let solid = near.map { halves[$0.ride] }.max()
                // One lane out at most, as further out they loop round tight curves
                let lines = min(1, Set(dashed.map { others[$0].route }).count)
                guard solid != nil || lines > 0 else { return 0 }
                return (solid.map { $0 + Double(besideWidth) / 2 } ?? 0) + Double(lines) * Double(besideWidth)
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
            // The trip's ride it's drawn as for over half its length, if any
            func meters(_ set: Set<Int>) -> Double {
                set.reduce(0) { sum, point in point + 1 < points.count && set.contains(point + 1)
                    ? sum + points[point].distance(to: points[point + 1]) : sum }
            }
            let length = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            let most = drawnAs.indices.max { meters(drawnAs[$0]) < meters(drawnAs[$1]) }
            let joined = most.flatMap { length > 0 && meters(drawnAs[$0]) > length / 2 ? $0 : nil }
            return Beside(out: out, hidden: hidden, joins: joined)
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
            nearest(to: point, within: reach) != nil
        }

        /// The line's nearest point to `point`, if within `reach` map points (at most a square's side).
        func nearest(to point: MKMapPoint, within reach: Double) -> MKMapPoint? {
            var best: (squared: Double, point: MKMapPoint)?
            let center = square(of: point)
            for x in (center.x - 1)...(center.x + 1) {
                for y in (center.y - 1)...(center.y + 1) {
                    for index in squares[Square(x: x, y: y)] ?? [] {
                        let a = points[index], b = points[index + 1]
                        let dx = b.x - a.x, dy = b.y - a.y
                        let squared = dx * dx + dy * dy
                        let t = squared == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / squared))
                        let near = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
                        let x = near.x - point.x, y = near.y - point.y
                        if x * x + y * y <= reach * reach, x * x + y * y < best?.squared ?? .infinity {
                            best = (x * x + y * y, near)
                        }
                    }
                }
            }
            return best?.point
        }
    }

    /// Meters around the trips and both ends that the map shows, at least.
    private static let margin: Double = 400

    /// What the map covers: `rides` (a trip's, or more) and both ends, a little beyond.
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
        /// A Citi Bike's ride, dock to dock along the streets; `route` is "bike" or "eBike".
        var isBike = false
        /// With `isBike`, your own bike's rather than a Citi Bike's: the tint, not Citi blue.
        var isOwnBike = false
        /// With more than one line, each's own track, the first's first: the N over the
        /// Manhattan Bridge and the R through the Montague St tunnel, side by side where they run
        /// together. Empty with one.
        var lanes: [[CLLocationCoordinate2D]] = []
        /// For each of `routes`, its stations: the express lines of the D, N or R skip some of the
        /// R's. Empty where they aren't known, as on a bus.
        var laneStops: [[Stop]] = []

        /// One of a line's stations, by its complex, to tell where lines stop at the same one.
        struct Stop {
            var complex: String
            var coordinate: CLLocationCoordinate2D
        }

        /// Each line's track, as `lanes`, or the one line's.
        var tracks: [[CLLocationCoordinate2D]] { lanes.isEmpty ? [coordinates] : lanes }

        /// Each of `tracks`' line's colour, for `TripMap.laneOffsets` to draw lines of one as one.
        var laneColors: [UInt32] {
            tracks.indices.map { LineStyle.of(routes.indices.contains($0) ? routes[$0] : route).color }
        }

        /// Whether its lines are of more than one colour, so drawn side by side, narrower.
        var isSideBySide: Bool { Set(laneColors).count > 1 }

        /// Where its bullets go: halfway along a stretch between two of its stations (or along
        /// it, without two), the stretch whose middle is furthest from them and `avoiding`.
        func bulletAt(avoiding: [CLLocationCoordinate2D]) -> TripMap.Bullet? {
            let points = coordinates.map(MKMapPoint.init)
            guard let first = points.first else { return nil }
            guard points.count > 1 else { return TripMap.Bullet(coordinate: first.coordinate, room: 0) }
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
            // The point `distance` along the line
            func point(at distance: Double) -> MKMapPoint {
                let index = max(0, min(points.count - 2, starts.lastIndex { $0 <= distance } ?? 0))
                let length = starts[index + 1] - starts[index]
                let t = length > 0 ? (distance - starts[index]) / length : 0
                let a = points[index], b = points[index + 1]
                return MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            let marks = stops.count > 1 ? stops.map(along).sorted() : [0, starts[starts.count - 1]]
            let avoided = avoiding.map(MKMapPoint.init)
            // Each stretch's middle, and how far it is from its ends and anything avoided
            let middles = zip(marks, marks.dropFirst()).map { from, to in
                let middle = point(at: (from + to) / 2)
                return TripMap.Bullet(coordinate: middle.coordinate,
                                      room: avoided.reduce((to - from) / 2) { min($0, $1.distance(to: middle)) })
            }
            return middles.max { $0.room < $1.room }
        }

        /// The first line.
        var route: String { routes.first ?? "" }

        /// The first line's colour, or the bus's blue.
        var color: Color { color(of: route) }

        /// `route`'s colour, the bus's blue, or Citi Bike's.
        func color(of route: String) -> Color {
            if isBike { return isOwnBike ? .accentColor : .citiBike }
            return isBus ? (BusBadge.isSBS(route) ? BusBadge.sbsBlue : BusBadge.blue) : LineStyle.of(route).swiftUIColor
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
        var complex: String
        var name: String?
        /// Your train on to it from the trip's change, where it's further along (none where your
        /// train passes it on the way there), then the lines changed to there on to the trip's end.
        var rides: [Ride]
        /// How many of `rides` are your train on to it, before the lines changed to.
        var onTo: Int
    }

    /// The trip's other change stations, each with your train on to it past the trip's change,
    /// and the lines changed to there on to the trip's end.
    var otherChanges: [OtherChange] {
        guard let origin = selection.station, let route = selection.routes.first,
              let change, let main = change.station, let last = endStation else { return [] }
        return change.stops.dropFirst().compactMap { stop in
            guard let at = stop.station else { return nil }
            // One of your lines that stops there
            let line = selection.routes.first { !at.platforms(serving: [$0]).isEmpty } ?? route
            let passed = Self.stations(of: line, from: Self.served(by: line, at: origin), to: Self.served(by: line, at: main))
                .contains { $0.complex == at.complex }
            let onTo = passed ? [] : [Self.ride(of: line, from: main, to: at)]
            let onward = stop.routes.first.map { [Self.ride(of: $0, or: stop.routes, from: at, to: last)] } ?? []
            return OtherChange(coordinate: at.coordinate, complex: at.complex,
                               name: at.complex == main.complex ? nil : at.name.mainStationName,
                               rides: onTo + onward, onTo: onTo.count)
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
        // Lines of its colour are drawn as one with it where they run together (`laneOffsets`)
        let lanes = also.isEmpty ? [] : [TripMap.densified(line)] + also.map { other in
            let board = served(by: other, at: origin), alight = served(by: other, at: destination)
            return TripMap.densified(TrackShapes.track(of: other, from: board.coordinate, to: alight.coordinate)
                .map { TrackShapes.rounded($0) } ?? line)
        }
        let laneStops = ([route] + also).map { line in
            Self.stations(of: line, from: served(by: line, at: origin), to: served(by: line, at: destination))
                .map { Ride.Stop(complex: $0.complex, coordinate: $0.coordinate) }
        }
        return Ride(routes: [route] + also, coordinates: line, stops: stations.map { TrackShapes.snapped($0, to: line) },
                    lanes: lanes, laneStops: laneStops)
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
    /// bus, along its street from stop to stop, and its train before or after it, or its second bus.
    var rides: [SharedTrip.Option.Ride] {
        switch self {
        case .train(let option):
            return option.rides
        case .bus(let trip):
            let ride = { (bus: BusRide) in
                let stops = [bus.from, bus.to].map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let path = BusNetwork.path(of: bus.line, from: stops[0], to: stops[1]) ?? stops
                return SharedTrip.Option.Ride(routes: [bus.line], coordinates: path, stops: stops, isBus: true)
            }
            // A second bus after the first, or the train
            let after = trip.onward.map { [ride($0)] } ?? trip.train?.rides ?? []
            return trip.busFirst ? [ride(trip.bus)] + after : after + [ride(trip.bus)]
        case .walk:
            // Nothing to ride: its walk is drawn on its own
            return []
        case .bike(let trip):
            // Along the streets, with no stops: its docks are marked on their own. Your own bike
            // carried on the train may be ridden again after it
            let ride = { (path: [Walk.Point]) in
                SharedTrip.Option.Ride(routes: [trip.kind.rawValue], coordinates: path.map(\.coordinate), stops: [],
                                       isBike: true, isOwnBike: trip.owned)
            }
            let train = trip.train?.rides ?? []
            let after = trip.rideAfter.map { [ride($0.path)] } ?? []
            return trip.bikeFirst ? [ride(trip.path)] + train + after : train + [ride(trip.path)]
        }
    }

    /// A train trip's other change stations (`SharedTrip.Option.otherChanges`); none by bus.
    var otherChanges: [SharedTrip.Option.OtherChange] {
        guard case .train(let option) = self else { return [] }
        return option.otherChanges
    }
}
