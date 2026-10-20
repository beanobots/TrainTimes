import Foundation
import Testing
@testable import TrainCore

@Suite struct ChangeDetectionTests {
    let last = state(train: 5)
    let pushed = now.addingTimeInterval(-60)

    func decision(_ new: ContentState, at time: Date = now) -> ActivityState.Push {
        ActivityState.push(new, last: last, lastPush: pushed, now: time)
    }

    @Test func firstPushAlwaysGoes() {
        #expect(ActivityState.push(last, last: nil, lastPush: nil, now: now) == .update)
    }

    @Test func trainTimeMovingUnder30sIsNotEnough() {
        #expect(decision(state(train: 5 + 29.0 / 60)) == .none)
        #expect(decision(state(train: 5 - 29.0 / 60)) == .none)
    }

    @Test func trainTimeMoving30sOrMoreIsAnUpdate() {
        #expect(decision(state(train: 5.5)) == .update)
        #expect(decision(state(train: 4.5)) == .update)
    }

    @Test func anotherTrainIsAnUpdate() {
        #expect(decision(state(train: 5, trip: "b")) == .update)
        var rerouted = last
        rerouted.terminal = "Astoria"
        #expect(decision(rerouted) == .update)
    }

    @Test func followingTrainsMustMoveAMinute() {
        #expect(decision(state(train: 5, following: [6 + 59.0 / 60, 9])) == .none)
        #expect(decision(state(train: 5, following: [6, 10])) == .update)
        #expect(decision(state(train: 5, following: [6])) == .update)
        var otherLine = last
        otherLine.followingRoutes = ["R", "N"]
        #expect(decision(otherLine) == .update)
    }

    @Test func noticeOrLivenessChangingIsAnUpdate() {
        #expect(decision(state(train: 5, notice: "Delays")) == .update)
        #expect(decision(state(train: 5, isLive: false)) == .update)
    }

    @Test func updatedAloneIsNotAnUpdate() {
        var new = last
        new.updated = now.addingTimeInterval(100)
        #expect(decision(new) == .none)
    }

    @Test func lowPriorityRefreshAfterFiveMinutes() {
        #expect(decision(last, at: pushed.addingTimeInterval(299)) == .none)
        #expect(decision(last, at: pushed.addingTimeInterval(300)) == .refresh)
        // Something meaningful still goes at priority 10
        #expect(decision(state(train: 7), at: pushed.addingTimeInterval(300)) == .update)
    }

    /// The notice of a countdown that said `last`, made new as `new` from a
    /// board with or without trains, alerts and outages.
    func notice(_ last: String?, _ new: String?, trains: Bool = true, alerts: Bool = true, outages: Bool = true,
                asksForAlerts: Bool = true) -> String? {
        let selection = Selection(stationID: "R34", routes: ["R"], direction: .north, elevatorAlerts: true,
                                  serviceAlerts: asksForAlerts)
        let board = Board(trains: trains ? fixtureBoard().trains : [], alerts: alerts ? [] : nil,
                          outages: outages ? [] : nil)
        return ActivityState.keepingNotice(of: state(train: 5, notice: last), in: state(train: 5, notice: new),
                                           board: board, selection: selection, now: now).notice
    }

    @Test func anAlertStaysWhileTheAlertsCantBeHad() {
        #expect(notice("Delays", nil, alerts: false) == "Delays")
        #expect(notice("Suspended", nil, alerts: false, outages: false) == "Suspended")
        // With no trains, it's the alert that would be named
        #expect(notice("Suspended", ActivityState.noTrains, trains: false, alerts: false) == "Suspended")
        // But not once it's known to be over, or an elevator out comes before it
        #expect(notice("Delays", nil) == nil)
        #expect(notice("Delays", "Service change") == "Service change")
        #expect(notice("Delays", nil, outages: false) == nil)
        #expect(notice("Delays", "Elevator out", alerts: false) == "Elevator out")
        // Nor where none were asked for
        #expect(notice("Delays", nil, alerts: false, asksForAlerts: false) == nil)
    }

    @Test func anElevatorOutStaysWhileTheOutagesCantBeHad() {
        #expect(notice("Elevator out", nil, outages: false) == "Elevator out")
        #expect(notice("2 elevators out", "Delays", outages: false) == "2 elevators out")
        #expect(notice("Elevator out", nil, alerts: false, outages: false) == "Elevator out")
        // But not once it's back, nor with the trains gone, when it isn't named
        #expect(notice("Elevator out", nil) == nil)
        #expect(notice("Elevator out", nil, alerts: false) == nil)
        #expect(notice("Elevator out", ActivityState.noTrains, trains: false, outages: false) == ActivityState.noTrains)
        #expect(notice("Elevator out", "Suspended", trains: false, outages: false) == "Suspended")
    }

    @Test func neitherNoTrainsNorNothingStays() {
        // The trains are back, whatever else the board can't say
        #expect(notice(ActivityState.noTrains, nil, alerts: false, outages: false) == nil)
        #expect(notice(ActivityState.noTrains, "Elevator out", alerts: false) == "Elevator out")
        #expect(notice(nil, "Delays", outages: false) == "Delays")
    }
}
