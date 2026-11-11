import CoreLocation
import CryptoKit
import Foundation
import Testing
import WidgetKit
@testable import Leeway

// MARK: - Support

/// Helpers for this folder's tests: feeds of their own (so no other test's fetch is reused for
/// them), throwaway files, and timetables to download.
enum WNSupport {
    static var server: URL { TrainService.serverURL! }

    /// A feed address only this test asks for: an MTA train feed's, as far as `TrainService` can
    /// tell, so it's relayed and hedged as one, but shared with no other test's fetch.
    static func uniqueFeed() -> URL {
        URL(string: TrainService.mtaFeeds + "nyct%2Fgtfs-wn\(UUID().uuidString.prefix(8).lowercased())")!
    }

    /// A real train feed's bytes, which `TrainService.isUsable` takes.
    static let feedBytes: Data = (try? Fixtures.data("weekday1030-feed-nqrw.pb")) ?? Data()

    static func isRelay(_ url: URL) -> Bool { url.host == server.host && url.path.hasSuffix("/feeds") }
    static func isMTA(_ url: URL) -> Bool { url.absoluteString.hasPrefix(TrainService.mtaFeeds) }

    /// The saved feeds, by their MTA address.
    static var fixtureFeeds: [URL: Data] {
        Dictionary(uniqueKeysWithValues: FeedFixtures.feeds.compactMap { suffix, name in
            FeedFixtures.data[name].map { (URL(string: TrainService.mtaFeeds + "nyct%2Fgtfs\(suffix)")!, $0) }
        })
    }

    /// A file in the temporary directory, not yet made.
    static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "wn-\(UUID().uuidString).json")
    }

    static func json(_ text: String) -> Data { Data(text.utf8) }

    /// A place no other test asks about, so no answer kept for it is reused.
    static func uniqueLocation() -> CLLocation {
        CLLocation(latitude: 40.68 + Double.random(in: 0..<0.01), longitude: -73.98 + Double.random(in: 0..<0.01))
    }

    /// A one-trip timetable that covers now, as the server sends it.
    static func timetableBytes(now: Date = .now) throws -> Data {
        let calls = [Timetable.Call(stop: 0, arrives: 0, waits: 0), Timetable.Call(stop: 1, arrives: 120, waits: 0)]
        return try Timetable(made: now, base: now.addingTimeInterval(-3600), stops: ["L29N", "L28N"], routes: ["L"],
                             patterns: [Timetable.Pattern(route: 0, calls: calls)], starts: [[7200]]).encoded()
    }

    /// A timetable file of this test's own name, so the real one and its failure marks are untouched.
    static func timetableFile() -> (file: TimetableFile, name: String) {
        let name = "wntest-\(UUID().uuidString.prefix(8).lowercased())"
        return (TimetableFile(name: name, refreshAfter: 20 * 60 * 60, failedKey: "\(name)Failed"), name)
    }

    /// Removes `timetableFile()`'s files and marks.
    static func removeTimetable(_ name: String) {
        for file in ["\(name).bin", "\(name)-etag.txt"] {
            if let url = SharedStore.url(named: file) { try? FileManager.default.removeItem(at: url) }
        }
        let defaults = UserDefaults(suiteName: SharedStore.groupID)
        defaults?.removeObject(forKey: "\(name)Failed")
        defaults?.removeObject(forKey: "\(name)DownloadStarted")
    }

    /// A train at `minutes` from `now`.
    static func arrival(_ minutes: Double, from now: Date, route: String = "R", stop: String = "R20N",
                        trip: String? = nil) -> Arrival {
        Arrival(route: route, time: now.addingTimeInterval(minutes * 60), stop: stop, lastStop: "R01N", isLive: true,
                trip: trip ?? "trip \(minutes)")
    }

    /// New York's calendar, for commuting hours.
    static var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Fixtures.newYork
        return calendar
    }
}

// MARK: - Correctness

/// Widgets' saved data, the App Group store, request sharing and offline fallbacks.
struct WidgetsNetworkTests {
    // MARK: Saved widgets across versions

    /// A selection saved before several lines (single `route`) still loads, with defaults.
    @Test func legacySingleLineSelectionDecodes() throws {
        let json = WNSupport.json(#"{"stationID":"R20","route":"R","direction":"N"}"#)
        let selection = try JSONDecoder().decode(Selection.self, from: json)
        #expect(selection.routes == ["R"])
        #expect(selection.direction == .north)
        #expect(selection.serviceAlerts && !selection.elevatorAlerts)
        #expect(selection.walkMinutes == 0)
    }

    /// A widget saved before names, kinds, buses and docks loads with defaults, its walk dropped.
    @Test func oldSavedWidgetDecodesWithDefaults() throws {
        let id = UUID()
        let json = WNSupport.json("""
        {"widgets":[{"id":"\(id.uuidString)","selection":{"stationID":"R20","routes":["N","R"],"direction":"S","walkMinutes":7}}]}
        """)
        let saved = try JSONDecoder().decode(SavedWidgets.self, from: json)
        let widget = try #require(saved.widget(id))
        #expect(widget.name == "")
        #expect(widget.kind == .subway)
        #expect(!widget.bothWays)
        #expect(widget.bus == nil && widget.dock == nil && widget.change == nil && widget.commute == nil)
        #expect(widget.selection.walkMinutes == 0)
        #expect(widget.selection.routes == ["N", "R"])
    }

    /// Saved widgets round-trip through JSON unchanged.
    @Test func savedWidgetsRoundTrip() throws {
        let bus = BusChoice(line: "B63", stop: BusStop(id: "301", name: "5 AV/3 ST", latitude: 40.67, longitude: -73.98),
                            destination: "COBBLE HILL", bothWays: true)
        let commute = CommutingHours(selection: Selection(stationID: "R20", routes: ["R"], direction: .south), start: 17 * 60,
                                     end: 19 * 60, weekdays: [2, 3])
        let saved = SavedWidgets(widgets: [
            SavedWidget(name: "Work", selection: .fallback, commute: commute, destinationID: "R14", bothWays: true),
            .bus(bus, name: "Bus home"),
        ])
        let decoded = try JSONDecoder().decode(SavedWidgets.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
    }

    /// Citi Bike docks saved as widgets are kept apart as moved docks, and saved again, last.
    @Test func dockWidgetsAreMovedAndKept() throws {
        let dock = SavedWidget.dock(DockChoice(id: "d1", name: "5 Av & 3 St", latitude: 40.67, longitude: -73.98))
        let train = SavedWidget(selection: .fallback)
        let json = try JSONEncoder().encode(["widgets": [dock, train]])
        let saved = try JSONDecoder().decode(SavedWidgets.self, from: json)
        #expect(saved.widgets.map(\.id) == [train.id])
        #expect(saved.movedDock(dock.id)?.dock?.id == "d1")
        #expect(saved.widget(dock.id) == nil)
        let again = try JSONDecoder().decode([String: [SavedWidget]].self, from: JSONEncoder().encode(saved))
        #expect(again["widgets"]?.map(\.id) == [train.id, dock.id])
    }

    /// A Q06 saved before the lines were renamed reads as the Q6.
    @Test func paddedBusLinesAreUnpadded() throws {
        let json = WNSupport.json(#"{"line":"Q06","lines":["Q06","Q100"],"stop":{"id":"1","name":"A","latitude":40.7,"longitude":-73.8}}"#)
        let bus = try JSONDecoder().decode(BusChoice.self, from: json)
        #expect(bus.line == "Q6")
        #expect(bus.lines == ["Q6", "Q100"])
        #expect(!bus.bothWays)
    }

    /// Commuting hours missing their times and days default to weekdays 4–6 pm.
    @Test func commutingHoursDefaults() throws {
        let json = WNSupport.json(#"{"selection":{"stationID":"R20","routes":["R"],"direction":"N"},"change":42}"#)
        let hours = try JSONDecoder().decode(CommutingHours.self, from: json)
        #expect(hours.start == 16 * 60 && hours.end == 18 * 60)
        #expect(hours.weekdays == [2, 3, 4, 5, 6])
        #expect(hours.change == nil)
    }

    /// Hours past midnight count toward the day they started, and switch on time.
    @Test func commutingHoursPastMidnight() throws {
        let calendar = WNSupport.newYork
        // Fridays 10 pm to 2 am
        let hours = CommutingHours(selection: .fallback, start: 22 * 60, end: 2 * 60, weekdays: [6])
        #expect(hours.isActive(at: Fixtures.date("2026-11-13 23:00"), calendar: calendar))
        #expect(hours.isActive(at: Fixtures.date("2026-11-14 01:30"), calendar: calendar))
        #expect(!hours.isActive(at: Fixtures.date("2026-11-14 23:00"), calendar: calendar))
        #expect(!hours.isActive(at: Fixtures.date("2026-11-13 21:59"), calendar: calendar))
        #expect(hours.nextSwitch(after: Fixtures.date("2026-11-13 21:00"), calendar: calendar) == Fixtures.date("2026-11-13 22:00"))
        #expect(hours.nextSwitch(after: Fixtures.date("2026-11-13 23:00"), calendar: calendar) == Fixtures.date("2026-11-14 02:00"))
        let never = CommutingHours(selection: .fallback, start: 600, end: 600)
        #expect(!never.isActive(at: Fixtures.date("2026-11-10 10:00"), calendar: calendar))
        #expect(never.nextSwitch(after: Fixtures.date("2026-11-10 10:00"), calendar: calendar) == nil)
    }

    /// During commuting hours a widget shows their train with its own alert choices.
    @Test func shownDuringCommuteKeepsAlertChoices() {
        var selection = Selection.fallback
        selection.elevatorAlerts = true
        selection.serviceAlerts = false
        let evening = Selection(stationID: "R14", routes: ["N"], direction: .south)
        let widget = SavedWidget(selection: selection,
                                 commute: CommutingHours(selection: evening, start: 0, end: 23 * 60 + 59,
                                                         weekdays: Set(1...7)))
        let shown = widget.shown(at: .now)
        #expect(shown.selection.stationID == "R14")
        #expect(shown.selection.elevatorAlerts && !shown.selection.serviceAlerts)
    }

    /// Validation drops lines a station lost and sends unknown stations to the fallback.
    @Test func validationDropsLostLinesAndStations() {
        let lost = SavedWidgets(widgets: [
            SavedWidget(selection: Selection(stationID: "R20", routes: ["N", "X9"], direction: .north)),
            SavedWidget(selection: Selection(stationID: "NOPE", routes: ["R"], direction: .north)),
        ]).validated()
        #expect(lost.widgets[0].selection.routes == ["N"])
        #expect(lost.widgets[1].selection == .fallback)
    }

    /// Reordering moves widgets as a List's onMove does.
    @Test func moveReorders() {
        let widgets = (0..<4).map { _ in SavedWidget(selection: .fallback) }
        var saved = SavedWidgets(widgets: widgets)
        saved.move(fromOffsets: [0], toOffset: 3)
        #expect(saved.widgets.map(\.id) == [widgets[1], widgets[2], widgets[0], widgets[3]].map(\.id))
        saved.delete(widgets[2].id)
        #expect(saved.widgets.count == 3 && saved.widget(widgets[2].id) == nil)
    }

    /// Changing a widget's line drops its destination; another station the same way keeps it.
    @Test func setSelectionKeepsDestinationOnlyOnSameLines() {
        var widget = SavedWidget(selection: Selection(stationID: "R20", routes: ["R"], direction: .north), destinationID: "R14")
        widget.setSelection(Selection(stationID: "R17", routes: ["R"], direction: .north))
        #expect(widget.destinationID == "R14")
        widget.setSelection(Selection(stationID: "R17", routes: ["R"], direction: .south))
        #expect(widget.destinationID == nil)
    }

    /// Names, summaries and ways read as the Widgets tab shows them.
    @Test func titlesAndWays() {
        let widget = SavedWidget(name: "  ", selection: .fallback, bothWays: true)
        #expect(!widget.isNamed)
        #expect(widget.title.hasSuffix("from 14 St-Union Sq"))
        #expect(widget.way == "both ways")
        let dock = SavedWidget.dock(DockChoice(id: "d", name: "Union Sq", latitude: 0, longitude: 0))
        #expect(dock.summary == "Citi Bike at Union Sq" && dock.way == "")
    }

    // MARK: Settings, trips and taps across versions

    /// Settings from a newer version (unknown kinds, styles, bikes) load with what's known.
    @Test func newerSettingsLoad() throws {
        let json = WNSupport.json("""
        {"alertKinds":[0,1,9],"favoriteCard":"hologram","bikeKinds":"scooters","stepFree":true,
         "defaultTrain":{"bad":1},"defaultBus":{"x":1},"futureField":[1,2]}
        """)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(settings.alertKinds == [.delays, .suspended])
        #expect(settings.favoriteCard == .bulletRow)
        #expect(settings.bikeKinds == .both)
        #expect(settings.stepFree)
        #expect(settings.defaultTrain == nil && settings.defaultBus == nil)
    }

    /// Empty settings decode to the defaults; settings round-trip.
    @Test func settingsDefaultsAndRoundTrip() throws {
        #expect(try JSONDecoder().decode(AppSettings.self, from: WNSupport.json("{}")) == AppSettings())
        var settings = AppSettings()
        settings.alertKinds = [.notice]
        settings.defaultTrain = .fallback
        settings.includesBuses = true
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    /// A shared trip from an unknown maps app loads as a Quick Trip; it shows for an hour only.
    @Test func sharedTripVersionsAndWindow() throws {
        let shared = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let json = WNSupport.json("""
        {"option":{"selection":{"stationID":"R20","routes":["R"],"direction":"N"}},"app":"waze","shared":\(shared.timeIntervalSinceReferenceDate)}
        """)
        let trip = try JSONDecoder().decode(SharedTrip.self, from: json)
        #expect(trip.app == nil && trip.nearby == nil)
        #expect(trip.isActive(at: shared.addingTimeInterval(59 * 60)))
        #expect(!trip.isActive(at: shared.addingTimeInterval(60 * 60)))
        // Clock set back
        #expect(!trip.isActive(at: shared.addingTimeInterval(-1)))
        if case .quickTrip = trip.source {} else { Issue.record("expected a Quick Trip, got \(trip.source)") }
        var gone = trip
        gone.option.selection.stationID = "NOPE"
        #expect(gone.validated() == nil)
    }

    /// Taps and countdowns saved before newer fields still load.
    @Test func tapsAndCountdownDecodeOld() throws {
        let taps = try JSONDecoder().decode(SharedStore.Taps.self, from: WNSupport.json("{}"))
        #expect(taps.latest == nil)
        let countdown = try JSONDecoder().decode(SharedStore.Countdown.self,
                                                 from: WNSupport.json(#"{"trainID":"R20:N:R","ends":0}"#))
        #expect(countdown.widgetID == nil)
        #expect(countdown.isShown(onWidget: "any", for: "R20:N:R"))
        #expect(!countdown.isShown(onWidget: "any", for: "R20:S:R"))
    }

    /// A saved board round-trips, its trains and times intact.
    @Test func savedBoardRoundTrips() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let board = SharedStore.SavedBoard(fetched: now, trains: [WNSupport.arrival(3, from: now)],
                                           notice: Notice(kind: .elevator, label: "Elevator out", text: "x", others: 0),
                                           destinationTimes: ["trip 3.0": now.addingTimeInterval(900)])
        let decoded = try JSONDecoder().decode(SharedStore.SavedBoard.self, from: JSONEncoder().encode(board))
        #expect(decoded.trains == board.trains)
        #expect(decoded.notice == board.notice)
        #expect(decoded.destinationTimes == board.destinationTimes)
        #expect(decoded.failed == nil)
    }

    // MARK: App Group store

    /// `write` then `read` round-trips; writing nil removes the file.
    @Test func storeReadWriteRoundTrip() throws {
        let file = WNSupport.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        SharedStore.write(["a": 1, "b": 2], to: file)
        #expect(SharedStore.read([String: Int].self, from: file) == ["a": 1, "b": 2])
        SharedStore.write(nil as [String: Int]?, to: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(SharedStore.read([String: Int].self, from: file) == nil)
    }

    /// `change` starts from empty with no file, and edits what's saved.
    @Test func storeChangeReadModifyWrite() {
        let file = WNSupport.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        SharedStore.change(file, empty: [String: Int]()) { $0["count"] = 1 }
        SharedStore.change(file, empty: [String: Int]()) { $0["count", default: 0] += 1 }
        #expect(SharedStore.read([String: Int].self, from: file) == ["count": 2])
    }

    /// Changes from many threads at once are each kept: none reads before another's written.
    @Test func storeChangeIsAtomicUnderConcurrency() {
        let file = WNSupport.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            SharedStore.change(file, empty: [String: Int]()) { $0["count", default: 0] += 1 }
        }
        #expect(SharedStore.read([String: Int].self, from: file) == ["count": 24])
    }

    /// The feed cache keeps data by name and age in the App Group.
    @Test func feedCacheRoundTrip() throws {
        try #require(SharedStore.isAvailable)
        let name = "wntest \(UUID().uuidString)"
        let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = try #require(SharedStore.url(named: "Library/Caches/Feeds/\(hash)"))
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = SharedStore.FeedCache()
        #expect(cache.data(for: name, within: 60) == nil)
        cache.save(Data("alerts".utf8), for: name)
        #expect(cache.data(for: name, within: 60) == Data("alerts".utf8))
        #expect(cache.data(for: name, within: 0) == nil)
        #expect(cache.keeps == 7 * 24 * 60 * 60)
    }

    /// A tapped board opens for 5 minutes, at least 1, and no longer than its train; ✕ closes it.
    @Test func openBoardsWindow() throws {
        try #require(SharedStore.isAvailable)
        let id = "wntest \(UUID().uuidString)"
        defer { OpenBoards.close(id) }
        let now = Date.now
        OpenBoards.open(id, leaves: nil)
        let closes = try #require(OpenBoards.closes(id))
        #expect(abs(closes.timeIntervalSince(now) - OpenBoards.duration) < 5)
        OpenBoards.open(id, leaves: now.addingTimeInterval(10))
        let soon = try #require(OpenBoards.closes(id))
        #expect(abs(soon.timeIntervalSince(now) - OpenBoards.shortest) < 5)
        OpenBoards.open(id, leaves: now.addingTimeInterval(120))
        #expect(abs((OpenBoards.closes(id)?.timeIntervalSince(now) ?? 0) - 120) < 5)
        #expect(OpenBoards.closes(id, now: now.addingTimeInterval(121)) == nil)
        OpenBoards.close(id)
        #expect(OpenBoards.closes(id) == nil)
    }

    // MARK: Edit menu and intents

    /// A picked widget is found; a deleted pick or none falls back to Settings' home stop.
    @Test func intentPicksSavedOrFallsBack() {
        let picked = SavedWidget(name: "Mine", selection: Selection(stationID: "R14", routes: ["N"], direction: .south))
        let saved = SavedWidgets(widgets: [picked])
        let intent = TrainWidgetIntent()
        #expect(intent.savedWidget(in: saved, defaultTrain: .fallback, defaultBothWays: true, defaultBus: nil)?.id
            == SavedWidget.defaultID)
        intent.widget = SavedWidgetEntity(picked)
        #expect(intent.savedWidget(in: saved, defaultTrain: .fallback, defaultBothWays: false, defaultBus: nil)?.id == picked.id)
        intent.widget = SavedWidgetEntity(deleted: UUID())
        let fallback = intent.savedWidget(in: saved, defaultTrain: .fallback, defaultBothWays: true, defaultBus: nil)
        #expect(fallback?.id == SavedWidget.defaultID && fallback?.bothWays == true)
        let bus = BusChoice(line: "B63", stop: BusStop(id: "1", name: "X", latitude: 0, longitude: 0))
        #expect(intent.savedWidget(in: saved, defaultTrain: .fallback, defaultBothWays: false, defaultBus: bus)?.kind == .bus)
    }

    /// A bus widget's train id is its own, not the fallback train's, so it never syncs with one.
    @Test func busWidgetTrainIDIsItsOwn() {
        let bus = SavedWidget.bus(BusChoice(line: "B63", stop: BusStop(id: "1", name: "X", latitude: 0, longitude: 0)))
        let intent = TrainWidgetIntent()
        intent.widget = SavedWidgetEntity(bus)
        let id = intent.trainID(kind: WidgetKind.train, at: .now, in: SavedWidgets(widgets: [bus]))
        #expect(id == "bus \(bus.id)")
        #expect(id != Selection.fallback.trainID)
    }

    /// Widget IDs tell kinds, sizes and picks apart.
    @Test func widgetIDsDiffer() {
        let intent = TrainWidgetIntent()
        let small = intent.widgetID(kind: WidgetKind.train, family: .systemSmall)
        let medium = intent.widgetID(kind: WidgetKind.train, family: .systemMedium)
        #expect(small != medium)
        #expect(intent.widgetID(kind: WidgetKind.transfers, family: .systemSmall) != small)
        intent.widget = SavedWidgetEntity(SavedWidget(selection: .fallback))
        #expect(intent.widgetID(kind: WidgetKind.train, family: .systemSmall) != small)
    }

    /// Edit menu entities say a deleted pick is deleted, and a moved dock that it moved.
    @Test func savedWidgetEntities() {
        let deleted = SavedWidgetEntity(deleted: UUID())
        #expect(deleted.title == "Deleted widget" && deleted.routes.isEmpty)
        let dock = SavedWidget.dock(DockChoice(id: "d", name: "Union Sq", latitude: 0, longitude: 0))
        #expect(SavedWidgetEntity(moved: dock).subtitle == "Moved to the Citi Bike widget")
        let train = SavedWidgetEntity(SavedWidget(selection: .fallback))
        #expect(train.routes == ["N", "Q", "R", "W"])
        #expect(train.subtitle.hasPrefix("14 St-Union Sq · "))
    }

    /// Stop entity ids parse back to the same train, and bad ones are refused. A platform's id
    /// (R20, from older saves) still parses, its selection moved to the station's.
    @Test func stopEntityIDs() throws {
        let union = try #require(StationDirectory.station(id: "R20"))
        let stop = try #require(StopEntity(id: "R20:N:N,Q,R,W"))
        #expect(stop.routes == ["N", "Q", "R", "W"] && stop.direction == .north)
        #expect(stop.selection(basedOn: .fallback).trainID == Selection.fallback.trainID)
        #expect(StopEntity(id: Selection.fallback.trainID)?.id == Selection.fallback.trainID)
        #expect(StopEntity(id: "R20:X:N") == nil)
        #expect(StopEntity(id: "NOPE:N:R") == nil)
        #expect(StopEntity(id: "R20:N") == nil)
        #expect(StopEntity(id: "R20:N:1") == nil)
        let choices = StopEntity.choices(at: union)
        #expect(Set(choices.map { $0.id }).count == choices.count)
        #expect(choices.contains { $0.id == "\(union.id):S:N,Q,R,W" })
    }

    /// The fallback train is as validation leaves it, so saved copies of it share its train id.
    @Test func fallbackIsValidated() {
        #expect(Selection.fallback.validated() == .fallback)
        #expect(Selection.fallback.stationID == StationDirectory.station(id: "R20")?.id)
        #expect(Selection.fallback.routes == ["N", "Q", "R", "W"])
        let first = SavedWidgets(widgets: [SavedWidget(id: SavedWidget.firstID, selection: .fallback, bothWays: true)])
        #expect(first.validated().widgets[0].selection.trainID == Selection.fallback.trainID)
        #expect(Selection(stationID: "NOPE", routes: ["R"], direction: .north).validated() == .fallback)
    }

    /// Station search for shortcuts finds the station, and never lists more than 60.
    @Test func stopQuerySearch() async throws {
        let union = try #require(StationDirectory.station(id: "R20"))
        let found = try await StopQuery().entities(matching: "union sq")
        #expect(found.contains { $0.stationID == union.id })
        #expect(try await StopQuery().entities(matching: "st").count <= 60)
    }

    /// Legacy line and direction choices parse as they were saved.
    @Test func legacyLineAndDirectionEntities() {
        #expect(LineEntity(id: "all:2,3,4")?.routes == ["2", "3", "4"])
        #expect(LineEntity(id: "D,N,R")?.routes == ["D", "N", "R"])
        #expect(LineEntity(id: "") == nil && LineEntity(id: "all:") == nil)
        #expect(DirectionEntity(id: "N:R31:N,R")?.direction == .north)
        #expect(DirectionEntity(id: "S")?.direction == .south)
        #expect(DirectionEntity(id: "X") == nil)
    }

    /// Edit menu bullets draw as a PNG, cached.
    @Test func bulletImages() throws {
        let png = try #require(BulletImage.data(for: ["N", "Q", "R", "W"]))
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(BulletImage.data(for: ["N", "Q", "R", "W"]) == png)
        #expect(BulletImage.data(for: ["6X"]) != nil)
    }

    // MARK: Trains from the real feeds

    /// Union Sq's uptown N Q R W from the saved feeds: theirs only, soonest first, each once.
    @Test func widgetTrainsFromRealFeeds() throws {
        let selection = Selection.fallback
        let now = FeedFixtures.capturedAt
        let arrivals = TrainService.arrivals(at: Set(selection.stopIDs), in: WNSupport.fixtureFeeds, now: now)
        let trains = try #require(TrainService.trains(for: [selection, selection], in: arrivals, now: now)[selection.trainID])
        #expect(!trains.isEmpty)
        #expect(trains.map(\.time) == trains.map(\.time).sorted())
        #expect(trains.allSatisfy { selection.stopIDs.contains($0.stop) && $0.leaves > now && !$0.endsHere })
        #expect(trains.allSatisfy { $0.stop.hasSuffix("N") })
        let trips = trains.map(\.trip).filter { !$0.isEmpty }
        #expect(Set(trips).count == trips.count)
        // The other way's are all southbound
        let other = selection.otherWay
        let south = TrainService.trains(for: [other], in: TrainService.arrivals(at: Set(other.stopIDs),
                                                                               in: WNSupport.fixtureFeeds, now: now),
                                        now: now)[other.trainID] ?? []
        #expect(!south.isEmpty && south.allSatisfy { $0.stop.hasSuffix("S") })
    }

    /// Without its own line's feed, a train is left out rather than shown with none.
    @Test func trainWithoutOwnFeedIsOmitted() {
        let now = FeedFixtures.capturedAt
        var feeds = WNSupport.fixtureFeeds
        feeds = feeds.filter { !$0.key.absoluteString.hasSuffix("gtfs-nqrw") }
        let arrivals = TrainService.arrivals(at: Set(Selection.fallback.stopIDs), in: feeds, now: now)
        #expect(TrainService.trains(for: [Selection.fallback], in: arrivals, now: now)[Selection.fallback.trainID] == nil)
    }

    /// The widget's timeline from real trains: sorted, unique, after now, and a bounded count.
    @Test func timelineEntriesStayBounded() throws {
        let selection = Selection.fallback
        let now = FeedFixtures.capturedAt
        let arrivals = TrainService.arrivals(at: Set(selection.stopIDs), in: WNSupport.fixtureFeeds, now: now)
        let trains = try #require(TrainService.trains(for: [selection], in: arrivals, now: now)[selection.trainID])
        for everyMinute in [false, true] {
            let dates = TimelinePlan.dates(after: now, toCatch: trains, selection: selection, everyMinute: everyMinute)
            #expect(!dates.isEmpty)
            #expect(dates == dates.sorted() && Set(dates).count == dates.count)
            #expect(dates.allSatisfy { $0 > now })
            #expect(dates.count <= (everyMinute ? 60 + 3 * TimelinePlan.trainsAhead : 3 * TimelinePlan.trainsAhead))
            let last = trains.prefix(TimelinePlan.trainsAhead).map(\.leaves).max() ?? now
            #expect(dates.last! <= last.addingTimeInterval(AtStation.seconds))
        }
    }

    /// Reloads are never within a minute nor past the interval, and overnight wait longer.
    @Test func reloadTimesStayInBounds() {
        let day = Fixtures.date("2026-11-10 10:30")
        let night = Fixtures.date("2026-11-10 02:30")
        #expect(TimelinePlan.reloadInterval(at: day) == 5 * 60)
        #expect(TimelinePlan.reloadInterval(at: night) == 15 * 60)
        #expect(TimelinePlan.reload(now: day, fetched: day, runsOut: nil, switches: nil) == day.addingTimeInterval(300))
        // Fetched "in the future" (clock set back), run out, or incomplete: still a minute on
        #expect(TimelinePlan.reload(now: day, fetched: day.addingTimeInterval(3600), runsOut: nil, switches: nil)
            == day.addingTimeInterval(60))
        #expect(TimelinePlan.reload(now: day, fetched: day, runsOut: day, switches: nil) == day.addingTimeInterval(60))
        #expect(TimelinePlan.reload(now: day, fetched: day, runsOut: nil, switches: nil, complete: false)
            == day.addingTimeInterval(60))
        // Failing with times an hour old: no longer than the interval
        #expect(TimelinePlan.reload(now: day, fetched: nil, old: day.addingTimeInterval(-3600), failed: day, runsOut: nil,
                                    switches: nil) == day.addingTimeInterval(300))
    }

    /// Saved times are reused within 30 s, never from before a ↻.
    @Test func reuseOfSavedTimes() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(TimelinePlan.reuses(saved: now.addingTimeInterval(-10), refreshed: nil, toggled: nil, anyToCatch: { true },
                                    now: now))
        #expect(!TimelinePlan.reuses(saved: now.addingTimeInterval(-10), refreshed: now.addingTimeInterval(-5), toggled: nil,
                                     anyToCatch: { true }, now: now))
        #expect(!TimelinePlan.reuses(saved: now.addingTimeInterval(-60), refreshed: nil, toggled: nil, anyToCatch: { true },
                                     now: now))
        #expect(!TimelinePlan.reuses(saved: now.addingTimeInterval(10), refreshed: nil, toggled: nil, anyToCatch: { true },
                                     now: now))
    }

    // MARK: Request sharing (the 11/8 audit)

    /// Identical feed requests at once share one fetch.
    @Test func concurrentFeedRequestsShareOneFetch() async {
        let url = WNSupport.uniqueFeed()
        let bytes = WNSupport.feedBytes
        let (results, made) = await withNetwork({ _ in .ok(bytes, delay: .milliseconds(200)) }) {
            await withTaskGroup(of: Data?.self) { group in
                for _ in 0..<8 {
                    group.addTask { await TrainService.optionalData(from: url, part: .init(stops: ["R20N"])) }
                }
                var all: [Data?] = []
                for await data in group { all.append(data) }
                return all
            }
        }
        #expect(results.count == 8 && results.allSatisfy { $0 == bytes })
        #expect(made.count == 1)
        #expect(made.allSatisfy { WNSupport.isRelay($0.url) })
    }

    /// A feed fetched moments ago is reused, also for fewer stops; other stops are fetched.
    @Test func recentFeedIsReusedWithinWindow() async {
        let url = WNSupport.uniqueFeed()
        let bytes = WNSupport.feedBytes
        let (_, made) = await withNetwork({ _ in .ok(bytes) }) {
            _ = await TrainService.optionalData(from: url, part: .init(stops: ["R20N", "R14N"]))
            _ = await TrainService.optionalData(from: url, part: .init(stops: ["R20N", "R14N"]))
            _ = await TrainService.optionalData(from: url, part: .init(stops: ["R14N"]))
            _ = await TrainService.optionalData(from: url, part: .init(stops: ["Q01N"]))
        }
        #expect(made.count == 2)
        let stops = made.map { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "stops" }?.value }
        #expect(stops == ["R14N,R20N", "Q01N"])
    }

    /// Boards fetched together ask for each feed once, for all their stops.
    @Test func batchFetchesEachFeedOnce() async {
        let url = WNSupport.uniqueFeed()
        let bytes = WNSupport.feedBytes
        let (_, made) = await withNetwork({ _ in .ok(bytes) }) {
            await TrainService.sharingFeeds(atStops: ["R20N", "R14N", "Q01N"]) {
                _ = await TrainService.optionalData(from: url, part: .init(stops: ["R20N"]))
                _ = await TrainService.optionalData(from: url, part: .init(stops: ["Q01N"]))
            }
        }
        #expect(made.count == 1)
        #expect(made.first?.url.query?.contains("stops=Q01N,R14N,R20N") == true)
    }

    /// Routes on stations no other test asks for, so no other test's fetch of their feeds is
    /// reused: Kings Hwy and Avenue U Q's, Whitehall St R's, all in the N Q R W feed, and one
    /// planned in New Route, whose trains are looked up at its own stops (`PlannedTrips.fetch`).
    @MainActor static let routes: [SavedWidget] = {
        let kingsHighway = Selection(stationID: "D35", routes: ["Q"], direction: .north)
        var change = Change(stationID: "N04", routes: ["N"], direction: .north)
        change.planned = PlannedTrip(ways: [PlannedWay(rides: [[PlannedRide(train: kingsHighway)]], endStationID: "N10")],
                                     destinationID: "N10")
        return [
            SavedWidget(selection: kingsHighway),
            SavedWidget(selection: Selection(stationID: "D37", routes: ["Q"], direction: .north)),
            SavedWidget(selection: Selection(stationID: "R27", routes: ["R"], direction: .north)),
            SavedWidget(selection: kingsHighway, change: change),
        ]
    }()

    /// Routes' first loads as the tab opens share one batch: each train feed asked for once, for
    /// every route's stops, and the same trains as each fetched on its own.
    @MainActor @Test func routesFirstLoadsFetchEachFeedOnce() async throws {
        let widgets = Self.routes
        let settings = AppSettings()
        let now = CountdownKit.cap
        let firstLoads = FirstLoads()
        firstLoads.start(widgets, look: { _ in .medium }, settings: settings)
        let trips = widgets.map { WidgetPreview.Trip($0, look: .medium, settings: settings, at: .now) }
        let (shared, made) = try await withNetwork(FeedFixtures.respond) {
            try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
                for (index, widget) in widgets.enumerated() {
                    let batch = firstLoads.take(for: widget.id)
                    let trip = trips[index]
                    group.addTask {
                        let (board, _) = try await WidgetPreview.boards(for: widget.selection, trip: trip, sharing: batch,
                                                                        now: now)
                        return (index, board.trains.map(\.trip))
                    }
                }
                var trains: [Int: [String]] = [:]
                for try await (index, trips) in group { trains[index] = trips }
                return trains
            }
        }
        let names = Self.trainFeeds(made)
        #expect(names.contains("nyct/gtfs-nqrw"))
        #expect(names.count == Set(names).count, "Feeds asked for more than once: \(names.sorted())")
        // Taken once each: an edit or refresh after fetches its own
        #expect(widgets.allSatisfy { firstLoads.take(for: $0.id) == nil })
        // The same trains as each route fetched alone (the saved feeds are whole, whatever's asked)
        let (alone, _) = try await withNetwork(FeedFixtures.respond) {
            var trains: [Int: [String]] = [:]
            for (index, widget) in widgets.enumerated() {
                trains[index] = try await WidgetPreview.boards(for: widget.selection, trip: trips[index], now: now)
                    .0.trains.map { $0.trip }
            }
            return trains
        }
        #expect(shared == alone)
    }

    /// The first loads' batch is only for moments: a route loading later fetches its own.
    @MainActor @Test func routesFirstLoadsBatchIsLetGo() {
        let widgets = Self.routes
        let firstLoads = FirstLoads()
        let start = Date.now
        firstLoads.start(widgets, look: { _ in .small }, settings: AppSettings(), at: start)
        #expect(firstLoads.take(for: widgets[0].id, now: start.addingTimeInterval(1)) != nil)
        #expect(firstLoads.take(for: widgets[1].id, now: start.addingTimeInterval(FirstLoads.life + 1)) == nil)
        // Let go once old, for the rest too
        #expect(firstLoads.take(for: widgets[2].id, now: start.addingTimeInterval(2)) == nil)
        // A route not there as the tab opened
        firstLoads.start(widgets, look: { _ in .small }, settings: AppSettings(), at: start)
        #expect(firstLoads.take(for: UUID(), now: start) == nil)
    }

    /// The train feeds asked of the push server, by name, once a request. Not alerts, asked for
    /// by each board's lines.
    static func trainFeeds(_ made: [TestNetwork.Made]) -> [String] {
        made.compactMap { made -> String? in
            guard WNSupport.isRelay(made.url) else { return nil }
            let name = URLComponents(url: made.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "name" }?.value
            return name.flatMap { $0.hasPrefix("nyct/gtfs") ? $0 : nil }
        }
    }

    /// A trip planned in New Route on the Q from `start` to `end`, its change at `change` (an N
    /// station). Each test's on stations no other test asks for, so no other's fetch is reused.
    static func plannedOption(from start: String, to end: String, changingAt change: String) -> SharedTrip.Option {
        let from = Selection(stationID: start, routes: ["Q"], direction: .north)
        var changing = Change(stationID: change, routes: ["N"], direction: .north)
        changing.planned = PlannedTrip(ways: [PlannedWay(rides: [[PlannedRide(train: from)]], endStationID: end)],
                                       destinationID: end)
        return SharedTrip.Option(selection: from, change: changing)
    }

    /// A board for `option`, as the widget's own fetch (`Provider.board`).
    static func board(for option: SharedTrip.Option, now: Date) async throws -> Board {
        if let change = option.change {
            return try await TrainService.routeBoard(for: option.selection, change: change, includingAlerts: false,
                                                     includingOutages: false, now: now)
        }
        return try await TrainService.board(for: option.selection, arrivingAt: option.directDestination,
                                            includingAlerts: false, includingOutages: false, now: now)
    }

    /// Quick Trip's prefetch of several trips, one planned in New Route: in one batch for all
    /// their stops (`SharedTrip.Option.feedStops`), each train feed asked for once.
    @Test func quickTripPrefetchWithPlannedTripFetchesEachFeedOnce() async throws {
        let options = [
            // Sheepshead Bay to Brighton Beach
            Self.plannedOption(from: "D39", to: "D40", changingAt: "N08"),
            SharedTrip.Option(selection: Selection(stationID: "D38", routes: ["Q"], direction: .north)),
            SharedTrip.Option(selection: Selection(stationID: "R29", routes: ["R"], direction: .north)),
        ]
        let now = CountdownKit.cap
        let stops = options.reduce(into: Set<String>()) { $0.formUnion($1.feedStops) }
        let (_, made) = try await withNetwork(FeedFixtures.respond) {
            try await TrainService.sharingFeeds(atStops: stops) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for option in options {
                        group.addTask { _ = try await Self.board(for: option, now: now) }
                    }
                    try await group.waitForAll()
                }
            }
        }
        let names = Self.trainFeeds(made)
        #expect(names.contains("nyct/gtfs-nqrw"))
        #expect(names.count == Set(names).count, "Feeds asked for more than once: \(names.sorted())")
    }

    /// A widget on a planned route with a second board, as one showing both ways: the two in
    /// one batch (as `Provider.timeline`), each train feed asked for once.
    @Test func plannedRouteBothWaysFetchesEachFeedOnce() async throws {
        // Avenue M to Ocean Pkwy, and 20 Av N's other way
        let option = Self.plannedOption(from: "D34", to: "D41", changingAt: "N07")
        let other = Selection(stationID: "N06", routes: ["N"], direction: .south)
        let now = CountdownKit.cap
        let stops = TrainService.routeFeedStops(for: option.selection, change: option.change, destination: nil)
            .union(TrainService.feedStops(for: other, change: nil, destination: nil))
        let (_, made) = try await withNetwork(FeedFixtures.respond) {
            try await TrainService.sharingFeeds(atStops: stops) {
                async let otherWay = Self.board(for: SharedTrip.Option(selection: other), now: now)
                _ = try await Self.board(for: option, now: now)
                _ = try await otherWay
            }
        }
        let names = Self.trainFeeds(made)
        #expect(names.contains("nyct/gtfs-nqrw"))
        #expect(names.count == Set(names).count, "Feeds asked for more than once: \(names.sorted())")
    }

    /// The push server's copy comes first; the MTA isn't asked when it answers.
    @Test func relayAnsweringSkipsMTA() async throws {
        let url = WNSupport.uniqueFeed()
        let bytes = WNSupport.feedBytes
        let (data, made) = await withNetwork({ _ in .ok(bytes) }) {
            await TrainService.optionalData(from: url)
        }
        #expect(data == bytes)
        let only = try #require(made.first)
        #expect(made.count == 1 && only.method == "GET")
        let name = URLComponents(url: only.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
        #expect(name == TrainService.feedName(of: url))
    }

    /// Without the push server, the MTA is asked straight away, once.
    @Test func relayFailingFallsBackToMTAOnce() async {
        let url = WNSupport.uniqueFeed()
        let bytes = WNSupport.feedBytes
        let (data, made) = await withNetwork({ request in
            WNSupport.isRelay(request.url!) ? nil : .ok(bytes)
        }) {
            await TrainService.optionalData(from: url)
        }
        #expect(data == bytes)
        #expect(made.map { WNSupport.isRelay($0.url) } == [true, false])
        #expect(made.last?.url == url)
    }

    /// A slow push server has the MTA asked alongside after 1.5 s, and the first answer wins.
    @Test func slowRelayIsHedged() async {
        let url = WNSupport.uniqueFeed()
        let bytes = WNSupport.feedBytes
        let started = Date.now
        let (data, made) = await withNetwork({ request in
            WNSupport.isRelay(request.url!) ? .ok(bytes, delay: .seconds(6)) : .ok(bytes)
        }) {
            await TrainService.optionalData(from: url)
        }
        #expect(data == bytes)
        #expect(made.count == 2)
        let took = Date.now.timeIntervalSince(started)
        #expect(took >= 1.4 && took < 5)
    }

    /// The subway timetable downloads when missing, is kept, and isn't asked for again until due.
    @Test func timetableDownloadsOnlyWhenDue() async throws {
        let (file, name) = WNSupport.timetableFile()
        defer { WNSupport.removeTimetable(name) }
        let bytes = try WNSupport.timetableBytes()
        #expect(file.isDue())
        let (_, made) = await withNetwork({ _ in TestNetwork.Answer(headers: ["ETag": "\"v1\""], body: bytes) }) {
            await file.refresh()
            await file.refresh()
            await file.refresh()
        }
        #expect(made.count == 1)
        #expect(made.first?.url.path == "/\(name)")
        #expect(made.first?.url.query == "days=30")
        #expect(!file.isDue())
        #expect(file.load(now: .now) != nil)
        // A day on, it's due again
        #expect(file.isDue(now: .now.addingTimeInterval(21 * 60 * 60)))
    }

    /// An unchanged timetable is asked for with its ETag and kept on a 304.
    @Test func timetableNotModifiedKeepsFile() async throws {
        let (file, name) = WNSupport.timetableFile()
        defer { WNSupport.removeTimetable(name) }
        let bytes = try WNSupport.timetableBytes()
        let (_, made) = await withNetwork({ request in
            request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\""
                ? .status(304) : TestNetwork.Answer(headers: ["ETag": "\"v1\""], body: bytes)
        }) {
            await file.refresh()
            await file.refresh(force: true)
        }
        #expect(made.count == 2)
        #expect(made.last?.headers["If-None-Match"] == "\"v1\"")
        #expect(file.load(now: .now) != nil && !file.isDue())
    }

    /// App and widgets refreshing the timetable together download it once.
    @Test func concurrentTimetableRefreshesShareOne() async throws {
        let (file, name) = WNSupport.timetableFile()
        defer { WNSupport.removeTimetable(name) }
        let bytes = try WNSupport.timetableBytes()
        let (_, made) = await withNetwork({ _ in .ok(bytes, delay: .milliseconds(300)) }) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<5 { group.addTask { await file.refresh() } }
            }
        }
        #expect(made.count == 1)
    }

    /// Citi Bike near you is one GET /docks, asking only for what's needed.
    @Test func docksNearYouIsOneRequest() async throws {
        let body = WNSupport.json(#"{"docks":[{"id":"d1","name":"5 Av & 3 St","lat":40.67,"lon":-73.98,"bikes":3,"eBikes":1,"docks":9,"renting":true,"returning":true}]}"#)
        let location = WNSupport.uniqueLocation()
        let (docks, made) = await withNetwork({ request in request.url?.path == "/docks" ? .ok(body) : nil }) {
            await CitiBike.docks(near: location, limit: 3, within: 500, has: .ebike)
        }
        #expect(docks?.map(\.id) == ["d1"])
        let request = try #require(made.first)
        #expect(made.count == 1 && request.method == "GET" && request.url.path == "/docks")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["limit"] == "3" && query["within"] == "500" && query["has"] == "ebike")
        #expect(query["at"] == String(format: "%.5f,%.5f", location.coordinate.latitude, location.coordinate.longitude))
    }

    /// Bus times for a stop are asked once for two at once, and reused for 30 s.
    @Test func busTimesShareAndReuse() async throws {
        let due = Date.now.addingTimeInterval(600).timeIntervalSinceReferenceDate
        let body = WNSupport.json("""
        {"stop":{"id":"301","name":"5 AV/3 ST","latitude":40.67,"longitude":-73.98},"arrivals":[{"line":"B63","expected":\(due)}]}
        """)
        let location = WNSupport.uniqueLocation()
        let place = BusRide.Place(name: "5 Av & 3 St", latitude: location.coordinate.latitude,
                                  longitude: location.coordinate.longitude)
        let (times, made) = await withNetwork({ request in request.url?.path == "/buses" ? .ok(body, delay: .milliseconds(150)) : nil }) {
            async let first = BusTimes.arrivals(line: "B63", at: place)
            async let second = BusTimes.arrivals(line: "B63", at: place)
            let both = await [first, second]
            let again = await BusTimes.arrivals(line: "B63", at: place)
            return both + [again]
        }
        #expect(times.allSatisfy { $0?.arrivals.first?.line == "B63" })
        #expect(made.count == 1)
    }

    /// A line with "+" is escaped, so the server doesn't read it as a space.
    @Test func busLineIsEscaped() async {
        let location = WNSupport.uniqueLocation()
        let place = BusRide.Place(name: "x", latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        let (_, made) = await withNetwork({ _ in .status(404) }) {
            _ = await BusTimes.arrivals(line: "M15+", at: place)
        }
        let request = made.first { $0.url.path == "/buses" }
        #expect(request?.url.query?.contains("line=M15%2B") == true)
    }

    /// Trips from the server are asked for once, by coordinates and time.
    @Test func routesRequestShape() async throws {
        let start = CLLocation(latitude: 40.735, longitude: -73.990)
        let end = CLLocation(latitude: 40.680, longitude: -73.975)
        // Past any timetable on the phone, so it's the server's
        let at = Date(timeIntervalSince1970: 1_950_000_000)
        let (answer, made) = await withNetwork({ request in request.url?.path == "/routes" ? .ok(WNSupport.json(#"{"routes":[]}"#)) : nil }) {
            await ServerRoutes.fetchRoutes(from: start, to: end, at: at, buses: true)
        }
        #expect(answer.routes == [] && !answer.overLimit)
        let request = try #require(made.first)
        #expect(made.count == 1 && request.headers["Accept"] == "application/json")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query == ["from": "40.735000,-73.990000", "to": "40.680000,-73.975000", "at": "1950000000", "bus": "1"])
    }

    // MARK: Offline

    /// With no signal, a feed fails after the relay and the MTA are each asked once, no more.
    @Test func offlineFeedTriesEachOnce() async {
        let url = WNSupport.uniqueFeed()
        let (data, made) = await withNetwork {
            let data = await TrainService.optionalData(from: url)
            try? await Task.sleep(for: .seconds(2))
            return data
        }
        #expect(data == nil)
        #expect(made.count == 2)
    }

    /// Offline, alerts fall back on those saved within the week, after one try each way.
    @Test func offlineAlertsFallBackOnSaved() async throws {
        let alerts = try Fixtures.data("weekday1030-alerts.json")
        let marker = "WN\(UUID().uuidString.prefix(6))"
        let cache = WNFakeCache(marker: marker, seed: alerts, age: 2 * 60 * 60)
        let (entries, made) = await withNetwork {
            let previous = TrainService.sharedCache
            TrainService.sharedCache = cache
            defer { TrainService.sharedCache = previous }
            return await TrainService.alertEntries(routes: [marker])
        }
        #expect(entries != nil)
        #expect(made.count == 2)
    }

    /// Alerts saved within 3 minutes are used without asking at all; new ones are saved.
    @Test func freshSharedAlertsSkipNetwork() async throws {
        let alerts = try Fixtures.data("weekday1030-alerts.json")
        let marker = "WN\(UUID().uuidString.prefix(6))"
        let fresh = WNFakeCache(marker: marker, seed: alerts, age: 10)
        let (entries, made) = await withNetwork(FeedFixtures.respond) {
            let previous = TrainService.sharedCache
            TrainService.sharedCache = fresh
            defer { TrainService.sharedCache = previous }
            return await TrainService.alertEntries(routes: [marker])
        }
        #expect(entries != nil && made.isEmpty)

        let other = "WN\(UUID().uuidString.prefix(6))"
        let empty = WNFakeCache(marker: other, seed: nil, age: 0)
        let (_, fetched) = await withNetwork(FeedFixtures.respond) {
            let previous = TrainService.sharedCache
            TrainService.sharedCache = empty
            defer { TrainService.sharedCache = previous }
            return await TrainService.alertEntries(routes: [other])
        }
        #expect(fetched.count == 1)
        #expect(empty.saved.count == 1 && empty.saved.first?.contains(other) == true)
    }

    /// The timetable kept on the phone stands in for a board when the MTA can't be reached.
    @Test func boardFromTimetable() throws {
        let now = Date.now
        let timetable = try Timetable(data: WNSupport.timetableBytes(now: now))
        let selection = Selection(stationID: "L29", routes: ["L"], direction: .north)
        let board = TrainService.board(for: selection, from: timetable, now: now)
        #expect(board.trains.count == 1)
        #expect(board.trains.first?.isLive == false)
        #expect(board.alerts == nil && board.outages == nil)
    }
}

/// A `FeedCaching` with one saved feed, for any name containing `marker`, saved `age` ago.
final class WNFakeCache: FeedCaching, @unchecked Sendable {
    private let lock = NSLock()
    private let marker: String
    private let seed: Data?
    private let age: TimeInterval
    private var saves: [String] = []

    init(marker: String, seed: Data?, age: TimeInterval) {
        self.marker = marker
        self.seed = seed
        self.age = age
    }

    /// The names saved.
    var saved: [String] { lock.withLock { saves } }

    func data(for name: String, within age: TimeInterval) -> Data? {
        guard name.contains(marker), let seed, self.age < age else { return nil }
        return seed
    }

    func save(_ data: Data, for name: String) {
        lock.withLock { saves.append(name) }
    }

    var keeps: TimeInterval { 7 * 24 * 60 * 60 }
}
