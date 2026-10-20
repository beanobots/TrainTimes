import Foundation
import Testing
@testable import TrainCore

/// The widgets' maps (Shared/MapLayout.swift): which stops they show, where
/// the trains are among them, and what VoiceOver says of them.
@Suite struct MapLayoutTests {
    func time(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    /// An R on its way to Prospect Av, due at each of `stops` (platform id, minutes from now).
    func rTrain(_ stops: [(String, Double)], isLive: Bool = true, position: Arrival.Position? = nil) -> Arrival {
        Arrival(route: "R", time: time(stops.last?.1 ?? 0), stop: "R34N", lastStop: "G08N", isLive: isLive,
                trip: "r1", approach: stops.map { Arrival.Stop(id: $0.0, time: time($0.1)) }, position: position)
    }

    /// From Bay Ridge, every stop to Prospect Av.
    let fromBayRidge: [(String, Double)] = [
        ("R45N", -1), ("R44N", 1), ("R43N", 3), ("R42N", 5), ("R41N", 7), ("R40N", 9), ("R39N", 11), ("R36N", 13),
        ("R35N", 15), ("R34N", 17),
    ]

    func clock(_ date: Date) -> String {
        "\(Int(date.timeIntervalSince(now) / 60)) min"
    }

    // MARK: The medium widget's stops

    @Test func betweenStopsTheTrainIsAsFarAlongAsItsTimesSay() throws {
        // Left 45 St 30 seconds ago, due at 36 St in a minute and a half
        let train = rTrain([("R40N", -2), ("R39N", -0.5), ("R36N", 1.5), ("R35N", 3), ("R34N", 5)])
        let layout = try #require(StopLayout(train: train, now: now))
        #expect(layout.rows.map(\.name) == ["45 St", "36 St", "25 St", "Prospect Av"])
        #expect(layout.rows.map(\.kind) == [.stop, .stop, .stop, .yours])
        #expect(layout.rows.map(\.isTrainStop) == [false, true, false, false])
        // A quarter of the way, not halfway
        #expect(abs(layout.trainRow - 0.25) < 0.001)
        #expect(layout.label == "3 STOPS AWAY")
        #expect(layout.spoken(clock: clock) == "R train between 45 St and 36 St, 3 stops from Prospect Av")
    }

    @Test func aLongWayFoldsTheStopsBetween() throws {
        let train = rTrain(fromBayRidge, position: Arrival.Position(stop: "R43N", isStopped: true))
        let layout = try #require(StopLayout(train: train, now: now))
        #expect(layout.rows.map(\.name) == ["77 St", "Bay Ridge Av", "5 more stops", "Prospect Av"])
        #expect(layout.rows.map(\.kind) == [.stop, .stop, .folded, .yours])
        #expect(layout.trainRow == 0)
        #expect(layout.label == "7 STOPS AWAY")
        #expect(layout.spoken(clock: clock) == "R train at 77 St, 7 stops from Prospect Av")

        // With three rows, from the stop it's heading for
        let moving = rTrain(fromBayRidge, position: Arrival.Position(stop: "R43N", isStopped: false))
        let short = try #require(StopLayout(train: moving, now: now, maxRows: 3))
        #expect(short.rows.map(\.name) == ["77 St", "6 more stops", "Prospect Av"])
        #expect(short.trainRow == -0.5)
        #expect(short.label == "8 STOPS AWAY")
        #expect(short.spoken(clock: clock) == "R train between 86 St and 77 St, 8 stops from Prospect Av")
    }

    @Test func aTimetableTrainLeavesItsFirstStop() throws {
        let train = rTrain(fromBayRidge.map { ($0.0, $0.1 + 10) }, isLive: false)
        let layout = try #require(StopLayout(train: train, now: now))
        #expect(layout.rows.first?.departs == time(9))
        #expect(layout.rows.dropFirst().allSatisfy { $0.departs == nil })
        #expect(layout.trainRow == 0)
        #expect(layout.label == "9 STOPS AWAY")
        #expect(layout.spoken(clock: clock) == "R train scheduled to leave Bay Ridge at 9 min, 9 stops from Prospect Av")
    }

    @Test func nextStopAndAtYourStop() throws {
        let coming = rTrain([("R35N", -1), ("R34N", 1)])
        let next = try #require(StopLayout(train: coming, now: now))
        #expect(next.label == "NEXT STOP")
        #expect(abs(next.trainRow - 0.5) < 0.001)
        #expect(next.spoken(clock: clock) == "R train between 25 St and Prospect Av, your stop is next")

        let here = rTrain([("R35N", -1), ("R34N", 0)], position: Arrival.Position(stop: "R34N", isStopped: true))
        let at = try #require(StopLayout(train: here, now: now))
        #expect(at.label == "AT YOUR STOP")
        #expect(at.rows.map(\.name) == ["Prospect Av"])
        #expect(at.spoken(clock: clock) == "R train at Prospect Av, your stop")
    }

    @Test func aShuttleIsSaidByItsName() throws {
        // Left Botanic Garden 30 seconds ago for Park Pl and Franklin Av
        let stops = [("S04N", -0.5), ("S03N", 1.0), ("S01N", 3.0)]
        let train = Arrival(route: "FS", time: time(3), stop: "S01N", lastStop: "S01N", isLive: true, trip: "fs1",
                            approach: stops.map { Arrival.Stop(id: $0.0, time: time($0.1)) })
        let layout = try #require(StopLayout(train: train, now: now))
        #expect(layout.spoken(clock: clock)
            == "Franklin Av Shuttle between Botanic Garden and Park Pl, 2 stops from Franklin Av")
    }

    @Test func noStopsNoMap() {
        #expect(StopLayout(train: rTrain([]), now: now) == nil)
    }

    // MARK: The large Transfers map

    /// The R from Prospect Av leaving at `leaves` minutes, through 4 Av-9 St
    /// and Union St to Atlantic Av, meeting a train of `line` `wait` minutes
    /// after it gets there, which calls at `theirs` on its way.
    func connection(leaves: Double, wait: Double?, line: String = "D",
                    theirs: [(String, Double)] = [("R36N", -6)]) -> Connection {
        let stops = [("R35N", -1.5), ("R34N", 0.0), ("R33N", 2.0), ("R32N", 4.0), ("R31N", 6.0)]
        let approach = stops.map { Arrival.Stop(id: $0.0, time: time(leaves + $0.1)) }
        let first = Arrival(route: "R", time: time(leaves), stop: "R34N", lastStop: "G08N", isLive: true, trip: "r1",
                            approach: Array(approach.prefix(2)))
        let arrival = Arrival(route: "R", time: time(leaves + 6), stop: "R31N", lastStop: "G08N", isLive: true,
                              trip: "r1", approach: approach)
        let next = wait.map { wait in
            let meets = time(leaves + 6 + wait)
            return Arrival(route: line, time: meets, stop: "R31N", lastStop: "D01N", isLive: true, trip: "x1",
                           approach: theirs.map { Arrival.Stop(id: $0.0, time: meets.addingTimeInterval($0.1 * 60)) }
                               + [Arrival.Stop(id: "R31N", time: meets)])
        }
        return Connection(first: first, arrival: arrival, next: next)
    }

    @Test func theTracksFromTheChangeBackToTheTrain() throws {
        let layout = try #require(TransferMapLayout(connection: connection(leaves: 0.5, wait: 1), selection: prospect,
                                                    now: now, maxRows: 5))
        #expect(layout.rows.map(\.name) == ["Atlantic Av-Barclays Ctr", "Union St", "4 Av-9 St", "Prospect Av", "25 St"])
        #expect(layout.rows.map(\.kind) == [.change, .stop, .stop, .origin, .stop])
        #expect(layout.rows.map(\.shared) == [true, false, false, false, false])
        // A third of the way from 25 St to Prospect Av
        #expect(abs(layout.firstRow - (3 + 1.0 / 3)) < 0.001)
        // The D, a minute behind at the change, is a minute behind on the track
        #expect(abs((layout.nextRow ?? 0) - 4) < 0.001)
        #expect(layout.nextNote == nil)
        #expect(layout.spoken == "Your R train is between 25 St and Prospect Av. "
            + "The D gets to Atlantic Av-Barclays Ctr a minute after yours.")
    }

    @Test func aTrainFurtherOffThanTheMapIsSaidWhereItIs() throws {
        let layout = try #require(TransferMapLayout(connection: connection(leaves: 0.5, wait: 6), selection: prospect,
                                                    now: now, maxRows: 5))
        #expect((layout.nextRow ?? 0) > 4)
        #expect(layout.nextNote == "D heading for 36 St")
        #expect(layout.spoken == "Your R train is between 25 St and Prospect Av. D heading for 36 St.")

        // A shuttle is "S" on the map, and said by its name
        let shuttle = try #require(TransferMapLayout(connection: connection(leaves: 0.5, wait: 6, line: "GS"),
                                                     selection: prospect, now: now, maxRows: 5))
        #expect(shuttle.nextNote == "S heading for 36 St")
        #expect(shuttle.spoken == "Your R train is between 25 St and Prospect Av. 42 St Shuttle heading for 36 St.")
    }

    @Test func foldedStopsAndPlatformsSharedOnTheWay() throws {
        // Left Prospect Av a minute ago; an N that calls at 4 Av-9 St too
        let layout = try #require(TransferMapLayout(
            connection: connection(leaves: -1, wait: 2, line: "N", theirs: [("R33N", -4)]),
            selection: prospect, now: now, maxRows: 4))
        #expect(layout.rows.map(\.name) == ["Atlantic Av-Barclays Ctr", "2 more stops", "Prospect Av", "25 St"])
        #expect(layout.rows.map(\.kind) == [.change, .folded, .origin, .stop])
        #expect(abs(layout.firstRow - (1 + 2.0 / 3)) < 0.001)
        // Past the fold, just where it's headed; the shared stop is folded away
        #expect(layout.spoken == "Your R train is on its way to Atlantic Av-Barclays Ctr. "
            + "The N gets to Atlantic Av-Barclays Ctr 2 minutes after yours.")

        let unfolded = try #require(TransferMapLayout(
            connection: connection(leaves: 3, wait: 2, line: "N", theirs: [("R33N", -4)]),
            selection: prospect, now: now, maxRows: 5))
        #expect(unfolded.rows.map(\.shared) == [true, false, true, false, false])
        #expect(unfolded.spoken == "Your R train is on its way to 25 St. N heading for 4 Av-9 St. "
            + "The N stops at 4 Av-9 St too.")
    }

    @Test func withNoTrainToChangeToJustYours() throws {
        let layout = try #require(TransferMapLayout(connection: connection(leaves: 0.5, wait: nil), selection: prospect,
                                                    now: now, maxRows: 5))
        #expect(layout.nextRow == nil)
        #expect(layout.spoken == "Your R train is between 25 St and Prospect Av.")
    }

    @Test func trackPlacesTheChangeAtTheRight() {
        let track = TrackGeometry(width: 300, stops: 5)
        #expect(track.x(0) == 288)
        #expect(abs(track.spacing - 278 / 4.6) < 0.001)
        #expect(abs(track.x(4.6) - TrackGeometry.leftmost) < 0.001)
    }

    @Test func mainStationNames() {
        #expect("Atlantic Av-Barclays Ctr".mainStationName == "Atlantic Av")
        #expect("47-50 Sts-Rockefeller Ctr".mainStationName == "47-50 Sts")
        #expect("Hoyt-Schermerhorn Sts".mainStationName == "Hoyt-Schermerhorn Sts")
        #expect("174-175 Sts".mainStationName == "174-175 Sts")
    }
}
