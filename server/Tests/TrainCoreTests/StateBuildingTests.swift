import Foundation
import Testing
@testable import TrainCore

/// `ActivityState.state(...)` against a fixture board, as the app's
/// `TrainActivityController.state(for:board:now:following:)` behaves.
@Suite struct StateBuildingTests {
    let all = AppSettings()

    @Test func stationDataLoadsFromTheResourceBundle() {
        #expect(StationDirectory.platforms.count > 400)
        #expect(!EquipmentDirectory.all.isEmpty)
        #expect(prospect.stopIDs == ["R34N"])
        #expect(prospect.trainID == "R34:N:R")
    }

    @Test func startsWithTheFirstCatchableTrain() throws {
        let state = try #require(ActivityState.state(for: prospect, board: fixtureBoard(), now: now, following: nil, settings: all))
        #expect(state.train == now.addingTimeInterval(120))
        #expect(state.trip == "a")
        #expect(state.isLive)
        #expect(state.terminal == "Forest Hills")
        #expect(state.route == "R")
        // The next two, whatever their line
        #expect(state.following == [now.addingTimeInterval(360), now.addingTimeInterval(540)])
        #expect(state.followingRoutes == ["R", "N"])
        #expect(state.updated == now)
        // Elevators aren't asked for; the alert is a service change
        #expect(state.notice == "Service change")
    }

    @Test func walkingTimeSkipsTrainsYouCantReach() throws {
        var selection = prospect
        selection.walkMinutes = 5
        let state = try #require(ActivityState.state(for: selection, board: fixtureBoard(), now: now, following: "", settings: all))
        #expect(state.trip == "b")
        #expect(!state.isLive)
        #expect(state.following.count == 2)
    }

    @Test func followsTheSameTripEvenIfItCantBeCaughtAnyMore() throws {
        var selection = prospect
        selection.walkMinutes = 5
        let state = try #require(ActivityState.state(for: selection, board: fixtureBoard(), now: now, following: "a", settings: all))
        #expect(state.trip == "a")
        #expect(state.following == [now.addingTimeInterval(360), now.addingTimeInterval(540)])
    }

    @Test func followsTheTrackedTripLaterOnTheBoard() throws {
        let state = try #require(ActivityState.state(for: prospect, board: fixtureBoard(), now: now, following: "c", settings: all))
        #expect(state.trip == "c")
        #expect(state.route == "N")
        #expect(state.terminal == "Astoria")
        #expect(state.following == [now.addingTimeInterval(900)])
        #expect(state.followingRoutes == ["R"])
    }

    @Test func movesOnToTheNextCatchableOnceTheTrackedTrainHasGone() throws {
        let state = try #require(ActivityState.state(for: prospect, board: fixtureBoard(), now: now, following: "gone", settings: all))
        #expect(state.trip == "a")
    }

    @Test func noticeFollowsTheSelectionAndSettings() throws {
        var selection = prospect
        selection.elevatorAlerts = true
        let board = fixtureBoard()
        #expect(ActivityState.state(for: selection, board: board, now: now, following: nil, settings: all)?.notice == "Elevator out")

        selection.elevatorAlerts = false
        var delaysOnly = AppSettings()
        delaysOnly.alertKinds = [.delays]
        #expect(ActivityState.state(for: selection, board: board, now: now, following: nil, settings: delaysOnly)?.notice == nil)

        selection.serviceAlerts = false
        #expect(ActivityState.state(for: selection, board: board, now: now, following: nil, settings: all)?.notice == nil)
    }

    @Test func nothingWithoutTrains() {
        var board = fixtureBoard()
        board.trains = [arrival(-1, trip: "gone")]
        #expect(ActivityState.state(for: prospect, board: board, now: now, following: "gone", settings: all) == nil)
    }

    @Test func noTrainsKeepsTheLastTrainAndSaysSo() {
        let last = state(train: -3)
        let later = now.addingTimeInterval(60)
        let new = ActivityState.noTrains(from: last, now: later)
        #expect(new.train == last.train)
        #expect(new.trip == last.trip)
        #expect(new.following.isEmpty)
        #expect(new.notice == "No trains predicted")
        #expect(new.updated == later)
    }

    @Test func staleTwoMinutesAfterTheTrain() {
        #expect(ActivityState.staleDate(for: state(train: 4)) == now.addingTimeInterval(6 * 60))
    }
}
