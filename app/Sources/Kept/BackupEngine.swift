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
///   7. the Photos library: the System Photo Library, checked against the
///      backup so a different or empty one can't retire it (PhotosLibrary)
///   8. osxphotos incremental mirror export, relaunched once on failure;
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
        /// Deadlines for the cleanup helper. Deleting a year of removed
        /// photos from a NAS can take a while; what isn't done by then is
        /// done next backup.
        var expiry: TimeInterval = Config.expiryTimeoutSecs
        var emptyFolders: TimeInterval = Config.emptyFoldersTimeoutSecs
        /// How long a killed child gets to end. See ChildProcess.grace.
        var grace: Duration = ChildProcess.grace
    }

    /// Runs a child process: executable, arguments, timeout, stop signal.
    typealias CommandRunner =
        @Sendable (String, [String], TimeInterval?, StopSignal?) async -> CommandResult

    private let timing: Timing
    private let command: CommandRunner
    private let pythonOverride: URL?
    private let exportGuardOverride: URL?
    private let workingDirectory: URL
    private let appBundle: URL
    private let systemLibrary: @Sendable () -> String?
    /// Whether the bundle is intact (AppSeal), injectable for tests.
    private let appSeal: @Sendable (URL) -> Bool?
    private let exportDatabase: String
    private let stop = StopSignal()
    /// Every call that touches the backup folder and can block on a share that
    /// stopped answering. See BlockingLane.
    private let volumeLane = BlockingLane()
    /// Kept itself, run as osxphotos' cleanup command and as the cleanup
    /// helper.
    private let helper: URL?
    /// Children that were killed and haven't ended: blocked, most likely, on
    /// a share that stopped answering. Each can do nothing more, but until
    /// it's gone nothing else may touch the backup folder. See
    /// refuseWhileStuck.
    private var stuck: [ChildProcess] = []

    init(
        timing: Timing = Timing(),
        python: URL? = nil,
        exportGuard: URL? = nil,
        workingDirectory: URL = Config.appSupportDir,
        appBundle: URL = Bundle.main.bundleURL,
        systemLibrary: @escaping @Sendable () -> String? = { PhotosLibrary.systemLibraryPath() },
        exportDatabase: String = Config.exportDBURL.path,
        helper: URL? = Bundle.main.executableURL,
        appSeal: @escaping @Sendable (URL) -> Bool? = { AppSeal.isIntact($0) },
        command: CommandRunner? = nil
    ) {
        self.helper = helper
        self.appSeal = appSeal
        self.timing = timing
        self.pythonOverride = python
        self.exportGuardOverride = exportGuard
        self.workingDirectory = workingDirectory
        self.appBundle = appBundle
        self.systemLibrary = systemLibrary
        self.exportDatabase = exportDatabase
        self.command = command ?? { executable, arguments, timeout, stop in
            await ShellCommand.run(executable, arguments, timeout: timeout, stop: stop)
        }
    }

    /// Stops the backup in progress at whatever step it's on: a reconnect, a
    /// probe, the cleanup or the export. Each child registers with the stop
    /// signal, and firing it kills the child and everything it started.
    func cancel() {
        stop.fire()
    }

    /// Records a child that was killed and hasn't ended.
    func remember(stuck child: ChildProcess) {
        stuck.append(child)
    }

    /// Refuses to start anything that touches the backup folder while a
    /// killed child from earlier still hasn't ended. Two at once could move
    /// or delete the same files.
    func refuseWhileStuck(_ dest: Destination, _ runLog: RunLog) throws {
        stuck.removeAll { !$0.groupIsAlive }
        guard !stuck.isEmpty else { return }
        runLog.log(
            "A stopped part of an earlier backup is still waiting on the backup folder "
                + "(pid \(stuck.map { "\($0.pid)" }.joined(separator: ", "))).")
        throw BackupError("“\(dest.displayName)” stopped responding.", kind: .volumeUnreachable)
    }

    /// Runs the cleanup helper: Kept, in a process the stop signal and a
    /// deadline can kill. Its output goes to the run log. Throws when it was
    /// stopped, or killed and stuck.
    private func runHelper(
        _ arguments: [String], input: Data = Data(), timeout: TimeInterval,
        _ dest: Destination, _ runLog: RunLog
    ) async throws -> CommandResult {
        try refuseWhileStuck(dest, runLog)
        try throwIfStopped()
        guard let helper else {
            throw BackupError("Part of Kept is missing. Reinstall it.", kind: .setupFailed)
        }
        var environment = ChildEnvironment.sanitized()
        environment[RemovedPhotos.backupRootVariable] = dest.path
        let result = await ShellCommand.run(
            helper.path, arguments, timeout: timeout, environment: environment, input: input,
            stop: stop)
        result.stdout.enumerateLines { line, _ in runLog.log(line) }
        if let child = result.stuck {
            remember(stuck: child)
            try throwIfStopped()
            throw notResponding(dest, runLog)
        }
        try throwIfStopped()
        if result.status != 0, !result.timedOut {
            result.stderr.enumerateLines { line, _ in runLog.log(line) }
        }
        return result
    }

    private func throwIfStopped() throws {
        if stop.isStopped { throw BackupError("Cancelled", kind: .cancelled) }
    }

    private var python: URL? { pythonOverride ?? Config.bundledPython }
    private var exportGuard: URL? { exportGuardOverride ?? Config.exportGuard }

    /// The export's exit status when it refused a link in the backup folder
    /// (LINK_REFUSED in kept_export.py).
    static let linkRefusedStatus: Int32 = 75

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

        // One backup at a time, across every copy of Kept (BackupLock).
        let lock: BackupLock
        switch BackupLock.acquire() {
        case .acquired(let acquired):
            lock = acquired
        case .held(let otherPid):
            let who = otherPid.map { $0 > 0 ? " (pid \($0))" : "" } ?? ""
            runLog.log("Backup already running\(who); exiting.")
            record.end = .now
            record.outcome = .skipped
            record.message = "Another backup is already running\(who)"
            Self.save(record, runLog)
            return record
        case .failed(let reason):
            runLog.log("FAILED: \(reason)")
            record.end = .now
            record.outcome = .failed
            record.message = "Kept couldn't make sure no other backup is running. Try again."
            record.failureKind = .setupFailed
            Self.save(record, runLog)
            await Self.notify(record, destination: destination)
            return record
        }
        defer { lock.release() }

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
            try await expireRemovedPhotos(destination, runLog)
            try throwIfStopped()
            try await checkFreeSpace(destination, runLog)
            let source = try await checkPhotosLibrary(destination, runLog)
            let progress = try await runExport(
                destination, runLog, source: source, onProgress: onProgress,
                onLogTail: onLogTail)

            record.end = .now
            record.finish(with: progress)
            // osxphotos exits 0 whatever it left behind, so the summary line
            // is what says whether this backup is complete.
            if record.unconfirmed == true {
                runLog.log(
                    "=== Kept backup finished, unconfirmed: osxphotos printed no error count ===")
            } else if record.isPartial {
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

    /// First of all, and again right before every launch of Python, the
    /// backup's and Test Library Access's alike: a changed bundle would run
    /// the change with Full Disk Access (AppSeal). Test Library Access used
    /// to skip it (production review S4). Off the actor, on a thread of its
    /// own. The check and the launch are still two steps, so a change in
    /// the moment between them isn't caught.
    func checkOwnFiles(_ runLog: RunLog?) async throws {
        let bundle = appBundle
        let seal = appSeal
        let check = await BlockingLane().run(timeout: 120) { seal(bundle) }
        switch check {
        case .finished(true?), .finished(nil):
            return
        case .finished(false?):
            runLog?.log("Kept's signature doesn't match its files: \(bundle.path)")
            if AppSeal.runningRequirement == nil {
                runLog?.log("Kept couldn't read its own signature when it started")
            }
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

    /// The pid of a backup holding the lock, from any copy of Kept, or nil
    /// when none does. See BackupLock.
    static func livePidHoldingLock(at lock: URL = Config.lockFileURL) -> Int32? {
        BackupLock.holder(at: lock)
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
            return (exists, exists ? dest.volumeMismatch() ?? dest.folderMismatch() : nil)
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

    /// The reconnect, as `osascript` arguments.
    ///
    /// A bare `mount volume`, not `tell application "Finder"`: it's a
    /// scripting-addition command that runs inside osascript and sends no
    /// Apple Event, so it needs no Automation permission, and Kept no
    /// apple-events entitlement. Verified 2026-10-13: Kept had never appeared
    /// under Automation, and a build without the entitlement reconnected an
    /// ejected share in under a second.
    static func mountScriptArguments(_ smbURL: String) -> [String] {
        [
            "-e", "on run argv",
            "-e", "mount volume (item 1 of argv)",
            "-e", "end run",
            "--", smbURL,
        ]
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
        exportGuard: String,
        source: ExportSource = ExportSource(library: nil, cleanup: true),
        exportDB: String = Config.exportDBURL.path,
        report: String = Config.reportURL.path
    ) -> [String] {
        var arguments = [
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
            // osxphotos, through Kept's launcher: nothing it does in the
            // backup folder follows a link (production review S3).
            exportGuard, destinationPath,
            "export", destinationPath,
        ]
        // Named, never left to osxphotos, which picks the library Photos
        // opened last. See PhotosLibrary.
        if let library = source.library { arguments += ["--library", library] }
        arguments += [
            "--export-by-date",
            "--update",
        ]
        // No --cleanup: see RemovedPhotos. Its job is done by the
        // --cleanup-command, which moves instead of deleting. No --keep
        // either: osxphotos refuses --keep without --cleanup, so the keep
        // rules are in the backup folder's .osxphotos_keep file
        // (RemovedPhotos.writeKeepRules). No --cleanup-command-error: if a
        // move fails, the export stops and the backup is marked failed.
        // Nothing is deleted either way. Left out entirely when the library
        // couldn't be checked against the backup: new photos are still
        // copied, and nothing is set aside on a guess.
        if source.cleanup {
            arguments += ["--cleanup-command", RemovedPhotos.cleanupCommand]
        }
        arguments += [
            "--sidecar", "XMP",
            "--ramdb",
            "--exportdb", exportDB,
            "--report", report, "--append",
            "--retry", "3",
            "--verbose",
        ]
        return arguments
    }

    // MARK: - The Photos library

    /// Which library the export reads, and whether it may set aside what's
    /// no longer in it.
    struct ExportSource: Equatable, Sendable {
        /// Passed as --library. nil leaves the choice to osxphotos.
        var library: String?
        /// Whether files no longer in the library are moved to Removed from
        /// Photos. Off when the library couldn't be checked.
        var cleanup: Bool
    }

    /// The System Photo Library, checked against the backup before anything
    /// in the backup can be set aside. See PhotosLibrary.
    ///
    /// After the access check, which this needs: where macOS records the
    /// System Photo Library takes Full Disk Access to read.
    func checkPhotosLibrary(_ dest: Destination, _ runLog: RunLog) async throws -> ExportSource {
        let fallback = (Config.defaultPhotosLibrary as NSString).expandingTildeInPath
        let library: String
        if let system = systemLibrary() {
            library = system
        } else if FileManager.default.fileExists(atPath: fallback) {
            runLog.log("macOS didn't say which library is the System Photo Library; using \(fallback).")
            library = fallback
        } else {
            throw BackupError(
                "Kept can't tell which Photos library to back up. Open Photos, then try again.",
                kind: .setupFailed)
        }
        let name = PhotosLibrary.displayName(library)
        runLog.log("Photos library: \(library)")

        let database = PhotosLibrary.database(ofLibrary: library)
        guard FileManager.default.fileExists(atPath: database) else {
            throw BackupError(
                "Kept can't find your Photos library “\(name)”. If it's on a disk that isn't "
                    + "connected, connect it, then try again.",
                kind: .setupFailed)
        }
        if dest.libraryConfirmed == true {
            runLog.log("Backup folder chosen since the last backup; library not compared with the backup.")
            return ExportSource(library: library, cleanup: true)
        }

        let result = await command(
            "/usr/bin/sqlite3",
            PhotosLibrary.overlapArguments(
                libraryDatabase: database, exportDatabase: exportDatabase),
            120, stop)
        try throwIfStopped()
        guard result.status == 0, let overlap = PhotosLibrary.parseOverlap(result.stdout) else {
            // Backed up anyway, without setting anything aside: the check is
            // there to protect the backup, and a backup that copies new
            // photos and retires nothing can't hurt it.
            runLog.log(
                "Couldn't compare the library with the backup (status \(result.status)): "
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            runLog.log("Backing up without moving anything to \(RemovedPhotos.folderName) this time.")
            return ExportSource(library: library, cleanup: false)
        }
        runLog.log(
            "Library has \(overlap.inLibrary) items; \(overlap.shared) of the "
                + "\(overlap.backedUp) photos in the backup are in it.")
        guard !overlap.isDifferentLibrary else {
            let message = overlap.inLibrary == 0
                ? "Your System Photo Library, “\(name)”, has no photos, so Kept left your backup "
                    + "as it was. To back it up anyway, choose your backup folder again in Settings."
                : "Only \(overlap.shared.formatted()) of the \(overlap.backedUp.formatted()) photos "
                    + "in your backup are in your System Photo Library, “\(name)”, so Kept left "
                    + "your backup as it was. To back up “\(name)” from now on, choose your backup "
                    + "folder again in Settings."
            throw BackupError(message, kind: .setupFailed)
        }
        return ExportSource(library: library, cleanup: true)
    }

    // MARK: - Removed photos

    /// Deletes "Removed from Photos" folders past the retention setting, before
    /// the free-space check so the space they free counts. Anything it
    /// couldn't delete is logged and tried again next run.
    ///
    /// In the cleanup helper, a process Stop and a deadline can kill: a share
    /// that stops answering mid-delete otherwise held the backup for good.
    /// Past the deadline the rest waits for the next backup. Fails the backup
    /// only when it was stopped, or killed and still stuck on the share.
    func expireRemovedPhotos(_ dest: Destination, _ runLog: RunLog) async throws {
        let days = RemovedPhotos.retentionDays()
        let result = try await runHelper(
            [RemovedPhotos.expireFlag, "\(days)"], timeout: timing.expiry, dest, runLog)
        if result.timedOut {
            runLog.log(
                "Stopped deleting expired removed photos after "
                    + "\(Int(timing.expiry / 60)) minutes; the rest go next backup.")
        } else if result.status != 0 {
            runLog.log("Couldn't delete expired removed photos (exit \(result.status)).")
        }
    }

    // MARK: - Export

    func runExport(
        _ dest: Destination,
        _ runLog: RunLog,
        source: ExportSource = ExportSource(library: nil, cleanup: true),
        onProgress: @escaping @Sendable (ExportProgress) -> Void,
        onLogTail: @escaping @Sendable ([String]) -> Void
    ) async throws -> ExportProgress {
        var lastStatus: Int32 = -1
        for attempt in 1...Config.exportAttempts {
            try throwIfStopped()
            runLog.log("Starting osxphotos export (attempt \(attempt) of \(Config.exportAttempts))...")

            let (status, progress) = try await runOsxphotos(
                dest, runLog, source: source, onProgress: onProgress, onLogTail: onLogTail)
            lastStatus = status
            if status == 0 { return progress }
            try throwIfStopped()
            if status == Self.linkRefusedStatus {
                // Not tried again: the link is still there. Everything else was
                // copied; the log names the link.
                runLog.log("The export refused a link in the backup folder.")
                throw BackupError(Self.linkRefusedMessage, kind: .setupFailed)
            }

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

    static let linkRefusedMessage =
        "Some photos weren't backed up: part of your backup folder is a link, "
        + "and Kept won't follow it. The log shows where. Remove the link, then try again."

    private func runOsxphotos(
        _ dest: Destination,
        _ runLog: RunLog,
        source: ExportSource,
        onProgress: @escaping @Sendable (ExportProgress) -> Void,
        onLogTail: @escaping @Sendable ([String]) -> Void
    ) async throws -> (status: Int32, progress: ExportProgress) {
        guard let python, let exportGuard, let executable = helper?.path else {
            throw BackupError("Part of Kept is missing. Reinstall it.", kind: .setupFailed)
        }
        try refuseWhileStuck(dest, runLog)
        try await checkOwnFiles(runLog)
        var environment = ChildEnvironment.sanitized()
        environment[RemovedPhotos.executableVariable] = executable
        environment[RemovedPhotos.backupRootVariable] = dest.path
        // The folder again, just before osxphotos is given its path: the
        // checks at the start of the backup were minutes ago.
        let rules = await volumeLane.run(timeout: timing.volumeCall) {
            Result { () throws -> Void in
                if let mismatch = dest.folderMismatch() {
                    throw BackupError(mismatch, kind: .setupFailed)
                }
                try RemovedPhotos.writeKeepRules(
                    backupRoot: URL(filePath: dest.path, directoryHint: .isDirectory))
            }
        }
        guard case .finished(let written) = rules else { throw notResponding(dest, runLog) }
        do {
            try written.get()
        } catch let error as BackupError {
            runLog.log("Refusing to back up: \(error.message)")
            throw error
        }
        // The last suspension before launch. Past it, a Stop reaches the
        // export through the stop signal.
        try throwIfStopped()
        let pipe = Pipe()
        let nothing = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { close(nothing) }
        let child: ChildProcess
        do {
            child = try ChildProcess.launch(
                python.path,
                Self.exportArguments(
                    destinationPath: dest.path, exportGuard: exportGuard.path, source: source),
                environment: environment, directory: workingDirectory,
                stdin: nothing,
                stdout: pipe.fileHandleForWriting.fileDescriptor,
                stderr: pipe.fileHandleForWriting.fileDescriptor)
        } catch {
            throw BackupError("Kept couldn't start the backup: \(error)", kind: .setupFailed)
        }
        // osxphotos and its cleanup commands have their own copies. With
        // this one still open here, the output would never end.
        try? pipe.fileHandleForWriting.close()

        // The output, a line at a time. It ends when the pipe does, or a
        // grace after osxphotos has ended or been killed: a cleanup command
        // stuck on a dead share can hold the pipe open for good, and the
        // read loop below waited on it forever.
        let grace = timing.grace
        let (lines, linesContinuation) = AsyncStream<String>.makeStream()
        let splitter = Mutex(LineSplitter())
        PipeReader.start(
            pipe.fileHandleForReading,
            onData: { chunk in
                for line in splitter.withLock({ $0.lines(in: chunk) }) {
                    linesContinuation.yield(line)
                }
            },
            onEnd: {
                if let rest = splitter.withLock({ $0.rest() }) { linesContinuation.yield(rest) }
                linesContinuation.finish()
            })
        let closeAfterGrace: @Sendable () -> Void = {
            Task {
                try? await Task.sleep(for: grace)
                linesContinuation.finish()
            }
        }
        let stopToken = stop.onStop {
            child.terminate(grace: grace)
            closeAfterGrace()
        }
        defer { stop.remove(stopToken) }
        let reaper = Task {
            guard await child.exitStatus() != nil else { return }
            // Whatever osxphotos left running is not meant to be.
            child.killGroup()
            closeAfterGrace()
        }
        defer { reaper.cancel() }

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
        let pid = child.pid
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

                    // The whole process group: a cleanup command (`sh`, then
                    // `Kept --hold-removed`) inherits the output pipe, and one
                    // left hung on the share would hold it open after osxphotos
                    // is gone. The group takes in one started a moment ago,
                    // which a list of descendants made first could miss.
                    child.terminate(grace: grace)
                    closeAfterGrace()
                    return
                }
            }
        }
        defer { stallWatchdog.cancel() }

        var movedFrom: [String] = []
        do {
            for await line in lines {
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
        }

        // Ended, or killed and given up on after the grace.
        let ended = await child.exitStatus()
        let leftoversEnded = await child.endLeftovers(grace: grace)
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
        }
        guard let status = ended, leftoversEnded else {
            // Killed, and still there: no retry, and nothing else on the
            // folder until it's gone.
            remember(stuck: child)
            try throwIfStopped()
            runLog.log("The export couldn't be ended; it's waiting on the backup folder.")
            throw notResponding(dest, runLog)
        }
        if !movedFrom.isEmpty {
            // In the cleanup helper, which Stop and a deadline can kill. A
            // folder left behind is removed by a later backup that moves
            // something out of it.
            let result = try await runHelper(
                [RemovedPhotos.removeEmptyFlag],
                input: Data(movedFrom.map { $0 + "\n" }.joined().utf8),
                timeout: timing.emptyFolders, dest, runLog)
            if result.timedOut {
                runLog.log(
                    "Stopped removing empty folders after "
                        + "\(Int(timing.emptyFolders / 60)) minutes.")
            }
        }
        onProgress(parser.progress)
        onLogTail(tail)
        return (status, parser.progress)
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

        guard let python, let exportGuard else {
            return "Part of Kept is missing. Reinstall it."
        }
        do {
            try await checkOwnFiles(nil)
        } catch let error as BackupError {
            return error.message
        } catch {
            return "\(error)"
        }
        let result = await ShellCommand.run(
            python.path,
            [
                // Same isolation, and the same launcher, as a real run: see
                // exportArguments.
                "-I", "-B",
                exportGuard.path, tempDir.path,
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
