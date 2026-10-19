import Foundation
import Testing
@testable import TrainCore

/// Which trains a board lists, as `TrainService` picks them for the app, the
/// widgets and the push server's countdowns alike.
@Suite struct BoardTrainsTests {
    let nqrw = Lines.feedURLs(sharingTracksWith: ["R"]).own[0]
    let bdfm = Lines.feedURLs(sharingTracksWith: ["D"]).own[0]
    /// 4 Av-9 St, the stop after Prospect Av toward Manhattan.
    let fourthAv = Selection(stationID: "R33", routes: ["R"], direction: .north)

    func time(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    /// A train `minutes` from now at `stop`.
    func train(_ minutes: Double, trip: String, at stop: String, route: String = "R") -> Arrival {
        Arrival(route: route, time: time(minutes), stop: stop, lastStop: "G08N", isLive: true, trip: trip)
    }

    @Test func trainsThatEndHereAreLeftOut() {
        let trains = TrainService.trains(for: prospect, in: [
            arrival(2, trip: "ends", lastStop: "R34N"),
            arrival(4, trip: "goes"),
        ], now: now)
        #expect(trains.map(\.trip) == ["goes"])
    }

    @Test func aTrainHeldAtThePlatformStaysUntilItLeaves() {
        var held = arrival(-1, trip: "held")
        held.departure = time(0.5)
        let trains = TrainService.trains(for: prospect, in: [arrival(-0.5, trip: "gone"), held, arrival(3, trip: "next")],
                                         now: now)
        #expect(trains.map(\.trip) == ["held", "next"])
        #expect(TrainService.trains(for: prospect, in: [held], now: time(0.5)).isEmpty)
    }

    @Test func soonestFirstEachTripOnceAndOnlyTheLinesShown() {
        let trains = TrainService.trains(for: prospect, in: [
            arrival(9, trip: "b"),
            arrival(5, trip: "a"),
            arrival(3, trip: "a"),
            // Trips without ids can't be told apart
            arrival(4, trip: "", route: "N"),
            arrival(6, trip: "", route: "N"),
        ], now: now)
        #expect(trains.map(\.time) == [3, 4, 6, 9].map(time))
    }

    @Test func eachSelectionGetsItsOwnStopsTrainsFromEveryFeed() {
        let feeds: [URL: [Arrival]] = [
            nqrw: [
                train(2, trip: "r1", at: "R34N"), train(4, trip: "r1", at: "R33N"),
                train(6, trip: "r2", at: "R34N"), train(8, trip: "r2", at: "R33N"),
                Arrival(route: "R", time: time(3), stop: "R33N", lastStop: "R33N", isLive: true, trip: "ends"),
            ],
            // A D running local on the R
            bdfm: [train(5, trip: "d1", at: "R34N", route: "D")],
        ]
        let trains = TrainService.trains(for: [prospect, fourthAv, prospect], in: feeds, now: now)
        #expect(trains.count == 2)
        #expect(trains[prospect.trainID]?.map(\.trip) == ["r1", "d1", "r2"])
        #expect(trains[fourthAv.trainID]?.map(\.time) == [time(4), time(8)])

        let ownOnly = TrainService.trains(for: [prospect], in: feeds, includingOtherLines: false, now: now)
        #expect(ownOnly[prospect.trainID]?.map(\.trip) == ["r1", "r2"])
    }

    @Test func oneWhoseOwnFeedDidntComeIsLeftOut() {
        let trains = TrainService.trains(for: [prospect], in: [bdfm: [train(5, trip: "d1", at: "R34N", route: "D")]],
                                         now: now)
        #expect(trains.isEmpty)
        // Without the other lines' feeds, there are just no rerouted trains
        let withoutOthers = TrainService.trains(for: [prospect], in: [nqrw: []], now: now)
        #expect(withoutOthers[prospect.trainID] == [])
    }

    @Test func aStaleFeedOfItsOwnLinesFailsTheBoardAndAnotherLinesIsLeftOut() throws {
        let stops = Set(prospect.stopIDs)
        let fresh = GTFSFeed.feed([GTFSFeed.trip("R1", stops: [FeedStop("R34N", at: 3), FeedStop("G08N", arrival: 40)])])
        // A D running local on the R, in a feed that stopped updating 4 minutes ago
        let stale = GTFSFeed.feed(made: -4, [
            GTFSFeed.trip("D1", route: "D", stops: [FeedStop("R34N", at: 2), FeedStop("D01N", arrival: 60)]),
        ])
        #expect(throws: FeedError.stale) {
            try TrainService.arrivals(at: stops, own: [stale], others: [fresh], now: now)
        }
        let arrivals = try TrainService.arrivals(at: stops, own: [fresh], others: [stale], now: now)
        #expect(arrivals.map(\.trip) == ["R1"])
        // Three minutes earlier, it was still up to date
        let both = try TrainService.arrivals(at: stops, own: [fresh], others: [stale], now: time(-3))
        #expect(Set(both.map(\.trip)) == ["R1", "D1"])
    }

    @Test func fromAFeed() throws {
        let feed = GTFSFeed.feed([
            GTFSFeed.trip("R1", stops: [FeedStop("R34N", at: 3), FeedStop("G08N", arrival: 40)]),
            GTFSFeed.trip("R2", stops: [FeedStop("R35N", at: -2), FeedStop("R34N", arrival: -1, departure: 1),
                                        FeedStop("G08N", arrival: 35)]),
            GTFSFeed.trip("R3", stops: [FeedStop("R35N", at: 1), FeedStop("R34N", arrival: 2)]),
        ])
        let arrivals = try SubwayFeed.arrivals(at: Set(prospect.stopIDs), in: feed, now: now)
        // The held train first; not the one whose trip ends here
        #expect(TrainService.trains(for: prospect, in: arrivals, now: now).map(\.trip) == ["R2", "R1"])
    }
}
