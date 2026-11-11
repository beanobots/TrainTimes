#if DEBUG
import Foundation
import Synchronization

/// Whether the app is hosting unit tests (LeewayTests), which load XCTest into it: the launch
/// then does none of its own work (fetches, Spotlight, walks to restore) and draws nothing,
/// so the tests' requests and timings are theirs alone. UI tests run the app as it is.
enum TestHost {
    static let isUnitTesting = NSClassFromString("XCTestCase") != nil
}

/// Every request the app makes, seen by the tests: on `TrainService.serverSession` and
/// URLSession.shared (MapKit's tiles and search go through neither). Does nothing until a test
/// turns it on. While `isOn`, each request is recorded and answered by `respond`, and one it
/// returns nil for fails as with no signal, so a test never reaches the real network.
final class TestNetwork: URLProtocol, @unchecked Sendable {
    /// A request as made: its URL, headers and body, for counting and checking what's sent.
    struct Made: Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data?
        let at: Date
    }

    /// An answer to a request: a status, headers and body, after `delay` (a slow network).
    struct Answer: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var delay: Duration = .zero
        /// A 3xx's Location, sent as a real redirect: the session's delegate decides whether it's
        /// followed (a new request, recorded too) or the 3xx answers.
        var redirect: URL? = nil

        static func ok(_ body: Data, delay: Duration = .zero) -> Answer {
            Answer(body: body, delay: delay)
        }

        static func status(_ status: Int) -> Answer {
            Answer(status: status)
        }
    }

    private struct State {
        var isOn = false
        var respond: @Sendable (URLRequest) -> Answer? = { _ in nil }
        var seen: (@Sendable (Made, _ cancelled: Bool) -> Void)? = nil
        var made: [Made] = []
    }

    private static let state = Mutex(State())

    /// URLSession.shared asks the registered protocols; `serverSession` has this in its own.
    private static let registered: Void = { URLProtocol.registerClass(TestNetwork.self) }()

    /// Turns it on, answering with `respond`, and forgets the requests made before. `seen` is
    /// told of each request as it's made, and again if it's cancelled before it's answered (UI
    /// tests' record of them, `UITestLaunch`).
    static func start(_ respond: @escaping @Sendable (URLRequest) -> Answer?,
                      seen: (@Sendable (Made, _ cancelled: Bool) -> Void)? = nil) {
        _ = registered
        state.withLock { $0 = State(isOn: true, respond: respond, seen: seen) }
    }

    /// Off: requests go to the network again (or fail, in the tests' simulator, offline).
    static func stop() {
        state.withLock { $0 = State() }
    }

    /// The requests made since `start`, in order.
    static var made: [Made] { state.withLock { $0.made } }

    private let stopped = Mutex(false)
    /// Answered or failed, so a stop after isn't a cancel; and the request, for `seen`'s cancel.
    private let done = Mutex(false)
    private let made = Mutex<Made?>(nil)

    override class func canInit(with request: URLRequest) -> Bool {
        state.withLock { $0.isOn }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let made = Made(url: request.url ?? URL(fileURLWithPath: "/"), method: request.httpMethod ?? "GET",
                        headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request), at: .now)
        let (respond, seen) = Self.state.withLock { state in
            state.made.append(made)
            return (state.respond, state.seen)
        }
        self.made.withLock { $0 = made }
        seen?(made, false)
        let answer = respond(request)
        let delay = answer?.delay ?? .zero
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            guard !stopped.withLock({ $0 }) else { return }
            guard let answer, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                                 headerFields: answer.headers) else {
                done.withLock { $0 = true }
                return client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) ?? ()
            }
            if let redirect = answer.redirect {
                var next = request
                next.url = redirect
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                // Followed, the session stops this load and starts the new one; refused, it waits
                // for this one's own answer, the 3xx
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                    guard !stopped.withLock({ $0 }) else { return }
                    finish(with: response, body: answer.body)
                }
                return
            }
            finish(with: response, body: answer.body)
        }
    }

    private func finish(with response: HTTPURLResponse, body: Data) {
        done.withLock { $0 = true }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
        guard !done.withLock({ $0 }), let made = made.withLock({ $0 }),
              let seen = Self.state.withLock({ $0.seen }) else { return }
        seen(made, true)
    }

    /// A request's body, which URLSession hands a protocol as a stream for uploads.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Which saved feed answers a request, for the unit tests' `FeedFixtures` and the UI tests'
/// launch (`UITestLaunch`) alike: the MTA's feeds as read on a weekday at about 10:30
/// (Tests/LeewayTests/Fixtures), for their MTA addresses and the push server's `/feeds?name=`.
enum FixtureFeeds {
    /// Each feed's suffix, as in `nyct%2Fgtfs-ace` ("" for the 1–7's), and its fixture.
    static let feeds: [String: String] = [
        "": "weekday1030-feed-1234567.pb", "-ace": "weekday1030-feed-ace.pb",
        "-bdfm": "weekday1030-feed-bdfm.pb", "-g": "weekday1030-feed-g.pb",
        "-jz": "weekday1030-feed-jz.pb", "-nqrw": "weekday1030-feed-nqrw.pb",
        "-l": "weekday1030-feed-l.pb", "-si": "weekday1030-feed-si.pb",
    ]

    /// The fixture for a request, by the MTA feed's name it's for ("nyct/gtfs-ace"), from the
    /// MTA's address or the push server's `/feeds?name=`. Nil if it isn't a feed.
    static func fixture(for url: URL) -> String? {
        let name: String?
        if let mta = TrainService.feedName(of: url) {
            name = mta
        } else if url.path.hasSuffix("/feeds") {
            name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "name" }?.value
        } else {
            name = nil
        }
        guard let name else { return nil }
        if name == "camsys/subway-alerts.json" { return "weekday1030-alerts.json" }
        if name == "nyct/nyct_ene.json" { return "weekday1030-outages.json" }
        guard name.hasPrefix("nyct/gtfs") else { return nil }
        return feeds[String(name.dropFirst("nyct/gtfs".count))]
    }
}
#endif
