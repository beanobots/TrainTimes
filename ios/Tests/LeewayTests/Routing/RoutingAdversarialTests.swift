import CoreLocation
import Foundation
import Testing
@testable import Leeway

// MARK: - Odd places

/// Trips between places that aren't sensible ones: the same place, outside the city, nowhere.
@Suite(.enabled(if: RouteKit.stepFreeOff))
struct RoutingOddPlacesTests {
    let timetable = RouteKit.subway()
    let at = RouteKit.base.addingTimeInterval(60)

    /// From a place to itself, walking's as quick: no train.
    @Test func samePlaceIsWalkingAsQuick() {
        let here = RouteKit.near("R34N")
        let planned = TripPlanner.planned(from: here, to: here, at: at, timetable: timetable)
        #expect(planned.trips.isEmpty)
        #expect(planned.none == .walkingAsQuick)
    }

    /// From a place to itself, the server's way offers no ride either, by train or bus.
    @Test func samePlaceRidesNothing() {
        let network = TransitNetwork(subway: timetable, buses: RouteKit.buses())
        for here in [RouteKit.near("R34N"), RouteKit.near("b2")] {
            #expect(TransitPlanner.routes(on: network, from: RouteKit.point(here), to: RouteKit.point(here), departure: at,
                                          modes: [.subway, .bus]).isEmpty)
        }
    }

    /// A ride getting there no sooner than walking straight there isn't offered: one stop on the R, just missed.
    @Test func aRideSlowerThanWalkingIsLeftOut() {
        let network = TransitNetwork(subway: timetable, buses: nil)
        let start = RouteKit.point(RouteKit.near("R34N")), end = RouteKit.point(RouteKit.near("R33N"))
        // At 1 minute, the R at 4 and at 4 Av-9 St at 6: sooner than the 11-minute walk
        #expect(!TransitPlanner.routes(on: network, from: start, to: end, departure: at, modes: [.subway]).isEmpty)
        // At 5, the next at 14, there at 16: not
        #expect(TransitPlanner.routes(on: network, from: start, to: end, departure: RouteKit.base.addingTimeInterval(300),
                                      modes: [.subway]).isEmpty)
    }

    /// Out in the Atlantic, or in Newark, there's no station near: none, and why.
    @Test func outsideTheCityHasNoStation() {
        let ocean = CLLocation(latitude: 40.40, longitude: -73.70)
        let newark = CLLocation(latitude: 40.735, longitude: -74.172)
        #expect(TripPlanner.planned(from: ocean, to: RouteKit.near("R30N"), at: at, timetable: timetable).none
            == .noStation(at: .start))
        #expect(TripPlanner.planned(from: RouteKit.near("R34N"), to: newark, at: at, timetable: timetable).none
            == .noStation(at: .end))
        #expect(TripPlanner.planned(from: ocean, to: newark, at: at, timetable: timetable).none == .noStation(at: .both))
        let network = TransitNetwork(subway: timetable, buses: RouteKit.buses())
        #expect(TransitPlanner.routes(on: network, from: RouteKit.point(ocean), to: RouteKit.point(RouteKit.near("R30N")),
                                      departure: at, modes: [.subway, .bus]).isEmpty)
    }

    /// A pole (as a shared link's "90,0" can say) or a place that isn't one plans nothing, rather than counting cells for ever or crashing.
    @Test func aPoleOrNowherePlansNothing() {
        let network = TransitNetwork(subway: timetable, buses: nil)
        let end = RouteKit.point(RouteKit.near("R30N"))
        for start in [(90.0, 0.0), (-90.0, 180.0), (Double.nan, -73.99), (40.66, Double.infinity)] {
            #expect(network.stops(near: start, within: TransitPlanner.longWalkRange).isEmpty)
            #expect(TransitPlanner.routes(on: network, from: start, to: end, departure: at, modes: [.subway]).isEmpty)
        }
    }

    /// Stops a route has at (0, 0), or none at all, match no station and are left out.
    @Test func routesWithNoPlacesAreLeftOut() {
        let nowhere = ServerRoutes.Route.Stop(name: "", latitude: 0, longitude: 0)
        let lost = ServerRoutes.Route(legs: [ServerRoutes.Route.Leg(line: "R", from: nowhere, to: nowhere)])
        let empty = ServerRoutes.Route(legs: [])
        #expect(ServerRoutes.trips(from: [lost, empty]).isEmpty)
        #expect(ServerRoutes.busTrip(from: empty) == nil)
        #expect(!empty.walks(within: 1200, from: RouteKit.near("R34N"), to: RouteKit.near("R30N")))
        #expect(empty.trimmed(within: 1200, of: RouteKit.near("R30N")) == empty)
    }

    /// A ride boarded and left in the same station, or on a line that doesn't stop there, isn't a trip.
    @Test func ridesThatGoNowhereAreLeftOut() {
        let still = ServerRoutes.Route(legs: [RouteKit.leg("R", from: "R31N", to: "D24N")])
        let wrongLine = ServerRoutes.Route(legs: [RouteKit.leg("7", from: "R34N", to: "R30N")])
        let unknown = ServerRoutes.Route(legs: [RouteKit.leg("ZZ", from: "R34N", to: "R30N")])
        #expect(ServerRoutes.trips(from: [still, wrongLine, unknown]).isEmpty)
    }

    /// From Prospect Av to itself, the way finder offers no way straight there; from a place it doesn't know, nothing.
    @Test func wayFinderSamePlaceAndNowhere() {
        let finder = WayFinder(timetable: WayFinderTests.timetable())
        let same = finder.ways(from: "30", to: "30")
        #expect(!(same.listed + same.more).contains { $0.changes.isEmpty })
        let nowhere = finder.ways(from: "nowhere", to: "26")
        #expect(nowhere.listed.isEmpty && nowhere.more.isEmpty)
        #expect(finder.reachable(from: "nowhere").isEmpty)
    }
}

// MARK: - Odd times

/// Trips at times with no trains, past midnight, and over the clocks changing.
@Suite(.enabled(if: RouteKit.stepFreeOff))
struct RoutingOddTimesTests {
    /// The R from 5 am to midnight: at 3 am there's no train, on the phone or the server's way.
    @Test func noServiceAtThreeInTheMorning() {
        let day = RouteKit.subway(rStarts: RouteKit.every(600, from: 5 * 3600, through: 24 * 3600),
                                  qStarts: RouteKit.every(600, from: 5 * 3600, through: 24 * 3600))
        let three = Fixtures.date("2035-06-05 03:00")
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        #expect(TripPlanner.planned(from: start, to: end, at: three, timetable: day).none == .noTrain)
        #expect(TransitPlanner.routes(on: TransitNetwork(subway: day, buses: nil), from: RouteKit.point(start),
                                      to: RouteKit.point(end), departure: three, modes: [.subway]).isEmpty)
    }

    /// A service day's train after midnight, counted from the day before's start, is caught the next morning.
    @Test func aServiceDayRunsPastMidnight() throws {
        let late = RouteKit.subway(rStarts: [25 * 3600 + 1800], qStarts: [])
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        let at = Fixtures.date("2035-06-05 01:30")
        let leg = try #require(TransitPlanner.routes(on: TransitNetwork(subway: late, buses: nil), from: RouteKit.point(start),
                                                     to: RouteKit.point(end), departure: at, modes: [.subway]).first?.legs.first)
        #expect(leg.leaves == RouteKit.seconds(Fixtures.date("2035-06-05 01:34")))
        let trip = try #require(TripPlanner.plan(from: start, to: end, at: at, timetable: late).first)
        let arrival = try #require(TripPlanner.arrival(of: trip, from: start, to: end, at: at, timetable: late))
        let walkOff = TripPlanner.walkSeconds(end.distance(from: trip.destination.location))
        #expect(abs(arrival.timeIntervalSince(Fixtures.date("2035-06-05 01:42")) - walkOff) < 0.5)
    }

    /// On the days the clocks go back and forward, the 8:04 is the 8:04, not an hour off, on the phone and the server's way.
    @Test(arguments: ["2026-11-01", "2027-03-14"]) func clocksChangingKeepTrainsOnTime(day: String) throws {
        let base = Fixtures.date("\(day) 00:00")
        let all = RouteKit.every(600, through: 26 * 3600)
        let timetable = RouteKit.subway(base: base, rStarts: all, qStarts: all)
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        let at = Fixtures.date("\(day) 08:00")
        let leg = try #require(TransitPlanner.routes(on: TransitNetwork(subway: timetable, buses: nil), from: RouteKit.point(start),
                                                     to: RouteKit.point(end), departure: at, modes: [.subway]).first?.legs.first)
        #expect(leg.leaves == RouteKit.seconds(Fixtures.date("\(day) 08:04")))
        let trip = try #require(TripPlanner.plan(from: start, to: end, at: at, timetable: timetable).first)
        let arrival = try #require(TripPlanner.arrival(of: trip, from: start, to: end, at: at, timetable: timetable))
        let walkOff = TripPlanner.walkSeconds(end.distance(from: trip.destination.location))
        #expect(abs(arrival.timeIntervalSince(Fixtures.date("\(day) 08:12")) - walkOff) < 0.5)
    }

    /// Saturday night is timed on the night the clocks go forward, though 2:30 never comes.
    @Test func wayFinderTimesTheNightTheClocksGoForward() throws {
        // Saturday 2035-03-10; the clocks go forward early on Sunday the 11th
        let base = Fixtures.date("2035-03-10 00:00")
        let all = RouteKit.every(600, through: 3 * 86400 - 600)
        let way = try #require(WayFinderTests.rWay(WayFinder(timetable: RouteKit.subway(base: base, rStarts: all, qStarts: all))))
        #expect(way.minutes[WayFinder.Part(day: .saturday, time: .night)] == 8)
        #expect(way.minutes[WayFinder.Part(day: .sunday, time: .day)] == 8)
    }

    /// Half an hour is the longest wait for a first train, on the phone and the server's way alike.
    @Test func waitsAtMostHalfAnHour() {
        #expect(TransitPlanner.maxWait == 30 * 60)
        #expect(TripPlanner.longestWait == TimeInterval(TransitPlanner.maxWait))
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        let at = RouteKit.base.addingTimeInterval(60)
        // At Prospect Av at about 1:40; its only R, straight to DeKalb Av, leaving at 29 minutes, or at 32
        for (leaves, offered) in [(29 * 60, true), (32 * 60, false)] {
            let timetable = Timetable(made: RouteKit.base, base: RouteKit.base, stops: ["R34N", "R30N"], routes: ["R"],
                                      patterns: [Timetable.Pattern(route: 0, calls: [RouteKit.call(0, 0), RouteKit.call(1, 480)])],
                                      starts: [[UInt32(leaves)]])
            let server = TransitPlanner.routes(on: TransitNetwork(subway: timetable, buses: nil), from: RouteKit.point(start),
                                               to: RouteKit.point(end), departure: at, modes: [.subway])
            let phone = TripPlanner.plan(from: start, to: end, at: at, timetable: timetable)
            #expect(server.isEmpty == !offered)
            #expect(phone.isEmpty == !offered)
        }
    }

    /// A day before the timetable starts, nothing's within the wait: no trip, not one a day later.
    @Test func beforeTheTimetableStarts() {
        let timetable = RouteKit.subway()
        let early = RouteKit.base.addingTimeInterval(-86400)
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        #expect(!timetable.covers(early))
        #expect(TripPlanner.planned(from: start, to: end, at: early, timetable: timetable).none == .noTrain)
        #expect(TransitPlanner.routes(on: TransitNetwork(subway: timetable, buses: nil), from: RouteKit.point(start),
                                      to: RouteKit.point(end), departure: early, modes: [.subway]).isEmpty)
    }
}

// MARK: - Odd timetables

/// Timetables with nothing in them, or that don't read.
@Suite(.enabled(if: RouteKit.stepFreeOff))
struct RoutingOddTimetablesTests {
    static let empty = Timetable(made: RouteKit.base, base: RouteKit.base, stops: [], routes: [], patterns: [], starts: [])

    /// An empty timetable covers no time and plans nothing anywhere, without crashing.
    @Test func anEmptyTimetablePlansNothing() {
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        #expect(!Self.empty.covers(RouteKit.base))
        let network = TransitNetwork(subway: Self.empty, buses: Self.empty)
        #expect(network.stops.isEmpty && network.patterns.isEmpty)
        #expect(TransitPlanner.routes(on: network, from: RouteKit.point(start), to: RouteKit.point(end),
                                      departure: RouteKit.base, modes: [.subway, .bus]).isEmpty)
        #expect(TripPlanner.planned(from: start, to: end, at: RouteKit.base, timetable: Self.empty).none == .noTrain)
        let ways = WayFinder(timetable: Self.empty).ways(from: "30", to: "26")
        #expect(!(ways.listed + ways.more).contains { $0.rides == [["R"]] })
    }

    /// A pattern with no trips isn't in the network.
    @Test func patternsWithoutTripsAreLeftOut() {
        let network = TransitNetwork(subway: RouteKit.subway(rStarts: [], qStarts: RouteKit.every()), buses: nil)
        #expect(network.patterns.count == 1)
        #expect(network.lines.map(\.name) == ["Q"])
    }

    /// Stops the timetable has but stations.json doesn't place are ridden through, never boarded.
    @Test func unplacedStopsAreNeverBoarded() {
        let timetable = Timetable(made: RouteKit.base, base: RouteKit.base, stops: ["XX1N", "R30N"], routes: ["R"],
                                  patterns: [Timetable.Pattern(route: 0, calls: [RouteKit.call(0, 0), RouteKit.call(1, 300)])],
                                  starts: [RouteKit.every()])
        let network = TransitNetwork(subway: timetable, buses: nil)
        #expect(network.stops.first?.isPlaced == false)
        #expect(network.stops(near: (0, 0), within: 1200).isEmpty)
    }

    /// A timetable reads back as written; garbage, another file or one cut short throws rather than reading wrong.
    @Test func timetableFilesReadOrThrow() throws {
        let written = RouteKit.subway()
        let data = try written.encoded()
        let read = try Timetable(data: data)
        #expect(read.stops == written.stops && read.routes == written.routes && read.starts == written.starts)
        #expect(read.patterns == written.patterns)
        #expect(throws: Timetable.Problem.self) { try Timetable(data: Data("not a timetable".utf8)) }
        let other = try (Data("JSON{}".utf8) as NSData).compressed(using: .zlib) as Data
        #expect(throws: Timetable.Problem.self) { try Timetable(data: other) }
        let raw = try (data as NSData).decompressed(using: .zlib) as Data
        let short = try (raw.prefix(raw.count / 2) as NSData).compressed(using: .zlib) as Data
        #expect(throws: Timetable.Problem.self) { try Timetable(data: short) }
    }
}

// MARK: - Odd answers from the server

/// The server's `/routes` answering badly, slowly or not at all.
struct RoutingServerTroubleTests {
    static let later = RouteKit.base

    static func fetch(_ answer: TestNetwork.Answer?) async -> (routes: [ServerRoutes.Route]?, overLimit: Bool) {
        await withNetwork({ _ in answer }) {
            await ServerRoutes.fetchRoutes(from: RouteKit.near("R34N"), to: RouteKit.near("R30N"), at: Self.later)
        }.result
    }

    /// Routes missing what's needed don't read; extra fields, missing optional ones and none at all do.
    @Test func malformedRoutesDontRead() throws {
        let decode = { (json: String) in try JSONDecoder().decode(RouteKit.Body.self, from: Data(json.utf8)) }
        let stop = #"{"name": "a", "latitude": 40.66, "longitude": -73.99}"#
        #expect(throws: DecodingError.self) { try decode(#"{"routes": [{}]}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"routes": [{"legs": [{"line": "R", "to": \#(stop)}]}]}"#) }
        #expect(throws: DecodingError.self) {
            try decode(#"{"routes": [{"legs": [{"line": "R", "from": {"name": "a", "latitude": "40.66", "longitude": -73.99}, "to": \#(stop)}]}]}"#)
        }
        #expect(throws: DecodingError.self) { try decode(#"{"routes": null}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"legs": []}"#) }
        #expect(try decode(#"{"routes": []}"#).routes.isEmpty)
        let extra = try decode(#"{"routes": [{"legs": [{"line": "R", "from": \#(stop), "to": \#(stop), "fare": 2.9, "mode": "ferry"}], "score": 1}], "v": 9}"#)
        #expect(extra.routes.first?.legs.first?.isBus == false)
    }

    /// A 500, a 429, an unreadable 200, HTML or no signal: no routes; only the 429 says it's over the limit.
    @Test func troubleIsNoRoutes() async {
        let five = await Self.fetch(.status(500))
        #expect(five.routes == nil && !five.overLimit)
        let limit = await Self.fetch(.status(429))
        #expect(limit.routes == nil && limit.overLimit)
        let unreadable = await Self.fetch(.ok(Data(#"{"routes": [{"legs": "#.utf8)))
        #expect(unreadable.routes == nil && !unreadable.overLimit)
        let html = await Self.fetch(.ok(Data("<html>Bad Gateway</html>".utf8)))
        #expect(html.routes == nil)
        let offline = await Self.fetch(nil)
        #expect(offline.routes == nil && !offline.overLimit)
        let empty = await Self.fetch(.ok(Data(#"{"routes": []}"#.utf8)))
        #expect(empty.routes == [])
    }

    /// Thousands of routes read and match without trouble.
    @Test func aHugeAnswerReads() async throws {
        let leg = #"{"line": "R", "mode": "subway", "from": {"name": "Prospect Av", "latitude": 40.665414, "longitude": -73.992872}, "to": {"name": "DeKalb Av", "latitude": 40.690635, "longitude": -73.981824}, "seconds": 480}"#
        let body = #"{"routes": ["# + Array(repeating: #"{"legs": [\#(leg)]}"#, count: 2000).joined(separator: ",") + "]}"
        let fetched = await Self.fetch(.ok(Data(body.utf8)))
        let routes = try #require(fetched.routes)
        #expect(routes.count == 2000)
        let trips = ServerRoutes.trips(from: Array(routes.prefix(200)))
        #expect(trips.count == 200)
        #expect(Set(trips.map(\.selection.trainID)).count == 1)
    }

    /// With the server down, the phone's own planner still offers its trips.
    @Test(.enabled(if: RouteKit.stepFreeOff)) func serverDownFallsBackToThePhone() async {
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        let fetched = await Self.fetch(.status(503))
        #expect(fetched.routes == nil)
        let planned = ServerRoutes.planned(fetched.routes ?? [], from: start, to: end, at: Self.later)
        #expect(!planned.trips.isEmpty)
        #expect(planned.none == nil)
        #expect(planned.trips.contains { $0.selection.stationID == "R34" && $0.selection.routes.contains("R") })
    }

    /// A plan cancelled while the server's slow gives up at once, with no routes.
    @Test func cancelledWhileWaitingGivesUp() async {
        let slow = TestNetwork.Answer(body: Data(#"{"routes": []}"#.utf8), delay: .seconds(20))
        let (result, _) = await withNetwork({ _ in slow }) {
            let clock = ContinuousClock()
            let started = clock.now
            let task = Task {
                await ServerRoutes.fetchRoutes(from: RouteKit.near("R34N"), to: RouteKit.near("R30N"), at: Self.later)
            }
            try? await Task.sleep(for: .milliseconds(300))
            task.cancel()
            let fetched = await task.value
            return (fetched.routes, clock.now - started)
        }
        #expect(result.0 == nil)
        #expect(result.1 < .seconds(6))
    }
}

// MARK: - Odd saves

/// Planned trips and Transit Directions' screens as older or later versions saved them.
struct RoutingOddSavesTests {
    /// A planned trip with no ways follows nothing, and its board is empty.
    @Test func aTripWithNoWaysFollowsNothing() {
        let trip = PlannedTrip(ways: [])
        let now = Fixtures.date("2026-11-10 10:00")
        let times = PlannedTrips.Times(trains: [RouteKit.train("R", at: "R34N", now.addingTimeInterval(60), trip: "r1")], buses: [:])
        #expect(trip.start == nil)
        #expect(PlannedTrips.firsts(trip, times: times, now: now).isEmpty)
        #expect(PlannedTrips.connections(trip, times: times, now: now).isEmpty)
        #expect(PlannedTrips.board(trip, times: times, now: now).trains.isEmpty)
        // A way with an empty ride, and a fallback with none
        var odd = PlannedTrip(ways: [PlannedWay(rides: [[]])])
        odd.fallback = PlannedTrip.Fallback(ways: [], when: "", takes: "")
        #expect(PlannedTrips.board(odd, times: times, now: now).fallbackNote == nil)
    }

    /// A ride saved before walks and bus minutes reads with none; unreadable bus minutes are dropped, not the ride.
    @Test func olderRidesStillRead() throws {
        let ride = try JSONDecoder().decode(PlannedRide.self, from: Data(#"""
        {"train": {"stationID": "R34", "routes": ["R"], "direction": "N"}, "busMinutes": "soon"}
        """#.utf8))
        #expect(ride.walkMinutes == 0)
        #expect(ride.busMinutes == nil)
        #expect(ride.train?.stationID == "R34")
        let way = try JSONDecoder().decode(PlannedWay.self, from: Data(#"{"rides": []}"#.utf8))
        #expect(way.endWalk == 0 && way.endStop == nil)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PlannedWay.self, from: Data("{}".utf8)) }
    }

    /// A screen from a later version, or a save missing everything, is the buttons; an unreadable bus pick is dropped.
    @Test func unknownScreensAreTheButtons() throws {
        let later = try JSONDecoder().decode(QuickTrip.self, from: Data(#"{"screen": "teleport", "nearbyRoute": "R"}"#.utf8))
        #expect(later.screen == .home)
        #expect(later.nearbyRoute == "R")
        let bare = try JSONDecoder().decode(QuickTrip.self, from: Data("{}".utf8))
        #expect(bare.screen == .home && bare.touched == .distantPast)
        let odd = try JSONDecoder().decode(QuickTrip.self, from: Data(#"{"screen": "nearbyBus", "nearbyBus": 7}"#.utf8))
        #expect(odd.screen == .nearbyBus && odd.nearbyBus == nil)
    }
}
