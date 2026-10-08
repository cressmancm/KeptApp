import XCTest

@testable import Kept

final class HousekeepingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "KeptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFile(_ name: String, modified: Date) throws -> URL {
        let url = tempDir.appending(path: name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testPruneDeletesOnlyOldRunLogs() throws {
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86400)
        let oldRunLog = try makeFile("2026-06-01_020000.log", modified: old)
        let recentRunLog = try makeFile("2026-07-20_020000.log", modified: now)
        // launchd.log doesn't match the 2*.log run-log naming and must survive.
        let launchdLog = try makeFile("launchd.log", modified: old)

        Housekeeping.pruneOldLogs(in: tempDir, olderThanDays: 30, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRunLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentRunLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: launchdLog.path))
    }

    func testReportRotatesAcrossYearBoundary() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let lastYear = cal.date(from: DateComponents(year: 2025, month: 12, day: 31))!
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let report = try makeFile("report.csv", modified: lastYear)

        let rotated = Housekeeping.rotateReportIfNeeded(reportURL: report, now: now, calendar: cal)

        XCTAssertEqual(rotated?.lastPathComponent, "report-2025.csv")
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated!.path))
    }

    func testReportNotRotatedWithinSameYear() throws {
        let report = try makeFile("report.csv", modified: .now)
        XCTAssertNil(Housekeeping.rotateReportIfNeeded(reportURL: report, now: .now))
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
    }

    /// One row per line, padded past the byte gate so the row count actually
    /// runs rather than being short-circuited by the size check.
    private func makeReport(rows: Int) throws -> URL {
        let url = tempDir.appending(path: "report.csv")
        let row = String(repeating: "x", count: 40) + "\n"
        try Data(String(repeating: row, count: rows).utf8).write(to: url)
        return url
    }

    /// A small limit keeps the fixture tiny; the production value only changes
    /// when rotation fires, not how.
    private let testRowLimit = 500

    func testReportRotatesWhenPastRowLimit() throws {
        let report = try makeReport(rows: testRowLimit + 1)

        let rotated = Housekeeping.rotateReportIfNeeded(
            reportURL: report, now: .now, rowLimit: testRowLimit)

        XCTAssertNotNil(rotated, "a report past the row limit must be rotated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated!.path))
    }

    func testReportKeptWhenUnderRowLimit() throws {
        let report = try makeReport(rows: testRowLimit - 1)
        XCTAssertNil(Housekeeping.rotateReportIfNeeded(
            reportURL: report, now: .now, rowLimit: testRowLimit))
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
    }

    /// Size rotation can fire more than once in a year, and the second one must
    /// not overwrite the first — that would destroy the history being kept.
    func testRepeatedRotationsWithinOneYearDoNotOverwrite() throws {
        let year = Calendar.current.component(.year, from: .now)
        let first = try makeReport(rows: testRowLimit + 1)
        let firstRotated = Housekeeping.rotateReportIfNeeded(
            reportURL: first, now: .now, rowLimit: testRowLimit)
        let second = try makeReport(rows: testRowLimit + 1)
        let secondRotated = Housekeeping.rotateReportIfNeeded(
            reportURL: second, now: .now, rowLimit: testRowLimit)

        XCTAssertEqual(firstRotated?.lastPathComponent, "report-\(year).csv")
        XCTAssertEqual(secondRotated?.lastPathComponent, "report-\(year)-2.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstRotated!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondRotated!.path))
    }

    /// The real limit must sit under what a spreadsheet will open, with room
    /// for one more run's worth of rows before the next rotation fires.
    func testProductionRowLimitFitsInASpreadsheet() {
        XCTAssertLessThan(Housekeeping.reportRowLimit, 1_048_576)
    }
}
