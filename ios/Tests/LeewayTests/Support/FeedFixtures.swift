import Foundation
@testable import Leeway

/// The MTA's feeds as saved on a weekday at about 10:30 (Fixtures/README.md), answered for
/// their MTA addresses and the push server's `/feeds?name=` copies alike.
enum FeedFixtures {
    /// Each feed's suffix, as in `nyct%2Fgtfs-ace` ("" for the 1–7's), and its fixture.
    static var feeds: [String: String] { FixtureFeeds.feeds }

    /// Every feed's bytes, by its fixture's name.
    static let data: [String: Data] = feeds.values.reduce(into: [:]) { all, name in
        all[name] = try? Fixtures.data(name)
    }

    /// When they were read: the newest feed header's timestamp.
    static var capturedAt: Date {
        SubwayFeed.newest(Array(data.values)) ?? Fixtures.date("2026-11-10 10:30")
    }

    /// The fixture for a request, from the MTA's address or the push server's `/feeds?name=`
    /// (`FixtureFeeds`, which the UI tests' launch shares). Nil if it isn't a feed.
    static func fixture(for url: URL) -> String? { FixtureFeeds.fixture(for: url) }

    /// Answers every feed request with its fixture, whole (the `stops`/`routes` the server would
    /// trim to are ignored), and nothing else.
    static let respond: @Sendable (URLRequest) -> TestNetwork.Answer? = { request in
        guard let url = request.url, let name = fixture(for: url), let body = try? Fixtures.data(name) else {
            return nil
        }
        return .ok(body)
    }
}
