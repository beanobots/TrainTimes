import Foundation
import Testing
@testable import TrainCore

/// `Change`: where a widget's train is left for another, which lines and which
/// way it changes to, and the train there each of yours can catch.
@Suite struct ChangeTests {
    /// The R from Prospect Av to the D or N at Atlantic Av-Barclays Ctr, the README's change.
    let atlantic = Change(stationID: "R31", routes: ["D", "N"])
    /// The R's stops from Forest Hills to Bay Ridge, as lines.json has them.
    let rLine = [
        "G08", "G09", "G10", "G11", "G12", "G13", "G14", "G15", "G16", "G18", "G19", "G20", "G21", "R11", "R13",
        "R14", "R15", "R16", "R17", "R18", "R19", "R20", "R21", "R22", "R23", "R24", "R25", "R26", "R27", "R28",
        "R29", "R30", "R31", "R32", "R33", "R34", "R35", "R36", "R39", "R40", "R41", "R42", "R43", "R44", "R45",
    ]

    func time(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    /// A train `minutes` from now at `stop`.
    func train(_ route: String, _ minutes: Double, trip: String, at stop: String,
               lastStop: String = "R01N") -> Arrival {
        Arrival(route: route, time: time(minutes), stop: stop, lastStop: lastStop, isLive: true, trip: trip)
    }

    // MARK: Pairing trains

    @Test func eachTrainMeetsTheFirstItCanCatch() {
        let trains = [train("R", 2, trip: "r1", at: "R34N"), train("R", 6, trip: "r2", at: "R34N"),
                      train("R", 9, trip: "r3", at: "R34N"), train("R", 12, trip: "r4", at: "R34N")]
        let atChange = [
            train("R", 10, trip: "r1", at: "R31N"),
            train("R", 14, trip: "r2", at: "R31N"),
            // Due at the change before your station: it's another trip's time, not this one's
            train("R", 8, trip: "r3", at: "R31N"),
        ]
        let departures = [
            // Your own trip is no train to change to
            train("R", 10, trip: "r1", at: "R31N"),
            train("D", 11, trip: "d1", at: "R31N"),
            train("N", 16, trip: "n1", at: "R31N"),
        ]
        let connections = atlantic.connections(for: trains, atChange: atChange, departures: departures,
                                               selection: prospect)
        // r4 doesn't get there in the feed, and r3's time there is before its time at yours
        #expect(connections.map(\.first.trip) == ["r1", "r2"])
        #expect(connections.map { $0.next?.trip } == ["d1", "n1"])
        #expect(connections.map(\.waitLabel) == ["1 min", "2 min"])
        #expect(connections[0].isQuick(within: 2))
        #expect(!connections[0].staysOn)
    }

    @Test func aLineOnAnotherPlatformCountsTheWalk() {
        let twoThree = Change(stationID: "R31", routes: ["2", "3"], walkMinutes: 3)
        let connections = twoThree.connections(
            for: [train("R", 2, trip: "r1", at: "R34N")],
            atChange: [train("R", 10, trip: "r1", at: "R31N")],
            departures: [train("2", 12, trip: "t2", at: "235N"), train("3", 13, trip: "t3", at: "235N")],
            selection: prospect)
        // The 2 leaves before you could walk to it
        #expect(connections.first?.next?.trip == "t3")
        #expect(connections.first?.waitLabel == "3 min")
        #expect(!twoThree.isAcross("2", from: prospect))
        #expect(!twoThree.isAllAcross(from: prospect))
    }

    @Test func aTrainHeldAtThePlatformCanStillBeCaught() {
        // The D gets there half a minute before your R, but waits a minute
        var held = train("D", 9.5, trip: "held", at: "R31N")
        held.departure = time(11)
        let connections = atlantic.connections(
            for: [train("R", 2, trip: "r1", at: "R34N")],
            atChange: [train("R", 10, trip: "r1", at: "R31N")],
            departures: [held, train("N", 18, trip: "n1", at: "R31N")],
            selection: prospect)
        #expect(connections.first?.next?.trip == "held")
        // It's there already, across the platform: no wait
        #expect(connections.first?.walk == 0)
        #expect(connections.first?.wait == 0)
        #expect(connections.first?.waitLabel == "<1 min")
    }

    @Test func aTrainHeldOnAnotherPlatformStillTakesTheWalk() {
        // A 2 gets to its platform half a minute before your R, and waits three and a half minutes
        let twoThree = Change(stationID: "R31", routes: ["2", "3"], walkMinutes: 3)
        var held = train("2", 9.5, trip: "held", at: "235N")
        held.departure = time(13.5)
        let connections = twoThree.connections(
            for: [train("R", 2, trip: "r1", at: "R34N")],
            atChange: [train("R", 10, trip: "r1", at: "R31N")],
            departures: [held, train("3", 16, trip: "t3", at: "235N")],
            selection: prospect)
        #expect(connections.first?.next?.trip == "held")
        #expect(connections.first?.walk == 180)
        // You're three minutes getting to it, so it's no quick change
        #expect(connections.first?.wait == 180)
        #expect(connections.first?.waitLabel == "3 min")
        #expect(connections.first?.isQuick(within: 2) == false)
    }

    @Test func whetherYouWalkGoesByThePlatformsTheTwoTrainsUse() {
        // The N and Q from 14 St-Union Sq to the D: the N gets to the D's
        // platform at Atlantic, the Q to the B and Q's
        let nq = Selection(stationID: "R20", routes: ["N", "Q"], direction: .south)
        let d = Change(stationID: "R31", routes: ["D"], walkMinutes: 3)
        #expect(d.arrivalStops(for: nq) == ["D24S", "R31S"])
        #expect(!d.isAcross("D", from: nq))
        #expect(!d.isExpress(for: nq))
        let departures = [train("D", 10.5, trip: "d1", at: "R31S"), train("D", 14, trip: "d2", at: "R31S")]
        let connections = d.connections(
            for: [train("N", 2, trip: "n1", at: "R20S"), train("Q", 3, trip: "q1", at: "R20S")],
            atChange: [train("N", 10, trip: "n1", at: "R31S"), train("Q", 10, trip: "q1", at: "D24S")],
            departures: departures, selection: nq)
        #expect(connections.map { $0.next?.trip } == ["d1", "d2"])

        // An N rerouted to the B and Q's platform is a walk from the R's
        let nAndQ = Change(stationID: "R31", routes: ["N", "Q"])
        #expect(nAndQ.departureStops(for: prospect) == ["D24N", "R31N"])
        let rerouted = nAndQ.connections(
            for: [train("R", 2, trip: "r1", at: "R34N")],
            atChange: [train("R", 10, trip: "r1", at: "R31N")],
            departures: [train("N", 10.3, trip: "n1", at: "D24N"), train("Q", 13.5, trip: "q1", at: "D24N")],
            selection: prospect)
        #expect(rerouted.first?.next?.trip == "q1")
        #expect(nAndQ.isAcross(from: train("R", 10, trip: "r1", at: "R31N"), to: train("N", 11, trip: "n2", at: "R31N")))
        #expect(!nAndQ.isAcross(from: train("R", 10, trip: "r1", at: "R31N"), to: train("N", 11, trip: "n2", at: "D24N")))
    }

    @Test func yourTrainGoingOnAsALineChangedToMeansStayingOn() {
        // An N running local on the R from Prospect Av, which goes on as an N
        let connections = atlantic.connections(
            for: [train("N", 2, trip: "n1", at: "R34N"), train("N", 5, trip: "ends", at: "R34N")],
            atChange: [train("N", 10, trip: "n1", at: "R31N"),
                       train("N", 13, trip: "ends", at: "R31N", lastStop: "R31N")],
            departures: [train("D", 14, trip: "d1", at: "R31N"), train("D", 19, trip: "d2", at: "R31N")],
            selection: prospect)
        #expect(connections[0].staysOn)
        #expect(connections[0].next == connections[0].arrival)
        #expect(connections[0].wait == 0)
        #expect(connections[0].waitLabel == "stay on")
        // One that ends its run at the change is left for the next D
        #expect(!connections[1].staysOn)
        #expect(connections[1].next?.trip == "d1")
    }

    // MARK: Which lines, which way

    @Test func theLinesToChangeToAcrossThePlatformAndNot() throws {
        let station = try #require(StationDirectory.station(id: "R31"))
        let lines = Change.lines(at: station, from: prospect)
        #expect(lines.across == ["D", "N"])
        #expect(lines.others == ["2", "3", "4", "5", "B", "Q"])
        #expect(atlantic.isAllAcross(from: prospect))
        // Neither stops at Prospect Av
        #expect(atlantic.isExpress(for: prospect))
        #expect(atlantic.goesYourWay(from: prospect))
        #expect(atlantic.heading(for: prospect) == "Manhattan")
    }

    @Test func theConnectingLineGoesTheWayNamedLikeYours() {
        // The L toward Manhattan meets the J and Z at Broadway Junction, whose way there is their S
        let l = Selection(stationID: "L24", routes: ["L"], direction: .north)
        var jz = Change(stationID: "L22", routes: ["J", "Z"])
        #expect(jz.departureStops(for: l) == ["J27N"])
        #expect(jz.heading(for: l) == "Jamaica")
        #expect(!jz.goesYourWay(from: l))
        #expect(jz.suggestedDirection(for: l) == .south)
        jz.direction = .south
        #expect(jz.departureStops(for: l) == ["J27S"])
        #expect(jz.heading(for: l) == "Manhattan")
        #expect(jz.goesYourWay(from: l))
        // Another way than the train's is never across the platform
        #expect(!jz.isAcross("J", from: l))
        // The A and C there are named like the L
        #expect(Change(stationID: "L22", routes: ["A", "C"]).suggestedDirection(for: l) == .north)

        // The G ends at Court Sq: nothing says which way the 7 is meant, so it's the G's, with both offered
        let g = Selection(stationID: "G24", routes: ["G"], direction: .north)
        let seven = Change(stationID: "G22", routes: ["7"])
        #expect(seven.suggestedDirection(for: g) == .north)
        #expect(!seven.goesYourWay(from: g))
    }

    @Test func aPlaceNamedForSomeLinesIsJustTheirs() {
        // At Delancey St-Essex St the J, Z and M share a platform whose S is
        // "Broad St (JZ) - Uptown (M)": uptown is the M's way, not the J's
        let uptownF = Selection(stationID: "F18", routes: ["F"], direction: .north)
        var jz = Change(stationID: "F15", routes: ["J", "Z"])
        // Nothing there is named like Uptown & Queens, so it's away from Brooklyn, where the F came from
        #expect(jz.suggestedDirection(for: uptownF) == .south)
        jz.direction = .south
        #expect(jz.departureStops(for: uptownF) == ["M18S"])
        #expect(!jz.goesYourWay(from: uptownF))
        // On another platform, going either way, so both are offered
        #expect(!jz.isAllAcross(from: uptownF))
        #expect(Change(stationID: "F15", routes: ["M"]).suggestedDirection(for: uptownF) == .south)
        #expect(Change(stationID: "F15", routes: ["M"], direction: .south).goesYourWay(from: uptownF))

        // From the downtown F, the J and Z toward Brooklyn
        let downtownF = Selection(stationID: "F14", routes: ["F"], direction: .south)
        #expect(Change(stationID: "F15", routes: ["J", "Z"]).suggestedDirection(for: downtownF) == .north)
        // From the M, the J across the platform goes the M's way, though for the J it's Broad St
        let m = Selection(stationID: "M16", routes: ["M"], direction: .south)
        let j = Change(stationID: "M18", routes: ["J"])
        #expect(j.suggestedDirection(for: m) == .south)
        #expect(j.isAllAcross(from: m))
    }

    @Test func aLineThatOnlyEndsHereYourWayGoesTheOtherWayOrNotAtAll() throws {
        // A Flushing-bound 7 at Court Sq: the G only leaves toward Brooklyn
        let seven = Selection(stationID: "720", routes: ["7"], direction: .north)
        let station = try #require(StationDirectory.station(id: "G22"))
        #expect(Change.lines(at: station, from: seven).others.contains("G"))
        #expect(!Change.leaves("G", from: station, going: .north))
        #expect(Change.leaves("G", from: station, going: .south))
        let g = Change(stationID: "G22", routes: ["G"])
        #expect(g.suggestedDirection(for: seven) == .south)
        // Saved going the 7's way, it's paired with Gs ending their run, so it's dropped
        #expect(g.validated(for: seven) == nil)
        var toBrooklyn = g
        toBrooklyn.direction = .south
        #expect(toBrooklyn.validated(for: seven)?.routes == ["G"])
        #expect(toBrooklyn.departureStops(for: seven) == ["G22S"])

        // The 42 St shuttle only leaves Times Sq for Grand Central
        let one = Selection(stationID: "128", routes: ["1"], direction: .north)
        let shuttle = Change(stationID: "127", routes: ["GS"])
        #expect(shuttle.suggestedDirection(for: one) == .south)
        #expect(shuttle.validated(for: one) == nil)
    }

    @Test func aChangeCanBeToAStationJoinedToYours() throws {
        // The R at Lexington Av/59 St to the 4 5 6 at 59 St
        let r = Selection(stationID: "R13", routes: ["R"], direction: .north)
        let lexington = try #require(StationDirectory.station(id: "R11"))
        #expect(StationDirectory.stations(inComplexOf: lexington).map(\.name) == ["Lexington Av/59 St", "59 St"])
        #expect(Change.lines(at: lexington, from: r) == (across: ["N", "W"], others: ["4", "5", "6"]))
        let change = try #require(Change(stationID: "R11", routes: ["6", "4"]).validated(for: r))
        #expect(change.routes == ["4", "6"])
        #expect(change.departureStops(for: r) == ["629N"])
        #expect(!change.isAcross("4", from: r))
        // There's no other way to call the 4 5 6's north than uptown
        #expect(change.heading(for: r) == "Uptown & The Bronx")

        // Court St, which has only the R, to the 2 3 4 5 at Borough Hall
        let south = Selection(stationID: "R27", routes: ["R"], direction: .south)
        let courtSt = try #require(StationDirectory.station(id: "R28"))
        #expect(Change.lines(at: courtSt, from: south).others == ["2", "3", "4", "5"])
        let boroughHall = try #require(Change(stationID: "R28", routes: ["2", "3", "4", "5"]).validated(for: south))
        #expect(boroughHall.departureStops(for: south) == ["232S", "423S"])
    }

    // MARK: Validating

    @Test func validatingDropsYourOwnLinesAndLinesNotThere() throws {
        // The R is yours, the 7 isn't at Atlantic Av
        let change = try #require(Change(stationID: "D24", routes: ["R", "7", "N", "D"]).validated(for: prospect))
        // A platform's id finds its station, whose id it takes, and its order of lines
        #expect(change.stationID == StationDirectory.station(id: "R31")?.id)
        #expect(change.routes == ["D", "N"])
        #expect(Change(stationID: "R31", routes: ["R"]).validated(for: prospect) == nil)
        #expect(Change(stationID: "R34", routes: ["N"]).validated(for: prospect) == nil)
        #expect(Change(stationID: "XYZ", routes: ["N"]).validated(for: prospect) == nil)
    }

    @Test func aChangeBehindYourStationIsNotOnYourWay() {
        let order = { (label: String) in label == "R" ? rLine : nil }
        let dekalb = Selection(stationID: "R30", routes: ["R"], direction: .north)
        #expect(atlantic.isAhead(of: prospect, order: order))
        #expect(!atlantic.isAhead(of: dekalb, order: order))
        // Going the other way, it's the other way round
        var south = dekalb
        south.direction = .south
        #expect(atlantic.isAhead(of: south, order: order))
        var bayRidge = prospect
        bayRidge.direction = .south
        #expect(!atlantic.isAhead(of: bayRidge, order: order))
        // With no order for the line, as for the server without lines.json, it's kept
        #expect(atlantic.isAhead(of: dekalb, order: { _ in nil }))
        #expect(atlantic.isAhead(of: dekalb, order: { _ in ["A02", "A03"] }))

        // Checking a widget whose station was moved past its change drops the change
        #expect(atlantic.validated(for: dekalb, order: order) == nil)
        #expect(atlantic.validated(for: prospect, order: order)?.routes == ["D", "N"])
    }

    // MARK: Saving

    @Test func aChangeSavedBeforeThereWasAWayGoesYours() throws {
        let json = #"{"stationID":"R31","routes":["D","N"],"quickMinutes":4,"walkMinutes":5}"#
        let change = try JSONDecoder().decode(Change.self, from: Data(json.utf8))
        #expect(change.direction == nil)
        #expect(change.departureDirection(for: prospect) == .north)
        #expect(change.quickMinutes == 4)
        #expect(change.walkMinutes == 5)
        #expect(change.key == "R31 D,N 5")
    }

    @Test func aChangeSavedWithoutItsTimesStillLoads() throws {
        let json = #"{"stationID":"L22","routes":["J","Z"],"direction":"S"}"#
        let change = try JSONDecoder().decode(Change.self, from: Data(json.utf8))
        #expect(change == Change(stationID: "L22", routes: ["J", "Z"], direction: .south))
        #expect(change.quickMinutes == Change.defaultQuickMinutes)
        #expect(change.walkMinutes == Change.defaultWalkMinutes)
        // Its way keeps its trains apart from the other way's
        #expect(change.key == "L22 J,Z 3 S")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Change.self, from: Data(#"{"stationID":"L22"}"#.utf8))
        }
    }

    @Test func savesAsItLoads() throws {
        for change in [atlantic, Change(stationID: "L22", routes: ["J"], direction: .south, quickMinutes: 1, walkMinutes: 6)] {
            let data = try JSONEncoder().encode(change)
            #expect(try JSONDecoder().decode(Change.self, from: data) == change)
        }
        // Without a way of its own, there's none in the file, as before there could be
        let keys = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(atlantic)) as? [String: Any]).map { Set($0.keys) }
        #expect(keys == ["stationID", "routes", "quickMinutes", "walkMinutes"])
    }

    @Test func aConnectionLoadsWithoutATrainToChangeTo() throws {
        let connection = Connection(first: train("R", 2, trip: "r1", at: "R34N"),
                                    arrival: train("R", 10, trip: "r1", at: "R31N"), next: nil)
        let data = try JSONEncoder().encode(connection)
        let loaded = try JSONDecoder().decode(Connection.self, from: data)
        #expect(loaded == connection)
        #expect(loaded.waitLabel == "–")
    }

    @Test func aConnectionSavedWithoutItsWalkLoadsWithNone() throws {
        let connection = Connection(first: train("R", 2, trip: "r1", at: "R34N"),
                                    arrival: train("R", 10, trip: "r1", at: "R31N"),
                                    next: train("2", 14, trip: "t2", at: "235N"), walk: 180)
        let data = try JSONEncoder().encode(connection)
        #expect(try JSONDecoder().decode(Connection.self, from: data) == connection)
        var saved = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        saved["walk"] = nil
        let loaded = try JSONDecoder().decode(Connection.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(loaded.walk == 0)
        #expect(loaded.next?.trip == "t2")
        #expect(loaded.waitLabel == "4 min")
    }

    @Test func theTransfersWidgetsLinkKeepsTheWay() throws {
        let l = Selection(stationID: "L24", routes: ["L"], direction: .north)
        let jz = Change(stationID: "L22", routes: ["J", "Z"], direction: .south)
        let url = l.transferURL(changingAt: jz)
        let opened = try #require(Selection.transfer(from: url))
        #expect(opened.change.departureStops(for: opened.selection) == ["J27S"])
        // A link from before there was a way goes your train's
        let old = try #require(URL(string: "traintimes://transfer?station=R34&lines=R&direction=N&elevators=0&walk=0&change=R31&to=D,N"))
        #expect(Selection.transfer(from: old)?.change.departureDirection(for: prospect) == .north)
    }
}

