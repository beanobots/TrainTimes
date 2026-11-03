import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit

/// The Nearby tab: next trains for every line at nearby stations, and, switched on, the next
/// buses at nearby stops and the bikes at nearby Citi Bike docks.
struct LiveView: View {
    /// Set when the Nearby widget's "allow location" link opens the app.
    @Binding var allowingLocation: Bool
    /// Counts taps on the Nearby tab, each one bringing the map back to you.
    let recenterRequests: Int
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @State private var location = NearbyLocation()
    @State private var path = NavigationPath()
    @State private var live = LiveTrains()
    /// The map's middle once you've moved it, which Nearby lists what's near instead of you
    /// until the Nearby tab (or the note over the map) brings it back.
    @State private var mapCenter: CLLocation?
    /// Where the map last came to rest, to tell a move of more than `followMeters` from it;
    /// and till when a rest is the map settling where `frame()` put it, not you moving it.
    @State private var restCenter: CLLocation?
    @State private var framingUntil = Date.distantPast
    /// Places tapped on the map since it was moved, their tiles saying how far they are from you.
    @State private var revealed: Set<String> = []
    /// Closest stations to `here`, nearest first. Recomputed only when `here` changes,
    /// not on every redraw.
    @State private var nearby: [Nearby.Result] = []
    @State private var camera = MapCameraPosition.userLocation(fallback: .automatic)
    /// The card over the map's bottom, for the map to frame clear of it.
    @State private var cardsHeight: CGFloat = 0
    /// The trains' full height, for the card to be no taller.
    @State private var trainsHeight: CGFloat = 0
    /// What Nearby lists, each a toggle at the foot of its card; all may be off.
    @AppStorage(Self.showsSubwayKey) private var showsSubway = true
    @AppStorage(Self.showsBusesKey) private var showsBuses = false
    /// Citi Bike docks, with the bikes Settings picks (`BikeKinds`): it was two switches, bikes
    /// and e-bikes, either on bringing it on.
    @AppStorage(Self.showsCitiBikeKey) private var showsCitiBike =
        UserDefaults.standard.bool(forKey: BikeKinds.oldNearbyBikesKey) || UserDefaults.standard.bool(forKey: BikeKinds.oldNearbyEBikesKey)
    private static let showsSubwayKey = "nearbyShowsSubway"
    private static let showsBusesKey = "nearbyShowsBuses"
    private static let showsCitiBikeKey = "nearbyShowsCitiBike"
    @AppStorage(BikeKinds.key) private var bikeKinds = BikeKinds.saved
    /// The map mark last tapped, for the card to scroll to its place.
    @State private var focusedMark: String?
    /// Where each place's tile starts in the card's list, by its map mark's id.
    @State private var tileTops: [String: CGFloat] = [:]
    @State private var cardScroll = ScrollPosition()
    /// Blank room under the list, for a place near its end to scroll to the top too; dropped
    /// once scrolled back out of sight.
    @State private var focusRoom: CGFloat = 0
    /// The bus places near `here`, as last loaded.
    @State private var buses: NearbyBusList = .finding
    /// Where `buses` was found from, for a failed refresh to keep them only if still there.
    @State private var busesFrom: CLLocation?
    /// The Citi Bike docks near `here`, nearest first; nil while finding them, and `docksFailed`
    /// if the feed couldn't be had.
    @State private var docks: [NearbyDock]?
    @State private var docksFailed = false
    /// When the last load finished, whatever it loaded.
    @State private var updated: Date?
    /// Each map mark's size as a sign and as a bubble, by its `mapMarks` id, and how each shows
    /// for them all to clear each other (`layOutMarks`).
    @State private var markSizes: [String: CGSize] = [:]
    @State private var bubbleSizes: [String: CGSize] = [:]
    @State private var markLayout = MarkLayout()
    /// When the marks were last laid out as the map moved (`layoutEvery`).
    @State private var laidOut = Date.distantPast
    /// The nearby stations' lines, worked out when the stations change; and a count of each new
    /// set, to tell the map's lines from the last ones'.
    @State private var lines = NearbyLines.none
    /// The other stops along the listed bus stops' lines, every few blocks (`findLines`).
    @State private var alongStops: [AlongStop] = []
    @State private var linesVersion = 0
    /// The map's height, and map points a point is once it last came to rest, to keep lines side
    /// by side the same points apart however far it's zoomed.
    @State private var mapHeight: CGFloat = 0
    @State private var mapWidth: CGFloat = 0
    /// Where the card starts, and the map, on the screen: the bottom of the map that shows.
    @State private var cardTop: CGFloat = 0
    @State private var mapTop: CGFloat = 0
    @State private var mapPointsPerPoint: Double = 0
    /// How much of the map shows, as it last came to rest, for centring on a stop opened.
    @State private var mapSpan: MKCoordinateSpan?
    /// A stop along the lines opened by a tap on its dot: its buses in the card, its lines drawn.
    @State private var openedStop: OpenedStop?
    /// The grey dot at the map's middle, as the map moves: on its own, for only it to redraw
    /// every frame, not the whole page.
    @State private var middle = MapMiddleTracker()
    /// Whether you've moved the map since it was last framed, which alone brings the grey dot.
    @State private var userMovedMap = false

    /// The page's side margin and its card's corners, as New Trip's.
    private static let margin: CGFloat = 16
    private static let card = RoundedRectangle(cornerRadius: 26, style: .continuous)
    /// The status bar's room over the top of the map.
    private static let statusBarRoom: CGFloat = 70
    /// The card's most height, its modes row included, as New Trip's (`NewTripView.cardMax`);
    /// past it the trains scroll within it.
    private static let cardHeight: CGFloat = 250
    /// The modes row's height at the card's foot, as New Trip's.
    private static let modesRowHeight: CGFloat = 58
    /// The margin around the card's list of places, kept over one scrolled to the top.
    private static let tilesMargin: CGFloat = 8
    /// The card's list of places, for each tile to note where it starts.
    private static let tilesSpace = "nearbyTiles"

    /// The map kept on the city, zoomed out no further than New Trip's (`NewTripView.cityBounds`).
    private static let cityBounds = MapCameraBounds(
        centerCoordinateBounds: MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.70, longitude: -73.95),
                                                   span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.6)),
        maximumDistance: 60_000)

    /// How far the map's middle moves, once it comes to rest, for Nearby to list what's there.
    private static let followMeters: Double = 100

    /// The map's middle once moved, or else your location.
    private var here: CLLocation? { mapCenter ?? location.location }

    /// Back to you: the map framed on you again, re-located even if you haven't moved. Times
    /// reload once the nearby stations change.
    private func recenter() {
        revealed = []
        openedStop = nil
        // The grey dot merges back into yours as the map goes back to you
        userMovedMap = false
        let wasMoved = mapCenter != nil
        mapCenter = nil
        location.find()
        if here == nil {
            withAnimation(.smooth) { camera = .userLocation(fallback: .automatic) }
        } else if !wasMoved {
            // Still `here`, so not framed by its change
            frame()
        }
        Task { await load() }
    }

    /// Whether the note over the map shows: the map moved more than 0.15 miles off you.
    private var showsMiddle: Bool {
        guard let mapCenter, let you = location.location else { return false }
        return you.distance(from: mapCenter) > Self.middleMeters
    }

    private static let middleMeters = 0.15 * 1609.344

    /// The map's come to rest at `center`: past `followMeters` from where it last rested, by
    /// your hand rather than `frame()`'s, Nearby lists what's near there.
    private func mapRested(at center: CLLocationCoordinate2D) {
        let middle = CLLocation(latitude: center.latitude, longitude: center.longitude)
        guard let rested = restCenter, Date.now > framingUntil else {
            restCenter = middle
            return
        }
        guard middle.distance(from: rested) > Self.followMeters else { return }
        restCenter = middle
        revealed = []
        mapCenter = middle
    }

    /// A mark tapped on the map: its place to the top of the card, and once the map's moved,
    /// its distance from you on its tile.
    private func tapped(_ id: String) {
        openedStop = nil
        focusedMark = id
        if mapCenter != nil { revealed.insert(id) }
    }

    /// A stop along the lines tapped: its buses in the card, at its top, and its lines drawn on
    /// the map, centred on it. Its place found as Nearby's are, from right where it is.
    private func open(_ stop: AlongStop) {
        openedStop = OpenedStop(id: stop.id, coordinate: stop.coordinate, lines: stop.lines)
        withAnimation(.smooth) { cardScroll.scrollTo(edge: .top) }
        if let mapSpan {
            // Where it comes to rest is where this put it, not a move of yours
            framingUntil = .now.addingTimeInterval(1.5)
            withAnimation(.smooth) { camera = .region(MKCoordinateRegion(center: stop.coordinate, span: mapSpan)) }
        }
        Task { await loadOpened() }
    }

    /// The opened stop's buses, from Bus Time: the place nearest it, if it's that stop.
    private func loadOpened() async {
        guard let opened = openedStop else { return }
        let at = CLLocation(latitude: opened.coordinate.latitude, longitude: opened.coordinate.longitude)
        let place = await NearbyBuses.places(near: at)?.first { place in
            place.ways.contains { CLLocation(latitude: $0.stop.latitude, longitude: $0.stop.longitude).distance(from: at) < Self.openedReach }
        }
        guard openedStop?.id == opened.id else { return }
        if let place {
            openedStop?.place = place
            openedStop?.failed = false
        } else if openedStop?.place == nil {
            openedStop?.failed = true
        }
    }

    /// Meters off Bus Time's stop may be from bus_stops.json's to be taken as it.
    private static let openedReach: Double = 80

    /// A merged bubble tapped: zoomed in round the places it stands for, till they come apart.
    private func zoom(into ids: [String]) {
        let points = mapMarks.filter { ids.contains($0.id) }.map(\.coordinate)
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 2.5, 0.003),
                                   longitudeDelta: max((maxLon - minLon) * 2.5, 0.003)))
        // Where it comes to rest is where the bubble was, not a move of yours to list round
        framingUntil = .now.addingTimeInterval(1.5)
        withAnimation(.smooth) { camera = .region(region) }
    }

    /// How far a place is, for its tile: its walk from you while the map's on you; once moved,
    /// how far it is from you, if it's been tapped on the map; otherwise nothing.
    private func distance(of id: String, walkMinutes: Int, at place: CLLocation) -> NearbyDistance? {
        guard mapCenter != nil else { return .walk(walkMinutes) }
        guard revealed.contains(id), let you = location.location else { return nil }
        return .fromYou(Self.miles(you.distance(from: place)))
    }

    /// "1.2 miles" or "1.9 kilometers", as the phone's set, as the station lists' distances are
    /// (`Nearby.Result.distance`).
    private static func miles(_ meters: Double) -> String {
        let unit: UnitLength = Locale.current.measurementSystem == .metric ? .kilometers : .miles
        return Measurement(value: meters, unit: UnitLength.meters).converted(to: unit)
            .formatted(.measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    /// Every nearby station's trains, fetched together; none with Subway off.
    private var everyTrain: [Selection] {
        showsSubway ? nearby.flatMap(\.station.lineSelections) : []
    }

    /// The bus places listed: up to three, nearest first.
    private var busPlaces: [NearbyBusPlace] { showsBuses ? Array(buses.places.prefix(3)) : [] }
    /// The nearest three docks with the bikes toggled on to take.
    private var shownDocks: [NearbyDock] {
        guard let bikes else { return [] }
        return Array((docks ?? []).filter { bikes.count(at: $0.dock) > 0 }.prefix(3))
    }
    private var bikes: BikeKinds? { showsCitiBike ? bikeKinds : nil }
    private var showsBikes: Bool { bikes != nil }

    /// Restarts loading when any of it changes.
    private var loadKey: LoadKey {
        LoadKey(trains: everyTrain.map(\.trainID), subway: showsSubway, buses: showsBuses, bikes: showsBikes,
                lat: here?.coordinate.latitude, lon: here?.coordinate.longitude)
    }

    private var marks: TimeMarks { settings.timeMarks(withoutColor: withoutColor) }

    var body: some View {
        NavigationStack(path: $path) {
            // As New Trip: the map the whole screen, the stations near you on it, and their
            // trains in a glass card over its bottom
            map
                // Framed clear of the status bar and the card; its logo and Legal over the card
                .safeAreaPadding(.top, Self.statusBarRoom)
                // Half a sign more, as signs sit centred on their places
                .safeAreaPadding(.bottom, cardsHeight + 32)
                .safeAreaPadding(.leading, 12)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .overlay(alignment: .top) { movedNote }
                .overlay(alignment: .bottom) {
                    card
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { cardTop = $0 }
                    .padding(.horizontal, Self.margin)
                    .padding(.bottom, 8)
                }
                // The modes row over the card's foot, on its own so it stays put as the card
                // opens and closes round it
                .overlay(alignment: .bottom) {
                    modesRow
                    .padding(.horizontal, Self.margin)
                    .padding(.bottom, 8)
                }
                .navigationDestination(for: Selection.self) { selection in
                    TrainDetail(selection: selection)
                        // Fresh identity per train; otherwise a page replaced in place would keep
                        // the previous train's state
                        .id(selection.trainID)
                        .toolbar(.visible, for: .navigationBar)
                }
                // No title bar, as New Trip: the tab says where you are
                .toolbar(.hidden, for: .navigationBar)
                .onChange(of: framedIDs, initial: true) { frame() }
                .onChange(of: here) { frame() }
                .onChange(of: showsBuses) {
                    if showsBuses { buses = .finding } else { openedStop = nil }
                }
                .onChange(of: showsBikes) { if showsBikes { docks = nil; docksFailed = false } }
                .onAppear { location.start() }
                .onChange(of: recenterRequests) { recenter() }
                .onChange(of: allowingLocation, initial: true) { _, allowing in
                    guard allowing else { return }
                    allowingLocation = false
                    path = NavigationPath()
                    if location.status == .denied || location.status == .restricted,
                       let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    } else {
                        recenter()
                    }
                }
                .onChange(of: here, initial: true) { _, here in
                    nearby = here.map { Nearby.stations(near: $0, limit: 3) } ?? []
                }
                .onChange(of: linesKey, initial: true) { findLines() }
                // Reload every minute and when the train list changes; pull-to-refresh (in the
                // card) and returning to the app also re-locate (unless the map's been moved)
                .updatingTrains(live, id: loadKey, refreshing: {
                    if location.isAllowed && mapCenter == nil { location.find() }
                }, load: load)
        }
    }

    /// You, the nearby stations as signs, bus stops as their lines and docks with their bikes.
    /// Where they'd overlap, they condense to bubbles by kind, and those to one bubble each
    /// (`layOutMarks`).
    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, bounds: Self.cityBounds) {
                // Under everything else
                NearbyLinesLayer(lines: lines, version: linesVersion, mapPointsPerPoint: mapPointsPerPoint)
                // Your dot, the app's own, to shrink as the grey dot splits off it
                UserAnnotation {
                    MapYouMark(tracker: middle)
                }
                if showsStations && showsSubway {
                    ForEach(nearby) { result in
                        Annotation(result.station.name, coordinate: CLLocationCoordinate2D(latitude: result.station.lat,
                                                                                         longitude: result.station.lon)) {
                            mark("s" + result.id) {
                                MapSign(name: result.station.name, fill: .black) {
                                    ForEach(result.station.routes, id: \.self) { LineBullet(route: $0, size: 15) }
                                }
                            } bubble: { count in
                                MapBubble(fill: .black, symbol: "tram.fill", count: count)
                            }
                            .accessibilityHint("Shows its trains")
                        }
                        // The signs carry their names
                        .annotationTitles(.hidden)
                    }
                }
                if showsStations {
                    let names = busNames
                    ForEach(busPlaces, id: \.self) { place in
                        if let stop = place.ways.first?.stop {
                            let id = "b" + stop.id
                            Annotation(place.name, coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)) {
                                mark(id) {
                                    BusStopMark(name: place.name, lines: names[id])
                                } bubble: { count in
                                    MapBubble(fill: BusBadge.blue, symbol: "bus.fill", count: count)
                                }
                                .opacity(isFaded(place.lines(at: live.mapNow).map(\.line)) ? Self.fadedOpacity : 1)
                                .accessibilityHint("Shows its buses")
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    ForEach(alongStops) { stop in
                        Annotation("Bus stop", coordinate: stop.coordinate) {
                            mark(stop.id) {
                                BusStopMark(name: "Bus stop", lines: names[stop.id], opened: stop.id == openedStop?.id)
                            } bubble: { _ in
                                // Never shown: it hides where its lines don't fit
                                MapBubble(fill: BusBadge.blue, symbol: "bus.fill")
                            }
                            .opacity(isFaded(stop.lines) ? Self.fadedOpacity : 1)
                            .accessibilityHint("Shows its buses")
                        }
                        .annotationTitles(.hidden)
                    }
                    if let bikes {
                        ForEach(shownDocks) { near in
                            Annotation(near.dock.name, coordinate: near.dock.coordinate) {
                                mark("d" + near.id) {
                                    DockMark(dock: near.dock, bikes: bikes)
                                        // Redrawn when its counts change, which the map's marks
                                        // otherwise can miss
                                        .id(bikes.kinds.map { near.dock.available($0) })
                                        // Room round the small pill to tap
                                        .padding(6)
                                        .contentShape(Rectangle())
                                } bubble: { count in
                                    // On its own, its bikes; standing for several, how many docks
                                    MapBubble(fill: .citiBike, symbol: bikes.symbol, count: count,
                                              number: bikes.count(at: near.dock))
                                        .padding(6)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityHint("Shows its bikes")
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                }
            }
            // No businesses or places on it, only its own marks; muted, as New Trip's: the
            // standard map's yellow main roads read as N/Q/R/W lines
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            // A few times a second while it moves, then once more where it stops
            // Every frame, the grey dot kept at the map's middle
            .onMapCameraChange(frequency: .continuous) { context in
                trackMiddle(proxy, center: context.region.center)
            }
            .onMapCameraChange(frequency: .continuous) {
                let now = Date.now
                guard now.timeIntervalSince(laidOut) >= Self.layoutEvery else { return }
                laidOut = now
                layOutMarks(proxy)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                layOutMarks(proxy)
                if mapHeight > 0 { mapPointsPerPoint = context.rect.height / Double(mapHeight) }
                mapSpan = context.region.span
                mapRested(at: context.region.center)
                trackMiddle(proxy, center: context.region.center)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                mapHeight = $0.height
                mapWidth = $0.width
                mapTop = $0.minY
            }
            .overlay {
                MapMiddleOverlay(tracker: middle)
                    .allowsHitTesting(false)
            }
            .onChange(of: markSizes) { layOutMarks(proxy) }
            .onChange(of: bubbleSizes) { layOutMarks(proxy) }
            .onChange(of: framedIDs) { layOutMarks(proxy) }
        }
    }

    /// Where you and the map's middle are as it moves, for the grey dot: split off you once
    /// you've moved the map and its middle is 0.15 miles off you, or your dot nears the edge of
    /// the map that shows; merged back once neither is. A little either way of each, so it
    /// doesn't flicker on and off at the line.
    private func trackMiddle(_ proxy: MapProxy, center: CLLocationCoordinate2D) {
        if !userMovedMap, Date.now > framingUntil { userMovedMap = true }
        let middlePoint = proxy.convert(center, to: .local) ?? CGPoint(x: mapWidth / 2, y: mapHeight / 2)
        guard let you = location.location, userMovedMap else {
            middle.update(you: nil, middle: middlePoint, shows: false)
            return
        }
        let youPoint = proxy.convert(you.coordinate, to: .local)
        let shown = middle.shows
        let meters = you.distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
        let far = meters > Self.middleMeters * (shown ? 0.85 : 1)
        // Clear of the status bar and the card, where it is on the screen
        let bottom = cardTop > mapTop ? cardTop - mapTop : mapHeight
        let seen = CGRect(x: 0, y: Self.statusBarRoom, width: mapWidth, height: max(0, bottom - Self.statusBarRoom))
        // Once split, merged back only a few points further in, not most of the way across
        let inset = shown ? Self.edgeInset + 8 : Self.edgeInset
        let nearEdge = youPoint.map { !seen.insetBy(dx: inset, dy: inset).contains($0) } ?? true
        middle.update(you: youPoint, middle: middlePoint, shows: far || nearEdge)
    }

    /// Points from the edge of the map that shows (the screen's sides, under the status bar,
    /// over the card) your dot brings the grey dot: about its own width, as it reaches the edge.
    private static let edgeInset: CGFloat = 14

    /// How faint the marks and lines not at the opened stop are.
    private static let fadedOpacity = 0.3

    /// Whether a bus stop's mark is faded: with a stop opened, if none of its lines stop there.
    private func isFaded(_ lines: [String]) -> Bool {
        guard let opened = openedStop else { return false }
        return Set(opened.lines.map(TrackShapes.busKey)).isDisjoint(with: lines.map(TrackShapes.busKey))
    }

    /// The lines drawn on the map, as `TrackShapes.busKey` has them: the listed stops', and the
    /// opened stop's.
    private var drawnBusLines: Set<String> {
        Set(busPlaces.flatMap { $0.lines(at: live.mapNow).map { TrackShapes.busKey($0.line) } }
            + (openedStop?.lines.map(TrackShapes.busKey) ?? []))
    }

    /// Each bus stop on the map named with lines, by its mark's id; the rest are dots. Each line
    /// drawn named once, at its stop nearest where Nearby is (you, or the moved map's middle);
    /// the opened stop first, with all its lines.
    private var busNames: [String: [String]] {
        guard let here else { return [:] }
        let drawn = drawnBusLines
        let listed = busPlaces.compactMap { place in
            place.ways.first.map { way in
                (id: "b" + way.stop.id, place: CLLocation(latitude: way.stop.latitude, longitude: way.stop.longitude),
                 lines: place.lines(at: live.mapNow).map(\.line))
            }
        }
        let along = alongStops.map { stop in
            (id: stop.id, place: CLLocation(latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude),
             lines: stop.lines)
        }
        var stops = (listed + along)
            .map { (stop: $0, meters: $0.place.distance(from: here)) }
            .sorted { $0.meters < $1.meters }
            .map(\.stop)
        if let opened = openedStop?.id, let index = stops.firstIndex(where: { $0.id == opened }) {
            stops.insert(stops.remove(at: index), at: 0)
        }
        var names: [String: [String]] = [:]
        var named: Set<String> = []
        for stop in stops {
            var fresh: [String] = []
            for line in stop.lines {
                let key = TrackShapes.busKey(line)
                guard drawn.contains(key), named.insert(key).inserted else { continue }
                fresh.append(line)
            }
            if !fresh.isEmpty { names[stop.id] = fresh }
        }
        return names
    }

    /// A place on the map as `markLayout` has it: its sign, or a bubble standing for it (and
    /// how many it stands for, merged); a tap on a merged one zooms in to part them.
    private func mark(_ id: String, @ViewBuilder sign: () -> some View,
                      @ViewBuilder bubble: @escaping (Int?) -> some View) -> some View {
        MapMark(id: id, layout: markLayout, signSizes: $markSizes, bubbleSizes: $bubbleSizes,
                sign: sign(), bubble: bubble) { merged in
            if let merged {
                zoom(into: merged)
            } else if id.hasPrefix("e") {
                // A stop along the lines has no tile till it's opened
                if let stop = alongStops.first(where: { $0.id == id }) { open(stop) }
            } else {
                tapped(id)
            }
        }
    }

    /// Every mark on the map, most important first: the nearest station, bus stop and dock, then
    /// the next nearest of each, and so on, so each kind shows where there's room for one.
    private var mapMarks: [(id: String, coordinate: CLLocationCoordinate2D)] {
        guard showsStations else { return [] }
        let stations = showsSubway ? nearby.map { ("s" + $0.id, $0.station.coordinate) } : []
        let stops = busPlaces.compactMap { place in
            place.ways.first.map { ("b" + $0.stop.id, CLLocationCoordinate2D(latitude: $0.stop.latitude, longitude: $0.stop.longitude)) }
        }
        let kinds = [stations, stops, shownDocks.map { ("d" + $0.id, $0.dock.coordinate) }]
        let names = busNames
        let opened = alongStops.filter { $0.id == openedStop?.id }
        let along = alongStops.filter { $0.id != openedStop?.id }
        // The opened stop first, as it's what you're looking at
        return opened.map { ($0.id, $0.coordinate) }
            + (0..<(kinds.map(\.count).max() ?? 0)).flatMap { index in
                kinds.compactMap { index < $0.count ? $0[index] : nil }
            }
            // Then the stops along their lines, where there's room: those naming lines first
            + along.filter { names[$0.id] != nil }.map { ($0.id, $0.coordinate) }
            + along.filter { names[$0.id] == nil }.map { ($0.id, $0.coordinate) }
    }

    /// How each mark shows where the map is now, most important first (`mapMarks`) and clear
    /// of those before it: its sign, if that covers no other place; else a bubble on its place;
    /// else merged into a bubble of its kind near enough, that one then standing for both; else
    /// hidden. A sign never covers another place, so places by a station bubble rather than
    /// vanish; but a bus stop's lines show if no mark covers much of them. Where one hides even with bubbles already merged, they're too crowded to show,
    /// and none show.
    private func layOutMarks(_ proxy: MapProxy) {
        let names = busNames
        // A bus stop naming no lines is a dot
        let isDot = { (id: String) in (id.hasPrefix("b") || id.hasPrefix("e")) && names[id] == nil }
        let marks = mapMarks.compactMap { mark -> (id: String, kind: Character, point: CGPoint, sign: CGSize, bubble: CGSize)? in
            guard let sign = markSizes[mark.id], let bubble = bubbleSizes[mark.id], let kind = mark.id.first,
                  let point = proxy.convert(mark.coordinate, to: .local) else { return nil }
            return (mark.id, kind, point, sign, bubble)
        }
        // With a little room round it
        func rect(_ point: CGPoint, _ size: CGSize) -> CGRect {
            CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                .insetBy(dx: -3, dy: -3)
        }
        var placed: [CGRect] = []
        var layout = MarkLayout()
        var groups: [(leader: String, kind: Character, point: CGPoint, members: [String])] = []
        var hiddenAlone = false
        // Each mark's place, once, not again for every mark it's checked against. Stops along
        // the lines don't keep others' signs off their places
        let places = marks.map { $0.kind == "e" || isDot($0.id) ? nil : rect($0.point, $0.bubble) }
        for (index, mark) in marks.enumerated() {
            let sign = rect(mark.point, mark.sign)
            let coversOther = places.indices.contains { $0 != index && places[$0]?.intersects(sign) == true }
            // A bus stop's lines, generously: still shown where they're crowded, if most of them
            // can be seen, and whatever places they cover
            let busFits = (mark.kind == "b" || mark.kind == "e") && placed.allSatisfy { placedRect in
                let overlap = placedRect.intersection(sign)
                return overlap.isNull || overlap.width * overlap.height <= sign.width * sign.height * Self.busOverlap
            }
            // A dot shows where it's clear of everything, and otherwise not at all, as there are
            // so many
            if isDot(mark.id) {
                let clear = !placed.contains { $0.intersects(sign) }
                if clear { placed.append(sign) }
                layout.looks[mark.id] = clear ? .sign : .hidden
                continue
            }
            // A stop along the lines naming some shows them generously, as a listed stop does,
            // and otherwise not at all: never a bubble
            if mark.kind == "e" {
                if busFits { placed.append(sign) }
                layout.looks[mark.id] = busFits ? .sign : .hidden
                continue
            }
            if busFits || (!placed.contains(where: { $0.intersects(sign) }) && !coversOther) {
                placed.append(sign)
                layout.looks[mark.id] = .sign
                continue
            }
            // Bubbles may touch: only a few points' overlap counts
            let bubble = rect(mark.point, mark.bubble).insetBy(dx: 6, dy: 6)
            if !placed.contains(where: { $0.intersects(bubble) }) {
                placed.append(bubble)
                layout.looks[mark.id] = .bubble
                groups.append((mark.id, mark.kind, mark.point, [mark.id]))
                continue
            }
            let near = groups.indices
                .filter { groups[$0].kind == mark.kind }
                .map { ($0, hypot(groups[$0].point.x - mark.point.x, groups[$0].point.y - mark.point.y)) }
                .filter { $0.1 < Self.mergeReach }
                .min { $0.1 < $1.1 }
            if let (group, _) = near {
                groups[group].members.append(mark.id)
            } else {
                hiddenAlone = true
            }
            layout.looks[mark.id] = .hidden
        }
        let merged = groups.filter { $0.members.count > 1 }
        if hiddenAlone && !merged.isEmpty {
            layout = MarkLayout(tooCrowded: true)
        } else {
            for group in merged {
                layout.looks[group.leader] = .merged(group.members)
            }
        }
        if layout != markLayout {
            withAnimation(.easeOut(duration: 0.2)) { markLayout = layout }
        }
    }

    /// Seconds at least between laying the marks out while the map moves: each time is every
    /// mark against every other, on the main thread, and the map moves every frame.
    private static let layoutEvery: TimeInterval = 0.1

    /// How much of a bus stop's lines may be covered by any one mark and still show.
    private static let busOverlap: CGFloat = 0.35

    /// How far off a bubble may be from one of its kind to merge into it, in points.
    private static let mergeReach: CGFloat = 60

    /// The lines of the stations and bus stops listed, for the map, and where they're found
    /// from: the map's middle to about 100 m and the listed stops, which the lines' box and the
    /// stops along them go by.
    private var linesKey: [String] {
        let middle = here.map { String(format: "%.3f,%.3f", $0.coordinate.latitude, $0.coordinate.longitude) } ?? ""
        let routes: [String] = showsSubway ? nearby.flatMap(\.station.routes) : []
        let busLines: [String] = busPlaces.flatMap { $0.lines(at: live.mapNow).map(\.line) }
        let stops: [String] = busPlaces.flatMap { $0.ways.map { "\($0.stop.latitude),\($0.stop.longitude)" } }
        return routes + ["|"] + busLines + ["|", middle] + stops + ["|", openedStop?.id ?? ""]
    }

    /// The listed stations' lines, each its own colour, and the listed bus stops' lines, pale.
    private func findLines() {
        let points = nearby.map { $0.station.coordinate }
            + busPlaces.compactMap { $0.ways.first.map { CLLocationCoordinate2D(latitude: $0.stop.latitude, longitude: $0.stop.longitude) } }
            + [here?.coordinate, openedStop?.coordinate].compactMap { $0 }
        // With a stop opened, its lines too, and the others faded
        let openedLines = openedStop?.lines ?? []
        lines = NearbyLines(routes: showsSubway ? nearby.flatMap(\.station.routes) : [],
                            busLines: busPlaces.flatMap { $0.lines(at: live.mapNow).map(\.line) } + openedLines,
                            brightBusLines: openedStop.map { _ in Set(openedLines.map(TrackShapes.busKey)) },
                            around: points)
        linesVersion += 1
        alongStops = findAlongStops()
    }

    /// A stop along a listed bus stop's lines, marked with its lines but not listed.
    private struct AlongStop: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let lines: [String]
    }

    /// Meters from the map's middle stops along the lines are marked, how far apart those of the
    /// same lines are (about every other block, so each way's stops a block apart are one), and
    /// how many at most, nearest first.
    private static let alongReach: Double = 1500
    private static let alongApart: Double = 150
    /// Meters from a listed stop another isn't marked, as it's the listed one's other way.
    private static let listedApart: Double = 60
    private static let alongMost = 40

    /// The stops along the listed bus stops' lines round the map's middle, but not those listed,
    /// nor the other side of the street from one marked.
    private func findAlongStops() -> [AlongStop] {
        let drawn = drawnBusLines
        guard let center = here, !drawn.isEmpty else { return [] }
        let listed = busPlaces.flatMap { $0.ways.map { CLLocation(latitude: $0.stop.latitude, longitude: $0.stop.longitude) } }
        let degrees = Self.alongReach / Earth.metresPerDegree
        let candidates = TrackShapes.busStops
            .filter { abs($0.coordinate.latitude - center.coordinate.latitude) < degrees
                && abs($0.coordinate.longitude - center.coordinate.longitude) < degrees * 1.4
                && !drawn.isDisjoint(with: $0.lines) }
            .map { stop in
                let place = CLLocation(latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude)
                return (stop: stop, place: place, meters: place.distance(from: center))
            }
            .filter { $0.meters < Self.alongReach }
            // Each one's distance worked out once, not again in every comparison
            .sorted { $0.meters < $1.meters }
        var kept: [(stop: TrackShapes.BusStop, place: CLLocation)] = []
        // The opened stop kept, wherever it is
        if let opened = openedStop {
            let place = CLLocation(latitude: opened.coordinate.latitude, longitude: opened.coordinate.longitude)
            kept.append((TrackShapes.BusStop(coordinate: opened.coordinate, lines: opened.lines), place))
        }
        for (stop, place, _) in candidates where kept.count < Self.alongMost {
            guard !listed.contains(where: { $0.distance(from: place) < Self.listedApart }),
                  !kept.contains(where: { $0.place.distance(from: place) < 1 }),
                  !kept.contains(where: { $0.stop.lines == stop.lines && $0.place.distance(from: place) < Self.alongApart }) else { continue }
            kept.append((stop, place))
        }
        return kept.map { stop, _ in
            AlongStop(id: "e\(stop.coordinate.latitude),\(stop.coordinate.longitude)", coordinate: stop.coordinate, lines: stop.lines)
        }
    }

    /// Everything on the map, to frame it again when they change.
    private var framedIDs: [String] { mapMarks.map(\.id).filter { !$0.hasPrefix("e") } }

    /// Frames you and the nearby stations; just you before there are any. Not once you've moved
    /// the map, which stays where you put it.
    private func frame() {
        // Everything toggled off: leave the map where it is
        guard mapCenter == nil, let here, showsSubway || showsBuses || showsBikes else { return }
        let stations = showsSubway ? nearby.map { $0.station.coordinate } : []
        let stops = busPlaces.compactMap { $0.ways.first.map { CLLocationCoordinate2D(latitude: $0.stop.latitude, longitude: $0.stop.longitude) } }
        let points = [here.coordinate] + stations + stops + shownDocks.map(\.dock.coordinate)
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return }
        // Room round the edges, and at least a few blocks across
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            // Room enough for the signs, which sit centred on their places, to clear the edges
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.004),
                                   longitudeDelta: max((maxLon - minLon) * 1.4, 0.004)))
        // Where it comes to rest is where this put it, not a move of yours
        framingUntil = .now.addingTimeInterval(1.5)
        userMovedMap = false
        withAnimation(.smooth) { camera = .region(region) }
    }

    /// Once the map's been moved off you, how far its middle is from you, over the map's top;
    /// tapped, back to you, as the Nearby tab does. Only past 0.15 miles off, so a nudge of the
    /// map doesn't bring it up.
    @ViewBuilder private var movedNote: some View {
        if showsMiddle, let mapCenter, let you = location.location {
            Button(action: recenter) {
                Label("\(Self.miles(you.distance(from: mapCenter))) from you. Tap to recenter.", systemImage: "location.fill")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.top, 8)
            .transition(.opacity)
        }
    }

    /// Turns off every kind Nearby lists but `on`, for a long press on it.
    private func showOnly(_ on: Binding<Bool>) {
        showsSubway = false
        showsBuses = false
        showsCitiBike = false
        on.wrappedValue = true
        onlyShown += 1
    }

    /// Bumped by `showOnly`, for its tap of feedback.
    @State private var onlyShown = 0
    /// Set as a long press shows only one kind, so letting go doesn't toggle it back off.
    @State private var heldMode = false

    /// What Nearby lists, at the card's foot as New Trip's ways to go: Subway, Bus and Citi Bike
    /// each a toggle (the bikes counted are Settings' pick), then when it last loaded. All off
    /// leaves just the row. A long press on a toggle shows only that kind.
    private var modesRow: some View {
        HStack(spacing: 8) {
            modeToggle("Subway", symbol: "tram.fill", on: $showsSubway, hint: "Shows stations nearby")
            modeToggle("Bus", symbol: "bus.fill", on: $showsBuses, hint: "Shows bus stops nearby")
            modeToggle("Citi Bike", symbol: "bicycle", on: $showsCitiBike, hint: "Shows Citi Bike docks nearby",
                       eBike: bikeKinds == .eBike)
            Spacer(minLength: 0)
            if let updated, listing {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Self.margin)
        .frame(height: Self.modesRowHeight)
        .sensoryFeedback(.selection, trigger: onlyShown)
    }

    /// What Nearby lists, an icon tinted while it's on, as New Trip's, a bolt badge on it for
    /// e-bikes only; a long press on it shows only it.
    private func modeToggle(_ name: String, symbol: String, on: Binding<Bool>, hint: String,
                            eBike: Bool = false) -> some View {
        Button {
            guard !heldMode else {
                heldMode = false
                return
            }
            on.wrappedValue.toggle()
        } label: {
            Label(name, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on.wrappedValue ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 48, height: 38)
                .background(on.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .eBikeBadge(eBike)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture().onEnded { _ in
            heldMode = true
            showOnly(on)
        })
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
        .accessibilityHint(hint)
        .accessibilityAction(named: "Only \(name)") { showOnly(on) }
    }

    /// Whether there are stations, stops or docks to list, rather than why not.
    private var listing: Bool {
        showsStations && (showsSubway && !nearby.isEmpty || showsBuses || showsBikes)
    }

    /// The trains at each nearby station, the buses at each stop and the bikes at each dock,
    /// scrolling within the card past `cardHeight`, or, with none to show, why, with what to do
    /// about it, at its full height so its buttons show; room for the modes row at its foot,
    /// drawn over it on its own. All toggled off, just the row's room. It opens up out of the
    /// row and closes back down into it.
    private var card: some View {
        VStack(spacing: 0) {
            if cardPanel != nil {
                panel
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
            }
            Color.clear.frame(height: Self.modesRowHeight)
        }
        .clipShape(Self.card)
        .glassEffect(.regular, in: Self.card)
        .animation(.smooth, value: cardPanel)
        // The list's height, once measured, grows and shrinks the card smoothly too
        .animation(.smooth, value: trainsHeight)
    }

    /// What the card shows over the modes row, if anything.
    private enum CardPanel: Equatable {
        case crowded, list, empty
    }

    private var cardPanel: CardPanel? {
        if listing && markLayout.tooCrowded { .crowded }
        else if listing { .list }
        else if showsSubway || showsBuses || showsBikes { .empty }
        else { nil }
    }

    @ViewBuilder private var panel: some View {
        VStack(spacing: 0) {
            if listing && markLayout.tooCrowded {
                ContentUnavailableView {
                    Label("Zoom In to See What's Nearby", systemImage: "plus.magnifyingglass")
                } description: {
                    Text("Zoomed out this far, there's too much to show.")
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
            } else if listing {
                ScrollView {
                    VStack(spacing: 0) {
                        trains
                            .coordinateSpace(.named(Self.tilesSpace))
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { trainsHeight = $0 }
                        Color.clear.frame(height: focusRoom)
                    }
                }
                .scrollPosition($cardScroll)
                // A tap on a map mark brings its place to the top of the card, keeping the
                // list's top margin over it, with room under the list for one near its end
                .onChange(of: focusedMark) { _, mark in
                    guard let mark else { return }
                    focusedMark = nil
                    let shown = Self.cardHeight - Self.modesRowHeight
                    guard trainsHeight > shown, let top = tileTops[mark] else { return }
                    let target = max(0, top - Self.tilesMargin)
                    focusRoom = max(0, shown - (trainsHeight - target))
                    withAnimation(.smooth) { cardScroll.scrollTo(y: target) }
                }
                .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY > trainsHeight + 0.5 } action: { roomShown, shows in
                    if roomShown && !shows { focusRoom = 0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(trainsHeight, Self.cardHeight - Self.modesRowHeight))
                Divider()
            } else if showsSubway || showsBuses || showsBikes {
                emptyState
                    .padding(.vertical, 16)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
        }
    }

    /// Any failure note, then each station, bus stop and dock as a tile of its own (stations
    /// first, then stops, then docks).
    private var trains: some View {
        VStack(spacing: 8) {
            if live.anyFailed(everyTrain) {
                UnreachableNote(timetable: live.anyFromTimetable(everyTrain))
                    .font(.subheadline)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }
            if let openedStop { openedTile(openedStop) }
            if showsSubway {
                // Identified as their map marks are, for a tap on one to scroll here
                ForEach(nearby, id: \.markID) { result in
                    NearbyTile(symbol: "tram.fill", kind: "Station", name: result.station.name,
                               distance: distance(of: result.markID, walkMinutes: result.walkMinutes,
                                                  at: result.station.location)) {
                        ForEach(result.station.routes, id: \.self) { route in
                            NearbyLineRow(station: result.station, route: route, live: live, marks: marks) { path.append($0) }
                        }
                    }
                    .notingTop(of: result.markID, in: $tileTops)
                }
            }
            if showsBuses { busTiles }
            if showsBikes { dockTiles }
            if !SharedStore.isAvailable {
                Label("The widget can't see your choice on this install, so it keeps showing 14 St-Union Sq (N Q R W) uptown. Make sure the app and widget both have the App Group in Xcode, then reinstall.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
            }
        }
        .padding(Self.tilesMargin)
    }

    /// Each nearby bus place's lines with their next buses each way; or, with none, why.
    @ViewBuilder private var busTiles: some View {
        switch buses {
        case .finding:
            NearbyNoteTile(symbol: "bus.fill", text: "Finding bus stops…", finding: true)
        case .unavailable:
            NearbyNoteTile(symbol: "bus.fill", text: "Bus times aren't available right now.")
        case .places(let places) where places.isEmpty:
            NearbyNoteTile(symbol: "bus.fill", text: "No bus stops within ¼ mile.")
        case .places:
            ForEach(busPlaces, id: \.self) { place in
                let stop = place.ways.first?.stop
                NearbyTile(symbol: "bus.fill", kind: "Bus stop", name: place.name,
                           distance: distance(of: "b" + (stop?.id ?? ""), walkMinutes: place.walkMinutes,
                                              at: CLLocation(latitude: stop?.latitude ?? 0, longitude: stop?.longitude ?? 0))) {
                    NearbyBusLines(place: place, live: live, marks: marks)
                }
                .notingTop(of: "b" + (place.ways.first?.stop.id ?? ""), in: $tileTops)
            }
        }
    }

    /// The stop opened from its dot, first in the card: its buses, as a listed stop's, and a
    /// button to close it.
    private func openedTile(_ opened: OpenedStop) -> some View {
        let at = CLLocation(latitude: opened.coordinate.latitude, longitude: opened.coordinate.longitude)
        let distance: NearbyDistance? = location.location.map { you in
            mapCenter == nil ? .walk(TripPlanner.walkMinutes(you.distance(from: at))) : .fromYou(Self.miles(you.distance(from: at)))
        }
        return NearbyTile(symbol: "bus.fill", kind: "Bus stop", name: opened.place?.name ?? "Bus Stop", distance: distance,
                          close: { withAnimation(.smooth) { openedStop = nil } }) {
            if let place = opened.place {
                NearbyBusLines(place: place, live: live, marks: marks)
            } else if opened.failed {
                Text("Bus times aren't available right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }
    }

    /// The nearest docks with the bikes toggled on, and how many; or, with none, why.
    @ViewBuilder private var dockTiles: some View {
        if docksFailed {
            NearbyNoteTile(symbol: "bicycle", text: "Citi Bike isn't available right now.")
        } else if docks != nil, let bikes {
            if shownDocks.isEmpty {
                NearbyNoteTile(symbol: bikes.symbol, text: "No docks with \(bikes == .eBike ? "e-bikes" : "bikes") within ½ mile.")
            }
            ForEach(shownDocks, id: \.markID) { near in
                NearbyTile(symbol: bikes.symbol, kind: "Citi Bike dock", name: near.dock.name,
                           distance: distance(of: near.markID, walkMinutes: near.walkMinutes, at: near.dock.location)) {
                    NearbyDockCounts(dock: near.dock, bikes: bikes)
                }
                .notingTop(of: near.markID, in: $tileTops)
            }
        } else {
            NearbyNoteTile(symbol: "bicycle", text: "Finding Citi Bike docks…", finding: true)
        }
    }

    /// Whether there's a place to list stations near: the moved map's middle, or your location
    /// once found.
    private var showsStations: Bool {
        mapCenter != nil || (location.isAllowed && !location.failed && location.location != nil)
    }

    /// Why there are no station cards, with what to do about it.
    @ViewBuilder private var emptyState: some View {
        if mapCenter != nil {
            ContentUnavailableView {
                Label("No Stations Here", systemImage: "map")
            } description: {
                Text("No stations within \(Nearby.rangeDescription) of the map's middle.")
            }
        } else if location.status == .notDetermined {
            ContentUnavailableView {
                Label("Trains Near You", systemImage: "location.fill")
            } description: {
                Text("See the next trains at the stations closest to you, or move the map to see them anywhere.")
            } actions: {
                Button("Allow Location") { location.find() }
                    .buttonStyle(.glassProminent)
            }
        } else if !location.isAllowed {
            ContentUnavailableView {
                Label("Location Is Off", systemImage: "location.slash")
            } description: {
                Text("Turn on Location for Leeway in Settings, or move the map to see trains near somewhere else.")
            } actions: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Turn On in Settings", destination: url)
                        .buttonStyle(.glassProminent)
                }
            }
        } else if location.failed {
            ContentUnavailableView {
                Label("Couldn't Find You", systemImage: "location.slash")
            } description: {
                Text("Your location isn't available right now.")
            } actions: {
                Button("Try Again") { location.find() }
                    .buttonStyle(.glassProminent)
            }
        } else if location.location == nil {
            ProgressView("Finding stations near you…")
        } else {
            ContentUnavailableView {
                Label("No Stations Nearby", systemImage: "tram")
            } description: {
                Text("No stations within \(Nearby.rangeDescription) of you.")
            }
        }
    }

    /// Loads what's switched on together. Rows show a dash until their first load.
    private func load() async {
        let trains = everyTrain
        let wantsBuses = showsBuses, wantsBikes = showsBikes
        let here = here
        async let busPlaces: [NearbyBusPlace]? = if wantsBuses, let here { await NearbyBuses.places(near: here) } else { nil }
        async let allDocks: [CitiBike.Dock]? = wantsBikes && here != nil ? await CitiBike.docks() : nil
        // Nearby rows show only the line's own trains, which are all in its own feeds
        async let opened: Void = loadOpened()
        await live.load(trains, includingOtherLines: false)
        let places = await busPlaces, found = await allDocks
        await opened
        guard !Task.isCancelled else { return }
        // Loads not cancelled by a move (recentering, coming back to the app) may finish after
        // the one for where Nearby is now: not stops and docks near where it was
        if let now = self.here, let here, now.distance(from: here) > Self.followMeters { return }
        if wantsBuses, let here {
            if let places {
                buses = .places(places)
                busesFrom = here
            } else {
                // A failed refresh keeps the stops last found, rather than dropping them; not
                // once the map's moved on, where they'd be listed as near somewhere they aren't
                let samePlace = busesFrom.map { $0.distance(from: here) <= Self.followMeters } ?? false
                buses = buses.places.isEmpty || !samePlace ? .unavailable : buses
            }
        }
        if wantsBikes, let here {
            docksFailed = found == nil
            // All within range: the toggles pick which three show
            docks = found.map { NearbyDock.nearest(to: here, among: $0, limit: 40) }
        }
        updated = .now
    }
}

extension Nearby.Result {
    /// Its map mark's and card tile's id.
    fileprivate var markID: String { "s" + id }
}

extension NearbyDock {
    fileprivate var markID: String { "d" + id }
}

extension View {
    /// Notes where this tile starts in the card's list, under its map mark's id.
    fileprivate func notingTop(of id: String, in tops: Binding<[String: CGFloat]>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("nearbyTiles")).minY } action: {
            tops.wrappedValue[id] = $0
        }
    }
}

/// What restarts Nearby's loading: its trains, what's switched on, and where it's near.
private struct LoadKey: Equatable {
    var trains: [String]
    var subway: Bool
    var buses: Bool
    var bikes: Bool
    var lat: Double?
    var lon: Double?
}

/// A Citi Bike dock near Nearby's place.
struct NearbyDock: Identifiable, Hashable {
    let dock: CitiBike.Dock
    let meters: Double

    var id: String { dock.id }
    var walkMinutes: Int { TripPlanner.walkMinutes(meters) }

    /// Beyond this (about half a mile), no docks are listed.
    private static let range: Double = 800

    /// Up to `limit` docks within `range` of `location`, nearest first.
    static func nearest(to location: CLLocation, among docks: [CitiBike.Dock], limit: Int = 3) -> [NearbyDock] {
        docks.map { NearbyDock(dock: $0, meters: location.distance(from: $0.location)) }
            .filter { $0.meters <= range }
            .sorted { $0.meters < $1.meters }
            .prefix(limit)
            .map { $0 }
    }
}

/// How far a place in Nearby's card is.
private enum NearbyDistance {
    /// Minutes' walk from you
    case walk(Int)
    /// "1.2 miles"
    case fromYou(String)
}

/// One station, bus stop or dock in Nearby's card, a tile of its own so each is clearly apart
/// from the next: what it is and its name over its walk, then its rows.
private struct NearbyTile<Content: View>: View {
    let symbol: String
    /// "Station", "Bus stop": said by VoiceOver, shown as the icon.
    let kind: String
    let name: String
    /// Its walk, or how far it is from you; nil, neither.
    let distance: NearbyDistance?
    /// Closes it, for a stop opened from the map; nil, it can't be.
    var close: (() -> Void)? = nil
    @ViewBuilder let content: Content

    private var spokenDistance: String {
        switch distance {
        case .walk(let minutes): ", \(minutes) minute walk"
        case .fromYou(let miles): ", \(miles) from you"
        case nil: ""
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(name)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Group {
                    switch distance {
                    case .walk(let minutes): Label("\(minutes) min", systemImage: "figure.walk")
                    case .fromYou(let miles): Label(miles, systemImage: "location.fill")
                    case nil: EmptyView()
                    }
                }
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind), \(name)\(spokenDistance)")
            .accessibilityAddTraits(.isHeader)
            // Beside the heading, apart from it for VoiceOver
            .padding(.trailing, close == nil ? 0 : 34)
            .overlay(alignment: .topTrailing) {
                if let close {
                    Button("Close", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.fill.tertiary, in: Circle())
                        .buttonStyle(.plain)
                        .offset(y: -2)
                }
            }
            content
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A tile saying why there's no bus stop or dock to list, or that they're being found.
private struct NearbyNoteTile: View {
    let symbol: String
    let text: String
    var finding = false

    var body: some View {
        HStack(spacing: 8) {
            if finding {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).font(.caption.weight(.bold))
            }
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// One bus line at a stop with its next buses each way, as `NearbyLineRow` has a train's.
/// A bus stop tile's lines, by the buses still due: its own view, so the ticks that count them
/// down redraw it alone, not the whole page and its map.
private struct NearbyBusLines: View {
    let place: NearbyBusPlace
    let live: LiveTrains
    let marks: TimeMarks

    var body: some View {
        let lines = place.lines(at: live.now)
        if lines.isEmpty {
            Text("No buses due").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
        ForEach(lines, id: \.line) { pick in
            NearbyBusRow(pick: pick, now: live.now, marks: marks)
        }
    }
}

private struct NearbyBusRow: View {
    let pick: NearbyBusPick
    let now: Date
    let marks: TimeMarks

    var body: some View {
        HStack(spacing: 22) {
            BusBadge(line: pick.line, size: 30)
                .frame(width: 44)
            VStack(spacing: 0) {
                ForEach(Array(pick.ways.enumerated()), id: \.element.stop.id) { index, way in
                    if index > 0 {
                        Divider().padding(.vertical, 8)
                    }
                    let buses = way.arrivals.compactMap { bus in
                        bus.time.flatMap { $0 > now ? Arrival(route: pick.line, time: $0, stop: way.stop.id,
                                                              lastStop: bus.destination ?? "", isLive: bus.isLive) : nil }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(way.name).lineLimit(1)
                            if let stops = way.arrivals.first?.stopsAway {
                                Text(stops == 1 ? "1 stop away" : "\(stops) stops away")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        Minutes(trains: buses, failed: false, now: now, marks: marks, none: "No buses")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(BusBadge.spokenName(pick.line)) to \(way.name)")
                    .accessibilityValue(Minutes.spoken(buses, now: now))
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Which Citi Bikes you'll ride, as Settings picks: Nearby counts them at a dock, and New Trip
/// plans trips on them. Free docks aren't shown on Nearby: they matter once you're riding,
/// which New Trip's bike trips show.
enum BikeKinds: String, CaseIterable {
    case bike
    case eBike
    case both

    /// Where the pick is kept.
    static let key = "bikeKinds"
    /// Whether Settings has both Citi Bike tiles off: New Trip offers no Citi Bike then (Nearby
    /// still counts these). The kinds are kept as they were, for turning one on again.
    static let offKey = "citiBikeOff"
    /// Where it was before Settings had it: New Trip's old Bike menu, and Nearby's two switches.
    static let oldTripKey = "tripBike"
    static let oldNearbyBikesKey = "nearbyShowsBikes"
    static let oldNearbyEBikesKey = "nearbyShowsEBikes"
    /// What it was before Settings had it: from New Trip's old Bike menu, or Nearby's.
    static var saved: BikeKinds {
        let defaults = UserDefaults.standard
        if let trip = defaults.string(forKey: oldTripKey), let kind = BikeKinds(rawValue: trip) { return kind }
        switch (defaults.bool(forKey: oldNearbyBikesKey), defaults.bool(forKey: oldNearbyEBikesKey)) {
        case (true, false): return .bike
        case (false, true): return .eBike
        default: return .both
        }
    }

    var name: String {
        switch self {
        case .bike: "Bikes"
        case .eBike: "E-Bikes"
        case .both: "Both"
        }
    }

    var symbol: String { self == .eBike ? "bolt.fill" : "bicycle" }

    /// The bikes of this kind to take at `dock`.
    func count(at dock: CitiBike.Dock) -> Int {
        switch self {
        case .bike: dock.available(.bike)
        case .eBike: dock.available(.eBike)
        case .both: dock.available(.bike) + dock.available(.eBike)
        }
    }

    var kinds: [CitiBike.Kind] {
        switch self {
        case .bike: [.bike]
        case .eBike: [.eBike]
        case .both: [.bike, .eBike]
        }
    }
}

/// A dock's bikes, e-bikes or both side by side, as the Citi Bike menu picks.
private struct NearbyDockCounts: View {
    let dock: CitiBike.Dock
    let bikes: BikeKinds

    var body: some View {
        HStack(spacing: 0) {
            ForEach(bikes.kinds, id: \.self) { kind in
                count(dock.available(kind), kind.name + "s", symbol: kind == .eBike ? "bolt.fill" : "bicycle")
            }
        }
        .padding(.vertical, 6)
    }

    private func count(_ number: Int, _ name: String, symbol: String) -> some View {
        VStack(spacing: 2) {
            Text("\(number)")
                .font(.title3.weight(.bold))
                .monospacedDigit()
            Label(name, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number) \(name)")
    }
}

/// A station on Nearby's map, as a station sign: the name in white on `fill` over its
/// bullets, a white rule along the top.
private struct MapSign<Marks: View>: View {
    let name: String
    let fill: Color
    @ViewBuilder let marks: Marks

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 2) { marks }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(.white).frame(height: 1).padding(.horizontal, 6).padding(.top, 2)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .fixedSize()
    }
}

/// A bus stop on Nearby's map: the lines it's named with (`busNames`) in a bus blue pill, small
/// enough that stops a block apart don't crowd each other off, or, naming none, a small bus blue
/// dot. Opened, it's bigger, its edge thicker. Its name is on its tile.
private struct BusStopMark: View {
    let name: String
    /// Nil, a dot.
    let lines: [String]?
    var opened = false

    var body: some View {
        Group {
            if let lines {
                HStack(spacing: 2) {
                    ForEach(lines, id: \.self) { MapSignBusBadge(line: $0) }
                }
                .padding(3)
                .background(BusBadge.blue, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.white, lineWidth: opened ? 2.5 : 1.5))
                .shadow(color: .black.opacity(opened ? 0.45 : 0.3), radius: opened ? 5 : 2, y: 1)
                .scaleEffect(opened ? 1.25 : 1)
                .animation(.smooth, value: opened)
            } else {
                Circle()
                    .fill(BusBadge.blue)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    // Room round it to tap
                    .padding(6)
                    .contentShape(Rectangle())
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue((lines ?? []).map(BusBadge.spokenName).joined(separator: ", "))
    }
}

/// A stop along the lines opened from its dot on Nearby's map, and its buses once found.
private struct OpenedStop: Equatable {
    /// Its map mark's id.
    let id: String
    let coordinate: CLLocationCoordinate2D
    /// The lines stopping there, as bus_stops.json has them.
    let lines: [String]
    var place: NearbyBusPlace?
    var failed = false

    static func == (a: OpenedStop, b: OpenedStop) -> Bool {
        a.id == b.id && a.place == b.place && a.failed == b.failed
    }
}

/// Where you and the map's middle are on Nearby's map as it moves, and how far the grey dot's
/// split off you: 0 at you, 1 at the middle, animated as it splits off or merges back.
@MainActor @Observable
private final class MapMiddleTracker {
    private(set) var you: CGPoint?
    private(set) var middle: CGPoint = .zero
    private(set) var progress: Double = 0
    /// Whether it's showing, or splitting off; not as it merges back.
    private(set) var shows = false

    func update(you: CGPoint?, middle: CGPoint, shows: Bool) {
        if self.you != you { self.you = you }
        if self.middle != middle { self.middle = middle }
        guard shows != self.shows else { return }
        self.shows = shows
        withAnimation(.linear(duration: shows ? 0.7 : 0.45)) {
            progress = shows ? 1 : 0
        }
    }
}

/// The grey dot, wherever the map's middle is as it moves, splitting off your dot or merging
/// back into it; where you're not on the map, coming and going on its own. Always there,
/// drawing nothing at 0, for it to animate from where it was: one just added would show at
/// once where it ends.
private struct MapMiddleOverlay: View {
    let tracker: MapMiddleTracker

    var body: some View {
        if let you = tracker.you {
            MapMiddleSplit(you: you, middle: tracker.middle, progress: tracker.progress)
        } else {
            MapMiddleDot(radius: MapMiddleSplit.greyRadius(1))
                .position(tracker.middle)
                .opacity(tracker.progress)
        }
    }
}

/// Where Nearby measures nearest from once the map's moved off you: a grey dot at its middle,
/// `radius` points across its grey.
private struct MapMiddleDot: View {
    let radius: CGFloat

    var body: some View {
        Circle()
            .fill(Color(.systemGray))
            .frame(width: radius * 2, height: radius * 2)
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}

/// Your location on Nearby's map, as the grey dot splits off it: a blue dot drawn out towards
/// the map's middle as the neck pulls, wobbling back once it lets go, and shrinking as the grey
/// dot grows, so it reads as the smaller once they're apart.
private struct MapYouMark: View {
    let tracker: MapMiddleTracker

    var body: some View {
        let angle = tracker.you.map { you in
            Angle(radians: atan2(tracker.middle.y - you.y, tracker.middle.x - you.x))
        } ?? .zero
        MapYouDot(progress: tracker.progress, angle: angle)
    }
}

private struct MapYouDot: View, Animatable {
    var progress: Double
    let angle: Angle

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let pulling = progress < 0.4
        let t = pulling ? progress / 0.4 : (progress - 0.4) / 0.6
        let stretch = pulling
            ? 1 + 0.18 * t * t * (3 - 2 * t)
            : 1 + 0.18 * cos(t * .pi * 3) * pow(1 - t, 2)
        Circle()
            .fill(Color(.systemBlue))
            .frame(width: MapMiddleSplit.youFill * 2, height: MapMiddleSplit.youFill * 2)
            .overlay(Circle().stroke(.white, lineWidth: MapMiddleSplit.youEdge))
            .shadow(color: .black.opacity(0.3), radius: 3)
            .scaleEffect(x: stretch, y: 1 / stretch)
            .rotationEffect(angle)
            .scaleEffect(MapMiddleSplit.youScale(progress))
            // Room for its edge, which the stroke draws outside the fill only by half
            .padding(MapMiddleSplit.youEdge)
            .accessibilityLabel("Your location")
    }
}

/// The grey dot dividing off your location's, like a cell, at `progress` 0 to 1 (or back,
/// merging): a gooey neck pulls out from under your dot (to 0.4), narrowing at its waist till it
/// pinches off; then the grey dot springs out to the map's middle, overshooting a little, and
/// grows as your dot (`MapYouDot`, drawn by the map) shrinks. Your dot is left uncovered.
private struct MapMiddleSplit: View, Animatable {
    let you: CGPoint
    let middle: CGPoint
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// How far out the neck pulls before it pinches off, in points.
    private static let pull: CGFloat = 26
    /// Your dot's blue and white edge, before it shrinks.
    static let youFill: CGFloat = 10
    static let youEdge: CGFloat = 3.5

    /// How big your dot is, `progress` split off: down to two thirds once apart.
    static func youScale(_ progress: Double) -> CGFloat { 1 - 0.35 * min(max(progress, 0), 1) }

    /// The grey dot's radius, `progress` split off: a small bud growing bigger than your dot
    /// as it goes.
    static func greyRadius(_ progress: Double) -> CGFloat { 5 + 5 * min(max(progress, 0), 1) }

    var body: some View {
        let dx = middle.x - you.x, dy = middle.y - you.y
        let distance = max(hypot(dx, dy), 1)
        let pulling = progress < 0.4
        let t = pulling ? progress / 0.4 : (progress - 0.4) / 0.6
        // Out along the way to the middle
        let out: CGFloat = pulling
            ? Self.pull * Self.easeInOut(t)
            : Self.pull + (distance - Self.pull) * Self.easeOutBack(t)
        let grey = CGPoint(x: you.x + dx / distance * out, y: you.y + dy / distance * out)
        let greyRadius = Self.greyRadius(progress)
        let youScale = Self.youScale(progress)
        ZStack {
            Canvas { context, _ in
                // Not split off at all: nothing to draw
                guard progress > 0.001 else { return }
                func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
                    Circle().path(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                }
                // The goo: a white edge, then grey, each blurred and cut at half so the circles
                // and the neck between them run together
                for (color, grow) in [(Color.white, 2.0), (Color(.systemGray), 0.0)] {
                    context.drawLayer { layer in
                        layer.addFilter(.alphaThreshold(min: 0.5, color: color))
                        layer.addFilter(.blur(radius: 2.5))
                        layer.fill(circle(grey, greyRadius + grow), with: .color(.black))
                        guard pulling else { return }
                        let youRadius = Self.youFill * youScale
                        layer.fill(circle(you, youRadius + grow), with: .color(.black))
                        // The neck: circles along it, narrowing at its waist
                        let pinch = 0.1 + 0.55 * t * t
                        for step in 1..<8 {
                            let f = Double(step) / 8
                            let radius = (youRadius + (greyRadius - youRadius) * f) * (1 - pinch * sin(.pi * f)) + grow
                            layer.fill(circle(CGPoint(x: you.x + (grey.x - you.x) * f, y: you.y + (grey.y - you.y) * f), radius),
                                       with: .color(.black))
                        }
                    }
                }
                // Your dot shows through, the neck coming out from under it
                context.blendMode = .clear
                context.fill(circle(you, (Self.youFill + Self.youEdge / 2) * youScale), with: .color(.black))
            }
            if !pulling {
                MapMiddleDot(radius: greyRadius).position(grey)
            }
        }
        .accessibilityHidden(true)
    }

    private static func easeInOut(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    private static func easeOutBack(_ t: Double) -> Double {
        let c = 1.4
        return 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
    }
}

/// A bus line on a bus stop's mark: white, with the line in bus blue.
private struct MapSignBusBadge: View {
    let line: String

    var body: some View {
        Text(BusBadge.label(line))
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(BusBadge.blue)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .background(.white, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel(BusBadge.spokenName(line))
    }
}

/// A dock on Nearby's map: a Citi Bike blue capsule with the bikes the Citi Bike menu picked,
/// each kind with its symbol (a bike, or a bolt for e-bikes) and count.
private struct DockMark: View {
    let dock: CitiBike.Dock
    let bikes: BikeKinds

    var body: some View {
        HStack(spacing: 6) {
            ForEach(bikes.kinds, id: \.self) { kind in
                count(dock.available(kind), symbol: kind == .eBike ? "bolt.fill" : "bicycle")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Capsule().fill(Color.citiBike))
        .overlay(Capsule().stroke(.white, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dock.name)
        .accessibilityValue(bikes.kinds.map { $0.count(dock.available($0)) }.joined(separator: ", "))
    }

    private func count(_ number: Int, symbol: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text("\(number)").font(.system(size: 12, weight: .heavy)).monospacedDigit()
        }
        .frame(height: 16)
    }
}

/// How Nearby's map marks show, by id: each as its sign, a bubble, a bubble standing for
/// several (their ids, its own first), or hidden, merged into another's; and whether they're too
/// crowded to show at all.
private struct MarkLayout: Equatable {
    enum Look: Equatable {
        case sign, bubble, merged([String]), hidden
    }

    var looks: [String: Look] = [:]
    var tooCrowded = false
}

/// A place on Nearby's map as `layout` has it: its sign, or its bubble, each measured for
/// laying them out. `tap` gets the ids a merged bubble stands for, or nil for one place.
private struct MapMark<Sign: View, Bubble: View>: View {
    let id: String
    let layout: MarkLayout
    @Binding var signSizes: [String: CGSize]
    @Binding var bubbleSizes: [String: CGSize]
    let sign: Sign
    let bubble: (Int?) -> Bubble
    let tap: ([String]?) -> Void

    private var look: MarkLayout.Look { layout.tooCrowded ? .hidden : layout.looks[id] ?? .sign }

    var body: some View {
        let showsBubble = look == .bubble || look.merged != nil
        Button {
            tap(look.merged)
        } label: {
            ZStack {
                sign
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { signSizes[id] = $0 }
                    .opacity(look == .sign ? 1 : 0)
                    .allowsHitTesting(look == .sign)
                bubble(look.merged?.count)
                    // Measured on its own, as a count would widen it
                    .background {
                        bubble(nil).hidden()
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSizes[id] = $0 }
                    }
                    .opacity(showsBubble ? 1 : 0)
                    .scaleEffect(showsBubble ? 1 : 0.6)
                    .allowsHitTesting(showsBubble)
            }
        }
        .buttonStyle(.plain)
        .opacity(look == .hidden ? 0 : 1)
        .allowsHitTesting(look != .hidden)
        .accessibilityHidden(look == .hidden)
        .accessibilityValue(look.merged.map { "\($0.count) here" } ?? "")
    }
}

extension MarkLayout.Look {
    /// The ids a merged bubble stands for.
    fileprivate var merged: [String]? {
        if case .merged(let ids) = self { ids } else { nil }
    }
}

/// A place on Nearby's map condensed to a bubble of its kind's colour and symbol, with a number
/// (a dock's bikes) if given. Standing for `count` places, it shows how many, stacked.
private struct MapBubble: View {
    let fill: Color
    let symbol: String
    var count: Int?
    var number: Int?

    var body: some View {
        let shown = count ?? number
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            if let shown {
                Text("\(shown)").font(.system(size: 12, weight: .heavy)).monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, shown == nil ? 0 : 7)
        .frame(minWidth: 22, minHeight: 22)
        .background(Capsule().fill(fill))
        .overlay(Capsule().stroke(.white, lineWidth: 1.5))
        // Several: another peeking out behind
        .background {
            if count != nil {
                Capsule().fill(fill)
                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                    .offset(x: 3, y: -3)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .fixedSize()
    }
}

/// Next trains for everything a Nearby tab page lists, fetched together.
@MainActor @Observable
final class LiveTrains {
    /// Next arrivals by `Selection.trainID`, as last fetched.
    private(set) var trains: [String: [Arrival]] = [:]
    /// `Selection.trainID`s whose last fetch failed. May include trains from an older
    /// list, so pages should check via `anyFailed(_:)`.
    private(set) var failed: Set<String> = []
    /// Those of `failed` showing the timetable's times instead (`TimetableStore`).
    private(set) var fromTimetable: Set<String> = []
    /// When the last load finished; nil before the first.
    private(set) var updated: Date?
    /// Ticks every few seconds so the minutes count down.
    var now = Date.now {
        didSet {
            if now.timeIntervalSince(mapNow) >= Self.mapTick || now < mapNow { mapNow = now }
        }
    }
    /// `now` a minute at a time, for the map: its bus stops' lines and the lines drawn, by the
    /// buses still due. Not the whole map redrawn every tick for a bus gone a few seconds sooner.
    private(set) var mapNow = Date.now
    private static let mapTick: TimeInterval = 60

    /// Fetches via `TrainService.trains(for:)`. Trains missing from the result lose their
    /// old times rather than count down stale ones. Trains not in `selections` keep their
    /// times and failure state, so an older load finishing late can't clear a newer one's rows.
    func load(_ selections: [Selection], includingOtherLines: Bool = true) async {
        // With nothing to fetch, nothing failed
        guard !selections.isEmpty else {
            failed = []
            return
        }
        let fetched = await TrainService.trains(for: selections, includingOtherLines: includingOtherLines)
        // Cancelled by a newer list; not a failure
        guard !Task.isCancelled else { return }
        let asked = Set(selections.map(\.trainID))
        let missing = asked.subtracting(fetched.keys)
        trains.merge(fetched) { $1 }
        // Those the MTA couldn't give, from the timetable if there is one
        let timetable = missing.isEmpty ? nil : TimetableStore.load()
        let timed = timetable.map {
            TrainService.trains(for: selections.filter { missing.contains($0.trainID) }, from: $0)
        } ?? [:]
        for trainID in missing { trains[trainID] = timed[trainID] }
        failed.subtract(asked)
        failed.formUnion(missing)
        fromTimetable.subtract(asked)
        fromTimetable.formUnion(timed.keys)
        now = .now
        updated = now
    }

    /// Whether any of a page's `selections` failed their last fetch.
    func anyFailed(_ selections: [Selection]) -> Bool {
        !failed.isDisjoint(with: selections.map(\.trainID))
    }

    /// Whether any of them show the timetable's times, as their last fetch failed.
    func anyFromTimetable(_ selections: [Selection]) -> Bool {
        !fromTimetable.isDisjoint(with: selections.map(\.trainID))
    }
}

extension View {
    /// Updates `now` every 10 seconds so, between loads, minutes count down and
    /// uncatchable trains drop off.
    func ticking(_ now: Binding<Date>) -> some View {
        modifier(Ticking(now: now))
    }

    /// Runs `load` now and every minute (restarting when `id` changes), and after
    /// `refreshing` on pull-to-refresh or app foregrounding. Ticks `live.now` in between.
    fileprivate func updatingTrains<ID: Equatable>(_ live: LiveTrains, id: ID, refreshing: @escaping () -> Void = {},
                                                   load: @escaping () async -> Void) -> some View {
        modifier(UpdatingTrains(live: live, id: id, refreshing: refreshing, load: load))
    }
}

/// What a page's loop of loads runs for: its `id`, and not while the app's in the background.
/// A walk keeps the app running there, which kept the loop of a page left open going too.
struct Polling<ID: Equatable>: Equatable {
    let id: ID
    let inForeground: Bool
}

/// `ticking(_:)`: not while the app's in the background, and caught up at once as it comes back.
private struct Ticking: ViewModifier {
    let now: Binding<Date>
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: scenePhase != .background) {
            guard scenePhase != .background else { return }
            now.wrappedValue = .now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                now.wrappedValue = .now
            }
        }
    }
}

private struct UpdatingTrains<ID: Equatable>: ViewModifier {
    let live: LiveTrains
    let id: ID
    let refreshing: () -> Void
    let load: () async -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .refreshable {
                refreshing()
                await load()
            }
            // Restarted as the app comes back, loading then
            .task(id: Polling(id: id, inForeground: scenePhase != .background)) {
                guard scenePhase != .background else { return }
                while !Task.isCancelled {
                    await load()
                    // After a failure, sooner; and as soon as the network's back (a station
                    // after a tunnel)
                    await Connectivity.shared.pause(for: .seconds(live.failed.isEmpty ? 60 : 15))
                }
            }
            .ticking(Binding { live.now } set: { live.now = $0 })
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                refreshing()
            }
    }
}

/// Shown above a page's trains when some failed to load; `timetable` if some of them show the
/// timetable's times instead.
private struct UnreachableNote: View {
    var timetable = false

    var body: some View {
        Label(timetable ? "Couldn't reach the MTA, so some times are the timetable's. Pull down to try again."
                  : "Couldn't reach the MTA. Pull down to try again.", systemImage: "wifi.exclamationmark")
            .foregroundStyle(.secondary)
    }
}

/// One line at a station with its next trains each way, matching the Nearby widget
/// (`Station.ways(of:trains:now:)`): toward Manhattan first. Directions with no name (end of
/// the line) are omitted, as is a direction where the line terminates at a shared platform,
/// unless some of its trains continue.
private struct NearbyLineRow: View {
    let station: Station
    let route: String
    let live: LiveTrains
    let marks: TimeMarks
    let open: (Selection) -> Void

    private var ways: [LineWay] {
        station.ways(of: route, trains: live.trains, now: live.now).compactMap { $0 }
    }

    var body: some View {
        // The bullet is centred between the directions
        HStack(spacing: 22) {
            LineBullet(route: route, size: 40)
                .frame(width: 44)
            VStack(spacing: 0) {
                ForEach(Array(ways.enumerated()), id: \.element.direction) { index, way in
                    let failed = live.failed.contains(way.selection.trainID)
                    if index > 0 {
                        Divider().padding(.vertical, 8)
                    }
                    Button {
                        open(way.selection)
                    } label: {
                        // The direction sits on the next train's baseline
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(way.label)
                                    .lineLimit(1)
                                // The next train's destination
                                if let terminal = way.trains?.first?.terminal {
                                    Text(terminal)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 12)
                            // No chevron: the whole row's the tap, as New Trip's trips
                            Minutes(trains: way.trains, failed: failed, now: live.now, marks: marks)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Lines.name(of: route)) \(way.label)"
                                        + (way.trains?.first?.terminal.map { ", to \($0)" } ?? ""))
                    // The label covers the whole row, so times go in the value
                    .accessibilityValue(Minutes.spoken(way.trains, failed: failed, now: live.now))
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// The next train large ("3 min"), the two after it small beneath ("then 9, 15 min"),
/// live predictions in green.
private struct Minutes: View {
    /// Nil until fetched.
    let trains: [Arrival]?
    /// Shows "Couldn't load" instead.
    let failed: Bool
    let now: Date
    let marks: TimeMarks
    /// Shown with none to come.
    var none = "No trains"

    var body: some View {
        if failed {
            Text("Couldn't load").font(.subheadline).foregroundStyle(.secondary)
        } else if let trains {
            if trains.isEmpty {
                Text(none).font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    next(trains[0])
                    if trains.count > 1 {
                        later(trains.dropFirst().prefix(2))
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(trains, now: now))
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// VoiceOver text, e.g. "Now, 1 minute, 7 minutes by the timetable". Scheduled
    /// times say so, as their colour does on screen.
    static func spoken(_ trains: [Arrival]?, failed: Bool = false, now: Date) -> String {
        guard !failed else { return "Couldn't load" }
        guard let trains else { return "Loading" }
        guard !trains.isEmpty else { return "No trains" }
        return trains.prefix(3).map { train in
            let time = MinutesToGo(until: train.time, from: now).spoken
            return train.isLive ? time : "\(time) by the timetable"
        }
        .joined(separator: ", ")
    }

    /// The next train, large: "3 min" or "Now".
    private func next(_ train: Arrival) -> some View {
        let minutes = MinutesToGo(until: train.time, from: now)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            time(train, markSize: 11)
                .font(.title3.weight(.bold))
            if !minutes.isNow {
                Text("min").font(.footnote.weight(.semibold))
                    .foregroundStyle(train.statusColor(scheduled: .primary))
            }
        }
    }

    /// The two after it, small: "then 6, 12 min".
    private func later(_ trains: ArraySlice<Arrival>) -> some View {
        HStack(spacing: 0) {
            Text("then ").foregroundStyle(.secondary)
            ForEach(Array(trains.enumerated()), id: \.element) { index, train in
                if index > 0 {
                    Text(", ").foregroundStyle(.secondary)
                }
                time(train, markSize: 8)
            }
            Text(" min").foregroundStyle(.secondary)
        }
        .font(.footnote.weight(.medium))
    }

    /// One train's mark and minutes, in its status colour.
    private func time(_ train: Arrival, markSize: CGFloat) -> some View {
        HStack(spacing: 2) {
            StatusMark(isLive: train.isLive, marks: marks, size: markSize)
            Text(MinutesToGo(until: train.time, from: now).number)
        }
        .foregroundStyle(train.statusColor(scheduled: .primary))
    }
}

#Preview {
    LiveView(allowingLocation: .constant(false), recenterRequests: 0)
        .environment(WidgetStore())
        .environment(SettingsStore())
}
