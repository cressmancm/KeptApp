import Foundation

enum BackupTrigger: String, Codable, Sendable {
    case manual, scheduled, catchUp
    /// An automatic re-attempt after a failure, capped by
    /// `Config.maxFailureRetries` so a broken setup ends up in front of the
    /// user rather than looping unattended.
    case retry
}

enum RunOutcome: String, Codable, Sendable {
    case success, failed, cancelled
    /// Lock held by another process — nothing ran.
    /// Also used for a run deferred because the Mac was on battery.
    case skipped
    /// The process died mid-run — quit, killed by an installer, or crashed —
    /// so nothing ever wrote a final outcome. Reconstructed at the next launch
    /// from a record that was left without one.
    case interrupted
}

/// What went wrong, in the terms the user can act on. Recorded so the failed
/// panel can explain the failure in plain language instead of echoing the
/// engine's message; the raw message is still kept, and still shown in the log.
enum FailureKind: String, Codable, Sendable {
    case volumeUnreachable
    case diskFull
    case exportFailed
    case cancelled
    case setupFailed
    /// Kept couldn't read the Photos library, almost always because Full Disk
    /// Access is off. Found before the export starts, so nothing was copied.
    case libraryAccess
}

struct RunRecord: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var trigger: BackupTrigger
    var start: Date
    var end: Date?
    var outcome: RunOutcome?
    var message: String?
    var exported: Int?
    var updated: Int?
    var skipped: Int?
    var errors: Int?
    /// osxphotos ended cleanly but its summary, with the error count, never
    /// came: nothing says every file was copied (production review W3).
    /// nil in records from before Kept kept it.
    var unconfirmed: Bool?
    var deleted: Int?
    var logPath: String?
    /// Items osxphotos processed at export time. Optional so records written
    /// before this field decode fine.
    var mirroredCount: Int?
    var failureKind: FailureKind?
    /// The backup folder the run was for (`Destination.id`). A run belongs to
    /// one folder, so a newly chosen folder starts with no backups of its own
    /// rather than inheriting the last one's. nil in records from before Kept
    /// kept it, which belong to a folder chosen before then (whose id is nil
    /// too).
    var destinationID: UUID?
    /// Files already in the backup that the spot-check after this run
    /// compared with their originals, and how many of them didn't match, or
    /// were gone or unreadable (production review C2). Those are copied again
    /// by the next backup. nil when no spot-check ran, and `damaged` nil when
    /// none were.
    var spotChecked: Int?
    var damaged: Int?

    var duration: TimeInterval? {
        end.map { $0.timeIntervalSince(start) }
    }

    /// Ran to the end, but some files couldn't be copied.
    ///
    /// Originals osxphotos reports missing don't count. Most are shared
    /// items whose originals Photos never keeps on the Mac (shared albums,
    /// shared collections, Shared with You), and in the library that found
    /// this, all but one of 6,221 were. Optimize Mac Storage is the one case
    /// where they're the library's own; the README and the welcome screen
    /// say so instead.
    ///
    /// Still `.success`, deliberately. The backup ran, so it counts for the
    /// schedule and the daily check, and the next backup tries the failed
    /// files again anyway. What it must never do is look like a complete
    /// backup: osxphotos exits 0 either way.
    ///
    /// So is a backup whose summary never came: with no error count, nothing
    /// says it's complete, and it used to be taken as zero errors. And so is
    /// one whose spot-check found older copies damaged: those photos aren't
    /// safely backed up until the next backup copies them again.
    var isPartial: Bool {
        outcome == .success
            && ((errors ?? 0) > 0 || (damaged ?? 0) > 0 || unconfirmed == true)
    }

    /// A backup that ran to the end, with what osxphotos reported.
    mutating func finish(with progress: ExportProgress) {
        outcome = .success
        exported = progress.exported
        updated = progress.updated
        skipped = progress.skipped
        errors = progress.errors
        // The error count is in osxphotos' last summary line. Without it,
        // missing or garbled, the run can't be called complete.
        unconfirmed = progress.errors == nil ? true : nil
        deleted = progress.deleted
    }

    /// Whether this run belongs to `destination`'s history.
    func isFor(_ destination: Destination?) -> Bool {
        guard let destination else { return true }
        return destinationID == destination.id
    }
}

extension Array where Element == RunRecord {
    /// The runs for one backup folder. Every record, when there's no folder.
    func runs(for destination: Destination?) -> [RunRecord] {
        filter { $0.isFor(destination) }
    }
}

/// Append-only run history in runs.json next to the other state files.
enum RunHistory {
    /// Every record that can be read, in order.
    ///
    /// Record by record: a single record this version can't decode — one
    /// written by a newer Kept with an outcome this one doesn't know, say —
    /// used to fail the whole file, which loaded as empty and was then
    /// overwritten by the next run. The history, and with it the staleness
    /// check and catch-up's view of the last good backup, was gone.
    static func load(from url: URL = Config.historyURL) -> [RunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decode(data) ?? []
    }

    private struct Lenient: Decodable {
        let record: RunRecord?
        init(from decoder: Decoder) throws {
            record = try? RunRecord(from: decoder)
        }
    }

    /// nil only when the file isn't a JSON array of records at all.
    static func decode(_ data: Data) -> [RunRecord]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Lenient].self, from: data))?.compactMap(\.record)
    }

    /// Before overwriting a history file that can't be read at all, keeps a
    /// copy of it: rewriting it from nothing would destroy what may only be
    /// damaged.
    private static func preserveIfUnreadable(_ url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty, decode(data) == nil else { return }
        let aside = url.deletingLastPathComponent()
            .appending(path: "runs-unreadable-\(RunLog.fileStamp(.now)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    /// Writes a record, replacing an earlier one with the same id.
    ///
    /// A run is written twice: once when it starts, with no outcome, and again
    /// when it ends. Appending only at the end meant a process that died
    /// mid-run left no trace at all — the 37-hour hang of 2026-07-31 was
    /// invisible in the history, and so was every backup killed by an installer
    /// or by Quit. An attempt that vanishes is indistinguishable from a night
    /// nothing was scheduled.
    ///
    /// Throws when the file can't be written. The caller says so: the panel,
    /// catch-up and the daily check all read this file, and a history that
    /// silently stopped saving makes every one of them wrong.
    static func upsert(_ record: RunRecord, to url: URL = Config.historyURL) throws {
        preserveIfUnreadable(url)
        var records = load(from: url)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        // Oldest first, but never a folder's latest success: it's what the
        // panel, the failed panel and the daily check measure from, and losing
        // it to a run of failures or deferrals makes them all say no backup
        // ever finished. One per folder, so going back to a previous folder
        // finds its last backup still there.
        var latestSuccess: [UUID?: UUID] = [:]
        for record in records where record.outcome == .success {
            latestSuccess[record.destinationID] = record.id
        }
        let kept = Set(latestSuccess.values)
        while records.count > Config.historyLimit,
            let oldest = records.firstIndex(where: { !kept.contains($0.id) })
        {
            records.remove(at: oldest)
        }
        try write(records, to: url)
    }

    private static func write(_ records: [RunRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url, options: .atomic)
    }

    /// Closes out records left without an outcome by a process that died.
    ///
    /// Called at launch, when nothing of ours can legitimately be mid-run. The
    /// caller must confirm no live process holds the backup lock first — a
    /// second app instance starting while the first is exporting would
    /// otherwise mark a perfectly healthy run as interrupted.
    @discardableResult
    static func reconcileInterrupted(
        in url: URL = Config.historyURL, now: Date = .now
    ) -> [RunRecord] {
        var records = load(from: url)
        var changed = false
        for index in records.indices where records[index].outcome == nil {
            records[index].outcome = .interrupted
            records[index].end = now
            records[index].message = "Kept stopped before this run finished"
            changed = true
        }
        guard changed else { return records }
        // Not thrown: the records are right either way, and a write that
        // failed here is tried again at the next launch.
        try? write(records, to: url)
        return records
    }
}
