import XCTest

@testable import Kept

@MainActor
final class StalenessAgentTests: XCTestCase {
    /// The plist is hand-written XML, so a typo would only show up as launchd
    /// refusing the job. And without AssociatedBundleIdentifiers, System
    /// Settings lists the job as a second, unbranded "Kept".
    func testAgentPlistParsesAndNamesTheApp() throws {
        let xml = StalenessAgent.plist(
            executable: "/Applications/Kept & Co.app/Contents/MacOS/Kept",
            bundleIdentifier: "com.chipcressman.Kept")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
                as? [String: Any])

        XCTAssertEqual(plist["Label"] as? String, StalenessAgent.label)
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], ["com.chipcressman.Kept"])
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/Applications/Kept & Co.app/Contents/MacOS/Kept", "--staleness-check"])
    }

    // MARK: - "Hasn't run" warnings

    private func scratchDefaults() -> UserDefaults {
        SecurityTests.scratchDefaults(named: "KeptStalenessAgentTests", for: self)
    }

    /// Measured from when the check was set up, not from the app's date: a
    /// release built days before it was installed warned at once.
    func testANewCheckGetsTwoDaysBeforeItCountsAsNotRunning() {
        let defaults = scratchDefaults()
        XCTAssertNil(StalenessAgent.staleWarning(enabled: true, defaults: defaults))

        defaults.set(Date.now.addingTimeInterval(-86_400), forKey: Preferences.stalenessAgentInstalledAt)
        XCTAssertNil(StalenessAgent.staleWarning(enabled: true, defaults: defaults))

        defaults.set(Date.now.addingTimeInterval(-3 * 86_400), forKey: Preferences.stalenessAgentInstalledAt)
        XCTAssertEqual(
            StalenessAgent.staleWarning(enabled: true, defaults: defaults),
            "The daily check hasn't run yet.")
        XCTAssertNil(StalenessAgent.staleWarning(enabled: false, defaults: defaults))
    }

    func testACheckThatStoppedRunningIsReported() {
        let defaults = scratchDefaults()
        defaults.set(Date.now.addingTimeInterval(-86_400), forKey: Preferences.stalenessLastRun)
        XCTAssertNil(StalenessAgent.staleWarning(enabled: true, defaults: defaults))

        defaults.set(Date.now.addingTimeInterval(-4 * 86_400 - 60), forKey: Preferences.stalenessLastRun)
        XCTAssertEqual(
            StalenessAgent.staleWarning(enabled: true, defaults: defaults),
            "The daily check hasn't run in 4 days.")
    }
}
