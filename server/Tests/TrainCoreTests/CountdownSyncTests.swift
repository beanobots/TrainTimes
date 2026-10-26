import Foundation
import Testing
@testable import TrainCore

/// How a widget for the countdown's train takes the countdown's times
/// (Shared/CountdownSync.swift), so the two always agree.
@Suite struct CountdownSyncTests {
    func time(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    func times(_ trains: [Arrival]) -> [Date] { trains.map(\.time) }

    @Test func theCountdownsTimesReplaceTheBoardsForTheSameTrains() {
        // The widget fetched a little earlier: each train a bit off the countdown's
        let board = [arrival(2.5, trip: "a"), arrival(6.5, trip: "b"), arrival(8, trip: "c"), arrival(15, trip: "d")]
        let aligned = CountdownSync.aligned(board, to: state(train: 2, following: [6, 9]), selection: prospect, now: now)
        #expect(times(aligned.trains) == [time(2), time(6), time(9), time(15)])
        // Each keeps what the board knows of it
        #expect(aligned.trains.map(\.trip) == ["a", "b", "c", "d"])
    }

    @Test func theFirstTrainIsFoundByItsTripEvenIfItMovedFar() {
        let board = [arrival(2, trip: "x"), arrival(8, trip: "a")]
        let aligned = CountdownSync.aligned(board, to: state(train: 4, following: []), selection: prospect, now: now)
        #expect(aligned.trains.first { $0.trip == "a" }?.time == time(4))
        // The other is before the countdown's train, so kept: too soon for the countdown's walk
        #expect(times(aligned.trains) == [time(2), time(4)])
    }

    @Test func trainsTheCountdownDoesntHaveBetweenItsOwnAreLeftOut() {
        let board = [arrival(2, trip: "a"), arrival(4, trip: "extra"), arrival(6, trip: "b"), arrival(9, trip: "c")]
        let aligned = CountdownSync.aligned(board, to: state(train: 2, following: [6, 9]), selection: prospect, now: now)
        #expect(times(aligned.trains) == [time(2), time(6), time(9)])
    }

    @Test func aTrainTheBoardLacksIsAddedFromTheCountdown() {
        let board = [arrival(2, trip: "a"), arrival(15, trip: "d")]
        let aligned = CountdownSync.aligned(board, to: state(train: 2, following: [6]), selection: prospect, now: now)
        #expect(times(aligned.trains) == [time(2), time(6), time(15)])
        let added = aligned.trains[1]
        #expect(added.route == "R" && added.stop == prospect.stopIDs.first)
    }

    @Test func onlyTheSameLineMatchesAFollowingTrain() {
        // An N 30 s from the countdown's following R isn't it
        let board = [arrival(2, trip: "a"), arrival(6.5, trip: "n", route: "N"), arrival(8, trip: "b"), arrival(9, trip: "c")]
        let aligned = CountdownSync.aligned(board, to: state(train: 2, following: [6, 9]), selection: prospect, now: now)
        #expect(aligned.trains.first { $0.trip == "b" }?.time == time(6))
        // And, between the countdown's trains, it's left out
        #expect(!aligned.trains.contains { $0.trip == "n" })
    }

    @Test func itMovesOnAsTheLockScreenDoes() {
        // The countdown's train has come: its following one is the first now
        let board = [arrival(-1, trip: "a"), arrival(5.5, trip: "b"), arrival(9, trip: "c")]
        let aligned = CountdownSync.aligned(board, to: state(train: -1, following: [6, 9]), selection: prospect, now: now)
        #expect(times(aligned.trains) == [time(-1), time(6), time(9)])
    }

    @Test func onceTheCountdownsTrainsHaveComeTheBoardStands() {
        let board = [arrival(-1, trip: "a"), arrival(5, trip: "b")]
        let aligned = CountdownSync.aligned(board, to: state(train: -1, following: []), selection: prospect, now: now)
        #expect(aligned.trains == board)
    }

    @Test func aHeldTrainKeepsItsWait() {
        var held = arrival(2.5, trip: "a")
        held.departure = time(4.5)
        let aligned = CountdownSync.aligned([held], to: state(train: 2, following: []), selection: prospect, now: now)
        #expect(aligned.trains.first?.departure == time(4))
    }

    @Test func theCountdownsLivenessIsShownForItsTrain() {
        let board = [arrival(2.5, trip: "a", isLive: false)]
        let aligned = CountdownSync.aligned(board, to: state(train: 2, following: [], isLive: true), selection: prospect, now: now)
        #expect(aligned.trains.first?.isLive == true)
    }

    @Test func connectionsFollowTheirFirstTrain() {
        let a = arrival(2.5, trip: "a")
        let extra = arrival(4, trip: "extra")
        let b = arrival(6, trip: "b")
        let atChange = Arrival(route: "R", time: time(10.5), stop: "R20N", lastStop: "G08N", isLive: true, trip: "a")
        let connections = [Connection(first: a, arrival: atChange, next: nil),
                           Connection(first: extra, arrival: atChange, next: nil),
                           Connection(first: b, arrival: atChange, next: nil)]
        let aligned = CountdownSync.aligned([a, extra, b], to: state(train: 2, following: [6]), selection: prospect, now: now)
        let shown = aligned.connections(connections)
        #expect(shown.map(\.first.time) == [time(2), time(6)])
        // Its arrival at the change moves with it
        #expect(shown.first?.arrival.time == time(10))
    }
}
