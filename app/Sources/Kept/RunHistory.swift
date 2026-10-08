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
    var deleted: Int?
    var logPath: String?
    /// Items osxphotos processed at export time. Optional so records written
    /// before this field decode fine.
    var mirroredCount: Int?
    var failureKind: FailureKind?

    var duration: TimeInterval? {
        end.map { $0.timeIntervalSince(start) }
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
    static func upsert(_ record: RunRecord, to url: URL = Config.historyURL) {
        preserveIfUnreadable(url)
        var records = load(from: url)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        if records.count > Config.historyLimit {
            records.removeFirst(records.count - Config.historyLimit)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: url, options: .atomic)
        }
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

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: url, options: .atomic)
        }
        return records
    }
}
