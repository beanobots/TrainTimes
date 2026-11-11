import Foundation
import Testing
@testable import Leeway

/// The test harness itself: a quiet host, and `TestNetwork` catching every request.
struct HarnessTests {
    @Test func hostLaunchesQuietly() {
        #expect(TestHost.isUnitTesting)
    }

    @Test func serverSessionGoesThroughTestNetwork() async throws {
        let url = try #require(URL(string: "https://api.dctp.dev/harness"))
        let (result, made) = try await withNetwork({ _ in .ok(Data("hi".utf8)) }) {
            try await TrainService.serverSession.data(from: url).0
        }
        #expect(result == Data("hi".utf8))
        #expect(made.map(\.url) == [url])
    }

    @Test func unansweredRequestFailsAsOffline() async throws {
        let url = try #require(URL(string: "https://api.dctp.dev/nothing"))
        await withNetwork {
            await #expect(throws: URLError.self) {
                _ = try await URLSession.shared.data(from: url)
            }
        }
    }
}
