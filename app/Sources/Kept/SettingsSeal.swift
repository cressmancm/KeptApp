import CryptoKit
import Foundation
import Security

/// Tamper-evidence for the one setting that decides where Kept writes.
///
/// UserDefaults is a plain file anything running as this user can rewrite,
/// and Kept holds Full Disk Access. Unchecked, a program without that access
/// could set the backup folder to somewhere it can read and let the next
/// backup copy the whole library there for it. So the stored destination
/// carries an HMAC, and the key lives in the keychain.
///
/// Which keychain matters. In the login keychain, an item is whatever was
/// saved under Kept's name, by anyone: a program could plant one before Kept
/// first ran (or after an uninstall), open to every app and holding a key it
/// chose, and Kept would seal with a key the program already knows. So a
/// release keeps the key in the data-protection keychain instead, under
/// Kept's access group, which only apps signed by Kept's team can read or
/// write. That needs an entitlement, which needs a provisioning profile
/// (build.sh); a build without one, such as a self-signed contributor build,
/// falls back to the login keychain, hardened as far as it goes there.
enum SettingsSeal {
    static let service = "com.chipcressman.Kept.settings-seal"
    static let account = "destination"

    enum Store: Equatable {
        /// Kept's access group. Only Kept's team can put an item there.
        case dataProtection
        /// The fallback for builds without the keychain entitlement.
        case login
    }

    /// Decided once per process. A build without the entitlement can still
    /// search the data-protection keychain (it just finds nothing), but any
    /// write is refused with errSecMissingEntitlement, so the probe is a
    /// delete. Of an item under its own name that is never created, so it
    /// can't remove anything either way.
    static let store: Store = {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(service).probe",
            kSecUseDataProtectionKeychain as String: true,
        ]
        return SecItemDelete(probe as CFDictionary) == errSecMissingEntitlement
            ? .login : .dataProtection
    }()

    /// The keychain key, created on first use. nil when the keychain can't be
    /// read — locked, or access denied — in which case nothing verifies, and
    /// the folder has to be chosen again rather than trusted unchecked.
    ///
    /// `service` is the keychain item's name; tests pass their own.
    static func key(service: String = service) -> SymmetricKey? {
        if let existing = readKey(store, service) { return existing }
        let fresh = SymmetricKey(size: .bits256)
        switch addKey(fresh, store, service) {
        case errSecSuccess: return fresh
        // Lost a race with another Kept process; use the one that won.
        case errSecDuplicateItem: return readKey(store, service)
        default: return nil
        }
    }

    /// Replaces the key with a fresh one, for sealing a newly chosen folder.
    ///
    /// Every earlier seal stops verifying, so a copy of an old setting — a
    /// folder chosen and then abandoned — can't be put back to redirect the
    /// backup.
    ///
    /// The old item is deleted and a new one added, never updated in place.
    /// In the login keychain that's the hardening: an item Kept adds itself
    /// trusts only Kept, while updating one planted under Kept's name would
    /// write the new key where its planter can read it. If something keeps
    /// planting between the delete and the add, nothing is sealed, and the
    /// folder has to be chosen again rather than sealed with a key that leaks.
    static func rotatedKey(service: String = service) -> SymmetricKey? {
        for _ in 0..<3 {
            let deleted = SecItemDelete(baseQuery(store, service) as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return nil }
            let fresh = SymmetricKey(size: .bits256)
            switch addKey(fresh, store, service) {
            case errSecSuccess: return fresh
            case errSecDuplicateItem: continue
            default: return nil
            }
        }
        return nil
    }

    /// The login-keychain key, when this build has moved to the
    /// data-protection keychain: one a build without the provisioning profile
    /// made. Read once, to carry that build's folder over without asking for
    /// it again; nil otherwise. (Kept 1.0's key isn't reachable this way: it
    /// was saved under the old identifier, see IdentityMigration.)
    static func legacyKeyForMigration() -> SymmetricKey? {
        store == .dataProtection ? readKey(.login, service) : nil
    }

    static func deleteLegacyKey() {
        guard store == .dataProtection else { return }
        SecItemDelete(baseQuery(.login, service) as CFDictionary)
    }

    /// Removes the key. Uninstall only: every sealed setting stops verifying.
    /// From both keychains, so a key left over from 1.0 goes too.
    static func deleteKey(service: String = service) -> OSStatus {
        var first = errSecSuccess
        for store in store == .dataProtection ? [Store.dataProtection, .login] : [.login] {
            let status = SecItemDelete(baseQuery(store, service) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound, first == errSecSuccess {
                first = status
            }
        }
        return first
    }

    static func seal(_ data: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func verify(_ data: Data, seal: Data, key: SymmetricKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(seal, authenticating: data, using: key)
    }

    // MARK: - Keychain

    private static func baseQuery(_ store: Store, _ service: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if store == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func addKey(
        _ key: SymmetricKey, _ store: Store, _ service: String
    ) -> OSStatus {
        var attributes = baseQuery(store, service)
        attributes[kSecAttrLabel as String] = "Kept settings seal"
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        if store == .dataProtection {
            // Readable once the user has logged in, so the 2 AM backup can
            // check the folder with the screen locked; never synced or
            // restored to another Mac.
            attributes[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func readKey(_ store: Store, _ service: String) -> SymmetricKey? {
        var query = baseQuery(store, service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data, data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }
}
