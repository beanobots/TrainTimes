import XCTest

/// Moves for a profiler to watch (Instruments' Time Profiler attached to the app): each opens
/// its screen, waits `attachWindow` for the profiler to attach, then repeats its moves for
/// `driveFor`. Skipped unless the runner's environment has LEEWAY_PROFILE (xcodebuild's
/// `TEST_RUNNER_LEEWAY_PROFILE=1`), as they measure nothing themselves.
final class ProfilingTests: XCTestCase {
    private var app: XCUIApplication!
    private static let attachWindow: UInt32 = 12
    private static let driveFor: TimeInterval = 25

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LEEWAY_PROFILE"] != nil, "Only for profiling")
        app = TestApp.make()
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
    }

    private func drive(_ moves: () -> Void) {
        sleep(Self.attachWindow)
        let end = Date.now.addingTimeInterval(Self.driveFor)
        while Date.now < end { moves() }
    }

    func testProfileNearbyPanPinch() {
        app.openNearby()
        let map = app.maps.firstMatch
        drive {
            map.swipeLeft(velocity: .slow)
            map.swipeRight(velocity: .default)
            map.pinch(withScale: 2.5, velocity: 2)
            sleep(1)
            map.pinch(withScale: 0.4, velocity: -2)
            sleep(1)
        }
    }

    func testProfileRotation() {
        app.openNearby()
        drive {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
            XCUIDevice.shared.orientation = .portrait
            sleep(2)
        }
    }

    func testProfilePlanning() {
        app.pick("Navigate")
        drive {
            let newTrip = app.buttons["New Trip"]
            if newTrip.exists { newTrip.tap() }
            app.buttons["Work"].firstMatch.tap()
            app.buttons["Plan Trip"].tap()
            _ = app.buttons["Go"].waitForExistence(timeout: 30)
            sleep(1)
        }
    }

    /// Nothing moved, only looked up, as the tests do before each move (accessibility snapshots).
    func testProfileLookups() {
        app.openNearby()
        let map = app.maps.firstMatch
        drive {
            _ = map.exists
            _ = app.buttons.count
            sleep(1)
        }
    }
}
