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

    @Test func aStopListedTwiceUnderTwoIdsIsThereOnce() throws {
        // An H leaving Broad Channel: the feed lists its own track there, H19S, then the platform, H04S
        let hTrip = GTFSFeed.trip("H1", route: "H", stops: [
            FeedStop("H19S", at: -1), FeedStop("H04S", at: 0.5), FeedStop("H12S", at: 5), FeedStop("H13S", at: 7),
            FeedStop("H15S", arrival: 10),
        ])
        let arrivals = try SubwayFeed.arrivals(at: ["H04S", "H12S"], in: GTFSFeed.feed([hTrip]), now: now)
        #expect(arrivals.map { $0.approach.map(\.id) } == [["H04S"], ["H04S", "H12S"]])
        #expect(arrivals.last?.approach.map(\.name) == ["Broad Channel", "Beach 90 St"])
        #expect(arrivals.last?.approach.map(\.time) == [time(0.5), time(5)])
        // Asked about its own track too, that arrival still ends there
        let both = try SubwayFeed.arrivals(at: ["H19S", "H12S"], in: GTFSFeed.feed([hTrip]), now: now)
        #expect(both.map { $0.approach.map(\.id) } == [["H19S"], ["H04S", "H12S"]])
        // Stopped on its own track, it's at Broad Channel
        let feed = GTFSFeed.feed([hTrip, GTFSFeed.vehicle("H1", route: "H", at: "H19S", status: 1)])
        let stopped = try #require(try SubwayFeed.arrivals(at: ["H12S"], in: feed, now: now).first)
        #expect(stopped.position == Arrival.Position(stop: "H19S", isStopped: true))
        #expect(stopped.place(now: now) == .at(0))
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

    @Test func whenAFeedWasMade() {
        #expect(SubwayFeed.made(GTFSFeed.feed(made: -2, [rTrip])) == time(-2))
        #expect(SubwayFeed.made(GTFSFeed.feed(made: nil, [rTrip])) == nil)
        #expect(SubwayFeed.newest([GTFSFeed.feed(made: -2, []), GTFSFeed.feed(made: -1, []), GTFSFeed.feed(made: nil, [])])
            == time(-1))
        #expect(SubwayFeed.newest([GTFSFeed.feed(made: nil, [])]) == nil)
    }

    @Test func aFastClockGoesByTheNewestFeed() throws {
        // This device's clock 5 minutes fast, with the newest feed made just now
        let fast = time(5)
        let newest = time(0)
        #expect(try SubwayFeed.arrivals(at: ["R34N"], in: GTFSFeed.feed([rTrip]), newest: newest, now: fast).count == 1)
        // One that stopped updating 4 minutes before it is out of date all the same
        #expect(throws: FeedError.stale) {
            try SubwayFeed.arrivals(at: ["R34N"], in: GTFSFeed.feed(made: -4, [rTrip]), newest: newest, now: fast)
        }
        // By the clock alone, every feed would be
        #expect(throws: FeedError.stale) {
            try SubwayFeed.arrivals(at: ["R34N"], in: GTFSFeed.feed([rTrip]), now: fast)
        }
    }

    @Test func aFeedWithNoNewerOneGoesByTheClockAndTheAllowance() throws {
        let limit = (SubwayFeed.staleAfter + SubwayFeed.clockAllowance) / 60
        let feed = GTFSFeed.feed([rTrip])
        let made = SubwayFeed.made(feed)
        #expect(try SubwayFeed.arrivals(at: ["R34N"], in: feed, newest: made, now: time(limit)).count == 1)
        #expect(throws: FeedError.stale) {
            try SubwayFeed.arrivals(at: ["R34N"], in: feed, newest: made, now: time(limit + 0.5))
        }
    }

    @Test func aNewestFeedAheadOfTheClockGoesByTheClock() {
        // One feed an hour ahead doesn't put the others out of date
        #expect(!SubwayFeed.isStale(made: time(-1), newest: time(60), now: now))
        #expect(SubwayFeed.isStale(made: time(-3.5), newest: time(60), now: now))
        // Nor does a clock that's slow
        #expect(!SubwayFeed.isStale(made: time(1), newest: time(2), now: now))
    }

    @Test func aTimeOutOfRangeIsNone() throws {
        let oddTimes = Protobuf { entity in
            entity.string(1, "000001R1") // FeedEntity.id
            entity.message(3) { update in // FeedEntity.trip_update
                update.message(1) { trip in // TripUpdate.trip
                    trip.string(1, "R1") // trip_id
                    trip.string(5, "R") // route_id
                }
                let stops: [(id: String, arrival: Int64, departure: Int64?)] = [
                    ("R35N", -1, nil), // a negative time, which protobuf writes as a huge number
                    ("R34N", -1, Int64(GTFSFeed.seconds(3))),
                    ("G08N", Int64(GTFSFeed.seconds(40)) * 1000, nil), // in milliseconds
                ]
                for stop in stops {
                    update.message(2) { stopTime in // TripUpdate.stop_time_update
                        stopTime.message(2) { $0.int(2, stop.arrival) } // arrival.time
                        if let departure = stop.departure {
                            stopTime.message(3) { $0.int(2, departure) } // departure.time
                        }
                        stopTime.string(4, stop.id) // stop_id
                    }
                }
            }
        }
        let arrivals = try SubwayFeed.arrivals(at: ["R35N", "R34N", "G08N"], in: GTFSFeed.feed([oddTimes]), now: now)
        #expect(arrivals.count == 1)
        let train = try #require(arrivals.first)
        #expect(train.stop == "R34N")
        #expect(train.time == time(3))
        #expect(train.departure == nil)
        #expect(train.approach.map(\.id) == ["R34N"])
        #expect(train.lastStop == "G08N")

        // A feed whose time is out of range doesn't say when it was made
        let feed = Protobuf { feed in
            feed.message(1) { $0.int(3, -1) } // FeedHeader.timestamp
            feed.message(2, rTrip) // FeedMessage.entity
        }.data
        #expect(SubwayFeed.made(feed) == nil)
        #expect(try SubwayFeed.arrivals(at: ["R34N"], in: feed, now: now).count == 1)
    }

    @Test func theStopsAfterYours() throws {
        let feed = GTFSFeed.feed([
            rTrip,
            GTFSFeed.trip("N1", route: "N", stops: [FeedStop("R34N", at: 4), FeedStop("R31N", at: 9), FeedStop("R01N")]),
            GTFSFeed.trip("D1", route: "D", stops: [FeedStop("R34N", at: 5), FeedStop("R31N", at: 10)]),
        ])
        let stops = { (routes: Set<String>) in
            try SubwayFeed.timedStops(after: ["R34N"], on: routes, in: feed).map { $0.map(\.id) }
        }
        #expect(try stops(["R"]) == [["R33N", "G08N"]])
        #expect(try stops(["R", "N"]) == [["R33N", "G08N"], ["R31N", "R01N"]])
    }

    @Test func linesThatPartGoingTheSameWayEachHaveTheirStopsListed() throws {
        // From 59 St in Brooklyn, the R goes on to Bay Ridge and the N to Coney Island
        let feed = GTFSFeed.feed([
            GTFSFeed.trip("R1", route: "R", stops: [FeedStop("R41S", at: 1), FeedStop("R42S", at: 3), FeedStop("R43S", at: 5),
                                                    FeedStop("R44S", at: 7), FeedStop("R45S", arrival: 9)]),
            GTFSFeed.trip("N1", route: "N", stops: [FeedStop("R41S", at: 2), FeedStop("N02S", at: 4), FeedStop("N03S", at: 6),
                                                    FeedStop("N04S", at: 8), FeedStop("N10S", at: 14),
                                                    FeedStop("D43S", arrival: 20)]),
        ])
        let nr = Selection(stationID: "R41", routes: ["N", "R"], direction: .south)
        let names = try TrainService.stations(after: nr, in: [feed]).map(\.name)
        // In the order the trains get there: the N's 8 Av and the R's Bay Ridge Av are both 2
        // minutes on, the N's listed first as the longer
        #expect(names == ["8 Av", "Bay Ridge Av", "Fort Hamilton Pkwy", "77 St", "New Utrecht Av", "86 St",
                          "Bay Ridge-95 St", "86 St", "Coney Island-Stillwell Av"])
        // One line's are just its own
        let r = Selection(stationID: "R41", routes: ["R"], direction: .south)
        #expect(try TrainService.stations(after: r, in: [feed]).map(\.name) == ["Bay Ridge Av", "77 St", "86 St",
                                                                                  "Bay Ridge-95 St"])
    }

    @Test func anExpressAndItsLocalHaveTheirStopsListedInOrder() throws {
        // From 96 St, the 1 runs local to South Ferry and the 2, the longer, express to Flatbush Av
        let one = ["120S", "121S", "122S", "123S", "124S", "125S", "126S", "127S", "128S", "129S", "130S", "131S",
                   "132S", "133S", "134S", "135S", "136S", "137S", "138S", "139S", "142S"]
        let two = ["120S", "123S", "127S", "128S", "132S", "137S", "228S", "229S", "230S", "231S", "232S", "233S",
                   "234S", "235S", "236S", "237S", "238S", "239S", "241S", "242S", "243S", "244S", "245S", "246S", "247S"]
        func trip(_ id: String, route: String, stops: [String]) -> Protobuf {
            GTFSFeed.trip(id, route: route, stops: stops.enumerated().map { FeedStop($0.element, at: Double($0.offset) * 2 + 1) })
        }
        let feed = GTFSFeed.feed([trip("1A", route: "1", stops: one), trip("2A", route: "2", stops: two)])
        let both = Selection(stationID: "120", routes: ["1", "2"], direction: .south)
        let stations = try TrainService.stations(after: both, in: [feed])
        // The 1's own stops among the 2's, nearest first, each line's in its order
        for stops in [one, two] {
            let own = stops.dropFirst().compactMap(StationDirectory.station(forStop:)).map(\.id)
            #expect(stations.map(\.id).filter(Set(own).contains) == own)
        }
        #expect(stations.prefix(5).map(\.name) == ["86 St", "79 St", "72 St", "66 St-Lincoln Center",
                                                   "59 St-Columbus Circle"])
        #expect(stations.count == 39)
        // Where they part after Chambers St, the express 2 gets to Park Place before the 1 gets
        // to Franklin St
        let ids = stations.map(\.id)
        let parkPlace = try #require(StationDirectory.station(forStop: "228S")).id
        let franklin = try #require(StationDirectory.station(forStop: "138S")).id
        #expect(try #require(ids.firstIndex(of: parkPlace)) < #require(ids.firstIndex(of: franklin)))
    }

    @Test func linesThatPartAndMeetAgainAreListedInTheOrderTheTrainsGetThere() throws {
        // South from 34 St-Herald Sq the D runs by W 4 St and Grand St, the N by Canal St, and
        // the Q by Canal St and DeKalb Av, all to Atlantic Av-Barclays Ctr
        func trip(_ id: String, route: String, stops: [(String, Double)]) -> Protobuf {
            GTFSFeed.trip(id, route: route, stops: stops.map { FeedStop($0.0, at: $0.1) })
        }
        let feed = GTFSFeed.feed([
            trip("D1", route: "D", stops: [("D17S", 0), ("D20S", 2), ("D21S", 5), ("D22S", 7), ("R31S", 10), ("R36S", 15)]),
            trip("N1", route: "N", stops: [("R17S", 0), ("R20S", 3), ("Q01S", 6), ("R31S", 10), ("R36S", 15)]),
            trip("Q1", route: "Q", stops: [("R17S", 0), ("R20S", 3), ("Q01S", 6), ("R30S", 9), ("D24S", 11)]),
        ])
        let dnq = Selection(stationID: "D17", routes: ["D", "N", "Q"], direction: .south)
        let names = try TrainService.stations(after: dnq, in: [feed]).map(\.name)
        #expect(names == ["W 4 St-Wash Sq", "14 St-Union Sq", "Broadway-Lafayette St", "Canal St", "Grand St",
                          "DeKalb Av", "Atlantic Av-Barclays Ctr", "36 St"])
    }

    @Test func threeLinesThatCrossEachHaveTheirStopsListedInOrder() throws {
        // South from Times Sq, the R runs local to Bay Ridge, the Q over the Manhattan
        // Bridge to Coney Island by Brighton Beach, and the N over it, then by the R's
        // 36 St and 59 St, to Coney Island by its own 86 St
        let r = ["R16S", "R17S", "R18S", "R19S", "R20S", "R21S", "R22S", "R23S", "R24S", "R25S", "R26S", "R27S",
                 "R28S", "R29S", "R30S", "R31S", "R32S", "R33S", "R34S", "R35S", "R36S", "R39S", "R40S", "R41S",
                 "R42S", "R43S", "R44S", "R45S"]
        let q = ["R16S", "R17S", "R20S", "Q01S", "R30S", "D24S", "D25S", "D26S", "D27S", "D28S", "D29S", "D30S",
                 "D31S", "D32S", "D33S", "D34S", "D35S", "D37S", "D38S", "D39S", "D40S", "D41S", "D42S", "D43S"]
        let n = ["R16S", "R17S", "R20S", "Q01S", "R31S", "R36S", "R41S", "N02S", "N03S", "N04S", "N05S", "N06S",
                 "N07S", "N08S", "N09S", "N10S", "D43S"]
        func trip(_ id: String, route: String, stops: [String]) -> Protobuf {
            GTFSFeed.trip(id, route: route, stops: stops.enumerated().map { FeedStop($0.element, at: Double($0.offset) * 2 + 1) })
        }
        let feed = GTFSFeed.feed([trip("R1", route: "R", stops: r), trip("Q1", route: "Q", stops: q),
                                  trip("N1", route: "N", stops: n)])
        let nqr = Selection(stationID: "R16", routes: ["N", "Q", "R"], direction: .south)
        let stations = try TrainService.stations(after: nqr, in: [feed]).map(\.id)
        for stops in [r, q, n] {
            let own = stops.dropFirst().compactMap(StationDirectory.station(forStop:)).map(\.id)
            #expect(stations.filter(Set(own).contains) == own)
        }
        #expect(Set(stations).count == stations.count)
        #expect(stations.count == 54)
        // Coney Island-Stillwell Av, where the Q and N end, comes after the N's
        // 86 St, not among the Q's stops ahead of the N's 36 St
        let coneyIsland = try #require(StationDirectory.station(forStop: "D43S")).id
        let eightySixth = try #require(StationDirectory.station(forStop: "N10S")).id
        #expect(stations.firstIndex(of: coneyIsland) == stations.firstIndex(of: eightySixth).map { $0 + 1 })
    }
}
