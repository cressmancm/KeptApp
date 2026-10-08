import Foundation

struct ExportProgress: Equatable, Sendable {
    enum Phase: String, Sendable {
        case starting = "Starting"
        case scanning = "Reading Photos library"
        case exporting = "Exporting"
        case cleaning = "Cleaning up"
        case finishing = "Finishing"

        /// What the panel shows. The raw values stay as they are because the
        /// run log's progress marks print them, and the log is written for
        /// whoever is reading it later, not for the panel.
        var label: String {
            switch self {
            case .starting: "Starting"
            case .scanning: "Reading your library"
            case .exporting: "Copying"
            // Files no longer in the library move to "Removed from Photos".
            case .cleaning: "Moving deleted photos"
            case .finishing: "Finishing"
            }
        }
    }

    var phase: Phase = .starting
    var current = 0
    var total = 0
    /// Filename of the item being exported, for the running panel's detail row.
    var currentItemName: String?

    // Populated from the final summary line.
    var exported: Int?
    var updated: Int?
    var skipped: Int?
    var missing: Int?
    var errors: Int?
    var deleted: Int?

    var fractionComplete: Double? {
        guard total > 0 else { return nil }
        return Double(current) / Double(total)
    }
}

/// Incremental parser over osxphotos --verbose output. Line formats are taken
/// from a real run log:
///   Processing database /Users/…/Photos.sqlite
///   Exporting 46920 photos to /Volumes/PhotoBackup...
///   Exporting IMG_5355.HEIC (5AB8590A-….heic) (46917/46920)
///   Processed: 46920 photos, exported: 31, updated: 0, skipped: 63296, updated EXIF data: 0, missing: 5643, error: 0
///   Cleaning up /Volumes/PhotoBackup
///   Deleted: 6 files, 0 directories
///   Writing export database changes back to /Users/…/export.db
struct ProgressParser {
    private(set) var progress = ExportProgress()

    private let totalRegex = #/^Exporting (\d+) photos to /#
    private let itemRegex = #/\((\d+)\/(\d+)\)\s*$/#
    // Same line as itemRegex, split out to name the file: the filename may
    // contain spaces ("Chad & Sax.jpg"), so it is bounded by the UUID group
    // that always follows it rather than by whitespace.
    private let itemNameRegex = #/^Exporting (.+?) \([^()]*\) \(\d+\/\d+\)\s*$/#
    // The summary line's fields vary by invocation (--limit runs omit
    // updated/skipped), so each field is matched independently. ", updated:"
    // cannot false-match "updated EXIF data:" — no colon directly after
    // "updated" there.
    private let exportedRegex = #/, exported: (\d+)/#
    private let updatedRegex = #/, updated: (\d+)/#
    private let skippedRegex = #/, skipped: (\d+)/#
    private let missingRegex = #/, missing: (\d+)/#
    private let errorRegex = #/, error: (\d+)/#
    private let deletedRegex = #/^Deleted: (\d+) file/#

    /// Feeds one output line; returns true if the visible progress changed.
    mutating func consume(line: String) -> Bool {
        let before = progress

        if progress.phase == .starting, line.hasPrefix("Processing ") {
            progress.phase = .scanning
        }
        if let match = line.firstMatch(of: totalRegex) {
            progress.phase = .exporting
            progress.total = Int(match.1) ?? 0
        } else if line.hasPrefix("Exporting "), let match = line.firstMatch(of: itemRegex) {
            progress.phase = .exporting
            progress.current = Int(match.1) ?? progress.current
            progress.total = Int(match.2) ?? progress.total
            if let named = line.firstMatch(of: itemNameRegex) {
                progress.currentItemName = String(named.1)
            }
        } else if line.hasPrefix("Processed: ") {
            if let match = line.firstMatch(of: exportedRegex) { progress.exported = Int(match.1) }
            if let match = line.firstMatch(of: updatedRegex) { progress.updated = Int(match.1) }
            if let match = line.firstMatch(of: skippedRegex) { progress.skipped = Int(match.1) }
            if let match = line.firstMatch(of: missingRegex) { progress.missing = Int(match.1) }
            if let match = line.firstMatch(of: errorRegex) { progress.errors = Int(match.1) }
        } else if line.hasPrefix("Running cleanup command on ") || line.hasPrefix("Cleaning up ") {
            progress.phase = .cleaning
        } else if line.hasPrefix(RemovedPhotos.logPrefix) {
            // One per file moved to "Removed from Photos". osxphotos' own
            // "Deleted: N files" no longer appears: Kept runs it without
            // --cleanup, so it deletes nothing.
            progress.deleted = (progress.deleted ?? 0) + 1
        } else if let match = line.firstMatch(of: deletedRegex) {
            progress.deleted = Int(match.1)
        } else if line.hasPrefix("Writing export database changes") {
            progress.phase = .finishing
        }

        return progress != before
    }
}
