import APNS
import APNSCore
import Crypto
import Foundation
import NIOPosix

/// One Live Activity push.
struct Push: Sendable, Equatable {
    enum Event: String, Sendable { case update, end }

    var token: String
    var environment: PushEnvironment
    var event: Event
    var state: ContentState
    /// 10 to show now, 5 when it can wait.
    var priority: Int
    var timestamp: Date
    var staleDate: Date?
    var dismissalDate: Date?
}

enum PushResult: Sendable, Equatable {
    case sent
    /// APNs no longer knows the token (or never did): it's to be dropped.
    case invalidToken(String)
    case failed(String)
}

protocol Pusher: Sendable {
    func send(_ push: Push) async -> PushResult
    func shutdown() async
}

/// Sends pushes with token (JWT) authentication, through the sandbox or the
/// production servers as each token needs.
final class APNSPusher: Pusher {
    private typealias Client = APNSClient<JSONDecoder, JSONEncoder>
    private let sandbox: Client
    private let production: Client
    private let topic: String

    init(config: APNSConfig) throws {
        let pem: String
        do {
            pem = try String(contentsOfFile: config.keyPath, encoding: .utf8)
        } catch {
            throw Config.Problem(description: "Can't read the APNs key at APNS_KEY_PATH: \(error.localizedDescription)")
        }
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw Config.Problem(description: "The file at APNS_KEY_PATH isn't a P-256 private key (.p8)")
        }
        func client(_ environment: APNSEnvironment) -> Client {
            Client(
                configuration: .init(
                    authenticationMethod: .jwt(privateKey: key, keyIdentifier: config.keyID, teamIdentifier: config.teamID),
                    environment: environment
                ),
                eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
                responseDecoder: JSONDecoder(),
                // Its defaults are ActivityKit's: content-state dates as seconds since 2001
                requestEncoder: ContentState.encoder()
            )
        }
        sandbox = client(.development)
        production = client(.production)
        topic = config.topic
    }

    /// The payload's `aps` has `timestamp`, `event`, `content-state` and
    /// `stale-date` or `dismissal-date`; those two and `timestamp` are Unix
    /// seconds, as APNs wants, while content-state's dates are ActivityKit's.
    static func notification(for push: Push, topic: String) -> APNSLiveActivityNotification<ContentState> {
        APNSLiveActivityNotification(
            // No use once it's stale, though always worth a few minutes' retrying
            expiration: .timeIntervalSince1970InSeconds(unixSeconds(max(
                push.staleDate ?? push.timestamp.addingTimeInterval(60 * 60),
                push.timestamp.addingTimeInterval(5 * 60)
            ))),
            priority: push.priority == 10 ? .immediately : .consideringDevicePower,
            topic: topic,
            contentState: push.state,
            event: push.event == .end ? .end : .update,
            timestamp: unixSeconds(push.timestamp),
            dismissalDate: push.dismissalDate.map { .timeIntervalSince1970InSeconds(unixSeconds($0)) } ?? .none,
            staleDate: push.staleDate.map(unixSeconds)
        )
    }

    /// A date far outside Int's range, from a malformed feed, gives the
    /// nearest Int rather than crashing the pass.
    private static func unixSeconds(_ date: Date) -> Int { Int(saturating: date.timeIntervalSince1970) }

    /// What an APNs error means for the token. It's dropped only when APNs
    /// doesn't know it or no longer does; for anything else (the server's key
    /// or topic, APNs busy) it's kept. As only the attested app registers,
    /// a token that isn't for the topic means APNS_TOPIC is wrong.
    static func result(status: Int, reason: APNSError.ErrorReason?) -> PushResult {
        let description = "\(status) \(reason?.reason ?? "no reason given")"
        let gone: [APNSError.ErrorReason] = [.badDeviceToken, .unregistered, .expiredToken]
        if [400, 410].contains(status), let reason, gone.contains(reason) {
            return .invalidToken(description)
        }
        return .failed("APNs \(description)")
    }

    func send(_ push: Push) async -> PushResult {
        let notification = Self.notification(for: push, topic: topic)
        let client = push.environment == .production ? production : sandbox
        let token = push.token
        do {
            // APNSwift waits on a request with no deadline; one that hangs mustn't hold up the pass.
            // Both clients are HTTP/2, so concurrent pushes share their connections.
            _ = try await Concurrency.withTimeout(30) {
                try await client.sendLiveActivityNotification(notification, deviceToken: token)
            }
            return .sent
        } catch let error as APNSError {
            return Self.result(status: error.responseStatus, reason: error.reason)
        } catch {
            return .failed(String(describing: error))
        }
    }

    func shutdown() async {
        try? await sandbox.shutdown()
        try? await production.shutdown()
    }
}
