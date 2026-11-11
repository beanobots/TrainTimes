import XCTest

/// Hitches while the screens are moved as you would: the map panned and pinched, the cards and
/// pages scrolled, the phone turned. XCTest, not Swift Testing: only it measures.
///
/// On a device, XCTHitchMetric and the scrolling metric's hitch ratio are in the result bundle
/// (`xcrun xcresulttool get test-results metrics`). The simulator measures neither (only the
/// scrolls' durations), so each test also counts the app's own late frames (`UITestFrames`)
/// over its iterations and checks them against `target`: 5 ms of hitches a second.
final class SmoothnessTests: XCTestCase {
    private var app: XCUIApplication!
    private var record: URL!

    /// The most ms of late frames a second.
    private static let target = 5.0

    private static var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        return options
    }

    private func metrics() -> [XCTMetric] {
        [XCTHitchMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric]
    }

    override func setUp() {
        continueAfterFailure = false
        record = TestApp.newRecord(name)
        app = TestApp.make(recordingTo: record)
        app.launchArguments.append("-UITestFrames")
        app.launch()
    }

    /// `measure`, with the app's late frames over its iterations checked against `target`: those
    /// beyond the floor, what the tests' own looking up of `elements` makes the app drop with
    /// nothing moving (accessibility snapshots, on the app's main thread: a lot on Nearby's map).
    /// `known` for a hitch found and not fixed yet, recorded as an expected failure.
    private func measured(metrics: [XCTMetric], options: XCTMeasureOptions, lookingUp elements: [XCUIElement] = [],
                          known: String? = nil, file: StaticString = #filePath, line: UInt = #line,
                          block: () -> Void) {
        let still = Date.now
        for _ in 0..<3 {
            for element in elements { _ = element.exists }
            sleep(1)
        }
        let start = Date.now
        measure(metrics: metrics, options: options, block: block)
        // The last second's frames, written once it's over
        sleep(1)
        let all = Record(record)
        let floor = all.between(still, start).hitches?.ratio ?? 0
        let frames = try! XCTUnwrap(all.between(start).hitches, "No frames recorded", file: file, line: line)
        let text = String(format: "Hitches in %@: %.1f ms/s (%.1f with nothing moving), worst frame %.0f ms late, over %.0f s",
                          name, frames.ratio, floor, frames.worstMs, frames.seconds)
        print(text)
        // Each second's ms late, to tell which moves hitched
        let windows = all.between(start).entries.filter { $0.kind == "frames" }
        print("Timeline: " + windows.map { String(format: "%.0f@%.0f", $0["lateMs"] as? Double ?? 0, $0.at.timeIntervalSince(start)) }
            .joined(separator: " "))
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
        if let known { XCTExpectFailure(known, strict: false) }
        XCTAssertLessThan(frames.ratio - floor, Self.target, text, file: file, line: line)
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    private func openNearby() {
        app.openNearby()
        // Lines laid out and marks placed
        sleep(2)
    }

    func testNearbyMapPanAndPinch() {
        openNearby()
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        measured(metrics: metrics(), options: Self.options, lookingUp: [map],
                 known: "Nearby's map drops frames panned and pinched (~55 ms/s over the floor in the simulator)") {
            map.swipeLeft(velocity: .slow)
            map.swipeUp(velocity: .slow)
            map.swipeRight(velocity: .default)
            map.swipeDown(velocity: .default)
            map.pinch(withScale: 2.5, velocity: 2)
            // Laid out again at rest (`NearbyLinesLayer`)
            sleep(1)
            map.pinch(withScale: 0.4, velocity: -2)
            sleep(1)
        }
    }

    /// The control: Nearby as the others find it, its elements looked up as a swipe would, but
    /// nothing moved. What hitches here is the tests' own looking, not the app's.
    func testNearbyLookupsOnly() {
        openNearby()
        let card = app.scrollViews["nearbyCard"]
        let map = app.maps.firstMatch
        measured(metrics: [XCTHitchMetric(application: app)], options: Self.options, lookingUp: [card, map]) {
            for _ in 0..<4 {
                XCTAssertTrue(card.exists)
                XCTAssertTrue(map.exists)
                _ = app.buttons.count
                sleep(1)
            }
        }
    }

    func testNearbyCardScroll() {
        openNearby()
        let card = app.scrollViews["nearbyCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        measured(metrics: metrics(), options: Self.options, lookingUp: [card]) {
            card.swipeUp(velocity: .fast)
            card.swipeUp(velocity: .default)
            card.swipeDown(velocity: .fast)
            card.swipeDown(velocity: .default)
        }
    }

    /// New Trip to Work (Times Sq): planned, then its trips scrolled.
    func testNewTripPlanAndScroll() {
        app.pick("Navigate")
        let work = app.buttons["Work"].firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        work.tap()
        let plan = app.buttons["Plan Trip"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        plan.tap()
        XCTAssertTrue(app.buttons["Go"].waitForExistence(timeout: 30), "No trips planned")
        // The trips, the only scroll view once planned
        let list = app.scrollViews.firstMatch
        measured(metrics: metrics(), options: Self.options, lookingUp: [list]) {
            list.swipeUp(velocity: .fast)
            list.swipeUp(velocity: .default)
            list.swipeDown(velocity: .fast)
            list.swipeDown(velocity: .default)
        }
    }

    /// No trip takes more than 3 s to plot, from picking To to Go: planning starts once both ends
    /// are picked, then Plan Trip shows the trips. Ideally under 1 s, which the tool's own taps
    /// and waits (some 1 s here) leave no room to check.
    func testTripPlotsWithinThreeSeconds() {
        app.pick("Navigate")
        for attempt in 1...3 {
            let newTrip = app.buttons["New Trip"]
            if newTrip.exists { newTrip.tap() }
            let work = app.buttons["Work"].firstMatch
            XCTAssertTrue(work.waitForExistence(timeout: 10))
            let picked = Date()
            work.tap()
            app.buttons["Plan Trip"].tap()
            XCTAssertTrue(app.buttons["Go"].waitForExistence(timeout: 30), "No trips planned")
            let took = Date().timeIntervalSince(picked)
            print(String(format: "Trip plotted in %.2f s (attempt %d)", took, attempt))
            XCTAssertLessThan(took, 3, "Plotting the trip to Work took \(took) s")
        }
    }

    /// New Trip planned again and again: the tap, the trips coming in and the map framing them.
    func testNewTripPlanning() {
        app.pick("Navigate")
        measured(metrics: [XCTHitchMetric(application: app)], options: Self.options, lookingUp: [app.buttons["Work"].firstMatch],
                 known: "Planning holds the main thread up to ~160 ms as the trips come in") {
            let newTrip = app.buttons["New Trip"]
            if newTrip.exists { newTrip.tap() }
            let work = app.buttons["Work"].firstMatch
            XCTAssertTrue(work.waitForExistence(timeout: 10))
            work.tap()
            app.buttons["Plan Trip"].tap()
            XCTAssertTrue(app.buttons["Go"].waitForExistence(timeout: 30), "No trips planned")
            sleep(1)
        }
    }

    func testSettingsScroll() {
        app.pick("Settings")
        let page = app.scrollViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        measured(metrics: metrics(), options: Self.options, lookingUp: [page]) {
            page.swipeUp(velocity: .fast)
            page.swipeUp(velocity: .default)
            page.swipeDown(velocity: .fast)
            page.swipeDown(velocity: .default)
        }
    }

    func testRoutesScroll() {
        app.pick("Routes")
        let page = app.collectionViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        sleep(2)
        measured(metrics: metrics(), options: Self.options, lookingUp: [page]) {
            page.swipeUp(velocity: .fast)
            page.swipeUp(velocity: .default)
            page.swipeDown(velocity: .fast)
            page.swipeDown(velocity: .default)
        }
    }

    /// Nearby turned on its side and back (`Sideways`).
    func testLandscapeRotation() {
        openNearby()
        measured(metrics: [XCTHitchMetric(application: app)], options: Self.options, lookingUp: [app.maps.firstMatch],
                 known: "Turning Nearby on its side drops frames (~110 ms/s in the simulator)") {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
            XCUIDevice.shared.orientation = .portrait
            sleep(2)
        }
    }
}
