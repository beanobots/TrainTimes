import XCTest

/// Cold launch to the first frame. XCTest, not Swift Testing: only it measures. Launched as
/// the other UI tests are (`TestApp`): past setup, no real servers.
final class LaunchTests: XCTestCase {
    func testLaunchTime() {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            TestApp.make().launch()
        }
    }
}
