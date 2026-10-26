import Foundation
import Testing
@testable import TrainCore

/// `StationDirectory.branches(of:)` and what goes by it: lines.json lists each line's stops in
/// one list, the A's three branches one after another.
@Suite struct BranchesTests {
    func ids(_ ids: String...) -> Set<String> { Set(ids) }

    @Test func theAsThreeBranchesShareItsStopsUpToWhereTheyPart() {
        let branches = StationDirectory.branches(of: "A")
        #expect(branches.map(\.last) == ["A65", "H15", "H11"])
        #expect(branches.allSatisfy { $0.first == "A02" })
        // Lefferts Blvd's after Rockaway Blvd; Rockaway Park's and Far Rockaway's after Broad Channel
        #expect(branches[0].suffix(4) == ["A61", "A63", "A64", "A65"])
        #expect(branches[1].suffix(9) == ["A61", "H01", "H02", "H03", "H04", "H12", "H13", "H14", "H15"])
        #expect(branches[2].suffix(7) == ["H04", "H06", "H07", "H08", "H09", "H10", "H11"])
        #expect(!branches[2].contains("H12"))
        // A line without branches is its own stops whole
        #expect(StationDirectory.branches(of: "R") == [StationDirectory.stops(of: "R")])
        #expect(StationDirectory.branches(of: "H") == [["H04", "H12", "H13", "H14", "H15"]])
    }

    @Test func aLinesOwnStopsLeaveOutOtherShuttles() {
        #expect(StationDirectory.stops(of: "FS") == ["S01", "S03", "S04", "D26"])
        #expect(StationDirectory.stops(of: "GS") == ["902", "901"])
        #expect(StationDirectory.stops(of: "nothing").isEmpty)
    }

    @Test func noWayBetweenTwoBranches() {
        // Beach 90 St to Beach 67 St: Rockaway Park's branch and Far Rockaway's
        #expect(StationDirectory.direction(of: "A", from: ids("H12"), to: ids("H06")) == nil)
        #expect(StationDirectory.direction(of: "A", from: ids("A64"), to: ids("H01")) == nil)
        #expect(StationDirectory.direction(of: "A", from: ids("H12"), to: ids("H15")) == .south)
        #expect(StationDirectory.direction(of: "A", from: ids("H06"), to: ids("H04")) == .north)
        #expect(StationDirectory.direction(of: "A", from: ids("A61"), to: ids("H01")) == .south)
        #expect(StationDirectory.direction(of: "A", from: ids("H11"), to: ids("A02")) == .north)
        #expect(StationDirectory.direction(of: "A", from: ids("A61"), to: ids("A61")) == nil)
    }

    @Test func theStopsAheadFollowEachBranchFromHere() {
        let south = StationDirectory.stops(of: "A", from: ids("H12"), going: .south)
        #expect(south == ["H13", "H14", "H15"])
        let north = StationDirectory.stops(of: "A", from: ids("H06"), going: .north)
        #expect(north.prefix(3) == ["H04", "H03", "H02"])
        #expect(north.last == "A02")
        // From where they part, every branch's
        let parting = StationDirectory.stops(of: "A", from: ids("A61"), going: .south)
        #expect(Set(parting) == Set(["A63", "A64", "A65", "H01", "H02", "H03", "H04", "H12", "H13", "H14", "H15",
                                     "H06", "H07", "H08", "H09", "H10", "H11"]))
        #expect(parting.count == Set(parting).count)
    }

    @Test func theNextStopIsNoneWhereBranchesPart() {
        #expect(StationDirectory.nextStop(of: "A", from: ids("A61"), going: .south) == nil)
        #expect(StationDirectory.nextStop(of: "A", from: ids("H01"), going: .north) == "A61")
        #expect(StationDirectory.nextStop(of: "A", from: ids("H06"), going: .north) == "H04")
        #expect(StationDirectory.nextStop(of: "A", from: ids("H12"), going: .north) == "H04")
        #expect(StationDirectory.nextStop(of: "A", from: ids("H15"), going: .south) == nil)
        #expect(StationDirectory.nextStop(of: "R", from: ids("R31"), going: .south) == "R32")
    }

    @Test func aPlaceOnAnotherBranchIsNoWayFromHere() {
        #expect(StationDirectory.goes("A", going: .south, from: "H12", toward: "Rockaway Park"))
        #expect(!StationDirectory.goes("A", going: .south, from: "H12", toward: "Far Rockaway"))
        #expect(StationDirectory.goes("A", going: .south, from: "H04", toward: "Far Rockaway"))
        #expect(StationDirectory.direction(toward: "Far Rockaway-Mott Av", on: "A", from: ["H12"]) == nil)
        #expect(StationDirectory.direction(toward: "Far Rockaway-Mott Av", on: "A", from: ["H04"]) == .south)
    }
}
