import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import TrainCore

let testAppID = "XUU899AG4D.dev.dctp.leeway"

/// Lenient limits, so tests other than the rate limit's aren't throttled.
func testLimits() -> Limits {
    var limits = Limits()
    limits.requestsPerMinute = 100_000
    limits.requestBurst = 100_000
    return limits
}

func registrationBody(token: String = sampleToken, started: Date? = nil, selection: Selection = prospect,
                      trip: String = "091200_R..N", state: ContentState? = nil,
                      widgetToken: String? = nil) throws -> [UInt8] {
    var json: [String: Any] = [
        "token": token.uppercased(),
        "environment": "sandbox",
        // As the app's JSONEncoder writes a Selection
        "selection": try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)),
        "trip": trip,
        "alertKinds": [0, 1],
    ]
    if let started { json["started"] = started.timeIntervalSinceReferenceDate }
    if let state { json["state"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) }
    if let widgetToken { json["widgetToken"] = widgetToken }
    return Array(try JSONSerialization.data(withJSONObject: json))
}

func text(_ response: TestResponse) -> String {
    String(decoding: response.body.readableBytesView, as: UTF8.self)
}

@Suite struct SecretModeHTTPTests {
    let secret = "test-secret-0123456789abcdef"
    var bearer: HTTPFields { [.authorization: "Bearer \(secret)"] }

    func withApp(_ body: @escaping @Sendable (any TestClientProtocol, Store) async throws -> Void) async throws {
        let store = try Store(directory: nil)
        let services = HTTPServices(store: store, auth: .secret(secret), appID: testAppID, limits: testLimits())
        try await Application(router: HTTPRoutes.router(services)).test(.router) { client in try await body(client, store) }
    }

    @Test func healthNeedsNoAuthAndSaysOnlyOk() async throws {
        let services = HTTPServices(store: try Store(directory: nil), auth: .secret(secret), appID: testAppID,
                                    limits: testLimits())
        let config = try Config(environment: [
            "APNS_KEY_PATH": "/k.p8", "APNS_KEY_ID": "K", "APNS_TEAM_ID": "T", "DATA_DIR": "/d",
            "ATTEST_MODE": "off", "API_SECRET": secret,
        ])
        #expect(ServerMain.configuration(for: config).serverName == nil)
        // Live, with the server's own configuration: only a running server adds a Server header
        let app = Application(router: HTTPRoutes.router(services), configuration: ServerMain.configuration(for: config))
        try await app.test(.live) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
                #expect(text(response) == "ok")
                #expect(response.headers[.server] == nil)
            }
        }
        // As it would with a name
        let named = Application(router: HTTPRoutes.router(services), configuration: .init(serverName: "TrainTimes"))
        try await named.test(.live) { client in
            try await client.execute(uri: "/health", method: .get) { #expect($0.headers[.server] == "TrainTimes") }
        }
    }

    @Test func rejectsMissingWrongAndMalformedSecrets() async throws {
        let wrong: [HTTPFields] = [
            [:],
            [.authorization: "Bearer wrong"],
            [.authorization: "Bearer \(secret)x"],
            [.authorization: "Bearer \(secret.dropLast())"],
            [.authorization: "bearer \(secret)"],
            [.authorization: "Basic \(secret)"],
            [.authorization: secret],
        ]
        try await withApp { (client, store) async throws in
            for headers in wrong {
                try await client.execute(uri: "/activities", method: .post, headers: headers,
                                         body: ByteBuffer(bytes: try registrationBody())) { response in
                    #expect(response.status == .unauthorized)
                    #expect(text(response).isEmpty)
                }
                try await client.execute(uri: "/activities/\(sampleToken)", method: .delete, headers: headers) { response in
                    #expect(response.status == .unauthorized)
                }
            }
            #expect(await store.count == 0)
        }
    }

    @Test func attestRoutesAreOffWithTheSecret() async throws {
        try await withApp { (client, _) async throws in
            try await client.execute(uri: "/attest/challenge", method: .get, headers: bearer) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/nothing", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test func registersAndDeletes() async throws {
        let started = Date.now - 60
        try await withApp { (client, store) async throws in
            try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try registrationBody(started: started))) { response in
                #expect(response.status == .noContent)
            }
            let saved = try #require(await store.registration(for: sampleToken))
            #expect(saved.selection == prospect)
            #expect(saved.owner == Owner.secret)
            #expect(saved.trip == "091200_R..N")
            #expect(saved.environment == .sandbox)
            #expect(saved.alertKinds == [.delays, .suspended])
            #expect(abs(saved.started.timeIntervalSince(started)) < 0.001)

            // Again: an upsert, not a second one
            try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try registrationBody())) { response in
                #expect(response.status == .noContent)
            }
            #expect(await store.count == 1)

            try await client.execute(uri: "/activities/\(sampleToken)", method: .delete, headers: bearer) { response in
                #expect(response.status == .noContent)
            }
            #expect(await store.count == 0)
        }
    }

    @Test func keepsTheAppsStateForTheFirstPushToMoveOnFrom() async throws {
        let state = ContentState(train: now, trip: "091200_R..N", isLive: true, terminal: "Forest Hills",
                                 following: [now.addingTimeInterval(240)], notice: "Delays", updated: now - 60,
                                 route: "R", followingRoutes: ["R"])
        try await withApp { (client, store) async throws in
            try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try registrationBody(state: state))) { response in
                #expect(response.status == .noContent)
            }
            let saved = try #require(await store.registration(for: sampleToken))
            #expect(saved.lastState == state)
            #expect(saved.lastPush == nil)

            // Without one, as from an app that doesn't send it, there's none
            try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try registrationBody())) { response in
                #expect(response.status == .noContent)
            }
            #expect(await store.registration(for: sampleToken)?.lastState == nil)
        }
    }

    @Test func keepsThePhonesWidgetTokenAndRejectsAMalformedOne() async throws {
        let widgetToken = String(repeating: "cd34", count: 16)
        try await withApp { (client, store) async throws in
            try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try registrationBody(widgetToken: widgetToken.uppercased()))) { response in
                #expect(response.status == .noContent)
            }
            #expect(await store.registration(for: sampleToken)?.widgetToken == widgetToken)

            try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try registrationBody(widgetToken: "not hex"))) { response in
                #expect(response.status == .badRequest)
            }
            // Without one, as from an older app, there's none
            try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try registrationBody())) { response in
                #expect(response.status == .noContent)
            }
            #expect(await store.registration(for: sampleToken)?.widgetToken == nil)
        }
    }

    @Test func givesTheLastPushedStateToAnyoneWithTheToken() async throws {
        try await withApp { (client, store) async throws in
            // Unknown, then known but not yet pushed to: nothing to show
            try await client.execute(uri: "/activities/\(sampleToken)/state", method: .get) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try registrationBody())) { _ in }
            try await client.execute(uri: "/activities/\(sampleToken)/state", method: .get) { response in
                #expect(response.status == .notFound)
            }

            let revision = try #require(await store.registration(for: sampleToken)).revision
            let pushed = state(train: 4, trip: "z")
            try await store.apply([.pushed(token: sampleToken, revision: revision, state: pushed, at: now)])
            // No signature needed: the widgets have none to give
            try await client.execute(uri: "/activities/\(sampleToken.uppercased())/state", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                // As ActivityKit decodes it
                let decoded = try JSONDecoder().decode(ContentState.self, from: Data(response.body.readableBytesView))
                #expect(decoded == pushed)
            }
            try await client.execute(uri: "/activities/xyz/state", method: .get) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func rejectsAStateBiggerThanTheAppSends() async throws {
        let state = ContentState(train: now, trip: "091200_R..N", isLive: true, terminal: "Forest Hills",
                                 following: [now.addingTimeInterval(240)], notice: "Delays", updated: now - 60,
                                 route: "R", followingRoutes: ["R"])
        func with(_ change: (inout ContentState) -> Void) -> ContentState {
            var changed = state
            change(&changed)
            return changed
        }
        func letters(_ count: Int) -> String { String(repeating: "x", count: count) }
        let bad = [
            with { $0.trip = letters(257) },
            with { $0.terminal = letters(257) },
            with { $0.notice = letters(257) },
            with { $0.route = letters(17) },
            with { $0.following = Array(repeating: now, count: 11) },
            with { $0.followingRoutes = Array(repeating: "R", count: 11) },
            with { $0.followingRoutes = [letters(17)] },
        ]
        // Right at the limits
        let longest = with {
            $0.trip = letters(256)
            $0.terminal = letters(256)
            $0.notice = letters(256)
            $0.route = letters(16)
            $0.following = Array(repeating: now, count: 10)
            $0.followingRoutes = Array(repeating: letters(16), count: 10)
        }
        try await withApp { (client, store) async throws in
            for state in bad {
                try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                         body: ByteBuffer(bytes: try registrationBody(state: state))) { response in
                    #expect(response.status == .badRequest)
                }
            }
            #expect(await store.count == 0)
            try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try registrationBody(state: longest))) { response in
                #expect(response.status == .noContent)
            }
            #expect(await store.registration(for: sampleToken)?.lastState == longest)
        }
    }

    @Test func rejectsBadBodies() async throws {
        try await withApp { (client, store) async throws in
            let bad: [[UInt8]] = [
                Array("not json".utf8),
                try registrationBody(token: "../../etc/passwd"),
                try registrationBody(token: "abc"),
                Array(#"{"token":"\#(sampleToken)","environment":"staging","selection":{},"trip":""}"#.utf8),
            ]
            for body in bad {
                try await client.execute(uri: "/activities", method: .post, headers: bearer, body: ByteBuffer(bytes: body)) { response in
                    #expect(response.status == .badRequest)
                }
            }
            let huge = ByteBuffer(string: String(repeating: " ", count: AppContext.bodyLimit + 1))
            try await client.execute(uri: "/activities", method: .post, headers: bearer, body: huge) { response in
                #expect(response.status == .contentTooLarge)
            }
            try await client.execute(uri: "/activities/not-hex", method: .delete, headers: bearer) { response in
                #expect(response.status == .badRequest)
            }
            #expect(await store.count == 0)
        }
    }

    @Test func rejectsStationsAndLinesThatDontExist() async throws {
        let trip = "091200_R..N"
        let bad: [(Selection, String)] = [
            (Selection(stationID: "XXX", routes: ["R"], direction: .north), trip),
            // Prospect Av has only the R
            (Selection(stationID: "R34", routes: ["Q"], direction: .north), trip),
            (Selection(stationID: "R34", routes: ["R", "Q"], direction: .north), trip),
            (Selection(stationID: "R34", routes: [], direction: .north), trip),
            (Selection(stationID: "R34", routes: ["R"], direction: .north, walkMinutes: -1), trip),
            (Selection(stationID: "R34", routes: ["R"], direction: .north, walkMinutes: 181), trip),
            (prospect, String(repeating: "x", count: 257)),
        ]
        try await withApp { (client, store) async throws in
            for (selection, trip) in bad {
                let body = try registrationBody(selection: selection, trip: trip)
                try await client.execute(uri: "/activities", method: .post, headers: bearer, body: ByteBuffer(bytes: body)) { response in
                    #expect(response.status == .badRequest)
                }
            }
            #expect(await store.count == 0)
            // Right at the limits
            let longest = try registrationBody(selection: Selection(stationID: "R34", routes: ["R"], direction: .north, walkMinutes: 180),
                                               trip: String(repeating: "x", count: 256))
            try await client.execute(uri: "/activities", method: .post, headers: bearer, body: ByteBuffer(bytes: longest)) { response in
                #expect(response.status == .noContent)
            }
        }
    }

    @Test func keepsStartedWithinWhatIOSAllows() async throws {
        try await withApp { (client, store) async throws in
            func saved(started: Date?) async throws -> Date {
                try await client.execute(uri: "/activities", method: .post, headers: bearer,
                                         body: ByteBuffer(bytes: try registrationBody(started: started))) { response in
                    #expect(response.status == .noContent)
                }
                return try #require(await store.registration(for: sampleToken)).started
            }
            let before = Date.now
            // None: now
            var started = try await saved(started: nil)
            #expect(started >= before && started <= Date.now)
            // Longer ago than iOS keeps a Live Activity going: as long ago as it does
            started = try await saved(started: before - 9 * 3600)
            #expect(started >= before - ActivityState.lifetime && started <= Date.now - ActivityState.lifetime)
            // In the future: now
            started = try await saved(started: before + 3600)
            #expect(started >= before && started <= Date.now)
        }
    }

    @Test func comparesTheWholeSecret() {
        let auth = BearerAuth(secret: secret)
        #expect(auth.isAuthorized("Bearer \(secret)"))
        #expect(!auth.isAuthorized("Bearer "))
        #expect(!auth.isAuthorized(nil))
        #expect(!auth.isAuthorized("Bearer \(secret) "))
    }
}

/// A device's App Attest key, as the app would use it.
final class TestDevice: @unchecked Sendable {
    let key = P256.Signing.PrivateKey()
    var counter: UInt32 = 0
    var keyID: String { Data(TestAuthority.keyID(of: key)).base64EncodedString() }

    func headers(challenge: String, method: String, path: String, body: [UInt8]) throws -> HTTPFields {
        counter += 1
        let clientData = ClientData.make(challenge: challenge, method: method, path: path, body: body)
        let assertion = try TestAuthority.assertion(clientData: clientData, deviceKey: key, appID: testAppID, counter: counter)
        return [.attestKey: keyID, .attestAssertion: Data(assertion).base64EncodedString(), .attestChallenge: challenge]
    }
}

@Suite struct AttestModeHTTPTests {
    func withApp(limits: Limits = testLimits(), setup: TestingSetup = .router,
                 _ body: @escaping @Sendable (any TestClientProtocol, Store, TestAuthority) async throws -> Void) async throws {
        let store = try Store(directory: nil)
        let authority = try TestAuthority()
        let services = HTTPServices(store: store, auth: .attest([.production]), appID: testAppID, limits: limits,
                                    roots: [authority.root])
        try await Application(router: HTTPRoutes.router(services)).test(setup) { client in
            try await body(client, store, authority)
        }
    }

    static func challenge(_ client: any TestClientProtocol) async throws -> String {
        try await client.execute(uri: "/attest/challenge", method: .get) { response in
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            let json = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
            #expect(json?["expiresIn"] as? Int == 300)
            return try #require(json?["challenge"] as? String)
        }
    }

    static func attestBody(_ device: TestDevice, _ authority: TestAuthority, challenge: String,
                           environment: AttestEnvironment = .production) throws -> ByteBuffer {
        let attestation = try authority.attestation(appID: testAppID, challenge: Array(challenge.utf8), deviceKey: device.key,
                                                    environment: environment)
        return ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: [
            "keyID": device.keyID, "attestation": Data(attestation).base64EncodedString(), "challenge": challenge,
        ]))
    }

    static func attest(_ device: TestDevice, _ client: any TestClientProtocol, _ authority: TestAuthority,
                       challenge: String? = nil, environment: AttestEnvironment = .production) async throws -> HTTPResponse.Status {
        let challenge = if let challenge { challenge } else { try await Self.challenge(client) }
        let body = try attestBody(device, authority, challenge: challenge, environment: environment)
        return try await client.execute(uri: "/attest", method: .post, body: body) { $0.status }
    }

    static func register(_ device: TestDevice, _ client: any TestClientProtocol, token: String = sampleToken,
                         tamper: Bool = false) async throws -> HTTPResponse.Status {
        let body = try registrationBody(token: token)
        let headers = try device.headers(challenge: try await challenge(client), method: "POST", path: "/activities",
                                         body: tamper ? body + [0x20] : body)
        return try await client.execute(uri: "/activities", method: .post, headers: headers, body: ByteBuffer(bytes: body)) { $0.status }
    }

    static func delete(_ device: TestDevice, _ client: any TestClientProtocol, token: String = sampleToken) async throws -> HTTPResponse.Status {
        let path = "/activities/\(token)"
        let headers = try device.headers(challenge: try await challenge(client), method: "DELETE", path: path, body: [])
        return try await client.execute(uri: path, method: .delete, headers: headers) { $0.status }
    }

    @Test func attestsRegistersAndDeletes() async throws {
        try await withApp { (client, store, authority) async throws in
            let device = TestDevice()
            #expect(try await Self.attest(device, client, authority) == .noContent)
            #expect(try await store.key(id: device.keyID)?.counter == 0)

            #expect(try await Self.register(device, client) == .noContent)
            #expect(await store.registration(for: sampleToken)?.owner == device.keyID)
            #expect(try await store.key(id: device.keyID)?.counter == 1)

            #expect(try await Self.delete(device, client) == .noContent)
            #expect(await store.count == 0)
        }
    }

    @Test func refusesReplaysStaleCountersAndTampering() async throws {
        try await withApp { (client, store, authority) async throws in
            let device = TestDevice()
            #expect(try await Self.attest(device, client, authority) == .noContent)

            // The same request twice: its challenge is used up
            let body = try registrationBody()
            let headers = try device.headers(challenge: try await Self.challenge(client), method: "POST",
                                             path: "/activities", body: body)
            for expected: HTTPResponse.Status in [.noContent, .unauthorized] {
                let status = try await client.execute(uri: "/activities", method: .post, headers: headers,
                                                      body: ByteBuffer(bytes: body)) { $0.status }
                #expect(status == expected)
            }

            // A fresh challenge, but an old counter
            device.counter = 0
            #expect(try await Self.register(device, client) == .unauthorized)
            device.counter = 10

            // Signed for another body
            #expect(try await Self.register(device, client, tamper: true) == .unauthorized)

            // Signed for another path
            let wrongPath = try device.headers(challenge: try await Self.challenge(client), method: "POST",
                                               path: "/activities/x", body: body)
            #expect(try await client.execute(uri: "/activities", method: .post, headers: wrongPath,
                                             body: ByteBuffer(bytes: body)) { $0.status } == .unauthorized)

            // A key never attested
            #expect(try await Self.register(TestDevice(), client) == .unauthorized)

            // No headers, or a made-up challenge
            #expect(try await client.execute(uri: "/activities", method: .post, body: ByteBuffer(bytes: body)) { $0.status } == .unauthorized)
            let madeUp = try device.headers(challenge: "made-up", method: "POST", path: "/activities", body: body)
            #expect(try await client.execute(uri: "/activities", method: .post, headers: madeUp,
                                             body: ByteBuffer(bytes: body)) { $0.status } == .unauthorized)
            #expect(await store.count == 1)
        }
    }

    @Test func attestationNeedsAFreshChallengeOnce() async throws {
        try await withApp { (client, store, authority) async throws in
            let device = TestDevice()
            #expect(try await Self.attest(device, client, authority, challenge: "made-up") == .unauthorized)
            let challenge = try await Self.challenge(client)
            #expect(try await Self.attest(device, client, authority, challenge: challenge) == .noContent)
            #expect(try await Self.attest(device, client, authority, challenge: challenge) == .unauthorized)
            // The same key again
            #expect(try await Self.attest(device, client, authority) == .conflict)
            #expect(try await store.keyCount() == 1)
        }
    }

    @Test func onlyTheOwnerDeletes() async throws {
        try await withApp { (client, store, authority) async throws in
            let owner = TestDevice(), other = TestDevice()
            #expect(try await Self.attest(owner, client, authority) == .noContent)
            #expect(try await Self.attest(other, client, authority) == .noContent)
            #expect(try await Self.register(owner, client) == .noContent)
            #expect(try await Self.delete(other, client) == .forbidden)
            // Nor take it over
            #expect(try await Self.register(other, client) == .forbidden)
            #expect(await store.registration(for: sampleToken)?.owner == owner.keyID)
        }
    }

    @Test func eachKeyKeepsItsNewestFive() async throws {
        try await withApp { (client, store, authority) async throws in
            let device = TestDevice()
            #expect(try await Self.attest(device, client, authority) == .noContent)
            let tokens = (0..<6).map { String(format: "%064x", $0 + 1) }
            for token in tokens {
                #expect(try await Self.register(device, client, token: token) == .noContent)
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(await store.count(ownedBy: device.keyID) == 5)
            #expect(await store.registration(for: tokens[0]) == nil)
            #expect(await store.registration(for: tokens[5]) != nil)
        }
    }

    @Test func capsKeysPerAddressPerDay() async throws {
        var limits = testLimits()
        limits.keysPerIPPerDay = 2
        try await withApp(limits: limits) { (client, store, authority) async throws in
            // Attestations that fail, and a key attested again, use up none of the address's day
            let device = TestDevice()
            for _ in 0..<3 {
                #expect(try await Self.attest(device, client, authority, environment: .development) == .unauthorized)
            }
            #expect(try await Self.attest(device, client, authority) == .noContent)
            #expect(try await Self.attest(device, client, authority) == .conflict)
            #expect(try await Self.attest(TestDevice(), client, authority) == .noContent)
            let over = try Self.attestBody(TestDevice(), authority, challenge: try await Self.challenge(client))
            try await client.execute(uri: "/attest", method: .post, body: over) { response in
                #expect(response.status == .tooManyRequests)
                // Until midnight UTC
                let retryAfter = try #require(response.headers[.retryAfter].flatMap { Int($0) })
                #expect((1...86400).contains(retryAfter))
            }
            #expect(try await store.keyCount() == 2)
        }
    }

    @Test func refusesKeysFromAnEnvironmentNoLongerAllowed() async throws {
        let store = try Store(directory: nil)
        let authority = try TestAuthority()
        func app(_ environments: Set<AttestEnvironment>) -> some ApplicationProtocol {
            Application(router: HTTPRoutes.router(HTTPServices(store: store, auth: .attest(environments), appID: testAppID,
                                                               limits: testLimits(), roots: [authority.root])))
        }
        let development = TestDevice(), production = TestDevice()
        let other = String(format: "%064x", 7)
        try await app([.development, .production]).test(.router) { client async throws in
            #expect(try await Self.attest(development, client, authority, environment: .development) == .noContent)
            #expect(try await Self.attest(production, client, authority) == .noContent)
            #expect(try await Self.register(development, client) == .noContent)
        }
        // ATTEST_ENVIRONMENT=production since
        try await app([.production]).test(.router) { client async throws in
            #expect(try await Self.delete(development, client) == .unauthorized)
            #expect(try await Self.register(development, client, token: other) == .unauthorized)
            #expect(try await Self.register(production, client, token: other) == .noContent)
        }
        #expect(await store.registration(for: sampleToken)?.owner == development.keyID)
        #expect(await store.registration(for: other)?.owner == production.keyID)
    }

    @Test func limitsAttestationBodies() async throws {
        try await withApp { (client, _, _) async throws in
            let huge = ByteBuffer(string: String(repeating: " ", count: AppContext.attestBodyLimit + 1))
            try await client.execute(uri: "/attest", method: .post, body: huge) { #expect($0.status == .contentTooLarge) }
            // Up to the limit it's read, then refused as malformed
            let largest = ByteBuffer(string: String(repeating: " ", count: AppContext.attestBodyLimit))
            try await client.execute(uri: "/attest", method: .post, body: largest) { #expect($0.status == .badRequest) }
        }
    }

    @Test func capsOutstandingChallenges() async throws {
        var limits = testLimits()
        limits.maxChallenges = 2
        try await withApp(limits: limits) { (client, _, _) async throws in
            _ = try await Self.challenge(client)
            _ = try await Self.challenge(client)
            try await client.execute(uri: "/attest/challenge", method: .get) { response in
                #expect(response.status == .serviceUnavailable)
            }
        }
    }

    @Test func capsEachClientsOutstandingChallenges() async throws {
        var limits = testLimits()
        limits.challengesPerIP = 2
        // Live, so requests come from loopback, as cloudflared's do, and CF-Connecting-IP counts
        try await withApp(limits: limits, setup: .live) { (client, _, _) async throws in
            let requests: [(String, HTTPResponse.Status)] = [
                ("2001:db8:1:2::1", .ok), ("2001:db8:1:2::2", .ok),
                // Another address in the same /64 is the same client
                ("2001:db8:1:2::3", .tooManyRequests),
                ("2001:db8:1:3::1", .ok), ("203.0.113.9", .ok), ("203.0.113.9", .ok), ("203.0.113.9", .tooManyRequests),
            ]
            for (address, expected) in requests {
                try await client.execute(uri: "/attest/challenge", method: .get, headers: [.cfConnectingIP: address]) { response in
                    #expect(response.status == expected)
                    if expected == .tooManyRequests {
                        // When its first expires
                        let retryAfter = try #require(response.headers[.retryAfter].flatMap { Int($0) })
                        #expect((290...300).contains(retryAfter))
                    }
                }
            }
        }
    }

    @Test func rateLimitsEveryRoute() async throws {
        var limits = testLimits()
        limits.requestsPerMinute = 3
        limits.requestBurst = 3
        try await withApp(limits: limits) { (client, _, _) async throws in
            for _ in 0..<3 {
                try await client.execute(uri: "/health", method: .get) { #expect($0.status == .ok) }
            }
            // A CF-Connecting-IP from anything but cloudflared on this machine changes nothing
            try await client.execute(uri: "/health", method: .get, headers: [.cfConnectingIP: "203.0.113.9"]) { response in
                #expect(response.status == .tooManyRequests)
                #expect(response.headers[.retryAfter] == "60")
            }
            try await client.execute(uri: "/nothing", method: .get) { #expect($0.status == .tooManyRequests) }
        }
    }

    @Test func rateLimitsEachClientBehindCloudflared() async throws {
        var limits = testLimits()
        limits.requestsPerMinute = 1
        limits.requestBurst = 1
        // Live, so requests come from loopback, as cloudflared's do, and CF-Connecting-IP counts
        try await withApp(limits: limits, setup: .live) { (client, _, _) async throws in
            try await client.execute(uri: "/health", method: .get) { #expect($0.status == .ok) }
            let behind: HTTPFields = [.cfConnectingIP: "203.0.113.9"]
            try await client.execute(uri: "/health", method: .get, headers: behind) { #expect($0.status == .ok) }
            try await client.execute(uri: "/health", method: .get, headers: behind) { #expect($0.status == .tooManyRequests) }
            try await client.execute(uri: "/health", method: .get) { #expect($0.status == .tooManyRequests) }
        }
    }

    @Test func clientDataIsPinned() {
        let data = ClientData.make(challenge: "abc", method: "DELETE", path: "/activities/00ff", body: [UInt8]())
        #expect(String(decoding: data, as: UTF8.self) ==
            "abc\nDELETE\n/activities/00ff\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
