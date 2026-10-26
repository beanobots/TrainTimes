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

/// The per-client token bucket, on every request: `GET /feeds`'s own, every other route's
/// shared.
struct RateLimit: RouterMiddleware {
    typealias Context = AppContext
    let limiter: RateLimiter
    let feedLimiter: RateLimiter

    func handle(_ request: Request, context: AppContext,
                next: (Request, AppContext) async throws -> Response) async throws -> Response {
        var context = context
        context.clientIP = ClientIP.resolve(peer: context.remoteAddress, connectingIP: request.headers[.cfConnectingIP])
        let bucket = request.uri.path == "/feeds" ? feedLimiter : limiter
        guard await bucket.allow(context.clientIP) else {
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
    var feedLimiter: RateLimiter
    var keyCreation: DailyLimiter
    var refusals: RefusalLog
    var auth: AuthMode
    var attest: AppAttest
    var limits: Limits
    var feeds: FeedRelay
    var timetable: TimetableCopy
    /// Nil without a Google key: `GET /routes` isn't offered.
    var routes: TransitRoutes?
    /// Nil without a Bus Time key: `GET /buses` isn't offered.
    var buses: BusTime?

    init(store: Store, auth: AuthMode, appID: String, limits: Limits, roots: [Certificate]? = nil,
         feeds: FeedRelay = FeedRelay(interval: 20), timetable: TimetableCopy = TimetableCopy(),
         routes: TransitRoutes? = nil, buses: BusTime? = nil) {
        self.store = store
        self.routes = routes
        self.buses = buses
        self.auth = auth
        self.limits = limits
        self.feeds = feeds
        self.timetable = timetable
        challenges = ChallengeStore(limit: limits.maxChallenges, perClient: limits.challengesPerIP)
        limiter = RateLimiter(perMinute: limits.requestsPerMinute, burst: limits.requestBurst)
        feedLimiter = RateLimiter(perMinute: limits.feedRequestsPerMinute, burst: limits.feedRequestBurst)
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
        router.add(middleware: RateLimit(limiter: services.limiter, feedLimiter: services.feedLimiter))

        // Says only that it's up
        router.get("/health") { _, _ in "ok" }

        // An MTA feed as the poller last read it (`FeedRelay`), for the app and widgets to read
        // here before the MTA; never read for a request. Public data, so no authentication:
        // widgets can't sign requests.
        // With `stops` (a train feed's) or `routes` (the alerts'), comma-separated, only what
        // those need (`FeedRelay.served`); gzipped for a client that takes it. Both save phones
        // with little signal below ground most of the download.
        router.get("/feeds") { request, _ -> Response in
            let query = request.uri.queryParameters
            guard let name = query.get("name") else { throw HTTPError(.badRequest) }
            guard FeedRelay.feeds[name] != nil else { throw HTTPError(.notFound) }
            var ask = FeedRelay.Ask(name: name, gzip: Gzip.isAccepted(by: request.headers[.acceptEncoding]))
            if let stops = query.get("stops") {
                guard let ids = FeedRelay.ids(in: stops) else { throw HTTPError(.badRequest) }
                ask.stops = ids
            }
            if let routes = query.get("routes") {
                guard let ids = FeedRelay.ids(in: routes) else { throw HTTPError(.badRequest) }
                ask.routes = ids
            }
            guard let served = await services.feeds.served(ask) else { throw HTTPError(.badGateway) }
            var headers: HTTPFields = [.contentType: "application/octet-stream", .cacheControl: "no-store",
                                       .vary: "Accept-Encoding"]
            if served.gzipped { headers[.contentEncoding] = "gzip" }
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: served.data)))
        }

        // The timetable the app falls back on when the MTA can't be reached (`TimetableMaker`).
        // Public, like the feeds; with If-None-Match, 304 if the phone has the current one.
        router.get("/timetable") { request, _ -> Response in
            guard let data = await services.timetable.data, let etag = await services.timetable.etag else {
                throw HTTPError(.serviceUnavailable)
            }
            let headers: HTTPFields = [.contentType: "application/octet-stream", .eTag: etag,
                                       .cacheControl: "no-cache"]
            if request.headers[.ifNoneMatch] == etag {
                return Response(status: .notModified, headers: headers)
            }
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }

        // Google's subway routes between two places in the city (`TransitRoutes`), for directions
        // shared to the app's Share extension, which can't sign requests: from=lat,lon&to=lat,lon,
        // optionally at=<seconds since 1970> to leave then, and bus=1 for bus rides too. Daily
        // limits keep it in Google's free allowance; where trips are isn't logged.
        if let routes = services.routes {
            router.get("/routes") { request, context -> Response in
                let query = request.uri.queryParameters
                guard let from = TransitRoutes.point(query.get("from")),
                      let to = TransitRoutes.point(query.get("to")),
                      TransitRoutes.isInCity(from), TransitRoutes.isInCity(to) else {
                    throw HTTPError(.badRequest)
                }
                // Not in the past, which Google refuses, nor over a week on
                let now = Date.now
                let asked = query.get("at").flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) } ?? now
                let departure = min(max(asked, now), now.addingTimeInterval(7 * 86400))
                let bus = query.get("bus") == "1"
                switch await routes.routes(from: from, to: to, departure: departure, client: context.clientIP, bus: bus) {
                case .routes(let found):
                    let json = try JSONEncoder().encode(["routes": found])
                    return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                                    body: .init(byteBuffer: ByteBuffer(bytes: json)))
                case .limited(let retryAfter):
                    await log("routes: over a daily limit", context, services)
                    return Response(status: .tooManyRequests, headers: [.retryAfter: String(retryAfter)])
                case .unavailable:
                    throw HTTPError(.badGateway)
                }
            }
        }

        // Bus Time's next buses for a bus ride from `GET /routes?bus=1` (`BusTime`):
        // line=<Google's name for it>&stop=lat,lon, where the ride boards. Public, like the
        // routes, and to daily limits like them; where riders wait isn't logged.
        if let buses = services.buses {
            router.get("/buses") { request, context -> Response in
                let query = request.uri.queryParameters
                guard let line = query.get("line").flatMap(BusTime.validLine),
                      let stop = TransitRoutes.point(query.get("stop")), TransitRoutes.isInCity(stop) else {
                    throw HTTPError(.badRequest)
                }
                switch await buses.arrivals(line: line, near: stop, client: context.clientIP) {
                case .arrivals(let found):
                    // Dates as the app's JSONDecoder reads them by default
                    let json = try JSONEncoder().encode(found)
                    return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                                    body: .init(byteBuffer: ByteBuffer(bytes: json)))
                case .noStop:
                    throw HTTPError(.notFound)
                case .limited(let retryAfter):
                    await log("buses: over a daily limit", context, services)
                    return Response(status: .tooManyRequests, headers: [.retryAfter: String(retryAfter)])
                case .unavailable:
                    throw HTTPError(.badGateway)
                }
            }

            // For the app's Nearby with buses: the closest stop each way within a quarter mile of
            // at=lat,lon, with their next buses (`BusTime.nearbyPlaces`); none with no stop that close.
            router.get("/buses/nearby") { request, context -> Response in
                guard let point = TransitRoutes.point(request.uri.queryParameters.get("at")),
                      TransitRoutes.isInCity(point) else {
                    throw HTTPError(.badRequest)
                }
                // `ways`, the nearest place's, for apps that predate `places`
                let places: [[BusTime.Way]]
                do {
                    places = try await buses.nearbyPlaces(point, client: context.clientIP)
                } catch BusTime.Failure.limited(let retryAfter) {
                    await log("buses: over a daily limit", context, services)
                    return Response(status: .tooManyRequests, headers: [.retryAfter: String(retryAfter)])
                } catch {
                    throw HTTPError(.badGateway)
                }
                struct Nearby: Encodable { var ways: [BusTime.Way]; var places: [[BusTime.Way]] }
                let json = try JSONEncoder().encode(Nearby(ways: places.first ?? [], places: places))
                return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                                body: .init(byteBuffer: ByteBuffer(bytes: json)))
            }
        }

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
            let widgetToken = registration.widgetToken.map(Registration.normalizedToken)
            if case .some(nil) = widgetToken { throw HTTPError(.badRequest) }
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
                lastState: registration.state,
                // Dropped if it's no longer a change for this train, as a saved widget's is
                change: registration.change?.validated(for: registration.selection),
                widgetToken: widgetToken ?? nil
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

        // The state last pushed to a countdown, for the phone's widgets to show the same times
        // (they can't sign requests, but have its push token, which only APNs and the phone
        // know). Times are all it has: nothing about whose it is.
        router.get("/activities/:token/state") { _, context -> Response in
            guard let token = context.parameters.get("token").flatMap(Registration.normalizedToken) else {
                throw HTTPError(.badRequest)
            }
            guard let state = await services.store.registration(for: token)?.lastState else {
                throw HTTPError(.notFound)
            }
            let json = try ContentState.encoder().encode(state)
            return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                            body: .init(byteBuffer: ByteBuffer(bytes: json)))
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
