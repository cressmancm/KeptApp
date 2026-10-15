import XCTest

@testable import Kept

/// Production review W3, 2026-10-13: osxphotos exits 0 whatever it left
/// behind, and its last summary line is the only thing that says how many
/// files failed. When that line never came, or came garbled, Kept took the
/// count as zero and showed the backup as complete.
final class MissingSummaryTests: XCTestCase {
    private func progress(_ lines: [String]) -> ExportProgress {
        var parser = ProgressParser()
        for line in lines { _ = parser.consume(line: line) }
        return parser.progress
    }

    private func finished(_ progress: ExportProgress) -> RunRecord {
        var record = RunRecord(trigger: .scheduled, start: Date(timeIntervalSince1970: 1_800_000_000))
        record.finish(with: progress)
        return record
    }

    func testNoSummaryIsNotComplete() {
        let record = finished(progress([
            "Exporting 3 photos to /Volumes/PhotoBackup...",
            "Exporting IMG_1.jpg (A-1.jpg) (1/3)",
        ]))
        XCTAssertTrue(record.isPartial)
        XCTAssertEqual(RunFormatting.notCopied(record), "Not confirmed")
        XCTAssertEqual(RunFormatting.partialTitle(record), "Some photos may not be backed up")
        XCTAssertEqual(RunFormatting.partialDetails(record), [RunFormatting.unconfirmedSentence])
    }

    func testAGarbledSummaryIsNotComplete() {
        let record = finished(progress(["Processed: 3 photos, exported: 3, err"]))
        XCTAssertEqual(record.exported, 3)
        XCTAssertTrue(record.isPartial)
    }

    func testAFullSummaryStillDecides() {
        let clean = finished(progress([
            "Processed: 3 photos, exported: 3, updated: 0, skipped: 0, missing: 0, error: 0",
        ]))
        XCTAssertFalse(clean.isPartial)
        XCTAssertNil(clean.unconfirmed)
        let failed = finished(progress([
            "Processed: 3 photos, exported: 1, updated: 0, skipped: 0, missing: 0, error: 2",
        ]))
        XCTAssertEqual(RunFormatting.notCopied(failed), "2 not copied")
        XCTAssertEqual(RunFormatting.partialTitle(failed), "Some photos aren't backed up")
    }

    /// Records from before Kept kept it decode as they always did.
    func testOlderRecordsAreReadAsBefore() throws {
        let json = #"{"id":"6F9A1C2E-0000-4000-8000-000000000001","trigger":"scheduled","start":0,"outcome":"success","errors":0}"#
        let decoder = JSONDecoder()
        let record = try decoder.decode(RunRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.unconfirmed)
        XCTAssertFalse(record.isPartial)
    }
}
