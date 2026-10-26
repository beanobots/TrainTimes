import Foundation
import Testing
@testable import TrainCore

/// Choosing a train: one that isn't the app's own checked against the station
/// list, links made up by hand, and a saved widget's change when its train changes.
@Suite struct TrainChoiceTests {
    // MARK: Checking a train against the station list

    @Test func aTrainKeepsTheLinesItStillHas() throws {
        let lost = Selection(stationID: "R34", routes: ["R", "7"], direction: .north)
        #expect(lost.validatedIfKnown() == prospect)
        // A platform's id finds its station, whose id it takes
        let platform = try #require(Selection(stationID: "D24", routes: ["Q"], direction: .south).validatedIfKnown())
        #expect(platform.stationID == StationDirectory.station(id: "R31")?.id)
        #expect(platform.routes == ["Q"])
    }

    @Test func aTrainWithNoneOfItsLinesLeftIsNoTrain() {
        // Rather than Prospect Av's R, as for the app's own choice
        let gone = Selection(stationID: "R34", routes: ["7"], direction: .north)
        #expect(gone.validated() == .fallback)
        #expect(gone.validatedIfKnown() == nil)
        #expect(Selection(stationID: "XYZ", routes: ["R"], direction: .north).validatedIfKnown() == nil)
    }

    @Test func anyWalkWorksOutWhenToLeave() {
        let train = arrival(5, trip: "a")
        var far = prospect
        far.walkMinutes = .max
        #expect(far.leaveTime(for: train) < train.time)
        #expect(far.lastLeaveTime(for: train) < train.time)
        #expect(far.catchable([train], now: now).isEmpty)
    }

    @Test func aTrainsLinesAndWhereTheyGo() {
        #expect(prospect.caption == "R Manhattan")
        #expect(Selection(stationID: "R31", routes: ["N", "R"], direction: .north).caption == "N and R Manhattan")
    }

    // MARK: A change when its train changes

    /// Prospect Av's R toward Manhattan, changing at Atlantic Av for the D or N.
    func changingAtAtlantic() throws -> SavedWidget {
        let change = try #require(Change(stationID: "R31", routes: ["D", "N"]).validated(for: prospect))
        return SavedWidget(selection: prospect, change: change)
    }

    @Test func anotherStationOnTheWayKeepsTheChange() throws {
        var widget = try changingAtAtlantic()
        let change = widget.change
        let unionSt = Selection(stationID: "R32", routes: ["R"], direction: .north)
        widget.setSelection(unionSt)
        #expect(widget.selection == unionSt)
        #expect(widget.change == change)
        // Nor does a new walking time change it
        var walking = unionSt
        walking.walkMinutes = 5
        widget.setSelection(walking)
        #expect(widget.selection.walkMinutes == 5)
        #expect(widget.change == change)
    }

    @Test func aStationPastTheChangeLosesIt() throws {
        var widget = try changingAtAtlantic()
        widget.setSelection(Selection(stationID: "R30", routes: ["R"], direction: .north))
        #expect(widget.change == nil)
    }

    @Test func anotherLineOrDirectionLosesTheChange() throws {
        var widget = try changingAtAtlantic()
        var south = prospect
        south.direction = .south
        widget.setSelection(south)
        #expect(widget.selection == south)
        #expect(widget.change == nil)

        widget = try changingAtAtlantic()
        widget.setSelection(Selection(stationID: "R36", routes: ["N", "R"], direction: .north))
        #expect(widget.change == nil)
    }

    @Test func theSameTrainKeepsItsChangeAsItIs() throws {
        var widget = SavedWidget(selection: prospect, change: Change(stationID: "R31", routes: ["R", "N"]))
        widget.setSelection(prospect)
        #expect(widget.change == Change(stationID: "R31", routes: ["R", "N"]))
    }

    @Test func commutingHoursKeepOrLoseTheirChangeTheSameWay() throws {
        let change = try #require(Change(stationID: "R31", routes: ["D", "N"]).validated(for: prospect))
        var hours = CommutingHours(selection: prospect, change: change)
        hours.setSelection(Selection(stationID: "R33", routes: ["R"], direction: .north))
        #expect(hours.change == change)
        var south = hours.selection
        south.direction = .south
        hours.setSelection(south)
        #expect(hours.selection == south)
        #expect(hours.change == nil)
    }
}
