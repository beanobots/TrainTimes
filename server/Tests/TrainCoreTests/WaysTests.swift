import Foundation
import Testing
@testable import TrainCore

/// `TrainService.ways(for:...)`: every way on from your train for the large Transfers widget,
/// soonest to the change's destination first.
@Suite struct WaysTests {
    /// A train `minutes` from now at `stop`.
    func train(_ route: String, _ minutes: Double, trip: String, at stop: String) -> Arrival {
        Arrival(route: route, time: now.addingTimeInterval(minutes * 60), stop: stop, lastStop: "R01N",
                isLive: true, trip: trip)
    }

    let herald = StationDirectory.all.first { $0.name == "34 St-Herald Sq" }?.id

    /// From Prospect Av on the R: the D, N and 2 at Atlantic Av, the Q across at DeKalb Av.
    func legs(_ change: Change, atlantic: [Arrival], deKalb: [Arrival])
        -> [(part: (change: Change, lines: [String], selection: Selection), departures: [Arrival], atChange: [Arrival])] {
        let parts = change.smartChanges(for: prospect).map { (change: $0.change, lines: $0.lines, selection: prospect.only($0.lines)) }
        #expect(parts.map(\.change.stationID) == ["R31", "R30"])
        return [
            (parts[0], atlantic, [train("R", 10, trip: "r1", at: "R31N")]),
            (parts[1], deKalb, [train("R", 12, trip: "r1", at: "R30N")]),
        ]
    }

    @Test func eachLineThatGetsThereAndStayingOnSoonestFirst() throws {
        let change = Change(stationID: "R31", routes: ["D", "N", "Q", "2"], smartTransfer: true, destinationID: try #require(herald))
        let legs = legs(change,
                        atlantic: [train("D", 11, trip: "d1", at: "R31N"), train("N", 20, trip: "n1", at: "R31N"),
                                   train("2", 15, trip: "t1", at: "235N")],
                        deKalb: [train("Q", 13, trip: "q1", at: "R30N")])
        let there = Dictionary(grouping: [train("D", 25, trip: "d1", at: "D17N"), train("Q", 27, trip: "q1", at: "R17N"),
                                          train("N", 32, trip: "n1", at: "R17N"), train("R", 40, trip: "r1", at: "R17N")],
                               by: \.trip)
        let ways = TrainService.ways(for: train("R", 2, trip: "r1", at: "R34N"), legs: legs, change: change,
                                     selection: prospect, there: there)
        // The 2 doesn't stop at 34 St-Herald Sq
        #expect(ways.map(\.route) == ["D", "Q", "N", "R"])
        #expect(ways.map(\.staysOn) == [false, false, false, true])
        #expect(ways.map { $0.connection?.stationID } == ["R31", "R30", "R31", nil])
        #expect(ways.map { $0.arrival?.stop } == ["D17N", "R17N", "R17N", "R17N"])
        #expect(ways[0].connection?.waitLabel == "1 min")
    }

    @Test func aLinesFirstTrainThatGetsThereIsTheOneTaken() throws {
        let change = Change(stationID: "R31", routes: ["N"], destinationID: try #require(herald))
        let parts = change.smartChanges(for: prospect).map { (change: $0.change, lines: $0.lines, selection: prospect.only($0.lines)) }
        let legs = [(part: parts[0],
                     departures: [train("N", 11, trip: "n1", at: "R31N"), train("N", 15, trip: "n2", at: "R31N")],
                     atChange: [train("R", 10, trip: "r1", at: "R31N")])]
        // n1 isn't predicted to get there
        let there = Dictionary(grouping: [train("N", 30, trip: "n2", at: "R17N")], by: \.trip)
        let ways = TrainService.ways(for: train("R", 2, trip: "r1", at: "R34N"), legs: legs, change: change,
                                     selection: prospect, there: there)
        #expect(ways.map { $0.connection?.next?.trip } == ["n2"])
    }

    @Test func withoutADestinationEachLineIsTimedToTheChange() {
        let change = Change(stationID: "R31", routes: ["D", "N", "Q", "2"], walkMinutes: 3, smartTransfer: true)
        let legs = legs(change,
                        atlantic: [train("D", 11, trip: "d1", at: "R31N"), train("N", 20, trip: "n1", at: "R31N"),
                                   train("2", 12, trip: "t1", at: "235N"), train("2", 15, trip: "t2", at: "235N")],
                        deKalb: [train("Q", 13, trip: "q1", at: "R30N")])
        let ways = TrainService.ways(for: train("R", 2, trip: "r1", at: "R34N"), legs: legs, change: change,
                                     selection: prospect, there: [:])
        // The 2 a walk away misses t1; no staying on without somewhere to stay on to
        #expect(ways.map(\.route) == ["D", "Q", "2", "N"])
        #expect(ways.map { $0.arrival?.trip } == ["d1", "q1", "t2", "n1"])
    }

    @Test func aDestinationSavesAndTellsChangesApart() throws {
        let change = Change(stationID: "R31", routes: ["D"], destinationID: "D17")
        let loaded = try JSONDecoder().decode(Change.self, from: JSONEncoder().encode(change))
        #expect(loaded == change)
        #expect(loaded.destination?.name == "34 St-Herald Sq")
        #expect(change.key != Change(stationID: "R31", routes: ["D"]).key)
        // Its stops both ways, at both of its joined stations
        #expect(change.destinationStops.isSuperset(of: ["D17N", "D17S", "R17N", "R17S"]))
        #expect(change.reachesDestination("Q") && !change.reachesDestination("2"))
    }

    @Test func aConnectionSavedWithoutWaysLoads() throws {
        // Saved before ways, so with no "ways" key
        let saved = Connection(first: train("R", 2, trip: "r1", at: "R34N"), arrival: train("R", 10, trip: "r1", at: "R31N"))
        let data = try JSONEncoder().encode(saved)
        #expect(!String(decoding: data, as: UTF8.self).contains("ways"))
        #expect(try JSONDecoder().decode(Connection.self, from: data).ways == nil)
    }
}
