import XCTest

@testable import Kept

/// Regressions from the 2026-10-07 re-audit.
final class ReauditTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "KeptReaudit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - .osxphotos_keep

    /// A planted link must not carry a file from this Mac onto the share.
    func testKeepRulesNeverReadThroughALink() throws {
        let backup = root.appending(path: "Backup", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let secret = root.appending(path: "id_rsa")
        try Data("-----BEGIN PRIVATE KEY-----\n".utf8).write(to: secret)
        let keep = backup.appending(path: ".osxphotos_keep")
        try FileManager.default.createSymbolicLink(at: keep, withDestinationURL: secret)

        try RemovedPhotos.writeKeepRules(backupRoot: backup)

        var info = stat()
        XCTAssertEqual(lstat(keep.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG, "the link is replaced by a real file")
        let written = try String(contentsOf: keep, encoding: .utf8)
        XCTAssertFalse(written.contains("PRIVATE KEY"))
        XCTAssertTrue(written.contains("@eaDir"))
        XCTAssertEqual(
            try String(contentsOf: secret, encoding: .utf8), "-----BEGIN PRIVATE KEY-----\n",
            "the link's target is untouched")
    }

    // MARK: - runs.json

    private func record(_ outcome: RunOutcome) -> RunRecord {
        var record = RunRecord(trigger: .scheduled, start: .now)
        record.outcome = outcome
        return record
    }

    /// One record a newer Kept wrote must not cost the rest of the history.
    func testAnUnknownRecordDoesNotEmptyTheHistory() throws {
        let url = root.appending(path: "runs.json")
        RunHistory.upsert(record(.success), to: url)
        RunHistory.upsert(record(.failed), to: url)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"failed\"", with: "\"fromTheFuture\"")
        try text.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(RunHistory.load(from: url).map(\.outcome), [.success])
        RunHistory.upsert(record(.success), to: url)
        XCTAssertEqual(RunHistory.load(from: url).count, 2)
    }

    /// A file that isn't readable at all is set aside, not overwritten.
    func testAnUnreadableHistoryIsKeptAside() throws {
        let url = root.appending(path: "runs.json")
        try Data("{ not json".utf8).write(to: url)
        RunHistory.upsert(record(.success), to: url)

        XCTAssertEqual(RunHistory.load(from: url).count, 1)
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("runs-unreadable-") }
        XCTAssertEqual(aside.count, 1)
    }

    // MARK: - Schedule

    /// A damaged stored time must not crash the date math.
    func testOutOfRangeScheduleValuesAreClamped() {
        XCTAssertEqual(Scheduler.clamped(25, 0...23), 23)
        XCTAssertEqual(Scheduler.clamped(-3, 0...59), 0)
        XCTAssertEqual(Scheduler.clamped(0, 1...7), 1)
        XCTAssertNotNil(Scheduler.nextFireDate(
            after: .now, cadence: .weekly, weekday: Scheduler.clamped(9, 1...7),
            hour: Scheduler.clamped(99, 0...23), minute: Scheduler.clamped(99, 0...59)))
    }

    // MARK: - Housekeeping

    func testOldStallSamplesArePrunedWithTheLogs() throws {
        let old = Date.now.addingTimeInterval(-40 * 86_400)
        for name in ["stall-sample-2026-08-01_020000.txt", "2026-08-01_020000.log", "notes.txt"] {
            let url = root.appending(path: name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        Housekeeping.pruneOldLogs(in: root, olderThanDays: 30)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["notes.txt"])
    }

    // MARK: - Copy

    func testOneHourIsSingular() {
        var success = record(.success)
        success.start = Date.now.addingTimeInterval(-90 * 60)
        XCTAssertEqual(FailureCopy.lastGoodCopy(success), "Last good backup: 1 hour ago")
    }

    /// A folder name is the user's text spliced into markdown: it must render
    /// as itself, and come back out of the notification as itself.
    func testFolderNamesAreEscapedInAuthoredCopy() {
        let destination = Destination(path: "/Volumes/X/[old]_*mirror*", isNetwork: false)
        let copy = FailureCopy.message(
            kind: .diskFull, rawMessage: nil, destination: destination, failedAt: nil)
        guard case .authored(let markdown) = copy else { return XCTFail("authored") }
        XCTAssertTrue(markdown.contains(#"\[old\]\_\*mirror\*"#), markdown)
        XCTAssertTrue(copy.plainText.hasPrefix("[old]_*mirror* has less than"), copy.plainText)
    }

    // MARK: - Process tree

    func testDescendantsAreFound() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "sleep 30 & sleep 30; wait"]
        try process.run()
        defer { process.terminate() }
        try await Task.sleep(for: .milliseconds(300))

        let tree = ProcessAncestry.descendants(of: process.processIdentifier)
        XCTAssertEqual(tree.count, 2, "both sleeps")
        for pid in tree { kill(pid, SIGKILL) }
    }
}
