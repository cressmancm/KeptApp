import CryptoKit
import Foundation
import Security

/// Tamper-evidence for the one setting that decides where Kept writes.
///
/// UserDefaults is a plain file anything running as this user can rewrite,
/// and Kept holds Full Disk Access. Unchecked, a program without that access
/// could set the backup folder to somewhere it can read and let the next
/// backup copy the whole library there for it. So the stored destination
/// carries an HMAC, and the key lives in the login keychain, where macOS asks
/// the user before handing an item to any app other than the one that made it.
enum SettingsSeal {
    static let service = "com.chip.Kept.settings-seal"
    static let account = "destination"

    /// The keychain key, created on first use. nil when the keychain can't be
    /// read — locked, or access denied — in which case nothing verifies, and
    /// the folder has to be chosen again rather than trusted unchecked.
    static func key() -> SymmetricKey? {
        if let existing = readKey() { return existing }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Kept settings seal",
            kSecValueData as String: data,
        ]
        switch SecItemAdd(attributes as CFDictionary, nil) {
        case errSecSuccess: return fresh
        // Lost a race with another Kept process; use the one that won.
        case errSecDuplicateItem: return readKey()
        default: return nil
        }
    }

    /// Replaces the key with a fresh one, for sealing a newly chosen folder.
    ///
    /// Every earlier seal stops verifying, so a copy of an old setting — a
    /// folder chosen and then abandoned — can't be put back to redirect the
    /// backup. Falls back to the current key if the keychain won't take the
    /// new one, which leaves replay possible but the setting still sealed.
    static func rotatedKey() -> SymmetricKey? {
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess: return fresh
        case errSecItemNotFound: return key()
        default: return readKey()
        }
    }

    private static func readKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data, data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }

    /// Removes the key. Uninstall only: every sealed setting stops verifying.
    static func deleteKey() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    static func seal(_ data: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func verify(_ data: Data, seal: Data, key: SymmetricKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(seal, authenticating: data, using: key)
    }
}
