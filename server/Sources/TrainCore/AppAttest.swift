import Crypto
import Foundation
import SwiftASN1
@_spi(FixedExpiryValidationTime) import X509

/// Which App Attest servers a key was attested by: an app built from Xcode
/// uses the development one, TestFlight and the App Store production.
enum AttestEnvironment: String, Codable, Sendable, CaseIterable {
    case development, production

    /// The authenticator data's aaguid for each.
    var aaguid: [UInt8] {
        switch self {
        case .development: Array("appattestdevelop".utf8)
        case .production: Array("appattest".utf8) + [UInt8](repeating: 0, count: 7)
        }
    }
}

/// An attested key, as stored.
struct AttestKey: Sendable, Equatable {
    /// The app's key identifier: base64 of the SHA256 of the public key.
    var id: String
    /// The public key, X9.63 (65 bytes, uncompressed).
    var publicKey: Data
    var counter: UInt32
    var environment: AttestEnvironment
    var created: Date
    var lastUsed: Date
}

/// The authenticator data in attestations and assertions:
/// rpIdHash (32) | flags (1) | counter (4, big-endian) | [aaguid (16) | credentialId length (2) | credentialId | COSE key]
struct AuthenticatorData: Sendable {
    var rpIDHash: [UInt8]
    var flags: UInt8
    var counter: UInt32
    var aaguid: [UInt8]?
    var credentialID: [UInt8]?

    /// Attested credential data is read only from an attestation's: Apple's
    /// assertions set the AT flag (0x40) yet stop after the counter.
    init(_ bytes: [UInt8], withCredential: Bool) throws {
        guard bytes.count >= 37 else { throw AppAttest.Problem.malformed("authenticator data too short") }
        rpIDHash = Array(bytes[0..<32])
        flags = bytes[32]
        counter = bytes[33..<37].reduce(0) { $0 << 8 | UInt32($1) }
        if withCredential {
            guard flags & 0x40 != 0 else { throw AppAttest.Problem.malformed("no attested credential data") }
            guard bytes.count >= 55 else { throw AppAttest.Problem.malformed("attested credential data too short") }
            aaguid = Array(bytes[37..<53])
            let length = Int(bytes[53]) << 8 | Int(bytes[54])
            guard bytes.count >= 55 + length else { throw AppAttest.Problem.malformed("credential id truncated") }
            credentialID = Array(bytes[55..<(55 + length)])
        }
    }
}

/// Checks attestations and assertions from `DCAppAttestService`, as Apple's
/// "Validating apps that connect to your server" lays out.
struct AppAttest: Sendable {
    /// "TEAMID.bundle.id"
    let appID: String
    let environments: Set<AttestEnvironment>
    /// The Apple App Attestation Root CA, unless a test gives its own.
    let roots: [Certificate]
    /// For tests with recorded attestations, whose certificates have since expired.
    var certificateTime: Date?

    enum Problem: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case untrustedChain
        case nonceMismatch
        case keyIDMismatch
        case wrongApp
        case wrongEnvironment
        case badCounter
        case badSignature

        var description: String {
            switch self {
            case .malformed(let what): "malformed: \(what)"
            case .untrustedChain: "certificate chain not trusted"
            case .nonceMismatch: "nonce mismatch"
            case .keyIDMismatch: "key id mismatch"
            case .wrongApp: "rpIdHash isn't this app's"
            case .wrongEnvironment: "aaguid not allowed"
            case .badCounter: "counter not valid"
            case .badSignature: "signature not valid"
            }
        }
    }

    /// 1.2.840.113635.100.8.2: the nonce in the credential certificate.
    static let nonceExtension: ASN1ObjectIdentifier = [1, 2, 840, 113635, 100, 8, 2]

    init(appID: String, environments: Set<AttestEnvironment>, roots: [Certificate]? = nil, certificateTime: Date? = nil) {
        self.appID = appID
        self.environments = environments
        self.roots = roots ?? [Self.appleRoot]
        self.certificateTime = certificateTime
    }

    /// The key identifier as the app has it (base64 of 32 bytes), or nil.
    static func keyIDBytes(_ keyID: String) -> [UInt8]? {
        guard let data = Data(base64Encoded: keyID), data.count == 32 else { return nil }
        return Array(data)
    }

    /// Verifies an attestation object for `keyID`, made with
    /// `attestKey(keyID, clientDataHash: SHA256(challenge))`, and returns the key to store.
    func verifyAttestation(_ attestation: [UInt8], keyID: String, challenge: [UInt8], now: Date) async throws -> AttestKey {
        guard let keyIDBytes = Self.keyIDBytes(keyID) else { throw Problem.malformed("key id") }
        let object: CBOR
        do { object = try CBOR.decode(attestation) } catch { throw Problem.malformed("attestation CBOR") }
        // x5c is the credential certificate and Apple's intermediate, as Apple
        // sends it: the chain search's cost grows factorially with more
        guard object["fmt"]?.text == "apple-appattest",
              let x5c = object["attStmt"]?["x5c"]?.array, x5c.count == 2,
              let authDataBytes = object["authData"]?.bytes else {
            throw Problem.malformed("attestation object")
        }
        let certificates: [Certificate]
        do {
            certificates = try x5c.map { value in
                guard let der = value.bytes else { throw Problem.malformed("x5c") }
                return try Certificate(derEncoded: der)
            }
        } catch {
            throw Problem.malformed("x5c certificate")
        }
        let credential = certificates[0]

        // 1. The chain, from the credential certificate up to the root
        // Certificates' validity is checked against the clock, unless a test fixes the time
        var verifier = Verifier(rootCertificates: CertificateStore(roots)) {
            if let certificateTime {
                RFC5280Policy(fixedExpiryValidationTime: certificateTime)
            } else {
                RFC5280Policy()
            }
        }
        let result = await verifier.validate(leaf: credential, intermediates: CertificateStore(certificates.dropFirst()))
        guard case .validCertificate = result else { throw Problem.untrustedChain }

        // 2-4. The nonce in the certificate is SHA256(authData ‖ SHA256(challenge))
        let clientDataHash = SHA256.hash(data: challenge)
        let nonce = SHA256.hash(data: authDataBytes + Array(clientDataHash))
        guard let certificateNonce = try? Self.nonce(in: credential), certificateNonce == Array(nonce) else {
            throw Problem.nonceMismatch
        }

        // 5. The key identifier is the SHA256 of the public key
        guard let publicKey = P256.Signing.PublicKey(credential.publicKey) else { throw Problem.malformed("public key") }
        let x963 = publicKey.x963Representation
        guard Array(SHA256.hash(data: x963)) == keyIDBytes else { throw Problem.keyIDMismatch }

        // 6-9. The authenticator data: this app, a new key, an allowed environment, this key
        let authData = try AuthenticatorData(authDataBytes, withCredential: true)
        guard authData.rpIDHash == Array(SHA256.hash(data: Data(appID.utf8))) else { throw Problem.wrongApp }
        guard authData.counter == 0 else { throw Problem.badCounter }
        guard let aaguid = authData.aaguid,
              let environment = AttestEnvironment.allCases.first(where: { $0.aaguid == aaguid }) else {
            throw Problem.malformed("aaguid")
        }
        guard environments.contains(environment) else { throw Problem.wrongEnvironment }
        guard authData.credentialID == keyIDBytes else { throw Problem.keyIDMismatch }

        return AttestKey(id: Data(keyIDBytes).base64EncodedString(), publicKey: x963, counter: 0,
                         environment: environment, created: now, lastUsed: now)
    }

    /// Verifies an assertion made with `generateAssertion(keyID, clientDataHash: SHA256(clientData))`
    /// and returns its counter, which the caller must check is above the stored one and store.
    func verifyAssertion(_ assertion: [UInt8], clientData: [UInt8], key: AttestKey) throws -> UInt32 {
        let object: CBOR
        do { object = try CBOR.decode(assertion) } catch { throw Problem.malformed("assertion CBOR") }
        guard let signatureBytes = object["signature"]?.bytes,
              let authDataBytes = object["authenticatorData"]?.bytes else {
            throw Problem.malformed("assertion object")
        }
        let authData = try AuthenticatorData(authDataBytes, withCredential: false)

        // 1-3. The signature is ECDSA-SHA256 over nonce = SHA256(authenticatorData ‖ SHA256(clientData))
        let clientDataHash = SHA256.hash(data: clientData)
        let nonce = Data(SHA256.hash(data: authDataBytes + Array(clientDataHash)))
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: key.publicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureBytes),
              publicKey.isValidSignature(signature, for: nonce) else {
            throw Problem.badSignature
        }
        // 4. This app's
        guard authData.rpIDHash == Array(SHA256.hash(data: Data(appID.utf8))) else { throw Problem.wrongApp }
        // 5. A counter above the last one
        guard authData.counter > key.counter else { throw Problem.badCounter }
        return authData.counter
    }

    /// The extension's value: SEQUENCE { [1] EXPLICIT OCTET STRING nonce }.
    static func nonce(in certificate: Certificate) throws -> [UInt8] {
        guard let ext = certificate.extensions.first(where: { $0.oid == nonceExtension }) else {
            throw Problem.nonceMismatch
        }
        let node = try DER.parse(ext.value)
        return try DER.sequence(node, identifier: .sequence) { nodes in
            try DER.explicitlyTagged(&nodes, tagNumber: 1, tagClass: .contextSpecific) { inner in
                Array(try ASN1OctetString(derEncoded: inner).bytes)
            }
        }
    }

    /// From https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
    /// (SHA-256 fingerprint 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32).
    static let appleRootPEM = """
        -----BEGIN CERTIFICATE-----
        MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
        JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
        QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
        Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
        biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
        bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
        NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
        Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
        MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
        CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
        53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
        oyFraWVIyd/dganmrduC1bmTBGwD
        -----END CERTIFICATE-----
        """

    /// The PEM's DER, whose SHA-256 a test pins to Apple's fingerprint.
    static var appleRootDER: Data {
        Data(base64Encoded: appleRootPEM.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()) ?? Data()
    }

    static let appleRoot: Certificate = {
        do {
            return try Certificate(pemEncoded: appleRootPEM)
        } catch {
            fatalError("The embedded Apple App Attestation Root CA doesn't parse: \(error)")
        }
    }()
}

