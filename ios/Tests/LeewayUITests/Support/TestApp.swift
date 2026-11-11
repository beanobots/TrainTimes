import XCTest

/// The app launched for a UI test (`UITestLaunch`): past setup, at 4 Av-9 St, its feeds the
/// saved ones in Tests/LeewayTests/Fixtures, read from the source tree (the simulator can), and
/// no real server reached.
enum TestApp {
    /// Tests/LeewayTests/Fixtures, beside this target's folder.
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("LeewayTests/Fixtures").path

    /// The app, set to launch as above; recording to `record`'s file if given.
    static func make(recordingTo record: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITest"]
        if let record { app.launchArguments += ["-UITestRecordRequests", record.path] }
        app.launchEnvironment["LEEWAY_FIXTURES"] = fixtures
        return app
    }

    /// A fresh, empty record file in the test runner's temporary folder, which the simulator's
    /// app can write to (both are on the Mac's disk).
    static func newRecord(_ name: String = #function) -> URL {
        let safe = name.filter { $0.isLetter || $0.isNumber }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("leeway-\(safe)-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }
}

extension XCUIApplication {
    /// The tab bar's button for `name` ("Nearby", "Navigate", "Routes", "Settings").
    func tab(_ name: String) -> XCUIElement {
        tabBars.buttons[name]
    }

    /// Picks a tab and waits for it to be selected.
    func pick(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = tab(name)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "No \(name) tab", file: file, line: line)
        button.tap()
    }

    /// Nearby, with the saved feeds' trains in: the F at 4 Av-9 St listed.
    func openNearby(file: StaticString = #filePath, line: UInt = #line) {
        pick("Nearby", file: file, line: line)
        let tile = buttons.matching(NSPredicate(format: "label BEGINSWITH 'F train at 4 Av-9 St'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "Nearby's trains didn't load", file: file, line: line)
    }
}
