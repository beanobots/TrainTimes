import CoreLocation
import Foundation
import Testing
@testable import Leeway

// Buses, Citi Bike and your own bike, and Nearby: the rules they keep, on the bundled data and
// on server answers made here.

// MARK: - Helpers

/// Places the tests stand at.
enum BusBikePlaces {
    /// 5 Av & 9 St, Park Slope: the B63's stop toward Pier 6 (308204), and the one across (305423).
    static let parkSlopeNorth = CLLocation(latitude: 40.669453, longitude: -73.986015)
    static let parkSlopeSouth = CLLocation(latitude: 40.668896, longitude: -73.986608)
    static let timesSquare = CLLocation(latitude: 40.7580, longitude: -73.9855)
    static let hoboken = CLLocation(latitude: 40.7450, longitude: -74.0300)
    /// Staten Island by the Verrazzano: Bay Ridge is across the Narrows, with no walk over.
    static let fortWadsworth = CLLocation(latitude: 40.6000, longitude: -74.0600)
    /// The Atlantic south of Long Beach: no land, stop or dock.
    static let atlantic = CLLocation(latitude: 40.4500, longitude: -73.7000)
    static let albany = CLLocation(latitude: 42.6500, longitude: -73.7500)

    static func place(_ name: String, _ location: CLLocation) -> BusRide.Place {
        BusRide.Place(name: name, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }
}

/// A Citi Bike dock with counts.
func testDock(_ id: String, _ lat: Double, _ lon: Double, bikes: Int = 10, eBikes: Int = 5, docks: Int = 10,
              renting: Bool = true, returning: Bool = true) -> CitiBike.Dock {
    CitiBike.Dock(id: id, name: "Dock \(id)", lat: lat, lon: lon, bikes: bikes, eBikes: eBikes, docks: docks,
                  renting: renting, returning: returning)
}

/// A bus at a stop, due `minutes` after `now`, live or by the timetable.
func testBus(_ line: String, _ minutes: Double, after now: Date, live: Bool = true, to destination: String? = nil) -> BusArrival {
    let time = now.addingTimeInterval(minutes * 60)
    return BusArrival(line: line, destination: destination, expected: live ? time : nil, aimed: live ? nil : time)
}

/// One test at a time with the bus timetable file, which is the whole app's.
actor BusTimetableLock {
    static let shared = BusTimetableLock()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

/// Runs `body` with `timetable` as the App Group's bus timetable, then puts back whatever was
/// there (its bytes and date, so it's neither lost nor taken as fresh).
func withBusTimetable<T>(_ timetable: Timetable, _ body: () async throws -> T) async throws -> T {
    await BusTimetableLock.shared.acquire()
    defer { Task { await BusTimetableLock.shared.release() } }
    let file = try #require(SharedStore.url(named: "bus-timetable.bin"))
    let manager = FileManager.default
    let saved = try? Data(contentsOf: file)
    let savedDate = (try? manager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try timetable.encoded().write(to: file, options: .atomic)
    defer {
        if let saved {
            try? saved.write(to: file, options: .atomic)
            if let savedDate { try? manager.setAttributes([.modificationDate: savedDate], ofItemAtPath: file.path) }
        } else {
            try? manager.removeItem(at: file)
        }
    }
    return try await body()
}

/// A small bus timetable round 5 Av & 9 St, from 04:00 on 2026-11-10: the B63 north through S1
/// (08:20, and 07:00, 10:30, 23:50 and 00:10), south through S2 across from it (08:25), and a
/// B99 that ends at S1 (08:18).
enum ParkSlopeTimetable {
    static let base = Fixtures.date("2026-11-10 04:00")

    static func seconds(_ time: String, nextDay: Bool = false) -> UInt32 {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return UInt32((parts[0] - 4 + (nextDay ? 24 : 0)) * 3600 + parts[1] * 60)
    }

    static let timetable = Timetable(
        made: base, base: base,
        stops: ["S1", "S2", "S3", "S4"],
        routes: ["B63\tPIER 6 BKLYN BRIDGE PARK via 5 AV", "B63\tBAY RIDGE SHORE RD via 5 AV", "B99\tNOWHERE"],
        patterns: [
            .init(route: 0, calls: [.init(stop: 3, arrives: 0, waits: 0), .init(stop: 0, arrives: 120, waits: 0),
                                    .init(stop: 2, arrives: 300, waits: 0)]),
            .init(route: 1, calls: [.init(stop: 2, arrives: 0, waits: 0), .init(stop: 1, arrives: 180, waits: 0),
                                    .init(stop: 3, arrives: 400, waits: 0)]),
            .init(route: 2, calls: [.init(stop: 3, arrives: 0, waits: 0), .init(stop: 0, arrives: 60, waits: 0)]),
        ],
        starts: [
            [seconds("07:00") - 120, seconds("08:20") - 120, seconds("10:30") - 120, seconds("23:50") - 120,
             seconds("00:10", nextDay: true) - 120],
            [seconds("08:25") - 180],
            [seconds("08:18") - 60],
        ],
        places: [
            .init(latitude: 40.669453, longitude: -73.986015, name: "5 AV/9 ST"),
            .init(latitude: 40.668896, longitude: -73.986608, name: "5 AV/9 ST"),
            .init(latitude: 40.674000, longitude: -73.982000, name: "5 AV/UNION ST"),
            .init(latitude: 40.665000, longitude: -73.991000, name: "5 AV/17 ST"),
        ])
}

// MARK: - Bus names and keys

struct BusNameTests {
    /// Bus Time's capitals read as a sign: "&" for "/", small "via", airports in capitals.
    @Test func readableNames() {
        #expect(BusNames.readable("7 AV/9 ST") == "7 Av & 9 St")
        #expect(BusNames.readable("LGA/TERMINAL B") == "LGA & Terminal B")
        #expect(BusNames.readable("PIER 6 BKLYN BRIDGE PARK VIA 5 AV") == "Pier 6 Bklyn Bridge Park via 5 Av")
    }

    /// A headsign loses its service ("Select Bus Service", "Limited"), shown by the badge.
    @Test func destinationDropsService() {
        #expect(BusNames.destination("SELECT BUS SERVICE 125 ST via 1 AV") == "125 St via 1 Av")
        #expect(BusNames.destination("LIMITED JAMAICA LIRR") == "Jamaica LIRR")
        #expect(BusLineStopsStep.shortName("PIER 6 BKLYN BRIDGE PARK via 5 AV") == "Pier 6 Bklyn Bridge Park")
    }

    /// Select Bus Service in each spelling is tagged and badged as its plain number.
    @Test func selectBusTags() {
        for line in ["M86-SBS", "M86 SBS", "M86+", "m86-sbs"] {
            #expect(BusNames.isSBS(line), "\(line)")
            #expect(BusNames.label(line).uppercased() == "M86", "\(line)")
        }
        #expect(!BusNames.isSBS("B63"))
        #expect(BusBadge.spokenName("M86+") == "M86 Select Bus")
        #expect(BusBadge.spokenName("B63") == "B63 bus")
    }

    /// The bundled routes' keys: SBS as "+", leading zeros dropped, case and spaces ignored.
    @Test func routeKeys() {
        #expect(BusRoutes.key("M15-SBS") == "M15+")
        #expect(BusRoutes.key("m15 sbs") == "M15+")
        #expect(BusRoutes.key("Q06") == "Q6")
        #expect(BusRoutes.key("BX12+") == "BX12+")
        #expect(TrackShapes.busKey("M15 SBS") == "M15+")
    }

    /// The bus map keys a line as the routes do: an old "Q06" finds the Q6's drawn ways and stops.
    @Test func mapKeyDropsLeadingZeros() throws {
        #expect(TrackShapes.busKey("Q06") == "Q6" && TrackShapes.busKey("q06-sbs") == "Q6+")
        let q6 = try #require(BusNetwork.byLine["Q6"])
        #expect(!q6.isEmpty)
        #expect(BusNetwork.ways(of: ["Q06"]).map(\.index) == BusNetwork.ways(of: ["Q6"]).map(\.index))
        #expect(BusNetwork.byLine.keys.allSatisfy { TrackShapes.busKey($0) == $0 })
        #expect(BusNetwork.stops.allSatisfy { stop in stop.lines.allSatisfy { TrackShapes.busKey($0) == $0 } })
        let stop = try #require(BusNetwork.stops.first { $0.lines.contains("Q6") })
        let ways = BusNetwork.ways(of: ["Q06"])
        #expect(BusSides(ways: ways).way(at: stop.coordinate, lines: [TrackShapes.busKey("Q06")]) != nil)
    }

    /// A saved bus from before names "Q06" as "Q6", in `line` and `lines` alike.
    @Test func busChoiceUnpadsOldLines() throws {
        let json = #"{"line":"Q06","lines":["Q06","Q09"],"stop":{"id":"1","name":"A","latitude":40.7,"longitude":-73.8}}"#
        let choice = try JSONDecoder().decode(BusChoice.self, from: Data(json.utf8))
        #expect(choice.line == "Q6")
        #expect(choice.allLines == ["Q6", "Q9"])
        #expect(!choice.bothWays)
    }
}

// MARK: - Bundled bus routes and network

struct BusRoutesDataTests {
    /// The B63 runs both ways, its stops in order with the timetable's minutes rising from boarding.
    @Test func b63AheadRises() throws {
        #expect(BusRoutes.ways(of: "b63").count >= 2)
        let ahead = BusRoutes.ahead(on: "B63", from: "306619", toward: "PIER 6 BKLYN BRIDGE PARK via 5 AV")
        try #require(ahead.count > 10)
        #expect(ahead.allSatisfy { $0.minutes > 0 })
        #expect(zip(ahead, ahead.dropFirst()).allSatisfy { $0.minutes <= $1.minutes })
        #expect(!ahead.contains { $0.stop.code == "306619" })
    }

    /// Near 5 Av & 9 St, the B63 each way once, at its nearest stop, nearest first.
    @Test func nearbyEachLineAndWayOnce() {
        let near = BusRoutes.nearby(BusBikePlaces.parkSlopeNorth, walkMinutes: 5)
        let b63 = near.filter { $0.line == "B63" }
        #expect(Set(b63.map(\.to)).count == b63.count)
        #expect(b63.contains { $0.to.hasPrefix("PIER 6") && $0.stop.code == "308204" })
        #expect(b63.contains { $0.to.hasPrefix("BAY RIDGE") })
        #expect(zip(near, near.dropFirst()).allSatisfy { $0.meters <= $1.meters })
    }

    /// The network's stops have the way their buses go: 5 Av's north-east, then south-west across.
    @Test func stopBearingsByDirection() throws {
        let north = try #require(BusNetwork.stopByID["308204"])
        let south = try #require(BusNetwork.stopByID["305423"])
        #expect(north.lines.contains("B63") && south.lines.contains("B63"))
        let turn = abs(north.bearing - south.bearing)
        #expect(abs(turn - 180) < 20)
    }

    /// A bearing as map points have it: north is up (-y), east is +x.
    @Test func stopAngleFromBearing() {
        func angle(_ bearing: Double) -> Double {
            BusNetwork.Stop(id: "x", coordinate: .init(), bearing: bearing, lines: []).angle
        }
        #expect(abs(angle(0) - -Double.pi / 2) < 1e-9)
        #expect(abs(angle(90)) < 1e-9)
        #expect(abs(angle(180) - Double.pi / 2) < 1e-9)
    }

    /// Each B63 stop's mark sits on its own side's way, going its buses' way, not the other side's.
    @Test func busSidesByDirection() throws {
        let sides = BusSides(ways: BusNetwork.ways(of: ["B63"]))
        for id in ["308204", "305423"] {
            let stop = try #require(BusNetwork.stopByID[id])
            let way = try #require(sides.way(at: stop.coordinate, lines: stop.lines))
            var off = abs(way.angle - stop.angle).truncatingRemainder(dividingBy: 2 * .pi)
            off = min(off, 2 * .pi - off)
            #expect(off < .pi / 4, "\(id)")
        }
    }

    /// A ride drawn along the B63's street, from near its start to near its end.
    @Test func pathAlongLine() throws {
        let from = try #require(BusNetwork.stopByID["305423"]).coordinate
        let toStop = try #require(BusRoutes.stopByCode["801042"])
        let path = try #require(BusNetwork.path(of: "B63", from: from, to: CLLocationCoordinate2D(
            latitude: toStop.latitude, longitude: toStop.longitude)))
        #expect(path.count > 2)
        let start = CLLocation(latitude: path[0].latitude, longitude: path[0].longitude)
        #expect(start.distance(from: CLLocation(latitude: from.latitude, longitude: from.longitude)) < 200)
    }

    /// Nearby's pale bus lines: the B63 stops by 5 Av & 9 St; none drawn with no place.
    @Test func nearbyBusLines() {
        let coordinate = BusBikePlaces.parkSlopeNorth.coordinate
        #expect(NearbyLines.busLines(near: coordinate, within: 150).contains("B63"))
        #expect(NearbyLines.nearestStopsLines(near: BusBikePlaces.parkSlopeNorth).contains("B63"))
        #expect(NearbyLines.nearestStopsLines(near: nil).isEmpty)
    }

    /// A line's two main ways for the home stop picker, and their ends named without "via".
    @Test func homeStopMainWays() {
        let ways = BusLineStopsStep.mainWays(of: "B63")
        #expect(ways.count == 2)
        #expect(ways[0].stops.first?.code != ways[1].stops.first?.code)
        let ends = BusLineStopsStep.ends(of: "B63")
        #expect(ends.contains(" – ") && !ends.lowercased().contains(" via "))
    }
}

// MARK: - Bus trips

struct BusTripTests {
    let now = Fixtures.date("2026-11-10 08:15")
    let from = BusRide.Place(name: "5 Av & 9 St", latitude: 40.669453, longitude: -73.986015)
    let to = BusRide.Place(name: "5 Av & Union St", latitude: 40.6770, longitude: -73.9800)

    /// A ride's time: the timetable's seconds, else 2 minutes a stop, else 5 stops' worth.
    @Test func rideDuration() {
        #expect(BusRide(line: "B63", from: from, to: to, seconds: 420).duration == 420)
        #expect(BusRide(line: "B63", from: from, to: to, stops: 3).duration == 360)
        #expect(BusRide(line: "B63", from: from, to: to).duration == 600)
    }

    /// A bus alone with no timetable time: there when you're at the stop, the 5-minute wait, the ride.
    @Test func arrivalWithoutTimetableWaitsFiveMinutes() throws {
        let trip = BusTrip(bus: BusRide(line: "B63", from: from, to: to, seconds: 600), busFirst: true)
        let arrival = try #require(trip.arrival(from: from.location, to: to.location, at: now, timetable: nil))
        #expect(arrival == now.addingTimeInterval(BusTrip.wait + 600))
        #expect(trip.minutes(from: from.location, to: to.location, at: now, timetable: nil) == 15)
    }

    /// A timetable's leaving time, when it can be caught, rather than the 5-minute guess.
    @Test func arrivalByTimetableLeaves() throws {
        var ride = BusRide(line: "B63", from: from, to: to, seconds: 600)
        ride.leaves = now.addingTimeInterval(2 * 60)
        let trip = BusTrip(bus: ride, busFirst: true)
        let arrival = try #require(trip.arrival(from: from.location, to: to.location, at: now, timetable: nil))
        #expect(arrival == now.addingTimeInterval(120 + 600))
    }

    /// Ranking counts the whole wait for a first bus: 12 minutes standing counts as 12.
    @Test func penaltyCountsWholeBusWait() {
        var ride = BusRide(line: "B63", from: from, to: to, seconds: 600)
        ride.leaves = now.addingTimeInterval(12 * 60)
        let trip = BusTrip(bus: ride, busFirst: true)
        #expect(abs(trip.penalty(from: from.location, to: to.location, at: now, timetable: nil) - 720) < 0.001)
        ride.leaves = nil
        #expect(abs(BusTrip(bus: ride, busFirst: true).penalty(from: from.location, to: to.location, at: now,
                                                               timetable: nil) - BusTrip.wait) < 0.001)
    }

    /// Two buses: a change on foot counted, and the walk between their stops at least a minute.
    @Test func twoBusesChangeCost() {
        let onward = BusRide(line: "B41", from: to, to: from, seconds: 300)
        let trip = BusTrip(bus: BusRide(line: "B63", from: from, to: to, seconds: 600), busFirst: true, onward: onward)
        #expect(trip.walk == 60)
        let penalty = trip.penalty(from: from.location, to: from.location, at: now, timetable: nil)
        #expect(abs(penalty - (TripPlanner.changeCost(across: false) + BusTrip.wait)) < 0.001)
        #expect(trip.endName == from.name)
    }

    /// A live bus is Bus Time's expected time; one yet to leave its terminal, the timetable's.
    @Test func arrivalTimes() {
        let live = testBus("B63", 3, after: now)
        let aimed = testBus("B63", 4, after: now, live: false)
        #expect(live.isLive && !aimed.isLive)
        #expect(aimed.time == now.addingTimeInterval(240))
        var both = live
        both.aimed = now
        #expect(both.time == live.expected)
    }

    /// A shared bus trip shows for an hour from when it's shared, not before (clock set back).
    @Test func sharedBusTripWindow() {
        let shown = SharedBusTrip(trip: BusTrip(bus: BusRide(line: "B63", from: from, to: to), busFirst: true), shared: now)
        #expect(shown.isActive(at: now))
        #expect(shown.isActive(at: now.addingTimeInterval(59 * 60)))
        #expect(!shown.isActive(at: now.addingTimeInterval(60 * 60)))
        #expect(!shown.isActive(at: now.addingTimeInterval(-1)))
    }
}

// MARK: - Nearby's bus places and lines

struct NearbyBusTests {
    let now = Fixtures.date("2026-11-10 08:15")
    let north = BusStop(id: "308204", name: "5 AV/9 ST", latitude: 40.669453, longitude: -73.986015)
    let south = BusStop(id: "305423", name: "5 AV/9 ST", latitude: 40.668896, longitude: -73.986608)

    var place: NearbyBusPlace {
        NearbyBusPlace(ways: [
            .init(stop: north, destination: nil, arrivals: [
                testBus("B63", 4, after: now, to: "PIER 6 BKLYN BRIDGE PARK via 5 AV"),
                testBus("B67", 2, after: now, to: "DOWNTOWN"),
                testBus("B63", 14, after: now, to: "PIER 6 BKLYN BRIDGE PARK via 5 AV"),
                testBus("B63", -1, after: now),
            ]),
            .init(stop: south, destination: nil, arrivals: [
                testBus("B63", 6, after: now, to: "BAY RIDGE SHORE RD via 5 AV"),
            ]),
        ], meters: 120)
    }

    /// The line grid's rule: each line once, soonest first, with its buses each way it goes.
    @Test func eachLineOnceSoonestFirst() throws {
        let lines = place.lines(at: now)
        #expect(lines.map(\.line) == ["B67", "B63"])
        let b63 = try #require(lines.last)
        #expect(b63.ways.count == 2)
        #expect(b63.ways[0].arrivals.count == 2)
        #expect(b63.ways[0].arrivals.allSatisfy { ($0.time ?? .distantPast) > now })
        #expect(b63.ways[1].name == "Bay Ridge Shore Rd via 5 Av")
    }

    /// The limit on lines, and buses each way kept to three.
    @Test func linesLimitAndThreeBuses() {
        let arrivals = (1...6).map { testBus("B63", Double($0), after: now) }
            + ["B1", "B2", "B3"].map { testBus($0, 10, after: now) }
        let picks = NearbyBusPick.lines(at: [(north, arrivals)], date: now, limit: 3)
        #expect(picks.count == 3)
        #expect(picks[0].line == "B63" && picks[0].ways[0].arrivals.count == 3)
    }

    /// A bus line picked both ways shows the other beside it; as an intent's parameter, unchanged.
    @Test func pickShownAndEncoded() throws {
        let pick = try #require(place.lines(at: now).last)
        let shown = try #require(pick.shown(way: 0, both: true, at: now))
        #expect(shown.otherWay?.from.latitude == south.latitude)
        #expect(pick.shown(way: 0, both: false, at: now)?.otherWay == nil)
        #expect(NearbyBusPick(encoded: pick.encoded) == pick)
        #expect(NearbyBusPlace(encoded: place.encoded) == place)
    }

    /// A place by its nearer stop's sign, and its walk as a station's is timed.
    @Test func placeNameAndWalk() {
        #expect(place.name == "5 Av & 9 St")
        #expect(place.walkMinutes == TripPlanner.walkMinutes(120))
        #expect(NearbyBuses.place([.init(stop: north, meters: 300, arrivals: []), .init(stop: south, meters: 90, arrivals: [])])
            .meters == 90)
    }

    /// The home stop picker: each side's next buses, where they go, and the stop kept each way.
    @Test func homeStopPickerWays() throws {
        let place = place
        let way = place.ways[0]
        #expect(place.buses(at: way, lines: ["B63"], now: now).count == 2)
        #expect(place.going(way, lines: ["B63"]) == "Pier 6 Bklyn Bridge Park")
        #expect(place.detail(way, index: 0, lines: ["B63"], now: now) == "This side · Next: 4 min, 14 min")
        #expect(place.detail(place.ways[1], index: 1, lines: ["B63", "B67"], now: now) == "Across the street · Next: B63 6 min")
        let choice = try #require(place.choice(lines: ["B63"], way: 0, of: place.ways, both: true))
        #expect(choice.stop.id == "308204" && choice.otherStop?.id == "305423" && choice.bothWays)
        #expect(choice.destination == "PIER 6 BKLYN BRIDGE PARK via 5 AV")
        #expect(choice.otherWay?.stop.id == "305423")
        #expect(choice.shortWayName == "Pier 6 Bklyn Bridge Park")
    }

    /// The Home Stop's countdown keeps its stop and lines, not the changes and plan only widgets follow.
    @Test func homeStopForCountdown() {
        let change = BusChange(stop: south, minutes: 5, walkMinutes: 2,
                               selection: Selection(stationID: "R31", routes: ["R"], direction: .north))
        var choice = BusChoice(line: "B63", lines: ["B63", "B67"], stop: north, changes: [change],
                               planned: PlannedTrip(ways: []))
        choice.bothWays = true
        let countdown = choice.forCountdown
        #expect(countdown.changes == nil && countdown.planned == nil)
        #expect(countdown.allLines == ["B63", "B67"] && countdown.stop == north && countdown.bothWays)
    }
}

// MARK: - Bus ↔ train changes

struct BusChangeTests {
    let now = Fixtures.date("2026-11-10 08:15")
    let stop = BusStop(id: "308204", name: "5 AV/9 ST", latitude: 40.669453, longitude: -73.986015)

    func train(_ route: String, _ minutes: Double, stop: String = "R31N") -> Arrival {
        Arrival(route: route, time: now.addingTimeInterval(minutes * 60), stop: stop, lastStop: "R01N", isLive: true,
                trip: "\(route)-\(minutes)")
    }

    /// Train to bus: the first bus caught after the walk, among the ways by when each leaves.
    @Test func trainToBusFirstCatchable() throws {
        let leg = BusLeg(line: "B63", stop: stop, destination: "PIER 6", walkMinutes: 3)
        let arrival = train("R", 10)
        let later = train("F", 30, stop: "F23N")
        var connection = Connection(first: train("R", 0), arrival: arrival, next: later, walk: 120)
        connection.ways = [Way(route: "F", connection: connection, arrival: later)]
        let buses = [testBus("B63", 11, after: now), testBus("B63", 14, after: now), testBus("B63", 20, after: now)]
        let changed = TrainService.addingBuses([(leg: leg, arrivals: buses)], to: connection)
        let ways = try #require(changed.ways)
        #expect(ways.count == 2)
        #expect(ways[0].route == "bus:B63")
        #expect(ways[0].arrival?.time == now.addingTimeInterval(14 * 60))
        #expect(ways[0].connection?.walk == 180)
        #expect(BusLeg.line(of: ways[0].route) == "B63")
        #expect(changed.next == later)
    }

    /// With no train to change to, the bus is the connection.
    @Test func busBecomesConnection() {
        let leg = BusLeg(line: "B63", stop: stop, walkMinutes: 2)
        let connection = Connection(first: train("R", 0), arrival: train("R", 10), next: nil)
        let changed = TrainService.addingBuses([(leg: leg, arrivals: [testBus("B63", 15, after: now)])], to: connection)
        #expect(changed.next?.route == "bus:B63")
        #expect(changed.walk == 120)
    }

    /// Bus to train: timed to the change by the timetable's minutes, then the walk, then the first
    /// train it can catch at each change, soonest first.
    @Test func busToTrainConnections() throws {
        let off = BusStop(id: "305000", name: "5 AV/UNION ST", latitude: 40.677, longitude: -73.98)
        let changes = [BusChange(stop: off, minutes: 6, walkMinutes: 3,
                                 selection: Selection(stationID: "R31", routes: ["R"], direction: .north)),
                       BusChange(stop: off, minutes: 9, walkMinutes: 1,
                                 selection: Selection(stationID: "D24", routes: ["Q"], direction: .north))]
        let choice = BusChoice(line: "B63", stop: stop, changes: changes)
        let buses = [testBus("B63", -2, after: now), testBus("B63", 4, after: now)]
        // Off the bus at 08:25 (R) or 08:28 (Q), walked to by 08:28 or 08:29
        let trains = [[train("R", 12), train("R", 14)], [train("Q", 13, stop: "D24N"), train("Q", 20, stop: "D24N")]]
        let connections = choice.connections(buses: buses, trains: trains, at: now)
        let connection = try #require(connections.first)
        #expect(connections.count == 1)
        #expect(connection.first.route == "bus:B63")
        #expect(connection.next?.route == "R" && connection.next?.time == now.addingTimeInterval(14 * 60))
        #expect(connection.ways?.map(\.route) == ["R", "Q"])
        #expect(connection.stationID == nil)
        #expect(choice.trainChange?.stationID == "R31")
        #expect(choice.trainChange?.alternatives.map(\.stationID) == ["D24"])
    }
}

// MARK: - Bus Time through the push server

struct BusTimesNetworkTests {
    let now = Fixtures.date("2026-11-10 08:15")

    func body(_ stop: BusStop, _ arrivals: [BusArrival]) throws -> Data {
        try JSONEncoder().encode(BusStopTimes(stop: stop, arrivals: arrivals))
    }

    /// `GET /buses` for a line at a stop: gone buses dropped, soonest first, "+" escaped.
    @Test func liveArrivalsSortedAndEscaped() async throws {
        let stop = BusStop(id: "401687", name: "1 AV/E 14 ST", latitude: 40.732109, longitude: -73.981917)
        let now = now
        let data = try body(stop, [testBus("M15+", 9, after: now), testBus("M15+", -3, after: now), testBus("M15+", 2, after: now)])
        let (times, made) = await withNetwork({ $0.url?.path == "/buses" ? .ok(data) : nil }) {
            await BusTimes.arrivals(line: "M15+", at: BusRide.Place(name: "1 Av", latitude: 40.732101, longitude: -73.981901),
                                    now: now)
        }
        #expect(times?.arrivals.map(\.time) == [now.addingTimeInterval(120), now.addingTimeInterval(540)])
        #expect(times?.stop.id == "401687")
        let query = try #require(made.first?.url.query)
        #expect(query.contains("line=M15%2B"))
        #expect(query.contains("stop=40.732101,-73.981901"))
    }

    /// Several lines at once: each asked, merged soonest first, only those at the chosen stop.
    @Test func manyLinesMergedAtStop() async throws {
        let mine = BusStop(id: "500001", name: "MINE", latitude: 40.70, longitude: -73.90)
        let across = BusStop(id: "500002", name: "ACROSS", latitude: 40.7001, longitude: -73.9001)
        let now = now
        let b1 = try body(mine, [testBus("Q58", 7, after: now)])
        let b2 = try body(mine, [testBus("Q39", 3, after: now)])
        let b3 = try body(across, [testBus("B57", 1, after: now)])
        let (times, made) = await withNetwork({ request in
            let query = request.url?.query ?? ""
            return query.contains("line=Q58") ? .ok(b1) : query.contains("line=Q39") ? .ok(b2) : .ok(b3)
        }) {
            await BusTimes.arrivals(lines: ["Q58", "Q39", "B57"], at: BusRide.Place(name: "x", latitude: 40.700012, longitude: -73.900012),
                                    onlyAt: "500001", now: now)
        }
        #expect(made.count == 3)
        #expect(times?.arrivals.map(\.line) == ["Q39", "Q58"])
    }

    /// Nearby's bus places from `GET /buses/nearby`, each a stop and the one across from it.
    @Test func nearbyPlaces() async throws {
        let now = now
        let stop = { (id: String) in BusStop(id: id, name: "\(id) ST", latitude: 40.69, longitude: -73.91) }
        let ways = [NearbyBuses.Way(stop: stop("1"), meters: 80, arrivals: [testBus("B26", 4, after: now)]),
                    NearbyBuses.Way(stop: stop("2"), meters: 95, arrivals: [])]
        struct Body: Encodable { var ways: [NearbyBuses.Way]; var places: [[NearbyBuses.Way]] }
        let data = try JSONEncoder().encode(Body(ways: ways, places: [ways, [ways[1]]]))
        let (places, made) = await withNetwork({ $0.url?.path == "/buses/nearby" ? .ok(data) : nil }) {
            await NearbyBuses.places(near: CLLocation(latitude: 40.69001, longitude: -73.91001))
        }
        #expect(places?.count == 2)
        #expect(places?.first?.ways.count == 2 && places?.first?.meters == 80)
        #expect(made.first?.url.query == "at=40.69001,-73.91001")
    }
}

// MARK: - The bus timetable, without Bus Time

@Suite(.serialized) struct BusScheduleTests {
    let morning = Fixtures.date("2026-11-10 08:15")
    let here = BusBikePlaces.place("5 Av & 9 St", BusBikePlaces.parkSlopeNorth)

    /// The B63 by the timetable at its nearest stop: only buses due in the next two hours, aimed, not live.
    @Test func timesWithinTwoHours() async throws {
        let times = try await withBusTimetable(ParkSlopeTimetable.timetable) {
            BusSchedule.times(line: "b63", at: here, now: morning)
        }
        let found = try #require(times)
        #expect(found.stop.id == "S1" && found.stop.name == "5 AV/9 ST")
        #expect(found.arrivals.map(\.time) == [Fixtures.date("2026-11-10 08:20")])
        #expect(found.arrivals.allSatisfy { !$0.isLive && $0.line == "B63" })
        #expect(found.arrivals.first?.destination == "PIER 6 BKLYN BRIDGE PARK via 5 AV")
    }

    /// Late at night, the buses either side of midnight, in order.
    @Test func timesAcrossMidnight() async throws {
        let times = try await withBusTimetable(ParkSlopeTimetable.timetable) {
            BusSchedule.times(line: "B63", at: here, now: Fixtures.date("2026-11-10 23:45"))
        }
        #expect(times?.arrivals.map(\.time) == [Fixtures.date("2026-11-10 23:50"), Fixtures.date("2026-11-11 00:10")])
    }

    /// A line whose last stop it is isn't ridden from there, nor are its buses listed.
    @Test func lineEndingAtStopLeftOut() async throws {
        let (b99, places) = try await withBusTimetable(ParkSlopeTimetable.timetable) {
            (BusSchedule.times(line: "B99", at: here, now: morning),
             BusSchedule.places(near: BusBikePlaces.parkSlopeNorth, now: morning))
        }
        #expect(b99 == nil)
        #expect(places?.flatMap { $0.ways.flatMap(\.arrivals) }.contains { $0.line == "B99" } == false)
    }

    /// Nearby by the timetable: the stop and the one across sharing its line, as one place.
    @Test func placesPairAcross() async throws {
        let places = try await withBusTimetable(ParkSlopeTimetable.timetable) {
            BusSchedule.places(near: BusBikePlaces.parkSlopeNorth, now: morning)
        }
        let first = try #require(places?.first)
        #expect(places?.count == 1)
        #expect(first.ways.map(\.stop.id) == ["S1", "S2"])
        #expect(first.meters < 1)
        #expect(first.lines(at: morning).map(\.line) == ["B63"])
    }

    /// Before the timetable starts, or after its last bus, it has none.
    @Test func outsideTimetable() async throws {
        let (before, after) = try await withBusTimetable(ParkSlopeTimetable.timetable) {
            (BusSchedule.times(line: "B63", at: here, now: Fixtures.date("2026-11-10 03:00")),
             BusSchedule.times(line: "B63", at: here, now: Fixtures.date("2026-11-11 01:00")))
        }
        #expect(before == nil && after == nil)
    }

    /// Across the clocks going back (1 Nov 2026), two hours ahead is two real hours, not the wall clock's.
    @Test func fallBackTwoRealHours() async throws {
        let base = Fixtures.date("2026-10-31 04:00")
        let timetable = Timetable(
            made: base, base: base, stops: ["S1", "S3"], routes: ["B63\tPIER 6"],
            patterns: [.init(route: 0, calls: [.init(stop: 0, arrives: 0, waits: 0), .init(stop: 1, arrives: 300, waits: 0)])],
            starts: [[81_900, 85_500]],
            places: [.init(latitude: 40.669453, longitude: -73.986015, name: "5 AV/9 ST"),
                     .init(latitude: 40.674, longitude: -73.982, name: "5 AV/UNION ST")])
        // 01:30 EDT; the buses at 01:45 EST (75 min on) and 02:45 EST (135 min on)
        let now = base.addingTimeInterval(77_400)
        let times = try await withBusTimetable(timetable) { BusSchedule.times(line: "B63", at: here, now: now) }
        let arrivals = try #require(times?.arrivals)
        #expect(arrivals.map(\.time) == [base.addingTimeInterval(81_900)])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Fixtures.newYork
        let shown = try #require(arrivals.first?.time)
        #expect(calendar.component(.hour, from: shown) == 1 && calendar.component(.minute, from: shown) == 45)
        #expect(!Fixtures.newYork.isDaylightSavingTime(for: shown))
    }
}

// MARK: - Citi Bike

struct CitiBikeTests {
    /// Bike and e-bike, named and counted.
    @Test func kindsNamedAndCounted() {
        #expect(CitiBike.Kind.bike.name == "Bike" && CitiBike.Kind.eBike.name == "E-Bike")
        #expect(CitiBike.Kind.bike.count(1) == "1 bike")
        #expect(CitiBike.Kind.eBike.count(6) == "6 e-bikes")
        #expect(CitiBike.Kind.eBike.count(0) == "0 e-bikes")
    }

    /// A dock's bikes of each kind, none while it's not renting; its free docks, none while not returning.
    @Test func dockAvailability() {
        let dock = testDock("1", 40.7, -74, bikes: 3, eBikes: 7, docks: 9)
        #expect(dock.available(.bike) == 3 && dock.available(.eBike) == 7 && dock.free == 9)
        let closed = testDock("2", 40.7, -74, renting: false, returning: false)
        #expect(closed.available(.bike) == 0 && closed.available(.eBike) == 0 && closed.free == 0)
    }

    /// Under 4 bikes (of the kind ridden) or docks, a trip warns; 4 is enough.
    @Test func shortUnderFour() {
        func trip(_ kind: CitiBike.Kind, bikes: Int, eBikes: Int, docks: Int) -> BikeTrip {
            BikeTrip(kind: kind, pickup: testDock("a", 40.7, -74, bikes: bikes, eBikes: eBikes),
                     dropoff: testDock("b", 40.71, -74, docks: docks), path: [], rideMinutes: 10, bikeFirst: true, minutes: 15)
        }
        #expect(CitiBike.few == 4)
        #expect(!trip(.bike, bikes: 4, eBikes: 0, docks: 4).isShort)
        #expect(trip(.bike, bikes: 3, eBikes: 20, docks: 10).isShort)
        #expect(!trip(.eBike, bikes: 0, eBikes: 4, docks: 10).isShort)
        #expect(trip(.eBike, bikes: 20, eBikes: 3, docks: 10).isShort)
        #expect(trip(.bike, bikes: 10, eBikes: 0, docks: 3).isShort)
    }

    /// Over a member's 45 minutes, a ride's charged; your own bike's never short nor charged.
    @Test func overIncludedAndOwnBike() {
        let empty = testDock("a", 40.7, -74, bikes: 0, eBikes: 0, docks: 0)
        var trip = BikeTrip(kind: .bike, pickup: empty, dropoff: empty, path: [], rideMinutes: 46, bikeFirst: true, minutes: 50)
        #expect(trip.isOverIncluded && trip.isShort)
        trip.rideMinutes = 45
        #expect(!trip.isOverIncluded)
        trip.rideMinutes = 70
        trip.owned = true
        #expect(!trip.isOverIncluded && !trip.isShort)
    }

    /// Which docks the push server's `has=` admits, and from Settings' kinds.
    @Test func hasAdmits() {
        let bikesOnly = testDock("1", 40.7, -74, bikes: 2, eBikes: 0)
        let eBikesOnly = testDock("2", 40.7, -74, bikes: 0, eBikes: 1)
        let closed = testDock("3", 40.7, -74, renting: false, returning: false)
        #expect(CitiBike.Has.bike.admits(bikesOnly) && !CitiBike.Has.bike.admits(eBikesOnly))
        #expect(CitiBike.Has.ebike.admits(eBikesOnly) && !CitiBike.Has.ebike.admits(bikesOnly))
        #expect(CitiBike.Has.either.admits(bikesOnly) && CitiBike.Has.either.admits(eBikesOnly))
        #expect(!CitiBike.Has.service.admits(closed) && CitiBike.Has.any.admits(closed))
        #expect(CitiBike.Has(taking: .bikes) == .bike && CitiBike.Has(taking: .eBikes) == .ebike
            && CitiBike.Has(taking: .both) == .either)
    }

    /// Nearby counts the kinds Settings picks at a dock; New Trip rides them.
    @Test func bikeKindsCount() {
        let dock = testDock("1", 40.7, -74, bikes: 3, eBikes: 2)
        #expect(BikeKinds.bike.count(at: dock) == 3 && BikeKinds.eBike.count(at: dock) == 2 && BikeKinds.both.count(at: dock) == 5)
        #expect(BikeKinds.both.kinds == [.bike, .eBike] && BikeKinds.eBike.shared == .eBikes)
    }

    /// Nearby's docks: up to 3, within half a mile, nearest first.
    @Test func nearbyDocks() {
        let here = BusBikePlaces.timesSquare
        let docks = [testDock("far", 40.7700, -73.9855), testDock("b", 40.7600, -73.9855),
                     testDock("a", 40.7590, -73.9855), testDock("c", 40.7620, -73.9855), testDock("d", 40.7630, -73.9855)]
        let near = NearbyDock.nearest(to: here, among: docks)
        #expect(near.map(\.id) == ["a", "b", "c"])
        #expect(near.allSatisfy { $0.meters <= 800 })
        #expect(NearbyDock.nearest(to: here, among: docks, limit: 10).map(\.id) == ["a", "b", "c", "d"])
    }

    /// `GET /docks` asked with where, how many, how far and what kind, nearest first as sent.
    @Test func docksNearAsksServer() async throws {
        let body = #"{"docks":[{"id":"72","name":"W 52 St & 11 Av","lat":40.767,"lon":-73.993,"bikes":4,"eBikes":1,"docks":20,"renting":true,"returning":true}]}"#
        let (docks, made) = await withNetwork({ $0.url?.path == "/docks" ? .ok(Data(body.utf8)) : nil }) {
            await CitiBike.docks(near: CLLocation(latitude: 40.76712, longitude: -73.99321), limit: 2, within: 500, has: .ebike)
        }
        #expect(docks?.map(\.id) == ["72"])
        let items = URLComponents(url: try #require(made.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query == ["at": "40.76712,-73.99321", "limit": "2", "within": "500", "has": "ebike"])
    }

    /// No ids, no request.
    @Test func docksByNoIDs() async {
        let (docks, made) = await withNetwork { await CitiBike.docks(ids: []) }
        #expect(docks?.isEmpty == true && made.isEmpty)
    }
}

// MARK: - Bike trips: lanes, own bike

struct BikeTripLogicTests {
    /// The protected-lane pill: the percent, hidden under 5% or not known.
    @Test func protectedPercentShown() {
        #expect(BikeTripRow.protectedPercent(of: nil) == nil)
        #expect(BikeTripRow.protectedPercent(of: 0.049) == nil)
        #expect(BikeTripRow.protectedPercent(of: 0.05) == 5)
        #expect(BikeTripRow.protectedPercent(of: 0.624) == 62)
        #expect(BikeTripRow.protectedPercent(of: 1) == 100)
    }

    /// The bundled lanes, each shape decoded as BikeLanes reads them.
    static func lanes(_ kind: String) throws -> [[Walk.Point]] {
        let url = try #require(Bundle.main.url(forResource: "bike_lanes", withExtension: "json"))
        let shapes = try JSONDecoder().decode([String: [[Int]]].self, from: Data(contentsOf: url))[kind] ?? []
        return shapes.map { flat in
            var lat = 0, lon = 0
            return stride(from: 0, to: flat.count - 1, by: 2).map { index in
                lat += flat[index]
                lon += flat[index + 1]
                return Walk.Point(lat: Double(lat) / 1e5, lon: Double(lon) / 1e5)
            }
        }
    }

    /// A ride along a two-way protected path is on it either way.
    @Test func twoWayLaneEitherWay() throws {
        let lane = try #require(try Self.lanes("both").max { $0.count < $1.count })
        #expect(try #require(BikeLanes.protectedShare(of: lane)) > 0.95)
        #expect(try #require(BikeLanes.protectedShare(of: lane.reversed())) > 0.95)
    }

    /// A one-way lane counts only ridden its way: against it, it isn't.
    @Test func oneWayLaneOnlyItsWay() throws {
        let lane = try #require(try Self.lanes("along").first {
            abs($0[0].lat - 40.52524) < 1e-6 && abs($0[0].lon - -74.19515) < 1e-6
        })
        #expect(try #require(BikeLanes.protectedShare(of: lane)) > 0.95)
        #expect(try #require(BikeLanes.protectedShare(of: lane.reversed())) < 0.1)
    }

    /// Your own bike from where you are: an id to about 11 m, so a fix a few metres on is the same ride.
    @Test func ownBikePlaceID() {
        let a = CitiBike.Dock.place("Start", CLLocation(latitude: 40.712_34, longitude: -73.987_68))
        let b = CitiBike.Dock.place("Start", CLLocation(latitude: 40.712_32, longitude: -73.987_66))
        #expect(a.id == "place 40.7123 -73.9877" && a.id == b.id)
        #expect(a.renting && a.returning)
        let trip = BikeTrip(kind: .bike, pickup: a, dropoff: b, path: [], rideMinutes: 1, bikeFirst: true, minutes: 1)
        #expect(trip.sameDocks(as: trip))
    }

    /// Settings' own bike rides as its kind; With Transit brings it, leaves it, or both.
    @Test func ownBikeSettings() {
        #expect(OwnBike.none.kind == nil && OwnBike.bike.kind == .bike && OwnBike.eBike.kind == .eBike)
        #expect(BikeCarry.all.brings && BikeCarry.all.leaves)
        #expect(BikeCarry.bring.brings && !BikeCarry.bring.leaves)
        #expect(!BikeCarry.leave.brings && BikeCarry.leave.leaves)
        #expect(!BikeCarry.none.brings && !BikeCarry.none.leaves)
    }

    /// Your own bike, a walk away and no subway: no trip, and Apple Maps isn't asked.
    @Test func ownBikeShortHopNoTrip() async {
        let start = BusBikePlaces.timesSquare
        let end = CLLocation(latitude: 40.7610, longitude: -73.9855)
        let planned = await BikePlanner.plannedOwn(from: start, to: end, endName: "Here", kind: .bike, carry: .all,
                                                   subway: false, walkRange: 1200, at: Fixtures.date("2026-11-10 08:15"))
        #expect(planned.trips.isEmpty && planned.none == nil)
    }
}

// MARK: - Nearby and the water

struct NearbyReachTests {
    /// Each borough's land, and New Jersey, as walks know them.
    @Test func lands() {
        #expect(WalkReach.land(at: BusBikePlaces.timesSquare.coordinate) == .manhattan)
        #expect(WalkReach.land(at: BusBikePlaces.parkSlopeNorth.coordinate) == .longIsland)
        #expect(WalkReach.land(at: .init(latitude: 40.85, longitude: -73.88)) == .bronx)
        #expect(WalkReach.land(at: .init(latitude: 40.58, longitude: -74.15)) == .statenIsland)
        #expect(WalkReach.land(at: BusBikePlaces.hoboken.coordinate) == .newJersey)
        #expect(WalkReach.land(at: .init(latitude: 40.76, longitude: -73.95)) == .roosevelt)
        #expect(WalkReach.land(at: .init(latitude: 40.60, longitude: -73.75)) == .rockaway)
    }

    /// Manhattan to Brooklyn on foot goes over a bridge: longer than as the crow flies.
    @Test func walkOverBridge() throws {
        let walk = try #require(WalkReach.meters(from: BusBikePlaces.timesSquare, to: BusBikePlaces.parkSlopeNorth))
        #expect(walk > BusBikePlaces.timesSquare.distance(from: BusBikePlaces.parkSlopeNorth))
        #expect(WalkReach.meters(from: BusBikePlaces.timesSquare, to: CLLocation(latitude: 40.758, longitude: -73.986)) ?? 0 < 100)
    }

    /// Nearby's stations: at most 5, nearest by the walk, within 5 km.
    @Test func stationsNearTimesSquare() throws {
        let near = Nearby.stations(near: BusBikePlaces.timesSquare)
        try #require(near.count == 5)
        #expect(near[0].meters < 300)
        #expect(zip(near, near.dropFirst()).allSatisfy { $0.meters <= $1.meters })
        #expect(near.allSatisfy { $0.walkMinutes >= 1 })
    }

    /// The map's line zoom: kept within its hold, moved past it; nothing taken from a bad scale.
    @Test func lineScaleHold() {
        #expect(LineScale.step(10, from: 0) == 10)
        #expect(LineScale.step(12, from: 10) == 10)
        #expect(LineScale.step(15, from: 10) == 15)
        #expect(LineScale.step(4, from: 10) == 4)
        #expect(LineScale.step(.nan, from: 10) == 10)
        #expect(LineScale.step(-1, from: 10) == 10)
        #expect(LineScale.id(of: 0) == 0)
    }

    /// Nearby's bus marks by zoom, with a margin either side so they don't flicker.
    @Test func busZoomHysteresis() {
        #expect(BusZoom(metersPerPoint: 5, from: .between) == .far)
        #expect(BusZoom(metersPerPoint: 1, from: .between) == .close)
        #expect(BusZoom(metersPerPoint: 3.8, from: .far) == .far)
        #expect(BusZoom(metersPerPoint: 3.8, from: .between) == .between)
        #expect(BusZoom(metersPerPoint: 1.6, from: .close) == .close)
        #expect(BusZoom(metersPerPoint: 0, from: .close) == .close)
    }
}
