import Foundation
import Testing
@testable import TrainCore

/// How `TrainService` tells a feed that has stopped updating: by the newest of
/// the feeds fetched with it, so that a clock that's fast doesn't make them all
/// out of date, and failing the board for one of its own lines but leaving out
/// another line's.
@Suite struct FeedAgeTests {
    let nqrw = Lines.feedURLs(sharingTracksWith: ["R"]).own[0]
    let bdfm = Lines.feedURLs(sharingTracksWith: ["D"]).own[0]
    let stops = Set(prospect.stopIDs)
    /// An R at Prospect Av in 10 minutes, in a feed made just now.
    let fresh = GTFSFeed.feed([GTFSFeed.trip("R1", stops: [FeedStop("R34N", at: 10), FeedStop("G08N", arrival: 45)])])
    /// A D running local on the R, in a feed that stopped updating 4 minutes ago.
    let stale = GTFSFeed.feed(made: -4, [
        GTFSFeed.trip("D1", route: "D", stops: [FeedStop("R34N", at: 12), FeedStop("D01N", arrival: 60)]),
    ])

    func time(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    @Test func aBoardOnAClockThatsFast() throws {
        // This device's clock 5 minutes fast
        let fast = time(5)
        #expect(try TrainService.arrivals(at: stops, own: [fresh], others: [], now: fast).map(\.trip) == ["R1"])
        // A feed that stopped updating is still told by the newer one
        #expect(throws: FeedError.stale) {
            try TrainService.arrivals(at: stops, own: [stale], others: [fresh], now: fast)
        }
        #expect(try TrainService.arrivals(at: stops, own: [fresh], others: [stale], now: fast).map(\.trip) == ["R1"])
    }

    @Test func feedsWithNoNewerOneGoByTheClockAndTheAllowance() throws {
        let limit = (SubwayFeed.staleAfter + SubwayFeed.clockAllowance) / 60
        #expect(try TrainService.arrivals(at: stops, own: [fresh], others: [], now: time(limit)).count == 1)
        #expect(throws: FeedError.stale) {
            try TrainService.arrivals(at: stops, own: [fresh], others: [], now: time(limit + 0.5))
        }
        // Or that have all stopped updating
        #expect(throws: FeedError.stale) {
            try TrainService.arrivals(at: stops, own: [fresh], others: [fresh], now: time(limit + 0.5))
        }
    }

    @Test func eachOfTheLiveTabsFeedsGoesByTheNewest() {
        // The feeds the Nearby tab and the push server read together, on a clock 5 minutes fast
        let fast = time(5)
        let arrivals = TrainService.arrivals(at: stops, in: [nqrw: fresh, bdfm: stale], now: fast)
        #expect(arrivals[nqrw]?.map(\.trip) == ["R1"])
        #expect(arrivals[bdfm] == nil)
        #expect(TrainService.trains(for: [prospect], in: arrivals, now: fast)[prospect.trainID]?.map(\.trip) == ["R1"])
        // Without its own lines' feed, a selection is left out
        let ownStale = TrainService.arrivals(at: stops, in: [nqrw: stale, bdfm: fresh], now: fast)
        #expect(ownStale[nqrw] == nil)
        #expect(TrainService.trains(for: [prospect], in: ownStale, now: fast).isEmpty)
    }
}
