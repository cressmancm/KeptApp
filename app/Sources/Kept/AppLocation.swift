import AppKit
import Foundation

/// Moves a Kept opened straight from its download into Applications.
///
/// macOS runs a downloaded app that hasn't been moved from a random read-only
/// copy (App Translocation), and that copy's path is what Kept would record:
/// the daily check's LaunchAgent and the login item would point at a folder
/// that is gone after the next restart, and the backup would stop with nothing
/// to say so. So before anything is registered, a translocated Kept offers to
/// move itself to Applications and reopen from there. Opening a newer download
/// this way is also how an existing copy gets updated.
enum AppLocation {
    static let destination = URL(filePath: "/Applications/Kept.app", directoryHint: .isDirectory)

    /// Whether this copy is running translocated.
    static var isTranslocated: Bool {
        isTranslocated(path: Bundle.main.bundlePath)
    }

    static func isTranslocated(path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    /// Runs before any other UI and never returns: either this copy moved
    /// itself and opened the moved copy, or the user chose to quit.
    @MainActor
    static func offerMoveAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        guard let original = originalURL() else {
            // No way to find the download: say what to do by hand.
            showManualMove(original: nil)
            exit(0)
        }

        let replacing = FileManager.default.fileExists(atPath: destination.path)
        let alert = NSAlert()
        alert.messageText = "Move Kept to Applications?"
        alert.informativeText = replacing
            ? "Kept needs to be in Applications to back up every night. It will "
                + "replace the copy that's there and open again."
            : "Kept needs to be in Applications to back up every night. It will "
                + "move itself there and open again."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { exit(0) }

        do {
            if replacing {
                // Moving over the running copy mid-backup would end its backup.
                if BackupEngine.livePidHoldingLock() != nil {
                    busyAlert().runModal()
                    exit(0)
                }
                quitCopies(at: destination)
                // To the Trash, not deleted: the old copy can still be put back.
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.moveItem(at: original, to: destination)
        } catch {
            // Usually a standard account, which can't write to Applications.
            showManualMove(original: original)
            exit(0)
        }

        // The quarantine flag came with the download. Left on the moved copy,
        // macOS would translocate it again, and this alert would come back
        // every launch. Gatekeeper already checked this copy to open it.
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        run("/usr/bin/open", ["-n", destination.path])
        exit(0)
    }

    /// The download this translocated copy was made from. Uses the Security
    /// framework call LaunchServices itself uses, looked up at run time since
    /// it isn't in the public headers.
    static func originalURL() -> URL? {
        typealias OriginalPath = @convention(c) (
            CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFURL>?
        // For a copy that isn't translocated the call just hands back its own
        // location, which isn't a download to move.
        guard isTranslocated,
            let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
            let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL")
        else { return nil }
        let originalPath = unsafeBitCast(symbol, to: OriginalPath.self)
        guard let url = originalPath(Bundle.main.bundleURL as CFURL, nil)?.takeRetainedValue() as URL?,
            url.pathExtension == "app", !isTranslocated(path: url.path),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// For when Kept can't move itself: says how, and offers to show the
    /// download in the Finder when it knows where that is.
    @MainActor
    private static func showManualMove(original: URL?) {
        let alert = NSAlert()
        alert.messageText = "Move Kept to Applications"
        guard let original else {
            alert.informativeText = "Kept needs to be in Applications to back up every night. "
                + "Drag it there in the Finder, then open it from Applications."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            return
        }
        alert.informativeText = "Kept couldn't move itself. Drag it to Applications in the "
            + "Finder, then open it from there."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([original])
        }
    }

    @MainActor
    private static func busyAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "A backup is running"
        alert.informativeText =
            "Open this copy of Kept again when the backup finishes, and it will replace the one in Applications."
        alert.addButton(withTitle: "OK")
        return alert
    }

    /// Asks every copy of Kept running from `bundle` to quit, then insists.
    private static func quitCopies(at bundle: URL) {
        let running = [
            Bundle.main.bundleIdentifier ?? "com.chipcressman.Kept", IdentityMigration.oldIdentifier,
        ]
        .flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
        .filter { $0.bundleURL?.standardizedFileURL == bundle.standardizedFileURL }
        // By pid, as in SingleInstance: `isTerminated` isn't kept up to date
        // this early in launch.
        func isGone(_ app: NSRunningApplication) -> Bool {
            kill(app.processIdentifier, 0) != 0 && errno == ESRCH
        }
        for app in running { app.terminate() }
        for _ in 0..<40 where !running.allSatisfy(isGone) {
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        }
        for app in running where !isGone(app) { app.forceTerminate() }
        for _ in 0..<20 where !running.allSatisfy(isGone) {
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = ChildEnvironment.sanitized()
        try? process.run()
        process.waitUntilExit()
    }
}
