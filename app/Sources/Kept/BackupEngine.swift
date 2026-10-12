import AppKit
import Foundation
import IOKit.pwr_mgt
import Synchronization

struct BackupError: Error, CustomStringConvertible {
    let message: String
    /// Classified at the throw site so the UI can explain the failure without
    /// pattern-matching on the message text.
    let kind: FailureKind
    init(_ message: String, kind: FailureKind) {
        self.message = message
        self.kind = kind
    }
    var description: String { message }
}

/// The backup itself:
///   1. single-instance lock
///   2. housekeeping (log pruning, yearly report rotation)
///   3. library access (Full Disk Access)
///   4. mount with zombie-mount detection and force-remount
///   5. expiry of "Removed from Photos" folders past the retention setting
///   6. free-space check
///   7. osxphotos incremental mirror export, relaunched once on failure;
///      files it would delete are moved to "Removed from Photos" instead
actor BackupEngine {
    /// How long the engine waits on things, in one place so tests can shrink
    /// it. The defaults are what a real backup uses.
    struct Timing: Sendable {
        var probe: TimeInterval = Config.probeTimeoutSecs
        var slowProbe: TimeInterval = Config.slowProbeTimeoutSecs
        var unmountSettle: Duration = .seconds(3)
        var mountPoll: Duration = .seconds(2)
        var mountTimeout: Duration = .seconds(Config.mountTimeoutSecs)
        var stall: Duration = .seconds(Config.exportStallTimeoutSecs)
        var stallCheck: Duration = .seconds(30)
        var stallSampleSecs = 3
        var volumeCall: TimeInterval = Config.volumeCallTimeoutSecs
    }

    /// Runs a child process: executable, arguments, timeout, stop signal.
    typealias CommandRunner =
        @Sendable (String, [String], TimeInterval?, StopSignal?) async -> CommandResult

    private let timing: Timing
    private let command: CommandRunner
    private let pythonOverride: URL?
    private let workingDirectory: URL
    private let appBundle: URL
    private let stop = StopSignal()
    /// Every call that touches the backup folder and can block on a share that
    /// stopped answering. See BlockingLane.
    private let volumeLane = BlockingLane()
    private var currentProcess: Process?

    init(
        timing: Timing = Timing(),
        python: URL? = nil,
        workingDirectory: URL = Config.appSupportDir,
        appBundle: URL = Bundle.main.bundleURL,
        command: CommandRunner? = nil
    ) {
        self.timing = timing
        self.pythonOverride = python
        self.workingDirectory = workingDirectory
        self.appBundle = appBundle
        self.command = command ?? { executable, arguments, timeout, stop in
            await ShellCommand.run(executable, arguments, timeout: timeout, stop: stop)
        }
    }

    /// Stops the backup in progress at whatever step it's on: a reconnect, a
    /// probe or the export.
    func cancel() {
        stop.fire()
        currentProcess?.terminate()
    }

    private func throwIfStopped() throws {
        if stop.isStopped { throw BackupError("Cancelled", kind: .cancelled) }
    }

    private var python: URL? { pythonOverride ?? Config.bundledPython }

    func run(
        trigger: BackupTrigger,
        destination: Destination,
        onProgress: @escaping @Sendable (ExportProgress) -> Void,
        onLogTail: @escaping @Sendable ([String]) -> Void = { _ in }
    ) async -> RunRecord {
        stop.reset()
        var record = RunRecord(trigger: trigger, start: .now)
        record.destinationID = destination.id
        Config.ensureDirectories()

        let runLog: RunLog
        do {
            runLog = try RunLog()
        } catch {
            record.end = .now
            record.outcome = .failed
            record.message = "Kept couldn't start the backup: \(error.localizedDescription)"
            record.failureKind = .setupFailed
            Self.save(record, nil)
            await Self.notify(record, destination: destination)
            return record
        }
        record.logPath = runLog.url.path

        // Keep the machine awake for the duration. Two mechanisms, because one
        // is not enough — see holdSystemAwake().
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Kept photo backup running")
        let sleepAssertion = Self.holdSystemAwake(reason: "Kept photo backup running")
        if sleepAssertion == nil {
            runLog.log("Warning: could not take a PreventSystemSleep assertion.")
        }
        // PowerSource, shared with the battery rule that decides whether an
        // unattended backup starts at all, so the two never disagree. This
        // used to be a copy that took an unknown power source for battery,
        // where the rule takes it for mains.
        if !PowerSource.isOnAC {
            // The assertion is honoured on AC only. On battery the system will
            // sleep mid-export and drop the share, so say so in the log rather
            // than leave a baffling "Permission denied: /Volumes/..." later.
            runLog.log("Warning: running on battery — macOS may sleep and interrupt this backup.")
        }
        defer {
            if let sleepAssertion { IOPMAssertionRelease(sleepAssertion) }
            ProcessInfo.processInfo.endActivity(activity)
            runLog.close()
        }

        // --- single-instance lock, same .backup.pid file as the script ---
        if let otherPid = Self.livePidHoldingLock() {
            runLog.log("Backup already running (pid \(otherPid)); exiting.")
            record.end = .now
            record.outcome = .skipped
            record.message = "Another backup is already running (pid \(otherPid))"
            Self.save(record, runLog)
            return record
        }
        try? "\(ProcessInfo.processInfo.processIdentifier)\n"
            .write(to: Config.lockFileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: Config.lockFileURL) }

        // Recorded now, with no outcome yet, so the attempt survives the
        // process dying. Everything after this point either updates it in place
        // or leaves it for reconcileInterrupted() to close out at next launch.
        Self.save(record, runLog)

        runLog.log("=== Kept backup starting (trigger: \(trigger.rawValue)) ===")

        Housekeeping.pruneOldLogs(in: Config.logDir, olderThanDays: Config.logRetentionDays)
        if let rotated = Housekeeping.rotateReportIfNeeded(reportURL: Config.reportURL) {
            runLog.log("Rotated report.csv to \(rotated.lastPathComponent)")
        }

        do {
            try await checkOwnFiles(runLog)
            try await checkLibraryAccess(runLog)
            try await ensureDestinationReady(destination, runLog)
            try throwIfStopped()
            await expireRemovedPhotos(destination, runLog)
            try throwIfStopped()
            try await checkFreeSpace(destination, runLog)
            let progress = try await runExport(
                destination, runLog, onProgress: onProgress, onLogTail: onLogTail)

            record.end = .now
            record.outcome = .success
            record.exported = progress.exported
            record.updated = progress.updated
            record.skipped = progress.skipped
            record.errors = progress.errors
            record.deleted = progress.deleted
            // osxphotos exits 0 whatever it left behind, so the summary line
            // is what says whether this backup is complete.
            if record.isPartial {
                runLog.log(
                    "=== Kept backup finished, incomplete: \(progress.errors ?? 0) errors ===")
            } else {
                runLog.log("=== Kept backup completed successfully ===")
            }
            // The library count osxphotos announced for this run. Wider than
            // the Photos app total: it includes hidden, shared and burst
            // items. Kept only uses it to size the first-copy warning.
            record.mirroredCount = progress.total > 0 ? progress.total : nil
        } catch let error as BackupError where stop.isStopped {
            _ = error
            runLog.log("Backup cancelled by user.")
            record.end = .now
            record.outcome = .cancelled
            record.message = "Cancelled"
            record.failureKind = .cancelled
        } catch {
            let message = (error as? BackupError)?.message ?? error.localizedDescription
            runLog.log("FAILED: \(message)")
            record.end = .now
            record.outcome = .failed
            record.message = message
            record.failureKind = (error as? BackupError)?.kind ?? .setupFailed
            // A backup the user started opens its log at once. Not an
            // unattended one: a Mac away from its NAS fails every retry, and
            // each one put a log window and the failure sound in front of
            // whoever was using it. The panel and the notification say what
            // happened, and the log is a click away. Not for missing library
            // access either, where the panel says exactly what to do.
            if trigger == .manual, record.failureKind != .libraryAccess {
                let logURL = runLog.url
                Task { @MainActor in NSWorkspace.shared.open(logURL) }
            }
        }

        Self.save(record, runLog)
        await Self.notify(record, destination: destination)
        return record
    }

    /// Writes the record, and says so in the run log when it can't. The
    /// controller notices too: it reads the history back after every backup.
    private static func save(_ record: RunRecord, _ runLog: RunLog?) {
        do {
            try RunHistory.upsert(record)
        } catch {
            runLog?.log("Couldn't save this backup to the history: \(error.localizedDescription)")
        }
    }

    // MARK: - Kept's own files

    /// First of all: a changed bundle would run the change with Full Disk
    /// Access (AppSeal). Off the actor, on a thread of its own.
    func checkOwnFiles(_ runLog: RunLog) async throws {
        let bundle = appBundle
        let check = await BlockingLane().run(timeout: 120) { AppSeal.isIntact(bundle) }
        switch check {
        case .finished(true?), .finished(nil):
            return
        case .finished(false?):
            runLog.log("Kept's signature doesn't match its files: \(bundle.path)")
            throw BackupError("Part of Kept has been changed. Reinstall it.", kind: .setupFailed)
        case .timedOut, .busy:
            throw BackupError("Kept couldn't check its own files. Try again.", kind: .setupFailed)
        }
    }

    // MARK: - Library access

    /// First, before the destination is touched. Without Full Disk Access the
    /// export dies on its first read, and on 2026-10-06 that surfaced three
    /// times as "stopped partway" — a cause the user could not act on.
    private func checkLibraryAccess(_ runLog: RunLog) async throws {
        let canRead = await LibraryAccess.canRead(stop: stop)
        try throwIfStopped()
        guard canRead == false else { return }
        throw BackupError(
            "Can't read \(Config.photosLibraryProbePath): Full Disk Access is off",
            kind: .libraryAccess)
    }

    // MARK: - Lock

    /// Returns the pid in the lock file if that process is still alive and
    /// is a copy of Kept.
    ///
    /// Alive alone isn't enough. A lock left behind by a crash names a pid the
    /// system will hand out again, and whatever unrelated process gets it would
    /// otherwise turn every backup into "Another backup is already running"
    /// until it happened to exit. Matched by executable name rather than full
    /// path, so a development build still sees an installed copy's backup.
    static func livePidHoldingLock() -> Int32? {
        guard let contents = try? String(contentsOf: Config.lockFileURL, encoding: .utf8),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0,
              isKept(pid: pid)
        else { return nil }
        return pid
    }

    static func isKept(
        pid: Int32, ownName: String? = Bundle.main.executableURL?.lastPathComponent
    ) -> Bool {
        guard let ownName, let path = ProcessAncestry.executablePath(of: pid) else { return false }
        return (path as NSString).lastPathComponent == ownName
    }

    // MARK: - Destination readiness

    /// Local destination: the folder must exist (an unplugged disk fails
    /// loudly). Network destination: mount-with-recovery, below. Either way,
    /// the volume must be the one that was chosen.
    func ensureDestinationReady(_ dest: Destination, _ runLog: RunLog) async throws {
        // Re-checked here, not just at selection time: whatever is in the
        // folder and isn't from the library gets moved aside and, later,
        // deleted.
        guard !Destination.isUnsafeMirrorRoot(path: dest.path),
            Destination.refusal(path: dest.path) == nil
        else {
            throw BackupError(
                "“\(dest.displayName)” isn't a safe backup folder. "
                    + "Choose a different one in Settings.",
                kind: .setupFailed)
        }
        if dest.isNetwork {
            try await ensureMount(dest, runLog)
        }
        // On a share too, once it's mounted: a folder renamed or moved on the
        // NAS used to surface as "Couldn't check free space".
        let check = await volumeLane.run(timeout: timing.volumeCall) {
            () -> (exists: Bool, mismatch: String?) in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir)
                && isDir.boolValue
            return (exists, exists ? dest.volumeMismatch() : nil)
        }
        guard case .finished(let result) = check else { throw notResponding(dest, runLog) }
        guard result.exists else {
            throw BackupError(
                "Backup folder \(dest.path) is not available (disk unplugged or folder deleted?)",
                kind: .volumeUnreachable)
        }
        if let mismatch = result.mismatch {
            runLog.log("Refusing to back up: \(mismatch)")
            throw BackupError(mismatch, kind: .setupFailed)
        }
    }

    /// The backup folder's disk didn't answer a call in time, or is still
    /// stuck on an earlier one.
    private func notResponding(_ dest: Destination, _ runLog: RunLog) -> BackupError {
        runLog.log("The backup folder stopped answering file requests.")
        return BackupError("“\(dest.displayName)” stopped responding.", kind: .volumeUnreachable)
    }

    /// True if the share responds to a real directory read in time. A stale
    /// SMB mount hangs or errors on reads while still showing up in `mount`,
    /// so the probe is a child process that gets SIGKILLed on timeout.
    private func mountIsHealthy(
        _ mountPoint: String, _ runLog: RunLog, timeout: TimeInterval
    ) async -> Bool {
        let probe = await command("/bin/ls", [mountPoint], timeout, stop)
        if probe.timedOut {
            runLog.log("Mount probe hung for \(Int(timeout))s.")
            return false
        }
        return probe.status == 0
    }

    private func isMounted(_ mountPoint: String) async -> Bool {
        let result = await command("/sbin/mount", [], 30, stop)
        return result.stdout.contains(" on \(mountPoint) (smbfs")
    }

    func ensureMount(_ dest: Destination, _ runLog: RunLog) async throws {
        guard let mountPoint = dest.mountPoint, let smbURL = dest.smbURL else {
            // Network volume we can't remount (AFP/NFS). If it reads, proceed.
            let healthy = await mountIsHealthy(dest.path, runLog, timeout: timing.probe)
            try throwIfStopped()
            if healthy { return }
            throw BackupError(
                "Network folder \(dest.path) is unreachable; automatic remounting is only supported for SMB shares",
                kind: .volumeUnreachable)
        }
        let mounted = await isMounted(mountPoint)
        try throwIfStopped()
        if mounted {
            if await mountIsHealthy(mountPoint, runLog, timeout: timing.probe) { return }
            try throwIfStopped()
            // A NAS whose disks were asleep can take longer than the first
            // probe allows to answer. Force-unmounting it then turned a slow
            // wake-up into a failed backup, so it gets one longer try first.
            runLog.log("Share didn't answer; trying again for \(Int(timing.slowProbe))s.")
            if await mountIsHealthy(mountPoint, runLog, timeout: timing.slowProbe) { return }
            try throwIfStopped()
            runLog.log("Share is mounted but stale; force-unmounting.")
            let unmount = await command(
                "/usr/sbin/diskutil", ["unmount", "force", mountPoint], 60, stop)
            try throwIfStopped()
            if unmount.status != 0 {
                _ = await command("/sbin/umount", ["-f", mountPoint], 60, stop)
                try throwIfStopped()
            }
            try? await Task.sleep(for: timing.unmountSettle)
            try throwIfStopped()
        }

        // Checked only now, when the URL is about to be used: a share that is
        // already mounted and healthy needs no URL at all.
        guard Destination.isWellFormedSMBURL(smbURL) else {
            throw BackupError(
                "Refusing to mount a malformed share URL; re-select the backup folder",
                kind: .volumeUnreachable)
        }
        runLog.log("Mounting \(smbURL)")
        // `mount volume` reuses the credential saved in the Keychain when the
        // user first connected to the share in Finder.
        //
        // The URL is passed as an argument and read back out of `argv`, never
        // spliced into the script text. Interpolating it would let a quote in
        // the stored URL close the string literal and append AppleScript —
        // which `do shell script` turns into arbitrary code running as a child
        // of this app, inheriting its Photos and network-volume TCC grants.
        let mountResult = await command(
            "/usr/bin/osascript", Self.mountScriptArguments(smbURL), 120, stop)
        try throwIfStopped()
        if !mountResult.stderr.isEmpty {
            runLog.appendRaw(mountResult.stderr.trimmingCharacters(in: .newlines))
        }
        // Said plainly rather than left to time out as "Couldn't reach": the
        // share is fine, and waiting a minute for it won't help.
        if Self.isAutomationDenied(mountResult.stderr) {
            throw BackupError(
                "Kept isn't allowed to reconnect “\(dest.displayName)”. Turn on Kept in "
                    + "System Settings → Privacy & Security → Automation.",
                kind: .setupFailed)
        }

        let clock = ContinuousClock()
        let started = clock.now
        while !(await isMounted(mountPoint)) {
            try throwIfStopped()
            if started.duration(to: clock.now) >= timing.mountTimeout {
                throw BackupError(
                    "Could not mount \(smbURL) after \(timing.mountTimeout.components.seconds)s",
                    kind: .volumeUnreachable)
            }
            try? await Task.sleep(for: timing.mountPoll)
            try throwIfStopped()
        }
        // The longer probe: a share that was just mounted may still be waking
        // its disks.
        let healthy = await mountIsHealthy(mountPoint, runLog, timeout: timing.slowProbe)
        try throwIfStopped()
        guard healthy else {
            throw BackupError(
                "Mounted \(smbURL) but it does not respond to reads", kind: .volumeUnreachable)
        }
        runLog.log(
            "Mounted and healthy after \(started.duration(to: clock.now).components.seconds)s.")
    }

    /// The reconnect, as `osascript` arguments. Shared with the check the
    /// controller runs when a share is chosen, so both raise the same prompt.
    static func mountScriptArguments(_ smbURL: String) -> [String] {
        [
            "-e", "on run argv",
            "-e", "mount volume (item 1 of argv)",
            "-e", "end run",
            "--", smbURL,
        ]
    }

    /// osascript's "Not authorized to send Apple events" (-1743): Automation
    /// is off for Kept, or its prompt was answered Don't Allow.
    static func isAutomationDenied(_ stderr: String) -> Bool {
        stderr.contains("(-1743)")
    }

    // MARK: - Free space

    /// From statfs, which the panel already uses. This used to read the
    /// fourth field of `df -g`, which shifts for a volume whose name has a
    /// space in it. Gigabytes as df counts them (2^30 bytes).
    private func checkFreeSpace(_ dest: Destination, _ runLog: RunLog) async throws {
        let read = await volumeLane.run(timeout: timing.volumeCall) { dest.volumeStats() }
        guard case .finished(let stats) = read else { throw notResponding(dest, runLog) }
        guard let stats else {
            throw BackupError(
                "Couldn't check free space on “\(dest.displayName)”.", kind: .setupFailed)
        }
        let availGB = Int(stats.freeBytes / 1_073_741_824)
        guard availGB >= Config.minFreeGB else {
            throw BackupError(
                "Low free space on \(dest.path): \(availGB)GB available (need \(Config.minFreeGB)GB)",
                kind: .diskFull)
        }
        runLog.log("Free space OK: \(availGB)GB available.")
    }

    /// osxphotos' arguments, after the interpreter. A function of its own so a
    /// test can run them past osxphotos' option checks, which happen before it
    /// opens the library: on 2026-10-06 dropping --cleanup made --keep invalid,
    /// and every backup failed at once.
    static func exportArguments(
        destinationPath: String,
        exportDB: String = Config.exportDBURL.path,
        report: String = Config.reportURL.path
    ) -> [String] {
        [
            // -I (isolated) is load-bearing, not tidiness. Without it `-m`
            // puts the working directory first on sys.path — and the working
            // directory is Application Support/Kept, which anything
            // running as this user can write. An `osxphotos.py` dropped there
            // shadows the real package and executes inside this process,
            // inheriting its TCC grants. -I also drops the user site-packages
            // directory and ignores PYTHON* environment variables.
            "-I",
            // -B: never write bytecode. The bundle ships it precompiled and
            // sealed (build.sh); a .pyc written at run time lands inside the
            // signed app, breaks its signature, and is a file the
            // interpreter would load next time without anything checking it.
            "-B",
            "-m", "osxphotos",
            "export", destinationPath,
            "--export-by-date",
            "--update",
            // No --cleanup: see RemovedPhotos. Its job is done by the
            // --cleanup-command, which moves instead of deleting. No --keep
            // either: osxphotos refuses --keep without --cleanup, so the keep
            // rules are in the backup folder's .osxphotos_keep file
            // (RemovedPhotos.writeKeepRules). No --cleanup-command-error: if a
            // move fails, the export stops and the backup is marked failed.
            // Nothing is deleted either way.
            "--cleanup-command", RemovedPhotos.cleanupCommand,
            "--sidecar", "XMP",
            "--ramdb",
            "--exportdb", exportDB,
            "--report", report, "--append",
            "--retry", "3",
            "--verbose",
        ]
    }

    // MARK: - Removed photos

    /// Deletes "Removed from Photos" folders past the retention setting, before
    /// the free-space check so the space they free counts. Never fails the
    /// backup: anything it couldn't delete is logged and tried again next run.
    ///
    /// On the volume lane, off the actor, so Stop can still reach the engine
    /// while it works. No timeout: deleting a year of removed photos from a
    /// NAS can legitimately take minutes, and nothing else may touch the
    /// folder until it's done.
    private func expireRemovedPhotos(_ dest: Destination, _ runLog: RunLog) async {
        let days = RemovedPhotos.retentionDays()
        let outcome = await volumeLane.run {
            RemovedPhotos.expire(
                backupRoot: URL(filePath: dest.path, directoryHint: .isDirectory),
                retentionDays: days)
        }
        guard case .finished(let result) = outcome else {
            runLog.log("Skipped deleting expired removed photos: the backup folder isn't answering.")
            return
        }
        for folder in result.expired {
            runLog.log(
                "Deleted \(RemovedPhotos.folderName)/\(folder.name) "
                    + "(\(folder.fileCount) file\(folder.fileCount == 1 ? "" : "s")): "
                    + "older than \(days) days.")
        }
        for error in result.errors {
            runLog.log(error)
        }
    }

    // MARK: - Export

    func runExport(
        _ dest: Destination,
        _ runLog: RunLog,
        onProgress: @escaping @Sendable (ExportProgress) -> Void,
        onLogTail: @escaping @Sendable ([String]) -> Void
    ) async throws -> ExportProgress {
        var lastStatus: Int32 = -1
        for attempt in 1...Config.exportAttempts {
            try throwIfStopped()
            runLog.log("Starting osxphotos export (attempt \(attempt) of \(Config.exportAttempts))...")

            let (status, progress) = try await runOsxphotos(
                dest, runLog, onProgress: onProgress, onLogTail: onLogTail)
            lastStatus = status
            if status == 0 { return progress }
            try throwIfStopped()

            runLog.log("Export attempt \(attempt) exited with status \(status).")
            if attempt < Config.exportAttempts {
                runLog.log("Checking destination health before relaunch...")
                try await ensureDestinationReady(dest, runLog)
                runLog.log("Relaunching export; --update resumes from the export database.")
            }
        }
        throw BackupError(
            "osxphotos export failed after \(Config.exportAttempts) attempts (last status \(lastStatus); see log)",
            kind: .exportFailed)
    }

    private func runOsxphotos(
        _ dest: Destination,
        _ runLog: RunLog,
        onProgress: @escaping @Sendable (ExportProgress) -> Void,
        onLogTail: @escaping @Sendable ([String]) -> Void
    ) async throws -> (status: Int32, progress: ExportProgress) {
        guard let python else {
            throw BackupError("Part of Kept is missing. Reinstall it.", kind: .setupFailed)
        }
        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = workingDirectory
        guard let executable = Bundle.main.executableURL?.path else {
            throw BackupError("Part of Kept is missing. Reinstall it.", kind: .setupFailed)
        }
        var environment = ChildEnvironment.sanitized()
        environment[RemovedPhotos.executableVariable] = executable
        environment[RemovedPhotos.backupRootVariable] = dest.path
        process.environment = environment
        let rules = await volumeLane.run(timeout: timing.volumeCall) {
            Result { try RemovedPhotos.writeKeepRules(
                backupRoot: URL(filePath: dest.path, directoryHint: .isDirectory)) }
        }
        guard case .finished(let written) = rules else { throw notResponding(dest, runLog) }
        try written.get()
        // The last suspension before launch. Past it, a Stop reaches the
        // process through `currentProcess`.
        try throwIfStopped()
        process.arguments = Self.exportArguments(destinationPath: dest.path)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let exited = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            throw BackupError(
                "Kept couldn't start the backup: \(error.localizedDescription)",
                kind: .setupFailed)
        }
        currentProcess = process
        defer { currentProcess = nil }

        var parser = ProgressParser()
        var lastEmit = ContinuousClock.now
        // Rolling window feeding the popover's Live log disclosure. Only the
        // visible lines are held; the full output is already on disk.
        var tail: [String] = []
        // Periodic timestamped progress marks. osxphotos' own output carries no
        // timestamps, so a finished log could say a run took six hours without
        // showing where the time went — a steady crawl and a four-hour stall
        // look identical afterwards. These lines make the rate visible.
        var lastMark = ContinuousClock.now
        var lastMarkItem = 0
        onProgress(parser.progress)

        // Stall watchdog. Without it, an export that blocks forever blocks this
        // read loop forever, run() never returns, and `isRunning` stays true —
        // so every later scheduled run is silently dropped by the guard in
        // startBackup. That happened on 2026-07-31: one hung export cost three
        // nights of backups while the panel showed "Backing up now" throughout.
        //
        // The pid is captured by value rather than the Process, and the kill
        // happens here rather than in the watchdog's own log call, because
        // RunLog is not safe to write from two tasks.
        let lastOutput = Mutex(ContinuousClock.now)
        let stalled = Mutex(false)
        let samplePath = Mutex<String?>(nil)
        let pid = process.processIdentifier
        let stallLimit = timing.stall
        let stallCheck = timing.stallCheck
        let sampleSecs = timing.stallSampleSecs
        // Beside the run log, which is in the logs folder.
        let sampleDir = runLog.url.deletingLastPathComponent()
        let stallWatchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: stallCheck)
                if Task.isCancelled { return }
                let idle = lastOutput.withLock { $0.duration(to: ContinuousClock.now) }
                if idle > stallLimit {
                    stalled.withLock { $0 = true }

                    // Capture where it is stuck *before* killing it. Two hangs
                    // with this exact signature — banner printed, then silence,
                    // on 2026-07-31 and 2026-08-07 — and no evidence either
                    // time, because the only thing that could have said where
                    // it was blocked was the process being killed to end them.
                    let path = sampleDir
                        .appending(path: "stall-sample-\(RunLog.fileStamp(.now)).txt").path
                    let sampled = await ShellCommand.run(
                        "/usr/bin/sample", ["\(pid)", "\(sampleSecs)", "-file", path],
                        timeout: 120)
                    if sampled.status == 0 { samplePath.withLock { $0 = path } }

                    // SIGKILL, not SIGTERM: a process wedged in a syscall
                    // against a dead mount may never handle a catchable signal.
                    // Its descendants too: a cleanup command (`sh`, then
                    // `Kept --hold-removed`) inherits the output pipe, and one
                    // left hung on the share would hold it open after osxphotos
                    // is gone — so the read loop below would never end, which
                    // is the hang this watchdog exists to stop.
                    let tree = ProcessAncestry.descendants(of: pid)
                    kill(pid, SIGKILL)
                    for child in tree { kill(child, SIGKILL) }
                    return
                }
            }
        }
        defer { stallWatchdog.cancel() }

        var movedFrom: [String] = []
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                lastOutput.withLock { $0 = ContinuousClock.now }
                runLog.appendRaw(line)
                if let path = RemovedPhotos.originalPath(fromLogLine: line) { movedFrom.append(path) }
                tail.append(line)
                if tail.count > Config.logTailLines {
                    tail.removeFirst(tail.count - Config.logTailLines)
                }

                let phaseBefore = parser.progress.phase
                _ = parser.consume(line: line)
                // Throttle UI updates; phase changes always go through.
                let phaseChanged = parser.progress.phase != phaseBefore
                if phaseChanged { onProgress(parser.progress) }
                let now = ContinuousClock.now
                if lastEmit.duration(to: now) > .milliseconds(300) {
                    lastEmit = now
                    if !phaseChanged { onProgress(parser.progress) }
                    onLogTail(tail)
                }

                let sinceMark = lastMark.duration(to: now)
                if sinceMark > .seconds(Config.progressMarkIntervalSecs) {
                    runLog.log(Self.progressMark(
                        parser.progress, since: lastMarkItem, elapsed: sinceMark))
                    lastMark = now
                    lastMarkItem = parser.progress.current
                }
            }
        } catch {
            runLog.log("Error reading osxphotos output: \(error.localizedDescription)")
        }

        for await _ in exited {}
        if stalled.withLock({ $0 }) {
            runLog.log(
                "No output for \(stallLimit.components.seconds / 60) minutes — the export was "
                    + "hung and has been killed. Retrying if attempts remain.")
            if let path = samplePath.withLock({ $0 }) {
                runLog.log("Captured a stack sample of the hung process at \(path)")
            } else {
                runLog.log("Could not sample the hung process before killing it.")
            }
        }
        if !movedFrom.isEmpty {
            runLog.log(
                "Moved \(movedFrom.count) file\(movedFrom.count == 1 ? "" : "s") removed from Photos to "
                    + "\(RemovedPhotos.folderName); kept for "
                    + "\(RemovedPhotos.retentionDays()) days.")
            let moved = movedFrom
            let outcome = await volumeLane.run {
                RemovedPhotos.removeEmptyFolders(
                    backupRoot: URL(filePath: dest.path, directoryHint: .isDirectory),
                    movedFrom: moved)
            }
            if case .finished(let emptied) = outcome, !emptied.isEmpty {
                runLog.log("Removed \(emptied.count) empty folder\(emptied.count == 1 ? "" : "s").")
            }
        }
        onProgress(parser.progress)
        onLogTail(tail)
        return (process.terminationStatus, parser.progress)
    }

    // MARK: - Access test

    /// Quick permission diagnostic: exports a few photos to a throwaway temp
    /// directory with its own export database. Exercises the same TCC gates
    /// as a real backup (library database read + original file reads) in
    /// about a minute, without touching the NAS or any real state. Full
    /// osxphotos output is kept in logs/access-test.log for inspection.
    /// --limit 5 rather than 1 because ~12% of the library has no local
    /// original; a single missing pick would look like a failure.
    func accessTest() async -> String {
        Config.ensureDirectories()
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "KeptAccessTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return "The test couldn't start: \(error.localizedDescription)"
        }

        guard let python else {
            return "Part of Kept is missing. Reinstall it."
        }
        let result = await ShellCommand.run(
            python.path,
            [
                "-I", "-B",  // same isolation as a real run — see exportArguments
                "-m", "osxphotos",
                "export", tempDir.path,
                "--limit", "5",
                "--exportdb", tempDir.appending(path: "test-export.db").path,
                "--verbose",
            ],
            timeout: 900,
            environment: ChildEnvironment.sanitized())

        let transcript = "exit status: \(result.status)  timedOut: \(result.timedOut)\n"
            + result.stdout + result.stderr
        try? transcript.write(
            to: Config.logDir.appending(path: "access-test.log"),
            atomically: true, encoding: .utf8)

        if result.timedOut {
            return "The test timed out after 15 minutes."
        }
        var parser = ProgressParser()
        result.stdout.enumerateLines { line, _ in _ = parser.consume(line: line) }
        let progress = parser.progress
        if result.status == 0, let exported = progress.exported, exported >= 1 {
            return "OK — exported \(exported), missing \(progress.missing ?? 0), errors \(progress.errors ?? 0)"
        }
        let tail = (result.stdout + result.stderr)
            .split(separator: "\n").suffix(2).joined(separator: " ")
        return "FAILED (exit \(result.status)) \(tail) — see access-test.log"
    }

    /// One progress mark: where the export is, and how fast it has been moving
    /// since the previous mark.
    ///
    /// The rate is the point. An export that is merely large and one that is
    /// stuck behind a hibernating NAS both end up as "took six hours"; only a
    /// per-interval rate separates them, and only from inside the run — the
    /// finished log cannot be re-derived afterwards.
    static func progressMark(
        _ progress: ExportProgress, since previousItem: Int, elapsed: Duration
    ) -> String {
        guard progress.phase == .exporting, progress.total > 0 else {
            return "progress: \(progress.phase.rawValue)"
        }
        let minutes = Double(elapsed.components.seconds) / 60
        let done = progress.current
        let percent = Int((Double(done) / Double(progress.total) * 100).rounded())
        var line = "progress: \(done.formatted(.number)) of "
            + "\(progress.total.formatted(.number)) (\(percent)%)"
        if minutes > 0 {
            let rate = Int((Double(done - previousItem) / minutes).rounded())
            line += " · \(rate.formatted(.number))/min"
        }
        return line
    }

    // MARK: - Keeping the machine awake

    /// Takes a `PreventSystemSleep` power assertion — the missing half of
    /// `caffeinate -ims`.
    ///
    /// `beginActivity(.idleSystemSleepDisabled)` is only `caffeinate -i`: it
    /// prevents *idle* sleep from an awake machine, and does nothing at 2 AM,
    /// when the Mac is asleep and merely DarkWakes for short maintenance
    /// windows. Without this, an overnight export runs in 45-second slivers
    /// with the machine sleeping in between, and the SMB mount does not
    /// survive that — the export dies on `Permission denied` against its own
    /// mount point. Observed 2026-07-28: ~25 sleep/wake cycles across 37
    /// minutes, both export attempts killed.
    ///
    /// Honoured on AC power only, exactly like `caffeinate -s`.
    private static func holdSystemAwake(reason: String) -> IOPMAssertionID? {
        var assertionID = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID)
        return status == kIOReturnSuccess ? assertionID : nil
    }

    // MARK: - Notifications

    /// Posts at most one notification per run, gated by the Settings
    /// preferences: failures are announced by default, successes only when the
    /// user opts in. Cancelled and skipped runs stay silent — the user was
    /// there for one, and nothing happened in the other.
    /// A failure is posted as the same sentence the failed panel shows. The
    /// engine's own message is written for the log — paths, exit codes, tool
    /// names — and used to be the notification body verbatim, so a failed
    /// night arrived as "osxphotos export failed after 2 attempts (last status
    /// 1; see log)". It is still in the log.
    private static func notify(_ record: RunRecord, destination: Destination) async {
        let defaults = UserDefaults.standard
        let kind: KeptNotification.Kind
        switch record.outcome {
        case .failed:
            guard defaults.bool(forKey: Preferences.notifyOnFailure) else { return }
            kind = .backupFailed(
                message: FailureCopy.message(
                    kind: record.failureKind, rawMessage: record.message,
                    destination: destination, failedAt: record.start
                ).plainText)
        case .success where (record.errors ?? 0) > 0:
            // Files that should have copied and didn't are a failure the user
            // would want to hear about.
            guard defaults.bool(forKey: Preferences.notifyOnFailure) else { return }
            kind = .backupIncomplete(message: RunFormatting.errorsSentence(record.errors ?? 0))
        case .success:
            guard defaults.bool(forKey: Preferences.notifyAlways) else { return }
            kind = .backupComplete(body: Self.successBody(record))
        default:
            return
        }
        await KeptNotification.post(kind)
    }

    /// What changed, not what the library totals. The total osxphotos reports
    /// counts hidden, shared and burst items the Photos app leaves out of its
    /// own summary, so quoting it here invites the same false comparison the
    /// popover subtitle used to.
    static func successBody(_ record: RunRecord) -> String {
        var parts: [String] = []
        if let exported = record.exported { parts.append("\(exported) new") }
        if let deleted = record.deleted, deleted > 0 { parts.append("\(deleted) removed") }
        if let notCopied = RunFormatting.notCopied(record) { parts.append(notCopied) }
        return parts.isEmpty ? "No changes since the last backup." : parts.joined(separator: " · ")
    }
}
