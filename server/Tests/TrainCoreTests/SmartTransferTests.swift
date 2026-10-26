import Foundation
import Testing
@testable import TrainCore

/// `Change.smartTransfer`: lines that are a walk at the change but across the platform at your
/// train's next stop are changed to there instead.
@Suite struct SmartTransferTests {
    /// A train `minutes` from now at `stop`.
    func train(_ route: String, _ minutes: Double, trip: String, at stop: String) -> Arrival {
        Arrival(route: route, time: now.addingTimeInterval(minutes * 60), stop: stop, lastStop: "R01N",
                isLive: true, trip: trip)
    }

    /// Where `change`'s walked-to lines are across the platform one stop on, as "DeKalb Av Q".
    func later(_ change: Change, from selection: Selection) -> String? {
        describe(change.acrossNearby(for: selection).after)
    }

    /// Where they're across the platform a stop sooner.
    func sooner(_ change: Change, from selection: Selection) -> String? {
        describe(change.acrossNearby(for: selection).before)
    }

    func describe(_ change: Change?) -> String? {
        change.map { "\($0.station?.name ?? $0.stationID) \($0.routes.joined(separator: ","))" }
    }

    @Test func theQIsAcrossAtDeKalbAfterAWalkAtAtlantic() {
        #expect(later(Change(stationID: "R31", routes: ["Q"]), from: prospect) == "DeKalb Av Q")
        #expect(later(Change(stationID: "R31", routes: ["B", "Q"]), from: prospect) == "DeKalb Av B,Q")
    }

    @Test func onlyTheWalkedToLinesMove() {
        let change = Change(stationID: "R31", routes: ["D", "N", "Q"], smartTransfer: true)
        #expect(later(change, from: prospect) == "DeKalb Av Q")
        let parts = change.smartChanges(for: prospect).map(\.change)
        #expect(parts.map(\.stationID) == ["R31", "R30"])
        #expect(parts.map(\.routes) == [["D", "N"], ["Q"]])
        #expect(change.stationNames(for: prospect) == "Atlantic Av / DeKalb Av")
    }

    @Test func offOrNothingBetterKeepsTheChange() {
        var change = Change(stationID: "R31", routes: ["D", "N", "Q"])
        #expect(change.smartChanges(for: prospect).map(\.change) == [change])
        // Already across the platform
        change = Change(stationID: "R31", routes: ["D", "N"], smartTransfer: true)
        #expect(later(change, from: prospect) == nil)
        #expect(change.smartChanges(for: prospect).map(\.change) == [change])
        // Southbound the R reaches DeKalb Av, across from the Q, first
        let unionSquare = Selection(stationID: "R20", routes: ["R"], direction: .south)
        #expect(later(Change(stationID: "R30", routes: ["Q"]), from: unionSquare) == nil)
        #expect(sooner(Change(stationID: "R30", routes: ["Q"]), from: unionSquare) == nil)
        // The stop before the change can't be your own station or behind it
        let deKalb = Selection(stationID: "R30", routes: ["R"], direction: .south)
        #expect(sooner(Change(stationID: "R31", routes: ["Q"]), from: deKalb) == nil)
    }

    @Test func goingTheOtherWayItChangesAStopSooner() {
        // A Q toward Coney Island meets the R across the platform at DeKalb Av, before Atlantic Av
        let qSouth = Selection(stationID: "R20", routes: ["Q"], direction: .south)
        let toR = Change(stationID: "R31", routes: ["R"], smartTransfer: true)
        #expect(sooner(toR, from: qSouth) == "DeKalb Av R")
        #expect(later(toR, from: qSouth) == nil)
        #expect(toR.smartChanges(for: qSouth).map(\.change).map(\.station?.name) == ["DeKalb Av"])
        // As does the R toward Bay Ridge for the Q
        let rSouth = Selection(stationID: "R20", routes: ["R"], direction: .south)
        #expect(sooner(Change(stationID: "R31", routes: ["Q"]), from: rSouth) == "DeKalb Av Q")
        // Lines across at Atlantic Av stay there, in the order the train gets to them
        let mixed = Change(stationID: "R31", routes: ["D", "N", "Q"], smartTransfer: true)
        #expect(mixed.smartChanges(for: rSouth).map(\.change).map(\.routes) == [["Q"], ["D", "N"]])
        #expect(mixed.stationNames(for: rSouth) == "DeKalb Av / Atlantic Av")
    }

    @Test func otherPlacesItHelps() {
        let myrtle = Selection(stationID: "M11", routes: ["M"], direction: .north)
        #expect(later(Change(stationID: "M18", routes: ["F"]), from: myrtle) == "Broadway-Lafayette St F")
        let bowlingGreen = Selection(stationID: "420", routes: ["4"], direction: .south)
        #expect(later(Change(stationID: "423", routes: ["2", "3"]), from: bowlingGreen) == "Nevins St 2,3")
        let atlanticQ = Selection(stationID: "D24", routes: ["Q"], direction: .north)
        // The R is across the platform a stop sooner, at DeKalb Av; the W (Manhattan only) after
        let toRW = Change(stationID: "Q01", routes: ["R", "W"])
        #expect(sooner(toRW, from: atlanticQ) == "DeKalb Av R")
        #expect(later(toRW, from: atlanticQ) == "14 St-Union Sq W")
        // The 7's next stop after Times Sq has no N or W
        let flushing = Selection(stationID: "702", routes: ["7"], direction: .south)
        #expect(later(Change(stationID: "725", routes: ["N", "W"]), from: flushing) == nil)
    }

    @Test func eachTrainTakesTheSoonestOfEitherStation() {
        let change = Change(stationID: "R31", routes: ["D", "N", "Q"], smartTransfer: true)
        let parts = change.smartChanges(for: prospect).map(\.change)
        let trains = [train("R", 2, trip: "r1", at: "R34N"), train("R", 6, trip: "r2", at: "R34N")]
        let atAtlantic = parts[0].connections(
            for: trains,
            atChange: [train("R", 10, trip: "r1", at: "R31N"), train("R", 14, trip: "r2", at: "R31N")],
            departures: [train("D", 11, trip: "d1", at: "R31N"), train("N", 20, trip: "n1", at: "R31N")],
            selection: prospect)
        let atDeKalb = parts[1].connections(
            for: trains,
            atChange: [train("R", 12, trip: "r1", at: "R30N"), train("R", 16, trip: "r2", at: "R30N")],
            departures: [train("Q", 13, trip: "q1", at: "R30N"), train("Q", 17, trip: "q2", at: "R30N")],
            selection: prospect)
        let best = Connection.best(of: [atAtlantic, atDeKalb], for: trains)
        #expect(best.map { $0.next?.trip } == ["d1", "q2"])
        #expect(best.map(\.stationID) == ["R31", "R30"])
        #expect(best.map { change.at($0).station?.name } == ["Atlantic Av-Barclays Ctr", "DeKalb Av"])
        #expect(best[1].walk == 0)
    }

    @Test func stationsAreComparedWhereTheTrainsPassTheChangeAsSaved() {
        // An R toward Bay Ridge: Q across at DeKalb Av, or D across at Atlantic Av
        let rSouth = Selection(stationID: "R20", routes: ["R"], direction: .south)
        let change = Change(stationID: "R31", routes: ["D", "Q"], smartTransfer: true)
        let parts = change.smartChanges(for: rSouth).map(\.change)
        #expect(parts.map(\.stationID) == ["R30", "R31"])
        let trains = [train("R", 2, trip: "r1", at: "R20S")]
        // The Q leaves DeKalb Av before the D leaves Atlantic Av, but reaches Atlantic Av after it
        let atDeKalb = parts[0].connections(for: trains, atChange: [train("R", 10, trip: "r1", at: "R30S")],
                                            departures: [train("Q", 11, trip: "q1", at: "R30S")], selection: rSouth)
        let atAtlantic = parts[1].connections(for: trains, atChange: [train("R", 12, trip: "r1", at: "R31S")],
                                              departures: [train("D", 12.5, trip: "d1", at: "R31S")], selection: rSouth)
        #expect(Connection.best(of: [atDeKalb, atAtlantic], for: trains).first?.next?.trip == "q1")
        let passing = ["q1": now.addingTimeInterval(13 * 60), "d1": now.addingTimeInterval(12.5 * 60)]
        #expect(Connection.best(of: [atDeKalb, atAtlantic], for: trains, passing: passing).first?.next?.trip == "d1")
    }

    @Test func eachOfYourLinesGetsItsOwn() {
        // South from 34 St-Herald Sq the D, N and Q reach Atlantic Av-Barclays Ctr from three
        // different stops. The D and N have the R across the platform there; the Q has it across
        // a stop sooner, at DeKalb Av
        let dnq = Selection(stationID: "D17", routes: ["D", "N", "Q"], direction: .south)
        let toR = Change(stationID: "235", routes: ["R"], smartTransfer: true)
        let parts = toR.smartChanges(for: dnq)
        #expect(parts.map(\.change.station?.name) == ["Atlantic Av-Barclays Ctr", "DeKalb Av"])
        #expect(parts.map(\.lines) == [["D", "N"], ["Q"]])
        #expect(toR.stationNames(for: dnq) == "Atlantic Av / DeKalb Av")
        #expect(toR.changesAtSeveral(for: dnq))
        // Off, one change for all of them
        var off = toR
        off.smartTransfer = false
        #expect(off.smartChanges(for: dnq).map(\.lines) == [["D", "N", "Q"]])
        #expect(!off.changesAtSeveral(for: dnq))

        // Each train is paired at its own line's station
        let trains = [train("D", 1, trip: "d1", at: "D17S"), train("Q", 2, trip: "q1", at: "R17S")]
        let options = parts.map { part in
            let line = dnq.only(part.lines)
            let theirs = trains.filter { part.lines.contains($0.route) }
            return part.change.connections(
                for: theirs,
                atChange: [train("D", 10, trip: "d1", at: "R31S"), train("Q", 9, trip: "q1", at: "R30S")],
                departures: [train("R", 11, trip: "r1", at: "R31S"), train("R", 10, trip: "r0", at: "R30S")]
                    .filter { part.change.departs($0, for: line) },
                selection: line)
        }
        let best = Connection.best(of: options, for: trains)
        #expect(best.map(\.first.trip) == ["d1", "q1"])
        #expect(best.map { $0.next?.trip } == ["r1", "r0"])
        #expect(best.map { toR.at($0).station?.name } == ["Atlantic Av-Barclays Ctr", "DeKalb Av"])
        #expect(best.map(\.walk) == [0, 0])
    }
}
