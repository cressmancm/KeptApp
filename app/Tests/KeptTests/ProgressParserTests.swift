import XCTest

@testable import Kept

final class ProgressParserTests: XCTestCase {
    // Lines captured verbatim from logs/2026-07-24_020004.log
    func testFullRunSequence() {
        var parser = ProgressParser()

        XCTAssertTrue(parser.consume(
            line: "Processing database /Users/me/Pictures/Photos Library.photoslibrary/database/Photos.sqlite"))
        XCTAssertEqual(parser.progress.phase, .scanning)

        XCTAssertFalse(parser.consume(line: "Processing keywords."))

        XCTAssertTrue(parser.consume(line: "Exporting 46920 photos to /Volumes/PhotoBackup..."))
        XCTAssertEqual(parser.progress.phase, .exporting)
        XCTAssertEqual(parser.progress.total, 46920)

        XCTAssertTrue(parser.consume(
            line: "Exporting Chad & Sax.jpg (B95F184C-78B8-4DFC-B033-9DC219BE97EE.jpeg) (1/46920)"))
        XCTAssertEqual(parser.progress.current, 1)

        XCTAssertFalse(parser.consume(
            line: "Writing XMP sidecar /Volumes/PhotoBackup/2001/01/29/Chad & Sax.jpg.xmp"))

        XCTAssertTrue(parser.consume(
            line: "Exporting IMG_5355.HEIC (5AB8590A-E05C-4661-8E50-D98B0FADF06D.heic) (46917/46920)"))
        XCTAssertEqual(parser.progress.current, 46917)

        // "Exporting edited version of ..." has no (n/total) — must not disturb counts.
        XCTAssertFalse(parser.consume(
            line: "Exporting edited version of IMG_5355.HEIC (5AB8590A-E05C-4661-8E50-D98B0FADF06D.heic)"))
        XCTAssertEqual(parser.progress.current, 46917)

        XCTAssertTrue(parser.consume(
            line: "Processed: 46920 photos, exported: 31, updated: 0, skipped: 63296, updated EXIF data: 0, missing: 5643, error: 0"))
        XCTAssertEqual(parser.progress.exported, 31)
        XCTAssertEqual(parser.progress.updated, 0)
        XCTAssertEqual(parser.progress.skipped, 63296)
        XCTAssertEqual(parser.progress.missing, 5643)
        XCTAssertEqual(parser.progress.errors, 0)

        // What osxphotos prints now that Kept runs it with --cleanup-command
        // and without --cleanup: one line per file Kept moved aside.
        XCTAssertTrue(parser.consume(line: "Running cleanup command on /Volumes/PhotoBackup"))
        XCTAssertEqual(parser.progress.phase, .cleaning)
        XCTAssertFalse(parser.consume(
            line: #"Running command: ""$KEPT_EXECUTABLE" --hold-removed /Volumes/PhotoBackup/2026/07/22/IMG_5333.HEIC""#))
        XCTAssertTrue(parser.consume(
            line: "Moved to Removed from Photos/2026-10-06/2026/07/22/IMG_5333.HEIC"))
        XCTAssertTrue(parser.consume(
            line: "Moved to Removed from Photos/2026-10-06/2026/07/22/IMG_5333.HEIC.xmp"))
        XCTAssertEqual(parser.progress.deleted, 2)

        XCTAssertTrue(parser.consume(
            line: "Writing export database changes back to /Users/me/Library/Application Support/Kept/export.db"))
        XCTAssertEqual(parser.progress.phase, .finishing)
    }

    // Captured from a real `--limit 5` run: no updated/skipped fields.
    func testLimitRunSummary() {
        var parser = ProgressParser()
        XCTAssertTrue(parser.consume(
            line: "Processed: 46920 photos, exported: 5, missing: 0, error: 0, limit: 5/5 exported"))
        XCTAssertEqual(parser.progress.exported, 5)
        XCTAssertEqual(parser.progress.missing, 0)
        XCTAssertEqual(parser.progress.errors, 0)
        XCTAssertNil(parser.progress.updated)
        XCTAssertNil(parser.progress.skipped)
    }

    func testCurrentItemNameSurvivesSpacesInFilenames() {
        var parser = ProgressParser()
        _ = parser.consume(line: "Exporting 46920 photos to /Volumes/PhotoBackup...")

        _ = parser.consume(
            line: "Exporting Chad & Sax.jpg (B95F184C-78B8-4DFC-B033-9DC219BE97EE.jpeg) (1/46920)")
        XCTAssertEqual(parser.progress.currentItemName, "Chad & Sax.jpg")

        _ = parser.consume(
            line: "Exporting IMG_5355.HEIC (5AB8590A-E05C-4661-8E50-D98B0FADF06D.heic) (46917/46920)")
        XCTAssertEqual(parser.progress.currentItemName, "IMG_5355.HEIC")
    }

    func testCurrentItemNameIgnoresLinesWithoutACount() {
        var parser = ProgressParser()
        _ = parser.consume(
            line: "Exporting IMG_5355.HEIC (5AB8590A-E05C-4661-8E50-D98B0FADF06D.heic) (1/2)")
        // "Exporting edited version of …" carries no (n/total) and must not
        // overwrite the name with "edited version of IMG_5355.HEIC".
        _ = parser.consume(
            line: "Exporting edited version of IMG_5355.HEIC (5AB8590A-E05C-4661-8E50-D98B0FADF06D.heic)")
        XCTAssertEqual(parser.progress.currentItemName, "IMG_5355.HEIC")
    }

    /// Pins why the running panel gates its detail row on the phase rather
    /// than on `fractionComplete`: once the export finishes, current and total
    /// stay equal, so the fraction remains 1.0 for the rest of the run. A view
    /// keyed off "do we have a fraction" keeps showing the last filename at
    /// 100% while osxphotos is actually cleaning up.
    func testFractionStaysCompleteAfterExportingEnds() {
        var parser = ProgressParser()
        _ = parser.consume(line: "Exporting 2 photos to /Volumes/PhotoBackup...")
        _ = parser.consume(line: "Exporting IMG_5423.HEIC (5AB8590A-E05C-4661-8E50-D98B0FADF06D.heic) (2/2)")
        XCTAssertEqual(parser.progress.fractionComplete, 1.0)

        _ = parser.consume(line: "Cleaning up /Volumes/PhotoBackup")
        XCTAssertEqual(parser.progress.phase, .cleaning)
        XCTAssertEqual(parser.progress.fractionComplete, 1.0, "fraction is stale, not nil")
        XCTAssertEqual(parser.progress.currentItemName, "IMG_5423.HEIC", "filename is stale too")
    }

    // MARK: - Timestamped progress marks

    private func exporting(current: Int, total: Int) -> ExportProgress {
        var p = ExportProgress()
        p.phase = .exporting
        p.current = current
        p.total = total
        return p
    }

    func testProgressMarkReportsPositionAndRate() {
        let mark = BackupEngine.progressMark(
            exporting(current: 12_340, total: 46_891), since: 11_270, elapsed: .seconds(300))
        XCTAssertTrue(mark.contains("12,340 of 46,891"), mark)
        XCTAssertTrue(mark.contains("26%"), mark)
        // 1,070 items in 5 minutes = 214/min
        XCTAssertTrue(mark.contains("214/min"), mark)
    }

    /// The case the marks exist for: a run crawling behind a slow NAS. The rate
    /// makes it obvious in the log, where "took six hours" alone would not.
    func testProgressMarkMakesAStallVisible() {
        let mark = BackupEngine.progressMark(
            exporting(current: 12_355, total: 46_891), since: 12_340, elapsed: .seconds(300))
        XCTAssertTrue(mark.contains("3/min"), mark)
    }

    func testProgressMarkOutsideExportingNamesThePhase() {
        var cleaning = ExportProgress()
        cleaning.phase = .cleaning
        cleaning.current = 46_891
        cleaning.total = 46_891
        XCTAssertEqual(
            BackupEngine.progressMark(cleaning, since: 0, elapsed: .seconds(300)),
            "progress: Cleaning up")
    }

    func testProgressBarLineIgnored() {
        var parser = ProgressParser()
        _ = parser.consume(line: "Exporting 46920 photos to /Volumes/PhotoBackup...")
        // The rich progress-bar line ends in a time, not (n/total).
        XCTAssertFalse(parser.consume(
            line: "Exporting 46920 photos ━━━━━━━━━━ 100% 0:00:00"))
        XCTAssertEqual(parser.progress.current, 0)
    }
}
