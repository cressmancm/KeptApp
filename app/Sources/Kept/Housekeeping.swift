import Foundation

/// Log pruning and yearly report rotation, ported from the script's
/// housekeeping block. URLs and `now` are parameters so tests can run
/// against a temp directory.
enum Housekeeping {
    /// Deletes run logs older than `days`, and stack samples of hung exports
    /// (stall-sample-*.txt) with them — those used to be kept forever. Only
    /// those two namings are considered, so launchd.log-style files survive.
    static func pruneOldLogs(in dir: URL, olderThanDays days: Int, now: Date = .now) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        for entry in entries {
            let name = entry.lastPathComponent
            let isRunLog = name.hasPrefix("2") && name.hasSuffix(".log")
            let isStallSample = name.hasPrefix("stall-sample-") && name.hasSuffix(".txt")
            guard isRunLog || isStallSample else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Numbers and Excel both stop at 1,048,576 rows and refuse to open a file
    /// with more, which makes an oversized report worthless — being openable in
    /// a spreadsheet is the only reason it is kept. osxphotos appends to it on
    /// every run (`--report … --append`), so a yearly rotation alone is not
    /// enough: it reached 2.98M rows / 366MB in under a month.
    static let reportRowLimit = 900_000

    /// Rows run ~120 bytes in practice — a full destination path plus a handful
    /// of fields. Below `reportRowLimit` × 32 bytes even implausibly short rows
    /// cannot reach the limit, so smaller files skip the count entirely. The
    /// count is authoritative; this only keeps a 366MB read off every run, and
    /// a freshly rotated report stays under it for months.
    private static func rowCountSkipBelowBytes(_ rowLimit: Int) -> Int { rowLimit * 32 }

    /// Moves the report aside when it has rolled into a new year or grown past
    /// `rowLimit` rows. Returns the rotated-to URL when rotation happened;
    /// osxphotos recreates report.csv, header and all, on next run.
    ///
    /// `rowLimit` is a parameter only so tests can exercise the size path
    /// without writing a 110MB fixture; callers should take the default.
    @discardableResult
    static func rotateReportIfNeeded(
        reportURL: URL, now: Date = .now, calendar: Calendar = .current,
        rowLimit: Int = reportRowLimit
    ) -> URL? {
        guard let modified = (try? reportURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return nil }
        let reportYear = calendar.component(.year, from: modified)
        let rolledOver = reportYear != calendar.component(.year, from: now)
        guard rolledOver || isOversized(reportURL, rowLimit: rowLimit) else { return nil }
        return rotate(reportURL, taggedWith: reportYear)
    }

    /// True when the file holds at least `rowLimit` rows.
    private static func isOversized(_ url: URL, rowLimit: Int) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size >= rowCountSkipBelowBytes(rowLimit) else { return false }
        return countRows(url, stoppingAt: rowLimit) >= rowLimit
    }

    /// Streams the file counting newlines, so a 366MB report never lands in
    /// memory at once. Stops as soon as the limit is reached — there is no
    /// reason to finish counting a file already known to be too big.
    private static func countRows(_ url: URL, stoppingAt limit: Int) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        var rows = 0
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            for byte in chunk where byte == UInt8(ascii: "\n") {
                rows += 1
                if rows >= limit { return rows }
            }
        }
        return rows
    }

    /// Rotation target is report-<year>.csv, suffixed when that name is taken —
    /// size rotation can fire repeatedly within one year, and silently
    /// overwriting the previous report would destroy the history the file
    /// exists to preserve.
    private static func rotate(_ reportURL: URL, taggedWith year: Int) -> URL? {
        let fm = FileManager.default
        let dir = reportURL.deletingLastPathComponent()
        var target = dir.appending(path: "report-\(year).csv")
        var suffix = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appending(path: "report-\(year)-\(suffix).csv")
            suffix += 1
        }
        do {
            try fm.moveItem(at: reportURL, to: target)
            return target
        } catch {
            return nil
        }
    }
}
