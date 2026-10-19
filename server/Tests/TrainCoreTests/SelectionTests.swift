import Foundation
import Testing
@testable import TrainCore

/// `Selection`: which trains it shows and can catch, and choices saved by older versions of the app.
@Suite struct SelectionTests {
    /// A `route` train at `stop`.
    func train(_ route: String, at stop: String) -> Arrival {
        Arrival(route: route, time: now, stop: stop, lastStop: "G08N", isLive: true)
    }

    @Test func showsItsLinesAndLinesRunningOnThem() {
        // Prospect Av has only the R
        #expect(prospect.shows(train("R", at: "R34N")))
        #expect(prospect.shows(train("N", at: "R34N")))
        #expect(prospect.shows(train("D", at: "R34N")))
    }

    @Test func leavesOutLinesThatUsuallyStopThereUnlessChosen() {
        // Atlantic Av-Barclays Ctr's D N R platform
        let atlantic = Selection(stationID: "R31", routes: ["R"], direction: .north)
        #expect(atlantic.stopIDs == ["R31N"])
        #expect(atlantic.shows(train("R", at: "R31N")))
        #expect(!atlantic.shows(train("D", at: "R31N")))
        #expect(!atlantic.shows(train("N", at: "R31N")))
        // The Q usually stops on another of the station's platforms, not this one
        #expect(atlantic.shows(train("Q", at: "R31N")))

        var both = atlantic
        both.routes = ["N", "R"]
        #expect(both.shows(train("N", at: "R31N")))
        #expect(!both.shows(train("D", at: "R31N")))
    }

    @Test func aTrainHeldAtThePlatformCanBeCaughtUntilItLeaves() {
        var held = arrival(-1, trip: "held")
        held.departure = now.addingTimeInterval(2 * 60)
        let next = arrival(5, trip: "next")
        #expect(prospect.catchable([arrival(-0.5, trip: "gone"), held, next], now: now) == [held, next])
        // Its leave time is still for when it gets there
        #expect(prospect.leaveTime(for: held) == held.time)
        #expect(prospect.lastLeaveTime(for: held) == held.departure)

        var walking = prospect
        walking.walkMinutes = 3
        // 3 minutes away, it's gone before you'd get there
        #expect(walking.catchable([held, next], now: now) == [next])
        // Due in a minute, but held until 4: there's still time
        var soon = arrival(1, trip: "soon")
        #expect(walking.catchable([soon], now: now).isEmpty)
        soon.departure = now.addingTimeInterval(4 * 60)
        #expect(walking.catchable([soon], now: now) == [soon])
        #expect(walking.catchable([soon], now: now.addingTimeInterval(60)).isEmpty)
    }

    @Test func connectionsAreCaughtByTheirTrainAtYourStation() {
        var held = arrival(-1, trip: "held")
        held.departure = now.addingTimeInterval(60)
        let connections = [arrival(-0.5, trip: "gone"), held, arrival(4, trip: "next")].map { train in
            Connection(first: train, arrival: arrival(10, trip: train.trip), next: nil)
        }
        #expect(prospect.catchable(connections, now: now).map(\.first.trip) == ["held", "next"])
    }

    @Test func aChoiceOfOneLineSavedBeforeThereCouldBeMore() throws {
        let json = #"{"stationID":"R34","route":"R","direction":"N"}"#
        let selection = try JSONDecoder().decode(Selection.self, from: Data(json.utf8))
        #expect(selection == prospect)
        #expect(selection.routes == ["R"])
        #expect(!selection.elevatorAlerts)
        #expect(selection.serviceAlerts)
        #expect(selection.walkMinutes == 0)
    }

    @Test func savesAsItLoads() throws {
        let selection = Selection(stationID: "R31", routes: ["N", "R"], direction: .south, elevatorAlerts: true,
                                  serviceAlerts: false, walkMinutes: 4)
        let data = try JSONEncoder().encode(selection)
        #expect(try JSONDecoder().decode(Selection.self, from: data) == selection)
        let keys = (try JSONSerialization.jsonObject(with: data) as? [String: Any]).map { Set($0.keys) }
        #expect(keys == ["stationID", "routes", "direction", "elevatorAlerts", "serviceAlerts", "walkMinutes"])
    }

    @Test func aChoiceWithNeitherLineNorLinesDoesntLoad() {
        let json = #"{"stationID":"R34","direction":"N"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Selection.self, from: Data(json.utf8)) }
    }
}
