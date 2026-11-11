import Foundation
import Testing
@testable import TrainCore

/// A change's second change (`Change.then`), as saved routes keep it.
struct SecondChangeTests {
    private func roundTrip(_ change: Change) throws -> Change {
        try JSONDecoder().decode(Change.self, from: try JSONEncoder().encode(change))
    }

    @Test func aSecondChangeIsKeptWithEachStation() throws {
        let then = Change(stationID: "127", routes: ["GS"], direction: .north)
        var change = try #require(Change(stops: [
            Change(stationID: "R30", routes: ["Q"], direction: .north, then: then),
            Change(stationID: "R31", routes: ["4", "5"], direction: .north),
        ]))
        change.destinationID = "631"
        let loaded = try roundTrip(change)
        #expect(loaded == change)
        #expect(loaded.stops[0].then == then)
        #expect(loaded.stops[1].then == nil)
        #expect(loaded.changesTwice)
        #expect(loaded.everyRoute.contains("GS"))
    }

    @Test func aChangeSavedBeforeSecondChangesLoadsWithNone() throws {
        let json = #"{"stationID":"R30","routes":["Q"],"quickMinutes":2,"walkMinutes":3,"smartTransfer":false,"alternatives":[{"stationID":"R31","routes":["N"]}]}"#
        let change = try JSONDecoder().decode(Change.self, from: Data(json.utf8))
        #expect(change.then == nil)
        #expect(change.alternatives.first?.then == nil)
        #expect(!change.changesTwice)
    }

    @Test func aChangeWithoutOneSavesAsBefore() throws {
        let data = try JSONEncoder().encode(Change(stationID: "R30", routes: ["Q"]))
        #expect(!String(decoding: data, as: UTF8.self).contains("then"))
    }

    @Test func theSecondChangeTellsChangesApart() {
        let plain = Change(stationID: "R30", routes: ["Q"])
        var twice = plain
        twice.then = Change(stationID: "127", routes: ["GS"])
        #expect(plain.key != twice.key)
    }
}

/// A route planned From and To (`PlannedTrip`), every ride a train or a bus.
struct PlannedTripTests {
    private let stop = BusStop(id: "308204", name: "5 AV/9 ST", latitude: 40.67, longitude: -73.98)

    private var trip: PlannedTrip {
        let bus = PlannedRide(bus: BusLeg(line: "B63", stop: stop, destination: "PIER 6", walkMinutes: 0))
        let train = PlannedRide(train: Selection(stationID: "R33", routes: ["R"], direction: .north), walkMinutes: 5,
                                offStop: BusStop(id: "308201", name: "5 AV/7 ST", latitude: 40.67, longitude: -73.98))
        let onward = PlannedRide(train: Selection(stationID: "D24", routes: ["N"], direction: .north), offStationID: "R31")
        return PlannedTrip(ways: [PlannedWay(rides: [[bus], [train], [onward]], endStationID: "127")], destinationID: "127")
    }

    @Test func aPlannedTripIsKeptByItsBus() throws {
        var choice = BusChoice(line: "B63", stop: stop)
        choice.planned = trip
        let widget = SavedWidget(selection: .fallback, destinationID: "127", kind: .bus, bus: choice)
        let loaded = try JSONDecoder().decode(SavedWidget.self, from: JSONEncoder().encode(widget))
        #expect(loaded == widget)
        #expect(loaded.trip == trip)
        #expect(loaded.trip?.ways[0].rides.map { $0[0].routes } == [["bus:B63"], ["R"], ["N"]])
    }

    @Test func aPlannedTripIsKeptByItsChangeAndNotValidatedAway() throws {
        var change = Change(stationID: "R33", routes: [])
        change.planned = trip
        // No lines to change to, which would drop a change picked by hand
        #expect(change.validated(for: Selection(stationID: "R33", routes: ["R"], direction: .north)) == change)
        let loaded = try JSONDecoder().decode(Change.self, from: JSONEncoder().encode(change))
        #expect(loaded.planned == trip)
        #expect(change.key != Change(stationID: "R33", routes: []).key)
    }

    @Test func aChangeSavedBeforeTripsHasNone() throws {
        let json = #"{"stationID":"R30","routes":["Q"],"quickMinutes":2,"walkMinutes":3,"smartTransfer":false}"#
        #expect(try JSONDecoder().decode(Change.self, from: Data(json.utf8)).planned == nil)
    }
}
