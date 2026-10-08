import XCTest

@testable import Kept

final class FailureCopyTests: XCTestCase {
    private let networkDestination = Destination(
        path: "/Volumes/PhotoBackup/PhotoArchive",
        isNetwork: true,
        smbURL: "smb://user@nas.local/PhotoArchive",
        mountPoint: "/Volumes/PhotoBackup")

    private let localDestination = Destination(
        path: "/Users/me/Pictures/Mirror", isNetwork: false)

    func testUnreachableVolumeNamesTheHostAndPromisesARetry() {
        let copy = FailureCopy.message(
            kind: .volumeUnreachable,
            rawMessage: "Could not mount smb://user@nas.local/PhotoArchive after 60s",
            destination: networkDestination,
            failedAt: nil)
        XCTAssertTrue(copy.text.contains("**nas.local**"), copy.text)
        XCTAssertTrue(copy.text.contains("try again"), copy.text)
        // The raw message belongs in the log, not the panel.
        XCTAssertFalse(copy.text.contains("60s"), copy.text)
    }

    func testLocalDestinationFallsBackToTheFolderName() {
        let copy = FailureCopy.message(
            kind: .diskFull, rawMessage: nil, destination: localDestination, failedAt: nil)
        XCTAssertTrue(copy.text.contains("**Mirror**"), copy.text)
    }

    /// The engine's message names a file path; the user needs the switch.
    func testMissingLibraryAccessNamesTheFix() {
        let copy = FailureCopy.message(
            kind: .libraryAccess,
            rawMessage: "Can't read /Users/me/Pictures/…/Photos.sqlite: Full Disk Access is off",
            destination: networkDestination, failedAt: nil)
        XCTAssertTrue(copy.plainText.contains("Full Disk Access"), copy.text)
        XCTAssertFalse(copy.text.contains("Photos.sqlite"), copy.text)
    }

    func testUnmappedFailureKeepsTheEngineMessage() {
        let raw = "Could not create run log: permission denied"
        let copy = FailureCopy.message(
            kind: .setupFailed, rawMessage: raw, destination: networkDestination, failedAt: nil)
        XCTAssertEqual(copy, .verbatim(raw))
    }

    func testMissingKindAndMessageStillSaysSomethingUseful() {
        let copy = FailureCopy.message(
            kind: nil, rawMessage: nil, destination: nil, failedAt: nil)
        XCTAssertFalse(copy.text.isEmpty)
        XCTAssertTrue(copy.text.contains("Open the log"), copy.text)
    }

    func testExportFailureNamesTheDestination() {
        let copy = FailureCopy.message(
            kind: .exportFailed, rawMessage: "exit 1", destination: networkDestination,
            failedAt: nil)
        XCTAssertTrue(copy.text.contains("**nas.local**"), copy.text)
    }

    func testLastGoodCopyAgesInHoursThenDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var record = RunRecord(trigger: .scheduled, start: now.addingTimeInterval(-30 * 3600))
        record.outcome = .success
        XCTAssertEqual(
            FailureCopy.lastGoodCopy(record, now: now),
            "Last good backup: 30 hours ago")

        record.start = now.addingTimeInterval(-72 * 3600)
        XCTAssertEqual(
            FailureCopy.lastGoodCopy(record, now: now),
            "Last good backup: 3 days ago")
    }

    /// Notifications show plain text, so the bold markers must go — but a
    /// verbatim engine message must come through exactly as it was.
    func testPlainTextDropsBoldMarkersOnlyFromAuthoredCopy() {
        let authored = FailureCopy.message(
            kind: .volumeUnreachable, rawMessage: nil,
            destination: networkDestination, failedAt: nil)
        XCTAssertTrue(authored.plainText.contains("Couldn't reach nas.local"), authored.plainText)
        XCTAssertFalse(authored.plainText.contains("**"), authored.plainText)

        let raw = "Kept couldn't start the backup: **not markdown**"
        XCTAssertEqual(FailureCopy.Message.verbatim(raw).plainText, raw)
    }

    func testLastGoodCopyWithNoSuccessfulRun() {
        XCTAssertEqual(FailureCopy.lastGoodCopy(nil), "No backup has finished yet")
    }
}
