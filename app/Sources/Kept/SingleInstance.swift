import AppKit
import Foundation

/// One menubar Kept at a time.
///
/// On 2026-10-07 an install replaced Kept.app while the old copy was still
/// running; the old process carried on beside the new one, with the previous
/// code in memory, and would have run that night's backup itself. Two copies
/// also both read-modify-write runs.json. LaunchServices normally prevents a
/// second copy, but not once the bundle on disk has been replaced underneath
/// the first.
///
/// The newest copy wins — it is the one just installed — unless another copy
/// is in the middle of a backup, which it must not interrupt.
enum SingleInstance {
    /// Called before any UI exists. Returns normally when this process should
    /// carry on as the menubar app; exits otherwise.
    static func claim() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).filter { $0.processIdentifier != me && !isGone($0.processIdentifier) }
        guard !others.isEmpty else { return }

        // A backup in flight belongs to whichever copy started it. Leave it be.
        if BackupEngine.livePidHoldingLock() != nil { exit(0) }

        for app in others { app.terminate() }
        if !waitForExit(others, seconds: 10) {
            // Idle, so nothing is lost by not waiting for its consent.
            for app in others where !isGone(app.processIdentifier) { app.forceTerminate() }
            if !waitForExit(others, seconds: 5) { exit(0) }
        }
    }

    private static func waitForExit(_ apps: [NSRunningApplication], seconds: Int) -> Bool {
        let pids = apps.map(\.processIdentifier)
        for _ in 0..<(seconds * 4) {
            if pids.allSatisfy(isGone) { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        }
        return pids.allSatisfy(isGone)
    }

    /// By pid rather than `isTerminated`, which is only updated by
    /// LaunchServices notifications this process isn't set up to receive yet.
    private static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }
}
