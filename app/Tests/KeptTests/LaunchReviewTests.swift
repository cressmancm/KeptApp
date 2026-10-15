import CryptoKit
import XCTest

@testable import Kept

/// The Astra launch review's open findings: backups that finish without
/// copying everything (F1), history that belongs to one backup folder (F4),
/// saves that used to fail silently (F8), and a planted named pipe that hung
/// the backup (F3).
final class LaunchReviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "KeptLaunchReviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func success(errors: Int? = nil, exported: Int? = 8) -> RunRecord {
        var record = RunRecord(trigger: .scheduled, start: start)
        record.end = start.addingTimeInterval(33 * 60)
        record.outcome = .success
        record.exported = exported
        record.errors = errors
        return record
    }

    // MARK: - F1: incomplete backups

    func testOnlyACleanSuccessIsComplete() {
        XCTAssertFalse(success().isPartial)
        XCTAssertFalse(success(errors: 0).isPartial)
        XCTAssertTrue(success(errors: 2).isPartial)

        var failed = success(errors: 5)
        failed.outcome = .failed
        XCTAssertFalse(failed.isPartial, "a failure is a failure, not a partial backup")
    }

    /// osxphotos counts shared items whose originals Photos never keeps on
    /// the Mac as missing, every night. Kept doesn't record or show them: a
    /// record from before carrying the count reads as a complete backup.
    func testMissingOriginalsDontMakeABackupIncomplete() throws {
        let url = root.appending(path: "runs.json")
        try RunHistory.upsert(success(errors: 0), to: url)
        let json = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"errors\" : 0", with: "\"errors\" : 0, \"missing\" : 6221")
        XCTAssertTrue(json.contains("\"missing\" : 6221"))
        try Data(json.utf8).write(to: url)
        let loaded = try XCTUnwrap(RunHistory.load(from: url).first)
        XCTAssertFalse(loaded.isPartial)
        XCTAssertNil(RunFormatting.notCopied(loaded))
    }

    /// Still a success for the schedule: the next backup tries the failed
    /// files again anyway.
    func testAPartialBackupStillServicesItsSlot() {
        XCTAssertTrue(Scheduler.slotWasServiced(
            [success(errors: 3)], since: start.addingTimeInterval(-60)))
    }

    func testTheRowSaysHowManyWerentCopied() {
        XCTAssertEqual(RunFormatting.rowDetail(success(errors: 3)), "8 new · 3 not copied · 33 min")
        XCTAssertEqual(RunFormatting.rowDetail(success()), "8 new · 33 min")
        XCTAssertTrue(
            RunFormatting.lastRunSummary(success(errors: 3)).hasSuffix("· 8 new · 3 not copied"))
        XCTAssertTrue(RunFormatting.lastRunSummary(success(exported: nil)).hasSuffix("· Done"))
    }

    func testThePanelSaysWhatWasntCopied() {
        XCTAssertEqual(
            RunFormatting.partialDetails(success(errors: 3)),
            ["3 items couldn't be copied. The next backup tries them again."])
        XCTAssertEqual(
            RunFormatting.errorsSentence(1), "1 item couldn't be copied. The next backup tries it again.")
        XCTAssertEqual(RunFormatting.partialDetails(success()), [])
    }

    func testAPartialRowIsOrangeNotGreen() {
        XCTAssertEqual(RunOutcomeStyle.color(for: success(errors: 1)), .orange)
        XCTAssertEqual(RunOutcomeStyle.color(for: success()), .green)
    }

    func testTheSuccessNotificationCountsWhatWasntCopied() {
        var record = success(errors: 3)
        record.deleted = 2
        XCTAssertEqual(BackupEngine.successBody(record), "8 new · 2 removed · 3 not copied")
    }

    func testTheErrorCountSurvivesTheHistory() throws {
        let url = root.appending(path: "runs.json")
        try RunHistory.upsert(success(errors: 1), to: url)
        let loaded = try XCTUnwrap(RunHistory.load(from: url).first)
        XCTAssertEqual(loaded.errors, 1)
        XCTAssertTrue(loaded.isPartial)
    }

    // MARK: - F4: history belongs to a folder

    private func destination(_ path: String, id: UUID? = UUID(), chosenAt: Date? = nil) -> Destination {
        var destination = Destination(path: path, isNetwork: false)
        destination.id = id
        destination.chosenAt = chosenAt
        return destination
    }

    func testANewFolderStartsWithNoBackups() {
        let old = destination("/Volumes/Old")
        let new = destination("/Volumes/New")
        var record = success()
        record.destinationID = old.id

        XCTAssertEqual([record].runs(for: old).count, 1)
        XCTAssertTrue([record].runs(for: new).isEmpty, "the old folder's backup isn't the new one's")
        XCTAssertFalse(Scheduler.slotWasServiced(
            [record].runs(for: new), since: start.addingTimeInterval(-60)))
    }

    /// Records from before Kept kept the folder belong to the folder chosen
    /// before then, which has no id either.
    func testOlderRecordsBelongToTheFolderChosenBeforeThem() {
        let legacy = destination("/Volumes/PhotoBackup", id: nil)
        XCTAssertEqual([success()].runs(for: legacy).count, 1)
        XCTAssertTrue([success()].runs(for: destination("/Volumes/PhotoBackup")).isEmpty)
        XCTAssertEqual([success()].runs(for: nil).count, 1, "no folder: every record")
    }

    func testChoosingTheSameFolderAgainKeepsItsBackups() {
        let current = destination("/Volumes/PhotoBackup", chosenAt: start)
        let again = Destination.adopting(
            Destination(path: "/Volumes/PhotoBackup", isNetwork: false), replacing: current)
        XCTAssertEqual(again.id, current.id)
        XCTAssertEqual(again.chosenAt, start)

        let now = start.addingTimeInterval(86_400)
        let other = Destination.adopting(
            Destination(path: "/Volumes/Other", isNetwork: false), replacing: current, now: now)
        XCTAssertNotNil(other.id)
        XCTAssertNotEqual(other.id, current.id)
        XCTAssertEqual(other.chosenAt, now)

        // Kept 1.2's folder had no id, and choosing it again keeps it that way,
        // so its existing backups still count.
        let legacy = destination("/Volumes/PhotoBackup", id: nil)
        XCTAssertNil(Destination.adopting(legacy, replacing: legacy).id)
    }

    // MARK: - W5: the same path on another disk is another folder

    /// Production review W5, 2026-10-13: choosing a folder at the same path
    /// kept its backups even on another disk or share, so a new, empty
    /// folder looked backed up.
    func testTheSamePathOnAnotherDiskStartsWithNoBackups() {
        func local(_ uuid: String?, folder: UInt64? = 7) -> Destination {
            Destination(
                path: "/Volumes/Backup", isNetwork: false, volumeUUID: uuid, id: UUID(),
                chosenAt: start, folderID: folder)
        }
        let current = local("DISK-A")
        XCTAssertEqual(Destination.adopting(local("DISK-A"), replacing: current).id, current.id)
        XCTAssertNotEqual(Destination.adopting(local("DISK-B"), replacing: current).id, current.id)
        // Same disk, but another folder made at that path since.
        XCTAssertNotEqual(
            Destination.adopting(local("DISK-A", folder: 8), replacing: current).id, current.id)
        // Chosen before Kept recorded the disk: nothing shows it's the same one.
        XCTAssertNotEqual(Destination.adopting(local("DISK-A"), replacing: local(nil)).id, current.id)
        // A disk without a UUID can only be told by its path.
        let plain = local(nil, folder: nil)
        XCTAssertEqual(Destination.adopting(local(nil, folder: nil), replacing: plain).id, plain.id)
    }

    func testTheSamePathOnAnotherShareStartsWithNoBackups() {
        func share(_ url: String?) -> Destination {
            Destination(
                path: "/Volumes/PhotoBackup", isNetwork: true, smbURL: url,
                mountPoint: "/Volumes/PhotoBackup", id: UUID(), chosenAt: start)
        }
        let current = share("smb://me@nas._smb._tcp.local/PhotoBackup")
        // However the server was named when it was mounted.
        XCTAssertEqual(
            Destination.adopting(share("smb://nas.local/PhotoBackup"), replacing: current).id,
            current.id)
        XCTAssertNotEqual(
            Destination.adopting(share("smb://other.local/PhotoBackup"), replacing: current).id,
            current.id)
        // A local disk mounted where the share was.
        let disk = Destination(path: "/Volumes/PhotoBackup", isNetwork: false, volumeUUID: "X")
        XCTAssertNotEqual(Destination.adopting(disk, replacing: current).id, current.id)
    }

    func testTrimmingKeepsEachFoldersLatestSuccess() throws {
        let url = root.appending(path: "runs.json")
        let old = UUID()
        var oldSuccess = success()
        oldSuccess.destinationID = old
        try RunHistory.upsert(oldSuccess, to: url)
        var newSuccess = success()
        newSuccess.start = start + 60
        try RunHistory.upsert(newSuccess, to: url)
        for index in 1...(Config.historyLimit + 5) {
            var failed = RunRecord(trigger: .scheduled, start: start + Double(index) * 3600)
            failed.outcome = .failed
            try RunHistory.upsert(failed, to: url)
        }
        let ids = RunHistory.load(from: url).map(\.id)
        XCTAssertEqual(ids.count, Config.historyLimit)
        XCTAssertTrue(ids.contains(oldSuccess.id))
        XCTAssertTrue(ids.contains(newSuccess.id))
    }

    /// A folder chosen and then never backed up to used to stay quiet for
    /// good: the daily check only spoke once there was a failure to report.
    func testAFolderNeverBackedUpIsReportedOnceItHasWaited() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = start.addingTimeInterval(4 * 86_400)
        XCTAssertEqual(
            StalenessCheck.staleMessage(
                history: [], thresholdDays: 3, waitingSince: start, now: now, calendar: calendar),
            "No backup has finished yet.")
        XCTAssertNil(StalenessCheck.staleMessage(
            history: [], thresholdDays: 5, waitingSince: start, now: now, calendar: calendar))
        XCTAssertNil(StalenessCheck.staleMessage(
            history: [], thresholdDays: 3, waitingSince: nil, now: now, calendar: calendar))
    }

    func testTheDailyCheckReadsTheFolderWithoutItsSeal() throws {
        let defaults = SecurityTests.scratchDefaults(named: "KeptLaunchReviewPeek", for: self)
        XCTAssertNil(DestinationStore.peek(defaults: defaults))
        let saved = destination("/Volumes/New", chosenAt: start)
        XCTAssertTrue(DestinationStore.save(saved, defaults: defaults, sealingKey: SymmetricKey(size: .bits256)))
        XCTAssertEqual(DestinationStore.peek(defaults: defaults), saved)
    }

    // MARK: - F8: saves that fail say so

    /// Without a key nothing is saved, so the folder chosen before stays.
    /// It used to be overwritten with an unsealed one, which looked chosen
    /// until the next launch found no folder at all.
    func testAFolderThatCantBeSealedIsNotSaved() {
        let defaults = SecurityTests.scratchDefaults(named: "KeptLaunchReviewSave", for: self)
        let key = SymmetricKey(size: .bits256)
        let previous = destination("/Volumes/Old")
        XCTAssertTrue(DestinationStore.save(previous, defaults: defaults, sealingKey: key))

        XCTAssertFalse(DestinationStore.save(destination("/Volumes/New"), defaults: defaults, sealingKey: nil))
        XCTAssertEqual(DestinationStore.load(defaults: defaults, sealingKey: key), previous)
    }

    func testAHistoryThatCantBeWrittenThrows() throws {
        let blocked = root.appending(path: "not-a-folder")
        try Data("x".utf8).write(to: blocked)
        XCTAssertThrowsError(try RunHistory.upsert(success(), to: blocked.appending(path: "runs.json")))
    }

    // MARK: - F3: a planted named pipe

    /// Opening a named pipe for reading waits for a writer that never comes.
    /// One at `.osxphotos_keep` hung the backup; now it's replaced like a
    /// planted link.
    func testANamedPipeInPlaceOfTheKeepFileIsReplacedNotWaitedOn() throws {
        let keep = root.appending(path: ".osxphotos_keep")
        XCTAssertEqual(mkfifo(keep.path, 0o644), 0)

        let done = expectation(description: "keep rules written")
        let failure = LockedBox<Error?>(nil)
        let backupRoot = root!
        Thread {
            do { try RemovedPhotos.writeKeepRules(backupRoot: backupRoot) } catch { failure.value = error }
            done.fulfill()
        }.start()
        wait(for: [done], timeout: 5)
        XCTAssertNil(failure.value)

        var info = stat()
        XCTAssertEqual(lstat(keep.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
        let text = try String(contentsOf: keep, encoding: .utf8)
        for rule in RemovedPhotos.keepRules { XCTAssertTrue(text.contains(rule), rule) }
    }

    func testReadingAFolderAsAFileIsStillRefused() throws {
        try FileManager.default.createDirectory(
            at: root.appending(path: "folder"), withIntermediateDirectories: false)
        let directory = try NoFollow.openRoot(root.path)
        defer { close(directory) }
        XCTAssertThrowsError(try NoFollow.readRegularFile("folder", in: directory))
        XCTAssertNil(try NoFollow.readRegularFile("absent", in: directory))
    }
}

/// A value a background thread sets and the test reads after waiting for it.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
