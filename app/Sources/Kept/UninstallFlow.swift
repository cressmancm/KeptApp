import AppKit
import Foundation

/// Settings → Advanced → Remove Kept: the confirmation, the removal, the
/// summary, and quitting.
///
/// A menubar app that registers a login item and a LaunchAgent has no
/// Installer to undo it, and the obvious move — drag it to the Trash — is the
/// one that leaves launchd firing daily at a missing binary. So the app has to
/// know how to remove itself. What it removes is in Uninstall.
@MainActor
enum UninstallFlow {
    /// Returns without changing anything if a backup is running or the user
    /// cancels. Otherwise calls `willRemove`, removes Kept, and quits.
    static func run(
        destination: Destination?, backupIsRunning: Bool, willRemove: () -> Void
    ) async {
        // build.sh refuses for the same reason: taking the app away mid-export
        // kills osxphotos, loses the run, and leaves the mirror half-updated.
        // The lock file is checked as well, so a run started by another copy
        // of Kept also counts.
        guard !backupIsRunning, BackupEngine.livePidHoldingLock() == nil else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "A backup is running"
            alert.informativeText =
                "Wait for it to finish, or stop it from the menubar, then try again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        // Decided once, so the confirmation, the plan and the summary agree.
        let removeApp = Uninstall.canRemoveApp()
        // Asked before the confirmation, so the answer can't be one that
        // deletes the backup.
        if let holder = Uninstall.itemHolding(
            backup: destination?.path,
            in: Uninstall.plan(keepExportDatabase: false, removeApp: removeApp))
        {
            let name = if case .appBundle = holder.target { "Kept.app" } else {
                "Kept's \(holder.label.lowercased())"
            }
            backupInsideAlert(backup: destination?.path ?? "", holder: name).runModal()
            return
        }
        let confirmation = confirmAlert(destination: destination, removeApp: removeApp)
        guard confirmation.alert.runModal() == .alertSecondButtonReturn else { return }
        let keepExportDatabase = confirmation.keepExportDatabase?.state == .on

        // The caller stops starting backups from here on. The summary alert
        // below runs a modal loop, which services timers — so without this a
        // scheduled slot landing in those few seconds would start a backup into
        // the state directory that was just deleted.
        willRemove()
        // The Settings window saves its frame into the defaults domain when it
        // closes, and it used to close after the domain was deleted, which
        // brought the domain back with that one key. Closed first now.
        for window in NSApp.windows where window.isVisible { window.close() }
        let outcome = await Uninstall.perform(
            Uninstall.plan(keepExportDatabase: keepExportDatabase, removeApp: removeApp),
            protecting: destination?.path)

        summaryAlert(
            outcome, destination: destination, keptExportDatabase: keepExportDatabase,
            removedApp: removeApp
        ).runModal()
        // Again, flushed to disk: the alert is a window too, and AppKit can
        // write state on the way out.
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            CFPreferencesAppSynchronize(bundleIdentifier as CFString)
        }
        NSApp.terminate(nil)
    }

    /// Refusal when the backup folder is inside something removing Kept
    /// deletes. A static builder so the review tools can show it.
    static func backupInsideAlert(backup: String, holder: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Kept can't remove itself yet"
        alert.informativeText = """
            Your backup folder is inside \(holder), which removing Kept deletes:
            \(backup)

            Choose a different backup folder in Settings, or move this one, then try again.
            """
        alert.addButton(withTitle: "OK")
        return alert
    }

    /// The confirmation, plus the checkbox that decides the export database's
    /// fate — nil when there is no database to keep.
    ///
    /// Asked rather than decided: deleting it is what "remove Kept" promises
    /// and leaves nothing behind, but it is also about a gigabyte that takes
    /// hours of copying to rebuild, and someone reinstalling to fix a broken
    /// install would want it kept. Off by default, so the button still does
    /// what it says.
    private static func confirmAlert(
        destination: Destination?, removeApp: Bool
    ) -> (alert: NSAlert, keepExportDatabase: NSButton?) {
        let exportDBSize = (try? Config.exportDBURL.resourceValues(forKeys: [.fileSizeKey]))?
            .fileSize

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Remove Kept from this Mac?"
        var text = removeApp
            ? "Kept moves to the Trash, and its settings, history, logs, and permissions are deleted.\n"
            : """
                Kept's settings, history, and logs are deleted from this account. \
                Kept.app stays in Applications: removing it needs an administrator.

                """
        text += destination.map { "\nYour backup folder stays as it is:\n\($0.path)" }
            ?? "\nYour backup folder stays as it is."
        var checkbox: NSButton?
        if let exportDBSize {
            text += """


                Planning to reinstall? Keep the backup index, or the next backup \
                starts over from scratch.
                """
            let box = NSButton(
                checkboxWithTitle:
                    "Keep the backup index (\(RunFormatting.bytes(Int64(exportDBSize))))",
                target: nil, action: nil)
            box.state = .off
            box.sizeToFit()
            alert.accessoryView = box
            checkbox = box
        }
        alert.informativeText = text
        // Cancel first, as in the folder-picker warning, and for a stronger
        // reason here: NSAlert makes the first button added both the rightmost
        // one and the Return default. That puts the safe answer under the
        // return key AND under a fast click on the button macOS trains people
        // to aim for. Reordering these means reworking the caller's
        // return-code check.
        alert.addButton(withTitle: "Cancel")
        let remove = alert.addButton(withTitle: "Remove Kept")
        remove.hasDestructiveAction = true
        return (alert, checkbox)
    }

    private static func summaryAlert(
        _ outcome: Uninstall.Outcome, destination: Destination?, keptExportDatabase: Bool,
        removedApp: Bool
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = outcome.isClean ? .informational : .warning
        alert.messageText = switch (outcome.isClean, removedApp) {
        case (true, true): "Kept was removed."
        case (true, false): "Kept was removed from this account."
        case (false, _): "Kept was removed, but some items were left behind."
        }

        // No list of what was removed: on a clean removal it is noise, and the
        // title already says it. Only what's left over, and why, is worth
        // reading. The Quit button says the rest.
        var paragraphs: [String] = []
        // Never "delete these yourself" for a folder the backup is in.
        let toDelete = outcome.failed.filter { $0.reason != Uninstall.leftForBackup }
        let leftForBackup = outcome.failed.filter { $0.reason == Uninstall.leftForBackup }
        if !leftForBackup.isEmpty {
            paragraphs.append("Kept left these, because your backup is in them:\n"
                + leftForBackup.map { "• \($0.label)\n  \($0.path ?? "")" }.joined(separator: "\n"))
        }
        if !toDelete.isEmpty {
            // Named with their paths: a partial uninstall the user cannot see
            // is worse than one they can finish in the Finder.
            paragraphs.append("Delete these yourself:\n"
                + toDelete.map { failure in
                    var line = "• \(failure.label): \(failure.reason)"
                    if let path = failure.path { line += "\n  \(path)" }
                    return line
                }.joined(separator: "\n"))
        }
        // "“Kept”" — the name the summary promises survived. The confirmation
        // gives the full path instead, on a line of its own: wrapped inside a
        // sentence, a long path left its closing parenthesis alone on a line.
        let folderName = destination.map { "“\($0.displayName)”" } ?? "your backup folder"
        var backup = "Your backup in \(folderName) wasn't touched."
        // Checked on disk rather than assumed from the choice: this sentence
        // tells the user where a gigabyte is, so it has to be true.
        if keptExportDatabase,
            FileManager.default.fileExists(atPath: Config.exportDBURL.path) {
            let folder = (Config.appSupportDir.path as NSString).abbreviatingWithTildeInPath
            backup += " The backup index stays in \(folder) for a reinstall."
        }
        paragraphs.append(backup)
        // With Kept.app gone its permissions went too; with it staying, they
        // stay with it, since every account shares them
        // (Uninstall.tccResetArguments).
        if !removedApp {
            paragraphs.append(
                "Kept.app and its Privacy & Security settings are shared by every "
                    + "account, so they stay. An administrator can remove them.")
        }
        alert.informativeText = paragraphs.joined(separator: "\n\n")
        alert.addButton(withTitle: "Quit")
        return alert
    }
}
