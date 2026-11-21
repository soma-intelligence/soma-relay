import CryptoKit
import Foundation
import Security

/// AES-256-GCM sealing for everything at rest (message bodies, media, engine state). The key lives
/// in the Keychain, this device only, and never leaves it.
nonisolated final class SecretBox: Sendable {
    static let shared = SecretBox()

    private let key: SymmetricKey

    private static let service = "me.somalabs.relay.storage"
    private static let account = "storage-key-v1"

    init() {
        key = Self.loadOrCreateKey()
    }

    func seal(_ plain: Data) -> Data {
        (try? AES.GCM.seal(plain, using: key).combined) ?? Data()
    }

    func open(_ sealed: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    func seal(_ text: String) -> Data { seal(Data(text.utf8)) }

    func openText(_ sealed: Data?) -> String? {
        guard let sealed, let data = open(sealed) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Emergency wipe: forget the key. Everything sealed with it becomes noise.
    static func destroyKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func loadOrCreateKey() -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(add as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
        return key
    }
}
