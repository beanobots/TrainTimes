import Foundation
import Testing
@testable import TrainCore

/// What stations.json knows of an entrance for walking to and from a train: its streets and
/// corner, the side its stairs go to where a platform's sides aren't joined, and which part of
/// the train stops by it (make_stations.py).
@Suite struct StationEntrancesTests {
    func platform(_ id: String) throws -> Platform {
        try #require(StationDirectory.platform(forStop: id))
    }

    @Test func anEntranceIsNamedByItsCorner() throws {
        let ninth = try platform("R33").entrances
        #expect(ninth.compactMap(\.address).contains("NW corner of 4 Av & 9 St"))
        #expect(ninth.compactMap(\.address).contains("NE corner of 4 Av & 9 St"))
    }

    /// At 23 St on the 6 the Downtown platform is under Park Av's west side, the Uptown one its
    /// east: trains keep right.
    @Test func stairsGoToTheirSideWhereTheSidesArentJoined() throws {
        let station = try platform("634")
        #expect(station.noCrossover == true)
        let downtown = station.entrances.filter { $0.side == .south }
        let uptown = station.entrances.filter { $0.side == .north }
        #expect(!downtown.isEmpty && !uptown.isEmpty)
        #expect(downtown.allSatisfy { $0.corner?.hasSuffix("W") != false })
        #expect(uptown.allSatisfy { $0.corner?.hasSuffix("E") != false })
        // 4 Av-9 St's R platforms are joined, so its stairs say nothing of a side
        #expect(try platform("R33").noCrossover == nil)
        #expect(try platform("R33").entrances.allSatisfy { $0.side == nil })
    }

    /// At 1 Av on the L, the 1 Av stairs are at the west end and Avenue A's at the east: the back
    /// of a train to Brooklyn, and the front.
    @Test func theTrainsPartByAnEntranceFollowsItsWay() throws {
        let first = try platform("L06")
        let west = try #require(first.entrances.first { $0.streets == ["1 Av", "14 St"] })
        let east = try #require(first.entrances.first { $0.streets == nil && ($0.along ?? 0) > 60 })
        #expect(first.part(of: "L", going: .south, by: west) == .back)
        #expect(first.part(of: "L", going: .south, by: east) == .front)
        #expect(first.part(of: "L", going: .north, by: west) == .front)
        #expect(first.part(of: "L", going: .north, by: east) == .back)
    }

    @Test func shortTrainsGiveNoPart() throws {
        let hoyt = try platform("A42")
        let entrance = try #require(hoyt.entrances.first { $0.along != nil })
        #expect(hoyt.part(of: "G", going: .north, by: entrance) == nil)
    }

    /// A complex's shared entrances are listed under each platform, each with its own `along`;
    /// the station lists each once.
    @Test func aStationListsEachEntranceOnce() throws {
        let atlantic = try #require(StationDirectory.station(id: "R31"))
        let places = atlantic.platforms.flatMap(\.entrances).map(\.place)
        #expect(atlantic.entrances.count == Set(places).count)
    }
}
