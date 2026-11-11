import CoreLocation
import Foundation
import Testing
@testable import Leeway

/// Made-up timetables on real stations (stations.json), and places near them, for the routing
/// tests. The timetables start in 2035, past any the phone has downloaded, so `TimetableStore`
/// has none for them and nothing on disk changes a plan; and `WayFinder`, which times from the
/// later of its timetable's start and now, times from the start whatever the clock says.
enum RouteKit {
    /// Monday 2035-06-04, midnight in New York.
    static let base = Fixtures.date("2035-06-04 00:00")

    static func call(_ stop: UInt16, _ at: UInt16, waits: UInt8 = 0) -> Timetable.Call {
        Timetable.Call(stop: stop, arrives: at, waits: waits)
    }

    /// Every `every` seconds from `from` through `through`.
    static func every(_ every: Int = 600, from: Int = 0, through: Int = 6 * 3600) -> [UInt32] {
        stride(from: from, through: through, by: every).map(UInt32.init)
    }

    /// The stops `subway` calls at, by index.
    static let subwayStops = ["R36N", "R35N", "R34N", "R33N", "R32N", "R31N", "R30N", "D24N", "Q01N", "R23N"]

    /// The R north from 36 St to DeKalb Av, 2 minutes a stop (with `rToCanal`, on to Canal St at
    /// 25 minutes), and the Q from Atlantic Av through DeKalb Av (2½ minutes in) to Canal St (10),
    /// each every 10 minutes for six hours unless given.
    static func subway(base: Date = base, rStarts: [UInt32]? = nil, qStarts: [UInt32]? = nil,
                       rToCanal: Bool = false) -> Timetable {
        var rCalls = [call(0, 0), call(1, 120), call(2, 240), call(3, 360), call(4, 480), call(5, 600), call(6, 720)]
        if rToCanal { rCalls.append(call(9, 1500)) }
        let r = Timetable.Pattern(route: 0, calls: rCalls)
        let q = Timetable.Pattern(route: 1, calls: [call(7, 0), call(6, 150), call(8, 600)])
        return Timetable(made: base, base: base, stops: subwayStops, routes: ["R", "Q"], patterns: [r, q],
                         starts: [rStarts ?? every(), qStarts ?? every()])
    }

    /// Bus stops up 5 Av in Park Slope, and on toward Downtown Brooklyn (as the server's tests).
    static let busStops: [(String, Double, Double)] = [
        ("b0", 40.6650, -73.9850), ("b1", 40.6700, -73.9820), ("b2", 40.6750, -73.9790),
        ("b2x", 40.6752, -73.9788), ("b3", 40.6900, -73.9750),
    ]

    /// The B63 up 5 Av (b0 to b2) and the B67 on from beside b2 to b3, every 8 minutes.
    static func buses(base: Date = base) -> Timetable {
        let patterns = [
            Timetable.Pattern(route: 0, calls: [call(0, 0), call(1, 240), call(2, 480)]),
            Timetable.Pattern(route: 1, calls: [call(3, 0), call(4, 600)]),
        ]
        return Timetable(made: base, base: base, stops: busStops.map(\.0), routes: ["B63\tCOBBLE HILL", "B67\tDOWNTOWN"],
                         patterns: patterns, starts: [every(480), every(480)],
                         places: busStops.map { Timetable.Place(latitude: $0.1, longitude: $0.2, name: $0.0.uppercased()) })
    }

    /// Where feed stop `stop` ("R34N") is.
    static func spot(_ stop: String) -> CLLocation {
        if let bus = busStops.first(where: { $0.0 == stop }) { return CLLocation(latitude: bus.1, longitude: bus.2) }
        let platform = StationDirectory.platform(forStop: stop)!
        return CLLocation(latitude: platform.lat, longitude: platform.lon)
    }

    /// A little north of `stop`, about 45 m, as a start or end would be.
    static func near(_ stop: String) -> CLLocation {
        let at = spot(stop).coordinate
        return CLLocation(latitude: at.latitude + 0.0004, longitude: at.longitude)
    }

    static func point(_ location: CLLocation) -> (Double, Double) {
        (location.coordinate.latitude, location.coordinate.longitude)
    }

    static func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded()) }

    /// The stop of `ride`'s `call`th call.
    static func stop(_ ride: TransitPlanner.Journey.Ride, _ call: Int32, on network: TransitNetwork) -> TransitNetwork.Stop {
        let pattern = network.patterns[Int(ride.pattern)]
        return network.stops[Int(network.callStops[Int(pattern.firstCall) + Int(call)])]
    }

    /// What `TransitPlanner.cost` counts for a journey's walks at its ends.
    static func walkPart(_ journey: TransitPlanner.Journey, on network: TransitNetwork, from: (Double, Double),
                         to: (Double, Double)) -> Int {
        guard let first = journey.rides.first, let last = journey.rides.last else { return 0 }
        let board = stop(first, first.board, on: network), alight = stop(last, last.alight, on: network)
        let walked = TransitNetwork.walkSeconds(TransitNetwork.meters(from, (board.latitude, board.longitude)))
            + TransitNetwork.walkSeconds(TransitNetwork.meters((alight.latitude, alight.longitude), to))
        return Int((Double(walked) * TransitPlanner.walkWeight).rounded())
    }

    /// A train as the feeds have it.
    static func train(_ route: String, at stop: String, _ time: Date, trip: String, last: String = "R01N") -> Arrival {
        Arrival(route: route, time: time, stop: stop, lastStop: last, isLive: true, trip: trip)
    }

    /// The server's `GET /routes` answer, as `ServerRoutes.fetchRoutes` reads it.
    struct Body: Decodable { var routes: [ServerRoutes.Route] }

    static func leg(_ line: String, from: String, to: String, mode: String? = nil, seconds: Int? = nil,
                    leaves: Int? = nil) -> ServerRoutes.Route.Leg {
        let stop = { (id: String) in
            let at = spot(id).coordinate
            return ServerRoutes.Route.Stop(name: id, latitude: at.latitude, longitude: at.longitude)
        }
        return ServerRoutes.Route.Leg(line: line, from: stop(from), to: stop(to), mode: mode, seconds: seconds, leaves: leaves)
    }

    /// Whether step-free mode is off, as the planners keep to it (`SharedStore.loadSettings`).
    static var stepFreeOff: Bool { !SharedStore.loadSettings().stepFree }
}

// MARK: - Ranking, shared with the server

/// How trips are ranked by convenience, which the phone's planners and the server's share.
struct RankingTests {
    /// A change across the platform counts a minute, one on foot seven, and a fifth more walking 0.15 a second, alike on the phone and the server.
    @Test func rankingCostsAreTheSameEverywhere() {
        #expect(TransitPlanner.acrossChangeCost == 60)
        #expect(TransitPlanner.walkingChangeCost == 7 * 60)
        #expect(TransitPlanner.walkWeight == 0.15)
        #expect(TripPlanner.changeCost(across: true) == TimeInterval(TransitPlanner.acrossChangeCost))
        #expect(TripPlanner.changeCost(across: false) == TimeInterval(TransitPlanner.walkingChangeCost))
        #expect(TripPlanner.walkWeight == TransitPlanner.walkWeight)
    }

    /// Walks are 80 m a minute plus a fifth for indirect streets, the network's rounded to the second.
    @Test func walksAreTimedAlike() {
        #expect(TripPlanner.walkSeconds(800) == 720)
        for meters in [0.0, 37, 400, 1234.5, 2400] {
            #expect(TransitNetwork.walkSeconds(meters) == Int(TripPlanner.walkSeconds(meters).rounded()))
        }
        #expect(TripPlanner.walkMinutes(0) == 1)
        #expect(TripPlanner.walkMinutes(800) == 12)
    }

    /// A one-ride trip costs when it gets there plus 0.15 of its walks at the ends; waiting longer for the same train costs nothing.
    @Test func costCountsTheWalksNotTheWait() throws {
        let network = TransitNetwork(subway: RouteKit.subway(), buses: nil)
        let from = RouteKit.point(RouteKit.near("R34N")), to = RouteKit.point(RouteKit.near("R30N"))
        let leaving = RouteKit.seconds(RouteKit.base) + 60
        let journey = try #require(TransitPlanner.journeys(on: network, from: from, to: to, leaving: leaving,
                                                           modes: [.subway]).first { $0.rides.count == 1 })
        let cost = TransitPlanner.cost(of: journey, on: network, from: from, to: to)
        #expect(cost == journey.arrival + RouteKit.walkPart(journey, on: network, from: from, to: to))
        // Three minutes sooner at the door, the same train: the same cost
        let sooner = try #require(TransitPlanner.journeys(on: network, from: from, to: to, leaving: leaving - 180,
                                                          modes: [.subway]).first { $0.rides.count == 1 })
        #expect(sooner.rides == journey.rides)
        #expect(TransitPlanner.cost(of: sooner, on: network, from: from, to: to) == cost)
    }

    /// Changing at one platform costs a minute on top; between buses at stops apart, seven.
    @Test func changesCostByHowTheyreMade() throws {
        let subway = TransitNetwork(subway: RouteKit.subway(), buses: nil)
        let from = RouteKit.point(RouteKit.near("R34N")), to = RouteKit.point(RouteKit.near("Q01N"))
        let leaving = RouteKit.seconds(RouteKit.base) + 60
        let change = try #require(TransitPlanner.journeys(on: subway, from: from, to: to, leaving: leaving,
                                                          modes: [.subway]).first { $0.rides.count == 2 })
        let off = RouteKit.stop(change.rides[0], change.rides[0].alight, on: subway)
        let on = RouteKit.stop(change.rides[1], change.rides[1].board, on: subway)
        let across = Change.isAcross(off: "R", at: try #require(off.feedID), on: "Q", at: try #require(on.feedID))
        #expect(TransitPlanner.cost(of: change, on: subway, from: from, to: to)
            == change.arrival + (across ? 60 : 420) + RouteKit.walkPart(change, on: subway, from: from, to: to))

        let buses = TransitNetwork(subway: nil, buses: RouteKit.buses())
        let start = RouteKit.point(RouteKit.near("b0")), end = RouteKit.point(RouteKit.near("b3"))
        let twoBuses = try #require(TransitPlanner.journeys(on: buses, from: start, to: end, leaving: leaving,
                                                            modes: [.bus]).first { $0.rides.count == 2 })
        #expect(TransitPlanner.cost(of: twoBuses, on: buses, from: start, to: end)
            == twoBuses.arrival + 420 + RouteKit.walkPart(twoBuses, on: buses, from: start, to: end))
    }

    /// The R to DeKalb Av, across the platform to the Q, ranks before staying on the slower R to Canal St, on the phone as on the server.
    @Test(.enabled(if: RouteKit.stepFreeOff)) func phoneAndServerRankAlike() throws {
        let timetable = RouteKit.subway(rToCanal: true)
        // The Q calls at the R's platform at DeKalb Av, on the same side (the server's tests say so too)
        try #require(Change.isAcross(off: "R", at: "R30N", on: "Q", at: "R30N"))
        let start = RouteKit.near("R34N"), end = RouteKit.near("Q01N")
        let at = RouteKit.base.addingTimeInterval(60)
        let phone = TripPlanner.plan(from: start, to: end, at: at, timetable: timetable)
        let server = TransitPlanner.routes(on: TransitNetwork(subway: timetable, buses: nil), from: RouteKit.point(start),
                                           to: RouteKit.point(end), departure: at, modes: [.subway])
        let first = try #require(phone.first)
        #expect(first.selection.routes == ["R"])
        #expect(first.change?.allRoutes.contains("Q") == true)
        #expect(server.first?.legs.map(\.line) == ["R", "Q"])
        #expect(phone.contains { $0.change == nil && $0.selection.routes == ["R"] })
        #expect(server.contains { $0.legs.map(\.line) == ["R"] })
    }

    /// The phone and the server catch the same train and get there within seconds of each other.
    @Test(.enabled(if: RouteKit.stepFreeOff)) func phoneAndServerTimeTheSameTrain() throws {
        let timetable = RouteKit.subway()
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        let at = RouteKit.base.addingTimeInterval(60)
        let trip = try #require(TripPlanner.plan(from: start, to: end, at: at, timetable: timetable).first)
        let phone = try #require(TripPlanner.arrival(of: trip, from: start, to: end, at: at, timetable: timetable))
        let route = try #require(TransitPlanner.routes(on: TransitNetwork(subway: timetable, buses: nil),
                                                       from: RouteKit.point(start), to: RouteKit.point(end),
                                                       departure: at, modes: [.subway]).first)
        let leg = try #require(route.legs.first)
        let off = (leg.to.latitude, leg.to.longitude)
        let server = try #require(leg.leaves) + (leg.seconds ?? 0)
            + TransitNetwork.walkSeconds(TransitNetwork.meters(off, RouteKit.point(end)))
        #expect(leg.leaves == RouteKit.seconds(RouteKit.base) + 240)
        #expect(abs(RouteKit.seconds(phone) - server) <= 3)
    }

    /// With no stop within the usual 1.2 km, it plans again walking up to 2.4 km.
    @Test func walksFurtherWhenNothingsNear() throws {
        let network = TransitNetwork(subway: RouteKit.subway(), buses: nil)
        // 1.5 km south of 36 St, the first stop in the timetable
        let start = (40.6416, -74.0035), end = RouteKit.point(RouteKit.near("R30N"))
        let leaving = RouteKit.seconds(RouteKit.base) + 60
        #expect(TransitPlanner.journeys(on: network, from: start, to: end, leaving: leaving, modes: [.subway]).isEmpty)
        let routes = TransitPlanner.routes(on: network, from: start, to: end, departure: RouteKit.base.addingTimeInterval(60),
                                           modes: [.subway])
        let first = try #require(routes.first)
        #expect(first.legs.first?.from.name == "36 St")
        #expect(routes.count <= TransitPlanner.maxRoutes)
    }

    /// A trip planned on the phone reads the same as the server's `/routes` sends it.
    @Test func phoneTripsReadAsTheServersDo() throws {
        let network = TransitNetwork(subway: RouteKit.subway(), buses: RouteKit.buses())
        let routes = TransitPlanner.routes(on: network, from: RouteKit.point(RouteKit.near("b0")),
                                           to: RouteKit.point(RouteKit.near("b3")),
                                           departure: RouteKit.base.addingTimeInterval(60), modes: [.bus, .subway])
        #expect(!routes.isEmpty)
        for route in routes {
            let read = try JSONDecoder().decode(ServerRoutes.Route.self, from: try JSONEncoder().encode(route))
            #expect(read == ServerRoutes.Route(route))
        }
        // By the B63 and B67, as well as the R from Prospect Av
        let bus = try #require(routes.first { $0.legs.allSatisfy { $0.mode == .bus } })
        let read = ServerRoutes.Route(bus)
        #expect(read.legs.allSatisfy { $0.isBus })
        #expect(read.legs.map(\.line) == ["B63", "B67"])
        #expect(read.legs.first?.headsign == "COBBLE HILL")
        #expect(read.legs.first?.busRide.from.name == "B0")
    }

    /// Changes inside a complex take the MTA's time for them; between stops apart, the walk and a minute.
    @Test func networkWalksBetweenStops() throws {
        let network = TransitNetwork(subway: RouteKit.subway(), buses: RouteKit.buses())
        let index = { (id: String) in try #require(network.stops.firstIndex { $0.feedID == id }) }
        let atlantic = try index("R31N"), bq = try index("D24N")
        let walk = try #require(network.walks[atlantic].first { $0.to == Int32(bq) })
        #expect(walk.seconds == 5 * 60)
        // b2 to b2x, 30 m apart along the street
        let b2 = try #require(network.stops.firstIndex { $0.name == "B2" })
        let b2x = try #require(network.stops.firstIndex { $0.name == "B2X" })
        let onFoot = try #require(network.walks[b2].first { $0.to == Int32(b2x) })
        let meters = TransitNetwork.meters((network.stops[b2].latitude, network.stops[b2].longitude),
                                           (network.stops[b2x].latitude, network.stops[b2x].longitude))
        #expect(Int(onFoot.seconds) == TransitNetwork.walkSeconds(meters) + TransitNetwork.changeSeconds)
    }

    /// The 6 express is the 6: one line, so no trip changes from one to the other.
    @Test func anExpressIsItsLine() {
        let timetable = Timetable(made: RouteKit.base, base: RouteKit.base, stops: ["631N", "626N", "621N"],
                                  routes: ["6", "6X"],
                                  patterns: [Timetable.Pattern(route: 0, calls: [RouteKit.call(0, 0), RouteKit.call(1, 300),
                                                                                 RouteKit.call(2, 600)]),
                                             Timetable.Pattern(route: 1, calls: [RouteKit.call(0, 0), RouteKit.call(2, 420)])],
                                  starts: [RouteKit.every(), RouteKit.every()])
        let network = TransitNetwork(subway: timetable, buses: nil)
        #expect(network.lines.map(\.name) == ["6", "6"])
        #expect(network.lineGroups[0] == network.lineGroups[1])
    }

    /// A bus's whole wait counts against it, five minutes where the timetable doesn't say.
    @Test func aBusWaitCountsInFull() {
        let now = Fixtures.date("2026-11-10 08:15")
        let start = RouteKit.near("b0"), end = RouteKit.near("b2")
        let stop = { (id: String) in
            BusRide.Place(name: id, latitude: RouteKit.spot(id).coordinate.latitude, longitude: RouteKit.spot(id).coordinate.longitude)
        }
        let atStop = now.addingTimeInterval(TripPlanner.walkSeconds(start.distance(from: RouteKit.spot("b0"))))
        var ride = BusRide(line: "B63", from: stop("b0"), to: stop("b2"), headsign: "Cobble Hill", stops: 2, seconds: 480,
                           leaves: atStop.addingTimeInterval(600))
        let walks = (TripPlanner.walkSeconds(start.distance(from: RouteKit.spot("b0")))
            + TripPlanner.walkSeconds(RouteKit.spot("b2").distance(from: end))) * TripPlanner.walkWeight
        let timed = BusTrip(bus: ride, train: nil, busFirst: true)
        #expect(abs(timed.penalty(from: start, to: end, at: now, timetable: nil) - (600 + walks)) < 0.01)
        ride.leaves = nil
        let untimed = BusTrip(bus: ride, train: nil, busFirst: true)
        #expect(abs(untimed.penalty(from: start, to: end, at: now, timetable: nil) - (BusTrip.wait + walks)) < 0.01)
    }
}

// MARK: - The phone's timed planner

/// `TripPlanner.plan(from:to:at:timetable:)`, the phone's own trips by the timetable.
@Suite(.enabled(if: RouteKit.stepFreeOff))
struct TimedPlannerTests {
    let timetable = RouteKit.subway()
    let at = RouteKit.base.addingTimeInterval(60)

    /// From beside Prospect Av to beside DeKalb Av, the R north from Prospect Av.
    @Test func plansTheRFromTheNearestStation() throws {
        let trip = try #require(TripPlanner.plan(from: RouteKit.near("R34N"), to: RouteKit.near("R30N"), at: at,
                                                 timetable: timetable).first)
        #expect(trip.selection.stationID == "R34")
        #expect(trip.selection.routes == ["R"])
        #expect(trip.selection.direction == .north)
        #expect(trip.change == nil)
        #expect(trip.destination.id == "R30")
    }

    /// It gets there when the timetable's train does, plus the walk on from the station.
    @Test func arrivalIsTheTrainsAndTheWalkOff() throws {
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        let trip = try #require(TripPlanner.plan(from: start, to: end, at: at, timetable: timetable).first)
        let arrival = try #require(TripPlanner.arrival(of: trip, from: start, to: end, at: at, timetable: timetable))
        let walkOff = TripPlanner.walkSeconds(end.distance(from: trip.destination.location))
        #expect(abs(arrival.timeIntervalSince(RouteKit.base) - (720 + walkOff)) < 0.5)
    }

    /// A direct train's penalty is 0.15 of its walks at the ends, however long the wait for it.
    @Test func penaltyIsTheWalksNotTheWait() throws {
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        let trip = try #require(TripPlanner.plan(from: start, to: end, at: at, timetable: timetable).first)
        let origin = try #require(trip.selection.station)
        let walks = (TripPlanner.walkSeconds(start.distance(from: origin.location))
            + TripPlanner.walkSeconds(end.distance(from: trip.destination.location))) * TripPlanner.walkWeight
        let now = try #require(TripPlanner.penalty(of: trip, from: start, to: end, at: at, timetable: timetable))
        let waiting = try #require(TripPlanner.penalty(of: trip, from: start, to: end, at: at.addingTimeInterval(-50),
                                                       timetable: timetable))
        #expect(abs(now - walks) < 0.01)
        #expect(now == waiting)
        let cost = try #require(TripPlanner.cost(of: trip, from: start, to: end, at: at, timetable: timetable))
        let arrival = try #require(TripPlanner.arrival(of: trip, from: start, to: end, at: at, timetable: timetable))
        #expect(abs(cost - (arrival.timeIntervalSince(RouteKit.base) + now)) < 0.01)
    }

    /// A change across the platform adds its minute to the penalty, on top of the walks.
    @Test func aChangeAddsItsCost() throws {
        try #require(Change.isAcross(off: "R", at: "R30N", on: "Q", at: "R30N"))
        let start = RouteKit.near("R34N"), end = RouteKit.near("Q01N")
        let trip = try #require(TripPlanner.plan(from: start, to: end, at: at, timetable: timetable).first)
        let change = try #require(trip.change)
        #expect(change.stops.contains { $0.stationID == "R30" && $0.routes.contains("Q") })
        let origin = try #require(trip.selection.station)
        let last = change.destination ?? trip.destination
        let walks = (TripPlanner.walkSeconds(start.distance(from: origin.location))
            + TripPlanner.walkSeconds(end.distance(from: last.location))) * TripPlanner.walkWeight
        let penalty = try #require(TripPlanner.penalty(of: trip, from: start, to: end, at: at, timetable: timetable))
        #expect(abs(penalty - (60 + walks)) < 0.01)
        // Off the R at 12 minutes, onto the Q leaving at 12½, at Canal St at 20
        let arrival = try #require(TripPlanner.arrival(of: trip, from: start, to: end, at: at, timetable: timetable))
        #expect(abs(arrival.timeIntervalSince(RouteKit.base) - (1200 + TripPlanner.walkSeconds(end.distance(from: last.location)))) < 0.5)
    }

    /// The same line from a station further from the start, getting there later, isn't offered too.
    @Test func dropsTheSameLineFromFurtherOn() throws {
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        let near = TripPlanner.Trip(selection: Selection(stationID: "R34", routes: ["R"], direction: .north),
                                    destination: try #require(StationDirectory.station(id: "R30")))
        var further = near
        further.selection.stationID = "R35"
        let kept = TripPlanner.withoutSlowerWalks([further, near], from: start, to: end, at: at, timetable: timetable)
        #expect(kept == [near])
    }

    /// Ends a short walk apart: walking's as quick, and it says so.
    @Test func walkingAsQuickWhenTheEndsAreClose() {
        let start = RouteKit.near("R34N")
        let end = CLLocation(latitude: start.coordinate.latitude + 0.0027, longitude: start.coordinate.longitude)
        let planned = TripPlanner.planned(from: start, to: end, at: at, timetable: timetable)
        #expect(planned.trips.isEmpty)
        #expect(planned.none == .walkingAsQuick)
    }

    /// No train for over half an hour: no train, rather than a trip leaving much later.
    @Test func noTrainWhenTheNextIsOverHalfAnHourOff() {
        let later = RouteKit.subway(rStarts: [7200], qStarts: [7200])
        let planned = TripPlanner.planned(from: RouteKit.near("R34N"), to: RouteKit.near("R30N"), at: at, timetable: later)
        #expect(planned.trips.isEmpty)
        #expect(planned.none == .noTrain)
    }
}

// MARK: - The server's routes, read

/// `ServerRoutes`: the server's `/routes` read, and matched to the app's stations and lines.
struct ServerRoutesTests {
    /// The server's routes read with every field: mode, headsign, stops, seconds and when it leaves.
    @Test func readsTheServersRoutes() throws {
        let json = """
        {"routes": [{"legs": [{"line": "B63", "mode": "bus", "headsign": "SBS COBBLE HILL", "stops": 4, "seconds": 600,
          "leaves": 2064556800, "from": {"name": "5 AV/9 ST", "latitude": 40.6705, "longitude": -73.9862},
          "to": {"name": "ATLANTIC AV/4 AV", "latitude": 40.6839, "longitude": -73.9785}}]}]}
        """
        let body = try JSONDecoder().decode(RouteKit.Body.self, from: Data(json.utf8))
        let leg = try #require(body.routes.first?.legs.first)
        #expect(leg.isBus)
        #expect(leg.duration == 600)
        let ride = leg.busRide
        #expect(ride.from.name == "5 Av & 9 St")
        #expect(ride.headsign == "Cobble Hill")
        #expect(ride.leaves == Date(timeIntervalSince1970: 2_064_556_800))
    }

    /// A leg from a server older than buses has no mode, and is a train of about 2 minutes a stop.
    @Test func anOlderServersLegIsATrain() throws {
        let json = """
        {"line": "R", "stops": 3, "from": {"name": "a", "latitude": 40.66, "longitude": -73.99},
         "to": {"name": "b", "latitude": 40.69, "longitude": -73.98}}
        """
        let leg = try JSONDecoder().decode(ServerRoutes.Route.Leg.self, from: Data(json.utf8))
        #expect(leg.mode == nil)
        #expect(!leg.isBus)
        #expect(leg.leaves == nil)
        #expect(leg.duration == 360)
        var unsaid = leg
        unsaid.stops = nil
        #expect(unsaid.duration == 600)
    }

    /// A ride is matched to the stations near its stops on its line, and the way it goes.
    @Test func matchesARideToItsStationsAndWay() throws {
        let trip = try #require(ServerRoutes.trips(from: [ServerRoutes.Route(legs: [RouteKit.leg("R", from: "R34N", to: "R30N")])]).first)
        #expect(trip.selection.stationID == "R34")
        #expect(trip.selection.routes == ["R"])
        #expect(trip.selection.direction == .north)
        #expect(trip.destination.id == "R30")
        #expect(trip.change == nil)
    }

    /// An express is its line, "S" a shuttle, "SIR" the Staten Island Railway.
    @Test func expressesAndShuttlesAreTheirLines() throws {
        let six = try #require(ServerRoutes.trips(from: [ServerRoutes.Route(legs: [RouteKit.leg("6X", from: "631N", to: "621N")])]).first)
        #expect(six.selection.routes == ["6"])
        #expect(six.selection.direction == .north)
        let shuttle = try #require(ServerRoutes.trips(from: [ServerRoutes.Route(legs: [RouteKit.leg("S", from: "902N", to: "901N")])]).first)
        #expect(shuttle.selection.routes == ["GS"])
        let sir = try #require(ServerRoutes.trips(from: [ServerRoutes.Route(legs: [RouteKit.leg("SIR", from: "S31S", to: "S09S")])]).first)
        #expect(sir.selection.routes == ["SI"])
    }

    /// Two rides are the train and its change; three can't be shown on a widget, so aren't offered.
    @Test func twoRidesAreATrainAndItsChange() throws {
        let two = ServerRoutes.Route(legs: [RouteKit.leg("R", from: "R34N", to: "R30N"), RouteKit.leg("Q", from: "R30N", to: "Q01N")])
        let trip = try #require(ServerRoutes.trips(from: [two]).first)
        #expect(trip.selection.stationID == "R34")
        #expect(trip.change?.stationID == "R30")
        #expect(trip.change?.routes == ["Q"])
        #expect(trip.destination.complex == StationDirectory.station(id: "Q01")?.complex)
        let three = ServerRoutes.Route(legs: two.legs + [RouteKit.leg("N", from: "Q01N", to: "R16N")])
        #expect(ServerRoutes.trips(from: [three]).isEmpty)
    }

    /// Routes with a bus are bus trips: alone, two buses, or a bus and a train either way round; not three rides, nor none by bus.
    @Test func busTripsTakeTheirShape() throws {
        let bus = RouteKit.leg("B63", from: "b0", to: "b2", mode: "bus")
        let onward = RouteKit.leg("B67", from: "b2x", to: "b3", mode: "bus")
        let alone = try #require(ServerRoutes.busTrip(from: ServerRoutes.Route(legs: [bus])))
        #expect(alone.train == nil && alone.onward == nil && alone.busFirst)
        let twoBuses = try #require(ServerRoutes.busTrip(from: ServerRoutes.Route(legs: [bus, onward])))
        #expect(twoBuses.onward?.line == "B67")
        let toTrain = ServerRoutes.Route(legs: [RouteKit.leg("B63", from: "b0", to: "R31N", mode: "bus"),
                                                RouteKit.leg("Q", from: "D24N", to: "Q01N")])
        let busFirst = try #require(ServerRoutes.busTrip(from: toTrain))
        #expect(busFirst.busFirst)
        // Atlantic Av-Barclays Ctr: one station of all its platforms, by its first's id ("235"), the Q's D24 among them
        #expect(busFirst.train?.selection.stationID == StationDirectory.station(id: "D24")?.id)
        #expect(busFirst.train?.selection.platforms.map(\.id) == ["D24"])
        #expect(busFirst.train?.selection.routes == ["Q"])
        let trainFirst = try #require(ServerRoutes.busTrip(from: ServerRoutes.Route(legs: [RouteKit.leg("R", from: "R34N", to: "R31N"),
                                                                                          RouteKit.leg("B67", from: "b2x", to: "b3", mode: "bus")])))
        #expect(!trainFirst.busFirst)
        #expect(ServerRoutes.busTrip(from: ServerRoutes.Route(legs: [bus, onward, bus])) == nil)
        #expect(ServerRoutes.busTrip(from: ServerRoutes.Route(legs: [RouteKit.leg("R", from: "R34N", to: "R30N")])) == nil)
    }

    /// A route is offered only if it starts and ends within the walk of either end.
    @Test func walksWithinTheRange() {
        let route = ServerRoutes.Route(legs: [RouteKit.leg("R", from: "R34N", to: "R30N")])
        #expect(route.walks(within: 100, from: RouteKit.near("R34N"), to: RouteKit.near("R30N")))
        #expect(!route.walks(within: 30, from: RouteKit.near("R34N"), to: RouteKit.near("R30N")))
        #expect(!route.walks(within: 1200, from: RouteKit.near("R34N"), to: RouteKit.near("Q01N")))
    }

    /// A second bus a walk would do is cut off: the route ends at the first bus's stop near the end.
    @Test func trimsASecondBusAWalkWouldDo() {
        let end = RouteKit.spot("b3")
        let first = RouteKit.leg("B63", from: "b0", to: "b2", mode: "bus", seconds: 480, leaves: 1_000_000)
        let second = RouteKit.leg("B67", from: "b2x", to: "b3", mode: "bus", seconds: 600, leaves: 1_000_600)
        let long = ServerRoutes.Route(legs: [first, second])
        // b2 is 1.7 km from b3: too far to walk instead
        #expect(long.trimmed(within: 1200, of: end) == long)
        // Within 2 km, walking from b2 (about 26 minutes) is slower than the B67's ride by more than a change is worth
        #expect(long.trimmed(within: 2000, of: end) == long)
        let near = CLLocation(latitude: 40.6760, longitude: -73.9785)
        #expect(long.trimmed(within: 1200, of: near).legs.count == 1)
        let trains = ServerRoutes.Route(legs: [RouteKit.leg("R", from: "R34N", to: "R30N")])
        #expect(trains.trimmed(within: 1200, of: end) == trains)
    }

    /// A trip whose lines include another's, from the same station the same way to the same end, stands for both.
    @Test func aTripWithMoreLinesCoversOneWithFewer() throws {
        let end = try #require(StationDirectory.station(id: "R36"))
        let r = TripPlanner.Trip(selection: Selection(stationID: "R31", routes: ["R"], direction: .south), destination: end)
        let dnr = TripPlanner.Trip(selection: Selection(stationID: "R31", routes: ["D", "N", "R"], direction: .south),
                                   destination: end)
        #expect(ServerRoutes.covers(dnr, r))
        #expect(!ServerRoutes.covers(r, dnr))
        #expect(ServerRoutes.covering([r, dnr]) == [dnr])
        var north = r
        north.selection.direction = .north
        #expect(!ServerRoutes.covers(dnr, north))
    }

    /// With no timetable for then, the route's train and the app's own are offered as one trip.
    @Test(.enabled(if: RouteKit.stepFreeOff)) func plannedOffersEachTrainOnce() throws {
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        let route = ServerRoutes.Route(legs: [RouteKit.leg("R", from: "R34N", to: "R30N")])
        let planned = ServerRoutes.planned([route], from: start, to: end, at: RouteKit.base)
        #expect(planned.none == nil)
        let first = try #require(planned.trips.first)
        #expect(first.selection.trainID == Selection(stationID: "R34", routes: ["R"], direction: .north).trainID)
        let ids = planned.trips.map { "\($0.selection.trainID) \($0.change.map { "\($0.stationID) \($0.routes)" } ?? "")" }
        #expect(Set(ids).count == ids.count)
        #expect(planned.trips.count <= ServerRoutes.maxOptions)
    }
}

// MARK: - Asking the server

/// `ServerRoutes.fetchRoutes` over the network, for a time no timetable on the phone covers.
struct FetchRoutesTests {
    static let later = RouteKit.base
    static let answer = Data("""
    {"routes": [{"legs": [{"line": "R", "mode": "subway", "from": {"name": "Prospect Av", "latitude": 40.665414,
      "longitude": -73.992872}, "to": {"name": "DeKalb Av", "latitude": 40.690635, "longitude": -73.981824},
      "stops": 6, "seconds": 480, "leaves": 2064556800}]}]}
    """.utf8)

    /// It asks `/routes` with the trip's ends and time, buses and no trains as asked, and nothing about who's asking.
    @Test func asksWithTheTripAndNothingPersonal() async throws {
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        let (result, made) = await withNetwork({ request in
            request.url?.path.hasSuffix("/routes") == true ? .ok(Self.answer) : nil
        }) {
            await ServerRoutes.fetchRoutes(from: start, to: end, at: Self.later, buses: true, subway: false)
        }
        #expect(result.routes?.first?.legs.first?.line == "R")
        #expect(!result.overLimit)
        let request = try #require(made.first { $0.url.path.hasSuffix("/routes") })
        #expect(request.method == "GET")
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(value("from") == String(format: "%.6f,%.6f", start.coordinate.latitude, start.coordinate.longitude))
        #expect(value("to") == String(format: "%.6f,%.6f", end.coordinate.latitude, end.coordinate.longitude))
        #expect(value("at") == String(RouteKit.seconds(Self.later)))
        #expect(value("bus") == "1")
        #expect(value("subway") == "0")
        #expect(Set(items.map(\.name)) == ["from", "to", "at", "bus", "subway"])
        #expect(request.headers["Accept"] == "application/json")
        #expect(!request.headers.values.contains { $0.contains("@") })
        #expect(request.body?.isEmpty ?? true)
    }

    /// By train only, it says neither, for servers from before buses.
    @Test func trainsOnlySaysNeitherFlag() async throws {
        let (_, made) = await withNetwork({ _ in .ok(Self.answer) }) {
            await ServerRoutes.fetchRoutes(from: RouteKit.near("R34N"), to: RouteKit.near("R30N"), at: Self.later)
        }
        let request = try #require(made.first { $0.url.path.hasSuffix("/routes") })
        let names = (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        #expect(Set(names) == ["from", "to", "at"])
    }
}

// MARK: - Planned trips, followed

/// `PlannedTrips`: a saved route's ways followed through the feeds' trains.
struct PlannedTripsTests {
    static let now = Fixtures.date("2026-11-10 10:00")
    static func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
    static let r = PlannedRide(train: Selection(stationID: "R34", routes: ["R"], direction: .north))

    /// The first train is followed to the end on its own trip.
    @Test func followsTheFirstTrainToTheEnd() throws {
        let trip = PlannedTrip(ways: [PlannedWay(rides: [[Self.r]], endStationID: "R30")], destinationID: "R30")
        let times = PlannedTrips.Times(trains: [RouteKit.train("R", at: "R34N", Self.at(2), trip: "r1"),
                                                RouteKit.train("R", at: "R30N", Self.at(10), trip: "r1")], buses: [:])
        let connections = PlannedTrips.connections(trip, times: times, now: Self.now)
        #expect(connections.count == 1)
        #expect(connections.first?.first.stop == "R34N")
        #expect(connections.first?.arrival.time == Self.at(10))
    }

    /// At a change with several places, the one whose next train gets there soonest.
    @Test func changesWhereTheNextRideGetsThereSoonest() throws {
        let dekalb = PlannedRide(train: Selection(stationID: "R30", routes: ["Q"], direction: .north))
        let atlantic = PlannedRide(train: Selection(stationID: "D24", routes: ["Q"], direction: .north), walkMinutes: 5,
                                   offStationID: "R31")
        let trip = PlannedTrip(ways: [PlannedWay(rides: [[Self.r], [atlantic, dekalb]], endStationID: "Q01")],
                               destinationID: "Q01")
        let times = PlannedTrips.Times(trains: [
            RouteKit.train("R", at: "R34N", Self.at(2), trip: "r1"),
            RouteKit.train("R", at: "R31N", Self.at(8), trip: "r1"),
            RouteKit.train("R", at: "R30N", Self.at(10), trip: "r1"),
            RouteKit.train("Q", at: "R30N", Self.at(14), trip: "q1", last: "Q05N"),
            RouteKit.train("Q", at: "D24N", Self.at(16), trip: "q2", last: "Q05N"),
            RouteKit.train("Q", at: "Q01N", Self.at(25), trip: "q1", last: "Q05N"),
            RouteKit.train("Q", at: "Q01N", Self.at(35), trip: "q2", last: "Q05N"),
        ], buses: [:])
        let connection = try #require(PlannedTrips.connections(trip, times: times, now: Self.now).first)
        #expect(connection.stationID == "R30")
        #expect(connection.next?.trip == "q1")
        #expect(connection.ways?.first?.arrival?.time == Self.at(25))
    }

    /// With no first train of its own ways coming, the fallback's are followed, and the board says why.
    @Test func takesTheFallbackWhenNothingsComing() throws {
        let other = PlannedRide(train: Selection(stationID: "R34", routes: ["R"], direction: .south))
        var trip = PlannedTrip(ways: [PlannedWay(rides: [[Self.r]], endStationID: "R30")], destinationID: "R30")
        trip.fallback = PlannedTrip.Fallback(ways: [PlannedWay(rides: [[other]], endStationID: "R36")],
                                             when: "No Manhattan-bound R trains", takes: "R to 36 St, back on the D or N")
        let times = PlannedTrips.Times(trains: [RouteKit.train("R", at: "R34S", Self.at(3), trip: "s1", last: "R45S"),
                                                RouteKit.train("R", at: "R36S", Self.at(7), trip: "s1", last: "R45S")], buses: [:])
        let followed = PlannedTrips.following(trip, times: times, now: Self.now)
        #expect(followed.fallback == trip.fallback)
        #expect(followed.trip.fallback == nil)
        let board = PlannedTrips.board(trip, times: times, now: Self.now)
        #expect(board.fallbackNote == "No Manhattan-bound R trains · R to 36 St, back on the D or N")
        #expect(board.trains.map(\.stop) == ["R34S"])
    }

    /// With the fallback's trains not coming either, the trip's own ways stay, saying nothing.
    @Test func staysWhenTheFallbacksArentComingEither() {
        let other = PlannedRide(train: Selection(stationID: "R34", routes: ["R"], direction: .south))
        var trip = PlannedTrip(ways: [PlannedWay(rides: [[Self.r]], endStationID: "R30")], destinationID: "R30")
        trip.fallback = PlannedTrip.Fallback(ways: [PlannedWay(rides: [[other]], endStationID: "R36")],
                                             when: "No Manhattan-bound R trains", takes: "R to 36 St")
        let times = PlannedTrips.Times(trains: [], buses: [:])
        #expect(PlannedTrips.following(trip, times: times, now: Self.now).fallback == nil)
        #expect(PlannedTrips.board(trip, times: times, now: Self.now).fallbackNote == nil)
    }

    /// First trains leave out those gone and those ending here.
    @Test func firstsLeaveOutTrainsGoneAndEndingHere() {
        let trip = PlannedTrip(ways: [PlannedWay(rides: [[Self.r]], endStationID: "R30")], destinationID: "R30")
        let times = PlannedTrips.Times(trains: [
            RouteKit.train("R", at: "R34N", Self.at(-1), trip: "gone"),
            RouteKit.train("R", at: "R34N", Self.at(3), trip: "ends", last: "R34N"),
            RouteKit.train("R", at: "R34N", Self.at(5), trip: "next"),
        ], buses: [:])
        #expect(PlannedTrips.firsts(trip, times: times, now: Self.now).map(\.trip) == ["next"])
    }

    /// Another line's train on a line's own platform counts as it; one at its own platform doesn't.
    @Test func aTrainOnAnotherLinesTrackCountsAsIt() {
        #expect(PlannedTrips.takes(RouteKit.train("N", at: "R34N", Self.now, trip: "n"), lines: ["R"]))
        #expect(!PlannedTrips.takes(RouteKit.train("R", at: "R30N", Self.now, trip: "r"), lines: ["Q"]))
    }

    /// Without the feeds, its trains come from the timetable.
    @Test func timesFromTheTimetable() {
        let trip = PlannedTrip(ways: [PlannedWay(rides: [[Self.r]], endStationID: "R30")], destinationID: "R30")
        let times = PlannedTrips.times(trip, from: RouteKit.subway(), now: RouteKit.base.addingTimeInterval(60))
        #expect(times.trains.contains { $0.route == "R" && $0.stop == "R34N" && $0.time == RouteKit.base.addingTimeInterval(240) })
        #expect(times.buses.isEmpty)
    }
}

// MARK: - Ways across the week

/// `WayFinder`: every way between two places across the week, for New Route.
struct WayFinderTests {
    /// Every 10 minutes of the day for nine days from Monday, or only within each day's `hours`.
    static func timetable(_ hours: ClosedRange<Int>? = nil, days: Set<Int> = Set(0..<9)) -> Timetable {
        let starts = (0..<9).filter(days.contains).flatMap { day -> [UInt32] in
            let range = hours ?? 0...23
            return RouteKit.every(600, from: day * 86400 + range.lowerBound * 3600,
                                  through: day * 86400 + range.upperBound * 3600 + (hours == nil ? 3000 : 0))
        }
        return RouteKit.subway(rStarts: starts, qStarts: starts)
    }

    static func rWay(_ finder: WayFinder) -> WayFinder.Way? {
        let found = finder.ways(from: "30", to: "26")
        return (found.listed + found.more).first { $0.rides == [["R"]] }
    }

    /// Prospect Av to DeKalb Av: the R straight there at every part of the week, 8 minutes.
    @Test func findsTheRStraightThereAllWeek() throws {
        let way = try #require(Self.rWay(WayFinder(timetable: Self.timetable())))
        #expect(way.start.stationID == "R34")
        #expect(way.start.direction == .north)
        #expect(way.changes.isEmpty)
        #expect(Set(way.minutes.keys) == Set(WayFinder.Part.allCases))
        #expect(way.when == "All times")
        #expect(way.minutesLabel == "8 min")
        #expect(way.changesLabel == "Straight there")
        #expect(way.localTrackLabel == nil)
    }

    /// Trains only at weekday rush hours run "Weekdays".
    @Test func rushHourOnlyRunsWeekdays() throws {
        let way = try #require(Self.rWay(WayFinder(timetable: Self.timetable(7...9, days: [0, 1, 2, 3, 4]))))
        #expect(way.minutes.keys.allSatisfy { $0.day == .weekday && $0.time == .rush })
        #expect(way.when == "Weekdays")
        #expect(way.isLimited)
    }

    /// Trains only in the small hours run "Late nights".
    @Test func smallHoursOnlyRunLateNights() throws {
        let way = try #require(Self.rWay(WayFinder(timetable: Self.timetable(1...4))))
        #expect(Set(way.minutes.keys) == Set(WayFinder.Part.allCases.filter { $0.time == .night }))
        #expect(way.when == "Late nights")
        #expect(way.whenSymbol == "moon.stars")
    }

    /// An N on the R's local stops counts as the R there, "and trains running on the local track".
    @Test func localTrackTrainsCountAsTheLocal() throws {
        let n = Timetable.Pattern(route: 0, calls: [RouteKit.call(0, 0), RouteKit.call(1, 120), RouteKit.call(2, 240),
                                                    RouteKit.call(3, 360), RouteKit.call(4, 480), RouteKit.call(5, 600)])
        let timetable = Timetable(made: RouteKit.base, base: RouteKit.base, stops: RouteKit.subwayStops, routes: ["N"],
                                  patterns: [n], starts: [RouteKit.every(600, through: 9 * 86400)])
        // 25 St to Union St
        let found = WayFinder(timetable: timetable).ways(from: "31", to: "28")
        let way = try #require((found.listed + found.more).first { $0.rides == [["R"]] })
        #expect(way.localTrack == [0])
        #expect(way.localTrackLabel == "R and trains running on the local track")
        #expect(way.minutes.values.min() == 6)
    }

    /// From Prospect Av, the stations up the R are reachable; the start itself isn't.
    @Test func reachesOnFromTheStart() {
        let reached = WayFinder(timetable: Self.timetable()).reachable(from: "30")
        #expect(reached.isSuperset(of: ["608", "28", "617", "26"]))
        #expect(!reached.contains("30"))
    }
}

// MARK: - New Route's words

/// How New Route names parts of the week, ways and their fallbacks.
struct RouteWordsTests {
    static func way(_ minutes: [WayFinder.Part: Int], rides: [[String]] = [["R"]]) -> WayFinder.Way {
        WayFinder.Way(rides: rides, changes: [], start: .init(stationID: "R34", direction: .north),
                      end: .init(stationID: "R30", walk: 0), minutes: minutes, typical: 480)
    }

    static let all = WayFinder.Part.allCases

    /// Parts of the week, as "Not covered" follows them.
    @Test func partsOfTheWeekNamed() {
        let all = Set(Self.all)
        #expect(WayFinder.Part.named(all) == "at any time")
        #expect(WayFinder.Part.named(all.filter { $0.time == .night }) == "late nights")
        #expect(WayFinder.Part.named(all.filter { $0.day != .weekday }) == "weekends")
        #expect(WayFinder.Part.named([WayFinder.Part(day: .weekday, time: .rush)]) == "weekdays at rush hour")
        #expect(WayFinder.Part.named(all.filter { $0.day == .saturday }) == "Saturdays")
        #expect(WayFinder.Part.named([WayFinder.Part(day: .sunday, time: .day)]) == "some Sundays")
    }

    /// When a way runs, and which is fastest when.
    @Test func whenAndFastest() {
        let days = Dictionary(uniqueKeysWithValues: Self.all.filter { $0.time != .night }.map { ($0, 10) })
        let nights = Dictionary(uniqueKeysWithValues: Self.all.filter { $0.time == .night }.map { ($0, 20) })
        let daytime = Self.way(days)
        let always = Self.way(days.mapValues { $0 + 5 }.merging(nights) { a, _ in a }, rides: [["D"]])
        #expect(daytime.when == "Not late nights")
        #expect(always.when == "All times")
        #expect(daytime.fastest(among: [daytime, always]) == "Fastest daytime")
        #expect(always.fastest(among: [daytime, always]) == "Fastest late nights")
        #expect(Self.way([WayFinder.Part(day: .saturday, time: .day): 9]).when == "Weekends")
        #expect(Self.way([:]).fastest(among: [daytime]) == nil)
        #expect(always.minutesLabel == "15–20 min")
    }

    /// A fallback the other way from the same station says so, and that it comes back on the main way.
    @Test func aFallbackTheOtherWayComesBackOn() {
        let main = WayFinder.Way.Start(stationID: "R34", direction: .north)
        let back = WayFinder.Way.Option(place: "32", offStationID: "R36", boardStationID: "R36", direction: .north,
                                        across: true, walkMinutes: 0, typical: 900)
        let fallback = WayFinder.Way(rides: [["R"], ["D", "N"]], changes: [[back]],
                                     start: .init(stationID: "R34", direction: .south),
                                     end: .init(stationID: "R31", walk: 0), minutes: [:], typical: 900)
        #expect(fallback.fallbackDetail(from: main) == "R the other way to 36 St, then back on the D or N")
        #expect(fallback.fallbackShort(from: main) == "R to 36 St, back on the D or N")
    }

    /// A fallback from another station names it.
    @Test func aFallbackFromElsewhereNamesItsStation() {
        let main = WayFinder.Way.Start(stationID: "R34", direction: .north)
        let jay = WayFinder.Way.Option(place: "636", offStationID: "A41", boardStationID: "A41", direction: .north,
                                       across: true, walkMinutes: 0, typical: 900)
        let fallback = WayFinder.Way(rides: [["F"], ["A", "C"]], changes: [[jay]],
                                     start: .init(stationID: "F23", direction: .north),
                                     end: .init(stationID: "A32", walk: 0), minutes: [:], typical: 900)
        #expect(fallback.fallbackDetail(from: main) == "F from 4 Av-9 St to Jay St-MetroTech, then the A or C")
        #expect(fallback.fallbackShort(from: main) == "From 4 Av-9 St: F to Jay St-MetroTech, then the A or C")
    }

    /// A route's start or end, by id: a station, or a stop; anything else is none.
    @Test func startsReadBackByID() {
        #expect(RouteStart(id: "R34").id == "R34")
        #expect(RouteStart(id: "R34").place == StationDirectory.station(id: "R34")?.complex)
        #expect(RouteStart(id: nil).id == nil)
        #expect(RouteStart(id: "nowhere").id == nil)
        #expect(RouteStart(id: "stop not-a-code").id == nil)
    }
}

// MARK: - Transit Directions' screens

/// `QuickTrip`: which of Transit Directions' screens shows, and for how long.
struct QuickTripTests {
    static let touched = Fixtures.date("2026-11-10 08:15")

    /// Nearby and Trip go back to the buttons an hour after the last tap.
    @Test func planningScreensGoBackAfterAnHour() {
        var trip = QuickTrip()
        trip.screen = .trips
        trip.touched = Self.touched
        #expect(trip.shown(at: Self.touched.addingTimeInterval(59 * 60)).screen == .trips)
        #expect(trip.shown(at: Self.touched.addingTimeInterval(60 * 60)).screen == .home)
        trip.screen = .nearbyLine
        #expect(trip.planningExpires == Self.touched.addingTimeInterval(QuickTrip.planningDuration))
    }

    /// The clock set back before the last tap goes back to the buttons, rather than staying up until then.
    @Test func clockSetBackGoesBack() {
        var trip = QuickTrip()
        trip.screen = .nearby
        trip.touched = Self.touched
        #expect(trip.shown(at: Self.touched.addingTimeInterval(-60)).screen == .home)
    }

    /// Favorite Stop stays until its ✕.
    @Test func favoriteStays() {
        var trip = QuickTrip()
        trip.screen = .favorite
        trip.touched = Self.touched
        #expect(trip.planningExpires == nil)
        #expect(trip.shown(at: Self.touched.addingTimeInterval(86400 * 30)).screen == .favorite)
    }
}

// MARK: - New Trip's ranking

/// `TripRanking`: how New Trip weighs its rides against walking all the way, and what it keeps
/// beside a walk.
struct TripRankingTests {
    /// Walking all the way under 30 minutes counts a fifth less: a ride has to be a fifth quicker to go ahead of it.
    @Test func walkGoesFirstUnlessARideIsAFifthQuicker() {
        #expect(TripRanking.walkMarginUnder == 30)
        #expect(TripRanking.walkMargin == 0.2)
        let walk = TripRanking.walkEffort(minutes: 20)
        #expect(abs(walk - 960) < 0.001)
        // 16 minutes is a fifth quicker than 20: a tie, which walking wins
        let tie = TripRanking.order(efforts: [TripRanking.rideEffort(minutes: 16, penalty: 0), walk],
                                    walkAll: [false, true])
        #expect(tie == [1, 0])
        // 15 beats it
        let quicker = TripRanking.order(efforts: [walk, TripRanking.rideEffort(minutes: 15, penalty: 0)],
                                        walkAll: [true, false])
        #expect(quicker == [1, 0])
    }

    /// From 30 minutes, walking counts in full: a ride a minute quicker goes first.
    @Test func longWalksGetNoMargin() {
        #expect(abs(TripRanking.walkEffort(minutes: 29) - 29 * 60 * 0.8) < 0.001)
        #expect(TripRanking.walkEffort(minutes: 30) == 30 * 60)
        let order = TripRanking.order(efforts: [TripRanking.walkEffort(minutes: 30),
                                                TripRanking.rideEffort(minutes: 29, penalty: 0)],
                                      walkAll: [true, false])
        #expect(order == [1, 0])
    }

    /// Walking all the way counts nothing for its walk; a ride's penalty is added to its minutes as it is.
    @Test func onlyARidesWalksCount() {
        #expect(TripRanking.walkEffort(minutes: 45) == 45 * 60)
        #expect(TripRanking.rideEffort(minutes: 12, penalty: 90) == 12 * 60 + 90)
    }

    /// A bus's whole wait counts: 12 minutes with 6 waiting at the stop loses to a 20-minute walk, but not without the wait.
    @Test func aBusWaitCanPutWalkingFirst() {
        let now = Fixtures.date("2026-11-10 08:15")
        let start = RouteKit.near("b0"), end = RouteKit.near("b2")
        let stop = { (id: String) in
            BusRide.Place(name: id, latitude: RouteKit.spot(id).coordinate.latitude, longitude: RouteKit.spot(id).coordinate.longitude)
        }
        let atStop = now.addingTimeInterval(TripPlanner.walkSeconds(start.distance(from: RouteKit.spot("b0"))))
        let ride = { (wait: TimeInterval) in
            BusTrip(bus: BusRide(line: "B63", from: stop("b0"), to: stop("b2"), headsign: "Cobble Hill", stops: 2,
                                 seconds: 480, leaves: atStop.addingTimeInterval(wait)),
                    train: nil, busFirst: true)
        }
        let walk = TripRanking.walkEffort(minutes: 20)
        let waiting = TripRanking.rideEffort(minutes: 12, penalty: ride(360).penalty(from: start, to: end, at: now, timetable: nil))
        #expect(TripRanking.order(efforts: [waiting, walk], walkAll: [false, true]) == [1, 0])
        let boarding = TripRanking.rideEffort(minutes: 12, penalty: ride(1).penalty(from: start, to: end, at: now, timetable: nil))
        #expect(TripRanking.order(efforts: [walk, boarding], walkAll: [true, false]) == [1, 0])
    }

    /// The wait for a first train counts nothing: the same train caught with time to spare ranks the same.
    @Test(.enabled(if: RouteKit.stepFreeOff)) func aTrainWaitDoesntCount() throws {
        let timetable = RouteKit.subway()
        let at = RouteKit.base.addingTimeInterval(60)
        let start = RouteKit.near("R34N"), end = RouteKit.near("R30N")
        let trip = try #require(TripPlanner.plan(from: start, to: end, at: at, timetable: timetable).first)
        let now = try #require(TripPlanner.penalty(of: trip, from: start, to: end, at: at, timetable: timetable))
        let early = try #require(TripPlanner.penalty(of: trip, from: start, to: end, at: at.addingTimeInterval(-50),
                                                     timetable: timetable))
        #expect(TripRanking.rideEffort(minutes: 12, penalty: now) == TripRanking.rideEffort(minutes: 12, penalty: early))
    }

    /// Of two trips there at the same time, changing across the platform (a minute) goes ahead of changing on foot (seven).
    @Test func anAcrossChangeBeatsAWalkedOne() {
        let across = TripRanking.rideEffort(minutes: 25, penalty: TripPlanner.changeCost(across: true))
        let onFoot = TripRanking.rideEffort(minutes: 25, penalty: TripPlanner.changeCost(across: false))
        #expect(onFoot - across == 6 * 60)
        #expect(TripRanking.order(efforts: [onFoot, across], walkAll: [false, false]) == [1, 0])
        // On foot six minutes sooner only ties it, and a tie keeps its order
        let sooner = TripRanking.rideEffort(minutes: 19, penalty: TripPlanner.changeCost(across: false))
        #expect(TripRanking.order(efforts: [across, sooner], walkAll: [false, false]) == [0, 1])
    }

    /// Trips it can't time keep their places; the others fill the rest best first; ties keep their order.
    @Test func untimedTripsKeepTheirPlaces() {
        let order = TripRanking.order(efforts: [900, nil, 600, 900, 300], walkAll: [false, false, false, false, false])
        #expect(order == [4, 1, 2, 0, 3])
        #expect(TripRanking.order(efforts: [], walkAll: []) == [])
        #expect(TripRanking.order(efforts: [nil, nil], walkAll: [true, false]) == [0, 1])
    }

    /// The long-walk word comes at 1.6 times your comfortable walk, never with No Limit.
    @Test func longWalkAtOnePointSixTimes() {
        #expect(TripRanking.longWalk == 1.6)
        #expect(TripRanking.walkIsLong(minutes: 32, comfortable: 20, noLimit: false))
        #expect(!TripRanking.walkIsLong(minutes: 31, comfortable: 20, noLimit: false))
        #expect(TripRanking.walkIsLong(minutes: 25, comfortable: 15, noLimit: false))
        #expect(!TripRanking.walkIsLong(minutes: 500, comfortable: 60, noLimit: true))
    }

    /// Walking all the way is always offered up to two hours, and any with No Limit.
    @Test func walkingIsAlwaysOffered() {
        #expect(TripRanking.offersWalk(minutes: 1, noLimit: false))
        #expect(TripRanking.offersWalk(minutes: 120, noLimit: false))
        #expect(!TripRanking.offersWalk(minutes: 121, noLimit: false))
        #expect(TripRanking.offersWalk(minutes: 480, noLimit: true))
    }

    /// As walking all the way comes in after the trips: slower ones go, as quick and untimed stay, and the one tapped stays.
    @Test func walkComingInKeepsTheQuickerTrips() {
        #expect(TripRanking.keeps(minutes: 20, besideWalk: 20))
        #expect(!TripRanking.keeps(minutes: 21, besideWalk: 20))
        #expect(TripRanking.keeps(minutes: nil, besideWalk: 20))
        let minutes: [Int?] = [15, 25, nil, 20, 30]
        #expect(TripRanking.keptBesideWalk(20, minutes: minutes, bikes: [], tapped: nil) == [0, 2, 3])
        #expect(TripRanking.keptBesideWalk(20, minutes: minutes, bikes: [], tapped: 4) == [0, 2, 3, 4])
    }

    /// Bike rides stay only quicker than the walk, or the soonest of them if none is.
    @Test func bikesStayOnlyQuicker() {
        let minutes: [Int?] = [12, 18, 20, 26, 19]
        // Rows 1, 2 and 3 are bike rides: only the one quicker than 20 stays
        #expect(TripRanking.keptBesideWalk(20, minutes: minutes, bikes: [1, 2, 3], tapped: nil) == [0, 1, 4])
        // None quicker: the soonest, though slower, stays
        #expect(TripRanking.keptBesideWalk(15, minutes: minutes, bikes: [1, 2, 3], tapped: nil) == [0, 1])
        // A bike ride as quick as the walk isn't quicker
        #expect(TripRanking.keptBesideWalk(18, minutes: [18, 19], bikes: [0, 1], tapped: nil) == [0])
    }
}
