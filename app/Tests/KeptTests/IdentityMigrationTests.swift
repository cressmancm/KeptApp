import XCTest

@testable import Kept

/// Only the pure part: running the migration itself reads and deletes the
/// real com.chip.Kept preferences, so it refuses to outside Kept.app.
final class IdentityMigrationTests: XCTestCase {
    func testSettingsCarryOverButSetupIsRedone() {
        let old: [String: Any] = [
            "scheduleHour": 3, Preferences.removedRetentionDays: 365,
            Preferences.notifyAlways: true,
            DestinationStore.key: Data("folder".utf8), DestinationStore.sealKey: Data([1]),
            Preferences.hasCompletedOnboarding: true, "didRegisterLoginItem": true,
        ]
        let carried = IdentityMigration.carriedPreferences(old)
        XCTAssertEqual(
            Set(carried.keys),
            ["scheduleHour", Preferences.removedRetentionDays, Preferences.notifyAlways])
    }

    /// Whatever runs the tests: `swift test` isn't an app bundle, and Xcode's
    /// test host is one but counts as a test host.
    func testItNeverRunsUnderTests() {
        XCTAssertFalse(IdentityMigration.mayRun)
    }
}
