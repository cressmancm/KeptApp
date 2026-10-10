import Foundation

/// Fixed paths and tunables. The backup destination is the user's one
/// location setting (see Destination); everything else lives in standard
/// macOS locations. State files are never kept in the destination, because
/// `--cleanup` deletes anything there that osxphotos didn't put there.
enum Config {
    static let appSupportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Kept")
    static let logDir = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/Kept")

    static var exportDBURL: URL { appSupportDir.appending(path: "export.db") }
    static var reportURL: URL { appSupportDir.appending(path: "report.csv") }
    static var historyURL: URL { appSupportDir.appending(path: "runs.json") }
    static var lockFileURL: URL { appSupportDir.appending(path: ".backup.pid") }

    /// "1.0", from the bundle. Falls back for `swift run` / test binaries.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Version of the bundled osxphotos, read from the wheel's dist-info
    /// directory name rather than by running the interpreter, which would cost
    /// a second or more every time Settings opens.
    ///
    /// Computed once: the lookup walks 167 directory entries at ~0.76ms, and it
    /// was being called from a view body — filesystem I/O on every render of the
    /// Advanced tab, for a value that cannot change while the app is running.
    static let osxphotosVersion: String? = readOSXPhotosVersion()

    private static func readOSXPhotosVersion() -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let lib = resources.appending(path: "python/lib")
        guard let pythonDirs = try? FileManager.default.contentsOfDirectory(
            at: lib, includingPropertiesForKeys: nil) else { return nil }
        for pythonDir in pythonDirs {
            let sitePackages = pythonDir.appending(path: "site-packages")
            let entries = (try? FileManager.default.contentsOfDirectory(
                atPath: sitePackages.path)) ?? []
            for entry in entries
            where entry.hasPrefix("osxphotos-") && entry.hasSuffix(".dist-info") {
                return String(entry.dropFirst("osxphotos-".count).dropLast(".dist-info".count))
            }
        }
        return nil
    }

    /// The bundled interpreter; osxphotos runs as `python3 -m osxphotos`.
    static var bundledPython: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let python = resources.appending(path: "python/bin/python3")
        return FileManager.default.isExecutableFile(atPath: python.path) ? python : nil
    }

    /// Default Photos library location, used only as a permission probe.
    /// Libraries can live elsewhere; when this file doesn't exist the probe
    /// is skipped and a real run surfaces any permission problem loudly.
    static let photosLibraryProbePath =
        ("~/Pictures/Photos Library.photoslibrary/database/Photos.sqlite" as NSString)
        .expandingTildeInPath

    static let minFreeGB = 20
    static let mountTimeoutSecs = 60
    static let probeTimeoutSecs: TimeInterval = 15
    /// The second, longer probe of a share that didn't answer the first, before
    /// it's force-unmounted. A NAS spinning its disks up after a night asleep
    /// can take this long.
    static let slowProbeTimeoutSecs: TimeInterval = 60
    /// How long a file-system call on the backup folder (an existence check,
    /// free space) may take before the folder counts as not responding.
    static let volumeCallTimeoutSecs: TimeInterval = 30
    /// What a wake gives the network before anything tries the share, and
    /// what a scheduled backup waits when it fires late, after a sleep.
    static let wakeGraceSecs: TimeInterval = 30
    static let exportAttempts = 2
    static let logRetentionDays = 30
    /// Runs kept in runs.json. Everything that reads history looks at the
    /// recent end of it — the eight recent backups, the last success, whether
    /// this scheduled slot was serviced — so a long tail was storage without a
    /// reader. The run logs are pruned on their own schedule (logRetentionDays)
    /// and are the place to look for anything older.
    static let historyLimit = 50
    /// Lines kept for the popover's Live log disclosure.
    static let logTailLines = 6
    /// How often the run log gets a timestamped progress mark. Five minutes is
    /// ~11 lines on a healthy 55-minute run and ~78 on a bad six-hour one —
    /// enough to locate a stall, not enough to bury the output.
    static let progressMarkIntervalSecs = 300

    /// Quiet period after a real attempt before catch-up will try again, so a
    /// persistently unreachable NAS cannot turn every wake into a failed run.
    /// Also the gap between automatic retries after a failure.
    static let catchUpCooldownSecs: TimeInterval = 3600

    /// Automatic re-attempts after a failed run, per scheduled slot.
    ///
    /// Deliberately small. Retrying covers the transient case — a share that
    /// was briefly unreachable — but a backup that keeps failing needs a person
    /// looking at it, and an unattended loop would just bury that in a longer
    /// column of red dots.
    static let maxFailureRetries = 2

    /// Every attempt a slot gets, from any trigger: the first, plus the
    /// retries. Catch-up on wake and plug-in counts against it too.
    static let maxAttemptsPerSlot = 1 + maxFailureRetries

    /// Kill an export that has produced no output at all for this long.
    ///
    /// Not a cap on how long a run may take: the 6.5-hour run of 2026-07-30 was
    /// emitting lines throughout and must not be killed. This catches the run
    /// of 2026-07-31, which printed its banner and then blocked for 37 hours on
    /// 0.86s of CPU. Generous because osxphotos is legitimately silent while it
    /// reads a large library before the first export line.
    static let exportStallTimeoutSecs = 1800
    /// Runs listed under Recent backups: a week of normal nights, without
    /// growing the panel taller than everything above it.
    static let recentRunsShown = 8

    static func ensureDirectories() {
        try? FileManager.default.createDirectory(
            at: appSupportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true)
    }
}
