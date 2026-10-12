import AppKit
import Foundation

/// Choosing the backup folder: the open panel, the checks a folder has to
/// pass, and the alerts that say why one didn't.
@MainActor
enum DestinationPicker {
    /// Shows the open panel. Returns the folder if it passed every check and
    /// the user confirmed any warning, else nil.
    ///
    /// The backup folder is a mirror, not a folder that also holds a backup:
    /// anything else in it is moved aside and later deleted. Pointed at a home
    /// or system folder, a Photos library or a whole cloud drive, that loses
    /// someone's files, so those are refused outright rather than warned
    /// about. A folder with files in it gets a warning.
    static func choose(current: Destination?, retentionDays: Int) -> Destination? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use for Backup"
        panel.message = "Choose a folder for your backup."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let picked = Destination.from(folder: url)
        if Destination.isUnsafeMirrorRoot(path: picked.path, resolvingLinks: true) {
            unsafeMirrorRootAlert(for: picked.displayName).runModal()
            return nil
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if let refusal = Destination.refusal(path: picked.path, entries: entries)
            ?? Destination.refusal(path: url.resolvingSymlinksInPath().path)
        {
            unsafeMirrorRootAlert(for: picked.displayName, refusal: refusal).runModal()
            return nil
        }

        // By path: choosing the current folder again only refreshes what Kept
        // knows about its disk, and isn't a new folder to warn about.
        if picked.path != current?.path, !Destination.isEffectivelyEmpty(entries: entries) {
            let answer = nonEmptyFolderAlert(for: picked, retentionDays: retentionDays).runModal()
            guard answer == .alertSecondButtonReturn else { return nil }
        }
        return picked
    }

    /// Runs the reconnect once, now, while someone is at the Mac.
    ///
    /// Reconnecting a share is an Apple Event, and macOS asks before an app
    /// may send one. Left to the first night the share has dropped, that
    /// prompt would appear at 2 AM with nobody to answer it, and the backup
    /// would fail. The share is mounted (it was just picked), so reconnecting
    /// changes nothing; it only raises the prompt, if there is one, here.
    static func askToReconnectWhileAttended(_ smbURL: String, name: String) async {
        guard Bundle.main.bundleURL.pathExtension == "app",
            Destination.isWellFormedSMBURL(smbURL)
        else { return }
        let result = await ShellCommand.run(
            "/usr/bin/osascript", BackupEngine.mountScriptArguments(smbURL), timeout: 120)
        guard BackupEngine.isAutomationDenied(result.stderr) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if cantReconnectAlert(for: name).runModal() == .alertFirstButtonReturn {
            openAutomationSettings()
        }
    }

    static func cantReconnectAlert(for name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Kept can't reconnect “\(name)” on its own"
        alert.informativeText =
            "If it disconnects, backups will fail until you connect it in the Finder. "
            + "Turn on Kept in Automation to fix this."
        alert.addButton(withTitle: "Open Automation Settings")
        alert.addButton(withTitle: "Not Now")
        return alert
    }

    /// The folder couldn't be saved with its seal, because the keychain is
    /// locked or refused. Nothing changed, and the alert says where backups
    /// still go.
    static func cantSaveAlert(for name: String, previous: Destination? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Kept couldn't save “\(name)” as the backup folder"
        alert.informativeText = if let previous {
            "Your keychain didn't allow it. Backups still go to “\(previous.displayName)”."
        } else {
            "Your keychain didn't allow it. Try again."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        return alert
    }

    static func openAutomationSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        {
            NSWorkspace.shared.open(url)
        }
    }

    /// Refusal for a folder the mirror would empty out. Built here rather
    /// than inline so the review tools can show it without anyone having to
    /// aim the picker at their home folder to find out what it says.
    static func unsafeMirrorRootAlert(
        for name: String, refusal: Destination.Refusal? = nil
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(name)” can't be the backup folder"
        alert.informativeText = switch refusal {
        case nil:
            "Kept removes anything in the backup folder that isn't from your "
                + "library, so system and home folders aren't safe. Create a new "
                + "folder for it."
        case .insidePhotosLibrary:
            "It's inside a Photos library. Choose a folder outside the library."
        case .holdsPhotosLibrary:
            "It has a Photos library in it, which Kept would move out of the "
                + "folder. Create a new folder for the backup."
        case .cloudFolder:
            "Kept would move the files already in it, and the change would sync "
                + "to your other devices. Create a new folder for the backup."
        }
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        return alert
    }

    /// The "this folder is not empty" confirmation. Cancel is added first,
    /// which makes it the default button, so Return never accepts a folder
    /// whose contents Kept will move. "Use This Folder" is the second button;
    /// reordering these means reworking the caller's return-code check.
    static func nonEmptyFolderAlert(for picked: Destination, retentionDays: Int) -> NSAlert {
        let alert = NSAlert()
        alert.messageText =
            "Use “\(picked.displayName)”\(hostClause(picked)) as your backup folder?"
        alert.informativeText = """
            This folder isn't empty. Kept will move anything in it that isn't \
            from your library to “\(RemovedPhotos.folderName)” and delete it after \
            \(retentionDays) days. Continue only if it's an old Kept backup \
            or you don't need what's in it.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use This Folder")
        return alert
    }

    /// " on nas.local" for a network share, empty for a local disk — the design
    /// asks for the host in the alert so two same-named folders can be told apart.
    private static func hostClause(_ destination: Destination) -> String {
        guard destination.isNetwork,
            let smbURL = destination.smbURL,
            let host = URL(string: smbURL)?.host()
        else { return "" }
        return " on \(host)"
    }
}
