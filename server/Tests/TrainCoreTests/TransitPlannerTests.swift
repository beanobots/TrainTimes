import Foundation
import Testing
@testable import TrainCore

/// When the fixtures' timetables start, and leaving a minute after.
private let base = Date(timeIntervalSince1970: 1_793_000_000)
private let leaving = base.addingTimeInterval(60)

/// The R north from Prospect Av to DeKalb Av, 2 minutes a stop, and the Q from Atlantic Av on to
/// Canal St through DeKalb Av, each every 10 minutes for 2 hours.
func plannerSubway(rEvery: UInt32 = 600, from base: Date = base) -> Timetable {
    let stops = ["R34N", "R33N", "R32N", "R31N", "R30N", "D24N", "Q01N"]
    let call = { (stop: UInt16, at: UInt16) in Timetable.Call(stop: stop, arrives: at, waits: 0) }
    let r = Timetable.Pattern(route: 0, calls: [call(0, 0), call(1, 120), call(2, 240), call(3, 360), call(4, 480)])
    let q = Timetable.Pattern(route: 1, calls: [call(5, 0), call(4, 150), call(6, 600)])
    return Timetable(made: base, base: base, stops: stops, routes: ["R", "Q"], patterns: [r, q],
                     starts: [Array(stride(from: 0, through: 7200, by: Int(rEvery))).map(UInt32.init),
                              Array(stride(from: 0, through: 7200, by: 600)).map(UInt32.init)])
}

/// Bus stops up 5 Av in Park Slope, and on toward Downtown Brooklyn.
let busStops: [(String, Double, Double)] = [
    ("b0", 40.6650, -73.9850), ("b1", 40.6700, -73.9820), ("b2", 40.6750, -73.9790),
    // 30 m from b2, where the B67 boards
    ("b2x", 40.6752, -73.9788), ("b3", 40.6900, -73.9750),
]

/// The B63 up 5 Av (b0 to b2, 4 minutes a stop) every 8 minutes, the slower B69 the same way, and
/// the B67 on from beside b2 to b3, all for 2 hours.
func plannerBuses(b63From: UInt32 = 0, from base: Date = base) -> Timetable {
    let call = { (stop: UInt16, at: UInt16) in Timetable.Call(stop: stop, arrives: at, waits: 0) }
    let patterns = [
        Timetable.Pattern(route: 0, calls: [call(0, 0), call(1, 240), call(2, 480)]),
        Timetable.Pattern(route: 1, calls: [call(0, 0), call(1, 420), call(2, 840)]),
        Timetable.Pattern(route: 2, calls: [call(3, 0), call(4, 600)]),
    ]
    let every = { (from: UInt32) in Array(stride(from: from, through: from + 7200, by: 480)) }
    return Timetable(made: base, base: base, stops: busStops.map(\.0),
                     routes: ["B63\tCOBBLE HILL", "B69\tDOWNTOWN", "B67\tDOWNTOWN"], patterns: patterns,
                     starts: [every(b63From), every(0), every(0)],
                     places: busStops.map { Timetable.Place(latitude: $0.1, longitude: $0.2, name: $0.0.uppercased()) })
}

private func point(_ stop: String) -> (Double, Double) {
    if let bus = busStops.first(where: { $0.0 == stop }) { return (bus.1, bus.2) }
    let platform = StationDirectory.platform(forStop: stop)!
    return (platform.lat, platform.lon)
}

/// A little off `place`, as a start or end would be.
private func near(_ place: (Double, Double)) -> (Double, Double) {
    (place.0 + 0.0005, place.1)
}

@Suite struct TransitPlannerTests {
    @Test func ridesABusFromNearTheStartToNearTheEnd() throws {
        let network = TransitNetwork(subway: nil, buses: plannerBuses())
        // From 330 m south of b0, too far to walk to b2 sooner than the B69 gets there
        let start = (point("b0").0 - 0.003, point("b0").1)
        let routes = TransitPlanner.routes(on: network, from: start, to: near(point("b2")),
                                           departure: leaving, modes: [.bus])
        let first = try #require(routes.first)
        #expect(first.legs.map(\.line) == ["B63"])
        let leg = first.legs[0]
        #expect(leg.mode == .bus)
        #expect(leg.headsign == "COBBLE HILL")
        #expect(leg.from.name == "B0")
        #expect(leg.to.name == "B2")
        #expect(leg.stops == 2)
        #expect(leg.seconds == 480)
        // 5 minutes to walk, a minute after the timetable starts: the bus at 8 minutes, not the one gone
        #expect(leg.leaves == Int(base.timeIntervalSince1970) + 480)
        // The slower B69 too, after it
        #expect(routes.map { $0.legs.map(\.line) }.contains(["B69"]))
        #expect((routes.firstIndex { $0.legs.map(\.line) == ["B69"] } ?? 0) > 0)
    }

    @Test func changesBusesOnFootToStopsNearby() throws {
        let network = TransitNetwork(subway: nil, buses: plannerBuses())
        let routes = TransitPlanner.routes(on: network, from: near(point("b0")), to: near(point("b3")),
                                           departure: leaving, modes: [.bus])
        let first = try #require(routes.first)
        #expect(first.legs.map(\.line) == ["B63", "B67"])
        // The B67 caught after the walk from b2
        let off = try #require(first.legs[0].leaves).advanced(by: try #require(first.legs[0].seconds))
        #expect(try #require(first.legs[1].leaves) >= off + TransitNetwork.changeSeconds)
        #expect(first.legs[1].from.name == "B2X")
    }

    @Test func ridesTheSubwayAndChangesAtTheSamePlatform() throws {
        let network = TransitNetwork(subway: plannerSubway(), buses: nil)
        let routes = TransitPlanner.routes(on: network, from: near(point("R34N")), to: near(point("Q01N")),
                                           departure: leaving, modes: [.subway])
        let first = try #require(routes.first)
        #expect(first.legs.map(\.line) == ["R", "Q"])
        #expect(first.legs.map(\.mode) == [.subway, .subway])
        #expect(first.legs[0].from.name == "Prospect Av")
        // DeKalb Av, where the Q calls at the R's platform, not Atlantic Av, a 5-minute walk
        #expect(first.legs[0].to.name == "DeKalb Av")
        #expect(first.legs[1].from == first.legs[0].to)
        #expect(first.legs[1].to.name == "Canal St")
    }

    @Test func plansBusAndSubwayTogetherAndEachAlone() throws {
        let network = TransitNetwork(subway: plannerSubway(), buses: plannerBuses())
        let routes = TransitPlanner.routes(on: network, from: near(point("R34N")), to: near(point("Q01N")),
                                           departure: leaving, modes: [.subway, .bus])
        #expect(routes.first?.legs.map(\.line) == ["R", "Q"])
        // Bus alone has nothing there; the subway's not asked for has nothing either
        let buses = TransitPlanner.routes(on: network, from: near(point("R34N")), to: near(point("Q01N")),
                                          departure: leaving, modes: [.bus])
        #expect(buses.allSatisfy { $0.legs.allSatisfy { $0.mode == .bus } })
    }

    @Test func offersNoTripLeavingMuchLater() {
        // The first B63 and B69 three hours on
        let call = { (stop: UInt16, at: UInt16) in Timetable.Call(stop: stop, arrives: at, waits: 0) }
        let late = Timetable(made: base, base: base, stops: busStops.map(\.0), routes: ["B63\tCOBBLE HILL"],
                             patterns: [Timetable.Pattern(route: 0, calls: [call(0, 0), call(2, 480)])],
                             starts: [[3 * 3600]],
                             places: busStops.map { Timetable.Place(latitude: $0.1, longitude: $0.2, name: $0.0) })
        let network = TransitNetwork(subway: nil, buses: late)
        #expect(TransitPlanner.routes(on: network, from: near(point("b0")), to: near(point("b2")),
                                      departure: leaving, modes: [.bus]).isEmpty)
    }

    @Test func doesntChangeToTheLineJustRidden() {
        // The R in two parts, meeting at Union St: no trip "changing" from the R to the R
        let call = { (stop: UInt16, at: UInt16) in Timetable.Call(stop: stop, arrives: at, waits: 0) }
        let split = Timetable(made: base, base: base, stops: ["R34N", "R32N", "R30N"], routes: ["R"],
                              patterns: [Timetable.Pattern(route: 0, calls: [call(0, 0), call(1, 240)]),
                                         Timetable.Pattern(route: 0, calls: [call(1, 0), call(2, 240)])],
                              starts: [[0, 600, 1200], [300, 900, 1500]])
        let network = TransitNetwork(subway: split, buses: nil)
        let routes = TransitPlanner.routes(on: network, from: near(point("R34N")), to: near(point("R30N")),
                                           departure: leaving, modes: [.subway])
        #expect(!routes.contains { $0.legs.count == 2 })
    }

    @Test func nothingNearEitherEndIsNoTrip() {
        let network = TransitNetwork(subway: nil, buses: plannerBuses())
        #expect(TransitPlanner.routes(on: network, from: (40.80, -73.90), to: near(point("b2")),
                                      departure: leaving, modes: [.bus]).isEmpty)
    }

    @Test func noRideFromAPlaceToItself() {
        let network = TransitNetwork(subway: plannerSubway(), buses: plannerBuses())
        let here = near(point("R34N"))
        #expect(TransitPlanner.routes(on: network, from: here, to: here, departure: leaving, modes: [.subway, .bus]).isEmpty)
    }

    @Test func noRideSlowerThanWalkingStraightThere() {
        // Prospect Av to 4 Av-9 St, a stop on: the R just gone, the next at 12 minutes, is slower than the walk
        let network = TransitNetwork(subway: plannerSubway(), buses: nil)
        #expect(TransitPlanner.routes(on: network, from: near(point("R34N")), to: near(point("R33N")),
                                      departure: leaving, modes: [.subway]).isEmpty)
        // To Canal St, the R and Q are well worth it
        #expect(!TransitPlanner.routes(on: network, from: near(point("R34N")), to: near(point("Q01N")),
                                       departure: leaving, modes: [.subway]).isEmpty)
    }

    @Test func waitsAtMostHalfAnHourForAFirstRide() {
        #expect(TransitPlanner.maxWait == 30 * 60)
        // A B63 from b0 on to b3, its only bus 29 or 32 minutes after the timetable starts; at b0 under a minute on
        let call = { (stop: UInt16, at: UInt16) in Timetable.Call(stop: stop, arrives: at, waits: 0) }
        let planned = { (start: UInt32) in
            let timetable = Timetable(made: base, base: base, stops: busStops.map(\.0), routes: ["B63\tCOBBLE HILL"],
                                      patterns: [Timetable.Pattern(route: 0, calls: [call(0, 0), call(4, 600)])],
                                      starts: [[start]],
                                      places: busStops.map { Timetable.Place(latitude: $0.1, longitude: $0.2, name: $0.0) })
            return TransitPlanner.routes(on: TransitNetwork(subway: nil, buses: timetable), from: near(point("b0")),
                                         to: near(point("b3")), departure: leaving, modes: [.bus])
        }
        #expect(planned(29 * 60).first?.legs.map(\.line) == ["B63"])
        #expect(planned(32 * 60).isEmpty)
    }
}
