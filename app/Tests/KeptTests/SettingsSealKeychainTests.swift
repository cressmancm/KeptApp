import CryptoKit
import Security
import XCTest

@testable import Kept

/// The seal key against a real keychain, under a service name of its own.
///
/// The test runner has no keychain entitlement, so this is the login keychain,
/// the store a build without a provisioning profile uses. The data-protection
/// store needs a signed, provisioned app and is checked on an installed build.
final class SettingsSealKeychainTests: XCTestCase {
    private func bytes(_ key: SymmetricKey?) -> Data? {
        key?.withUnsafeBytes { Data($0) }
    }

    func testTheKeyIsCreatedOnceRotatedAndDeleted() throws {
        let service = "com.chipcressman.Kept.tests.settings-seal.\(UUID().uuidString)"
        addTeardownBlock { _ = SettingsSeal.deleteKey(service: service) }

        guard let first = SettingsSeal.key(service: service) else {
            throw XCTSkip("No writable keychain here.")
        }
        XCTAssertEqual(SettingsSeal.store, .login)
        XCTAssertEqual(bytes(SettingsSeal.key(service: service)), bytes(first))

        let rotated = try XCTUnwrap(SettingsSeal.rotatedKey(service: service))
        XCTAssertNotEqual(bytes(rotated), bytes(first))
        XCTAssertEqual(bytes(SettingsSeal.key(service: service)), bytes(rotated))

        XCTAssertEqual(SettingsSeal.deleteKey(service: service), errSecSuccess)
        XCTAssertNotEqual(bytes(SettingsSeal.key(service: service)), bytes(rotated))
    }
}
