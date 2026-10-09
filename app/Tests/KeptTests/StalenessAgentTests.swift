import XCTest

@testable import Kept

@MainActor
final class StalenessAgentTests: XCTestCase {
    /// The plist is hand-written XML, so a typo would only show up as launchd
    /// refusing the job. And without AssociatedBundleIdentifiers, System
    /// Settings lists the job as a second, unbranded "Kept".
    func testAgentPlistParsesAndNamesTheApp() throws {
        let xml = BackupController.stalenessPlist(
            executable: "/Applications/Kept & Co.app/Contents/MacOS/Kept",
            bundleIdentifier: "com.chipcressman.Kept")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
                as? [String: Any])

        XCTAssertEqual(plist["Label"] as? String, BackupController.stalenessLabel)
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], ["com.chipcressman.Kept"])
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/Applications/Kept & Co.app/Contents/MacOS/Kept", "--staleness-check"])
    }
}
