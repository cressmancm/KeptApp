#if KEPT_REVIEW_TOOLS
import Foundation

/// One reviewable state of the app, selectable from Settings → Advanced.
///
/// The panel has six top-level states and several of them have copy that only
/// appears under conditions you cannot conjure on demand — a full disk, an
/// unreachable share, a library that hasn't been copied in nine days. Waiting
/// for those to happen is not a review process, and faking them by editing
/// runs.json means editing the real history of a real backup. This enumerates
/// them instead.
///
/// The order here is the order of the picker.
enum PreviewScenario: String, CaseIterable, Identifiable, Sendable {
    // Setup
    case firstRun
    case accessBlocked
    case readyNoRuns
    // Healthy
    case healthy
    case healthyLongGap
    case partialBackup
    case damagedBackup
    case mixedHistory
    // Running
    case runningStarting
    case runningScanning
    case runningExporting
    case runningCleaning
    case runningFinishing
    // Trouble
    case volumeUnreachable
    case diskFull
    case exportFailed
    case runCancelled
    case unmappedFailure
    case waitingForPower

    var id: String { rawValue }

    /// Picker sections, so eighteen states don't arrive as one flat list.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case setup = "Setup"
        case healthy = "Healthy"
        case running = "Running"
        case trouble = "Trouble"

        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .firstRun, .accessBlocked, .readyNoRuns: .setup
        case .healthy, .healthyLongGap, .partialBackup, .damagedBackup, .mixedHistory: .healthy
        case .runningStarting, .runningScanning, .runningExporting,
            .runningCleaning, .runningFinishing: .running
        case .volumeUnreachable, .diskFull, .exportFailed, .runCancelled,
            .unmappedFailure, .waitingForPower: .trouble
        }
    }

    /// Names the screen, not the enum case — this is what the picker shows.
    var label: String {
        switch self {
        case .firstRun: "No backup folder yet"
        case .accessBlocked: "Library access blocked"
        case .readyNoRuns: "Ready, nothing has run"
        case .healthy: "Backed up, recent"
        case .healthyLongGap: "Backed up, nine days ago"
        case .partialBackup: "Backed up, some not copied"
        case .damagedBackup: "Backed up, spot-check found damage"
        case .mixedHistory: "Every run outcome"
        case .runningStarting: "Running · starting"
        case .runningScanning: "Running · reading library"
        case .runningExporting: "Running · exporting"
        case .runningCleaning: "Running · cleaning up"
        case .runningFinishing: "Running · finishing"
        case .volumeUnreachable: "Failed · volume unreachable"
        case .diskFull: "Failed · disk full"
        case .exportFailed: "Failed · export stopped"
        case .runCancelled: "Stopped by you"
        case .unmappedFailure: "Failed · raw engine message"
        case .waitingForPower: "Waiting for power"
        }
    }

    /// One line under the picker saying what is worth looking at here — the
    /// states differ by a sentence in places, and the difference is the point.
    var note: String {
        switch self {
        case .firstRun: "The first-run panel, before a destination exists."
        case .accessBlocked: "The paused panel with its Full Disk Access step."
        case .readyNoRuns: "Destination set, no history — the neutral status row."
        case .healthy: "The everyday panel, with a week of good backups."
        case .healthyLongGap: "Same panel, stale copy. Nothing recent in the list."
        case .partialBackup: "Finished, but some files failed to copy."
        case .damagedBackup: "Finished, but older copies didn't match the library."
        case .mixedHistory: "Recent backups expanded over success, failure, stop, skip, interrupt."
        case .runningStarting: "Indeterminate bar, no counts announced yet."
        case .runningScanning: "The silent stretch before the first export line."
        case .runningExporting: "Determinate bar, filename, percentage, time remaining."
        case .runningCleaning: "Back to indeterminate — --cleanup deleting strays."
        case .runningFinishing: "Writing export.db back."
        case .volumeUnreachable: "Names the share and the time it went missing."
        case .diskFull: "The one failure the user fixes with a delete, not a cable."
        case .exportFailed: "Retry promised without naming a time."
        case .runCancelled: "The user stopped it; nothing broke."
        case .unmappedFailure: "Engine text shown verbatim — never parsed as markdown."
        case .waitingForPower: "Deferred on battery. Not a failure, and says so."
        }
    }
}

/// Builds the state each scenario stands for.
///
/// Everything here is synthetic and lives in memory only. No run is written to
/// runs.json, no preference is touched, and quitting Kept ends the preview —
/// the panel must never be able to outlive the session that faked it.
@MainActor
enum StatePreview {
    struct Snapshot {
        var scenario: PreviewScenario
        var status: BackupController.Status
        var history: [RunRecord] = []
        var logTail: [String] = []
        /// Stands in for the live extrapolation, which needs a real run's start
        /// time to compute anything.
        var estimatedTimeRemaining: TimeInterval?
        /// Shown only when no real destination is configured, so the panels that
        /// name a drive still read correctly on a machine that isn't set up.
        var destination: Destination?
    }

    /// A plausible NAS, used only as a fallback (see `Snapshot.destination`).
    static let sampleDestination = Destination(
        path: "/Volumes/PhotoBackup/Kept",
        isNetwork: true,
        smbURL: "smb://user@nas.local/PhotoBackup",
        mountPoint: "/Volumes/PhotoBackup")

    static func snapshot(for scenario: PreviewScenario, now: Date = .now) -> Snapshot {
        switch scenario {
        case .firstRun:
            return Snapshot(scenario: scenario, status: .needsDestination)

        case .accessBlocked:
            return Snapshot(
                scenario: scenario, status: .needsPhotosAccess,
                history: goodWeek(now: now), destination: sampleDestination)

        case .readyNoRuns:
            return Snapshot(
                scenario: scenario, status: .idle, destination: sampleDestination)

        case .healthy:
            return Snapshot(
                scenario: scenario, status: .idle,
                history: goodWeek(now: now), destination: sampleDestination)

        case .healthyLongGap:
            return Snapshot(
                scenario: scenario, status: .idle,
                history: [
                    run(hoursAgo: 10 * 24, outcome: .success, exported: 61, now: now),
                    run(hoursAgo: 9 * 24, outcome: .success, exported: 214, now: now),
                ],
                destination: sampleDestination)

        case .partialBackup:
            var history = goodWeek(now: now)
            history[history.count - 1].errors = 3
            return Snapshot(
                scenario: scenario, status: .idle, history: history,
                destination: sampleDestination)

        case .damagedBackup:
            var history = goodWeek(now: now)
            history[history.count - 1].spotChecked = 20
            history[history.count - 1].damaged = 2
            return Snapshot(
                scenario: scenario, status: .idle, history: history,
                destination: sampleDestination)

        case .mixedHistory:
            return Snapshot(
                scenario: scenario, status: .idle,
                history: [
                    run(hoursAgo: 126, outcome: .success, exported: 41, now: now),
                    run(hoursAgo: 102, outcome: .interrupted, now: now,
                        message: "Kept stopped before this run finished"),
                    run(hoursAgo: 78, outcome: .failed, now: now,
                        message: "Backup volume not reachable",
                        failureKind: .volumeUnreachable),
                    run(hoursAgo: 54, outcome: .skipped, now: now,
                        message: "Skipped — on battery power"),
                    run(hoursAgo: 30, outcome: .cancelled, trigger: .manual, now: now),
                    run(hoursAgo: 6, outcome: .success, exported: 12, deleted: 3, now: now),
                ],
                destination: sampleDestination)

        case .runningStarting:
            return running(scenario, progress: ExportProgress(phase: .starting), now: now)

        case .runningScanning:
            return running(
                scenario, progress: ExportProgress(phase: .scanning), now: now,
                logTail: Array(sampleLog.prefix(2)))

        case .runningExporting:
            var progress = ExportProgress(phase: .exporting)
            progress.current = 12_480
            progress.total = 46_920
            progress.currentItemName = "IMG_5355.HEIC"
            return running(
                scenario, progress: progress, now: now,
                logTail: sampleLog, remaining: 17 * 60)

        case .runningCleaning:
            var progress = ExportProgress(phase: .cleaning)
            // Held at the total on purpose: this is exactly the case the
            // running panel guards against showing as "100% · IMG_5355.HEIC".
            progress.current = 46_920
            progress.total = 46_920
            return running(
                scenario, progress: progress, now: now,
                logTail: sampleLog.suffix(3) + ["Cleaning up /Volumes/PhotoBackup/Kept"])

        case .runningFinishing:
            var progress = ExportProgress(phase: .finishing)
            progress.current = 46_920
            progress.total = 46_920
            progress.exported = 31
            progress.deleted = 6
            return running(
                scenario, progress: progress, now: now,
                logTail: [
                    "Cleaning up /Volumes/PhotoBackup/Kept",
                    "Deleted: 6 files, 0 directories",
                    "Writing export database changes back to export.db",
                ])

        case .volumeUnreachable:
            return failed(
                scenario, kind: .volumeUnreachable,
                message: "Backup volume not reachable after 60s: /Volumes/PhotoBackup/Kept",
                now: now)

        case .diskFull:
            return failed(
                scenario, kind: .diskFull,
                message: "Only 4 GB free on the destination volume; 20 GB required",
                now: now)

        case .exportFailed:
            return failed(
                scenario, kind: .exportFailed,
                message: "osxphotos exited 1 on attempt 2 of 2",
                now: now)

        case .runCancelled:
            return failed(
                scenario, kind: .cancelled, message: "Cancelled", now: now)

        case .unmappedFailure:
            // The verbatim branch of FailureCopy: engine text, rendered as
            // plain text rather than markdown, because runs.json is writable by
            // anything running as this user.
            return failed(
                scenario, kind: .setupFailed,
                message: "Kept couldn't start the backup: You don’t have permission to save the "
                    + "file “kept-2026-09-08.log” in the folder “Kept”.",
                now: now)

        case .waitingForPower:
            var snapshot = Snapshot(
                scenario: scenario, status: .waitingForPower,
                history: goodWeek(now: now), destination: sampleDestination)
            snapshot.history.append(
                run(hoursAgo: 1, outcome: .skipped, now: now,
                    message: "Skipped — on battery power"))
            return snapshot
        }
    }

    // MARK: - Builders

    private static func running(
        _ scenario: PreviewScenario, progress: ExportProgress, now: Date,
        logTail: [String] = [], remaining: TimeInterval? = nil
    ) -> Snapshot {
        var history = goodWeek(now: now)
        // The record a live run writes at its start: no outcome yet, which is
        // what makes the top row of Recent runs read "running…".
        history.append(RunRecord(trigger: .scheduled, start: now.addingTimeInterval(-19 * 60)))
        return Snapshot(
            scenario: scenario, status: .running(progress), history: history,
            logTail: logTail, estimatedTimeRemaining: remaining,
            destination: sampleDestination)
    }

    private static func failed(
        _ scenario: PreviewScenario, kind: FailureKind, message: String, now: Date
    ) -> Snapshot {
        var history = goodWeek(now: now)
        // Drop the most recent success so the panel's "your last good copy is
        // N hours old" line has a gap to describe.
        history.removeLast()
        history.append(
            run(
                hoursAgo: 2, outcome: kind == .cancelled ? .cancelled : .failed,
                trigger: kind == .cancelled ? .manual : .scheduled, now: now,
                message: message, failureKind: kind))
        return Snapshot(
            scenario: scenario, status: .failed(kind, message), history: history,
            destination: sampleDestination)
    }

    /// Six nightly successes, newest last — the shape `RunHistory.load()`
    /// returns, which everything downstream assumes.
    private static func goodWeek(now: Date) -> [RunRecord] {
        (0..<6).reversed().map { night in
            run(
                hoursAgo: Double(6 + night * 24), outcome: .success,
                exported: [12, 4, 0, 137, 8, 21][night], deleted: night == 3 ? 2 : 0,
                now: now)
        }
    }

    private static func run(
        hoursAgo: Double, outcome: RunOutcome?, trigger: BackupTrigger = .scheduled,
        exported: Int? = nil, deleted: Int? = nil, minutes: Double = 33,
        now: Date, message: String? = nil, failureKind: FailureKind? = nil
    ) -> RunRecord {
        let start = now.addingTimeInterval(-hoursAgo * 3600)
        var record = RunRecord(trigger: trigger, start: start)
        record.end = start.addingTimeInterval(minutes * 60)
        record.outcome = outcome
        record.exported = exported
        record.deleted = deleted
        record.message = message
        record.failureKind = failureKind
        record.mirroredCount = outcome == .success ? 46_920 : nil
        // Deliberately no logPath: a preview row must not open a real log, and
        // `openLog` already ignores a record without one.
        return record
    }

    private static let sampleLog = [
        "Exporting IMG_5350.HEIC (A1B2C3D4-0000-0000-0000-000000000001.heic) (12476/46920)",
        "Exporting IMG_5351.HEIC (A1B2C3D4-0000-0000-0000-000000000002.heic) (12477/46920)",
        "Exporting Chad & Sax.jpg (A1B2C3D4-0000-0000-0000-000000000003.jpeg) (12478/46920)",
        "Exporting IMG_5353.MOV (A1B2C3D4-0000-0000-0000-000000000004.mov) (12479/46920)",
        "Exporting IMG_5354.HEIC (A1B2C3D4-0000-0000-0000-000000000005.heic) (12480/46920)",
        "Exporting IMG_5355.HEIC (A1B2C3D4-0000-0000-0000-000000000006.heic) (12481/46920)",
    ]
}
#endif
