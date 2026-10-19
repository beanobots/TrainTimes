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
}
