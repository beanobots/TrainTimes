import DeviceCheck
import Foundation
import Security

/// The App Attest key that signs the app's requests to the push server (server/README.md).
/// Its ID is kept in the Keychain, as there's no way to find it again; whether the server has
/// attested it, in UserDefaults, so a reinstall (whose Keychain may hold a key that no longer
/// exists) attests again, and gets `409` if the key was already.
///
/// Only `PushServer` uses it, one request at a time: assertions must be made in turn, so each
/// counter is above the last, and two requests mustn't both make a key.
enum AttestKey {
    /// False in the simulator and on devices without a Secure Enclave.
    static var isSupported: Bool { DCAppAttestService.shared.isSupported }

    private static let service = "com.rtrainwidget.app.appattest"
    private static let account = "keyID"
    private static let attestedKey = "attestKeyAttested"

    /// The saved key, if any.
    static var saved: String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether the server has the saved key.
    static var isAttested: Bool {
        get { saved != nil && UserDefaults.standard.bool(forKey: attestedKey) }
        set { UserDefaults.standard.set(newValue, forKey: attestedKey) }
    }

    /// Makes a key and saves it, not yet attested.
    static func make() async throws -> String {
        let keyID = try await DCAppAttestService.shared.generateKey()
        discard()
        // Readable in the background once the phone's been unlocked, and never moved to another
        // phone by a backup: the key itself stays in this one's Secure Enclave
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecValueData: Data(keyID.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return keyID
    }

    /// Forgets the saved key, so the next request makes another.
    static func discard() {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
        isAttested = false
    }

    /// `attestKey(keyID, clientDataHash: SHA256(challenge))`, for `POST /attest`.
    static func attest(_ keyID: String, challenge: String) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: ClientData.hash(Data(challenge.utf8)))
    }

    /// `generateAssertion(keyID, clientDataHash: SHA256(clientData))`, for the X-Attest-Assertion header.
    static func assert(_ keyID: String, clientData: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: ClientData.hash(clientData))
    }
}
