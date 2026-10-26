import Foundation
import Testing
@testable import TrainCore

/// `Change.alternatives`: other stations to change at, each for the lines that call there, and
/// `Change.suggestions(for:)` offering more.
@Suite struct MultipleChangesTests {
    let herald = "D17"

    @Test func eachStationIsForTheLinesThatCallThere() {
        // South from 34 St-Herald Sq to the R: all three reach Atlantic Av, only the Q DeKalb Av
        let dnq = Selection(stationID: "D17", routes: ["D", "N", "Q"], direction: .south)
        let toR = Change(stationID: "235", routes: ["R"], alternatives: [Change.Stop(stationID: "R30", routes: ["R"])])
        let parts = toR.smartChanges(for: dnq)
        #expect(parts.map(\.change.station?.name) == ["Atlantic Av-Barclays Ctr", "DeKalb Av"])
        #expect(parts.map(\.lines) == [["D", "N", "Q"], ["Q"]])
        #expect(toR.stationNames(for: dnq) == "Atlantic Av / DeKalb Av")
        #expect(toR.changesAtSeveral(for: dnq))
        #expect(toR.allRoutes == ["R"])
    }

    @Test func theStationsShareTheWalkAndDestination() {
        let change = Change(stationID: "R31", routes: ["D", "N"], walkMinutes: 5, destinationID: herald,
                            alternatives: [Change.Stop(stationID: "R30", routes: ["Q"])])
        #expect(change.stops.map(\.stationID) == ["R31", "R30"])
        #expect(change.stops.map(\.walkMinutes) == [5, 5])
        #expect(change.stops.map(\.destinationID) == [herald, herald])
        #expect(change.stops.allSatisfy { $0.alternatives.isEmpty })
        #expect(change.allRoutes == ["D", "N", "Q"])
        #expect(Change(stops: change.stops) == change)
        #expect(Change(stops: []) == nil)
        #expect(change.key != change.stops[0].key)
    }

    @Test func savesAsItLoads() throws {
        let change = Change(stationID: "R31", routes: ["D", "N"],
                            alternatives: [Change.Stop(stationID: "R30", routes: ["Q"], direction: .north)])
        let data = try JSONEncoder().encode(change)
        #expect(try JSONDecoder().decode(Change.self, from: data) == change)
    }

    @Test func aSmartTransferIsWrittenOut() throws {
        let smart = Change(stationID: "R31", routes: ["D", "N", "Q"], smartTransfer: true)
        let written = try #require(smart.validated(for: prospect))
        #expect(!written.smartTransfer)
        #expect(written.stops.map(\.station?.name) == ["Atlantic Av-Barclays Ctr", "DeKalb Av"])
        #expect(written.stops.map(\.routes) == [["D", "N"], ["Q"]])
        // Paired just as before
        #expect(written.smartChanges(for: prospect).map(\.change.station?.name)
                == smart.smartChanges(for: prospect).map(\.change.station?.name))
    }

    @Test func stationsNoLongerAheadAreDropped() throws {
        // 36 St is behind Prospect Av toward Manhattan, so Atlantic Av becomes the change
        let change = Change(stationID: "R36", routes: ["D", "N"], walkMinutes: 4,
                            alternatives: [Change.Stop(stationID: "R31", routes: ["D", "N"])])
        let kept = try #require(change.validated(for: prospect))
        #expect(kept.station?.name == "Atlantic Av-Barclays Ctr")
        #expect(kept.alternatives.isEmpty)
        #expect(kept.walkMinutes == 4)
        #expect(Change(stationID: "R36", routes: ["D"]).validated(for: prospect) == nil)
    }

    @Test func suggestsLinesToTheDestinationAcrossTheNextStop() throws {
        let change = Change(stationID: "R31", routes: ["D", "N"], destinationID: herald)
        let suggestions = change.suggestions(for: prospect)
        let deKalb = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(deKalb.change.station?.name == "DeKalb Av")
        #expect(deKalb.change.routes.contains("Q"))
        #expect(deKalb.besides.stationID == "R31")
        #expect(!deKalb.sooner)
        // Once added, nothing more there
        var added = change
        added.alternatives = [Change.Stop(stationID: deKalb.change.stationID, routes: deKalb.change.routes)]
        #expect(added.suggestions(for: prospect).isEmpty)
    }

    @Test func withoutADestinationSuggestsWhereAWalkIsAcross() {
        // The Q is a walk at Atlantic Av, across the platform at DeKalb Av
        let change = Change(stationID: "R31", routes: ["D", "N", "Q"])
        #expect(change.suggestions(for: prospect).map { "\($0.change.station?.name ?? "") \($0.change.routes)" }
                == ["DeKalb Av [\"Q\"]"])
        // The D and N are across at Atlantic Av already
        #expect(Change(stationID: "R31", routes: ["D", "N"]).suggestions(for: prospect).isEmpty)
    }
}
