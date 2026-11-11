import Foundation
import Testing
@testable import Leeway

/// GTFS-realtime feeds of its own, written field by field, to feed the reader what the MTA
/// shouldn't send.
private enum Proto {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    static func number(_ field: Int, _ value: UInt64) -> [UInt8] { varint(UInt64(field << 3)) + varint(value) }

    static func bytes(_ field: Int, _ data: [UInt8]) -> [UInt8] {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(data.count)) + data
    }

    static func string(_ field: Int, _ text: String) -> [UInt8] { bytes(field, Array(text.utf8)) }

    /// A trip's update: `stops` with their arrival times.
    static func trip(_ id: String, route: String = "R", live: Bool = true, stops: [(String, Date)]) -> [UInt8] {
        let descriptor = string(1, id) + string(5, route) + bytes(1001, number(2, live ? 1 : 0))
        let updates = stops.flatMap { stop, time in
            bytes(2, bytes(2, number(2, UInt64(time.timeIntervalSince1970))) + string(4, stop))
        }
        return bytes(2, string(1, id) + bytes(3, bytes(1, descriptor) + updates))
    }

    /// A feed made at `made` (none if nil), of `trips`.
    static func feed(made: Date?, _ trips: [[UInt8]] = []) -> Data {
        let header = string(1, "2.0") + (made.map { number(3, UInt64($0.timeIntervalSince1970)) } ?? [])
        return Data(bytes(1, header) + trips.joined())
    }
}

/// The same "random" bytes every run.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 11 ^ state
    }
}

private let nqrw = Lines.feedURLs(sharingTracksWith: ["R"]).own[0]
private let relayHost = TrainService.serverURL?.host
private let cap = CountdownKit.cap

/// Feeds cut short, garbled, empty or stamped wrong.
struct BrokenFeedTests {
    /// Half the N Q R W feed: its header reads, the rest doesn't, and it isn't taken as a feed.
    @Test func aRealFeedCutInHalfIsMalformed() {
        let full = CountdownKit.fixture("-nqrw")
        let half = full.prefix(full.count / 2)
        #expect(throws: FeedError.malformed) { try SubwayFeed.arrivals(at: ["R34N"], in: half, now: cap) }
        #expect(SubwayFeed.made(half) == SubwayFeed.made(full))
        #expect(!SubwayFeed.isWhole(half))
        #expect(SubwayFeed.tripCount(half) == nil)
        #expect(!TrainService.isUsable(half, from: nqrw))
        #expect(TrainService.isUsable(full, from: nqrw))
    }

    /// Cut anywhere, the Staten Island feed reads only where it's whole, and never crashes.
    @Test func everyCutOfARealFeedReadsOnlyWhereWhole() {
        let full = CountdownKit.fixture("-si")
        let all = (try? SubwayFeed.arrivals(at: ["S23N", "S25N"], in: full, now: cap)) ?? []
        #expect(!all.isEmpty)
        for cut in stride(from: 0, to: full.count, by: 3) {
            let part = full.prefix(cut)
            let read = try? SubwayFeed.arrivals(at: ["S23N", "S25N"], in: part, now: cap)
            #expect((read != nil) == SubwayFeed.isWhole(part), "cut at \(cut)")
            if let read { #expect(read.count <= all.count) }
        }
    }

    /// Bytes flipped at random never crash it, and any time it reads is a plausible one.
    @Test func flippedBytesNeverCrash() {
        var random = Seeded(state: 20261110)
        let full = [UInt8](CountdownKit.fixture("-si"))
        let earliest = Date(timeIntervalSince1970: 946_684_800), latest = Date(timeIntervalSince1970: 4_102_444_800)
        for _ in 0..<400 {
            var bytes = full
            for _ in 0..<3 { bytes[Int.random(in: 0..<bytes.count, using: &random)] = UInt8.random(in: 0...255, using: &random) }
            let data = Data(bytes)
            _ = SubwayFeed.made(data)
            _ = SubwayFeed.tripCount(data)
            _ = try? SubwayFeed.timedStops(after: ["S23N"], on: ["SI"], in: data)
            for arrival in (try? SubwayFeed.arrivals(at: ["S23N", "S25N"], in: data, now: cap)) ?? [] {
                #expect(arrival.time >= earliest && arrival.time <= latest)
            }
        }
    }

    /// An error page, 0xFFs or noise in place of a feed: none taken as one.
    @Test func garbageIsNeverAFeed() {
        var random = Seeded(state: 7)
        let noise = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &random) })
        let html = Data("<html><body>502 Bad Gateway</body></html>".utf8)
        let ones = Data(repeating: 0xFF, count: 64)
        #expect(throws: FeedError.malformed) { try SubwayFeed.arrivals(at: ["R34N"], in: html, now: cap) }
        #expect(throws: FeedError.malformed) { try SubwayFeed.arrivals(at: ["R34N"], in: ones, now: cap) }
        _ = try? SubwayFeed.arrivals(at: ["R34N"], in: noise, now: cap)
        for data in [html, ones, noise] {
            #expect(!TrainService.isUsable(data, from: nqrw))
        }
        #expect(SubwayFeed.made(html) == nil)
    }

    /// An empty 200 reads as no trains, so it mustn't be taken as a feed.
    @Test func anEmptyBodyIsNoFeed() throws {
        #expect(try SubwayFeed.arrivals(at: ["R34N"], in: Data(), now: cap).isEmpty)
        #expect(SubwayFeed.tripCount(Data()) == 0)
        #expect(SubwayFeed.made(Data()) == nil)
        #expect(!TrainService.isUsable(Data(), from: nqrw))
    }

    /// A fresh feed with no trips (an MTA restart) is a feed: the countdown keeps its train and says so.
    @Test func aFeedWithNoTripsKeepsTheCountdownsTrain() throws {
        let empty = Proto.feed(made: cap)
        #expect(TrainService.isUsable(empty, from: nqrw))
        #expect(SubwayFeed.tripCount(empty) == 0)
        let arrivals = try TrainService.arrivals(at: ["R34N"], own: [empty], others: [], now: cap)
        #expect(arrivals.isEmpty)
        let state = CountdownState(train: CountdownKit.at(120), trip: "x", isLive: true, terminal: "Forest Hills",
                                   following: [CountdownKit.at(600)], notice: nil, updated: CountdownKit.at(-60),
                                   route: "R", followingRoutes: ["R"])
        let refreshed = state.refreshed(for: CountdownKit.prospect, board: Board(trains: [], alerts: []),
                                        settings: AppSettings(), now: cap)
        #expect(refreshed.train == state.train)
        #expect(refreshed.following.isEmpty)
        #expect(refreshed.notice == "No trains predicted")
        #expect(refreshed.updated == cap)
    }

    /// One feed stamped in 2090 doesn't make the real ones look stopped, as it's taken at their time.
    @Test func aFeedStampedFarAheadDoesntStaleTheOthers() throws {
        let future = Proto.feed(made: Date(timeIntervalSince1970: 3_800_000_000))
        let others = FeedFixtures.data.values.filter { $0 != CountdownKit.fixture("-nqrw") }
        // No more than a minute past the batch's middle stamp, 10:27:26
        let newest = try #require(SubwayFeed.newest(Array(others) + [future, CountdownKit.fixture("-nqrw")]))
        #expect(newest == Date(timeIntervalSince1970: 1_794_324_446 + 60))
        let arrivals = try TrainService.arrivals(at: ["R34N"], own: [CountdownKit.fixture("-nqrw")],
                                                 others: Array(others) + [future], now: cap)
        #expect(arrivals.contains { $0.trip == "061900_R..N93R" })
        // By itself, never stale: a frozen feed stamped ahead goes on as long as its stamp is ahead
        #expect(!SubwayFeed.isStale(made: Date(timeIntervalSince1970: 3_800_000_000),
                                    newest: Date(timeIntervalSince1970: 3_800_000_000), now: cap))
    }

    /// One stamped 4 minutes before the rest fails as its own line, and is left out as another's.
    @Test func aFeedStampedBehindIsStale() throws {
        let old = Proto.feed(made: cap.addingTimeInterval(-4 * 60),
                             [Proto.trip("old", stops: [("R34N", CountdownKit.at(300)), ("G08N", CountdownKit.at(3000))])])
        let fresh = CountdownKit.fixture("-bdfm")
        #expect(throws: FeedError.stale) {
            try TrainService.arrivals(at: ["R34N"], own: [old], others: [fresh], now: cap)
        }
        #expect(try TrainService.arrivals(at: ["R34N"], own: [fresh], others: [old], now: cap).allSatisfy { $0.trip != "old" })
        // Stamped before 2000, it has no stamp: not a feed
        let ancient = Proto.feed(made: Date(timeIntervalSince1970: 600_000_000))
        #expect(SubwayFeed.made(ancient) == nil)
        #expect(!TrainService.isUsable(ancient, from: nqrw))
    }

    /// Times outside 2000–2100, or none, count as no time: such stops aren't arrivals.
    @Test func implausibleStopTimesAreNone() throws {
        let feed = Proto.feed(made: cap, [
            Proto.trip("none", stops: [("R34N", Date(timeIntervalSince1970: 0)), ("G08N", CountdownKit.at(900))]),
            Proto.trip("far", stops: [("R34N", Date(timeIntervalSince1970: 5_000_000_000)), ("G08N", CountdownKit.at(900))]),
            Proto.trip("ok", stops: [("R34N", CountdownKit.at(300)), ("G08N", CountdownKit.at(900))]),
        ])
        #expect(try SubwayFeed.arrivals(at: ["R34N"], in: feed, now: cap).map(\.trip) == ["ok"])
    }
}

/// The phone's clock against the feeds', and Pretend Time.
struct ClockSkewTests {
    /// A phone up to 10 minutes fast still reads the feeds; past that they're taken as stopped.
    @Test func aFastPhoneReadsTheFeedsUpToTenMinutes() throws {
        #expect(SubwayFeed.staleAfter == 3 * 60)
        #expect(SubwayFeed.clockAllowance == 7 * 60)
        let fast = cap.addingTimeInterval(9 * 60)
        #expect(!(try CountdownKit.arrivals(CountdownKit.prospect, now: fast)).isEmpty)
        #expect(throws: FeedError.stale) {
            try CountdownKit.arrivals(CountdownKit.prospect, now: cap.addingTimeInterval(10 * 60 + 30))
        }
    }

    /// A phone an hour slow reads them, and its board has every train still to come by its clock.
    @Test func aSlowPhoneReadsTheFeeds() throws {
        let slow = cap.addingTimeInterval(-3600)
        let trains = try CountdownKit.trains(CountdownKit.unionSquare, now: slow)
        #expect(trains.contains { $0.trip == "057800_Q..N" })
    }

    /// Pretend Time makes every feed stale, for the timetable's; under a second isn't pretending.
    @Test func pretendTimeMakesFeedsStale() {
        let saved = AppClock.offset
        defer { AppClock.offset = saved }
        AppClock.offset = 0
        #expect(!SubwayFeed.isStale(made: cap, newest: cap, now: cap))
        AppClock.offset = 0.5
        #expect(!AppClock.isPretending)
        AppClock.offset = 3600
        let pretending = SubwayFeed.isStale(made: cap, newest: cap, now: cap)
        let real = AppClock.real(AppClock.now)
        AppClock.offset = saved
        #expect(pretending)
        #expect(abs(real.timeIntervalSinceNow) < 5)
    }

    /// Pretend and real times undo each other.
    @Test func pretendAndRealUndoEachOther() {
        let date = Fixtures.date("2026-11-10 08:15")
        #expect(AppClock.real(AppClock.pretend(date)) == date)
    }
}

/// Midnight, and the two days a year New York's clocks change.
struct ServiceDayTests {
    /// A countdown just before midnight moves on past it to the trains after.
    @Test func aCountdownRunsOnPastMidnight() {
        let train = Fixtures.date("2026-11-11 00:00:05")
        let state = CountdownState(train: train, trip: "late", isLive: true, terminal: nil,
                                   following: [Fixtures.date("2026-11-11 00:04"), Fixtures.date("2026-11-11 00:09")],
                                   notice: nil, updated: Fixtures.date("2026-11-10 23:59:50"))
        #expect(MinutesToGo(until: train, from: Fixtures.date("2026-11-10 23:57")).count == 3)
        #expect(state.movedOn(at: Fixtures.date("2026-11-11 00:00:15"), holding: AtStation.seconds) == state)
        let moved = state.movedOn(at: Fixtures.date("2026-11-11 00:00:20"), holding: AtStation.seconds)
        #expect(moved.train == Fixtures.date("2026-11-11 00:04"))
        #expect(moved.following == [Fixtures.date("2026-11-11 00:09")])
    }

    /// A service day's 23:55 trip gets to the stop at 00:05 the next day, its approach from the start.
    @Test func aTimetableTripRunsPastMidnight() throws {
        let base = Fixtures.date("2026-11-10 00:00")
        let timetable = Timetable(made: base, base: base, stops: ["T00N", "R34N", "T99N"], routes: ["R"],
                                  patterns: [Timetable.Pattern(route: 0, calls: [
                                      Timetable.Call(stop: 0, arrives: 0, waits: 0),
                                      Timetable.Call(stop: 1, arrives: 600, waits: 30),
                                      Timetable.Call(stop: 2, arrives: 1200, waits: 0),
                                  ])],
                                  starts: [[86_100, 3600]])
        let arrivals = timetable.arrivals(at: ["R34N"], from: Fixtures.date("2026-11-10 23:58"),
                                          to: Fixtures.date("2026-11-11 00:30"))
        let late = try #require(arrivals.first)
        #expect(arrivals.count == 1)
        #expect(late.time == Fixtures.date("2026-11-11 00:05"))
        #expect(late.departure == Fixtures.date("2026-11-11 00:05:30"))
        #expect(late.approach.map(\.id) == ["T00N", "R34N"])
        #expect(!late.isLive)
        #expect(timetable.covers(Fixtures.date("2026-11-11 00:10")))
        #expect(!timetable.covers(Fixtures.date("2026-11-11 00:20")))
    }

    /// On 2026-11-01 the 1 am hour comes twice: trains every 30 minutes stay 30 minutes apart.
    @Test func fallBackKeepsTimetableTrainsEvenlyApart() {
        let base = Fixtures.date("2026-11-01 00:00")
        let timetable = CountdownKit.timetable(base: base, stop: "R34N", every: 1800, count: 12)
        let arrivals = timetable.arrivals(at: ["R34N"], from: base, to: base.addingTimeInterval(4 * 3600))
            .sorted { $0.time < $1.time }
        #expect(arrivals.count == 8)
        #expect(zip(arrivals, arrivals.dropFirst()).allSatisfy { $1.time.timeIntervalSince($0.time) == 1800 })
        let clock = DateFormatter()
        clock.timeZone = Fixtures.newYork
        clock.dateFormat = "HH:mm"
        #expect(arrivals.filter { clock.string(from: $0.time) == "01:02" }.count == 2)
        #expect(MinutesToGo(until: Fixtures.date("2026-11-01 02:30"), from: Fixtures.date("2026-11-01 00:30")).count == 180)
    }

    /// On 2027-03-14 the 2 am hour doesn't happen: 1:30 to 3:00 is half an hour.
    @Test func springForwardSkipsAnHour() {
        #expect(MinutesToGo(until: Fixtures.date("2027-03-14 03:00"), from: Fixtures.date("2027-03-14 01:30")).count == 30)
        let base = Fixtures.date("2027-03-14 00:00")
        let timetable = CountdownKit.timetable(base: base, stop: "R34N", every: 1800, count: 12)
        let arrivals = timetable.arrivals(at: ["R34N"], from: Fixtures.date("2027-03-14 01:30"),
                                          to: Fixtures.date("2027-03-14 03:30"))
        // 01:32 EST and 03:02 EDT, half an hour apart, as every trip is
        #expect(arrivals.count == 2)
    }

    /// An outage date in the fall-back hour reads; one in the hour that doesn't exist keeps its row.
    @Test func outageDatesOnClockChangeDays() throws {
        let rows = """
        [{"equipment":"EL131","serving":"x","reason":"Repair","outagedate":"11/01/2026 01:30:00 AM",
          "estimatedreturntoservice":"03/14/2027 02:30:00 AM","isupcomingoutage":"N"}]
        """
        let outages = try OutagesFeed.outages(atComplex: "604", in: Data(rows.utf8))
        let outage = try #require(outages.first)
        #expect(outage.start != nil)
        #expect(outage.serving == "X")
    }
}

/// Odd trains in the feeds: twice under one trip, on lines or at stops nobody knows.
struct OddTrainTests {
    /// The same trip id twice at one stop is one train on the board, the sooner.
    @Test func aDuplicatedTripIsOneTrain() throws {
        let feed = Proto.feed(made: cap, [
            Proto.trip("dup", stops: [("R34N", CountdownKit.at(300)), ("G08N", CountdownKit.at(3000))]),
            Proto.trip("dup", stops: [("R34N", CountdownKit.at(600)), ("G08N", CountdownKit.at(3300))]),
        ])
        let arrivals = try TrainService.arrivals(at: ["R34N"], own: [feed], others: [], now: cap)
        #expect(arrivals.count == 2)
        let trains = TrainService.trains(for: CountdownKit.prospect, in: arrivals, now: cap)
        #expect(trains.map(\.time) == [CountdownKit.at(300)])
    }

    /// A line nobody knows to a stop nobody knows is shown, as if rerouted, with no terminal.
    @Test func anUnknownLineAndTerminal() throws {
        let feed = Proto.feed(made: cap, [Proto.trip("odd", route: "ZZ", stops: [("R34N", CountdownKit.at(240)), ("XX99N", CountdownKit.at(900))])])
        let trains = TrainService.trains(for: CountdownKit.prospect,
                                         in: try TrainService.arrivals(at: ["R34N"], own: [feed], others: [], now: cap), now: cap)
        let odd = try #require(trains.first)
        #expect(odd.route == "ZZ")
        #expect(odd.terminal == nil)
        let state = try #require(CountdownState(for: CountdownKit.prospect, trains: trains, notice: nil, now: cap,
                                                following: nil, after: nil))
        #expect(state.terminal == nil)
        #expect(state.route == "ZZ")
    }

    /// A station nobody knows has no stops, no trains, and no countdown.
    @Test func anUnknownStation() throws {
        let selection = Selection(stationID: "ZZZ", routes: ["R"], direction: .north)
        #expect(selection.stopIDs.isEmpty)
        #expect(try CountdownKit.trains(selection, now: cap).isEmpty)
        #expect(CountdownState(for: selection, trains: [], notice: nil, now: cap, following: nil, after: nil) == nil)
        #expect(TrainService.outages(for: selection, in: Data("[]".utf8)) == [])
    }

    /// With every bus already gone, there's no bus countdown; one due a little sooner is still it.
    @Test func busCountdownEdges() throws {
        let gone = [CountdownBus(line: "B63", destination: nil, time: cap.addingTimeInterval(-5), isLive: true)]
        #expect(CountdownState(buses: gone, after: nil, now: cap) == nil)
        #expect(CountdownState(buses: [], after: nil, now: cap) == nil)
        let buses = [CountdownBus(line: "B63", destination: nil, time: CountdownKit.at(100), isLive: true),
                     CountdownBus(line: "B63", destination: nil, time: CountdownKit.at(250), isLive: false)]
        let state = try #require(CountdownState(buses: buses, after: CountdownKit.at(300), now: cap))
        #expect(state.train == CountdownKit.at(250))
        #expect(!state.isLive)
    }
}

/// Alerts and outages that don't read, or are far bigger than they should be.
struct BrokenNoticeTests {
    /// An error page or the wrong shape doesn't read as alerts; one bad alert loses only itself.
    @Test func malformedAlerts() throws {
        #expect(throws: (any Error).self) { try AlertsFeed.entries(in: Data("<html></html>".utf8), now: cap) }
        #expect(throws: (any Error).self) { try AlertsFeed.entries(in: Data(#"{"entity":"x"}"#.utf8), now: cap) }
        #expect(throws: (any Error).self) { try AlertsFeed.entries(in: Data(), now: cap) }
        let mixed = #"""
        {"entity":[{"id":5,"alert":{}},{"id":"noalert"},
          {"id":"bad","alert":{"active_period":[{"start":"soon"}]}},
          {"id":"ok","alert":{"header_text":{"translation":[{"text":"Hi","language":"en"}]}}}]}
        """#
        #expect(try AlertsFeed.entries(in: Data(mixed.utf8), now: cap).count == 1)
        #expect(!TrainService.isUsable(Data(#"{"entity":["#.utf8), from: AlertsFeed.url))
    }

    /// Ten times the alerts read as ten times as many, and still find the Q's planned work.
    @Test func tenTimesTheAlerts() throws {
        let data = try Fixtures.data("weekday1030-alerts.json")
        var feed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entities = try #require(feed["entity"] as? [Any])
        feed["entity"] = Array(repeating: entities, count: 10).flatMap { $0 }
        let big = try JSONSerialization.data(withJSONObject: feed)
        #expect(big.count > 9 * data.count)
        #expect(TrainService.isUsable(big, from: AlertsFeed.url))
        let once = try AlertsFeed.entries(in: data, now: cap)
        let tenfold = try AlertsFeed.entries(in: big, now: cap)
        #expect(tenfold.count == 10 * once.count)
        let alerts = AlertsFeed.alerts(for: CountdownKit.cortelyou, in: tenfold, now: cap)
        #expect(alerts.contains { $0.id == "lmm:planned_work:35535" })
        // Merged, each once
        #expect(AlertsFeed.merged([alerts]).filter { $0.id == "lmm:planned_work:35535" }.count == 1)
    }

    /// Outage rows that don't read are skipped; a feed that doesn't is unavailable.
    @Test func malformedOutages() throws {
        let rows = #"[{"equipment":"EL131"},{"nope":1},5,{"equipment":"EL135","outagedate":"garbage"}]"#
        let outages = try OutagesFeed.outages(atComplex: "604", in: Data(rows.utf8))
        #expect(outages.count == 2)
        #expect(outages.allSatisfy { $0.start == nil })
        #expect(TrainService.outages(for: CountdownKit.yankeeStadium, in: Data("<html>".utf8)) == nil)
        #expect(TrainService.outages(for: CountdownKit.yankeeStadium, in: Data(#"{"a":1}"#.utf8)) == nil)
    }
}

/// Timetable files that aren't one, or claim to be huge.
struct BrokenTimetableTests {
    func compressed(_ bytes: [UInt8]) throws -> Data {
        try (Data(bytes) as NSData).compressed(using: .zlib) as Data
    }

    func header(version: UInt8, patterns: UInt32) -> [UInt8] {
        var bytes: [UInt8] = Array("LWTT".utf8) + [version]
        withUnsafeBytes(of: Int64(1_794_000_000).littleEndian) { bytes += $0 }
        withUnsafeBytes(of: Int64(1_794_000_000).littleEndian) { bytes += $0 }
        bytes += [0, 0, 0, 0]
        if version >= 2 { bytes += [0] }
        withUnsafeBytes(of: patterns.littleEndian) { bytes += $0 }
        return bytes
    }

    /// Not zlib, a wrong magic, an unknown version or a cut-off file: each refused.
    @Test func whatIsntATimetableIsRefused() throws {
        #expect(throws: (any Error).self) { try Timetable(data: Data("hello".utf8)) }
        #expect(throws: (any Error).self) { try Timetable(data: Data()) }
        #expect(throws: (any Error).self) { try Timetable(data: try compressed(Array("NOPE".utf8) + [1])) }
        #expect(throws: (any Error).self) { try Timetable(data: try compressed(header(version: 3, patterns: 0))) }
        let real = try CountdownKit.timetable(base: cap, stop: "R34N").encoded()
        #expect(try Timetable(data: real).stops == ["T00N", "R34N", "T99N"])
        let raw = try (real as NSData).decompressed(using: .zlib) as Data
        #expect(throws: (any Error).self) { try Timetable(data: try compressed(Array(raw.dropLast(3)))) }
    }

    /// One claiming more patterns than it has, or than can be indexed, is refused, not allocated.
    @Test func aTimetableClaimingTooMuchIsRefused() throws {
        #expect(throws: (any Error).self) { try Timetable(data: try compressed(header(version: 1, patterns: 1 << 20 + 1))) }
        #expect(throws: (any Error).self) { try Timetable(data: try compressed(header(version: 2, patterns: 1 << 20))) }
        #expect(try Timetable(data: try compressed(header(version: 1, patterns: 0))).patterns.isEmpty)
    }

    /// An empty timetable covers nothing and has no trains.
    @Test func anEmptyTimetableCoversNothing() {
        let empty = Timetable(made: cap, base: cap, stops: [], routes: [], patterns: [], starts: [])
        #expect(!empty.covers(cap))
        #expect(empty.arrivals(at: ["R34N"], from: cap, to: CountdownKit.at(3600)).isEmpty)
    }
}

/// Fetching when the network fails partway, and many asking for the same feed at once.
struct FlakyNetworkTests {
    func isRelay(_ made: TestNetwork.Made) -> Bool { made.url.host == relayHost }
    func isMTA(_ made: TestNetwork.Made) -> Bool { made.url.host == CountdownKit.mtaHost }

    /// Six identical fetches at once download the feed once.
    @Test func identicalFetchesAtOnceShareOneDownload() async throws {
        let part = TrainService.FeedPart(stops: [CountdownKit.uniqueStop()])
        let body = CountdownKit.fixture("-nqrw")
        let (results, made) = await withNetwork({ _ in .ok(body, delay: .milliseconds(300)) }) {
            await withTaskGroup(of: Data?.self) { group in
                for _ in 0..<6 { group.addTask { await TrainService.optionalData(from: nqrw, part: part) } }
                return await group.reduce(into: [Data?]()) { $0.append($1) }
            }
        }
        #expect(results.count == 6)
        #expect(results.allSatisfy { $0 == body })
        #expect(made.count == 1)
        #expect(made.allSatisfy(isRelay))
    }

    /// A fetch for some of the stops of one in flight joins it; one moments later reuses it.
    @Test func aNarrowerFetchJoinsOneInFlight() async throws {
        let (one, two) = (CountdownKit.uniqueStop(), CountdownKit.uniqueStop())
        let body = CountdownKit.fixture("-nqrw")
        let (results, made) = await withNetwork({ _ in .ok(body, delay: .milliseconds(400)) }) {
            async let both = TrainService.optionalData(from: nqrw, part: .init(stops: [one, two]))
            try? await Task.sleep(for: .milliseconds(50))
            async let some = TrainService.optionalData(from: nqrw, part: .init(stops: [one]))
            let first = await [both, some]
            let later = await TrainService.optionalData(from: nqrw, part: .init(stops: [two]))
            return first + [later]
        }
        #expect(results.allSatisfy { $0 == body })
        #expect(made.count == 1)
    }

    /// With the push server's copy failing, the MTA's is used.
    @Test func aFailedRelayFallsBackOnTheMTA() async throws {
        let part = TrainService.FeedPart(stops: [CountdownKit.uniqueStop()])
        let host = relayHost
        let (data, made) = await withNetwork({ request in
            request.url?.host == host ? nil : FeedFixtures.respond(request)
        }) {
            await TrainService.optionalData(from: nqrw, part: part)
        }
        #expect(data == CountdownKit.fixture("-nqrw"))
        #expect(made.filter(isRelay).count == 1)
        #expect(made.filter(isMTA).count == 1)
    }

    /// A relay answering a cut-off feed, an empty 200 or a 500: the MTA's is used each time.
    @Test(arguments: ["cut", "empty", "500"])
    func aBadRelayAnswerFallsBackOnTheMTA(_ kind: String) async throws {
        let part = TrainService.FeedPart(stops: [CountdownKit.uniqueStop()])
        let host = relayHost
        let full = CountdownKit.fixture("-nqrw")
        let bad: TestNetwork.Answer = switch kind {
        case "cut": .ok(full.prefix(full.count / 3))
        case "empty": .ok(Data())
        default: .status(500)
        }
        let (data, made) = await withNetwork({ request in
            request.url?.host == host ? bad : FeedFixtures.respond(request)
        }) {
            await TrainService.optionalData(from: nqrw, part: part)
        }
        #expect(data == full)
        #expect(made.contains(where: isMTA))
    }

    /// A relay that stalls past 1.5 s has the MTA asked alongside, and whichever's first wins.
    @Test func aStalledRelayIsHedgedWithTheMTA() async throws {
        let part = TrainService.FeedPart(stops: [CountdownKit.uniqueStop()])
        let host = relayHost
        let full = CountdownKit.fixture("-nqrw")
        let started = Date.now
        let (data, made) = await withNetwork({ request in
            request.url?.host == host ? .ok(full, delay: .seconds(5)) : FeedFixtures.respond(request)
        }) {
            await TrainService.optionalData(from: nqrw, part: part)
        }
        #expect(data == full)
        #expect(made.contains(where: isMTA))
        #expect(Date.now.timeIntervalSince(started) < 4.5)
    }

    /// Both failing, or both answering garbage: no feed.
    @Test func bothFailingIsNoFeed() async throws {
        let (none, made) = await withNetwork {
            await TrainService.optionalData(from: nqrw, part: .init(stops: [CountdownKit.uniqueStop()]))
        }
        #expect(none == nil)
        #expect(made.count == 2)
        let (garbage, _) = await withNetwork({ _ in .ok(Data("<html>".utf8)) }) {
            await TrainService.optionalData(from: nqrw, part: .init(stops: [CountdownKit.uniqueStop()]))
        }
        #expect(garbage == nil)
    }

    /// Without its own line's feed, and no timetable, the board fails.
    @Test func aBoardWithoutItsOwnFeedFails() async {
        let selection = Selection(stationID: "R41", routes: ["N", "R"], direction: .north)
        await withNetwork(CountdownKit.respond(failing: ["weekday1030-feed-nqrw.pb"])) {
            await #expect(throws: (any Error).self) {
                try await TrainService.board(for: selection, includingAlerts: false, includingOutages: false,
                                             now: cap)
            }
        }
    }

    /// Its own line's feed stopped 5 minutes before the others: the board fails as stale.
    @Test func aBoardWhoseOwnFeedStoppedFailsStale() async {
        let selection = Selection(stationID: "R41", routes: ["N", "R"], direction: .north)
        let stopped = Proto.feed(made: cap.addingTimeInterval(-5 * 60),
                                 [Proto.trip("stopped", stops: [("R41N", CountdownKit.at(300)), ("R01N", CountdownKit.at(3000))])])
        await withNetwork(CountdownKit.respond(replaced: ["weekday1030-feed-nqrw.pb": stopped])) {
            await #expect(throws: FeedError.stale) {
                try await TrainService.board(for: selection, includingAlerts: false, includingOutages: false,
                                             now: cap)
            }
        }
    }

    /// Another line's feed failing just leaves out its rerouted trains.
    @Test func anotherLinesFeedFailingStillMakesTheBoard() async throws {
        let (board, _) = try await withNetwork(CountdownKit.respond(failing: ["weekday1030-feed-bdfm.pb", "weekday1030-feed-ace.pb"])) {
            try await TrainService.board(for: CountdownKit.prospect, includingAlerts: false, includingOutages: false,
                                         now: cap)
        }
        #expect(board.trains.first?.trip == "061900_R..N93R")
        #expect(board.scheduledRoutes.isEmpty)
    }

    /// Alerts offline with nothing saved are unavailable, not none.
    @Test func alertsOfflineWithNothingSavedAreUnavailable() async {
        let (alerts, _) = await withNetwork {
            await TrainService.alertEntries(routes: ["R", CountdownKit.uniqueStop()])
        }
        #expect(alerts == nil)
        let (notices, _) = await withNetwork {
            await TrainService.notices(for: Selection(stationID: "D30", routes: ["Q"], direction: .south),
                                       includingAlerts: false, includingOutages: false)
        }
        #expect(notices.alerts == nil && notices.outages == nil)
    }
}
