import Crypto
import Foundation
import Testing
@testable import TrainCore

@Suite struct RecordedAppAttestTests {
    /// The recorded certificates were valid then (the credential certificates have since expired).
    let recorded = Date(timeIntervalSince1970: 1_709_251_200) // 2024-03-01

    func verifier(_ environments: Set<AttestEnvironment>) -> AppAttest {
        AppAttest(appID: RecordedAppAttest.appID, environments: environments, certificateTime: recorded)
    }

    func bytes(_ base64: String) -> [UInt8] { Array(Data(base64Encoded: base64)!) }

    @Test func verifiesARealDevelopmentAttestationAgainstApplesRoot() async throws {
        let fixture = RecordedAppAttest.Development.self
        let key = try await verifier([.development]).verifyAttestation(
            bytes(fixture.attestation), keyID: fixture.keyID, challenge: bytes(fixture.challenge), now: recorded)
        #expect(key.id == fixture.keyID)
        #expect(key.environment == .development)
        #expect(key.counter == 0)
        #expect(key.publicKey.count == 65)
    }

    @Test func verifiesARealProductionAttestation() async throws {
        let fixture = RecordedAppAttest.Production.self
        let key = try await verifier([.production]).verifyAttestation(
            bytes(fixture.attestation), keyID: fixture.keyID, challenge: bytes(fixture.challenge), now: recorded)
        #expect(key.environment == .production)
    }

    @Test func refusesTheEnvironmentNotAllowed() async throws {
        let fixture = RecordedAppAttest.Development.self
        await #expect(throws: AppAttest.Problem.wrongEnvironment) {
            try await verifier([.production]).verifyAttestation(
                bytes(fixture.attestation), keyID: fixture.keyID, challenge: bytes(fixture.challenge), now: recorded)
        }
    }

    @Test func refusesAnotherChallengeKeyOrApp() async throws {
        let fixture = RecordedAppAttest.Production.self
        await #expect(throws: AppAttest.Problem.nonceMismatch) {
            try await verifier([.production]).verifyAttestation(
                bytes(fixture.attestation), keyID: fixture.keyID, challenge: Array("other".utf8), now: recorded)
        }
        await #expect(throws: AppAttest.Problem.keyIDMismatch) {
            try await verifier([.production]).verifyAttestation(
                bytes(fixture.attestation), keyID: RecordedAppAttest.Development.keyID,
                challenge: bytes(fixture.challenge), now: recorded)
        }
        let otherApp = AppAttest(appID: "XUU899AG4D.dev.dctp.leeway", environments: [.production],
                                 certificateTime: recorded)
        await #expect(throws: AppAttest.Problem.wrongApp) {
            try await otherApp.verifyAttestation(
                bytes(fixture.attestation), keyID: fixture.keyID, challenge: bytes(fixture.challenge), now: recorded)
        }
    }

    @Test func refusesExpiredCertificatesByTheRealClock() async throws {
        let fixture = RecordedAppAttest.Production.self
        let today = AppAttest(appID: RecordedAppAttest.appID, environments: [.production])
        await #expect(throws: AppAttest.Problem.untrustedChain) {
            try await today.verifyAttestation(
                bytes(fixture.attestation), keyID: fixture.keyID, challenge: bytes(fixture.challenge), now: .now)
        }
    }

    @Test func refusesAChainNotFromTheRoot() async throws {
        let fixture = RecordedAppAttest.Production.self
        let otherRoot = AppAttest(appID: RecordedAppAttest.appID, environments: [.production],
                                  roots: [try TestAuthority().root], certificateTime: recorded)
        await #expect(throws: AppAttest.Problem.untrustedChain) {
            try await otherRoot.verifyAttestation(
                bytes(fixture.attestation), keyID: fixture.keyID, challenge: bytes(fixture.challenge), now: recorded)
        }
    }

    @Test func verifiesARealAssertion() throws {
        let fixture = RecordedAppAttest.Assertion.self
        let publicKey = try P256.Signing.PublicKey(pemRepresentation: fixture.publicKeyPEM)
        var key = AttestKey(id: "", publicKey: publicKey.x963Representation, counter: 0,
                            environment: .development, created: recorded, lastUsed: recorded)
        let counter = try verifier([.development]).verifyAssertion(
            bytes(fixture.assertion), clientData: Array(fixture.payload.utf8), key: key)
        #expect(counter == 1)

        // Not again with the same counter
        key.counter = 1
        #expect(throws: AppAttest.Problem.badCounter) {
            try verifier([.development]).verifyAssertion(bytes(fixture.assertion), clientData: Array(fixture.payload.utf8), key: key)
        }
        // Nor for other data
        key.counter = 0
        #expect(throws: AppAttest.Problem.badSignature) {
            try verifier([.development]).verifyAssertion(bytes(fixture.assertion), clientData: Array("x".utf8), key: key)
        }
    }

    @Test func embeddedRootIsApples() {
        let fingerprint = SHA256.hash(data: AppAttest.appleRootDER).map { String(format: "%02X", $0) }.joined()
        #expect(fingerprint == "1CB9823BA28BA6AD2D33A006941DE2AE4F513EF1D4E831B9F7E0FA7B6242C932")
    }
}

@Suite struct SyntheticAppAttestTests {
    let appID = "XUU899AG4D.dev.dctp.leeway"
    let challenge = Array("challenge-123".utf8)

    func verifier(_ authority: TestAuthority, _ environments: Set<AttestEnvironment> = [.production]) -> AppAttest {
        AppAttest(appID: appID, environments: environments, roots: [authority.root])
    }

    func keyID(_ key: P256.Signing.PrivateKey) -> String { Data(TestAuthority.keyID(of: key)).base64EncodedString() }

    @Test func acceptsAWellFormedAttestation() async throws {
        let authority = try TestAuthority()
        let device = P256.Signing.PrivateKey()
        let attestation = try authority.attestation(appID: appID, challenge: challenge, deviceKey: device)
        let key = try await verifier(authority).verifyAttestation(attestation, keyID: keyID(device), challenge: challenge, now: .now)
        #expect(key.publicKey == device.publicKey.x963Representation)
        #expect(key.environment == .production)
    }

    @Test func eachCheckRefuses() async throws {
        let authority = try TestAuthority()
        let device = P256.Signing.PrivateKey()
        let id = keyID(device)
        let cases: [([UInt8], AppAttest.Problem)] = [
            (try authority.attestation(appID: appID, challenge: challenge, deviceKey: device, counter: 1), .badCounter),
            (try authority.attestation(appID: "XUU899AG4D.other.app", challenge: challenge, deviceKey: device), .wrongApp),
            (try authority.attestation(appID: appID, challenge: challenge, deviceKey: device, environment: .development), .wrongEnvironment),
            (try authority.attestation(appID: appID, challenge: challenge, deviceKey: device, credentialID: [UInt8](repeating: 7, count: 32)), .keyIDMismatch),
            (try authority.attestation(appID: appID, challenge: challenge, deviceKey: device, nonceChallenge: Array("old".utf8)), .nonceMismatch),
            (try authority.attestation(appID: appID, challenge: challenge, deviceKey: device, signer: P256.Signing.PrivateKey()), .untrustedChain),
            // Certified by the chain, yet not what App Attest makes
            (try authority.attestation(appID: appID, challenge: challenge, deviceKey: device, aaguid: Array("appattestfuture!".utf8)),
             .malformed("aaguid")),
            (try authority.attestation(appID: appID, challenge: challenge, deviceKey: device, flags: 0x00),
             .malformed("no attested credential data")),
        ]
        for (attestation, problem) in cases {
            await #expect(throws: problem) {
                try await verifier(authority).verifyAttestation(attestation, keyID: id, challenge: challenge, now: .now)
            }
        }
        // Another key's id
        let attestation = try authority.attestation(appID: appID, challenge: challenge, deviceKey: device)
        await #expect(throws: AppAttest.Problem.keyIDMismatch) {
            try await verifier(authority).verifyAttestation(attestation, keyID: keyID(P256.Signing.PrivateKey()), challenge: challenge, now: .now)
        }
        // Junk
        await #expect(throws: AppAttest.Problem.malformed("attestation CBOR")) {
            try await verifier(authority).verifyAttestation([0xff, 0x00], keyID: id, challenge: challenge, now: .now)
        }
        await #expect(throws: AppAttest.Problem.malformed("key id")) {
            try await verifier(authority).verifyAttestation(attestation, keyID: "short", challenge: challenge, now: .now)
        }
    }

    @Test func refusesMoreCertificatesThanApplesTwo() async throws {
        let authority = try TestAuthority()
        let device = P256.Signing.PrivateKey()
        // Each chain would verify if searched: refused before it is
        for extra in [[authority.root], Array(repeating: authority.intermediate, count: 8)] {
            let attestation = try authority.attestation(appID: appID, challenge: challenge, deviceKey: device,
                                                        extraCertificates: extra)
            await #expect(throws: AppAttest.Problem.malformed("attestation object")) {
                try await verifier(authority).verifyAttestation(attestation, keyID: keyID(device), challenge: challenge, now: .now)
            }
        }
    }

    @Test func authenticatorDataRefusesWhatsMalformed() throws {
        let rpIDHash = [UInt8](repeating: 1, count: 32)
        let aaguid = AttestEnvironment.production.aaguid
        // rpIdHash, flags, a counter of 7, then the rest
        func data(flags: UInt8, _ rest: [UInt8]) -> [UInt8] {
            var bytes = rpIDHash
            bytes += [flags, 0, 0, 0, 7]
            return bytes + rest
        }
        let cases: [([UInt8], String)] = [
            (Array(data(flags: 0x40, []).dropLast()), "authenticator data too short"),
            (data(flags: 0x00, aaguid + [0, 0]), "no attested credential data"),
            (data(flags: 0x40, aaguid + [0]), "attested credential data too short"),
            (data(flags: 0x40, aaguid + [0xff, 0xff, 1, 2, 3]), "credential id truncated"),
        ]
        for (bytes, problem) in cases {
            #expect(throws: AppAttest.Problem.malformed(problem)) { try AuthenticatorData(bytes, withCredential: true) }
        }
        let parsed = try AuthenticatorData(data(flags: 0x40, aaguid + [0, 3, 9, 8, 7, 0xa0]), withCredential: true)
        #expect(parsed.rpIDHash == rpIDHash)
        #expect(parsed.counter == 7)
        #expect(parsed.aaguid == aaguid)
        #expect(parsed.credentialID == [9, 8, 7])
        // An assertion's stops after the counter, though Apple's set the AT flag
        let assertion = try AuthenticatorData(data(flags: 0x40, []), withCredential: false)
        #expect(assertion.counter == 7)
        #expect(assertion.credentialID == nil)
        #expect(throws: AppAttest.Problem.malformed("authenticator data too short")) {
            try AuthenticatorData(Array(data(flags: 0x40, []).dropLast()), withCredential: false)
        }
    }

    @Test func assertionsRefuseWhatsMalformed() throws {
        let device = P256.Signing.PrivateKey()
        let key = AttestKey(id: keyID(device), publicKey: device.publicKey.x963Representation, counter: 0,
                            environment: .production, created: .now, lastUsed: .now)
        let verifier = AppAttest(appID: appID, environments: [.production])
        let cases: [([UInt8], String)] = [
            ([0xff], "assertion CBOR"),
            (CBORValue.map([("signature", .bytes([1]))]).encoded, "assertion object"),
            (CBORValue.map([("signature", .bytes([1])), ("authenticatorData", .bytes([UInt8](repeating: 0, count: 36)))]).encoded,
             "authenticator data too short"),
        ]
        for (assertion, problem) in cases {
            #expect(throws: AppAttest.Problem.malformed(problem)) {
                try verifier.verifyAssertion(assertion, clientData: Array("clientData".utf8), key: key)
            }
        }
    }

    @Test func bothEnvironmentsWhenAsked() async throws {
        let authority = try TestAuthority()
        let device = P256.Signing.PrivateKey()
        let attestation = try authority.attestation(appID: appID, challenge: challenge, deviceKey: device, environment: .development)
        let key = try await verifier(authority, [.development, .production])
            .verifyAttestation(attestation, keyID: keyID(device), challenge: challenge, now: .now)
        #expect(key.environment == .development)
    }

    @Test func assertionCountersMustRise() throws {
        let device = P256.Signing.PrivateKey()
        let verifier = AppAttest(appID: appID, environments: [.production])
        var key = AttestKey(id: keyID(device), publicKey: device.publicKey.x963Representation, counter: 0,
                            environment: .production, created: .now, lastUsed: .now)
        let data = Array("clientData".utf8)
        #expect(try verifier.verifyAssertion(TestAuthority.assertion(clientData: data, deviceKey: device, appID: appID, counter: 1),
                                             clientData: data, key: key) == 1)
        key.counter = 5
        #expect(throws: AppAttest.Problem.badCounter) {
            try verifier.verifyAssertion(TestAuthority.assertion(clientData: data, deviceKey: device, appID: appID, counter: 5),
                                         clientData: data, key: key)
        }
        #expect(try verifier.verifyAssertion(TestAuthority.assertion(clientData: data, deviceKey: device, appID: appID, counter: 9),
                                             clientData: data, key: key) == 9)
        // Another key's signature, another app's
        #expect(throws: AppAttest.Problem.badSignature) {
            try verifier.verifyAssertion(TestAuthority.assertion(clientData: data, deviceKey: P256.Signing.PrivateKey(), appID: appID, counter: 9),
                                         clientData: data, key: key)
        }
        #expect(throws: AppAttest.Problem.wrongApp) {
            try verifier.verifyAssertion(TestAuthority.assertion(clientData: data, deviceKey: device, appID: "XUU899AG4D.other", counter: 9),
                                         clientData: data, key: key)
        }
    }
}

@Suite struct CBORTests {
    @Test func decodesTheTypesAppAttestUses() throws {
        let value = try CBOR.decode(CBORValue.map([
            ("a", .bytes([1, 2])), ("b", .text("hé")), ("c", .array([.unsigned(500), .unsigned(70000)])),
        ]).encoded)
        #expect(value["a"]?.bytes == [1, 2])
        #expect(value["b"]?.text == "hé")
        #expect(value["c"]?.array == [.unsigned(500), .unsigned(70000)])
        #expect(try CBOR.decode([0x20]) == .negative(0))
        #expect(try CBOR.decode([0xf5]) == .bool(true))
        #expect(try CBOR.decode([0xf6]) == .null)
    }

    @Test func refusesWhatItShouldnt() {
        let bad: [([UInt8], CBOR.Problem)] = [
            ([], .truncated),
            ([0x5a, 0xff, 0xff, 0xff, 0xff], .truncated), // a 4 GB byte string
            ([0x9b] + [UInt8](repeating: 0xff, count: 8), .truncated), // a huge array
            ([0x5f, 0xff], .unsupported(0x5f)), // indefinite length
            ([0xc0, 0x00], .unsupported(0xc0)), // a tag
            ([0xfb] + [UInt8](repeating: 0, count: 8), .unsupported(0xfb)), // a double
            ([0x62, 0xff, 0xfe], .invalidText),
            ([0xa2, 0x61, 0x61, 0x00, 0x61, 0x61, 0x01], .duplicateKey),
            ([0x00, 0x00], .trailingBytes),
            (Array(repeating: 0x81, count: 20) + [0x00], .tooDeep),
        ]
        for (bytes, problem) in bad {
            #expect(throws: problem) { try CBOR.decode(bytes) }
        }
    }
}
