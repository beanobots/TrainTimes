import Crypto
import Foundation
import SwiftASN1
import X509
@testable import TrainCore

/// Just enough CBOR encoding to make attestation and assertion objects.
indirect enum CBORValue {
    case bytes([UInt8]), text(String), array([CBORValue]), map([(String, CBORValue)]), unsigned(UInt64)

    var encoded: [UInt8] {
        func head(_ major: UInt8, _ value: UInt64) -> [UInt8] {
            switch value {
            case 0..<24: return [major << 5 | UInt8(value)]
            case 24..<256: return [major << 5 | 24, UInt8(value)]
            case 256..<65536: return [major << 5 | 25, UInt8(value >> 8), UInt8(value & 0xff)]
            default: return [major << 5 | 26] + (0..<4).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xff) }
            }
        }
        switch self {
        case .unsigned(let value): return head(0, value)
        case .bytes(let bytes): return head(2, UInt64(bytes.count)) + bytes
        case .text(let text): return head(3, UInt64(text.utf8.count)) + Array(text.utf8)
        case .array(let items): return head(4, UInt64(items.count)) + items.flatMap(\.encoded)
        case .map(let pairs): return head(5, UInt64(pairs.count)) + pairs.flatMap { CBORValue.text($0.0).encoded + $0.1.encoded }
        }
    }
}

/// A stand-in for Apple's App Attest CA and a device's Secure Enclave key.
struct TestAuthority {
    let rootKey = P256.Signing.PrivateKey()
    let intermediateKey = P256.Signing.PrivateKey()
    let root: Certificate
    let intermediate: Certificate
    let rootName: DistinguishedName
    let intermediateName: DistinguishedName

    init() throws {
        let now = Date.now
        rootName = try DistinguishedName { CommonName("Test App Attestation Root CA") }
        intermediateName = try DistinguishedName { CommonName("Test App Attestation CA 1") }
        root = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(rootKey.publicKey),
            notValidBefore: now - 3600, notValidAfter: now + 86400 * 365,
            issuer: rootName, subject: rootName, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: .init(rootKey))
        intermediate = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(intermediateKey.publicKey),
            notValidBefore: now - 3600, notValidAfter: now + 86400 * 365,
            issuer: rootName, subject: intermediateName, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: .init(rootKey))
    }

    static func keyID(of key: P256.Signing.PrivateKey) -> [UInt8] {
        Array(SHA256.hash(data: key.publicKey.x963Representation))
    }

    static func extensionValue(nonce: [UInt8]) throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.appendConstructedNode(identifier: .sequence) { sequence in
            try sequence.appendConstructedNode(identifier: ASN1Identifier(tagWithNumber: 1, tagClass: .contextSpecific)) { tagged in
                try tagged.serialize(ASN1OctetString(contentBytes: ArraySlice(nonce)))
            }
        }
        return serializer.serializedBytes
    }

    /// An attestation as a device would make for `deviceKey`, with knobs to break each check.
    func attestation(appID: String, challenge: [UInt8], deviceKey: P256.Signing.PrivateKey,
                     environment: AttestEnvironment = .production, counter: UInt32 = 0,
                     credentialID: [UInt8]? = nil, nonceChallenge: [UInt8]? = nil,
                     signer: P256.Signing.PrivateKey? = nil, extraCertificates: [Certificate] = [],
                     flags: UInt8 = 0x40, aaguid: [UInt8]? = nil) throws -> [UInt8] {
        let keyID = Self.keyID(of: deviceKey)
        let credential = credentialID ?? keyID
        // Built a piece at a time: as one `+` chain it's too much for the type checker
        var authData: [UInt8] = Array(SHA256.hash(data: Data(appID.utf8)))
        authData.append(flags)
        authData += withUnsafeBytes(of: counter.bigEndian) { Array($0) }
        authData += aaguid ?? environment.aaguid
        authData += [UInt8(credential.count >> 8), UInt8(credential.count & 0xff)]
        authData += credential
        authData.append(0xa0) // a COSE key, which isn't looked at
        let nonce = Array(SHA256.hash(data: authData + Array(SHA256.hash(data: nonceChallenge ?? challenge))))
        let now = Date.now
        let leaf = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(deviceKey.publicKey),
            notValidBefore: now - 3600, notValidAfter: now + 86400 * 30,
            issuer: intermediateName, subject: try DistinguishedName { CommonName(Data(keyID).base64EncodedString()) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                Certificate.Extension(oid: AppAttest.nonceExtension, critical: false,
                                      value: ArraySlice(try Self.extensionValue(nonce: nonce)))
            },
            issuerPrivateKey: .init(signer ?? intermediateKey))
        let x5c = try ([leaf, intermediate] + extraCertificates).map { certificate -> CBORValue in
            var der = DER.Serializer()
            try der.serialize(certificate)
            return .bytes(der.serializedBytes)
        }
        return CBORValue.map([
            ("fmt", .text("apple-appattest")),
            ("attStmt", .map([
                ("x5c", .array(x5c)),
                ("receipt", .bytes([1, 2, 3])),
            ])),
            ("authData", .bytes(authData)),
        ]).encoded
    }

    /// An assertion as `generateAssertion(keyID, clientDataHash: SHA256(clientData))` makes.
    static func assertion(clientData: [UInt8], deviceKey: P256.Signing.PrivateKey, appID: String,
                          counter: UInt32) throws -> [UInt8] {
        let authData = Array(SHA256.hash(data: Data(appID.utf8))) + [0x00]
            + withUnsafeBytes(of: counter.bigEndian, Array.init)
        let nonce = Data(SHA256.hash(data: authData + Array(SHA256.hash(data: clientData))))
        let signature = try deviceKey.signature(for: nonce)
        return CBORValue.map([
            ("signature", .bytes(Array(signature.derRepresentation))),
            ("authenticatorData", .bytes(authData)),
        ]).encoded
    }
}
