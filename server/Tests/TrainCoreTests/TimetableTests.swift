import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import TrainCore

/// A GTFS folder with `files` (name to contents), deleted after `body`.
private func withGTFS<T>(_ files: [String: String], _ body: (URL) throws -> T) throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gtfs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for (name, contents) in files {
        try Data(contents.utf8).write(to: folder.appendingPathComponent(name))
    }
    return try body(folder)
}

/// New York's wall clock time.
private func newYork(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimetableBuilder.newYork
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute,
                                              second: second))!
}

/// Weekday R trips from Bay Ridge-95 St (R45N) by 86 St (R44N) and 77 St (R43N), two of them the
/// same time apart; a Saturday one; one after midnight; and a 6X. Thursday 22 October 2026 is
/// today; Friday the 23rd has no weekday service, and Saturday the 24th adds an extra trip.
private let gtfs = [
    "calendar.txt": """
        service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
        Weekday,1,1,1,1,1,0,0,20261001,20261231
        Saturday,0,0,0,0,0,1,0,20261001,20261231
        Old,1,1,1,1,1,1,1,20250101,20250201
        """,
    "calendar_dates.txt": """
        service_id,date,exception_type
        Weekday,20261023,2
        Extra,20261024,1
        """,
    "trips.txt": """
        route_id,trip_id,service_id,trip_headsign,direction_id,shape_id
        R,W-0800,Weekday,"Forest Hills, 71 Av",0,R..N
        R,W-0810,Weekday,Forest Hills,0,R..N
        R,W-LATE,Weekday,Forest Hills,0,R..N
        R,S-0900,Saturday,Forest Hills,0,R..N
        R,E-1000,Extra,Forest Hills,0,R..N
        R,O-0800,Old,Forest Hills,0,R..N
        6X,X-0800,Weekday,Pelham Bay Park,0,6..N
        """,
    "stop_times.txt": """
        trip_id,stop_id,arrival_time,departure_time,stop_sequence
        W-0800,R44N,08:02:00,08:02:30,2
        W-0800,R45N,08:00:00,08:00:00,1
        W-0800,R43N,08:04:00,08:04:00,3
        W-0810,R45N,08:10:00,08:10:00,1
        W-0810,R44N,08:12:00,08:12:30,2
        W-0810,R43N,08:14:00,08:14:00,3
        W-LATE,R45N,24:50:00,24:50:00,1
        W-LATE,R44N,24:53:00,24:53:00,2
        S-0900,R45N,09:00:00,09:00:00,1
        S-0900,R44N,09:03:00,09:03:00,2
        E-1000,R45N,10:00:00,10:00:00,1
        E-1000,R44N,10:03:00,10:03:00,2
        O-0800,R45N,08:00:00,08:00:00,1
        O-0800,R44N,08:02:00,08:02:00,2
        X-0800,629N,08:00:00,08:00:00,1
        X-0800,627N,08:03:00,08:03:00,2
        """,
]

private let today = newYork(2026, 10, 22, 7)

@Suite struct TimetableTests {
    @Test func coversYesterdaysServiceDayToAWeekOn() {
        let days = TimetableBuilder.serviceDays(around: today)
        #expect(days.map(\.date) == ["20261021", "20261022", "20261023", "20261024", "20261025", "20261026",
                                     "20261027", "20261028", "20261029"])
        #expect(days[1].start == newYork(2026, 10, 22, 0))
    }

    @Test func countsADaysTimesFromNoonLessTwelveHours() {
        // The clocks go back at 2:00 on 1 November 2026: noon less 12 hours is 1:00 EDT, not midnight
        let days = TimetableBuilder.serviceDays(around: newYork(2026, 11, 1, 15))
        #expect(days[1].date == "20261101")
        #expect(days[1].start == Date(timeIntervalSince1970: 1_793_509_200)) // 2026-11-01 05:00 UTC
    }

    @Test func readsTimesPastMidnight() {
        #expect(TimetableBuilder.seconds("08:02:30") == 8 * 3600 + 150)
        #expect(TimetableBuilder.seconds("25:03:00") == 25 * 3600 + 180)
        #expect(TimetableBuilder.seconds(" 8:00:00") == 8 * 3600)
        #expect(TimetableBuilder.seconds("") == nil)
    }

    @Test func runsServicesByWeekdayDatesAndExceptions() throws {
        let calendar = try withGTFS(gtfs) { folder in
            try TimetableBuilder.ServiceCalendar(calendar: folder.appendingPathComponent("calendar.txt"),
                                                 dates: folder.appendingPathComponent("calendar_dates.txt"))
        }
        #expect(calendar.runs("Weekday", on: "20261022"))
        #expect(!calendar.runs("Weekday", on: "20261023")) // removed
        #expect(!calendar.runs("Weekday", on: "20261024")) // Saturday
        #expect(calendar.runs("Saturday", on: "20261024"))
        #expect(calendar.runs("Extra", on: "20261024")) // added, with no calendar.txt row
        #expect(!calendar.runs("Old", on: "20261022")) // ended
        #expect(!calendar.runs("Nothing", on: "20261022"))
    }

    @Test func readsQuotedFieldsAndShortRows() throws {
        var rows: [[String]] = []
        try CSV.rows(in: Data("\u{FEFF}a,b,c\r\n\"x, \"\"y\"\"\",2,3\r\n4,5\n\n".utf8), columns: ["c", "a"]) { rows.append($0) }
        #expect(rows == [["3", "x, \"y\""], ["", "4"]])
        #expect(throws: TimetableBuilder.Problem.self) {
            try CSV.rows(in: Data("a,b\n1,2\n".utf8), columns: ["z"]) { _ in }
        }
    }

    @Test func sharesPatternsBetweenTripsTheSameTimeApart() throws {
        let timetable = try withGTFS(gtfs) { try TimetableBuilder.build(from: $0, now: today) }
        #expect(timetable.made == today)
        #expect(timetable.base == newYork(2026, 10, 21, 0))
        #expect(Set(timetable.routes) == ["R", "6X"])
        // W-0800 and W-0810 share one; W-LATE, S-0900 and E-1000 (two stops, three minutes
        // apart) another; the 6X its own. Old runs on none of the days
        #expect(timetable.patterns.count == 3)
        // Weekday trips on the 21st, 22nd and 26th to 29th; the Saturday one on the 24th, as is the extra
        let trips = timetable.starts.reduce(0) { $0 + $1.count }
        #expect(trips == 3 * 6 + 1 + 1 + 6)
    }

    @Test func leavesOutTripsWhoseTimesGoBackwardsOrDontFit() throws {
        var broken = gtfs
        broken["trips.txt"]! += """

            R,B-0805,Weekday,Forest Hills,0,R..N
            R,N-0000,Weekday,Forest Hills,0,R..N
            R,L-0800,Weekday,Forest Hills,0,R..N
            """
        broken["stop_times.txt"]! += """

            B-0805,R45N,08:05:00,08:05:00,1
            B-0805,R44N,08:04:00,08:04:00,2
            B-0805,R43N,08:10:00,08:10:00,3
            N-0000,R45N,-1:00:00,-1:00:00,1
            N-0000,R44N,00:02:00,00:02:00,2
            L-0800,R45N,08:00:00,08:00:00,1
            L-0800,R44N,27:00:00,27:00:00,2
            """
        let timetable = try withGTFS(broken) { try TimetableBuilder.build(from: $0, now: today) }
        // Just as without them
        #expect(timetable.patterns.count == 3)
        #expect(timetable.starts.reduce(0) { $0 + $1.count } == 3 * 6 + 1 + 1 + 6)
    }

    @Test func listsTrainsAtAStopAsTheFeedsWould() throws {
        let timetable = try withGTFS(gtfs) { try TimetableBuilder.build(from: $0, now: today) }
        let now = newYork(2026, 10, 22, 8, 1)
        let arrivals = timetable.arrivals(at: ["R44N"], from: now, to: newYork(2026, 10, 22, 9))
            .sorted { $0.time < $1.time }
        #expect(arrivals.map(\.time) == [newYork(2026, 10, 22, 8, 2), newYork(2026, 10, 22, 8, 12)])
        let first = try #require(arrivals.first)
        #expect(first.route == "R")
        #expect(first.departure == newYork(2026, 10, 22, 8, 2, 30))
        #expect(first.lastStop == "R43N")
        #expect(!first.isLive)
        #expect(first.trip.hasPrefix("timetable "))
        #expect(first.trip != arrivals[1].trip)
        // From the stop it's left, as it's due to have at 8:01
        #expect(first.approach.map(\.id) == ["R45N", "R44N"])
        // Not yet set off
        #expect(arrivals[1].approach.map(\.id) == ["R45N", "R44N"])
        #expect(arrivals[1].approach.first?.time == newYork(2026, 10, 22, 8, 10))
    }

    @Test func keepsATrainWaitingAtThePlatformAndFoldsExpresses() throws {
        let timetable = try withGTFS(gtfs) { try TimetableBuilder.build(from: $0, now: today) }
        // Arrived at 8:02, leaves at 8:02:30
        let waiting = timetable.arrivals(at: ["R44N"], from: newYork(2026, 10, 22, 8, 2, 15), to: newYork(2026, 10, 22, 8, 5))
        #expect(waiting.map(\.time) == [newYork(2026, 10, 22, 8, 2)])
        #expect(timetable.arrivals(at: ["627N"], from: today, to: newYork(2026, 10, 22, 9)).map(\.route) == ["6"])
    }

    @Test func runsAServiceDaysLateTripsAfterMidnight() throws {
        let timetable = try withGTFS(gtfs) { try TimetableBuilder.build(from: $0, now: today) }
        // Yesterday's (the 21st's) 24:53 is today at 00:53
        let late = timetable.arrivals(at: ["R44N"], from: newYork(2026, 10, 22, 0), to: newYork(2026, 10, 22, 2))
        #expect(late.map(\.time) == [newYork(2026, 10, 22, 0, 53)])
        // No weekday trips on Friday the 23rd, nor its 24:53 on Saturday morning
        let friday = timetable.arrivals(at: ["R44N"], from: newYork(2026, 10, 23, 2), to: newYork(2026, 10, 24, 8))
        #expect(friday.isEmpty)
        #expect(timetable.covers(today))
        #expect(!timetable.covers(newYork(2026, 10, 30, 2)))
    }

    @Test func roundTripsThroughItsFile() throws {
        let timetable = try withGTFS(gtfs) { try TimetableBuilder.build(from: $0, now: today) }
        let read = try Timetable(data: try timetable.encoded())
        #expect(read.made == timetable.made)
        #expect(read.base == timetable.base)
        #expect(read.stops == timetable.stops)
        #expect(read.routes == timetable.routes)
        #expect(read.patterns == timetable.patterns)
        #expect(read.starts == timetable.starts)
        let from = newYork(2026, 10, 22, 0), to = newYork(2026, 10, 30, 0)
        #expect(Set(read.arrivals(at: ["R44N", "627N"], from: from, to: to))
            == Set(timetable.arrivals(at: ["R44N", "627N"], from: from, to: to)))
    }

    @Test func refusesWhatIsntOne() throws {
        #expect(throws: Timetable.Problem.self) { try Timetable(data: Data("not a timetable".utf8)) }
        let timetable = try withGTFS(gtfs) { try TimetableBuilder.build(from: $0, now: today) }
        // Cut short
        let raw = try (try timetable.encoded() as NSData).decompressed(using: .zlib) as Data
        let short = try (raw.prefix(raw.count - 3) as NSData).compressed(using: .zlib) as Data
        #expect(throws: Timetable.Problem.self) { try Timetable(data: short) }
    }

    @Test func buildsAtFourInTheMorningNewYorkTime() {
        #expect(TimetableMaker.nextBuild(after: newYork(2026, 10, 22, 4, 5), hour: 4) == newYork(2026, 10, 23, 4))
        #expect(TimetableMaker.nextBuild(after: newYork(2026, 10, 22, 3), hour: 4) == newYork(2026, 10, 22, 4))
    }

    @Test func savesWhatItBuildsAndKeepsItWhenABuildFails() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("maker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let timetable = try withGTFS(gtfs) { try TimetableBuilder.build(from: $0, now: today) }
        let copy = TimetableCopy()
        let maker = TimetableMaker(copy: copy, directory: folder) { _ in timetable }
        #expect(await maker.rebuild() == today)
        let saved = try Data(contentsOf: folder.appendingPathComponent("timetable.bin"))
        #expect(await copy.data == saved)
        let etag = try #require(await copy.etag)
        // Read together, as `GET /timetable` reads them
        let current = try #require(await copy.current)
        #expect(current.data == saved && current.etag == etag)
        #expect(await TimetableCopy().current == nil)

        struct Failed: Error {}
        let failing = TimetableMaker(copy: copy, directory: folder) { _ in throw Failed() }
        #expect(await failing.rebuild() == nil)
        #expect(await copy.data == saved)
        #expect(await copy.etag == etag)
    }

    @Test func servesWhatItBuildsThoughItCantSaveIt() async throws {
        let timetable = try withGTFS(gtfs) { try TimetableBuilder.build(from: $0, now: today) }
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)/data")
        let copy = TimetableCopy()
        let maker = TimetableMaker(copy: copy, directory: nowhere) { _ in timetable }
        // Made, so not built again within the hour
        #expect(await maker.rebuild() == today)
        #expect(await copy.data == (try timetable.encoded()))
    }

    @Test func servesItWithAnETag() async throws {
        let timetable = try withGTFS(gtfs) { try TimetableBuilder.build(from: $0, now: today) }
        let copy = TimetableCopy()
        let services = HTTPServices(store: try Store(directory: nil), auth: .secret("test-secret-0123456789abcdef"),
                                    appID: testAppID, limits: testLimits(), timetable: copy)
        try await Application(router: HTTPRoutes.router(services)).test(.router) { client in
            // Not built yet
            try await client.execute(uri: "/timetable", method: .get) { #expect($0.status == .serviceUnavailable) }
            let data = try timetable.encoded()
            await copy.set(data, made: today)
            let etag = try #require(await copy.etag)
            try await client.execute(uri: "/timetable", method: .get) { response in
                #expect(response.status == .ok)
                #expect(Data(response.body.readableBytesView) == data)
                #expect(response.headers[.eTag] == etag)
            }
            try await client.execute(uri: "/timetable", method: .get, headers: [.ifNoneMatch: etag]) { response in
                #expect(response.status == .notModified)
                #expect(response.body.readableBytes == 0)
            }
            try await client.execute(uri: "/timetable", method: .get, headers: [.ifNoneMatch: "\"old\""]) {
                #expect($0.status == .ok)
            }
        }
    }

    @Test func makesABoardFromTheTimetable() throws {
        let timetable = try withGTFS(gtfs) { try TimetableBuilder.build(from: $0, now: today) }
        let bayRidge = Selection(stationID: "R44", routes: ["R"], direction: .north)
        let at = newYork(2026, 10, 22, 8, 1)
        let board = TrainService.board(for: bayRidge, arrivingAt: StationDirectory.station(id: "R43"), from: timetable,
                                       now: at)
        // Only the next three hours': not tonight's 00:53
        #expect(board.trains.map(\.time) == [newYork(2026, 10, 22, 8, 2), newYork(2026, 10, 22, 8, 12)])
        #expect(board.alerts == nil)
        #expect(board.outages == nil)
        let first = try #require(board.trains.first)
        #expect(board.destinationTimes[first.trip] == newYork(2026, 10, 22, 8, 4))
        // As the Nearby widget and the Nearby tab ask, by train
        let trains = TrainService.trains(for: [bayRidge, bayRidge], from: timetable, now: at)
        #expect(trains.keys.sorted() == [bayRidge.trainID])
        #expect(trains[bayRidge.trainID]?.map(\.time) == board.trains.map(\.time))
    }

    @Test func fillsInAfterTheSavedTrains() {
        let saved = [arrival(-5, trip: "gone"), arrival(2, trip: "a"), arrival(9, trip: "b")]
        let timetable = [arrival(5, trip: "t1", isLive: false), arrival(12, trip: "t2", isLive: false)]
        // The saved ones' guess is better until their last; the timetable's after it
        #expect(TimelinePlan.filling(saved, from: timetable, selection: prospect, now: now).map(\.trip) == ["a", "b", "t2"])
        // None left to catch: just the timetable's
        #expect(TimelinePlan.filling([arrival(-5, trip: "gone")], from: timetable, selection: prospect, now: now)
            .map(\.trip) == ["t1", "t2"])
        #expect(TimelinePlan.filling([], from: timetable, selection: prospect, now: now).map(\.trip) == ["t1", "t2"])
    }

    /// The MTA's own GTFS, unzipped into TIMETABLE_GTFS, to see how big and quick it is.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TIMETABLE_GTFS"] != nil))
    func buildsTheMTAsTimetable() throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TIMETABLE_GTFS"]))
        let clock = ContinuousClock()
        let start = clock.now
        let timetable = try TimetableBuilder.build(from: folder)
        let built = clock.now
        let data = try timetable.encoded()
        let read = try Timetable(data: data)
        let decoded = clock.now
        print("timetable: \(timetable.patterns.count) patterns, \(timetable.starts.reduce(0) { $0 + $1.count }) trips, "
            + "\(timetable.stops.count) stops, routes \(timetable.routes.sorted()), \(data.count / 1024) KB; "
            + "built in \(built - start), read in \(decoded - built)")
        let at86 = read.arrivals(at: ["R44N"], from: .now, to: Date.now.addingTimeInterval(60 * 60))
        print("timetable: next hour at 86 St (R44N): \(at86.sorted { $0.time < $1.time }.map { "\($0.route) \($0.time)" })")
        #expect(read.covers(.now))
        #expect(!at86.isEmpty)
    }
}
