import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import X509

/// Requests' context: who sent it, as far as rate limits go.
struct AppContext: RequestContext, RemoteAddressRequestContext {
    var coreContext: CoreRequestContextStorage
    let remoteAddress: SocketAddress?
    /// Set by `RateLimit`: cloudflared's CF-Connecting-IP, or the peer's
    /// address; an IPv6 address's /64 (see `ClientIP`).
    var clientIP = "unknown"

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        remoteAddress = source.channel.remoteAddress
    }

    /// A registration is a few hundred bytes; an attestation about 7 KB in base64.
    static let bodyLimit = 4 * 1024
    static let attestBodyLimit = 16 * 1024
    /// For a body read without a limit of its own: every route gives one.
    var maxUploadSize: Int { Self.bodyLimit }
}

extension HTTPField.Name {
    static let attestKey = Self("X-Attest-Key")!
    static let attestAssertion = Self("X-Attest-Assertion")!
    static let attestChallenge = Self("X-Attest-Challenge")!
    static let cfConnectingIP = Self("CF-Connecting-IP")!
}

/// The per-client token bucket, on every request.
struct RateLimit: RouterMiddleware {
    typealias Context = AppContext
    let limiter: RateLimiter

    func handle(_ request: Request, context: AppContext,
                next: (Request, AppContext) async throws -> Response) async throws -> Response {
        var context = context
        context.clientIP = ClientIP.resolve(peer: context.remoteAddress, connectingIP: request.headers[.cfConnectingIP])
        guard await limiter.allow(context.clientIP) else {
            return Response(status: .tooManyRequests, headers: [.retryAfter: "60"])
        }
        return try await next(request, context)
    }
}

/// `Authorization: Bearer <API_SECRET>`, with ATTEST_MODE=off.
struct BearerAuth: Sendable {
    private let secretDigest: SHA256.Digest

    init(secret: String) {
        secretDigest = SHA256.hash(data: Data(secret.utf8))
    }

    /// Compares digests of the two, whose length doesn't depend on the
    /// secret's, every byte of them whether or not one differs.
    func isAuthorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let given = SHA256.hash(data: Data(header.utf8.dropFirst("Bearer ".utf8.count)))
        var difference: UInt8 = 0
        for (a, b) in zip(given, secretDigest) {
            difference |= a ^ b
        }
        return difference == 0
    }
}

/// What an assertion for a request signs: `generateAssertion(keyID, clientDataHash: SHA256(clientData))`.
enum ClientData {
    /// The UTF-8 bytes of four lines, joined by "\n" with none at the end:
    /// the challenge, the method ("POST"), the path ("/activities"), and the
    /// lowercase hex SHA256 of the exact body bytes (of nothing, for DELETE).
    static func make(challenge: String, method: String, path: String, body: some Sequence<UInt8>) -> [UInt8] {
        let bodyHash = SHA256.hash(data: Array(body)).hex
        return Array([challenge, method, path, bodyHash].joined(separator: "\n").utf8)
    }
}

/// What the routes work with.
struct HTTPServices: Sendable {
    var store: Store
    var challenges: ChallengeStore
    var limiter: RateLimiter
    var keyCreation: DailyLimiter
    var refusals: RefusalLog
    var auth: AuthMode
    var attest: AppAttest
    var limits: Limits

    init(store: Store, auth: AuthMode, appID: String, limits: Limits, roots: [Certificate]? = nil) {
        self.store = store
        self.auth = auth
        self.limits = limits
        challenges = ChallengeStore(limit: limits.maxChallenges, perClient: limits.challengesPerIP)
        limiter = RateLimiter(perMinute: limits.requestsPerMinute, burst: limits.requestBurst)
        keyCreation = DailyLimiter(limit: limits.keysPerIPPerDay)
        refusals = RefusalLog()
        let environments: Set<AttestEnvironment>
        if case .attest(let allowed) = auth { environments = allowed } else { environments = [] }
        attest = AppAttest(appID: appID, environments: environments, roots: roots)
    }
}

enum HTTPRoutes {
    private struct AttestRequest: Decodable {
        var keyID: String
        /// base64 of the attestation object's CBOR.
        var attestation: String
        var challenge: String
    }

    static func router(_ services: HTTPServices) -> Router<AppContext> {
        let router = Router(context: AppContext.self)
        // First, so it covers every route, and requests for none
        router.add(middleware: RateLimit(limiter: services.limiter))

        // Says only that it's up
        router.get("/health") { _, _ in "ok" }

        if case .attest = services.auth {
            router.get("/attest/challenge") { _, context -> Response in
                let challenge: String
                switch await services.challenges.issue(for: context.clientIP) {
                case .challenge(let issued):
                    challenge = issued
                case .clientFull(let retryAfter):
                    await log("challenges: \(services.limits.challengesPerIP) outstanding", context, services)
                    return Response(status: .tooManyRequests, headers: [.retryAfter: String(retryAfter)])
                case .full:
                    await services.refusals.error("challenges: \(services.limits.maxChallenges) outstanding, refusing more")
                    throw HTTPError(.serviceUnavailable)
                }
                let json = #"{"challenge":"\#(challenge)","expiresIn":\#(Int(ChallengeStore.lifetime))}"#
                return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                                body: .init(byteBuffer: ByteBuffer(string: json)))
            }

            router.post("/attest") { request, context -> Response in
                var request = request
                let body = try await request.collectBody(upTo: AppContext.attestBodyLimit)
                guard let attest = try? JSONDecoder().decode(AttestRequest.self, from: Data(body.readableBytesView)),
                      AppAttest.keyIDBytes(attest.keyID) != nil, attest.challenge.utf8.count <= 128,
                      let attestation = Data(base64Encoded: attest.attestation) else {
                    throw HTTPError(.badRequest)
                }
                guard await services.challenges.consume(attest.challenge) else {
                    return await refuse("attest: challenge unknown or expired", context, services)
                }
                // Only keys made count, so attestations that fail don't use up the address's day
                guard await services.keyCreation.allows(context.clientIP) else {
                    await log("attest: no more keys today", context, services)
                    return Response(status: .tooManyRequests,
                                    headers: [.retryAfter: String(DailyLimiter.secondsUntilReset(now: .now))])
                }
                let key: AttestKey
                do {
                    key = try await services.attest.verifyAttestation(
                        Array(attestation), keyID: attest.keyID, challenge: Array(attest.challenge.utf8), now: .now)
                } catch {
                    return await refuse("attest: \(error)", context, services)
                }
                guard try await services.store.addKey(key) else {
                    throw HTTPError(.conflict)
                }
                await services.keyCreation.record(context.clientIP)
                Log.info("attest: new key \(Redact.id(key.id)) (\(key.environment.rawValue)) from \(Redact.id(context.clientIP))")
                return Response(status: .noContent)
            }
        }

        router.post("/activities") { request, context -> Response in
            var request = request
            // Over the limit, this throws, which is answered with 413
            let body = try await request.collectBody(upTo: AppContext.bodyLimit)
            guard let owner = try await authenticate(request, body: body, context: context, services) else {
                return Response(status: .unauthorized)
            }
            let registration: RegistrationRequest
            do {
                // Dates as the app's JSONEncoder writes them by default
                registration = try JSONDecoder().decode(RegistrationRequest.self, from: Data(body.readableBytesView))
            } catch {
                throw HTTPError(.badRequest)
            }
            guard let token = Registration.normalizedToken(registration.token),
                  let station = registration.selection.station,
                  !registration.selection.routes.isEmpty,
                  registration.selection.routes.allSatisfy(station.routes.contains),
                  (0...180).contains(registration.selection.walkMinutes),
                  registration.trip.utf8.count <= 256,
                  registration.stateFits else {
                throw HTTPError(.badRequest)
            }
            let now = Date.now
            let entry = Registration(
                token: token,
                owner: owner,
                environment: registration.environment,
                selection: registration.selection,
                trip: registration.trip,
                // Not before what iOS would allow, nor in the future
                started: min(max(registration.started ?? now, now - ActivityState.lifetime), now),
                alertKinds: registration.alertKinds?.kinds,
                revision: UUID(),
                lastState: registration.state
            )
            switch try await services.store.upsert(entry, maxTotal: services.limits.maxRegistrations,
                                                   maxPerOwner: services.limits.maxRegistrationsPerKey) {
            case .full:
                await services.refusals.error("register: MAX_REGISTRATIONS (\(services.limits.maxRegistrations)) reached")
                throw HTTPError(.serviceUnavailable)
            case .ownedByOther:
                throw HTTPError(.forbidden)
            case .saved(let evicted):
                for token in evicted {
                    Log.info("drop \(Registration.prefix(of: token)): over \(services.limits.maxRegistrationsPerKey) for its key")
                }
            }
            Log.info("register \(entry.tokenPrefix) \(entry.environment.rawValue) \(entry.selection.trainID) key \(Redact.id(owner))")
            return Response(status: .noContent)
        }

        router.delete("/activities/:token") { request, context -> Response in
            guard let owner = try await authenticate(request, body: ByteBuffer(), context: context, services) else {
                return Response(status: .unauthorized)
            }
            guard let token = context.parameters.get("token").flatMap(Registration.normalizedToken) else {
                throw HTTPError(.badRequest)
            }
            switch try await services.store.remove(token, owner: owner) {
            case .removed:
                Log.info("drop \(Registration.prefix(of: token)): deleted by the app")
            case .notFound:
                break
            case .notOwner:
                throw HTTPError(.forbidden)
            }
            return Response(status: .noContent)
        }
        return router
    }

    /// The owner the request proves it's from, or nil (answered with 401).
    /// With App Attest, the challenge is used up whether or not the rest checks out.
    static func authenticate(_ request: Request, body: ByteBuffer, context: AppContext,
                             _ services: HTTPServices) async throws -> String? {
        switch services.auth {
        case .secret(let secret):
            guard BearerAuth(secret: secret).isAuthorized(request.headers[.authorization]) else {
                await log("auth: wrong or no API_SECRET", context, services)
                return nil
            }
            return Owner.secret
        case .attest:
            guard let keyIDBytes = request.headers[.attestKey].flatMap(AppAttest.keyIDBytes),
                  let assertionText = request.headers[.attestAssertion], assertionText.utf8.count <= 4096,
                  let assertion = Data(base64Encoded: assertionText),
                  let challenge = request.headers[.attestChallenge], challenge.utf8.count <= 128 else {
                await log("auth: missing or malformed X-Attest headers", context, services)
                return nil
            }
            guard await services.challenges.consume(challenge) else {
                await log("auth: challenge unknown or expired", context, services)
                return nil
            }
            let keyID = Data(keyIDBytes).base64EncodedString()
            guard let key = try await services.store.key(id: keyID) else {
                await log("auth: unknown key \(Redact.id(keyID))", context, services)
                return nil
            }
            // Not a key attested while ATTEST_ENVIRONMENT allowed more than it does now
            guard services.attest.environments.contains(key.environment) else {
                await log("auth: key \(Redact.id(keyID)) is \(key.environment.rawValue), which isn't allowed", context, services)
                return nil
            }
            let clientData = ClientData.make(challenge: challenge, method: request.method.rawValue,
                                             path: request.uri.path, body: body.readableBytesView)
            let counter: UInt32
            do {
                counter = try services.attest.verifyAssertion(Array(assertion), clientData: clientData, key: key)
            } catch {
                await log("auth: key \(Redact.id(keyID)): \(error)", context, services)
                return nil
            }
            // Atomically above the stored counter, so one assertion can't be used twice
            guard try await services.store.advanceCounter(keyID: keyID, to: counter, now: .now) else {
                await log("auth: key \(Redact.id(keyID)): counter not above the last", context, services)
                return nil
            }
            return keyID
        }
    }

    /// A refused request's line, with who sent it.
    private static func log(_ message: String, _ context: AppContext, _ services: HTTPServices) async {
        await services.refusals.info("\(message) from \(Redact.id(context.clientIP))")
    }

    private static func refuse(_ message: String, _ context: AppContext, _ services: HTTPServices) async -> Response {
        await log(message, context, services)
        return Response(status: .unauthorized)
    }
}
