import Foundation
import Testing
@testable import TrainCore

/// The countdown's state from a fixture board, as the app and the server both
/// make it (Shared/Countdown.swift).
@Suite struct StateBuildingTests {
    let all = AppSettings()

    func minutes(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    @Test func stationDataLoadsFromTheResourceBundle() {
        #expect(StationDirectory.platforms.count > 400)
        #expect(!EquipmentDirectory.all.isEmpty)
        #expect(prospect.stopIDs == ["R34N"])
        #expect(prospect.trainID == "R34:N:R")
        #expect(Selection(stationID: "R31", routes: ["N", "R"], direction: .north).trainID == "R31:N:N,R")
    }

    @Test func startsWithTheFirstCatchableTrain() throws {
        let state = try #require(ContentState(for: prospect, board: fixtureBoard(), settings: all, now: now,
                                              following: nil, after: nil))
        #expect(state.train == minutes(2))
        #expect(state.trip == "a")
        #expect(state.isLive)
        #expect(state.terminal == "Forest Hills")
        #expect(state.route == "R")
        // The next two, whatever their line
        #expect(state.following == [minutes(6), minutes(9)])
        #expect(state.followingRoutes == ["R", "N"])
        #expect(state.updated == now)
        // Elevators aren't asked for; the alert is a service change
        #expect(state.notice == "Service change")
    }

    @Test func walkingTimeSkipsTrainsYouCantReach() throws {
        var selection = prospect
        selection.walkMinutes = 5
        let state = try #require(ContentState(for: selection, board: fixtureBoard(), settings: all, now: now,
                                              following: nil, after: nil))
        #expect(state.trip == "b")
        #expect(!state.isLive)
        #expect(state.following.count == 2)
    }

    @Test func startsOnATrainYouReachAsItGetsInNotOneYoudCatchOnlyWhileItsHeld() throws {
        // Due in 3 minutes and held till 6: with a 5-minute walk you'd still
        // catch it, but the countdown would move on from it as it got in
        var selection = prospect
        selection.walkMinutes = 5
        var held = arrival(3, trip: "held")
        held.departure = minutes(6)
        let board = Board(trains: [held, arrival(12, trip: "next"), arrival(20, trip: "later")], alerts: [], outages: [])
        #expect(selection.catchable(board.trains, now: now).first?.trip == "held")
        let state = try #require(ContentState(for: selection, board: board, settings: all, now: now,
                                              following: nil, after: nil))
        #expect(state.trip == "next")
        #expect(state.train == minutes(12))
        // So getting there at 5 minutes, it and the Lock Screen still agree
        #expect(state.movedOn(at: minutes(5)).train == minutes(12))
        #expect(state.refreshed(for: selection, board: board, settings: all, now: minutes(5)).trip == "next")
    }

    @Test func followsTheSameTripEvenIfItCantBeCaughtAnyMore() throws {
        var selection = prospect
        selection.walkMinutes = 5
        let state = try #require(ContentState(for: selection, board: fixtureBoard(), settings: all, now: now,
                                              following: "a", after: minutes(2)))
        #expect(state.trip == "a")
        #expect(state.following == [minutes(6), minutes(9)])
    }

    @Test func followsTheTrackedTripLaterOnTheBoard() throws {
        let state = try #require(ContentState(for: prospect, board: fixtureBoard(), settings: all, now: now,
                                              following: "c", after: minutes(9)))
        #expect(state.trip == "c")
        #expect(state.route == "N")
        #expect(state.terminal == "Astoria")
        #expect(state.following == [minutes(15)])
        #expect(state.followingRoutes == ["R"])
    }

    @Test func movesOnToTheNextTrainOnceTheTrackedOneHasGoneWithoutTakingOffTheWalkAgain() throws {
        // You set off when the countdown started: a, two minutes away, is still yours
        var selection = prospect
        selection.walkMinutes = 5
        let state = try #require(ContentState(for: selection, board: fixtureBoard(), settings: all, now: now,
                                              following: "gone", after: minutes(-1)))
        #expect(state.trip == "a")
        #expect(state.following == [minutes(6), minutes(9)])
    }

    @Test func aRefreshMovesOnToTheTrainTheLockScreenMovedOnTo() throws {
        var selection = prospect
        selection.walkMinutes = 5
        let started = try #require(ContentState(for: selection, board: fixtureBoard(), settings: all, now: now,
                                                following: nil, after: nil))
        #expect(started.trip == "b")
        // Seven minutes on, b has been and gone, and the Lock Screen has moved on to c by itself
        let later = minutes(7)
        var board = fixtureBoard()
        board.trains.removeAll { $0.time <= later }
        let shown = started.movedOn(at: later)
        #expect(shown.train == minutes(9))
        let refreshed = started.refreshed(for: selection, board: board, settings: all, now: later)
        #expect(refreshed.trip == "c")
        #expect(refreshed.train == shown.train)
        #expect(refreshed.following == [minutes(15)])
        #expect(refreshed.updated == later)
    }

    @Test func theTrackedTrainUnderANewTripIsntTakenForASoonerOne() throws {
        // Its trip id has changed, and it's 30 s sooner than it was: b, not a
        let state = try #require(ContentState(for: prospect, board: fixtureBoard(), settings: all, now: now,
                                              following: "b-old", after: minutes(6.5)))
        #expect(state.trip == "b")
    }

    @Test func aTrainWithoutATripIsFollowedByItsTime() throws {
        let state = try #require(ContentState(for: prospect, board: fixtureBoard(), settings: all, now: now,
                                              following: "", after: minutes(9)))
        #expect(state.trip == "c")
    }

    @Test func withNothingKnownOfTheTrackedTrainItsTheFirstYouCanCatch() throws {
        // As on the server before its first push: the app sends the trip, not its time
        var selection = prospect
        selection.walkMinutes = 5
        let state = try #require(ContentState(for: selection, board: fixtureBoard(), settings: all, now: now,
                                              following: "gone", after: nil))
        #expect(state.trip == "b")
    }

    @Test func noticeFollowsTheSelectionAndSettings() throws {
        var selection = prospect
        selection.elevatorAlerts = true
        let board = fixtureBoard()
        func notice(_ settings: AppSettings) -> String? {
            ContentState(for: selection, board: board, settings: settings, now: now, following: nil, after: nil)?.notice
        }
        #expect(notice(all) == "Elevator out")

        selection.elevatorAlerts = false
        var delaysOnly = AppSettings()
        delaysOnly.alertKinds = [.delays]
        #expect(notice(delaysOnly) == nil)

        selection.serviceAlerts = false
        #expect(notice(all) == nil)
    }

    @Test func nothingWithoutTrains() {
        var board = fixtureBoard()
        board.trains = [arrival(-1, trip: "gone")]
        #expect(ContentState(for: prospect, board: board, settings: all, now: now, following: "gone",
                             after: minutes(-1)) == nil)
        #expect(ContentState(for: prospect, board: board, settings: all, now: now, following: nil, after: nil) == nil)
    }

    @Test func noTrainsKeepsTheLastTrainAndSaysSo() {
        let last = state(train: -3)
        let later = minutes(1)
        var board = fixtureBoard()
        board.trains = []
        board.alerts = []
        let new = last.refreshed(for: prospect, board: board, settings: all, now: later)
        #expect(new.train == last.train)
        #expect(new.trip == last.trip)
        #expect(new.following.isEmpty)
        #expect(new.followingRoutes == [])
        #expect(new.notice == "No trains predicted")
        #expect(new.updated == later)
    }

    @Test func noTrainsNamesTheAlertThatsWhy() {
        var board = fixtureBoard()
        board.trains = []
        let new = state(train: -3).refreshed(for: prospect, board: board, settings: all, now: minutes(1))
        #expect(new.notice == "Service change")
    }

    @Test func noTrainsDoesntPutAnElevatorOutInPlaceOfWhy() {
        var selection = prospect
        selection.elevatorAlerts = true
        var board = fixtureBoard()
        board.trains = []
        let last = state(train: -3)
        #expect(last.refreshed(for: selection, board: board, settings: all, now: minutes(1)).notice == "Service change")

        board.alerts = []
        #expect(last.refreshed(for: selection, board: board, settings: all, now: minutes(1)).notice
                == "No trains predicted")
    }

    @Test func staleAsTheTrainIsDue() {
        let countdown = state(train: 4)
        #expect(countdown.staleDate == minutes(4))
        #expect(ActivityState.staleDate(for: countdown) == minutes(4))
    }

    @Test func movesOnByItselfToTheNextFollowingTrain() {
        let countdown = state(train: 2, following: [6, 9])
        #expect(countdown.movedOn(at: now) == countdown)
        let moved = countdown.movedOn(at: minutes(3))
        #expect(moved.train == minutes(6))
        #expect(moved.trip == "")
        #expect(moved.terminal == nil)
        #expect(moved.following == [minutes(9)])
        #expect(moved.followingRoutes == ["R"])
        // With none still to come, it stays as it is
        #expect(countdown.movedOn(at: minutes(10)) == countdown)
    }
}
