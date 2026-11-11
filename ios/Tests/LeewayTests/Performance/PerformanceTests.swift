import CoreLocation
import Foundation
import Testing
import XCTest
@testable import Leeway

/// What the performance tests run on: no network, fixed dates, the saved feeds, and timetables
/// made from them. The phone's real timetables are downloaded, not bundled, so the subway's here
/// is the saved feeds' trains at about 10:30 (every trip's stops and times, as they ran), each
/// run again every hour of the day for nine days from Monday 2035-06-04 (`RouteKit.base`): about
/// the real one's size and spread. The buses' is every line's stops and minutes (bus_routes.json)
/// every 10 minutes on the Tuesday, 05:00 to 23:00. In 2035, so `TimetableStore` has none for
/// then and `WayFinder` times from the timetable's start.
enum PerfKit {
    /// Tuesday 2035-06-05 08:15, in the morning rush.
    static let departure = RouteKit.base.addingTimeInterval(86400 + 8 * 3600 + 15 * 60)

    /// Every platform's stops, both ways.
    static let allStops = Set(StationDirectory.platforms.flatMap { [$0.id + "N", $0.id + "S"] })

    static let subway: Timetable = {
        let newest = SubwayFeed.newest(Array(FeedFixtures.data.values))
        let midnight = Fixtures.date("2026-11-10 00:00")
        var trips: [String: [Arrival]] = [:]
        for (name, data) in FeedFixtures.data {
            let arrivals = (try? SubwayFeed.arrivals(at: allStops, in: data, newest: newest,
                                                     now: FeedFixtures.capturedAt)) ?? []
            for arrival in arrivals where !arrival.trip.isEmpty {
                trips[name + " " + arrival.trip, default: []].append(arrival)
            }
        }
        var stops: [String] = [], stopIndex: [String: UInt16] = [:]
        var routes: [String] = [], routeIndex: [String: UInt16] = [:]
        var patterns: [Timetable.Pattern] = [], patternIndex: [Timetable.Pattern: Int] = [:]
        var starts: [[UInt32]] = []
        func stop(_ id: String) -> UInt16 {
            if let known = stopIndex[id] { return known }
            stops.append(id)
            stopIndex[id] = UInt16(stops.count - 1)
            return UInt16(stops.count - 1)
        }
        func route(_ id: String) -> UInt16 {
            if let known = routeIndex[id] { return known }
            routes.append(id)
            routeIndex[id] = UInt16(routes.count - 1)
            return UInt16(routes.count - 1)
        }
        for key in trips.keys.sorted() {
            var seen = Set<String>()
            let calls = (trips[key] ?? []).sorted { $0.time < $1.time }.filter { seen.insert($0.stop).inserted }
            guard let first = calls.first, calls.count > 1,
                  let last = calls.last, last.time.timeIntervalSince(first.time) < 65_000 else { continue }
            var tripCalls: [Timetable.Call] = []
            for arrival in calls {
                let waits = min(max((arrival.departure ?? arrival.time).timeIntervalSince(arrival.time), 0), 255)
                tripCalls.append(Timetable.Call(stop: stop(arrival.stop), arrives: UInt16(arrival.time.timeIntervalSince(first.time)),
                                                waits: UInt8(waits)))
            }
            let pattern = Timetable.Pattern(route: route(first.route), calls: tripCalls)
            let index: Int
            if let known = patternIndex[pattern] {
                index = known
            } else {
                patterns.append(pattern)
                starts.append([])
                index = patterns.count - 1
                patternIndex[pattern] = index
            }
            // Its minute past the hour, every hour of nine days
            let past = UInt32(max(0, Int(first.time.timeIntervalSince(midnight))) % 3600)
            for day in 0..<9 {
                for hour in 0..<24 {
                    starts[index].append(UInt32(day * 86400 + hour * 3600) + past)
                }
            }
        }
        return Timetable(made: RouteKit.base, base: RouteKit.base, stops: stops, routes: routes,
                         patterns: patterns, starts: starts)
    }()

    static let buses: Timetable = {
        let ways = BusRoutes.everyWay
            .filter { $0.way.stops.count > 1 && $0.way.minutes.count == $0.way.stops.count }
            .sorted { ($0.line, $0.way.to, $0.way.stops[0].code) < ($1.line, $1.way.to, $1.way.stops[0].code) }
        var stops: [String] = [], places: [Timetable.Place] = [], stopIndex: [String: UInt16] = [:]
        var routes: [String] = [], patterns: [Timetable.Pattern] = []
        for (line, way) in ways {
            routes.append(line + "\t" + way.to)
            var calls: [Timetable.Call] = []
            for (stop, minutes) in zip(way.stops, way.minutes) {
                let index: UInt16
                if let known = stopIndex[stop.code] {
                    index = known
                } else {
                    stops.append(stop.code)
                    places.append(Timetable.Place(latitude: stop.latitude, longitude: stop.longitude, name: stop.name))
                    index = UInt16(stops.count - 1)
                    stopIndex[stop.code] = index
                }
                calls.append(Timetable.Call(stop: index, arrives: UInt16(min(max(minutes * 60, 0), 65_000)), waits: 0))
            }
            patterns.append(Timetable.Pattern(route: UInt16(routes.count - 1), calls: calls))
        }
        let day = RouteKit.every(600, from: 86400 + 5 * 3600, through: 86400 + 23 * 3600)
        return Timetable(made: RouteKit.base, base: RouteKit.base, stops: stops, routes: routes, patterns: patterns,
                         starts: Array(repeating: day, count: patterns.count), places: places)
    }()

    static let subwayNetwork = TransitNetwork(subway: subway, buses: nil)
    static let network = TransitNetwork(subway: subway, buses: buses)
    static let wayFinder = WayFinder(timetable: subway)

    /// A trip across the city: its name and ends.
    struct Trip {
        let name: String
        let from: CLLocation
        let to: CLLocation

        init(_ name: String, _ from: (Double, Double), _ to: (Double, Double)) {
            self.name = name
            self.from = CLLocation(latitude: from.0, longitude: from.1)
            self.to = CLLocation(latitude: to.0, longitude: to.1)
        }

        var start: (Double, Double) { (from.coordinate.latitude, from.coordinate.longitude) }
        var end: (Double, Double) { (to.coordinate.latitude, to.coordinate.longitude) }
    }

    /// Twenty everyday trips in every borough with the subway: straight there, with changes,
    /// across town where a bus does it, and out to the ends of lines.
    static let trips = [
        Trip("Park Slope to Times Sq", (40.6710, -73.9814), (40.7580, -73.9855)),
        Trip("Astoria to Wall St", (40.7644, -73.9235), (40.7069, -74.0113)),
        Trip("Williamsburg to Union Sq", (40.7172, -73.9566), (40.7359, -73.9906)),
        Trip("Harlem to Downtown Brooklyn", (40.8075, -73.9454), (40.6928, -73.9903)),
        Trip("Jackson Heights to Grand Central", (40.7466, -73.8914), (40.7527, -73.9772)),
        Trip("Flushing to Herald Sq", (40.7596, -73.8300), (40.7496, -73.9880)),
        Trip("Fordham to Columbia", (40.8615, -73.8905), (40.8075, -73.9626)),
        Trip("Bay Ridge to Chelsea", (40.6346, -74.0236), (40.7465, -74.0014)),
        Trip("Coney Island to Prospect Heights", (40.5772, -73.9811), (40.6775, -73.9690)),
        Trip("Jamaica to Long Island City", (40.7020, -73.8010), (40.7447, -73.9485)),
        Trip("Crown Heights to Red Hook", (40.6694, -73.9422), (40.6750, -74.0120)),
        Trip("Upper East Side to Upper West Side", (40.7736, -73.9566), (40.7870, -73.9754)),
        Trip("Bushwick to Greenpoint", (40.6944, -73.9213), (40.7300, -73.9540)),
        Trip("Riverdale to Yankee Stadium", (40.8890, -73.9070), (40.8296, -73.9262)),
        Trip("Sunset Park to Borough Park", (40.6455, -74.0124), (40.6340, -73.9950)),
        Trip("Washington Heights to FiDi", (40.8491, -73.9380), (40.7075, -74.0110)),
        Trip("Forest Hills to Williamsburg", (40.7216, -73.8446), (40.7140, -73.9610)),
        Trip("Canarsie to East Village", (40.6464, -73.9020), (40.7280, -73.9840)),
        Trip("Pelham Bay to Hunts Point", (40.8526, -73.8282), (40.8207, -73.8907)),
        Trip("Greenpoint to Long Island City", (40.7300, -73.9540), (40.7470, -73.9450)),
    ]

    /// The complex of the station nearest `place`, as `WayFinder` takes them.
    static func complex(near place: CLLocation) -> String? {
        StationDirectory.all.min { $0.location.distance(from: place) < $1.location.distance(from: place) }?.complex
    }

    /// Eight of the trips' station to station, for `WayFinder`.
    static let wayPairs: [(String, String)] = trips.prefix(8).compactMap { trip in
        guard let from = complex(near: trip.from), let to = complex(near: trip.to), from != to else { return nil }
        return (from, to)
    }

    /// The busiest stations' stops: Times Sq, Grand Central, Union Sq, Atlantic Av, Jay St,
    /// Herald Sq, W 4 St, Jackson Hts and Fulton St, each whole complex.
    static let busyStops: Set<String> = Set(["R16", "631", "R20", "D24", "A41", "D17", "A32", "G14", "A38"]
        .compactMap(StationDirectory.station(id:)).flatMap { StationDirectory.stops(inComplexOf: $0) })

    /// Boards as the widgets show them: Union Sq uptown and down (`Selection.fallback`), Times Sq
    /// downtown on the 1 2 3, Atlantic Av on the Q, Jackson Hts on the E F M R.
    static let selections: [Selection] = [
        .fallback, Selection.fallback.otherWay,
        Selection(stationID: "127", routes: ["1", "2", "3"], direction: .south),
        Selection(stationID: "D24", routes: ["Q"], direction: .north),
        Selection(stationID: "G14", routes: ["E", "F", "M", "R"], direction: .south),
    ]

    /// The walking router's benchmark (tools/walkbench/walks.json), all but the walk to Midtown,
    /// 9 km: start and end.
    static let walks: [(name: String, from: Walk.Point, to: Walk.Point)] = ([
        ("19st-smith-9sts", 40.6628, -73.9933, 40.6740, -73.9960),
        ("19st-carroll-gardens", 40.6628, -73.9933, 40.6790, -73.9990),
        ("parkslope-4av", 40.67385, -73.98640, 40.67080, -73.98880),
        ("midtown", 40.75800, -73.98550, 40.75270, -73.97720),
        ("westvillage", 40.73220, -74.00050, 40.73590, -74.00500),
        ("fidi", 40.70460, -74.01410, 40.71010, -74.00760),
        ("jacksonheights", 40.74660, -73.89140, 40.75010, -73.88350),
        ("harlem", 40.80790, -73.94540, 40.81000, -73.95000),
        ("centralpark", 40.76810, -73.98190, 40.77400, -73.97120),
        ("uws", 40.78390, -73.97960, 40.78930, -73.97050),
        ("williamsburg", 40.71420, -73.96160, 40.71900, -73.95610),
        ("astoria", 40.76200, -73.92530, 40.75680, -73.91700),
        ("parkslope-turns", 40.67650, -73.98010, 40.67080, -73.98880),
        ("chelsea", 40.74250, -74.00050, 40.74710, -73.99350),
        ("jjbyrne", 40.67500, -73.98380, 40.67230, -73.98860),
        ("jjbyrne2", 40.67380, -73.98330, 40.67330, -73.98880),
        ("washsq", 40.72980, -73.99950, 40.73200, -73.99600),
        ("queens-blvd", 40.72980, -73.86390, 40.73360, -73.85880),
        ("ocean-pkwy", 40.62420, -73.97080, 40.62620, -73.96390),
        ("grand-army-plaza", 40.67500, -73.97250, 40.67150, -73.96750),
        ("atlantic-flatbush", 40.68200, -73.97850, 40.68560, -73.97330),
        ("brooklyn-bridge", 40.69950, -73.99000, 40.71280, -74.00600),
        ("times-sq", 40.75500, -73.98800, 40.76050, -73.98450),
        ("prospect-park", 40.67250, -73.97030, 40.65950, -73.96180),
    ] as [(String, Double, Double, Double, Double)]).map { walk in
        (name: walk.0, from: Walk.Point(lat: walk.1, lon: walk.2), to: Walk.Point(lat: walk.3, lon: walk.4))
    }

    /// The bench's long one: 19 St in Brooklyn to Midtown, over the Manhattan Bridge.
    static let longWalk = (from: Walk.Point(lat: 40.6628, lon: -73.9933), to: Walk.Point(lat: 40.7486, lon: -73.9840))

    /// Places Nearby's map is moved to, in every borough with the subway.
    static let places: [CLLocationCoordinate2D] = ([
        (40.6710, -73.9814), (40.7549, -73.9840), (40.7466, -73.8914), (40.8075, -73.9454),
        (40.7172, -73.9566), (40.7075, -74.0110), (40.8615, -73.8905), (40.7596, -73.8300),
    ] as [(Double, Double)]).map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }

    /// Nearby's lines round each of `places`, as it lays them out once the map's come to rest
    /// somewhere new (`LiveView.findLines`, off the main thread): the whole subway, laid out once
    /// at launch (`NearbyLines.allTracks`, made before this is timed), the bus lines near, and
    /// each bus stop's side of the street.
    static func moveNearby() -> Int {
        var drawn = 0
        for place in places {
            let busLines = NearbyLines.busLines(near: place, within: 800)
            let bright = NearbyLines.nearestStopsLines(near: CLLocation(latitude: place.latitude, longitude: place.longitude))
            let lines = NearbyLines(routes: NearbyLines.allRoutes, busLines: busLines, brightBusLines: bright, around: [place])
            for stop in BusNetwork.stops where abs(stop.coordinate.latitude - place.latitude) < 0.004
                && abs(stop.coordinate.longitude - place.longitude) < 0.005 {
                if lines.sides.way(at: stop.coordinate, lines: stop.lines) != nil { drawn += 1 }
            }
            drawn += lines.tracks.count + lines.buses.count
        }
        return drawn
    }

    /// Every board's trains from the saved feeds and its widget entries' trains, as a Next
    /// train widget's timeline makes them each minute ahead.
    static func widgetTimelines() -> Int {
        let now = FeedFixtures.capturedAt
        let stops = Set(selections.flatMap(\.stopIDs))
        let arrivals = TrainService.arrivals(at: stops, in: WNSupport.fixtureFeeds, now: now)
        let trains = TrainService.trains(for: selections, in: arrivals, now: now)
        var entries = 0
        for selection in selections {
            let toCatch = trains[selection.trainID] ?? []
            for date in TimelinePlan.dates(after: now, toCatch: toCatch, selection: selection, everyMinute: true) {
                entries += TimelinePlan.trains(toCatch, at: date, selection: selection, fetched: now, keepsStops: true).count
            }
        }
        return entries
    }

    /// Every saved feed read for the busiest stations' trains.
    static func feedArrivals() -> Int {
        let newest = SubwayFeed.newest(Array(FeedFixtures.data.values))
        return FeedFixtures.data.values.reduce(0) { count, data in
            count + ((try? SubwayFeed.arrivals(at: busyStops, in: data, newest: newest, now: FeedFixtures.capturedAt))?.count ?? 0)
        }
    }

    /// Every saved feed's stops after the busiest stations, on every line, as a ride's are timed.
    static func timedStops() -> Int {
        let routes = Set(StationDirectory.all.flatMap(\.routes))
        return FeedFixtures.data.values.reduce(0) { count, data in
            count + ((try? SubwayFeed.timedStops(after: busyStops, on: routes, in: data))?.count ?? 0)
        }
    }

    /// The bundled lists read as at first use: stations.json into stations, equipment.json; and
    /// the saved alerts.
    static func decodeBundled() throws -> Int {
        guard let stations = Bundle.main.url(forResource: "stations", withExtension: "json"),
              let equipment = Bundle.main.url(forResource: "equipment", withExtension: "json")
        else { throw CocoaError(.fileNoSuchFile) }
        let platforms = try StationDirectory.load(from: stations)
        let grouped = StationDirectory.stations(from: platforms)
        let machines = try EquipmentDirectory.load(from: equipment)
        let alerts = try AlertsFeed.entries(in: Fixtures.data("weekday1030-alerts.json"), now: FeedFixtures.capturedAt)
        return grouped.count + machines.count + alerts.count
    }

    /// The subway's timetable written and read back, as it's saved and read from the App Group.
    static func timetableRoundTrip() throws -> Int {
        try Timetable(data: subway.encoded()).patterns.count
    }

    /// Runs `body` to its end, waiting here: XCTest's `measure` blocks can't wait.
    static func blocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await body()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    /// `walks` routed on `store`, from its tiles read again (`WalkGraphStore.drop`): as a trip's
    /// walks are first routed. How many found a way.
    static func routeWalks(_ walks: [(name: String, from: Walk.Point, to: Walk.Point)], on store: WalkGraphStore) async -> Int {
        await store.drop()
        var routed = 0
        for walk in walks {
            if case .success = await store.walk(from: walk.from, to: walk.to, options: WalkRouter.Options()) { routed += 1 }
        }
        return routed
    }
}

// MARK: - Measured (XCTest)

/// The app's heavy work measured by XCTest for baselines: time, CPU and memory, a few times each.
/// Debug builds, as the tests run, are many times slower than Release; times are for comparing
/// with earlier runs, not with the phone in the App Store. Best run alone, not beside the rest.
final class PerformanceTests: XCTestCase {
    private var metrics: [XCTMetric] { [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()] }

    private func runs(_ count: Int) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = count
        return options
    }

    override class func setUp() {
        super.setUp()
        // Made once, before anything's measured
        _ = PerfKit.network
        _ = PerfKit.subwayNetwork
        _ = NearbyLines.allTracks
    }

    /// Building the phone's network from both timetables, as `LocalRoutes` does once each is new.
    func testBuildNetwork() {
        measure(metrics: metrics, options: runs(3)) {
            XCTAssertFalse(TransitNetwork(subway: PerfKit.subway, buses: PerfKit.buses).patterns.isEmpty)
        }
    }

    /// The phone's planner (`TransitPlanner`, as `LocalRoutes`) for the twenty trips by subway.
    func testPhoneRoutesBySubway() {
        measure(metrics: metrics, options: runs(3)) {
            for trip in PerfKit.trips {
                _ = TransitPlanner.routes(on: PerfKit.subwayNetwork, from: trip.start, to: trip.end,
                                          departure: PerfKit.departure, modes: [.subway])
            }
        }
    }

    /// As above, by subway and bus.
    func testPhoneRoutesBySubwayAndBus() {
        measure(metrics: metrics, options: runs(2)) {
            for trip in PerfKit.trips {
                _ = TransitPlanner.routes(on: PerfKit.network, from: trip.start, to: trip.end,
                                          departure: PerfKit.departure, modes: [.subway, .bus])
            }
        }
    }

    /// The timed planner (`TripPlanner.plan`) for the twenty trips.
    func testTimedPlanner() {
        measure(metrics: metrics, options: runs(3)) {
            for trip in PerfKit.trips {
                _ = TripPlanner.plan(from: trip.from, to: trip.to, at: PerfKit.departure, timetable: PerfKit.subway)
            }
        }
    }

    /// New Route's ways across the week: the finder made, as New Route does for its timetable.
    func testWayFinderBuild() {
        measure(metrics: metrics, options: runs(2)) {
            XCTAssertFalse(WayFinder(timetable: PerfKit.subway).runs.isEmpty)
        }
    }

    /// New Route's ways for eight of the trips.
    func testWayFinderWays() {
        let finder = PerfKit.wayFinder
        measure(metrics: metrics, options: runs(2)) {
            for (from, to) in PerfKit.wayPairs {
                _ = finder.ways(from: from, to: to)
            }
        }
    }

    /// The walk bench's walks on the bundled walkgraph.sqlite, each run from the tiles read again.
    func testWalkBench() {
        let store = WalkGraphStore()
        measure(metrics: metrics, options: runs(2)) {
            let routed = PerfKit.blocking { await PerfKit.routeWalks(PerfKit.walks, on: store) }
            XCTAssertGreaterThan(routed, 0)
        }
    }

    /// The walk bench's long walk, 9 km to Midtown, as walking all the way's.
    func testLongWalk() {
        let store = WalkGraphStore()
        measure(metrics: metrics, options: runs(2)) {
            let routed = PerfKit.blocking { await PerfKit.routeWalks([("19st-midtown", PerfKit.longWalk.from, PerfKit.longWalk.to)], on: store) }
            XCTAssertEqual(routed, 1)
        }
    }

    /// The eight saved feeds read for the busiest stations' trains.
    func testFeedArrivals() {
        measure(metrics: metrics, options: runs(5)) {
            XCTAssertGreaterThan(PerfKit.feedArrivals(), 0)
        }
    }

    /// The eight saved feeds' stops after the busiest stations.
    func testFeedTimedStops() {
        measure(metrics: metrics, options: runs(5)) {
            XCTAssertGreaterThan(PerfKit.timedStops(), 0)
        }
    }

    /// Five boards' widget timelines from the saved feeds.
    func testWidgetTimelines() {
        measure(metrics: metrics, options: runs(5)) {
            XCTAssertGreaterThan(PerfKit.widgetTimelines(), 0)
        }
    }

    /// The bundled stations and equipment, and the saved alerts, read.
    func testDecodeBundled() throws {
        measure(metrics: metrics, options: runs(5)) {
            XCTAssertGreaterThan((try? PerfKit.decodeBundled()) ?? 0, 0)
        }
    }

    /// The subway's timetable written and read back.
    func testTimetableRoundTrip() {
        measure(metrics: metrics, options: runs(3)) {
            XCTAssertEqual((try? PerfKit.timetableRoundTrip()) ?? 0, PerfKit.subway.patterns.count)
        }
    }

    /// Nearby's lines laid out for eight map moves.
    func testNearbyLines() {
        measure(metrics: metrics, options: runs(3)) {
            XCTAssertGreaterThan(PerfKit.moveNearby(), 0)
        }
    }
}

// MARK: - Ceilings (Swift Testing)

/// Each of `PerformanceTests`' measures once, failing well past what it's taken: so a slowdown
/// fails without Xcode's baselines, which only Xcode can accept. About three times the Debug
/// times measured on the simulator (2026-11-10), and no less than 0.2 s, so noise doesn't fail
/// them. Each prints what it took.
@Suite(.serialized)
struct PerformanceCeilings {
    init() {
        _ = PerfKit.network
        _ = PerfKit.subwayNetwork
        _ = NearbyLines.allTracks
    }

    /// `body`'s time, printed, and whether it's within `ceiling`.
    @discardableResult
    private func within<T>(_ ceiling: Duration, _ name: String, _ body: () throws -> T) rethrows -> T {
        let clock = ContinuousClock()
        var result: T?
        let took = try clock.measure { result = try body() }
        print("Performance: \(name) took \(took) (ceiling \(ceiling))")
        #expect(took < ceiling, "\(name) took \(took), over \(ceiling)")
        return result!
    }

    private func within<T>(_ ceiling: Duration, _ name: String, _ body: () async -> T) async -> T {
        let clock = ContinuousClock()
        let started = clock.now
        let result = await body()
        let took = clock.now - started
        print("Performance: \(name) took \(took) (ceiling \(ceiling))")
        #expect(took < ceiling, "\(name) took \(took), over \(ceiling)")
        return result
    }

    /// The timetables made from the saved feeds are near the real ones' size.
    @Test func timetablesAreRealSized() {
        print("Performance: subway timetable \(PerfKit.subway.patterns.count) patterns, "
              + "\(PerfKit.subway.starts.reduce(0) { $0 + $1.count }) trips, \(PerfKit.subway.stops.count) stops; "
              + "buses \(PerfKit.buses.patterns.count) patterns, \(PerfKit.buses.stops.count) stops")
        #expect(PerfKit.subway.stops.count > 800)
        #expect(Set(PerfKit.subway.routes.map(Lines.normalized)).count > 20)
        #expect(PerfKit.buses.patterns.count > 500)
        #expect(PerfKit.subway.covers(PerfKit.departure) && PerfKit.buses.covers(PerfKit.departure))
    }

    @Test func buildNetwork() {
        let network = within(.milliseconds(600), "network built") { TransitNetwork(subway: PerfKit.subway, buses: PerfKit.buses) }
        #expect(!network.patterns.isEmpty)
    }

    /// Each trip by subway planned, none over 0.2 s, all within 0.8 s; most find a way.
    @Test func phoneRoutesBySubway() {
        var found = 0
        within(.milliseconds(800), "20 trips by subway") {
            for trip in PerfKit.trips {
                let clock = ContinuousClock()
                var routes: [TransitRoute] = []
                let took = clock.measure {
                    routes = TransitPlanner.routes(on: PerfKit.subwayNetwork, from: trip.start, to: trip.end,
                                                   departure: PerfKit.departure, modes: [.subway])
                }
                if !routes.isEmpty { found += 1 }
                #expect(took < .milliseconds(200), "\(trip.name) took \(took)")
            }
        }
        print("Performance: 20 trips by subway, \(found) found")
        #expect(found >= 18)
    }

    @Test func phoneRoutesBySubwayAndBus() {
        var found = 0
        within(.milliseconds(3200), "20 trips by subway and bus") {
            for trip in PerfKit.trips {
                let clock = ContinuousClock()
                var routes: [TransitRoute] = []
                let took = clock.measure {
                    routes = TransitPlanner.routes(on: PerfKit.network, from: trip.start, to: trip.end,
                                                   departure: PerfKit.departure, modes: [.subway, .bus])
                }
                if !routes.isEmpty { found += 1 }
                #expect(took < .milliseconds(500), "\(trip.name) took \(took)")
            }
        }
        print("Performance: 20 trips by subway and bus, \(found) found")
        #expect(found >= 19)
    }

    @Test func timedPlanner() {
        let found = within(.milliseconds(800), "20 trips timed") {
            PerfKit.trips.filter { !TripPlanner.plan(from: $0.from, to: $0.to, at: PerfKit.departure, timetable: PerfKit.subway).isEmpty }.count
        }
        print("Performance: 20 trips timed, \(found) found")
        #expect(found >= 17)
    }

    @Test func wayFinder() {
        let finder = within(.milliseconds(200), "way finder built") { WayFinder(timetable: PerfKit.subway) }
        let found = within(.milliseconds(6500), "\(PerfKit.wayPairs.count) ways across the week") {
            PerfKit.wayPairs.filter { !finder.ways(from: $0.0, to: $0.1).listed.isEmpty }.count
        }
        print("Performance: \(PerfKit.wayPairs.count) ways across the week, \(found) found")
        #expect(PerfKit.wayPairs.count >= 6)
        // All 8 found on 2026-11-10
        #expect(found >= PerfKit.wayPairs.count - 1)
    }

    /// Six of the bench's walks, from the tiles read, each within its own ceiling.
    @Test func walks() async {
        let store = WalkGraphStore()
        let ceilings: [String: Duration] = [
            "parkslope-4av": .milliseconds(1200), "midtown": .milliseconds(900), "jacksonheights": .milliseconds(1600),
            "centralpark": .milliseconds(1000), "brooklyn-bridge": .milliseconds(1900), "prospect-park": .milliseconds(2200),
        ]
        for walk in PerfKit.walks {
            guard let ceiling = ceilings[walk.name] else { continue }
            let routed = await within(ceiling, "walk \(walk.name)") { await PerfKit.routeWalks([walk], on: store) }
            #expect(routed == 1)
        }
    }

    @Test func longWalk() async {
        let routed = await within(.seconds(31), "walk 19st-midtown") {
            await PerfKit.routeWalks([("19st-midtown", PerfKit.longWalk.from, PerfKit.longWalk.to)], on: WalkGraphStore())
        }
        #expect(routed == 1)
    }

    @Test func feeds() {
        let arrivals = within(.milliseconds(200), "feed arrivals") { PerfKit.feedArrivals() }
        let stops = within(.milliseconds(200), "feed timed stops") { PerfKit.timedStops() }
        #expect(arrivals > 0)
        #expect(stops > 0)
    }

    @Test func widgetTimelines() {
        let entries = within(.milliseconds(200), "widget timelines") { PerfKit.widgetTimelines() }
        #expect(entries > 0)
    }

    @Test func decoding() throws {
        let read = try within(.milliseconds(200), "bundled lists read") { try PerfKit.decodeBundled() }
        let patterns = try within(.milliseconds(200), "timetable round trip") { try PerfKit.timetableRoundTrip() }
        #expect(read > 0)
        #expect(patterns == PerfKit.subway.patterns.count)
    }

    @Test func nearbyLines() {
        let drawn = within(.milliseconds(600), "Nearby lines, 8 moves") { PerfKit.moveNearby() }
        #expect(drawn > 0)
    }
}
