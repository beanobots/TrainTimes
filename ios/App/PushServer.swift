import CryptoKit
import DeviceCheck
import Foundation
import os

/// `POST /activities`'s body, as the server decodes it (server/Sources/TrainCore/Registrations.swift,
/// `RegistrationRequest`), written by a plain `JSONEncoder`: dates in seconds since 2001, and
/// nil fields left out.
struct PushRegistration: Encodable, Sendable {
    /// The countdown's push token, in lowercase hex.
    var token: String
    /// APNs's environment: "sandbox" or "production".
    var environment: String
    var selection: Selection
    /// `ContentState.trip`.
    var trip: String
    var started: Date?
    /// `AppSettings.alertKinds`' raw values, e.g. `[0, 1, 2, 3]`.
    var alertKinds: [Int]?
    /// The countdown's state as the app last posted it, so the first push moves on from the train
    /// it shows.
    var state: CountdownState?
    /// From a Transfers widget, its change, whose lines' alerts the server mentions too.
    var change: Change?
    /// The phone's widget push token (`WidgetPushInfo.token`), in lowercase hex, so the server
    /// reloads the widgets as it pushes new times; nil before iOS gives one.
    var widgetToken: String?
}

/// What an assertion signs (server/Sources/TrainCore/HTTP.swift, `ClientData`): the UTF-8 bytes
/// of the challenge, the method, the path and the lowercase hex SHA-256 of the exact body,
/// joined by "\n" with none at the end.
enum ClientData {
    static func make(challenge: String, method: String, path: String, body: Data) -> Data {
        Data([challenge, method, path, CountdownLookup.hex(hash(body))].joined(separator: "\n").utf8)
    }

    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}

/// The push server (server/), which updates running countdowns through APNs while the app isn't
/// running. Every request that changes a registration is signed with the app's App Attest key.
///
/// Requests go one at a time: each assertion's counter must be above the last the server saw,
/// and two requests at once could both make a key.
actor PushServer {
    static let shared = PushServer()

    enum Failure: Error {
        /// No App Attest here (the simulator), or no server URL.
        case unsupported
        /// Unreachable, busy (5xx) or over its rate limit (429): try again later.
        case unavailable
        /// It answered with `status`; sending the same again won't help.
        case refused(Int)
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Leeway", category: "PushServer")

    /// When requests started being refused (`401`) even with a fresh challenge, kept across
    /// launches; nil once one gets through.
    private static let refusedSinceKey = "pushServerRefusedSince"
    /// How long refusals go on before the key's replaced, and then before it's replaced again.
    private static let rotateAfter: TimeInterval = 60 * 60

    /// APNs's environment for this build's push tokens: the provisioning profile's
    /// `aps-environment` when there is one (builds from Xcode, and ad hoc), else "production":
    /// TestFlight and App Store builds have no profile in them, and push through production.
    static let environment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? Data(contentsOf: url) else { return "production" }
        // The profile is a signed message around a plain XML plist
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound],
                                                                      format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            #if DEBUG
            return "sandbox"
            #else
            return "production"
            #endif
        }
        return entitlements["aps-environment"] as? String == "development" ? "sandbox" : "production"
        #endif
    }()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// The latest request; each waits for the one before.
    private var last: Task<Void, Never>?

    private func inTurn<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = last
        let task = Task {
            await previous?.value
            return try await body()
        }
        last = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Registers a countdown, or replaces its registration.
    func register(_ registration: PushRegistration) async throws {
        let body = try JSONEncoder().encode(registration)
        let status = try await inTurn { try await self.signed("POST", path: "/activities", body: body) }
        switch status {
        case 204: return
        case 429, 500...: throw Failure.unavailable
        default: throw Failure.refused(status)
        }
    }

    /// Stops pushes to a countdown. Already gone counts as done.
    func unregister(token: String) async throws {
        let status = try await inTurn { try await self.signed("DELETE", path: "/activities/\(token)", body: Data()) }
        switch status {
        case 204: return
        case 429, 500...: throw Failure.unavailable
        default: throw Failure.refused(status)
        }
    }

    /// Sends a signed request and returns its status. On a `401`, tries again with a fresh
    /// challenge, and then, as the server may have forgotten the key (unused for 90 days), with a
    /// new one, but only once refusals have gone on for `rotateAfter`: the server answers a bare
    /// `401` alike for a key it doesn't know and for a challenge that expired or a counter that
    /// lagged, and a new key is only so many a day. Until then the `401` is returned, and the
    /// caller backs off.
    private func signed(_ method: String, path: String, body: Data) async throws -> Int {
        guard AttestKey.isSupported, ServerRoutes.baseURL != nil else { throw Failure.unsupported }
        var keyID = try await attestedKey()
        var status = 401
        var refusals = 0
        for attempt in 0..<3 {
            if refusals == 2 {
                // Refused with a fresh challenge too
                guard shouldRotateKey() else { break }
                Self.log.notice("Refused for over an hour; making a new App Attest key")
                AttestKey.discard()
                keyID = try await attestedKey()
            }
            let challenge = try await challenge()
            let assertion: Data
            do {
                assertion = try await AttestKey.assert(keyID, clientData: ClientData.make(challenge: challenge, method: method,
                                                                                          path: path, body: body))
            } catch let error as DCError where error.code == .invalidKey {
                // Gone, e.g. a Keychain restored onto a new install
                Self.log.notice("App Attest key invalid; making a new one")
                AttestKey.discard()
                keyID = try await attestedKey()
                continue
            }
            var request = request(method, path: path)
            request.setValue(keyID, forHTTPHeaderField: "X-Attest-Key")
            request.setValue(challenge, forHTTPHeaderField: "X-Attest-Challenge")
            request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-Attest-Assertion")
            if method == "POST" {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            status = try await send(request).status
            guard status == 401 else {
                // Got past the server's check of the key
                if (200..<300).contains(status) || status == 400 || status == 403 {
                    UserDefaults.standard.removeObject(forKey: Self.refusedSinceKey)
                }
                return status
            }
            refusals += 1
            Self.log.notice("\(method, privacy: .public) \(path.prefix(20), privacy: .public)… refused (401), attempt \(attempt + 1)")
        }
        return status
    }

    /// After a request's been refused with a fresh challenge too: whether that's gone on for
    /// `rotateAfter`, so the key is likely unknown to the server rather than refused for a
    /// passing reason. Starts the clock the first time, and again on saying yes, so a new key
    /// that's refused too isn't replaced straight away.
    private func shouldRotateKey() -> Bool {
        let defaults = UserDefaults.standard
        let now = Date.now
        guard let since = defaults.object(forKey: Self.refusedSinceKey) as? Date else {
            defaults.set(now, forKey: Self.refusedSinceKey)
            return false
        }
        guard now.timeIntervalSince(since) >= Self.rotateAfter else { return false }
        defaults.set(now, forKey: Self.refusedSinceKey)
        return true
    }

    /// The saved key once the server has it, else a new or saved one attested now.
    private func attestedKey() async throws -> String {
        if AttestKey.isAttested, let keyID = AttestKey.saved { return keyID }
        let keyID: String
        if let saved = AttestKey.saved {
            keyID = saved
        } else {
            do { keyID = try await AttestKey.make() } catch {
                Self.log.error("Couldn't make an App Attest key: \(error.localizedDescription, privacy: .public)")
                throw Failure.unavailable
            }
        }
        let challenge = try await challenge()
        let attestation: Data
        do {
            attestation = try await AttestKey.attest(keyID, challenge: challenge)
        } catch let error as DCError where error.code == .invalidKey {
            // Attested before, but the server never heard (or Apple refused it): start again
            Self.log.notice("App Attest key can't be attested; making a new one next time")
            AttestKey.discard()
            throw Failure.unavailable
        } catch {
            // e.g. Apple's servers unreachable: try the same key again later, as Apple asks
            Self.log.error("App Attest attestation failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.unavailable
        }
        var request = request("POST", path: "/attest")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["keyID": keyID, "attestation": attestation.base64EncodedString(),
                                                     "challenge": challenge])
        let status = try await send(request).status
        switch status {
        case 204, 409:
            // 409: the server already has it
            AttestKey.isAttested = true
            Self.log.info("App Attest key attested")
            return keyID
        case 429, 500...:
            throw Failure.unavailable
        default:
            Self.log.error("Attestation refused (\(status))")
            throw Failure.refused(status)
        }
    }

    /// A fresh one-use challenge from `GET /attest/challenge`.
    private func challenge() async throws -> String {
        struct Challenge: Decodable { var challenge: String }
        let (data, status) = try await send(request("GET", path: "/attest/challenge"))
        switch status {
        case 200:
            guard let challenge = try? JSONDecoder().decode(Challenge.self, from: data) else { throw Failure.unavailable }
            return challenge.challenge
        case 429, 500...: throw Failure.unavailable
        default: throw Failure.refused(status)
        }
    }

    private func request(_ method: String, path: String) -> URLRequest {
        // `signed` checked there's a URL
        var request = URLRequest(url: URL(string: ServerRoutes.baseURL!.absoluteString + path)!)
        request.httpMethod = method
        return request
    }

    /// The response's body and status; network errors are `Failure.unavailable`.
    private func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            Self.log.notice("Push server unreachable: \(error.localizedDescription, privacy: .public)")
            throw Failure.unavailable
        }
    }
}
