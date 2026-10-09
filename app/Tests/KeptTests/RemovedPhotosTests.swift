import XCTest

@testable import Kept

final class RemovedPhotosTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default
    private let calendar = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appending(path: "KeptRemovedPhotosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @discardableResult
    private func makeFile(_ relative: String) throws -> URL {
        let url = root.appending(path: relative)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: url)
        return url
    }

    private func exists(_ relative: String) -> Bool {
        fileManager.fileExists(atPath: root.appending(path: relative).path)
    }

    // MARK: - Holding

    /// The original path is kept under the day's folder, so a restore is a
    /// drag back to where it was.
    func testHoldKeepsTheOriginalPathUnderTodaysFolder() throws {
        let file = try makeFile("2024/03/01/IMG_1.jpg")
        try RemovedPhotos.hold(file, backupRoot: root, now: date(2026, 10, 6))
        XCTAssertFalse(exists("2024/03/01/IMG_1.jpg"))
        XCTAssertTrue(exists("Removed from Photos/2026-10-06/2024/03/01/IMG_1.jpg"))
    }

    func testTheSamePathRemovedTwiceInADayKeepsBoth() throws {
        let day = date(2026, 10, 6)
        try RemovedPhotos.hold(try makeFile("2024/IMG_1.jpg"), backupRoot: root, now: day)
        try RemovedPhotos.hold(try makeFile("2024/IMG_1.jpg"), backupRoot: root, now: day)
        XCTAssertTrue(exists("Removed from Photos/2026-10-06/2024/IMG_1.jpg"))
        XCTAssertTrue(exists("Removed from Photos/2026-10-06/2024/IMG_1 2.jpg"))
    }

    /// The path arrives on a command line; a move must never carry a file
    /// somewhere outside the backup.
    func testHoldRefusesPathsOutsideTheBackup() throws {
        let outside = fileManager.temporaryDirectory.appending(path: "elsewhere-\(UUID()).jpg")
        XCTAssertThrowsError(try RemovedPhotos.hold(outside, backupRoot: root))
        let sneaky = root.appending(path: "2024/../../escape.jpg")
        XCTAssertThrowsError(try RemovedPhotos.hold(sneaky, backupRoot: root))
    }

    /// osxphotos walks the backup while files are moved into the holding
    /// folder, so it can hand one back. That must not fail the backup, or
    /// move the file again.
    func testAFileAlreadyHeldIsLeftWhereItIs() throws {
        let held = try makeFile("Removed from Photos/2026-10-06/IMG_1.jpg")
        XCTAssertNil(try RemovedPhotos.hold(held, backupRoot: root, now: date(2026, 10, 7)))
        XCTAssertTrue(exists("Removed from Photos/2026-10-06/IMG_1.jpg"))
    }

    func testTheOriginalPathIsReadBackFromTheLogLine() {
        XCTAssertEqual(
            RemovedPhotos.originalPath(
                fromLogLine: "Moved to Removed from Photos/2026-10-06/2024/03/IMG 1.jpg"),
            "2024/03/IMG 1.jpg")
        XCTAssertNil(RemovedPhotos.originalPath(fromLogLine: "Exporting IMG_1.jpg"))
    }

    /// osxphotos' cleanup used to remove the folders it emptied. It no longer
    /// runs, so Kept does, for the folders files were moved out of and no
    /// others.
    func testFoldersLeftEmptyAreRemovedAndNothingElse() throws {
        try makeFile("2024/03/01/IMG_1.jpg")
        try makeFile("2024/03/02/IMG_2.jpg")
        try fileManager.createDirectory(
            at: root.appending(path: "2023/empty"), withIntermediateDirectories: true)
        try RemovedPhotos.hold(
            root.appending(path: "2024/03/01/IMG_1.jpg"), backupRoot: root, now: date(2026, 10, 6))

        let removed = RemovedPhotos.removeEmptyFolders(
            backupRoot: root, movedFrom: ["2024/03/01/IMG_1.jpg"])
        XCTAssertEqual(removed, ["2024/03/01"])
        XCTAssertTrue(exists("2024/03/02/IMG_2.jpg"))
        XCTAssertTrue(exists("2023/empty"), "not a folder anything was moved out of")
        XCTAssertTrue(exists("Removed from Photos/2026-10-06/2024/03/01/IMG_1.jpg"))
    }

    func testHoldingAFileThatIsAlreadyGoneIsNotAnError() throws {
        XCTAssertNil(try RemovedPhotos.hold(root.appending(path: "gone.jpg"), backupRoot: root))
    }

    /// The engine counts the helper's log lines by this prefix.
    func testTheLogLineMatchesWhatTheEngineCounts() {
        XCTAssertTrue("Moved to Removed from Photos/2026-10-06/2024/IMG_1.jpg"
            .hasPrefix(RemovedPhotos.logPrefix))
    }

    // MARK: - Keep rules

    func testKeepRulesAreWrittenOnceAndOtherLinesSurvive() throws {
        let file = root.appending(path: ".osxphotos_keep")
        try "my-notes/\n".write(to: file, atomically: true, encoding: .utf8)

        try RemovedPhotos.writeKeepRules(backupRoot: root)
        try RemovedPhotos.writeKeepRules(backupRoot: root)

        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(lines.first, "my-notes/")
        for rule in RemovedPhotos.keepRules {
            XCTAssertEqual(lines.filter { $0 == rule }.count, 1, rule)
        }
        XCTAssertTrue(lines.contains("/Removed from Photos"))
    }

    // MARK: - Expiry

    /// 90 days from 2026-10-06 is 2027-01-04: kept through the day before,
    /// deleted on the day itself.
    func testFoldersExpireOnTheDayTheirRetentionEnds() throws {
        try makeFile("Removed from Photos/2026-10-06/2024/IMG_1.jpg")

        var result = RemovedPhotos.expire(
            backupRoot: root, retentionDays: 90, now: date(2027, 1, 3), calendar: calendar)
        XCTAssertEqual(result.expired, [])
        XCTAssertTrue(exists("Removed from Photos/2026-10-06/2024/IMG_1.jpg"))

        result = RemovedPhotos.expire(
            backupRoot: root, retentionDays: 90, now: date(2027, 1, 4), calendar: calendar)
        XCTAssertEqual(result.expired, [.init(name: "2026-10-06", fileCount: 1)])
        // Nothing left in it, so the holding folder goes too.
        XCTAssertFalse(exists("Removed from Photos"))
    }

    /// Nothing is kept forever: anything in the holding folder that isn't a
    /// dated folder Kept made is cleared on the next backup.
    func testAnythingElseInTheHoldingFolderIsCleared() throws {
        try makeFile("Removed from Photos/2026-10-05/IMG_1.jpg")
        try makeFile("Removed from Photos/my notes.txt")
        try makeFile("Removed from Photos/2026-13-45/IMG_2.jpg")

        let result = RemovedPhotos.expire(
            backupRoot: root, retentionDays: 30, now: date(2026, 10, 6), calendar: calendar)
        XCTAssertEqual(Set(result.expired.map(\.name)), ["my notes.txt", "2026-13-45"])
        XCTAssertTrue(exists("Removed from Photos/2026-10-05/IMG_1.jpg"))
    }

    func testShorterRetentionDeletesMoreAtTheNextBackup() throws {
        try makeFile("Removed from Photos/2026-08-01/IMG_1.jpg")
        let now = date(2026, 10, 6)
        XCTAssertEqual(RemovedPhotos.expire(
            backupRoot: root, retentionDays: 90, now: now, calendar: calendar).expired, [])
        XCTAssertEqual(RemovedPhotos.expire(
            backupRoot: root, retentionDays: 30, now: now, calendar: calendar).expired.count, 1)
    }

    func testNoHoldingFolderIsNothingToDo() {
        let result = RemovedPhotos.expire(backupRoot: root, retentionDays: 90)
        XCTAssertEqual(result.expired, [])
        XCTAssertEqual(result.errors, [])
    }

    // MARK: - Setting

    /// A hand-edited preference can't turn retention off or make it forever.
    func testRetentionIsAlwaysOneOfTheChoices() {
        let defaults = SecurityTests.scratchDefaults(named: "KeptRemovedPhotosTests", for: self)
        XCTAssertEqual(RemovedPhotos.retentionDays(defaults), 90)
        defaults.set(365, forKey: Preferences.removedRetentionDays)
        XCTAssertEqual(RemovedPhotos.retentionDays(defaults), 365)
        for invalid in [0, -1, 100_000] {
            defaults.set(invalid, forKey: Preferences.removedRetentionDays)
            XCTAssertEqual(RemovedPhotos.retentionDays(defaults), 90, "\(invalid)")
        }
    }
}
