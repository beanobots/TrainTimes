import Foundation
import Testing
@testable import TrainCore

/// `SubwayFeed` reading GTFS-realtime feeds written as the MTA writes them.
@Suite struct SubwayFeedTests {
    /// An R from Bay Ridge to Forest Hills, at Prospect Av (R34N) in 3 minutes.
    let rTrip = GTFSFeed.trip("R1", stops: [
        FeedStop("R36N", at: -3), FeedStop("R35N", at: 1), FeedStop("R34N", at: 3), FeedStop("R33N", at: 5),
        FeedStop("G08N", arrival: 40),
    ])

    func time(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    @Test func readsATripAtTheStop() throws {
        let arrivals = try SubwayFeed.arrivals(at: ["R34N"], in: GTFSFeed.feed([rTrip]), now: now)
        #expect(arrivals.count == 1)
        let train = try #require(arrivals.first)
        #expect(train.route == "R")
        #expect(train.time == time(3))
        #expect(train.departure == nil)
        #expect(train.leaves == time(3))
        #expect(train.stop == "R34N")
        #expect(train.lastStop == "G08N")
        #expect(!train.endsHere)
        #expect(train.isLive)
        #expect(train.trip == "R1")
        #expect(train.approach.map(\.id) == ["R36N", "R35N", "R34N"])
        #expect(train.approach.map(\.time) == [time(-3), time(1), time(3)])
        #expect(train.position == nil)
    }

    @Test func expressRoutesAreTheirLines() throws {
        let feed = GTFSFeed.feed([
            GTFSFeed.trip("6X1", route: "6X", stops: [FeedStop("640S", at: 2), FeedStop("601S", arrival: 30)]),
        ])
        #expect(try SubwayFeed.arrivals(at: ["640S"], in: feed, now: now).map(\.route) == ["6"])
    }

    @Test func liveOnlyWithATrainAssigned() throws {
        let assigned: [Bool?] = [true, false, nil]
        let feed = GTFSFeed.feed(assigned.enumerated().map { index, assigned in
            GTFSFeed.trip("R\(index)", assigned: assigned,
                          stops: [FeedStop("R34N", at: Double(index + 1)), FeedStop("G08N", arrival: 40)])
        })
        #expect(try SubwayFeed.arrivals(at: ["R34N"], in: feed, now: now).map(\.isLive) == [true, false, false])
    }

    @Test func whereATripStartsItGoesByItsDeparture() throws {
        // The feeds give only a departure time for a trip's first stop
        let feed = GTFSFeed.feed([
            GTFSFeed.trip("R1", stops: [FeedStop("R45N", departure: 4), FeedStop("R44N", at: 6), FeedStop("G08N", arrival: 60)]),
        ])
        let train = try #require(try SubwayFeed.arrivals(at: ["R45N"], in: feed, now: now).first)
        #expect(train.time == time(4))
        #expect(train.departure == nil)
        #expect(train.leaves == time(4))
        #expect(train.approach.map(\.id) == ["R45N"])
    }

    @Test func aTrainHeldAtThePlatformLeavesLater() throws {
        let feed = GTFSFeed.feed([
            GTFSFeed.trip("1A", route: "1", stops: [FeedStop("103N", arrival: -2, departure: 1), FeedStop("101N", at: 5)]),
            // A departure before the arrival is no later departure
            GTFSFeed.trip("1B", route: "1", stops: [FeedStop("103N", arrival: 8, departure: 7), FeedStop("101N", at: 12)]),
        ])
        let arrivals = try SubwayFeed.arrivals(at: ["103N"], in: feed, now: now)
        #expect(arrivals.map(\.time) == [time(-2), time(8)])
        #expect(arrivals.map(\.departure) == [time(1), nil])
        #expect(arrivals.map(\.leaves) == [time(1), time(8)])
        // Its stops go by when it gets to them
        #expect(arrivals.first?.approach.map(\.time) == [time(-2)])
    }

    @Test func theLastStopListedEndsTheTripEvenWithoutATime() throws {
        let feed = GTFSFeed.feed([GTFSFeed.trip("R1", stops: [FeedStop("R34N", at: 3), FeedStop("G08N")])])
        let train = try #require(try SubwayFeed.arrivals(at: ["R34N"], in: feed, now: now).first)
        #expect(train.lastStop == "G08N")
        #expect(train.approach.map(\.id) == ["R34N"])
        // Without a time it would be due in 1970
        #expect(try SubwayFeed.arrivals(at: ["G08N"], in: feed, now: now).isEmpty)
    }

    @Test func aTrainEndingAtTheStopEndsHere() throws {
        let feed = GTFSFeed.feed([GTFSFeed.trip("R1", stops: [FeedStop("G09N", at: 2), FeedStop("G08N", arrival: 4)])])
        let train = try #require(try SubwayFeed.arrivals(at: ["G08N"], in: feed, now: now).first)
        #expect(train.endsHere)
        #expect(train.time == time(4))
    }

    @Test func negativeDelaysTakeTenBytes() throws {
        #expect(Protobuf.varint(UInt64(bitPattern: -30)).count == 10)
        // The L's feed has them
        let feed = GTFSFeed.feed([
            GTFSFeed.trip("L1", route: "L", delay: -30, stops: [FeedStop("L06N", at: 2), FeedStop("L01N", arrival: 9)]),
        ])
        let train = try #require(try SubwayFeed.arrivals(at: ["L06N"], in: feed, now: now).first)
        #expect(train.time == time(2))
        #expect(train.lastStop == "L01N")
    }

    @Test func aTripAtTwoOfTheStopsComesTwice() throws {
        let arrivals = try SubwayFeed.arrivals(at: ["R35N", "R33N"], in: GTFSFeed.feed([rTrip]), now: now)
        #expect(arrivals.map(\.stop) == ["R35N", "R33N"])
        #expect(arrivals.map(\.approach.count) == [2, 4])
    }

    @Test func soonestFirst() throws {
        let later = GTFSFeed.trip("R0", stops: [FeedStop("R34N", at: 9), FeedStop("G08N", arrival: 45)])
        let arrivals = try SubwayFeed.arrivals(at: ["R34N"], in: GTFSFeed.feed([later, rTrip]), now: now)
        #expect(arrivals.map(\.trip) == ["R1", "R0"])
    }

    @Test func eachTripGetsItsTrainsPosition() throws {
        let feed = GTFSFeed.feed([
            rTrip,
            GTFSFeed.trip("R2", stops: [FeedStop("R35N", at: 6), FeedStop("R34N", at: 8), FeedStop("G08N", arrival: 45)]),
            GTFSFeed.trip("R3", stops: [FeedStop("R35N", at: 10), FeedStop("R34N", at: 12), FeedStop("G08N", arrival: 50)]),
            GTFSFeed.vehicle("R1", at: "R35N", status: 1), // STOPPED_AT
            GTFSFeed.vehicle("R2", at: "R35N", status: nil), // IN_TRANSIT_TO, left out as protobuf's default
            GTFSFeed.vehicle("R3", at: "R35N", status: 0), // INCOMING_AT
            GTFSFeed.vehicle("R9", at: "R35N", status: 1), // a trip not at the stop
        ])
        let arrivals = try SubwayFeed.arrivals(at: ["R34N"], in: feed, now: now)
        #expect(arrivals.map(\.position) == [
            Arrival.Position(stop: "R35N", isStopped: true),
            Arrival.Position(stop: "R35N", isStopped: false),
            Arrival.Position(stop: "R35N", isStopped: false),
        ])
        #expect(arrivals.map { $0.place(now: now) } == [Arrival.Place.at(1), .approaching(0), .approaching(0)])
    }

    @Test func fieldsItDoesntReadAreSkipped() throws {
        var entity = rTrip
        entity.fixed64(20, 42)
        entity.fixed32(21, 7)
        entity.varint(22, UInt64.max)
        entity.string(23, "unknown")
        let feed = Protobuf { feed in
            feed.fixed32(15, 1)
            feed.raw([UInt8](GTFSFeed.feed([entity])))
            feed.message(16) { $0.fixed64(1, 9) }
        }.data
        #expect(try SubwayFeed.arrivals(at: ["R34N"], in: feed, now: now).map(\.trip) == ["R1"])
    }

    @Test func aFeedCutShortIsMalformed() {
        let header = GTFSFeed.feed([])
        let feed = GTFSFeed.feed([rTrip])
        #expect(feed.starts(with: header))
        for length in (header.count + 1)..<feed.count {
            #expect(throws: FeedError.malformed) {
                try SubwayFeed.arrivals(at: ["R34N"], in: feed.prefix(length), now: now)
            }
        }
    }

    @Test func aLengthPastTheEndIsMalformed() {
        let feed = Protobuf { feed in
            feed.key(2, wireType: 2)
            feed.raw(Protobuf.varint(1000))
            feed.raw([0x0a, 0x01, 0x41])
        }.data
        #expect(throws: FeedError.malformed) { try SubwayFeed.arrivals(at: ["R34N"], in: feed, now: now) }
    }

    @Test(arguments: [3, 4, 6, 7] as [UInt64])
    func anUnknownWireTypeIsMalformed(wireType: UInt64) {
        let feed = Protobuf { feed in
            feed.key(9, wireType: wireType)
            feed.raw([UInt8](repeating: 0, count: 8))
        }.data
        #expect(throws: FeedError.malformed) { try SubwayFeed.arrivals(at: ["R34N"], in: feed, now: now) }
    }

    @Test func aVarintOverTenBytesIsMalformed() {
        let feed = Protobuf { feed in
            feed.key(9, wireType: 0)
            feed.raw([UInt8](repeating: 0xff, count: 10) + [0x01])
        }.data
        #expect(throws: FeedError.malformed) { try SubwayFeed.arrivals(at: ["R34N"], in: feed, now: now) }
    }

    @Test func aFixedFieldPastTheEndIsMalformed() {
        let feed = Protobuf { feed in
            feed.key(9, wireType: 1)
            feed.raw([1, 2, 3, 4])
        }.data
        #expect(throws: FeedError.malformed) { try SubwayFeed.arrivals(at: ["R34N"], in: feed, now: now) }
    }

    @Test func aFeedThatHasStoppedUpdatingIsStale() throws {
        let limit = SubwayFeed.staleAfter / 60
        #expect(throws: FeedError.stale) {
            try SubwayFeed.arrivals(at: ["R34N"], in: GTFSFeed.feed(made: -limit - 0.5, [rTrip]), now: now)
        }
        // A feed a little behind, as the MTA's often are, or by a clock a little ahead
        for made in [-limit, -1, 0, 1] {
            #expect(try SubwayFeed.arrivals(at: ["R34N"], in: GTFSFeed.feed(made: made, [rTrip]), now: now).count == 1)
        }
        // One that doesn't say when it was made goes as it is
        #expect(try SubwayFeed.arrivals(at: ["R34N"], in: GTFSFeed.feed(made: nil, [rTrip]), now: now).count == 1)
    }

    @Test func theStopsAfterYours() throws {
        let feed = GTFSFeed.feed([
            rTrip,
            GTFSFeed.trip("N1", route: "N", stops: [FeedStop("R34N", at: 4), FeedStop("R31N", at: 9), FeedStop("R01N")]),
            GTFSFeed.trip("D1", route: "D", stops: [FeedStop("R34N", at: 5), FeedStop("R31N", at: 10)]),
        ])
        #expect(try SubwayFeed.stops(after: ["R34N"], on: ["R"], in: feed) == [["R33N", "G08N"]])
        #expect(try SubwayFeed.stops(after: ["R34N"], on: ["R", "N"], in: feed) == [["R33N", "G08N"], ["R31N", "R01N"]])
    }
}
