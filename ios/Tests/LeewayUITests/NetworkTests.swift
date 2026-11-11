import XCTest

/// Requests made per screen, counted from the app's record (`UITestRecord`), and its use of
/// location. The push server's and the MTA's answers are the saved feeds; the rest fail as with
/// no signal, so Nearby's buses and docks retry sooner (every 15 s) than its trains would.
final class NetworkTests: XCTestCase {
    private var app: XCUIApplication!
    private var record: URL!

    override func setUp() {
        continueAfterFailure = false
        record = TestApp.newRecord(name)
        app = TestApp.make(recordingTo: record)
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    /// Prints the counts and attaches them, for the report.
    private func report(_ record: Record, _ title: String) {
        let text = "\(title): \(record.requests.count) requests\n\(record.summary)"
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The same address asked for again within `seconds` of itself, while the first was still
    /// in flight or just answered: each such repeat.
    private func repeats(in record: Record, within seconds: TimeInterval = 2) -> [String] {
        var last: [String: Date] = [:]
        var found: [String] = []
        for entry in record.requests {
            let url = entry.string("url")
            if let before = last[url], entry.at.timeIntervalSince(before) < seconds { found.append(url) }
            last[url] = entry.at
        }
        return found
    }

    /// Nearby's own train feeds: those for its stations' stops (4 Av-9 St's F22/F23/R33/R34).
    private func nearbyFeeds(_ record: Record) -> [Record.Entry] {
        record.requests.filter { $0.string("path") == "/feeds" && $0.string("url").contains("F22N") }
    }

    /// Left on Nearby for a minute: a load, then one a minute, or every 15 s while something's
    /// failing (the buses and docks, here). No feed more often than that.
    func testNearbyForAMinute() {
        app.openNearby()
        let start = Date.now
        sleep(60)
        let all = Record(record)
        report(all, "Nearby, launch and 60 s")
        let minute = all.between(start)
        // Every 15 s at worst, as something fails: 4 a minute, and one at the start
        for (endpoint, count) in minute.byEndpoint {
            XCTAssertLessThanOrEqual(count, 5, "\(endpoint) asked \(count) times in a minute")
        }
        checkRepeats(all)
        // Nearby's first show: one /docks, though it fails here
        let launched = all.entries.first { $0.kind == "launch" }?.at ?? start
        let first = all.requests.filter { $0.string("path") == "/docks" && $0.at < launched.addingTimeInterval(20) }
        XCTAssertEqual(first.count, 1, "Nearby's first show asked /docks \(first.count) times")
    }

    /// No request made twice at once: not even `/docks`, which Nearby's load, starting over as
    /// it finds you and then its stations, asked three times at once till it shared one
    /// (`CitiBike.Served`).
    private func checkRepeats(_ record: Record) {
        XCTAssertEqual(repeats(in: record), [], "The same request made twice at once")
    }

    /// Nearby, then the other tabs and back, a few times within 30 s each: Nearby doesn't load
    /// again on coming back to it so soon (`UpdatingTrains.soonAgain`).
    func testTabSwitching() {
        app.openNearby()
        sleep(2)
        let start = Date.now
        var shown: [(tab: String, at: Date)] = []
        for tab in ["Routes", "Nearby", "Settings", "Nearby", "Navigate", "Nearby"] {
            shown.append((tab, .now))
            app.pick(tab)
            sleep(4)
        }
        let all = Record(record)
        report(all.between(start), "Tab switching, 24 s after Nearby loaded")
        // Routes' first show: every route's first load in one batch, each train feed asked once
        // for all their stops, not once a route (`FirstLoads`)
        let routes = all.between(shown[0].at, shown[1].at)
        report(routes, "Routes, first shown")
        let feeds = routes.requests.filter { $0.string("path") == "/feeds" }.map(Record.endpoint)
            .filter { $0.contains("nyct/gtfs") }
        XCTAssertEqual(feeds.count, Set(feeds).count, "Routes asked for a feed more than once: \(feeds.sorted())")
        let reloads = nearbyFeeds(all.between(start))
        // Its buses and docks failing, it may try again 15 s on; not on each return
        let batches = Set(reloads.map { Int($0.at.timeIntervalSince(start) / 2) }).count
        XCTAssertLessThanOrEqual(batches, 2, "Nearby loaded \(batches) times coming back to it within 30 s")
    }

    /// Turned on its side and back: the same stations listed, nothing loaded again. The map's
    /// resize was taken as a move of yours, Nearby listing what's near its new middle each turn.
    func testRotationKeepsNearby() {
        app.openNearby()
        sleep(3)
        let start = Date.now
        for _ in 0..<2 {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(3)
            XCUIDevice.shared.orientation = .portrait
            sleep(3)
        }
        let turning = Record(record).between(start)
        report(turning, "Turned on its side and back twice")
        XCTAssertEqual(turning.requests.map(Record.endpoint), [], "Loaded again on turning")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'F train at 4 Av-9 St'")).firstMatch.exists,
                      "4 Av-9 St no longer listed after turning")
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    /// Put away for 30 s: nothing asked while away; one load on coming back, not more.
    func testBackgrounding() {
        app.openNearby()
        sleep(5)
        XCUIDevice.shared.press(.home)
        sleep(30)
        app.activate()
        sleep(10)
        let all = Record(record)
        report(all, "Nearby, put away 30 s and back")
        let away = try! XCTUnwrap(all.phase("background").last, "Never went to the background")
        let back = try! XCTUnwrap(all.phase("foreground").last { $0 > away }, "Never came back")
        let whileAway = all.between(away.addingTimeInterval(5), back)
        XCTAssertEqual(whileAway.requests.map(Record.endpoint), [], "Requests while put away")
        let after = all.between(back)
        report(after, "After coming back")
        for (endpoint, count) in after.byEndpoint where endpoint.contains("/feeds") {
            XCTAssertLessThanOrEqual(count, 2, "\(endpoint) asked \(count) times in 10 s of coming back")
        }
        checkRepeats(after)
    }

    /// Location: Nearby asks only while in use, never in the background, and leaves nothing
    /// running once put away (no walk under way). From the location managers' calls as recorded.
    func testLocationUse() {
        app.openNearby()
        sleep(3)
        for tab in ["Navigate", "Nearby"] {
            app.pick(tab)
            sleep(3)
        }
        XCUIDevice.shared.press(.home)
        sleep(15)
        app.activate()
        sleep(5)
        let all = Record(record)
        let calls = all.locationCalls
        print("Location calls:\n" + calls.map {
            "\($0.string("call")) \($0["to"].map { "\($0)" } ?? "") accuracy \($0["accuracy"] ?? "") "
                + "\($0.string("appState")) \($0.string("module")) \($0.string("manager")) \($0.string("caller"))"
        }.joined(separator: "\n"))
        XCTAssertFalse(calls.contains { $0.string("call") == "requestAlwaysAuthorization" }, "Asked for Always")
        XCTAssertFalse(calls.contains { $0.string("call") == "startMonitoringSignificantLocationChanges" })
        XCTAssertFalse(calls.contains { $0.string("call") == "setAllowsBackgroundLocationUpdates" && ($0["to"] as? Bool) == true },
                       "Background location turned on without a walk")
        // A fix known as Nearby first shows (here, Pretend Location's): the map starts on it,
        // not following you, which ran MapKit's own best-for-navigation GPS till it was framed
        XCTAssertFalse(calls.contains { $0.string("call") == "startUpdatingLocation" && $0.string("module") == "MapKit" },
                       "MapKit's GPS started on Nearby with a fix known")
        let starts: Set = ["startUpdatingLocation", "requestLocation", "startUpdatingHeading"]
        XCTAssertFalse(calls.contains { starts.contains($0.string("call")) && $0.string("appState") == "background" },
                       "Location asked for in the background")
        // Each manager's last start or stop before being put away was a stop
        let away = try! XCTUnwrap(all.phase("background").last)
        var updating: [String: Bool] = [:]
        for call in calls where call.at < away {
            switch call.string("call") {
            case "startUpdatingLocation": updating[call.string("manager")] = true
            case "stopUpdatingLocation": updating[call.string("manager")] = false
            default: break
            }
        }
        let still = updating.filter(\.value).keys.sorted()
        XCTAssertEqual(still, [], "Location still updating as the app was put away")
    }
}
