import Foundation
import Testing
@testable import Leeway

/// What the countdown tests share: the saved feeds' moment, boards made from them, and small
/// timetables and trains of their own.
enum CountdownKit {
    /// When the fixtures were read: 10:27:28 New York time, 2026-11-10.
    static var cap: Date { FeedFixtures.capturedAt }

    static func at(_ seconds: TimeInterval) -> Date { cap.addingTimeInterval(seconds) }

    /// Prospect Av, Manhattan-bound R: only R's to Forest Hills.
    static let prospect = Selection(stationID: "R34", routes: ["R"], direction: .north)
    /// 14 St-Union Sq, uptown N Q R W.
    static let unionSquare = Selection.fallback
    /// 161 St-Yankee Stadium, B D toward 205 St, with elevator alerts.
    static let yankeeStadium = Selection(stationID: "D11", routes: ["B", "D"], direction: .north, elevatorAlerts: true)
    /// Cortelyou Rd, Manhattan-bound Q, skipped by planned work at 10:30.
    static let cortelyou = Selection(stationID: "D30", routes: ["Q"], direction: .north)

    static let mtaHost = "api-endpoint.mta.info"

    static func fixtureData(for url: URL) -> Data? {
        FeedFixtures.fixture(for: url).flatMap { FeedFixtures.data[$0] }
    }

    static func fixture(_ suffix: String) -> Data {
        FeedFixtures.data[FeedFixtures.feeds[suffix]!]!
    }

    /// `selection`'s arrivals in the saved feeds, its own lines' and the others', at `now`.
    static func arrivals(_ selection: Selection, now: Date) throws -> [Arrival] {
        let urls = Lines.feedURLs(sharingTracksWith: selection.routes)
        return try TrainService.arrivals(at: Set(selection.stopIDs), own: urls.own.compactMap(fixtureData),
                                         others: urls.others.compactMap(fixtureData), now: now)
    }

    /// The trains a board for `selection` lists from the saved feeds at `now`.
    static func trains(_ selection: Selection, now: Date) throws -> [Arrival] {
        TrainService.trains(for: selection, in: try arrivals(selection, now: now), now: now)
    }

    /// Fixtures for every feed but `failing` (fixture names), which go unanswered, and
    /// `replaced`, answered with their bytes.
    static func respond(failing: Set<String> = [], replaced: [String: Data] = [:])
        -> @Sendable (URLRequest) -> TestNetwork.Answer? {
        { request in
            guard let url = request.url, let name = FeedFixtures.fixture(for: url) else { return nil }
            if failing.contains(name) { return nil }
            if let data = replaced[name] { return .ok(data) }
            return FeedFixtures.respond(request)
        }
    }

    static func arrival(_ time: Date, trip: String, route: String = "R", stop: String = "R34N",
                        lastStop: String = "G08N", isLive: Bool = true) -> Arrival {
        Arrival(route: route, time: time, stop: stop, lastStop: lastStop, isLive: isLive, trip: trip)
    }

    /// One pattern on `route`: from T00N, at `stop` `rideIn` seconds on, to T99N, a trip every
    /// `every` seconds from `base`, `count` of them.
    static func timetable(base: Date, stop: String, route: String = "R", every: UInt32 = 600, count: Int = 24,
                          rideIn: UInt16 = 120) -> Timetable {
        Timetable(made: base, base: base, stops: ["T00N", stop, "T99N"], routes: [route],
                  patterns: [Timetable.Pattern(route: 0, calls: [
                      Timetable.Call(stop: 0, arrives: 0, waits: 0),
                      Timetable.Call(stop: 1, arrives: rideIn, waits: 0),
                      Timetable.Call(stop: 2, arrives: rideIn + 600, waits: 0),
                  ])],
                  starts: [(0..<count).map { UInt32($0) * every }])
    }

    /// A stop id no other test asks for, so a fetch of it shares nothing in flight or recent.
    static func uniqueStop() -> String {
        "Z" + UUID().uuidString.prefix(8) + "N"
    }
}

/// Feeds kept across processes, for the offline fallback: `saved`, as saved at `savedAt`, under
/// any name. Records what's saved.
final class SavedFeeds: FeedCaching, @unchecked Sendable {
    private let lock = NSLock()
    private let saved: Data?
    private let savedAt: Date
    private var saves: [Data] = []

    init(_ saved: Data?, savedAt: Date) {
        self.saved = saved
        self.savedAt = savedAt
    }

    var keeps: TimeInterval { SharedStore.FeedCache().keeps }

    func data(for name: String, within age: TimeInterval) -> Data? {
        savedAt.isWithin(age, before: .now) ? saved : nil
    }

    func save(_ data: Data, for name: String) {
        lock.withLock { saves.append(data) }
    }

    /// What's been saved, in order.
    var recorded: [Data] { lock.withLock { saves } }
}

/// The real feeds, as the phone reads them.
struct SavedFeedTests {
    /// The capture time is the newest feed header's, and every feed reads whole and fresh then.
    @Test func everySavedFeedReadsWholeAndFreshAtCapture() throws {
        #expect(CountdownKit.cap == Date(timeIntervalSince1970: 1_794_324_448))
        #expect(FeedFixtures.data.count == 8)
        for (name, data) in FeedFixtures.data {
            let made = try #require(SubwayFeed.made(data), "\(name)")
            #expect(CountdownKit.cap.timeIntervalSince(made) < 30, "\(name)")
            #expect(SubwayFeed.isWhole(data), "\(name)")
            #expect(throws: Never.self) {
                try SubwayFeed.arrivals(at: [], in: data, newest: CountdownKit.cap, now: CountdownKit.cap)
            }
        }
    }

    /// Each feed's trips, counted without reading them, as saved.
    @Test func tripCountsMatchTheSavedFeeds() {
        let expected = ["": 290, "-ace": 128, "-bdfm": 173, "-g": 25, "-jz": 24, "-l": 36, "-nqrw": 131, "-si": 6]
        for (suffix, count) in expected {
            #expect(SubwayFeed.tripCount(CountdownKit.fixture(suffix)) == count, "\(suffix)")
        }
    }

    /// Prospect Av's next R is live, to Forest Hills, 8.5 minutes off, stopped at 59 St.
    @Test func prospectAvsNextRFromTheRealFeed() throws {
        let arrivals = try SubwayFeed.arrivals(at: ["R34N"], in: CountdownKit.fixture("-nqrw"), now: CountdownKit.cap)
        let next = try #require(arrivals.first { $0.time > CountdownKit.cap })
        #expect(next.trip == "061900_R..N93R")
        #expect(next.time == CountdownKit.at(508))
        #expect(next.isLive)
        #expect(next.route == "R")
        #expect(next.lastStop == "G08N")
        #expect(next.terminal == "Forest Hills")
        #expect(next.approach.last?.id == "R34N")
        #expect(next.position == Arrival.Position(stop: "R41N", isStopped: true))
        #expect(arrivals == arrivals.sorted { $0.time < $1.time })
    }

    /// The board drops a Q gone 23 s before, and lists the rest soonest first, each trip once.
    @Test func unionSquaresBoardFromTheRealFeeds() throws {
        let trains = try CountdownKit.trains(CountdownKit.unionSquare, now: CountdownKit.cap)
        #expect(!trains.contains { $0.trip == "057800_Q..N" })
        #expect(trains.first?.trip == "057050_Q..N36R")
        #expect(trains.first?.time == CountdownKit.at(205))
        #expect(Array(trains.prefix(4).map(\.route)) == ["Q", "R", "N", "W"])
        #expect(Set(trains.map(\.trip)).count == trains.count)
        #expect(trains.allSatisfy { $0.time > CountdownKit.cap })
    }

    /// The 7's feed lists trip 054300_7..N twice; a board keeps it once.
    @Test func theRealDuplicateTripIsKeptOnce() throws {
        let arrivals = try SubwayFeed.arrivals(at: ["725N"], in: CountdownKit.fixture(""), now: CountdownKit.cap)
        #expect(arrivals.filter { $0.trip == "054300_7..N" }.count == 2)
        #expect(arrivals.oncePerTrip().filter { $0.trip == "054300_7..N" }.count == 1)
    }

    /// The stops after Prospect Av on the R, each with a ride time that only grows.
    @Test func timedStopsAfterProspectAv() throws {
        let lists = try SubwayFeed.timedStops(after: ["R34N"], on: ["R"], in: CountdownKit.fixture("-nqrw"))
        #expect(!lists.isEmpty)
        for list in lists {
            let rides = list.compactMap(\.ride)
            #expect(rides == rides.sorted())
            #expect(rides.allSatisfy { $0 > 0 })
        }
    }
}

/// The countdown's state from the real boards, and its 15 s "At Station".
struct CountdownFromFeedTests {
    let settings = AppSettings()

    /// With no walk it starts on the next R; with a 10-minute walk, the one after.
    @Test func startsOnTheFirstReachableRealTrain() throws {
        let trains = try CountdownKit.trains(CountdownKit.prospect, now: CountdownKit.cap)
        let state = try #require(CountdownState(for: CountdownKit.prospect, trains: trains, notice: nil,
                                                now: CountdownKit.cap, following: nil, after: nil))
        #expect(state.trip == "061900_R..N93R")
        #expect(state.train == CountdownKit.at(508))
        #expect(state.following == [CountdownKit.at(808), CountdownKit.at(1442)])
        #expect(state.followingRoutes == ["R", "R"])
        #expect(state.terminal == "Forest Hills")
        #expect(state.isLive)

        var walking = CountdownKit.prospect
        walking.walkMinutes = 10
        let later = try #require(CountdownState(for: walking, trains: trains, notice: nil, now: CountdownKit.cap,
                                                following: nil, after: nil))
        #expect(later.trip == "062550_R..N93R")
    }

    /// On the Lock Screen a train is "At Station" 15 s once due, then the next; a bus 5 s.
    @Test func lockScreenHoldsAtStationFifteenSeconds() throws {
        let trains = try CountdownKit.trains(CountdownKit.unionSquare, now: CountdownKit.cap)
        let state = try #require(CountdownState(for: CountdownKit.unionSquare, trains: trains, notice: nil,
                                                now: CountdownKit.cap, following: nil, after: nil))
        #expect(AtStation.seconds == 15)
        #expect(AtStation.label == "At Station")
        #expect(state.heldSeconds == 15)
        let due = state.train
        #expect(state.movedOn(at: due.addingTimeInterval(14.9), holding: AtStation.seconds) == state)
        #expect(state.movedOn(at: due.addingTimeInterval(15), holding: AtStation.seconds).train == state.following[0])
        // Without the push server, iOS redraws it once it's been there, moving on by itself
        #expect(state.staleDate(pushedOn: false) == due.addingTimeInterval(15))
        #expect(state.staleDate(pushedOn: true) == due)
        var bus = state
        bus.route = "bus:B63"
        #expect(bus.heldSeconds == AtStation.busSeconds)
        #expect(AtStation.busSeconds == 5)
    }

    /// Widgets without a walk get an entry 15 s after each train's due, and show it there till then.
    @Test func widgetsShowAtStationFifteenSeconds() throws {
        let selection = CountdownKit.unionSquare
        let trains = try CountdownKit.trains(selection, now: CountdownKit.cap)
        let dates = TimelinePlan.dates(after: CountdownKit.cap, toCatch: trains, selection: selection, everyMinute: false)
        for train in trains.prefix(TimelinePlan.trainsAhead) {
            #expect(dates.contains(train.time.addingTimeInterval(15)))
        }
        let first = try #require(trains.first)
        #expect(TimelinePlan.atStation(first, at: first.time.addingTimeInterval(10), selection: selection))
        #expect(!TimelinePlan.atStation(first, at: first.time.addingTimeInterval(15), selection: selection))
        var walking = selection
        walking.walkMinutes = 4
        #expect(!TimelinePlan.atStation(first, at: first.time.addingTimeInterval(10), selection: walking))
    }

    /// The walking screen's train in at the platform is one due under 15 s ago.
    @Test func walkingScreenAtStationIsFifteenSeconds() {
        let due = CountdownKit.at(205)
        #expect(!AtStation.covers(due, at: due.addingTimeInterval(-0.1)))
        #expect(AtStation.covers(due, at: due))
        #expect(AtStation.covers(due, at: due.addingTimeInterval(14.9)))
        #expect(!AtStation.covers(due, at: due.addingTimeInterval(15)))
    }

    /// Refreshed with the real board 5 s after its train's due, it should still say "At Station".
    @Test func aRefreshWhileAtStationKeepsTheTrain() throws {
        // The Q due 23 s before capture, counted down to; refreshed 5 s after it's due
        let due = CountdownKit.at(-23)
        let now = due.addingTimeInterval(5)
        let selection = CountdownKit.unionSquare
        let board = Board(trains: try CountdownKit.trains(selection, now: now))
        let state = CountdownState(train: due, trip: "057800_Q..N", isLive: true, terminal: nil,
                                   following: [CountdownKit.at(205), CountdownKit.at(298)], notice: nil,
                                   updated: CountdownKit.at(-120), route: "Q", followingRoutes: ["Q", "R"])
        // A board lists only trains that haven't left (`TrainService.trains`), so the train at the
        // platform is gone from it: kept, with the board's trains after it
        #expect(!board.trains.contains { $0.trip == "057800_Q..N" })
        let held = state.refreshed(for: selection, board: board, settings: settings, now: now)
        #expect(held.train == due)
        #expect(held.trip == "057800_Q..N")
        #expect(held.following == Array(board.trains.prefix(2).map(\.time)))
        #expect(held.updated == now)
        // Once it's been there, on to the next
        let gone = state.refreshed(for: selection, board: board, settings: settings, now: due.addingTimeInterval(16))
        #expect(gone.train == CountdownKit.at(205))
    }

    /// A refresh follows the same trip as its time moves.
    @Test func aRefreshFollowsTheSameRealTrip() throws {
        let selection = CountdownKit.prospect
        let trains = try CountdownKit.trains(selection, now: CountdownKit.cap)
        let started = try #require(CountdownState(for: selection, trains: trains, notice: nil,
                                                  now: CountdownKit.cap.addingTimeInterval(-60), following: nil, after: nil))
        let moved = trains.map { train in
            train.trip == started.trip ? CountdownKit.arrival(train.time.addingTimeInterval(90), trip: train.trip) : train
        }
        let refreshed = started.refreshed(for: selection, board: Board(trains: moved), settings: settings, now: CountdownKit.cap)
        #expect(refreshed.trip == started.trip)
        #expect(refreshed.train == started.train.addingTimeInterval(90))
        #expect(refreshed.updated == CountdownKit.cap)
    }
}

/// "Of leeway": the minutes over before a train, after the walk.
struct LeewayPhrasingTests {
    /// Labels say "of leeway", or "No leeway" under a minute.
    @Test func labelsSayOfLeeway() {
        #expect(Leeway.label(6) == "6 minutes of leeway")
        #expect(Leeway.label(1) == "1 minute of leeway")
        #expect(Leeway.label(0) == "No leeway")
        #expect(Leeway.label(-3) == "No leeway")
        #expect(Leeway.label(6, short: true) == "6 mins of leeway")
        #expect(Leeway.label(1, short: true) == "1 min of leeway")
    }

    /// A change's leeway is its wait less its walk, rounded down, never under none.
    @Test func changeLeewayIsWaitLessWalk() {
        let off = CountdownKit.at(600)
        let train = CountdownKit.arrival(CountdownKit.cap, trip: "a")
        let arrival = CountdownKit.arrival(off, trip: "a", stop: "R31N")
        let next = { (seconds: TimeInterval) in CountdownKit.arrival(off.addingTimeInterval(seconds), trip: "b", route: "D", stop: "R31N") }
        let roomy = Connection(first: train, arrival: arrival, next: next(7 * 60 + 50), walk: 3 * 60)
        // Seconds as a typed TimeInterval, to the second: the literal's own type isn't left to the macro
        let roomyLeeway: TimeInterval = 4 * 60 + 50
        #expect(abs((roomy.leeway ?? -1) - roomyLeeway) < 0.001)
        #expect(roomy.leewayMinutes == 4)
        #expect(roomy.spokenLeeway == "4 minutes of leeway")
        let tight = Connection(first: train, arrival: arrival, next: next(2 * 60), walk: 3 * 60)
        #expect(abs((tight.leeway ?? -1) - 0) < 0.001)
        #expect(tight.spokenLeeway == "no leeway")
        let none = Connection(first: train, arrival: arrival, next: nil, walk: 3 * 60)
        #expect(none.leeway == nil)
        #expect(none.spokenLeeway == "No train to change to")
    }
}

/// Alerts and outages from the saved feeds.
struct SavedNoticesTests {
    /// The Manhattan-bound Q skipping Cortelyou Rd at 10:30 is its alert, not the other way's.
    @Test func plannedWorkAlertForTheQAtCortelyou() throws {
        let entries = try AlertsFeed.entries(in: try Fixtures.data("weekday1030-alerts.json"), now: CountdownKit.cap)
        // Of 190, those in effect now or within the hour
        #expect(!entries.isEmpty && entries.count <= 16)
        let north = AlertsFeed.alerts(for: CountdownKit.cortelyou, in: entries, now: CountdownKit.cap)
        let alert = try #require(north.first { $0.id == "lmm:planned_work:35535" })
        #expect(alert.kind == .serviceChange)
        #expect(!alert.header.contains("["))
        let south = AlertsFeed.alerts(for: CountdownKit.cortelyou.otherWay, in: entries, now: CountdownKit.cap)
        #expect(!south.contains { $0.id == "lmm:planned_work:35535" })
        // Over by 3:20 pm
        let after = AlertsFeed.alerts(for: CountdownKit.cortelyou, in: entries,
                                      now: Date(timeIntervalSince1970: 1_794_340_800 + 60))
        #expect(!after.contains { $0.id == "lmm:planned_work:35535" })
    }

    /// At 161 St the B/D's two elevators out are listed, not the 4 platform's.
    @Test func elevatorsOutAtYankeeStadium() throws {
        let data = try Fixtures.data("weekday1030-outages.json")
        let outages = try #require(TrainService.outages(for: CountdownKit.yankeeStadium, in: data))
        #expect(outages.map { String($0.id.prefix(5)) } == ["EL135", "EL131"])
        let board = Board(trains: [], outages: outages)
        #expect(board.elevatorsOut.count == 2)
        let notice = try #require(board.notice(for: CountdownKit.yankeeStadium, settings: AppSettings()))
        #expect(notice.label == "2 elevators out")
        #expect(notice.kind == .elevator)
        #expect(notice.text.hasPrefix("Mezzanine to B/D platform"))
        // Unavailable is nil, unlike none
        #expect(TrainService.outages(for: CountdownKit.yankeeStadium, in: nil) == nil)
    }
}

/// Boards fetched through `TrainService`, answered by the saved feeds.
struct FeedFetchTests {
    /// A board's feeds come from the push server's copies, never the MTA, with their stops.
    @Test func boardComesFromThePushServersCopies() async throws {
        let (board, made) = try await withNetwork(FeedFixtures.respond) {
            try await TrainService.board(for: CountdownKit.unionSquare, includingAlerts: false, includingOutages: false,
                                         now: CountdownKit.cap)
        }
        #expect(board.trains.first?.trip == "057050_Q..N36R")
        #expect(board.alerts == nil)
        #expect(board.scheduledRoutes.isEmpty)
        #expect(!made.contains { $0.url.host == CountdownKit.mtaHost })
        #expect(made.allSatisfy { $0.url.path == "/feeds" && ($0.url.query ?? "").contains("stops=") })
    }

    /// A board's alerts are those in effect at its `now`, not the clock's: the Q's 10:30 planned work.
    @Test func boardAlertsAreThoseAtItsOwnTime() async throws {
        let (board, made) = try await withNetwork(FeedFixtures.respond) {
            try await TrainService.board(for: CountdownKit.cortelyou, includingAlerts: true, includingOutages: false,
                                         now: CountdownKit.cap)
        }
        #expect(made.contains { ($0.url.query ?? "").contains("subway-alerts") })
        #expect(board.alerts?.contains { $0.id == "lmm:planned_work:35535" } == true)
        // A month on, the same feed has none of it then
        let later = CountdownKit.cap.addingTimeInterval(30 * 24 * 3600)
        let (entries, _) = await withNetwork(FeedFixtures.respond) {
            await TrainService.alertEntries(routes: ["Q", CountdownKit.uniqueStop()], now: later)
        }
        let alerts = AlertsFeed.alerts(for: CountdownKit.cortelyou, in: try #require(entries), now: later)
        #expect(!alerts.contains { $0.id == "lmm:planned_work:35535" })
    }

    /// Outages come with the board, for the elevators out at the selection's platforms.
    @Test func boardWithOutages() async throws {
        let (board, _) = try await withNetwork(FeedFixtures.respond) {
            try await TrainService.board(for: CountdownKit.yankeeStadium, includingAlerts: false, includingOutages: true,
                                         now: CountdownKit.cap)
        }
        #expect(board.complete)
        #expect(board.elevatorsOut.count == 2)
        #expect(!board.trains.isEmpty)
        #expect(board.outages?.count == 2)
    }

    /// Without the E's feed, 7 Av's E trains are the timetable's, and the B and D still live.
    @Test func aLineWithoutItsFeedIsFilledFromTheTimetable() async throws {
        let selection = Selection(stationID: "D14", routes: ["B", "D", "E"], direction: .north)
        let stop = try #require(selection.stopIDs.first)
        let timetable = CountdownKit.timetable(base: CountdownKit.cap.addingTimeInterval(-3600), stop: stop, route: "E",
                                               every: 600, count: 30)
        let respond = CountdownKit.respond(failing: ["weekday1030-feed-ace.pb"])
        let (board, _) = try await withNetwork(respond) {
            try await TrainService.board(for: selection, includingAlerts: false, includingOutages: false,
                                         fillingFrom: { timetable }, now: CountdownKit.cap)
        }
        #expect(board.scheduledRoutes == ["E"])
        let es = board.trains.filter { $0.route == "E" }
        #expect(!es.isEmpty)
        #expect(es.allSatisfy { !$0.isLive && $0.trip.hasPrefix("timetable ") })
        #expect(board.trains.contains { $0.route != "E" && $0.isLive })
        // Without one, the board fails
        await withNetwork(respond) {
            await #expect(throws: (any Error).self) {
                try await TrainService.board(for: selection, includingAlerts: false, includingOutages: false,
                                             now: CountdownKit.cap)
            }
        }
    }

    /// The board from the timetable alone, offline: not live, no alerts or outages.
    @Test func offlineBoardFromTheTimetable() throws {
        let base = Fixtures.date("2026-11-10 05:00")
        let timetable = CountdownKit.timetable(base: base, stop: "R34N", every: 600, count: 100)
        let now = Fixtures.date("2026-11-10 08:15")
        let board = TrainService.board(for: CountdownKit.prospect, from: timetable, now: now)
        #expect(!board.trains.isEmpty)
        #expect(board.trains.allSatisfy { !$0.isLive && $0.time > now })
        #expect(board.trains.allSatisfy { $0.time <= now.addingTimeInterval(TrainService.timetableAhead) })
        #expect(board.alerts == nil && board.outages == nil)
        let state = try #require(CountdownState(for: CountdownKit.prospect, board: board, settings: AppSettings(),
                                                now: now, following: nil, after: nil))
        #expect(!state.isLive)
        #expect(state.following.count == 2)
    }
}

/// Save for Offline: the 30-day timetable downloaded, kept and checked, and alerts kept a week.
@Suite(.enabled(if: SharedStore.isAvailable))
struct OfflineTimetableTests {
    /// A timetable file of its own, removed after.
    final class Scratch {
        let name = "test-timetable-" + UUID().uuidString.prefix(8)
        lazy var file = TimetableFile(name: name, refreshAfter: 20 * 60 * 60, failedKey: name + "Failed")

        var url: URL { SharedStore.url(named: "\(name).bin")! }

        func age(by seconds: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-seconds)],
                                                  ofItemAtPath: url.path)
        }

        deinit {
            try? FileManager.default.removeItem(at: SharedStore.url(named: "\(name).bin")!)
            try? FileManager.default.removeItem(at: SharedStore.url(named: "\(name)-etag.txt")!)
            let defaults = UserDefaults(suiteName: SharedStore.groupID)
            defaults?.removeObject(forKey: name + "Failed")
            defaults?.removeObject(forKey: "\(name)DownloadStarted")
        }
    }

    /// A month's timetable from `base`: a trip an hour for 30 days.
    func month(from base: Date) throws -> Data {
        try CountdownKit.timetable(base: base, stop: "R34N", every: 3600, count: 30 * 24).encoded()
    }

    /// Downloaded for 30 days, saved, loaded while it covers now, and not after it ends.
    @Test func downloadsAMonthAndLoadsItWhileItCovers() async throws {
        let scratch = Scratch()
        let base = Fixtures.date("2026-11-10 00:00")
        let body = try month(from: base)
        #expect(scratch.file.isDue())
        let (_, made) = await withNetwork({ _ in TestNetwork.Answer(headers: ["ETag": "\"v1\""], body: body) }) {
            await scratch.file.refresh()
        }
        let request = try #require(made.first)
        #expect(made.count == 1)
        #expect(request.url.path == "/" + scratch.name)
        #expect(request.url.query == "days=30")
        #expect(request.headers["If-None-Match"] == nil)
        #expect(!scratch.file.isDue())
        #expect(scratch.file.load(now: base.addingTimeInterval(29 * 24 * 3600))?.stops.contains("R34N") == true)
        // Past its 30 days, nothing to fall back on
        #expect(scratch.file.load(now: base.addingTimeInterval(31 * 24 * 3600)) == nil)
        #expect(scratch.file.load(now: base.addingTimeInterval(-1)) == nil)
        // Not due, not asked again
        let (_, again) = await withNetwork({ _ in .ok(body) }) { await scratch.file.refresh() }
        #expect(again.isEmpty)
    }

    /// Asked again with its ETag once due; a 304 keeps it, checked now.
    @Test func anUnchangedOneIsKeptOnA304() async throws {
        let scratch = Scratch()
        let base = Fixtures.date("2026-11-10 00:00")
        let body = try month(from: base)
        await withNetwork({ _ in TestNetwork.Answer(headers: ["ETag": "\"v1\""], body: body) }) {
            await scratch.file.refresh()
        }
        try scratch.age(by: 21 * 60 * 60)
        #expect(scratch.file.isDue())
        let (_, made) = await withNetwork({ _ in .status(304) }) { await scratch.file.refresh() }
        #expect(made.first?.headers["If-None-Match"] == "\"v1\"")
        #expect(!scratch.file.isDue())
        #expect(scratch.file.load(now: base.addingTimeInterval(3600)) != nil)
    }

    /// One that doesn't read keeps the old, and isn't tried again for a while unless forced.
    @Test func aBadDownloadKeepsTheOldAndWaitsToRetry() async throws {
        let scratch = Scratch()
        let base = Fixtures.date("2026-11-10 00:00")
        let body = try month(from: base)
        await withNetwork({ _ in .ok(body) }) { await scratch.file.refresh() }
        try scratch.age(by: 21 * 60 * 60)
        await withNetwork({ _ in .ok(Data("<html>502</html>".utf8)) }) { await scratch.file.refresh() }
        #expect(scratch.file.load(now: base.addingTimeInterval(3600)) != nil)
        try scratch.age(by: 21 * 60 * 60)
        #expect(scratch.file.retryAfter == 5 * 60)
        let (_, waited) = await withNetwork({ _ in .ok(body) }) { await scratch.file.refresh() }
        #expect(waited.isEmpty)
        let (_, forced) = await withNetwork({ _ in .ok(body) }) { await scratch.file.refresh(force: true) }
        #expect(forced.count == 1)
        #expect(!scratch.file.isDue())
    }

    /// Offline, a failed download leaves the one there, and a 500 the same.
    @Test func offlineKeepsTheOneThere() async throws {
        let scratch = Scratch()
        let base = Fixtures.date("2026-11-10 00:00")
        let body = try month(from: base)
        await withNetwork({ _ in .ok(body) }) { await scratch.file.refresh() }
        await withNetwork { await scratch.file.refresh(force: true) }
        await withNetwork({ _ in .status(500) }) { await scratch.file.refresh(force: true) }
        #expect(scratch.file.load(now: base.addingTimeInterval(10 * 24 * 3600)) != nil)
    }

    /// The buses' timetable isn't asked for a month: a week, every few days.
    @Test func theSubwaysIsDailyAndTheBusesEveryFewDays() {
        #expect(TimetableStore.subway.refreshAfter == 20 * 60 * 60)
        #expect(TimetableStore.buses.refreshAfter == 3 * 24 * 60 * 60)
        #expect(!TimetableStore.isExtension)
    }

    /// Alerts are kept a week to fall back on offline.
    @Test func alertsAreKeptAWeek() {
        #expect(SharedStore.FeedCache().keeps == 7 * 24 * 60 * 60)
    }

    /// Offline, the alerts saved two days ago are used; ones saved over a week ago aren't.
    @Test func offlineAlertsFallBackOnAWeeksCopy() async throws {
        let alerts = try Fixtures.data("weekday1030-alerts.json")
        let previous = TrainService.sharedCache
        defer { TrainService.sharedCache = previous }
        let (recent, _) = await withNetwork {
            TrainService.sharedCache = SavedFeeds(alerts, savedAt: .now.addingTimeInterval(-2 * 24 * 3600))
            defer { TrainService.sharedCache = previous }
            return await TrainService.alertEntries(routes: ["R", CountdownKit.uniqueStop()])
        }
        #expect(recent != nil)
        let (old, _) = await withNetwork {
            TrainService.sharedCache = SavedFeeds(alerts, savedAt: .now.addingTimeInterval(-8 * 24 * 3600))
            defer { TrainService.sharedCache = previous }
            return await TrainService.alertEntries(routes: ["R", CountdownKit.uniqueStop()])
        }
        #expect(old == nil)
    }

    /// Alerts fetched are saved for offline, and a copy under 3 minutes old is used without asking.
    @Test func alertsAreSavedAndReusedForAFewMinutes() async throws {
        let alerts = try Fixtures.data("weekday1030-alerts.json")
        let previous = TrainService.sharedCache
        defer { TrainService.sharedCache = previous }
        let empty = SavedFeeds(nil, savedAt: .now)
        let (fetched, made) = await withNetwork(FeedFixtures.respond) {
            TrainService.sharedCache = empty
            defer { TrainService.sharedCache = previous }
            return await TrainService.alertEntries(routes: ["Q", CountdownKit.uniqueStop()])
        }
        #expect(fetched != nil)
        #expect(made.count == 1)
        #expect(empty.recorded == [alerts])
        let (reused, none) = await withNetwork(FeedFixtures.respond) {
            TrainService.sharedCache = SavedFeeds(alerts, savedAt: .now.addingTimeInterval(-60))
            defer { TrainService.sharedCache = previous }
            return await TrainService.alertEntries(routes: ["Q", CountdownKit.uniqueStop()])
        }
        #expect(reused != nil)
        #expect(none.isEmpty)
    }
}

/// The app's own countdown pieces: background tasks, push tokens, the Lock Screen's lookup.
struct CountdownAppTests {
    /// Both background refreshes are in Info.plist's permitted identifiers.
    @Test func backgroundRefreshesArePermitted() throws {
        let permitted = try #require(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        #expect(permitted.contains(TimetableStore.refreshTaskID))
        #expect(permitted.contains(ActivityPush.refreshTaskID))
    }

    /// Push tokens are lowercase hex, two digits a byte.
    @Test func pushTokensAreLowercaseHex() {
        #expect(CountdownLookup.hex(Data([0x00, 0xAB, 0x10, 0xFF])) == "00ab10ff")
        #expect(CountdownLookup.hex(Data()) == "")
    }

    /// With no countdown for a train, there's no state, current train or push server backing.
    @MainActor
    @Test func noCountdownForATrainNobodyStarted() async {
        let selection = Selection(stationID: "R41", routes: ["N", "R"], direction: .south)
        #expect(await CountdownLookup.state(for: "nobody:" + UUID().uuidString, localOnly: true) == nil)
        #expect(TrainActivityController.currentTrain(for: selection) == nil)
        #expect(!ActivityPush.isServerBacked(UUID().uuidString))
    }

    /// A bus countdown's id names its lines and stop.
    @Test func busCountdownID() {
        let stop = BusStop(id: "308209", name: "5 AV/9 ST", latitude: 40.67, longitude: -73.98, direction: "N")
        #expect(BusChoice(line: "B63", lines: ["B63", "B103"], stop: stop).countdownID == "bus:B63,B103@308209")
        #expect(BusChoice(line: "B63", stop: stop).countdownID == "bus:B63@308209")
    }

    /// A bus countdown counts down to the next bus and the two after, held 5 s at the stop.
    @Test func busCountdownFromBusTime() throws {
        let now = CountdownKit.cap
        let buses = [60, 300, 600, 900].map {
            CountdownBus(line: $0 == 300 ? "B103" : "B63", destination: "Cobble Hill", time: now.addingTimeInterval(TimeInterval($0)), isLive: true)
        }
        let state = try #require(CountdownState(buses: buses, after: nil, now: now))
        #expect(state.train == now.addingTimeInterval(60))
        #expect(state.route == "bus:B63")
        #expect(state.followingRoutes == ["bus:B103", "bus:B63"])
        #expect(state.heldSeconds == 5)
        #expect(state.staleDate(pushedOn: false) == now.addingTimeInterval(65))
    }
}
