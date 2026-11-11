import XCTest

/// CPU while nothing's touched: each tab left alone, and the app put away. XCTCPUMetric for the
/// result bundle; the app's own CPU samples (`UITestRecord`) to check against a bound here.
final class BatteryTests: XCTestCase {
    private var app: XCUIApplication!
    private var record: URL!

    /// The most CPU a tab may use left alone, as a share of the time: the ticking minutes and a
    /// reload a minute should be far below it.
    private static let idleShare = 0.03

    private static var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        return options
    }

    override func setUp() {
        continueAfterFailure = false
        record = TestApp.newRecord(name)
        app = TestApp.make(recordingTo: record)
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    /// `tab` left alone for 30 s, after 5 s to settle, measured and checked against `idleShare`.
    private func idle(on tab: String) {
        if tab == "Nearby" { app.openNearby() } else { app.pick(tab) }
        sleep(5)
        let start = Date.now
        measure(metrics: [XCTCPUMetric(application: app)], options: Self.options) {
            sleep(30)
        }
        let cpu = Record(record).between(start).cpu
        let used = try! XCTUnwrap(cpu, "No CPU samples")
        let share = used.used / used.over
        print("CPU idle on \(tab): \(String(format: "%.3f", used.used)) s over \(String(format: "%.0f", used.over)) s = \(String(format: "%.2f", share * 100))%")
        XCTAssertLessThan(share, Self.idleShare, "\(tab) uses \(share * 100)% CPU left alone")
    }

    func testIdleNearby() { idle(on: "Nearby") }

    func testIdleRoutes() { idle(on: "Routes") }

    func testIdleSettings() { idle(on: "Settings") }

    func testIdleNavigate() { idle(on: "Navigate") }

    /// Put away on Nearby for 30 s, then back. The simulator doesn't suspend it (its CPU samples
    /// go on), so what's checked is that it does next to nothing once it's settled.
    func testBackgrounded() {
        app.openNearby()
        sleep(3)
        measure(metrics: [XCTCPUMetric(application: app)], options: Self.options) {
            XCUIDevice.shared.press(.home)
            sleep(30)
            app.activate()
            sleep(5)
        }
        let all = Record(record)
        let away = try! XCTUnwrap(all.phase("background").last, "Never went to the background")
        let back = try! XCTUnwrap(all.phase("foreground").last { $0 > away }, "Never came back")
        // A few seconds to finish what it was doing first
        let used = try! XCTUnwrap(all.between(away.addingTimeInterval(5), back).cpu, "No CPU samples while away")
        let share = used.used / used.over
        print("CPU put away: \(String(format: "%.3f", used.used)) s over \(String(format: "%.0f", used.over)) s = \(String(format: "%.2f", share * 100))%")
        XCTAssertLessThan(share, 0.005, "Put away on Nearby, still using \(share * 100)% CPU")
    }
}
