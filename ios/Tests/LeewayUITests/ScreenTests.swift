import XCTest

/// Nearby as drawn, saved as screenshots for comparing before and after a change that mustn't
/// change how it looks, and its accessibility tree measured: how many elements, how long a
/// snapshot takes. Skipped unless the runner's environment has LEEWAY_SHOTS, the folder to save
/// them in (xcodebuild's `TEST_RUNNER_LEEWAY_SHOTS=…`).
final class ScreenTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        let path = ProcessInfo.processInfo.environment["LEEWAY_SHOTS"]
        try XCTSkipUnless(path != nil, "Only for comparing screens")
        folder = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func save(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = TestApp.make()
        app.launchArguments += extra
        app.launch()
        app.openNearby()
        // Lines laid out, marks placed, map tiles in
        sleep(6)
        return app
    }

    func testNearbyScreens() {
        let app = launch()
        save("nearby-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        save("nearby-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(3)
        // Scrolled to its foot, the last tiles and the docks' row
        app.scrollViews["nearbyCard"].swipeUp()
        sleep(2)
        save("nearby-portrait-scrolled")
        app.terminate()
    }

    func testNearbyLargestText() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        save("nearby-largest")
        app.scrollViews["nearbyCard"].swipeUp()
        sleep(2)
        save("nearby-largest-scrolled")
        app.terminate()
    }

    /// Elements in Nearby's tree, and the time a snapshot of it takes, the mean of ten.
    func testNearbyAccessibilityTree() throws {
        let app = launch()
        let all = try app.snapshot()
        func count(_ s: XCUIElementSnapshot) -> Int { 1 + s.children.map(count).reduce(0, +) }
        let elements = count(all)
        let start = Date.now
        for _ in 0..<10 { _ = try app.snapshot() }
        let ms = Date.now.timeIntervalSince(start) * 100
        let text = String(format: "Nearby's accessibility tree: %d elements, %.0f ms a snapshot", elements, ms)
        print(text)
        try text.write(to: folder.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
        try app.debugDescription.write(to: folder.appendingPathComponent("tree-dump.txt"), atomically: true, encoding: .utf8)
        app.terminate()
    }
}
