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
    /// Which way you last turned the map, by hand or its compass, when not Settings' way: the
    /// map's framed that way after, rather than turned back Grid North as the marks change.
    /// Shared with Navigate's map, and cleared as Settings changes.
    @Binding var keptHeading: Double?
    /// Counts taps on the Nearby tab, each one bringing the map back to you.
    let recenterRequests: Int
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var location = NearbyLocation()
    /// The bus home stop tapped in Spotlight, to open.
    @State private var opening = StationOpening.shared
    @State private var path = NavigationPath()
    @State private var live = LiveTrains()
    /// The map's middle once you've moved it, which Nearby lists what's near instead of you
    /// until the Nearby tab (or the note over the map) brings it back.
    @State private var mapCenter: CLLocation?
    /// What's kept as the map moves that nothing drawn reads: written as often as every frame,
    /// and writing SwiftUI state drew all of Nearby, every mark on its map, again each time
    /// (once on the first touch of each move, and ten times a second as it went on).
    @State private var motion = MapMotion()
    private static let restDelay: TimeInterval = 0.4
    /// How much the map's scale must change, a share of it, to be taken as zoomed: well inside
    /// `BusZoom`'s and `MapDetail`'s leeway.
    private static let scaleChange = 0.02
    @State private var framingUntil = Date.distantPast
    /// Places tapped on the map since it was moved, their tiles saying how far they are from you.
    @State private var revealed: Set<String> = []
    /// Closest stations to `here`, nearest first. Recomputed only when `here` changes,
    /// not on every redraw.
    @State private var nearby: [Nearby.Result] = []
    @State private var camera = Self.startCamera
    /// The map's size and safe area, and how far up it last rested, to frame it turned Grid North.
    @State private var room = MapRoom()
    @AppStorage(MapNorth.key) private var nyNorth = false
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
    /// The place tapped on the map, its tiles outlined, by its map mark's id (a stop opened from
    /// its dot, the stop's): one at a time, nil with none.
    @State private var openedPlace: String?
    /// The bus places near `here`, as last loaded.
    @State private var buses: NearbyBusList = .finding
    /// Where `buses` was found from, for a failed refresh to keep them only if still there.
    @State private var busesFrom: CLLocation?
    /// Whether `buses` are kept from before a failed refresh: their times not live, and a stop
    /// with none left due says they couldn't be updated rather than that none are due.
    @State private var busesStale = false
    /// The Citi Bike docks near `here`, nearest first; nil while finding them, and `docksFailed`
    /// if the feed couldn't be had.
    @State private var docks: [NearbyDock]?
    @State private var docksFailed = false
    /// When the last load finished, whatever it loaded.
    @State private var updated: Date?
    /// When the trains were last loaded, and which, and `buses` and `docks` last found, and the
    /// docks where: a load restarted by a toggle, or retried for the trains, doesn't fetch again
    /// what hasn't changed (`refetchAfter`, `docksLife`), unless pulled to refresh.
    @State private var trainsLoaded: (ids: [String], at: Date)?
    @State private var busesLoaded: Date?
    @State private var docksLoaded: (at: Date, near: CLLocation, has: CitiBike.Has)?
    /// Whether Nearby shows, not another tab or a train's page over it; and that you're to be
    /// found again once it does, back in the app elsewhere (`findsOnShow`).
    @State private var shown = false
    @State private var findsOnShow = false
    /// Each map mark's size as a sign and as a bubble, by its `mapMarks` id, and how each shows
    /// for them all to clear each other (`layOutMarks`).
    @State private var markSizes: [String: CGSize] = [:]
    @State private var bubbleSizes: [String: CGSize] = [:]
    @State private var markLayout = MarkLayout()
    /// Each bus stop on the map named with lines (`findBusNames`), worked out once each time the
    /// stops or their ways change, not every time the map's drawn or its marks laid out.
    @State private var busNames: [String: [String]] = [:]
    /// The lines of the bus stops nearest where Nearby is (`nearestBusLines`), drawn on its map.
    @State private var nearbyBusLines: Set<String> = []
    /// The nearby stations' lines, worked out when the stations change; and a count of each new
    /// set, to tell the map's lines from the last ones'.
    @State private var lines = NearbyLines.none
    /// The other stops along the listed bus stops' lines, every few blocks (`findLines`).
    @State private var alongStops: [AlongStop] = []
    /// Stops along the lines no longer marked, kept a moment to shrink away (`MarkBubble`).
    @State private var leavingStops: [AlongStop] = []
    @State private var linesVersion = 0
    /// The map's height, and map points a point is once it last came to rest, to keep lines side
    /// by side the same points apart however far it's zoomed.
    @State private var mapHeight: CGFloat = 0
    @State private var mapWidth: CGFloat = 0
    /// Where the card starts, and the map, on the screen: the bottom of the map that shows.
    @State private var cardTop: CGFloat = 0
    /// On its side, where the card's right edge is on the screen, for the map that shows past it.
    @State private var cardTrailing: CGFloat = 0
    @State private var mapLeft: CGFloat = 0
    /// On its side, the list's height in the card, filling it top to bottom.
    @State private var sideListHeight: CGFloat = 0
    /// The tab bar's room under the map, for its logo and Legal on its side.
    @State private var tabBarRoom: CGFloat = 0
    @Environment(\.isSideways) private var sideways
    @State private var mapTop: CGFloat = 0
    @State private var mapPointsPerPoint: Double = 0
    @State private var linesCache = NearbyLinesLayer.Cache()
    /// A stop along the lines opened by a tap on its dot: its buses in the card, its lines drawn.
    @State private var openedStop: OpenedStop?
    /// The grey dot at the map's middle, as the map moves: on its own, for only it to redraw
    /// every frame, not the whole page.
    @State private var middle = MapMiddleTracker()
    /// How near the map is for bus stops' marks (`BusZoom`), as it last came to rest, and which
    /// way it's turned, degrees from north, for the marks' arrows.
    @State private var busZoom = BusZoom.far
    @State private var mapDetail = MapDetail.full
    @State private var mapHeading: Double = 0
    /// Which way each bus stop marked's buses go, by its mark's id (`findLines`).
    @State private var busWays: [String: BusSides.Way] = [:]

    /// The page's side margin and its card's corners, as New Trip's.
    private static let margin: CGFloat = 16
    private static let card = RoundedRectangle(cornerRadius: 26, style: .continuous)
    /// The status bar's room over the top of the map.
    private static let statusBarRoom: CGFloat = 70
    /// The card's most height, its modes row included, as New Trip's (`NewTripView.cardMax`);
    /// past it the trains scroll within it.
    private static let cardHeight: CGFloat = 250
    /// The most it grows to with a place open, to fit its times; less on a short screen.
    /// The modes row's height at the card's foot, as New Trip's.
    private static let modesRowHeight: CGFloat = 58
    /// The margin around the card's list of places.
    private static let tilesMargin: CGFloat = 8
    /// The card's list of places, for each tile to note where it starts.
    private static let tilesSpace = "nearbyTiles"

    /// Before your location's known: the city, as New Trip's, rather than the whole country, which
    /// `cityBounds` then held at its far corner (Perth Amboy, NJ).
    private static let cityRegion = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.73, longitude: -73.97),
                                                       latitudinalMeters: 8_000, longitudinalMeters: 8_000)

    /// Where the map starts: on your last fix, if Leeway may know it and it's in the city,
    /// `framedMeters` across as `frame()` will have it. Following your location instead
    /// (`.userLocation`) has MapKit run its own best-for-navigation GPS till framed, so only
    /// with no fix known yet. Once, as Nearby's first made: `@State` keeps only the first.
    private static let startCamera: MapCameraPosition = {
        let manager = CLLocationManager()
        let allowed = [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)
        // Within the map's bounds' middles (`cityBounds`)
        guard let fix = PretendLocation.current ?? (allowed ? manager.location : nil),
              abs(fix.coordinate.latitude - 40.70) <= 0.25, abs(fix.coordinate.longitude + 73.95) <= 0.3 else {
            return .userLocation(fallback: .region(cityRegion))
        }
        return .region(MKCoordinateRegion(center: fix.coordinate, latitudinalMeters: framedMeters,
                                          longitudinalMeters: framedMeters))
    }()

    /// The map kept on the city, zoomed out no further than New Trip's (`NewTripView.cityBounds`).
    private static let cityBounds = MapCameraBounds(
        centerCoordinateBounds: MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.70, longitude: -73.95),
                                                   span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.6)),
        maximumDistance: 60_000)

    /// How far the map's middle moves, once it comes to rest, for Nearby to list what's there:
    /// a few blocks (250 m since 11/9, was 100), as each listing holds the map up a moment.
    private static let followMeters: Double = 250
    /// The docks asked for round `here`, with either kind of bike: three show with the bikes
    /// Settings picks (`shownDocks`), the rest there for a toggle's change.
    private static let docksAsked = 5
    /// Seconds within which trains or buses loaded for the same are not fetched again.
    private static let refetchAfter: TimeInterval = 30
    /// Seconds docks found within `followMeters` stand, not fetched again: they don't follow
    /// the trains' retries.
    private static let docksLife: TimeInterval = 60

    /// Home as first-run setup picked it, for Nearby to load near before your location's found.
    @State private var setupHome = SetupHome.shared

    /// The map's middle once moved, or else your location; till that's found, setup's Home, and
    /// once it is, still Home while you're within `followMeters` of it, for the trains, stops and
    /// docks loaded there not to load again, nor the map to shift, for a few metres. So too where
    /// you were last loaded round, so a fresh fix a few metres off (back in the app) doesn't load
    /// it all again.
    private var here: CLLocation? {
        if let mapCenter { return mapCenter }
        guard let you = location.location else { return setupHome.location }
        guard let kept = setupHome.location ?? loadedYou else { return you }
        return you.distance(from: kept) <= Self.followMeters ? kept : you
    }

    /// Your location as Nearby last loaded round it, kept as `here` while you're within
    /// `followMeters` of it.
    @State private var loadedYou: CLLocation?

    /// Back to you: the map framed on you again, re-located even if you haven't moved. Times
    /// reload once the nearby stations change.
    private func recenter() {
        let wasLoading = loadKey
        revealed = []
        openedStop = nil
        openedPlace = nil
        // The grey dot merges back into yours as the map goes back to you
        motion.userMovedMap = false
        motion.cameraMovedByHand = false
        let wasMoved = mapCenter != nil
        mapCenter = nil
        // Right where you are now, not setup's Home
        if location.location != nil { setupHome.location = nil }
        // Moved back from elsewhere, right where you are; already on you (as on coming back to
        // the tab), still where it loaded, so a fix a few metres off doesn't load it all again
        if wasMoved { loadedYou = nil }
        location.find()
        // Framed on you as you are now, whatever's toggled on and however it was zoomed, turned
        // the way it was kept (on either tab)
        if let you = location.location ?? here {
            let region = MKCoordinateRegion(center: you.coordinate,
                                            latitudinalMeters: Self.framedMeters, longitudinalMeters: Self.framedMeters)
            framingUntil = .now.addingTimeInterval(1.5)
            withAnimation(.smooth) { camera = framing(region) }
        } else {
            // Not found yet: the city, still turned the kept way, and framed on you once you're
            // found (`here` changing)
            framingUntil = .now.addingTimeInterval(1.5)
            withAnimation(.smooth) { camera = framing(Self.cityRegion) }
        }
        // Back to you elsewhere reloads by itself (`updatingTrains`); not here as well
        if loadKey == wasLoading { Task { await load() } }
    }

    /// Whether the note over the map shows: the map moved more than 0.15 miles off you.
    private var showsMiddle: Bool {
        guard let mapCenter, let you = location.location else { return false }
        return you.distance(from: mapCenter) > Self.middleMeters
    }

    private static let middleMeters = 0.15 * 1609.344

    /// The map's come to rest at `center`: past `followMeters` from where it last rested, by
    /// your hand rather than `frame()`'s (`byHand`, as it was when it came to rest), Nearby lists
    /// what's near there.
    private func mapRested(at center: CLLocationCoordinate2D, byHand: Bool) {
        let middle = CLLocation(latitude: center.latitude, longitude: center.longitude)
        guard let rested = motion.restCenter, byHand else {
            motion.restCenter = middle
            return
        }
        guard middle.distance(from: rested) > Self.followMeters else { return }
        motion.restCenter = middle
        revealed = []
        mapCenter = middle
        // Its lines with it, not in a drawing after (`onChange(of: here)`)
        nearbyBusLines = Self.nearestBusLines(near: middle)
    }

    /// A mark tapped on the map: its place's tiles outlined, a station's or stop's lines shown
    /// at it, scrolled to; and once the map's moved, its distance from you.
    private func tapped(_ id: String) {
        withAnimation(.smooth) {
            openedStop = nil
            openedPlace = id
        }
        focus(id)
        if mapCenter != nil { revealed.insert(id) }
    }

    /// Scrolls the card to `id`'s place once it's laid out open, for its top as it is then.
    private func focus(_ id: String) {
        Task { @MainActor in focusedMark = id }
    }

    /// A stop along the lines tapped: open first under Bus Stops, at the card's top, its buses
    /// under it, and its lines drawn on the map, centred on it. Its place found as Nearby's
    /// are, from right where it is.
    private func open(_ stop: AlongStop) {
        withAnimation(.smooth) {
            openedStop = OpenedStop(id: stop.id, coordinate: stop.coordinate, lines: stop.lines)
            openedPlace = stop.id
        }
        focus(stop.id)
        if MapNorth.isOff(framedHeading, from: 0), let mapDistance = motion.mapDistance {
            // As far up as it was, turned: a turned map's span is the rect round it
            framingUntil = .now.addingTimeInterval(1.5)
            withAnimation(.smooth) {
                camera = .camera(MapCamera(centerCoordinate: stop.coordinate, distance: mapDistance,
                                           heading: framedHeading))
            }
        } else if let mapSpan = motion.mapSpan {
            // Where it comes to rest is where this put it, not a move of yours
            framingUntil = .now.addingTimeInterval(1.5)
            withAnimation(.smooth) { camera = .region(MKCoordinateRegion(center: stop.coordinate, span: mapSpan)) }
        } else {
            // Not yet drawn (opened from Spotlight on a cold launch): a few blocks round it
            framingUntil = .now.addingTimeInterval(1.5)
            let span = MKCoordinateSpan(latitudeDelta: Self.openedSpan, longitudeDelta: Self.openedSpan)
            withAnimation(.smooth) { camera = framing(MKCoordinateRegion(center: stop.coordinate, span: span)) }
        }
        Task { await loadOpened() }
    }

    /// The opened stop's buses, from Bus Time: the place nearest it, if it's that stop.
    private func loadOpened() async {
        guard let opened = openedStop else { return }
        let at = CLLocation(latitude: opened.coordinate.latitude, longitude: opened.coordinate.longitude)
        let place = await NearbyBuses.places(near: at)?.first { Self.place($0, isAt: at) }
        guard openedStop?.id == opened.id else { return }
        if let place {
            openedStop?.place = place
            openedStop?.failed = false
        } else if openedStop?.place == nil {
            openedStop?.failed = true
        }
    }

    /// The opened stop's buses from `places`, Nearby's just found, if it's one of them; whether
    /// it was, or there's no stop opened, so it needn't be asked for on its own.
    private func takeOpened(from places: [NearbyBusPlace]) -> Bool {
        guard let opened = openedStop else { return true }
        let at = CLLocation(latitude: opened.coordinate.latitude, longitude: opened.coordinate.longitude)
        guard let place = places.first(where: { Self.place($0, isAt: at) }) else { return false }
        openedStop?.place = place
        openedStop?.failed = false
        return true
    }

    /// Whether `place` is the stop at `at` (`openedReach`).
    private static func place(_ place: NearbyBusPlace, isAt at: CLLocation) -> Bool {
        place.ways.contains { CLLocation(latitude: $0.stop.latitude, longitude: $0.stop.longitude).distance(from: at) < openedReach }
    }

    /// Degrees across round a stop opened before the map's first come to rest.
    private static let openedSpan: CLLocationDegrees = 0.008

    /// Meters off Bus Time's stop may be from the network's (`TrackShapes.busStops`) to be taken as it.
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
        // Where it comes to rest is where the bubble was, not a move of yours to list round;
        // but zoomed in by your tap, so not framed back out on the next load
        framingUntil = .now.addingTimeInterval(1.5)
        motion.cameraMovedByHand = true
        withAnimation(.smooth) { camera = framing(region) }
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

    /// Restarts loading when any of it changes. Not the bikes counted: the docks are fetched
    /// with either, so changing them only redraws.
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
                // Framed clear of the status bar and the card; its logo and Legal over the card.
                // On its side, no status bar, and the card down the left
                .safeAreaPadding(.top, sideways ? Sideways.top : Self.statusBarRoom)
                // Half a sign more, as signs sit centred on their places
                // On its side, its logo and Legal level with the card's foot, over the tab bar
                .safeAreaPadding(.bottom, sideways ? tabBarRoom + 8 : cardsHeight + 32)
                .safeAreaPadding(.leading, sideways ? Sideways.mapLeading : 12)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                // The tab bar's room, measured behind the map, which under `ignoresSafeArea` has none
                .background {
                    Color.clear.onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { tabBarRoom = $0 }
                }
                .overlay(alignment: .top) { movedNote }
                .overlay(alignment: sideways ? .bottomLeading : .bottom) {
                    card
                    // Upright only: on its side the card runs down the left, and kept, turned back
                    // upright, it padded the map's foot far too tall
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard !sideways else { return }
                        cardsHeight = height
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { cardTop = $0 }
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { cardTrailing = $0 }
                    .modifier(CardPlace(sideways: sideways))
                }
                // The modes row over the card's foot, on its own so it stays put as the card
                // opens and closes round it
                .overlay(alignment: sideways ? .bottomLeading : .bottom) {
                    modesRow
                    .modifier(CardPlace(sideways: sideways))
                }
                .navigationDestination(for: LineWays.self) { line in
                    LineDetail(line: line)
                        .toolbar(.visible, for: .navigationBar)
                }
                .navigationDestination(for: BusLineWays.self) { line in
                    BusLineDetail(line: line)
                        .toolbar(.visible, for: .navigationBar)
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
                // You've moved on: framed round where you are now, however the map was left
                .onChange(of: here) {
                    motion.cameraMovedByHand = false
                    frame()
                }
                .onChange(of: showsBuses) {
                    if showsBuses { buses = .finding; busesStale = false } else { openedStop = nil }
                }
                .onChange(of: showsBikes) { if showsBikes { docks = nil; docksFailed = false } }
                // Settings' way up, over the way you'd turned it
                .onChange(of: nyNorth) { keptHeading = nil }
                .onAppear {
                    location.start()
                    shown = true
                    if findsOnShow {
                        findsOnShow = false
                        if location.isAllowed && mapCenter == nil { location.find() }
                    }
                }
                .onDisappear { shown = false }
                .onChange(of: recenterRequests) { recenter() }
                // Turned on or off its side, the map's resized round the card, which moves its
                // middle: not a move of yours, which listed what's near somewhere else and loaded
                // it at every turn. Framed on you again, unless you'd moved it
                .onChange(of: sideways) {
                    framingUntil = .now.addingTimeInterval(1.5)
                    frame()
                }
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
                // Once you're found away from setup's Home, it's done with: not gone back to as
                // you come near it again
                .onChange(of: location.location) { _, you in
                    guard let you, let home = setupHome.location,
                          you.distance(from: home) > Self.followMeters else { return }
                    setupHome.location = nil
                }
                .onChange(of: here, initial: true) { _, here in
                    // The lines first, drawn once laid out (`findLines`)
                    // (Moved by the map, `mapRested` has them already)
                    if here != motion.restCenter {
                        let lines = Self.nearestBusLines(near: here)
                        if lines != nearbyBusLines { nearbyBusLines = lines }
                    }
                    // Moved on by the map, the stations listed with everything else, once it's all
                    // loaded (`load`), not each on its own; at first, and round you, straight away
                    guard nearby.isEmpty || mapCenter == nil else { return }
                    nearby = here.map { Nearby.stations(near: $0, limit: 3) } ?? []
                }
                // The stops along the lines and their ways at every re-listing; the lines themselves,
                // slow, off the main thread, only when what's drawn changes (`drawnLinesKey`)
                .onChange(of: linesKey, initial: true) {
                    // Not while the lines they're along are being laid out again: once, with them
                    guard motion.linesFoundFor == drawnLinesKey else { return }
                    findStopsAlong()
                }
                .task(id: drawnLinesKey) { await findLines() }
                // The bus home stop from Spotlight: buses shown, and it opened
                .onChange(of: opening.busStop, initial: true) { _, bus in
                    guard let bus else { return }
                    opening.busStop = nil
                    // Not under a train's page left open
                    path = NavigationPath()
                    showsBuses = true
                    // Named as `findAlongStops` names it, so its map mark is the one opened
                    let coordinate = CLLocationCoordinate2D(latitude: bus.stop.latitude, longitude: bus.stop.longitude)
                    // Nearby lists round the stop, not you: the map's moved there, so it isn't
                    // framed back on you once the buses near you load
                    let at = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    revealed = []
                    mapCenter = at
                    motion.restCenter = at
                    open(AlongStop(id: "e\(coordinate.latitude),\(coordinate.longitude)", coordinate: coordinate,
                                   lines: bus.allLines))
                }
                // Reload every minute and when the train list changes; pull-to-refresh (in the
                // card) and returning to the app also re-locate (unless the map's been moved);
                // returning on another tab, once Nearby shows
                .updatingTrains(live, id: loadKey, refreshing: {
                    guard location.isAllowed && mapCenter == nil else { return }
                    if shown { location.find() } else { findsOnShow = true }
                }, load: { await load(pulled: $0) })
        }
    }

    /// You, the nearby stations as signs, bus stops as their lines and docks with their bikes.
    /// Where they'd overlap, they condense to bubbles by kind, and those to one bubble each
    /// (`layOutMarks`).
    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, bounds: Self.cityBounds) {
                // Under everything else
                NearbyLinesLayer(lines: lines, version: linesVersion, mapPointsPerPoint: mapPointsPerPoint,
                                 cache: linesCache)
                DebugOverlays(on: .nearby)
                // Wide, the other stations round about, as icons, under the listed ones' signs
                if showsStations && showsSubway && mapDetail == .wide {
                    ForEach(otherStations) { station in
                        Annotation(station.name, coordinate: station.coordinate) {
                            OtherStationIcon(name: station.name) { zoom(toStation: station) }
                        }
                        .annotationTitles(.hidden)
                    }
                }
                // Your dot, the app's own, to shrink as the grey dot splits off it. At Nearby's own
                // fix, not MapKit's user location, which keeps best-accuracy GPS on while it shows
                if let you = location.location {
                    Annotation("My Location", coordinate: you.coordinate) {
                        // Tapped, back to you, zoomed as Nearby starts
                        MapYouMark(tracker: middle, tap: recenter)
                    }
                    .annotationTitles(.hidden)
                }
                if showsStations && showsSubway {
                    ForEach(nearby) { result in
                        Annotation(result.station.name, coordinate: CLLocationCoordinate2D(latitude: result.station.lat,
                                                                                         longitude: result.station.lon)) {
                            mark("s" + result.id, spoken: result.station.name, kinds: "stations",
                                 detail: result.station.routes.map(Lines.spokenName(of:)).joined(separator: ", "),
                                 hint: "Shows its trains", key: result.station.routes.joined(separator: " ")) {
                                MapSign(name: result.station.name, fill: .black) {
                                    ForEach(result.station.routes, id: \.self) { LineBullet(route: $0, size: 15) }
                                }
                            } bubble: { count in
                                MapBubble(fill: .black, symbol: "tram.fill", count: count)
                            }
                        }
                        // The signs carry their names
                        .annotationTitles(.hidden)
                    }
                }
                if showsStations {
                    let names = busNames
                    // By its stop, not the whole place, whose times change with each load: a new
                    // mark each time, taken off the map and added again, flickering
                    ForEach(busPlaces, id: \.ways.first?.stop.id) { place in
                        if let stop = place.ways.first?.stop {
                            let id = "b" + stop.id
                            Annotation(place.name, coordinate: busWays[id]?.onLine
                                       ?? CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)) {
                                let lines = shownLines(id, names: names)
                                let placed = placement(of: id, named: lines != nil)
                                let nudge = markLayout.nudges[id] ?? .zero
                                mark(id, spoken: place.name, kinds: "bus stops",
                                     // A dot names none, but its lines are said
                                     detail: BusStopMark.spoken(lines: lines ?? NearbyBusBadges.lines(of: place),
                                                                placement: placed),
                                     hint: "Shows its buses",
                                     key: "\(lines ?? [])|\(String(describing: placed))|\(nudge.width),\(nudge.height)") {
                                    BusStopMark(name: place.name, lines: lines, placement: placed, nudge: nudge)
                                } bubble: { count in
                                    MapBubble(fill: BusBadge.blue, symbol: "bus.fill", count: count)
                                }
                                .opacity(isFaded(place.lines(at: live.mapNow).map(\.line)) ? Self.fadedOpacity : 1)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    // With those just gone, shrinking away
                    ForEach(alongStops + leavingStops.filter { stop in !alongStops.contains { $0.id == stop.id } }) { stop in
                        Annotation("Bus stop", coordinate: busWays[stop.id]?.onLine ?? stop.coordinate) {
                            let lines = shownLines(stop.id, names: names)
                            let placed = placement(of: stop.id, named: lines != nil)
                            let opened = stop.id == openedStop?.id
                            let nudge = markLayout.nudges[stop.id] ?? .zero
                            mark(stop.id, spoken: "Bus stop", kinds: "bus stops",
                                 detail: BusStopMark.spoken(lines: lines ?? NearbyBusBadges.sorted(stop.lines),
                                                            placement: placed),
                                 hint: "Shows its buses",
                                 key: "\(lines ?? [])|\(opened)|\(String(describing: placed))|\(nudge.width),\(nudge.height)",
                                 popsIn: true) {
                                BusStopMark(name: "Bus stop", lines: lines, opened: opened, placement: placed, nudge: nudge)
                            } bubble: { _ in
                                // Never shown: it hides where its lines don't fit
                                MapBubble(fill: BusBadge.blue, symbol: "bus.fill")
                            }
                            .opacity(isFaded(stop.lines) ? Self.fadedOpacity : 1)
                        }
                        .annotationTitles(.hidden)
                    }
                    if let bikes {
                        ForEach(shownDocks) { near in
                            Annotation(near.dock.name, coordinate: near.dock.coordinate) {
                                let counts = bikes.kinds.map { $0.count(near.dock.available($0)) }.joined(separator: ", ")
                                mark("d" + near.id, spoken: near.dock.name, kinds: "docks", detail: counts,
                                     hint: "Shows its bikes", key: "\(counts)|\(bikes.symbol)|\(bikes.count(at: near.dock))") {
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
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                }
            }
            // No businesses or places on it, only its own marks; muted, as New Trip's: the
            // standard map's yellow main roads read as N/Q/R/W lines
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .measuresRoom($room)
            // Its own compass, always there, not MapKit's, there only once turned
            .mapControls {}
            // For the UI tests (LeewayUITests)
            .accessibilityIdentifier("nearbyMap")
            .feedsOverlays(.nearby)
            .turnsNorth($camera, unless: keptHeading != nil)
            // A few times a second while it moves, then once more where it stops
            // Every frame, the grey dot kept at the map's middle
            .onMapCameraChange(frequency: .continuous) { context in
                trackMiddle(proxy, center: context.region.center)
                // Moving again: what's near listed once it's still
                motion.restWait?.cancel()
                motion.moving = true
            }
            .onMapCameraChange(frequency: .continuous) { context in
                let now = Date.now
                guard now.timeIntervalSince(motion.laidOut) >= Self.layoutEvery else { return }
                motion.laidOut = now
                // Stems and arrows kept the way they go as you turn the map, not for every degree
                if abs((context.camera.heading - mapHeading + 540).truncatingRemainder(dividingBy: 360) - 180) > 5 {
                    mapHeading = context.camera.heading
                }
                layOutMarks(proxy)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                motion.moving = false
                layOutMarks(proxy)
                // Not for the hair it's off after a pan, measured again: each change drew Nearby
                // again, and its bus lines' outs (`onChange(of: mapPointsPerPoint)`), twice for
                // every release of quick moves one after another
                if let scale = measuredScale(proxy, context),
                   mapPointsPerPoint == 0 || abs(scale / mapPointsPerPoint - 1) > Self.scaleChange {
                    mapPointsPerPoint = scale
                }
                mapHeading = context.camera.heading
                let zoom = BusZoom(metersPerPoint: mapPointsPerPoint / MKMapPointsPerMeterAtLatitude(context.region.center.latitude),
                                   from: busZoom)
                let detail = MapDetail(metersPerPoint: mapPointsPerPoint / MKMapPointsPerMeterAtLatitude(context.region.center.latitude),
                                       from: mapDetail)
                if detail != mapDetail {
                    withAnimation(.smooth) { mapDetail = detail }
                }
                if zoom != busZoom {
                    withAnimation(.smooth) { busZoom = zoom }
                    // Past zoomed out, each way's stops; zoomed out, one each side of the street
                    findStopsAlong()
                }
                motion.mapSpan = context.region.span
                motion.mapDistance = context.camera.distance
                // Listing what's near holds the map up a moment: not till it's been still a
                // little while, so moving it again straight away isn't held up
                motion.restWait?.cancel()
                let center = context.region.center, byHand = Date.now > framingUntil
                motion.restWait = Task {
                    try? await Task.sleep(for: .seconds(Self.restDelay))
                    guard !Task.isCancelled else { return }
                    mapRested(at: center, byHand: byHand)
                }
                trackMiddle(proxy, center: context.region.center)
                // A pinch or turn of yours, not `frame()` settling: only a gesture leaves the
                // camera positioned by the user
                if camera.positionedByUser, Date.now > framingUntil { motion.cameraMovedByHand = true }
                keepHeading(context.camera.heading)
                motion.shownCamera = context.camera
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                mapHeight = $0.height
                mapWidth = $0.width
                mapTop = $0.minY
                mapLeft = $0.minX
            }
            .overlay {
                MapMiddleOverlay(tracker: middle)
                    .allowsHitTesting(false)
            }
            // The grey dot tapped: zoomed in on it, as Nearby starts
            .overlay {
                MapMiddleTap(tracker: middle, tap: zoomToMiddle)
            }
            .overlay(alignment: .topTrailing) {
                NorthButton(heading: mapHeading, turn: turnMap)
                    .padding(.trailing, 12)
            }
            .onChange(of: markSizes) { layOutMarks(proxy) }
            .onChange(of: bubbleSizes) { layOutMarks(proxy) }
            .onChange(of: framedIDs) { layOutMarks(proxy) }
            // Bus stops' arrows, past zoomed out
            .onChange(of: busZoom) { layOutMarks(proxy) }
            .onChange(of: mapDetail) { layOutMarks(proxy) }
            // Stems faded, or bright again, with the stop opened or closed
            .onChange(of: openedStop?.id) { layOutMarks(proxy) }
            .onChange(of: busWays) { layOutMarks(proxy) }
            .onChange(of: mapPointsPerPoint) { layOutMarks(proxy) }
        }
    }

    /// Map points per screen point where the map's come to rest, measured off the map, not from
    /// the camera's distance, which turned was about twice it.
    private func measuredScale(_ proxy: MapProxy, _ context: MapCameraUpdateContext) -> Double? {
        guard mapHeight > 0 else { return nil }
        return MapNorth.mapPointsPerPoint(proxy, middle: CGPoint(x: mapWidth / 2, y: mapHeight / 2))
            ?? MapNorth.mapPointsPerPoint(context, height: mapHeight)
    }

    /// Where you and the map's middle are as it moves, for the grey dot: split off you once
    /// you've moved the map and its middle is 0.15 miles off you (and, zoomed out, `middlePoints`
    /// off it on the screen), or your dot nears the edge of
    /// the map that shows; merged back once neither is. A little either way of each, so it
    /// doesn't flicker on and off at the line.
    private func trackMiddle(_ proxy: MapProxy, center: CLLocationCoordinate2D) {
        if !motion.userMovedMap, Date.now > framingUntil { motion.userMovedMap = true }
        let middlePoint = proxy.convert(center, to: .local) ?? CGPoint(x: mapWidth / 2, y: mapHeight / 2)
        guard let you = location.location, motion.userMovedMap else {
            middle.update(you: nil, middle: middlePoint, shows: false)
            return
        }
        let youPoint = proxy.convert(you.coordinate, to: .local)
        let shown = middle.shows
        let meters = you.distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
        // Zoomed out, further than 0.15 miles: a pinch drifts the middle further, so it splits
        // only once it's some way off you on the screen too
        let points = youPoint.map { hypot($0.x - middlePoint.x, $0.y - middlePoint.y) } ?? .infinity
        let far = meters > Self.middleMeters * (shown ? 0.85 : 1) && points > Self.middlePoints * (shown ? 0.85 : 1)
        // Clear of the status bar and the card, where it is on the screen; on its side, right
        // of the card
        let bottom = cardTop > mapTop ? cardTop - mapTop : mapHeight
        let left = cardTrailing > mapLeft ? cardTrailing - mapLeft : 0
        let seen = sideways
            ? CGRect(x: left, y: 0, width: max(0, mapWidth - left), height: mapHeight)
            : CGRect(x: 0, y: Self.statusBarRoom, width: mapWidth, height: max(0, bottom - Self.statusBarRoom))
        // Once split, merged back only a few points further in, not most of the way across
        let inset = shown ? Self.edgeInset + 8 : Self.edgeInset
        let nearEdge = youPoint.map { !seen.insetBy(dx: inset, dy: inset).contains($0) } ?? true
        middle.update(you: youPoint, middle: middlePoint, shows: far || nearEdge)
    }

    /// Points from the edge of the map that shows (the screen's sides, under the status bar,
    /// over the card) your dot brings the grey dot: about its own width, as it reaches the edge.
    private static let edgeInset: CGFloat = 14

    /// Points off your dot on the screen the map's middle must be, as well as `middleMeters`, to
    /// bring the grey dot: the more as it's zoomed out.
    private static let middlePoints: CGFloat = 60

    /// How faint the marks and lines not at the opened stop are.
    private static let fadedOpacity = 0.3

    /// Whether a bus stop's mark is faded: with a stop opened, if none of its lines stop there.
    private func isFaded(_ lines: [String]) -> Bool {
        guard let opened = openedStop else { return false }
        return Set(opened.lines.map(TrackShapes.busKey)).isDisjoint(with: lines.map(TrackShapes.busKey))
    }

    /// The lines drawn on the map, as `TrackShapes.busKey` has them: the nearest stops' (known at
    /// once, `nearbyBusLines`), the listed stops' (any a listed stop has past those), and the
    /// opened stop's.
    private var drawnBusLines: Set<String> {
        let listed = showsBuses ? busPlaces.flatMap { Self.lines(of: $0, at: live.mapNow) } : []
        return (showsBuses ? nearbyBusLines : []).union(listed).union(openedStop?.lines.map(TrackShapes.busKey) ?? [])
    }

    /// The lines a listed stop has, as `TrackShapes.busKey` has them: those with buses due, or
    /// with none due, any it's had buses for, so it's still placed on its own line.
    private static func lines(of place: NearbyBusPlace, at date: Date) -> [String] {
        let due = place.lines(at: date).map(\.line)
        let any = due.isEmpty ? place.ways.flatMap { $0.arrivals.map(\.line) } : due
        var seen: Set<String> = []
        return any.map(TrackShapes.busKey).filter { seen.insert($0).inserted }
    }

    /// The lines stopping at the bus stops nearest `place` (`NearbyLines.nearestStopsLines`): those
    /// the listed stops have, about, known at once without asking Bus Time, so the lines are drawn
    /// first as Nearby moves on, not after its buses load.
    private static func nearestBusLines(near place: CLLocation?) -> Set<String> {
        NearbyLines.nearestStopsLines(near: place)
    }

    /// The lines a bus stop's tag shows, from `names` (`busNames`): its own and those put in it
    /// from stops by it (`MarkLayout.extraLines`); nil, a dot, as is a stop whose lines went in another's.
    private func shownLines(_ id: String, names: [String: [String]]) -> [String]? {
        guard let own = names[id], !markLayout.joined.contains(id) else { return nil }
        return own + (markLayout.extraLines[id] ?? [])
    }

    /// Each bus stop on the map named with lines, by its mark's id; the rest are dots. Each line
    /// drawn named once, at its stop nearest where Nearby is (you, or the moved map's middle);
    /// close in, once each way, the way of the stop nearest and its other; the opened stop first,
    /// with all its lines.
    private func findBusNames() -> [String: [String]] {
        guard let here else { return [:] }
        let drawn = drawnBusLines
        let listed = busPlaces.compactMap { place in
            place.ways.first.map { way in
                (id: "b" + way.stop.id, place: CLLocation(latitude: way.stop.latitude, longitude: way.stop.longitude),
                 lines: NearbyBusBadges.sorted(place.lines(at: live.mapNow).map(\.line)))
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
        // Close in, the way each line's first named goes, to name it again the other way
        var firstWay: [String: Double] = [:]
        for stop in stops {
            var fresh: [String] = []
            let angle = busWays[stop.id]?.angle
            for line in stop.lines {
                let key = TrackShapes.busKey(line)
                guard drawn.contains(key) else { continue }
                var name = key
                if busZoom == .close, let angle {
                    if let first = firstWay[key] {
                        // More than a right angle off the first's way: its other way
                        if cos(angle - first) < 0 { name = key + " other" }
                    } else {
                        firstWay[key] = angle
                    }
                }
                guard named.insert(name).inserted else { continue }
                fresh.append(line)
            }
            if !fresh.isEmpty { names[stop.id] = fresh }
        }
        return names
    }

    /// A place on the map as `markLayout` has it: its sign, or a bubble standing for it (and
    /// how many it stands for, merged); a tap on a merged one zooms in to part them.
    private func mark(_ id: String, spoken name: String, kinds: String, detail: String = "", hint: String, key: String,
                      popsIn: Bool = false,
                      @ViewBuilder sign: () -> some View,
                      @ViewBuilder bubble: @escaping (Int?) -> some View) -> some View {
        // A stop along the lines no longer marked shrinks away
        let leaving = leavingStops.contains { $0.id == id } && !alongStops.contains { $0.id == id }
        return MapMark(id: id, look: markLayout.tooCrowded || leaving ? .hidden : markLayout.looks[id] ?? .sign, key: key,
                signSizes: $markSizes, bubbleSizes: $bubbleSizes,
                spoken: name, kinds: kinds, detail: detail, hint: hint, popsIn: popsIn, sign: sign(), bubble: bubble) { merged in
            if let merged {
                zoom(into: merged)
            } else if id.hasPrefix("e") {
                // A stop along the lines has no tile till it's opened
                if let stop = alongStops.first(where: { $0.id == id }) { open(stop) }
            } else {
                tapped(id)
            }
        }
        .equatable()
    }

    /// Every mark on the map, most important first: the nearest station, bus stop and dock, then
    /// the next nearest of each, and so on, so each kind shows where there's room for one.
    private var mapMarks: [(id: String, coordinate: CLLocationCoordinate2D)] {
        guard showsStations else { return [] }
        let stations = showsSubway ? nearby.map { ("s" + $0.id, $0.station.coordinate) } : []
        // Bus stops where they're drawn, on their streets' lines
        let stops = busPlaces.compactMap { place in
            place.ways.first.map { way in
                let id = "b" + way.stop.id
                return (id, busWays[id]?.onLine ?? CLLocationCoordinate2D(latitude: way.stop.latitude, longitude: way.stop.longitude))
            }
        }
        let kinds = [stations, stops, shownDocks.map { ("d" + $0.id, $0.dock.coordinate) }]
        let names = busNames
        let opened = alongStops.filter { $0.id == openedStop?.id }
        let along = alongStops.filter { $0.id != openedStop?.id }
        // The opened stop first, as it's what you're looking at
        let drawnAt = { (stop: AlongStop) in busWays[stop.id]?.onLine ?? stop.coordinate }
        return opened.map { ($0.id, drawnAt($0)) }
            + (0..<(kinds.map(\.count).max() ?? 0)).flatMap { index in
                kinds.compactMap { index < $0.count ? $0[index] : nil }
            }
            // Then the stops along their lines, where there's room: those naming lines first
            + along.filter { names[$0.id] != nil }.map { ($0.id, drawnAt($0)) }
            + along.filter { names[$0.id] == nil }.map { ($0.id, drawnAt($0)) }
    }

    /// How each mark shows where the map is now, most important first (`mapMarks`) and clear
    /// of those before it: its sign, if that covers no other place; else a bubble on its place;
    /// else merged into a bubble of its kind near enough, that one then standing for both; else
    /// hidden. A sign never covers another place, so places by a station bubble rather than
    /// vanish; but a bus stop's lines show if no mark covers much of them, and a station's sign
    /// if it covers little of others, or hides under a nearer station's covering much. Where one hides even with bubbles already merged, they're too crowded to show,
    /// and none show.
    private func layOutMarks(_ proxy: MapProxy) {
        let names = busNames
        // A bus stop naming no lines is a dot
        let isDot = { (id: String) in (id.hasPrefix("b") || id.hasPrefix("e")) && names[id] == nil }
        let marks = mapMarks.compactMap { mark -> (id: String, kind: Character, point: CGPoint, stop: CGPoint, sign: CGSize,
                                                   bubble: CGSize)? in
            guard let kind = mark.id.first, let stop = proxy.convert(mark.coordinate, to: .local) else { return nil }
            var point = stop
            // A bus stop's mark not measured yet (the map doesn't always say, for its marks
            // added as it zooms) as big as it's drawn, not left out, covering others unseen
            let isBus = kind == "b" || kind == "e"
            // A station's too, or it'd show its sign over the others
            let estimate = isBus ? BusTagLayout.size(lines: names[mark.id], arrow: busZoom != .far)
                : kind == "s" ? nearby.first { "s" + $0.id == mark.id }.map { Self.stationSignSize($0.station) } : nil
            // A stop's tag as its own lines draw it: not as measured with another's lines put in
            // it, or as a dot, its lines in another's
            let measured = isBus && (markLayout.extraLines[mark.id] != nil || markLayout.joined.contains(mark.id))
                ? nil : markSizes[mark.id]
            guard let sign = measured ?? estimate,
                  let bubble = bubbleSizes[mark.id] ?? (isBus || kind == "s" ? Self.busBubbleSize : nil) else { return nil }
            // A bus stop's where it's drawn, on its way's line, its lines just past it
            if isBus, let offset = placement(of: mark.id, named: names[mark.id] != nil, size: sign)?.offset {
                point.x += offset.width
                point.y += offset.height
            }
            return (mark.id, kind, point, stop, sign, bubble)
        }
        // The lines stopping at each bus stop, for its lines to go in another stop's tag only
        // where they stop there too
        var serves: [String: Set<String>] = [:]
        for place in busPlaces {
            if let stop = place.ways.first?.stop {
                serves["b" + stop.id] = Set(Self.lines(of: place, at: live.mapNow)).union(BusNetwork.stopByID[stop.id]?.lines ?? [])
            }
        }
        for stop in alongStops { serves[stop.id] = Set(stop.lines.map(TrackShapes.busKey)) }
        let close = busZoom == .close
        var tags: [BusTagLayout.Shown] = []
        // Close in, nothing over a bus stop's tag
        let coversTag = { (rect: CGRect) in close && tags.contains { $0.rect.intersects(rect) } }
        // With a little room round it
        func rect(_ point: CGPoint, _ size: CGSize) -> CGRect {
            CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                .insetBy(dx: -3, dy: -3)
        }
        var placed: [CGRect] = []
        // Bubbles whole, as drawn: `placed` has them a little smaller, for bubbles to touch, but
        // a stop's lines keep clear of all of one
        var bubbles: [CGRect] = []
        var layout = MarkLayout()
        var groups: [(leader: String, kind: Character, point: CGPoint, members: [String])] = []
        var hiddenAlone = false
        // The stations' signs placed, nearest first, for farther ones under them to hide
        var stationSigns: [CGRect] = []
        // Each mark's place, once, not again for every mark it's checked against. Stops along
        // the lines don't keep others' signs off their places
        let places = marks.map { $0.kind == "e" || isDot($0.id) ? nil : rect($0.point, $0.bubble) }
        for (index, mark) in marks.enumerated() {
            // Farthest out, only the stations, as icons; wide, no bus stops' dots yet
            if mapDetail == .overview && mark.kind != "s" || mapDetail == .wide && isDot(mark.id) {
                layout.looks[mark.id] = .hidden
                continue
            }
            let sign = rect(mark.point, mark.sign)
            let coversOther = places.indices.contains { $0 != index && places[$0]?.intersects(sign) == true }
            // A dot shows where it's clear of everything, and otherwise not at all, as there are
            // so many
            if isDot(mark.id) {
                let clear = !placed.contains { $0.intersects(sign) }
                if clear { placed.append(sign) }
                layout.looks[mark.id] = clear ? .sign : .hidden
                continue
            }
            // A bus stop's lines clear of the marks before them, where they can be: else in
            // the tag of a stop by it, or moved along their street, or (past close in) over
            // others as long as most shows (`BusTagLayout`)
            var tagHidden = false
            if mark.kind == "b" || mark.kind == "e", let lines = names[mark.id] {
                let angle = busWays[mark.id].map { $0.angle - mapHeading * .pi / 180 } ?? 0
                let tag = BusTagLayout.Tag(id: mark.id, rect: sign, stop: mark.stop, angle: angle, lines: lines,
                                           serves: serves[mark.id] ?? [])
                switch BusTagLayout.place(tag, placed: &placed, shown: &tags, extra: &layout.extraLines, close: close,
                                          width: { BusTagLayout.badgesWidth($0) + CGFloat($0.count) * 2 }) {
                case .shown(let nudge):
                    if nudge != .zero { layout.nudges[mark.id] = nudge }
                    layout.looks[mark.id] = .sign
                    continue
                case .joined:
                    // Its lines in the other's tag: itself a dot, on its line, where that's clear
                    layout.joined.insert(mark.id)
                    let dot = rect(mark.stop, BusTagLayout.size(lines: nil, arrow: busZoom != .far))
                    let clear = !placed.contains { $0.intersects(dot) }
                    if clear { placed.append(dot) }
                    layout.looks[mark.id] = clear ? .sign : .hidden
                    continue
                case .hidden:
                    tagHidden = true
                }
            }
            // A stop along the lines naming some, where they don't fit: never a bubble
            if mark.kind == "e" {
                layout.looks[mark.id] = .hidden
                continue
            }
            // Farthest out, a station's an icon, not its sign
            let signs = !(mapDetail == .overview && mark.kind == "s")
            // A station's sign over a nearer one's, covering much of either: only the nearer
            // shows, till the map's zoomed in to part them; covering a little, both show
            let isStation = mark.kind == "s"
            let underStation = isStation && signs && stationSigns.contains { Self.overlapShare(sign, $0) > Self.stationOverlap }
            if underStation {
                layout.looks[mark.id] = .hidden
                continue
            }
            let stationFits = isStation && placed.allSatisfy { Self.overlapShare(sign, $0) <= Self.stationOverlap }
                && !places.indices.contains { $0 != index && marks[$0].kind != "s" && places[$0]?.intersects(sign) == true }
            if signs && !tagHidden && !coversTag(sign)
                && (stationFits || (!placed.contains(where: { $0.intersects(sign) }) && !coversOther)) {
                placed.append(sign)
                if isStation { stationSigns.append(sign) }
                layout.looks[mark.id] = .sign
                continue
            }
            // Bubbles may touch: only a few points' overlap counts
            let bubble = rect(mark.point, mark.bubble).insetBy(dx: 6, dy: 6)
            if !placed.contains(where: { $0.intersects(bubble) }) && !coversTag(rect(mark.point, mark.bubble)) {
                placed.append(bubble)
                bubbles.append(rect(mark.point, mark.bubble))
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

    /// A bus stop's bubble's size, for one not yet measured.
    private static let busBubbleSize = CGSize(width: 30, height: 24)

    /// How much of a station's sign, or of the one it's over, whichever's more covered, may be
    /// covered and both still show.
    private static let stationOverlap: CGFloat = 0.55

    /// How much of the smaller of `a` and `b` the other covers, 0 to 1.
    private static func overlapShare(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? overlap.width * overlap.height / smaller : 0
    }

    /// About the size `MapSign` draws a station's at, for one not yet measured: its name over
    /// its lines' bullets.
    private static func stationSignSize(_ station: Station) -> CGSize {
        let bullets = CGFloat(station.routes.count) * 17
        return CGSize(width: max(CGFloat(station.name.count) * 6.3, bullets) + 14, height: 41)
    }

    /// Seconds at least between laying the marks out while the map moves: each time is every
    /// mark against every other, on the main thread, and the map moves every frame.
    private static let layoutEvery: TimeInterval = 0.1

    /// How far off a bubble may be from one of its kind to merge into it, in points.
    private static let mergeReach: CGFloat = 60

    /// The lines of the stations and bus stops listed, for the map, and where they're found
    /// from: the map's middle to about 100 m and the listed stops, which the lines' box and the
    /// stops along them go by.
    private var linesKey: [String] {
        // Roughly where (`drawnLinesKey`'s): Nearby moved on, its stops are found along its new
        // places' lines once those load, not first along the last places' too
        let middle = Self.roughly(here)
        let routes: [String] = showsSubway ? ["subway"] : []
        let busLines: [String] = busPlaces.flatMap { $0.lines(at: live.mapNow).map(\.line) }
        let stops: [String] = busPlaces.flatMap { $0.ways.map { "\($0.stop.latitude),\($0.stop.longitude)" } }
        return routes + ["|"] + busLines + ["|", middle] + stops + ["|", openedStop?.id ?? ""]
    }

    /// What the lines drawn depend on: the subway, the bus lines and the stop opened, not where
    /// (each drawn its whole length), nor each re-listing as the map's moved a few blocks. Each
    /// change lays them all out again, so not for less.
    private var drawnLinesKey: [String] {
        let routes: [String] = showsSubway ? ["subway"] : []
        let busLines = Array(drawnBusLines).sorted()
        return routes + ["|"] + busLines + ["|", openedStop?.id ?? ""]
    }

    /// About where `place` is, to a couple of kilometres, for the stops along the lines round it.
    private static func roughly(_ place: CLLocation?) -> String {
        guard let place else { return "" }
        let step = 0.02
        return "\((place.coordinate.latitude / step).rounded()),\((place.coordinate.longitude / step).rounded())"
    }

    /// Every subway line, each its own colour, and the listed bus stops' lines, pale: laid out
    /// off the main thread, where they took a tenth of a second or more on it each time the map
    /// came to rest; not shown if what's drawn has moved on meanwhile.
    private func findLines() async {
        let key = drawnLinesKey
        let points = nearby.map { $0.station.coordinate }
            + busPlaces.compactMap { $0.ways.first.map { CLLocationCoordinate2D(latitude: $0.stop.latitude, longitude: $0.stop.longitude) } }
            + [here?.coordinate, openedStop?.coordinate].compactMap { $0 }
        // With a stop opened, its lines too, and the others faded
        let openedLines = openedStop?.lines ?? []
        let busLines = Array(drawnBusLines)
        let bright = openedStop.map { _ in Set(openedLines.map(TrackShapes.busKey)) }
        let subway = showsSubway
        // Every subway line, the whole system, however far out; the stations' marks keep to the
        // zoom. Laid out at launch, off the main thread: waited on here, off it too
        let found = await Task.detached(priority: .userInitiated) {
            NearbyLines(routes: subway ? NearbyLines.allRoutes : [], busLines: busLines,
                        brightBusLines: bright, around: points)
        }.value
        guard await stillMap() else { return }
        lines = found
        linesVersion += 1
        motion.linesFoundFor = key
        // Its stops along, unless the buses where it's moved on to are still loading: found with
        // them then (`load`), not first round the last place's listed stops and again after
        if !showsBuses || busesAreHere { findStopsAlong() }
    }

    /// Whether the bus stops listed are those round where Nearby is, not still the last place's.
    private var busesAreHere: Bool {
        guard let busesFrom, let here else { return false }
        return busesFrom.distance(from: here) <= Self.followMeters
    }

    /// The stops along the lines drawn, and which way each stop marked's buses go.
    private func findStopsAlong() {
        // Only what's changed: each change draws Nearby again
        let along = findAlongStops()
        if along.map(\.id) != alongStops.map(\.id) {
            // Those no longer marked kept a moment, where they were, to shrink away
            let gone = reduceMotion ? [] : alongStops.filter { old in !along.contains { $0.id == old.id } }
            if !gone.isEmpty || !leavingStops.isEmpty {
                leavingStops = gone + leavingStops.filter { old in !gone.contains { $0.id == old.id } && !along.contains { $0.id == old.id } }
            }
            alongStops = along
            if !gone.isEmpty {
                let ids = Set(gone.map(\.id))
                Task {
                    try? await Task.sleep(for: .seconds(MarkBubble.shrinkTime + 0.15))
                    leavingStops.removeAll { ids.contains($0.id) }
                }
            }
        }
        var ways = findBusWays()
        var names = findBusNames()
        // Those going, as they were
        for stop in leavingStops {
            ways[stop.id] = ways[stop.id] ?? busWays[stop.id]
            names[stop.id] = names[stop.id] ?? busNames[stop.id]
        }
        if ways != busWays { busWays = ways }
        if names != busNames { busNames = names }
    }

    /// Which way each bus stop marked's buses go, from which side of its street it's on.
    private func findBusWays() -> [String: BusSides.Way] {
        var ways: [String: BusSides.Way] = [:]
        for place in busPlaces {
            guard let stop = place.ways.first?.stop else { continue }
            // Where the network has the stop, on its line already, the way its buses go there;
            // else the nearest of its lines'
            if let known = BusNetwork.stopByID[stop.id] {
                ways["b" + stop.id] = BusSides.Way(angle: known.angle, onLine: known.coordinate)
                continue
            }
            let keys = Self.lines(of: place, at: live.mapNow)
            ways["b" + stop.id] = lines.sides.way(at: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude),
                                                  lines: keys)
        }
        for stop in alongStops {
            if let angle = stop.angle {
                ways[stop.id] = BusSides.Way(angle: angle, onLine: stop.coordinate)
            } else {
                ways[stop.id] = lines.sides.way(at: stop.coordinate, lines: stop.lines.map(TrackShapes.busKey))
            }
        }
        return ways
    }

    /// Meters from the map's middle other stations show, zoomed out wide, and how many at most.
    private static let otherStationsReach: Double = 2500
    private static let otherStationsMost = 12

    /// The stations round where Nearby is, past those listed, nearest first, for the map zoomed
    /// out wide to show what else is about.
    private var otherStations: [Station] {
        guard let here else { return [] }
        // By complex: a listed station's other platforms (Atlantic Av's 2/3/4/5 and B/D/N/Q/R)
        // aren't another station, nor is each of an other's
        var seen = Set(nearby.map(\.station.complex))
        let degrees = Self.otherStationsReach / Earth.metresPerDegree
        return StationDirectory.all
            .filter { abs($0.coordinate.latitude - here.coordinate.latitude) < degrees
                && abs($0.coordinate.longitude - here.coordinate.longitude) < degrees * 1.4 }
            .map { (station: $0, meters: $0.location.distance(from: here)) }
            .filter { $0.meters < Self.otherStationsReach }
            .sorted { $0.meters < $1.meters }
            .filter { seen.insert($0.station.complex).inserted }
            .prefix(min(Self.otherStationsMost, max(0, Self.mostMarks - listedMarks)))
            .map(\.station)
    }

    /// An other station's icon tapped: the map zoomed in on it, for Nearby to list what's there.
    private func zoom(toStation station: Station) {
        let region = MKCoordinateRegion(center: station.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008))
        withAnimation(.smooth) { camera = framing(region) }
    }

    /// Where a bus stop's mark sits off its place on its way's line (`busWays`), at the map's
    /// zoom (`busZoom`): zoomed out, on it; closer, on it with an arrow the way its buses go,
    /// its lines (`named`) just past it on the kerb side. Nil on its place.
    private func placement(of id: String, named: Bool, size: CGSize? = nil) -> BusMarkPlacement? {
        guard let way = busWays[id], busZoom != .far else { return nil }
        // On the screen, turned as the map is
        let angle = way.angle - mapHeading * .pi / 180
        // A sign's middle out far enough for its edge to clear the line. Not measured yet: about
        // one line's pill
        let size = size ?? markSizes[id] ?? (named ? CGSize(width: 44, height: 21) : .zero)
        return BusMarkPlacement(angle: angle, out: named ? BusTagLayout.kerbOffset(angle: angle, size: size) : 0,
                                arrow: true, mapAngle: way.angle)
    }

    /// A stop along a listed bus stop's lines, marked with its lines but not listed.
    private struct AlongStop: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let lines: [String]
        /// The way its buses go (`TrackShapes.BusStop.angle`), where it's one of the network's.
        var angle: Double?
    }

    /// Meters from the map's middle stops along the lines are marked, how far apart those of the
    /// same lines are (about every other block, so each way's stops a block apart are one, or
    /// past zoomed out, those going the same way), and how many at most, nearest first.
    private static let alongReach: Double = 1500
    private static let alongApart: Double = 150
    /// Meters from a listed stop another isn't marked, as it's the listed one's other way (past
    /// zoomed out, as it's the listed one, going its way); and any nearer, as it's the listed one.
    private static let listedApart: Double = 60
    private static let sameStop: Double = 15
    private static let alongMost = 40
    /// Marks on Nearby's map at most, those nearest its middle (11/9): each is a view MapKit
    /// moves and lays out, and more held the map up.
    private static let mostMarks = 20

    /// The marks the listed places have: stations, bus stops, docks.
    private var listedMarks: Int {
        (showsSubway ? nearby.count : 0) + busPlaces.count + shownDocks.count
    }
    /// Each line's stops kept each way it goes, nearest first, the listed ones among them (11/9).
    private static let alongEachWay = 5

    /// The stops along the listed bus stops' lines round the map's middle, but not those listed,
    /// nor zoomed out, the other side of the street from one marked; past zoomed out, each way's.
    private func findAlongStops() -> [AlongStop] {
        let drawn = drawnBusLines
        guard let center = here, !drawn.isEmpty else { return [] }
        let eachWay = busZoom != .far
        // The way a stop's buses go, past zoomed out
        let angle = { (stop: TrackShapes.BusStop) -> Double? in
            eachWay ? stop.angle ?? lines.sides.way(at: stop.coordinate, lines: stop.lines)?.angle : nil
        }
        // Going the same way, or either's way unknown
        let sameWay = { (a: Double?, b: Double?) -> Bool in
            guard let a, let b else { return true }
            return cos(a - b) > 0
        }
        // Zoomed out, the listed stops' places; past it, only the stop each shows, with its way
        let listed: [(place: CLLocation, angle: Double?)] = busPlaces.flatMap { place in
            let ways = eachWay ? Array(place.ways.prefix(1)) : place.ways
            let lines = place.lines(at: live.mapNow).map { TrackShapes.busKey($0.line) }
            return ways.map { way in
                let coordinate = CLLocationCoordinate2D(latitude: way.stop.latitude, longitude: way.stop.longitude)
                return (CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                        angle(TrackShapes.BusStop(coordinate: coordinate, lines: lines)))
            }
        }
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
        var kept: [(stop: TrackShapes.BusStop, place: CLLocation, angle: Double?)] = []
        // The opened stop kept, wherever it is
        if let opened = openedStop {
            let place = CLLocation(latitude: opened.coordinate.latitude, longitude: opened.coordinate.longitude)
            let stop = TrackShapes.BusStop(coordinate: opened.coordinate, lines: opened.lines.map(TrackShapes.busKey))
            kept.append((stop, place, angle(stop)))
        }
        // How many of each line's stops are kept each way it goes (`alongEachWay`): the way
        // each line's first goes, and how many its way and the other
        var firstWay: [String: Double] = [:]
        var counts: [String: Int] = [:]
        // The way a stop's buses go on `line`, as counted: its own, or the other
        func wayKey(_ line: String, _ stop: TrackShapes.BusStop) -> String {
            guard let angle = stop.angle ?? lines.sides.way(at: stop.coordinate, lines: [line])?.angle else { return line }
            guard let first = firstWay[line] else {
                firstWay[line] = angle
                return line
            }
            return cos(angle - first) > 0 ? line : line + " other"
        }
        // The listed stops count among each line's nearest
        for place in busPlaces {
            for way in place.ways {
                let stop = TrackShapes.BusStop(coordinate: CLLocationCoordinate2D(latitude: way.stop.latitude, longitude: way.stop.longitude),
                                               lines: place.lines(at: live.mapNow).map { TrackShapes.busKey($0.line) })
                for line in stop.lines where drawn.contains(line) { counts[wayKey(line, stop), default: 0] += 1 }
            }
        }
        // Room left of `mostMarks` once the listed places have theirs, nearest the middle first
        let room = max(0, min(Self.alongMost, Self.mostMarks - listedMarks))
        for (stop, place, _) in candidates where kept.count < room {
            let way = angle(stop)
            // Only while one of its lines, the way it goes, has fewer than its nearest few
            let keys = stop.lines.filter(drawn.contains).map { wayKey($0, stop) }
            guard keys.contains(where: { counts[$0, default: 0] < Self.alongEachWay }) else { continue }
            guard !listed.contains(where: { listed in
                      let meters = listed.place.distance(from: place)
                      return meters < Self.sameStop || (meters < Self.listedApart && sameWay(listed.angle, way))
                  }),
                  !kept.contains(where: { $0.place.distance(from: place) < 1 }),
                  !kept.contains(where: { $0.stop.lines == stop.lines && $0.place.distance(from: place) < Self.alongApart
                      && sameWay($0.angle, way) }) else { continue }
            kept.append((stop, place, way))
            for key in keys { counts[key, default: 0] += 1 }
        }
        return kept.map { stop, _, _ in
            AlongStop(id: "e\(stop.coordinate.latitude),\(stop.coordinate.longitude)", coordinate: stop.coordinate, lines: stop.lines,
                      angle: stop.angle)
        }
    }

    /// Everything on the map, to frame it again when they change.
    private var framedIDs: [String] { mapMarks.map(\.id).filter { !$0.hasPrefix("e") } }

    /// How far across Nearby's map starts, round you: about a dozen blocks. Navigate's starts
    /// the same (`NewTripView.frameStart`).
    static let framedMeters: CLLocationDistance = 1_000

    /// Frames you, `framedMeters` across, whatever's near. Not once you've moved, zoomed or
    /// turned the map, which stays where you put it.
    private func frame() {
        // Everything toggled off: leave the map where it is
        guard mapCenter == nil, !motion.cameraMovedByHand, let here, showsSubway || showsBuses || showsBikes else { return }
        let region = MKCoordinateRegion(center: here.coordinate,
                                        latitudinalMeters: Self.framedMeters, longitudinalMeters: Self.framedMeters)
        // Where it comes to rest is where this put it, not a move of yours
        framingUntil = .now.addingTimeInterval(1.5)
        motion.userMovedMap = false
        withAnimation(.smooth) { camera = framing(region) }
    }

    /// The grey dot tapped: the map zoomed in on its middle, `framedMeters` across, as Nearby
    /// starts round you, still listing what's there.
    private func zoomToMiddle() {
        guard let center = motion.shownCamera?.centerCoordinate else { return }
        let region = MKCoordinateRegion(center: center,
                                        latitudinalMeters: Self.framedMeters, longitudinalMeters: Self.framedMeters)
        // Where it comes to rest is where this put it; but zoomed by your tap, so not framed
        // back on you by the next load
        framingUntil = .now.addingTimeInterval(1.5)
        motion.cameraMovedByHand = true
        withAnimation(.smooth) { camera = framing(region) }
    }

    /// `region` framed on the map, turned as you left it, or Grid North if Settings says.
    private func framing(_ region: MKCoordinateRegion) -> MapCameraPosition {
        MapNorth.position(fitting: MKMapRect(region), heading: framedHeading, in: room,
                          northUp: keptHeading != nil) ?? .region(region)
    }

    /// The compass tapped: the map turned `heading` where it is, and framed that way after.
    private func turnMap(to heading: Double) {
        guard let shownCamera = motion.shownCamera else { return }
        keptHeading = MapNorth.isOff(heading, from: MapNorth.heading(ny: nyNorth)) ? heading : nil
        // Where it comes to rest is where this put it
        framingUntil = .now.addingTimeInterval(1.5)
        withAnimation(.smooth) {
            camera = .camera(MapCamera(centerCoordinate: shownCamera.centerCoordinate, distance: shownCamera.distance,
                                       heading: heading, pitch: shownCamera.pitch))
        }
    }

    /// Which way the map's framed: as you turned it, or Settings' way.
    private var framedHeading: Double { keptHeading ?? MapNorth.heading(ny: nyNorth) }

    /// The map come to rest turned `heading`: turned off where it last rested, not by this
    /// page framing it, it's you, by hand or the compass (which doesn't leave the camera
    /// positioned by the user), so kept; back to Settings' way, nothing's kept.
    private func keepHeading(_ heading: Double) {
        defer { motion.restHeading = heading }
        guard let restHeading = motion.restHeading, Date.now > framingUntil, MapNorth.isOff(heading, from: restHeading) else { return }
        keptHeading = MapNorth.isOff(heading, from: MapNorth.heading(ny: nyNorth)) ? heading : nil
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
            .accessibilityLabel("\(Self.miles(you.distance(from: mapCenter))) from you")
            .accessibilityHint("Recenters the map on you")
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
        .accessibilityValue(eBike ? "E-bikes only" : "")
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
        // On its side, top to bottom down the left, its list scrolling within it
        .frame(maxHeight: sideways && cardPanel != nil ? .infinity : nil, alignment: .bottom)
        .clipShape(Self.card)
        .glassEffect(.regular, in: Self.card)
        .animation(.smooth, value: cardPanel)
        // The list's height, once measured, grows and shrinks the card smoothly too, as does
        // a place's opening and closing
        .animation(.smooth, value: trainsHeight)
        .animation(.smooth, value: listMax)
    }

    /// How tall the list may be before it scrolls: the card's `cardHeight` over its modes row;
    /// on its side, the card's whole height.
    private var listMax: CGFloat {
        if sideways, sideListHeight > 0 { return sideListHeight }
        return Self.cardHeight - Self.modesRowHeight
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
                // On its side, less round it, to fit the card's height
                .padding(.vertical, sideways ? 4 : 16)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: sideways ? .infinity : nil)
                Divider()
            } else if listing {
                ScrollView {
                    trains
                        .coordinateSpace(.named(Self.tilesSpace))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { trainsHeight = $0 }
                }
                .scrollPosition($cardScroll)
                // A kind switched on or off starts the card at its top again, not part way down
                .onChange(of: [showsSubway, showsBuses, showsCitiBike]) {
                    withAnimation(.smooth) { cardScroll.scrollTo(edge: .top) }
                }
                // A place tapped on its map mark: its first tile at the top of the card, or, near
                // the list's end, as far up as it goes, with no blank room under it
                .onChange(of: focusedMark) { _, mark in
                    guard let mark else { return }
                    focusedMark = nil
                    let shown = listMax
                    guard trainsHeight > shown, let top = tileTops[mark] else { return }
                    let target = min(max(0, top - Self.tilesMargin), trainsHeight - shown)
                    withAnimation(.smooth) { cardScroll.scrollTo(y: target) }
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("nearbyCard")
                // Its blur at the edges drew a place scrolled off the top over the card's edge
                .scrollEdgeEffectHidden()
                .clipped()
                // On its side, filling the card down the left
                .frame(height: sideways ? nil : min(trainsHeight, listMax))
                .frame(maxHeight: sideways ? .infinity : nil)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sideListHeight = $0 }
                Divider()
            } else if showsSubway || showsBuses || showsBikes {
                emptyState
                    .padding(.vertical, sideways ? 4 : 16)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: sideways ? .infinity : nil)
                Divider()
            }
        }
    }

    /// Any failure note, then the lines near you as tiles, two to a row, each with its next
    /// train or bus each way; then the docks, each a row, its counts once it's opened.
    private var trains: some View {
        VStack(alignment: .leading, spacing: 0) {
            if live.anyFailed(everyTrain) {
                UnreachableNote(timetable: live.anyFromTimetable(everyTrain))
                    .font(.subheadline)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }
            // Only roughly where you are: what's nearest may not be
            if location.isAllowed && !location.isPrecise {
                Label("Precise Location is off", systemImage: "location.slash")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }
            // Each line once, at its nearest station or stop, two to a row; a place tapped on
            // the map has its own lines, outlined
            NearbyLineGrid(stations: gridStations, stops: gridStops, docks: gridDocks, picked: openedPlace,
                           live: live, marks: marks, tops: $tileTops,
                           openTrains: { path.append($0) }, openBus: { path.append($0) })
            if showsBuses { busNote }
            if showsBikes { dockNote }
            if !SharedStore.isAvailable {
                Label("The widget can't see your choice on this install, so it keeps showing 14 St-Union Sq (N Q R W) uptown. Make sure the app and widget both have the App Group in Xcode, then reinstall.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.top, 8)
            }
        }
        .padding(Self.tilesMargin)
    }

    /// Why there's no bus stop to put lines from, or that they're being found.
    @ViewBuilder private var busNote: some View {
        switch buses {
        case .finding:
            NearbyNoteRow(text: "Finding bus stops…", finding: true)
        case .unavailable:
            NearbyNoteRow(text: "Bus times aren't available right now.")
        case .places(let places) where places.isEmpty:
            NearbyNoteRow(text: "No bus stops within ¼ mile.")
        case .places:
            if busesStale { NearbyNoteRow(text: "Bus times couldn't be updated.") }
        }
    }

    /// The stations whose lines the grid shows, nearest first; none with Subway off.
    private var gridStations: [NearbyGridPlace] {
        guard showsSubway else { return [] }
        return nearby.map { result in
            NearbyGridPlace(id: result.markID, name: result.station.name,
                            distance: distance(of: result.markID, walkMinutes: result.walkMinutes, at: result.station.location),
                            kind: .station(result.station))
        }
    }

    /// The bus stops whose lines the grid shows, nearest first: the stop opened from its dot
    /// too, while it's open, its lines waiting on its buses till they come.
    private var gridStops: [NearbyGridPlace] {
        guard showsBuses else { return [] }
        let listed = busPlaces.map { place in
            let stop = place.ways.first?.stop
            let id = "b" + (stop?.id ?? "")
            return NearbyGridPlace(id: id, name: place.name,
                                   distance: distance(of: id, walkMinutes: place.walkMinutes,
                                                      at: CLLocation(latitude: stop?.latitude ?? 0, longitude: stop?.longitude ?? 0)),
                                   kind: .stop(place, lines: [], stale: busesStale))
        }
        guard let opened = openedStop else { return listed }
        let at = CLLocation(latitude: opened.coordinate.latitude, longitude: opened.coordinate.longitude)
        let distance: NearbyDistance? = location.location.map { you in
            mapCenter == nil ? .walk(TripPlanner.walkMinutes(you.distance(from: at))) : .fromYou(Self.miles(you.distance(from: at)))
        }
        let place = NearbyGridPlace(id: opened.id, name: opened.place?.name ?? "Bus Stop", distance: distance,
                                    kind: .stop(opened.place, lines: opened.lines, stale: opened.failed))
        return [place] + listed
    }

    /// Why there's no dock to show, or that they're being found.
    @ViewBuilder private var dockNote: some View {
        if docksFailed {
            NearbyNoteRow(text: "Citi Bike isn't available right now.")
        } else if docks != nil, let bikes {
            if shownDocks.isEmpty {
                NearbyNoteRow(text: "No docks with \(bikes == .eBike ? "e-bikes" : "bikes") within ½ mile.")
            }
        } else {
            NearbyNoteRow(text: "Finding Citi Bike docks…", finding: true)
        }
    }

    /// The nearest docks with the bikes Settings counts, each a tile after the lines'.
    private var gridDocks: [NearbyGridPlace] {
        shownDocks.map { near in
            NearbyGridPlace(id: near.markID, name: near.dock.name,
                            distance: distance(of: near.markID, walkMinutes: near.walkMinutes, at: near.dock.location),
                            kind: .dock(near.dock))
        }
    }

    /// Whether there's a place to list stations near: the moved map's middle, or your location
    /// once found, or setup's Home before it is.
    private var showsStations: Bool {
        mapCenter != nil || (location.isAllowed && !location.failed && location.location != nil)
            || (location.location == nil && setupHome.location != nil)
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

    /// Loads what's switched on together. Rows show a dash until their first load. What hasn't
    /// changed since it was last fetched, lately, isn't fetched again (`refetchAfter`,
    /// `docksLife`), as a toggle restarts the load for its own; `pulled` to refresh, all of it.
    private func load(pulled: Bool = false) async {
        let here = here
        // The stations where Nearby is now, listed with what else loads (below)
        let stations = here.map { Nearby.stations(near: $0, limit: 3) } ?? []
        let trains = showsSubway ? stations.flatMap(\.station.lineSelections) : []
        let wantsBuses = showsBuses, wantsBikes = showsBikes
        let now = Date.now
        // Where you are, kept while you're near it (`here`)
        if mapCenter == nil, setupHome.location == nil, location.location != nil { loadedYou = here }
        let trainIDs = trains.map(\.trainID)
        let trainsFresh = !pulled && !live.anyFailed(trains)
            && trainsLoaded.map { $0.ids == trainIDs && now.timeIntervalSince($0.at) < Self.refetchAfter } == true
        let busesFresh: Bool = if !pulled, !busesStale, case .places = buses, let busesLoaded, let busesFrom, let here {
            now.timeIntervalSince(busesLoaded) < Self.refetchAfter && busesFrom.distance(from: here) < 1
        } else { false }
        // The five nearest with the bikes counted to take, so each of them can show
        let has = bikes.map { CitiBike.Has(taking: $0.shared) } ?? .either
        let docksFresh: Bool = if !pulled, docks != nil, !docksFailed, let docksLoaded, let here {
            now.timeIntervalSince(docksLoaded.at) < Self.docksLife && docksLoaded.near.distance(from: here) <= Self.followMeters
                && docksLoaded.has == has
        } else { false }
        // Longer than the widget's wait: a place newly moved to has the server ask Bus Time for
        // its stops before their buses, which often took past 3 seconds and left none shown
        async let busPlaces: [NearbyBusPlace]? = if wantsBuses, !busesFresh, let here {
            await NearbyBuses.places(near: here, wait: NearbyBuses.appWait)
        } else { nil }
        // Only the few nearest, not the whole city's
        async let nearDocks: [CitiBike.Dock]? = if wantsBikes, !docksFresh, let here {
            await CitiBike.docks(near: here, limit: Self.docksAsked, has: has)
        } else { nil }
        // Nearby rows show only the line's own trains, which are all in its own feeds
        if !trainsFresh {
            await live.load(trains, includingOtherLines: false)
            if !Task.isCancelled, !trains.isEmpty { trainsLoaded = (trainIDs, .now) }
        }
        // Loads not cancelled by a move (recentering, coming back to the app) may finish after
        // the one for where Nearby is now: not stops and docks near where it was
        let stillHere = {
            guard !Task.isCancelled else { return false }
            guard let now = self.here, let here else { return true }
            return now.distance(from: here) <= Self.followMeters
        }
        let found = await nearDocks
        let places = await busPlaces
        // All of it at once, once the map's still: each on its own drew Nearby and its marks
        // again, a dozen times as it moved on, taking the map's moving after up with it
        guard await stillMap(), stillHere() else { return }
        if nearby.map(\.id) != stations.map(\.id) { nearby = stations }
        if wantsBikes, !docksFresh, let here {
            docksFailed = found == nil
            docks = found.map { NearbyDock.nearest(to: here, among: $0, limit: Self.docksAsked) }
            docksLoaded = found == nil ? nil : (.now, here, has)
        }
        // The opened stop's buses from those found round here, if it's among them; else asked
        // for on their own
        let openedFound = takeOpened(from: places ?? (busesFresh ? buses.places : []))
        if wantsBuses, !busesFresh, let here {
            if let places {
                buses = .places(places)
                busesFrom = here
                busesStale = false
                busesLoaded = .now
            } else {
                // A failed refresh keeps the stops last found, rather than dropping them; not
                // once the map's moved on, where they'd be listed as near somewhere they aren't
                let samePlace = busesFrom.map { $0.distance(from: here) <= Self.followMeters } ?? false
                let keeps = !buses.places.isEmpty && samePlace
                buses = keeps ? buses : .unavailable
                busesStale = keeps
            }
        }
        if !(trainsFresh && busesFresh && docksFresh) { updated = AppClock.now }
        // With them, not a drawing after: the stops along the lines, if those are laid out
        if motion.linesFoundFor == drawnLinesKey { findStopsAlong() }
        if !openedFound { await loadOpened() }
    }

    /// Waits for the map to be still, for what's found to be shown then rather than as it's
    /// moving; false if what it was for is no longer wanted.
    private func stillMap() async -> Bool {
        // A couple of seconds at most: were the map's coming to rest ever missed, nothing would
        // be shown again, nor a pull to refresh end, till it was touched
        var waited = 0
        while motion.moving, waited < Self.stillWaitMost {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
            waited += 1
        }
        motion.moving = false
        return !Task.isCancelled
    }

    /// Tenths of a second at most `stillMap` waits.
    private static let stillWaitMost = 20
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
enum NearbyDistance: Hashable {
    /// Minutes' walk from you
    case walk(Int)
    /// "1.2 miles"
    case fromYou(String)
}

/// A station or bus stop whose lines Nearby's grid shows, with how far it is.
struct NearbyGridPlace: Hashable {
    enum Kind: Hashable {
        case station(Station)
        /// Its buses, once found; till then, the lines it's known to have (a stop opened from
        /// its dot). `stale`: kept from before a failed refresh, or, not found, couldn't be.
        case stop(NearbyBusPlace?, lines: [String], stale: Bool)
        case dock(CitiBike.Dock)
    }

    /// Its map mark's id.
    let id: String
    let name: String
    let distance: NearbyDistance?
    let kind: Kind
}

/// Every line near you as a tile, two to a row: each once, at the nearest station or stop it
/// stops at, with its next train or bus each way; trains before buses. A place tapped on the
/// map (`picked`) has its own lines, outlined, first. Its own view, so the ticks that count
/// the times down redraw it alone, not the whole page and its map.
struct NearbyLineGrid: View {
    let stations: [NearbyGridPlace]
    let stops: [NearbyGridPlace]
    let docks: [NearbyGridPlace]
    let picked: String?
    let live: LiveTrains
    let marks: TimeMarks
    /// Where each place's first tile starts, for a tap on its map mark to scroll there.
    @Binding var tops: [String: CGFloat]
    /// Opens a train tile's line page, and a bus tile's.
    let openTrains: (LineWays) -> Void
    let openBus: (BusLineWays) -> Void

    /// One line at one place, and its ways.
    struct Tile: Identifiable {
        enum Ways {
            case trains([LineWay])
            /// Nil while the stop's buses are being found.
            case buses([NearbyBusPick.Way]?, stale: Bool)
            /// A Citi Bike dock's bikes, both kinds, and its open docks.
            case dock(CitiBike.Dock)
        }

        let line: String
        let place: NearbyGridPlace
        let ways: Ways
        /// Whether it's its place's first, which notes where the place starts.
        var first = false

        var id: String {
            switch ways {
            case .trains: "s" + line
            case .buses: "b" + line
            case .dock: place.id
            }
        }
        var isBus: Bool { if case .buses = ways { true } else { false } }
    }

    /// The tiles as last worked out, and what for: the body's run again for every change to the
    /// page round it (each move of the map, the card's height), when they're the same, and
    /// working out each station's ways took a good part of the main thread's time.
    @State private var memo = TilesMemo()

    /// Every tile: the stations', then the stops', then the docks'.
    private var all: [Tile] {
        memo.tiles(for: TilesMemo.Key(stations: stations, stops: stops, docks: docks, picked: picked,
                                      trains: live.trains, now: live.now)) {
            Self.tiles(stations: stations, stops: stops, docks: docks, picked: picked, trains: live.trains, now: live.now)
        }
    }

    /// The tiles kept for the inputs they were worked out from.
    final class TilesMemo {
        struct Key: Equatable {
            let stations: [NearbyGridPlace]
            let stops: [NearbyGridPlace]
            let docks: [NearbyGridPlace]
            let picked: String?
            let trains: [String: [Arrival]]
            let now: Date
        }

        private var key: Key?
        private var kept: [Tile] = []

        /// `make`'s tiles, or those kept if `key`'s the same as theirs.
        func tiles(for key: Key, make: () -> [Tile]) -> [Tile] {
            if key == self.key { return kept }
            kept = make()
            self.key = key
            return kept
        }
    }

    /// Every tile: the stations', then the stops', then the docks', each `tiles(_:)`.
    static func tiles(stations: [NearbyGridPlace], stops: [NearbyGridPlace], docks: [NearbyGridPlace], picked: String?,
                      trains: [String: [Arrival]], now: Date) -> [Tile] {
        tiles(stations, picked: picked, trains: trains, now: now) + tiles(stops, picked: picked, trains: trains, now: now)
            + tiles(docks, picked: picked, trains: trains, now: now)
    }

    /// `places`' lines, each line once: at `picked`, if it has it, else the nearest. In `places`'
    /// order whatever's picked, so a tile tapped on the map stays where the card scrolls to.
    static func tiles(_ places: [NearbyGridPlace], picked: String?, trains: [String: [Arrival]], now: Date) -> [Tile] {
        let ordered = places.filter { $0.id == picked } + places.filter { $0.id != picked }
        var seen: Set<String> = []
        var byPlace: [String: [Tile]] = [:]
        for place in ordered {
            var found: [Tile] = []
            switch place.kind {
            case .station(let station):
                for route in station.routes where !seen.contains(route) {
                    let ways = station.ways(of: route, trains: trains, now: now).compactMap { $0 }
                    guard !ways.isEmpty else { continue }
                    seen.insert(route)
                    found.append(Tile(line: route, place: place, ways: .trains(ways)))
                }
            case .stop(let bus, let lines, let stale):
                if let bus {
                    let picks = bus.lines(at: now)
                        .sorted { $0.line.localizedStandardCompare($1.line) == .orderedAscending }
                    for pick in picks where seen.insert(BusBadge.label(pick.line).uppercased()).inserted {
                        found.append(Tile(line: pick.line, place: place, ways: .buses(pick.ways, stale: stale)))
                    }
                } else {
                    for line in lines where seen.insert(BusBadge.label(line).uppercased()).inserted {
                        found.append(Tile(line: line, place: place, ways: .buses(nil, stale: stale)))
                    }
                }
            case .dock(let dock):
                found.append(Tile(line: "", place: place, ways: .dock(dock)))
            }
            if !found.isEmpty { found[0].first = true }
            byPlace[place.id] = found
        }
        return places.flatMap { byPlace[$0.id] ?? [] }
    }

    var body: some View {
        let all = all
        PairedRows(items: all, spacing: 8) { tile($0) }
        .padding(.top, all.isEmpty ? 0 : 4)
        .padding(.bottom, all.isEmpty ? 0 : 4)
        .animation(.smooth, value: picked)
    }

    /// The whole tile one button, opening its line both ways; a dock's, and a stop's still being
    /// found, just the tile.
    @ViewBuilder private func tile(_ tile: Tile) -> some View {
        let isPicked = tile.place.id == picked
        let content = NearbyLineTile(tile: tile, now: live.now, failed: live.failed, marks: marks)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        Group {
            if opens(tile) {
                Button {
                    open(tile)
                } label: {
                    content
                }
                .buttonStyle(TileButtonStyle(shape: Self.shape))
            } else {
                content.background(.fill.quaternary, in: Self.shape)
            }
        }
        .overlay {
            if isPicked { Self.shape.strokeBorder(.tint, lineWidth: 2) }
        }
        // One element saying all it shows, standing in for the button: not also its bullet,
        // place, walk and each way's name and time, eight more for the tree to hold each tile
        .accessibilityRepresentation {
            let label = NearbyLineTile.spokenLabel(tile)
            Group {
                if opens(tile) {
                    Button(label) { open(tile) }
                        .accessibilityHint(tile.isBus ? "Shows its buses both ways" : "Shows its trains both ways")
                } else {
                    Text(label)
                }
            }
            .accessibilityValue(NearbyLineTile.spokenTimes(tile, now: live.now, failed: live.failed))
            .accessibilityAddTraits(isPicked ? [.isSelected, .updatesFrequently] : .updatesFrequently)
        }
        .modifier(NotingFirst(id: tile.first ? tile.place.id : nil, tops: $tops))
    }

    /// Your walk to the tile's place, while the map's on you.
    private func walkMinutes(_ tile: Tile) -> Int? {
        if case .walk(let minutes) = tile.place.distance { minutes } else { nil }
    }

    private func opens(_ tile: Tile) -> Bool {
        switch tile.ways {
        case .trains: true
        case .buses(let ways, _): ways != nil
        case .dock: false
        }
    }

    private func open(_ tile: Tile) {
        switch tile.ways {
        case .trains(let ways):
            openTrains(LineWays(ways: ways.map { way in
                var selection = way.selection
                selection.walkMinutes = walkMinutes(tile) ?? 0
                return LineWays.Way(selection: selection, label: way.label)
            }))
        case .buses(let ways, _):
            guard let ways else { return }
            openBus(BusLineWays(line: tile.line, stopName: tile.place.name, ways: ways, walkMinutes: walkMinutes(tile)))
        case .dock:
            break
        }
    }

    private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
}

/// Notes where a place's first tile starts, under its map mark's id.
private struct NotingFirst: ViewModifier {
    let id: String?
    @Binding var tops: [String: CGFloat]

    func body(content: Content) -> some View {
        if let id {
            content.notingTop(of: id, in: $tops)
        } else {
            content
        }
    }
}

/// A tile's fill, darker while pressed.
private struct TileButtonStyle<S: Shape>: ButtonStyle {
    let shape: S

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.quaternary), in: shape)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

/// Citi Bike's blue square with a bike, where a line's bullet is on a dock's tile.
private struct DockTileBadge: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "bicycle")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.citiBike, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One line's tile: its bullet or badge, where it's nearest and how far, then its next train
/// or bus each way; one button, said as one.
struct NearbyLineTile: View {
    let tile: NearbyLineGrid.Tile
    let now: Date
    let failed: Set<String>
    let marks: TimeMarks

    private var distance: String? { Self.distance(tile) }

    /// How far its place is, as shown: "3 min walk", or miles while the map's off you.
    private static func distance(_ tile: NearbyLineGrid.Tile) -> String? {
        switch tile.place.distance {
        case .walk(let minutes): "\(minutes) min walk"
        case .fromYou(let miles): miles
        case nil: nil
        }
    }

    /// For VoiceOver, the line, where and how far: "R train at 4 Av-9 St, 1 min walk".
    static func spokenLabel(_ tile: NearbyLineGrid.Tile) -> String {
        let line = switch tile.ways {
        case .trains: Lines.spokenName(of: tile.line)
        case .buses: BusBadge.spokenName(tile.line)
        case .dock: "Citi Bike dock"
        }
        return "\(line) at \(tile.place.name)" + (distance(tile).map { ", \($0)" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                switch tile.ways {
                case .trains: LineBullet(route: tile.line, size: 28)
                case .buses: BusBadge(line: tile.line, size: 28)
                case .dock: DockTileBadge(size: 28)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(tile.place.name).font(.caption.weight(.semibold)).lineLimit(1)
                    if let distance {
                        Text(distance).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            switch tile.ways {
            case .trains(let ways):
                ForEach(ways, id: \.direction) { way in
                    row(way.label, next: way.trains?.first, loaded: way.trains != nil,
                        failed: failed.contains(way.selection.trainID))
                }
            case .buses(let ways, let stale):
                if let ways {
                    ForEach(ways, id: \.stop.id) { way in
                        row(way.name, next: next(way, stale: stale), loaded: true, failed: false, fitted: true)
                    }
                } else if stale {
                    Text("Bus times aren't available").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .dock(let dock):
                countsRow(dock.renting ? "Bikes" : "Not renting",
                          [(dock.available(.bike), "bicycle"), (dock.available(.eBike), "bolt.fill")])
                countsRow(dock.returning ? "Open Docks" : "Not taking bikes", [(dock.free, "parkingsign")])
            }
        }
        .padding(10)
        // Said as one by the tile round it (`NearbyLineGrid.tile(_:)`)
    }

    /// A bus way's next bus, as an arrival.
    private func next(_ way: NearbyBusPick.Way, stale: Bool) -> Arrival? {
        Self.next(way, line: tile.line, stale: stale, now: now)
    }

    private static func next(_ way: NearbyBusPick.Way, line: String, stale: Bool, now: Date) -> Arrival? {
        way.arrivals.first { ($0.time ?? .distantPast) > now }
            .flatMap { bus in
                bus.time.map { Arrival(route: line, time: $0, stop: way.stop.id,
                                       lastStop: bus.destination ?? "", isLive: bus.isLive && !stale) }
            }
    }

    /// For VoiceOver, each way's next as shown: "Manhattan, 4 minutes; Brooklyn, now".
    static func spokenTimes(_ tile: NearbyLineGrid.Tile, now: Date, failed: Set<String>) -> String {
        switch tile.ways {
        case .trains(let ways):
            return ways.map { "\($0.label), \(Minutes.spoken($0.trains, failed: failed.contains($0.selection.trainID), now: now, count: 1))" }
                .joined(separator: "; ")
        case .buses(let ways, let stale):
            guard let ways else { return stale ? "Bus times aren't available" : "Loading" }
            return ways.map { way in
                let next = next(way, line: tile.line, stale: stale, now: now)
                // "None", as shown, not Minutes' "No trains"
                return "\(way.name), \(next.map { Minutes.spoken([$0], now: now, count: 1) } ?? "None")"
            }
            .joined(separator: "; ")
        case .dock(let dock):
            return [dock.renting ? nil : "Not renting",
                    "\(dock.available(.bike)) \(dock.available(.bike) == 1 ? "bike" : "bikes")",
                    "\(dock.available(.eBike)) \(dock.available(.eBike) == 1 ? "e-bike" : "e-bikes")",
                    dock.returning ? "\(dock.free) open \(dock.free == 1 ? "dock" : "docks")" : "Not taking bikes back"]
                .compactMap { $0 }
                .joined(separator: ", ")
        }
    }

    /// A dock's row, as a line's way: what it's for, and its counts at the end in Citi Bike blue,
    /// grey at none.
    private func countsRow(_ name: String, _ counts: [(count: Int, symbol: String)]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            ForEach(Array(counts.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 2) {
                    Image(systemName: item.symbol).font(.caption2.weight(.bold))
                    Text("\(item.count)").font(.subheadline.weight(.bold)).monospacedDigit()
                }
                .foregroundStyle(item.count == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.citiBike))
                .fixedSize()
            }
        }
    }

    /// A way's name, and its next time at the end: "Manhattan … 2 min".
    private func row(_ name: String, next: Arrival?, loaded: Bool, failed: Bool, fitted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Group {
                if fitted { FittedBusName(name: name) } else { Text(name).lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            time(next, loaded: loaded, failed: failed)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func time(_ next: Arrival?, loaded: Bool, failed: Bool) -> some View {
        if failed || !loaded {
            Text("—").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
        } else if let next {
            let minutes = MinutesToGo(until: next.time, from: now)
            HStack(spacing: 2) {
                StatusMark(isLive: next.isLive, marks: marks, size: 9)
                Text(minutes.isNow ? minutes.number : "\(minutes.number) min")
            }
            .font(.subheadline.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(next.statusColor(scheduled: .primary))
            .fixedSize()
        } else {
            Text("None").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A bus stop's lines on its row, small, side by side.
private struct NearbyBusBadges: View {
    let lines: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(lines, id: \.self) { BusBadge(line: $0, size: 20) }
        }
    }

    /// The lines with buses due at `place`, in a steady order, not soonest first, so the row
    /// doesn't shuffle as they come.
    static func lines(of place: NearbyBusPlace) -> [String] {
        sorted(Array(Set(place.lines(at: AppClock.now).map(\.line))))
    }

    /// Lines in a row's order, "B61" before "B67", which the stop's open lines and its map sign
    /// keep too.
    static func sorted(_ lines: [String]) -> [String] {
        lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Views two to a row, a row as tall as its tallest, `spacing` apart, where the two-column `Grid`
/// put them (`PairedRowsLayout`). Not a `Grid`, which measured every tile again for each of its
/// passes, turning the phone most.
struct PairedRows<Item, Cell: View>: View {
    let items: [Item]
    let spacing: CGFloat
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        PairedRowsLayout(spacing: spacing) {
            ForEach(items.indices, id: \.self) { cell(items[$0]) }
        }
    }
}

/// `PairedRows`' layout, the columns' widths as the `Grid` had them: each row shares the width
/// offered as an `HStack` would, half each unless one can't be that narrow (a time is never cut),
/// the other then taking what's left; a column is then as wide as its widest that way, the one
/// alone at the end given half. So at the largest text sizes wider than offered, the card with
/// them.
struct PairedRowsLayout: Layout {
    let spacing: CGFloat

    struct Cache {
        /// The narrowest each view can be.
        var least: [CGFloat]
        /// The columns' widths last worked out, and for what width offered, as each pass asks
        /// for the same twice.
        var columns: (width: CGFloat?, widths: (CGFloat, CGFloat))?
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(least: subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width })
    }

    /// The columns' widths for `width` offered (`Cache.columns`). Offered none, as wide as the
    /// widest view would like.
    private func columns(_ width: CGFloat?, _ subviews: Subviews, _ cache: inout Cache) -> (CGFloat, CGFloat) {
        if let kept = cache.columns, kept.width == width { return kept.widths }
        let widths = Self.columns(width, spacing: spacing, least: cache.least) { index, proposed in
            subviews[index].sizeThatFits(ProposedViewSize(width: proposed, height: nil)).width
        }
        cache.columns = (width, widths)
        return widths
    }

    /// The columns' widths for `width` offered, each view `least` wide at the narrowest and
    /// `measure`d at the width it's offered in its row.
    static func columns(_ width: CGFloat?, spacing: CGFloat, least: [CGFloat],
                        measure: (Int, CGFloat?) -> CGFloat) -> (CGFloat, CGFloat) {
        guard let width, width.isFinite else {
            let widest = least.indices.map { measure($0, nil) }.max() ?? 0
            return (widest, least.count > 1 ? widest : 0)
        }
        let room = max(0, width - spacing)
        var columns: (CGFloat, CGFloat) = (0, 0)
        for index in stride(from: 0, to: least.count, by: 2) {
            guard index + 1 < least.count else {
                // Alone, half, the other half sizing nothing
                columns.0 = max(columns.0, measure(index, room / 2))
                break
            }
            let shares = shares(room, least[index], least[index + 1])
            columns.0 = max(columns.0, measure(index, shares.0))
            columns.1 = max(columns.1, measure(index + 1, shares.1))
        }
        return columns
    }

    /// Two views' shares of `room`, as an `HStack` gives them: half each, but neither narrower
    /// than it can be.
    static func shares(_ room: CGFloat, _ least0: CGFloat, _ least1: CGFloat) -> (CGFloat, CGFloat) {
        if least0 + least1 >= room { return (least0, least1) }
        if least0 > room / 2 { return (least0, room - least0) }
        if least1 > room / 2 { return (room - least1, least1) }
        return (room / 2, room / 2)
    }

    /// Each row's height: its tallest view's, at its column's width.
    private func rows(_ subviews: Subviews, _ columns: (CGFloat, CGFloat)) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: 2).map { index in
            (index..<min(index + 2, subviews.count))
                .map { subviews[$0].sizeThatFits(ProposedViewSize(width: $0 % 2 == 0 ? columns.0 : columns.1,
                                                                   height: nil)).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let columns = columns(proposal.width, subviews, &cache)
        let rows = rows(subviews, columns)
        // One alone: its column and the space after it, as the Grid's empty second column had
        return CGSize(width: columns.0 + spacing + columns.1,
                      height: rows.reduce(0, +) + spacing * CGFloat(rows.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let columns = columns(proposal.width, subviews, &cache)
        var y = bounds.minY
        for (row, height) in rows(subviews, columns).enumerated() {
            for side in 0..<2 where row * 2 + side < subviews.count {
                subviews[row * 2 + side].place(at: CGPoint(x: bounds.minX + (side == 0 ? 0 : columns.0 + spacing), y: y),
                                               anchor: .topLeading,
                                               proposal: ProposedViewSize(width: side == 0 ? columns.0 : columns.1,
                                                                          height: height))
            }
            y += height + spacing
        }
    }
}

/// A bus's destination, shortened, not cut off, to fit: "Wlmsbrg Wythe Av via Flushing Av",
/// then without its "via", then without the street it ends on ("Wlmsbrg"). The place itself is
/// kept whole ("Red Hook", not "Red"), cut off only if even it can't fit.
struct FittedBusName: View {
    let name: String

    var body: some View {
        FirstThatFits {
            ForEach(Self.shortenings(of: name), id: \.self) { Text($0).lineLimit(1) }
        }
    }

    /// Street endings Bus Time's destinations end on, after `BusStopTimes.readable`.
    private static let streets: Set<String> = ["St", "Av", "Ave", "Rd", "Blvd", "Pl", "Pkwy", "Sq", "Dr", "Ln", "Tpke", "Hwy", "Expy"]

    /// `name`, then shorter and shorter, none twice.
    static func shortenings(of name: String) -> [String] {
        var names = [name]
        var shown = name
        if let via = shown.range(of: " via ", options: .caseInsensitive) {
            shown = String(shown[..<via.lowerBound])
            names.append(shown)
        }
        var words = shown.split(separator: " ").map(String.init)
        // The street it ends on, its name and kind ("Cortelyou Rd"), while a place stays
        if words.count > 2, let last = words.last, streets.contains(last) {
            words.removeLast(2)
            names.append(words.joined(separator: " "))
        }
        var seen: Set<String> = []
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// The first of its views as wide as it'd like within the width offered, or else its last, cut
/// to fit: as `ViewThatFits(in: .horizontal)`, but each view's width measured once, not again
/// for every view at each of the layout's passes. The others are given no room, at its start.
struct FirstThatFits: Layout {
    struct Cache {
        /// Each view's width as it'd like.
        var widths: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(widths: subviews.map { $0.sizeThatFits(.unspecified).width })
    }

    /// Which is shown for `width` offered: the first that fits, else the last.
    static func chosen(for width: CGFloat?, widths: [CGFloat]) -> Int {
        guard let width else { return 0 }
        return widths.firstIndex { $0 <= width } ?? max(0, widths.count - 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        return subviews[Self.chosen(for: proposal.width, widths: cache.widths)].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let shown = Self.chosen(for: proposal.width, widths: cache.widths)
        for index in subviews.indices {
            subviews[index].place(at: bounds.origin, anchor: .topLeading,
                                  proposal: index == shown ? ProposedViewSize(bounds.size) : .zero)
        }
    }
}

/// A row saying why there's no bus stop or dock to list, or that they're being found.
private struct NearbyNoteRow: View {
    let text: String
    var finding = false

    var body: some View {
        HStack(spacing: 8) {
            if finding { ProgressView().controlSize(.small) }
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 44)
        .padding(.horizontal, 6)
    }
}

/// Which Citi Bikes you'll ride, as Settings picks: Nearby counts them at a dock, and New Trip
/// plans trips on them. Free docks aren't shown on Nearby: they matter once you're riding,
/// which New Trip's bike trips show.
enum BikeKinds: String, CaseIterable {
    case bike
    case eBike
    case both

    /// As the widgets read it, from `AppSettings.bikeKinds`.
    var shared: SharedBikeKinds {
        switch self {
        case .bike: .bikes
        case .eBike: .eBikes
        case .both: .both
        }
    }

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

/// How near Nearby's map is for its bus stops: zoomed out, each stop's place, one each side of
/// its street; closer in, each way's on its own way's line with an arrow, each way's nearest
/// named, close in too. By meters a point is, a little either way of each cut-off as the map
/// comes back, so it doesn't flicker between them.
enum BusZoom {
    case far
    case between
    case close

    /// Meters a point is, past which it's zoomed out, and within which close in.
    private static let farFrom: Double = 4
    private static let closeWithin: Double = 1.5
    private static let margin = 1.1

    init(metersPerPoint: Double, from shown: BusZoom) {
        guard metersPerPoint > 0 else {
            self = shown
            return
        }
        let far = shown == .far ? Self.farFrom / Self.margin : Self.farFrom
        let close = shown == .close ? Self.closeWithin * Self.margin : Self.closeWithin
        self = metersPerPoint > far ? .far : metersPerPoint < close ? .close : .between
    }
}

/// A station not listed on Nearby's map zoomed out wide: a small black icon; tapped, zoomed in on.
private struct OtherStationIcon: View {
    let name: String
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Image(systemName: "tram.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(.black))
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                // Room round it to tap
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityHint("Shows what's near it")
    }
}

/// How much Nearby's map shows for how far out it is: farthest out, only the stations' icons;
/// then the lines, the bus stops' lines but not their dots, and other stations' icons; then
/// everything. By meters a point is, a little either way of each as the map comes back.
enum MapDetail {
    case overview
    case wide
    case full

    /// Meters a point is past which it's the overview (as far as the lines show,
    /// `NearbyLinesLayer`), and past which wide.
    private static let overviewFrom: Double = 8
    private static let wideFrom: Double = 5.5
    private static let margin = 1.1

    init(metersPerPoint: Double, from shown: MapDetail) {
        guard metersPerPoint > 0 else {
            self = shown
            return
        }
        let overview = shown == .overview ? Self.overviewFrom / Self.margin : Self.overviewFrom
        let wide = shown == .overview || shown == .wide ? Self.wideFrom / Self.margin : Self.wideFrom
        self = metersPerPoint > overview ? .overview : metersPerPoint > wide ? .wide : .full
    }
}

/// Nearby's map's bookkeeping as it moves (`LiveView.motion`): a plain object, not observed,
/// so changing it draws nothing again.
private final class MapMotion {
    /// When the marks were last laid out as the map moved (`layoutEvery`).
    var laidOut = Date.distantPast
    /// Whether you've moved the map since it was framed on you, for the grey dot.
    var userMovedMap = false
    /// Whether you've moved, zoomed or turned it yourself, for it not to be framed again.
    var cameraMovedByHand = false
    /// The `drawnLinesKey` the lines drawn were laid out for: while it's not the one now, they're
    /// being laid out again, and the stops along them are found once they are.
    var linesFoundFor: [String]?
    /// Whether the map's moving: what loads waits till it's still to be shown.
    var moving = false
    /// Where the map last came to rest, to tell a move of more than `followMeters` from it.
    var restCenter: CLLocation?
    /// Waiting for the map to stay still `restDelay` before listing what's near where it rested.
    var restWait: Task<Void, Never>?
    /// How far off and how much of the map shows, as it last came to rest, for centring on a
    /// stop opened.
    var mapDistance: Double?
    var mapSpan: MKCoordinateSpan?
    /// Which way it was turned as it last came to rest, to see you turn it; and where it was, for
    /// the compass to turn it there.
    var restHeading: Double?
    var shownCamera: MapCamera?
}

/// Where a bus stop's mark sits off its place on its way's line on Nearby's map (`busZoom`):
/// `out` points to its kerb side, an arrow on it the way its buses go, `angle` on the screen
/// (radians from east, y down).
struct BusMarkPlacement: Equatable {
    let angle: Double
    let out: CGFloat
    let arrow: Bool
    /// The way its buses go, said: "east".
    let compass: String

    init(angle: Double, out: CGFloat, arrow: Bool, mapAngle: Double) {
        self.angle = angle
        self.out = out
        self.arrow = arrow
        // Clockwise from north, from radians from east with y south
        let degrees = (mapAngle * 180 / .pi + 90 + 720).truncatingRemainder(dividingBy: 360)
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        compass = names[Int((degrees / 45).rounded()) % 8]
    }

    /// Out to the right of the way its buses go: its kerb side.
    var offset: CGSize { CGSize(width: -sin(angle) * out, height: cos(angle) * out) }
}

/// A bus stop on Nearby's map: the lines it's named with (`busNames`) in a bus blue pill, small
/// enough that stops a block apart don't crowd each other off, or, naming none, a small bus blue
/// dot. Opened, it's bigger, its edge thicker. Its name is on its tile. Placed (past zoomed out),
/// it's out to its kerb with an arrow the way its buses go, the dot a little bigger to hold it.
private struct BusStopMark: View {
    let name: String
    /// Nil, a dot.
    let lines: [String]?
    var opened = false
    var placement: BusMarkPlacement?
    /// Moved along its street, clear of another stop's lines (`BusTagLayout`).
    var nudge: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Its dot and its lines' tag, one shrinking into its stop and the other springing out of
        // it (`MarkBubble`), each moved from the stop as it's drawn so it scales to and from there
        ZStack {
            if lines != nil {
                look.offset(offset).transition(MarkBubble.transition(reduceMotion: reduceMotion))
            } else {
                look.offset(offset).transition(MarkBubble.transition(reduceMotion: reduceMotion))
            }
        }
        .animation(reduceMotion ? nil : .default, value: lines != nil)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: nudge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(spoken)
    }

    /// Where it's drawn from its stop: out to its kerb, and along its street.
    private var offset: CGSize {
        let out = placement?.offset ?? .zero
        return CGSize(width: out.width + nudge.width, height: out.height + nudge.height)
    }

    /// Its lines' tag, or its dot.
    private var look: some View {
        let arrow = placement.flatMap { $0.arrow ? Angle.radians($0.angle) : nil }
        return Group {
            if let lines {
                HStack(spacing: 2) {
                    ForEach(lines, id: \.self) { MapSignBusBadge(line: $0) }
                    if let arrow {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.white)
                            .rotationEffect(arrow)
                            .frame(width: 11)
                    }
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
                    .frame(width: arrow == nil ? 8 : 12, height: arrow == nil ? 8 : 12)
                    .overlay {
                        if let arrow {
                            // Drawn, not the chevron glyph, whose side bearings sat it off the
                            // dot's centre
                            DotChevron()
                                .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                .frame(width: 3, height: 5.5)
                                .rotationEffect(arrow)
                        }
                    }
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    // Room round it to tap
                    .padding(6)
                    .contentShape(Rectangle())
            }
        }
        .fixedSize()
    }

    /// Its lines, and the way its buses go: "B67 bus, heading east".
    private var spoken: String { Self.spoken(lines: lines, placement: placement) }

    /// As `spoken`, for its map mark's own (`MapMark`).
    static func spoken(lines: [String]?, placement: BusMarkPlacement?) -> String {
        let lines = (lines ?? []).map(BusBadge.spokenName).joined(separator: ", ")
        guard let placement, placement.arrow else { return lines }
        return [lines, "heading " + placement.compass].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A ">" filling its frame, so it sits on the centre of whatever it's framed in.
private struct DotChevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

/// A stop along the lines opened from its dot on Nearby's map, and its buses once found.
private struct OpenedStop: Equatable {
    /// Its map mark's id.
    let id: String
    let coordinate: CLLocationCoordinate2D
    /// The lines stopping there, as `TrackShapes.busStops` has them.
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
    let tap: () -> Void

    var body: some View {
        let angle = tracker.you.map { you in
            Angle(radians: atan2(tracker.middle.y - you.y, tracker.middle.x - you.x))
        } ?? .zero
        MapYouDot(progress: tracker.progress, angle: angle)
            // Room round the small dot to tap
            .padding(8)
            .contentShape(Circle())
            .onTapGesture(perform: tap)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Goes back to you")
    }
}

/// Room to tap the grey dot, at the map's middle, once it's split off; nothing elsewhere, for
/// the map to pan and pinch under it.
private struct MapMiddleTap: View {
    let tracker: MapMiddleTracker
    let tap: () -> Void

    var body: some View {
        if tracker.shows {
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .onTapGesture(perform: tap)
                .accessibilityElement()
                .accessibilityLabel("Map's middle")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Zooms in here")
                .position(tracker.middle)
        }
    }
}

/// Your dot, Nearby's and New Trip's before it's planned.
struct MapYouDot: View, Animatable {
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

/// A bus line on a bus stop's mark: white, with the line in bus blue; Select Bus's on its lighter
/// blue, "SBS" after it, to tell it from the local of the same number.
private struct MapSignBusBadge: View {
    let line: String

    var body: some View {
        let sbs = BusBadge.isSBS(line)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        HStack(spacing: 2) {
            Text(BusBadge.label(line))
                .font(.system(size: 9, weight: .heavy))
            if sbs {
                Text("SBS")
                    .font(.system(size: 7, weight: .heavy))
            }
        }
        .foregroundStyle(sbs ? .white : BusBadge.blue)
        .padding(.horizontal, 4)
        .frame(height: 15)
        .background(sbs ? BusBadge.sbsBlue : .white, in: shape)
        .overlay {
            if sbs { shape.stroke(.white, lineWidth: 1) }
        }
        .accessibilityElement(children: .ignore)
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
    /// Bus stops' tags: those moved along their streets, clear of others (`BusTagLayout`); the
    /// lines put in each from stops just by it; and those stops, dots now.
    var nudges: [String: CGSize] = [:]
    var extraLines: [String: [String]] = [:]
    var joined: Set<String> = []
}

/// A place on Nearby's map as `layout` has it: its sign, or its bubble, each measured for
/// laying them out. `tap` gets the ids a merged bubble stands for, or nil for one place.
private struct MapMark<Sign: View, Bubble: View>: View, Equatable {
    let id: String
    let look: MarkLayout.Look
    /// What its sign and bubble show, for it to be drawn again only when that or its look
    /// changes (`==`), not with every change to Nearby: each of its forty or so marks was drawn
    /// again a dozen times each time Nearby re-listed.
    let key: String
    @Binding var signSizes: [String: CGSize]
    @Binding var bubbleSizes: [String: CGSize]
    /// For VoiceOver, as a bubble shows only its kind's symbol: the place's name, what a merged
    /// one stands for ("3 docks"), and what's there: a station's lines, a stop's buses and the
    /// way they go, a dock's bikes.
    let spoken: String
    let kinds: String
    let detail: String
    let hint: String
    /// Springing out of its place once it's on the map (`MarkBubble`), as a stop along the
    /// lines does as the map's zoomed past where they're marked.
    var popsIn = false
    let sign: Sign
    let bubble: (Int?) -> Bubble
    let tap: ([String]?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// The same mark, showing the same: its sign, bubble and tap, which can't be compared,
    /// worked out from what `key` says.
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.look == b.look && a.key == b.key && a.spoken == b.spoken && a.kinds == b.kinds
            && a.detail == b.detail && a.hint == b.hint
    }

    var body: some View {
        let showsBubble = look == .bubble || look.merged != nil
        Button {
            tap(look.merged)
        } label: {
            // Each look shrinking into its place, the mark's middle, as it goes, and springing out
            // of it as it comes (`MarkBubble`): by its own animation, as the map's marks may not
            // be given one from outside it
            ZStack {
                sign
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        if signSizes[id] != size { signSizes[id] = size }
                    }
                    .scaleEffect(look == .sign ? 1 : MarkBubble.gone)
                    .animation(MarkBubble.animation(showing: look == .sign, reduceMotion: reduceMotion), value: look)
                    .modifier(MarkBubble.Gone(gone: look != .sign, look: look))
                    .allowsHitTesting(look == .sign)
                bubble(look.merged?.count)
                    // Measured on its own, as a count would widen it
                    .background {
                        bubble(nil).hidden()
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                if bubbleSizes[id] != size { bubbleSizes[id] = size }
                            }
                    }
                    .scaleEffect(showsBubble ? 1 : MarkBubble.gone)
                    .animation(MarkBubble.animation(showing: showsBubble, reduceMotion: reduceMotion), value: look)
                    .modifier(MarkBubble.Gone(gone: !showsBubble, look: look))
                    .allowsHitTesting(showsBubble)
            }
            .scaleEffect(popsIn && !appeared ? MarkBubble.gone : 1)
        }
        .buttonStyle(.plain)
        // One element, sign or bubble, standing in for the button: not the sign's name and lines
        // and the bubble's name again, each its own ("9 St & 4 Av, 9 St & 4 Av"), nor a dozen for
        // VoiceOver to step through and the accessibility tree to hold for each mark
        .accessibilityRepresentation {
            Button(look.merged.map { "\($0.count) \(kinds)" } ?? spoken) { tap(look.merged) }
                .accessibilityValue(look.merged == nil ? detail : "")
                .accessibilityHint(hint)
        }
        .allowsHitTesting(look != .hidden)
        .accessibilityHidden(look == .hidden)
        .onAppear {
            guard popsIn, !appeared else { return }
            withAnimation(MarkBubble.animation(showing: true, reduceMotion: reduceMotion)) { appeared = true }
        }
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
    var now = AppClock.now {
        didSet {
            if now.timeIntervalSince(mapNow) >= Self.mapTick || now < mapNow { mapNow = now }
        }
    }
    /// `now` a minute at a time, for the map: its bus stops' lines and the lines drawn, by the
    /// buses still due. Not the whole map redrawn every tick for a bus gone a few seconds sooner.
    private(set) var mapNow = AppClock.now
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
        // Those the MTA couldn't give, from the timetable if there is one. Off the main actor:
        // the first read decompresses and parses the whole timetable, which would freeze Nearby
        let timedOut = selections.filter { missing.contains($0.trainID) }
        var timed: [String: [Arrival]] = [:]
        if !timedOut.isEmpty {
            timed = await Task.detached(priority: .userInitiated) {
                TimetableStore.load().map { TrainService.trains(for: timedOut, from: $0) } ?? [:]
            }.value
        }
        // Cancelled while reading the timetable; a newer list's load has these rows
        guard !Task.isCancelled else { return }
        trains.merge(fetched) { $1 }
        for trainID in missing { trains[trainID] = timed[trainID] }
        failed.subtract(asked)
        failed.formUnion(missing)
        fromTimetable.subtract(asked)
        fromTimetable.formUnion(timed.keys)
        now = AppClock.now
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
    /// `refreshing` on pull-to-refresh (`load`'s true) or app foregrounding. Ticks `live.now` in
    /// between.
    fileprivate func updatingTrains<ID: Equatable>(_ live: LiveTrains, id: ID, refreshing: @escaping () -> Void = {},
                                                   load: @escaping (_ pulled: Bool) async -> Void) -> some View {
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
            now.wrappedValue = AppClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                now.wrappedValue = AppClock.now
            }
        }
    }
}

private struct UpdatingTrains<ID: Equatable>: ViewModifier {
    let live: LiveTrains
    let id: ID
    let refreshing: () -> Void
    let load: (_ pulled: Bool) async -> Void
    @Environment(\.scenePhase) private var scenePhase
    /// When it last loaded, and for which `id`: restarted for the same within `soonAgain` (the
    /// page back from a train's or another tab, or the app back), it waits out the minute first.
    @State private var loaded: (at: Date, id: ID)?
    private static var soonAgain: TimeInterval { 30 }

    func body(content: Content) -> some View {
        content
            .refreshable {
                refreshing()
                await load(true)
                loaded = (.now, id)
            }
            // Restarted as the app comes back, loading then, unless it just has
            .task(id: Polling(id: id, inForeground: scenePhase != .background)) {
                guard scenePhase != .background else { return }
                if let loaded, loaded.id == id, live.failed.isEmpty {
                    let since = Date.now.timeIntervalSince(loaded.at)
                    if since < Self.soonAgain { await Connectivity.shared.pause(for: .seconds(60 - since)) }
                }
                while !Task.isCancelled {
                    await load(false)
                    if !Task.isCancelled { loaded = (.now, id) }
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
    /// How many after the next to show small beneath it.
    var laterCount = 2

    var body: some View {
        if failed {
            Text("Couldn't load").font(.subheadline).foregroundStyle(.secondary)
        } else if let trains {
            if trains.isEmpty {
                Text(none).font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    next(trains[0])
                    if trains.count > 1, laterCount > 0 {
                        later(trains.dropFirst().prefix(laterCount))
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(trains, now: now, count: laterCount + 1))
                .accessibilityAddTraits(.updatesFrequently)
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// VoiceOver text, e.g. "Now, 1 minute, 7 minutes by the timetable". Scheduled
    /// times say so, as their colour does on screen.
    static func spoken(_ trains: [Arrival]?, failed: Bool = false, now: Date, count: Int = 3) -> String {
        guard !failed else { return "Couldn't load" }
        guard let trains else { return "Loading" }
        guard !trains.isEmpty else { return "No trains" }
        return trains.prefix(count).map { train in
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
    LiveView(allowingLocation: .constant(false), keptHeading: .constant(nil), recenterRequests: 0)
        .environment(WidgetStore())
        .environment(SettingsStore())
}

/// Nearby's card and its modes row: across the map's foot, or on its side down the left,
/// clear of the screen's rounded top corner.
private struct CardPlace: ViewModifier {
    let sideways: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: sideways ? Sideways.width : nil)
            .padding(.horizontal, sideways ? 0 : 16)
            .padding(.leading, sideways ? Sideways.inset : 0)
            .padding(.top, sideways ? Sideways.top : 0)
            .padding(.bottom, 8)
    }
}
