import AppKit
import Foundation
import ServiceManagement

/// Takes Kept off the machine.
///
/// Dragging the app to the Trash is not enough, and what it leaves behind is
/// not harmless: the staleness LaunchAgent keeps firing every morning at a
/// binary that no longer exists, the login item keeps trying to start it, and
/// three state directories survive under ~/Library. This removes all of it, in
/// the one order that works — the login item and the agent go first, while the
/// bundle they refer to is still there for the system to resolve.
///
/// It removes it for the account running it, and only that account. Full Disk
/// Access and network-volume access are granted to the app for the whole Mac,
/// and Kept.app in /Applications is shared too, so taking either away here
/// would break Kept for every other account that uses it. The summary says
/// what was left and why.
///
/// One thing is deliberately never removed: the backup. The mirror is the
/// user's photos and the entire reason this app exists, so uninstalling the
/// tool that made a backup must never be a way to lose one. The destination is
/// not in the plan, there is no parameter that could put it there, and
/// `UninstallTests` holds that line.
@MainActor
enum Uninstall {
    enum Target: Sendable {
        case loginItem
        case launchAgent(plist: URL, label: String)
        /// Kept's privacy permissions: only Automation (driving Finder to mount
        /// a share), which macOS keeps per account, unless Kept.app is going
        /// too. See `tccResetArguments`.
        case permissions(bundleIdentifier: String, allAccounts: Bool)
        case directory(URL)
        /// Everything in the directory except the export database, which the
        /// user chose to keep. See `isExportDatabase`.
        case directoryKeepingExportDatabase(URL)
        case defaultsDomain(String)
        case appBundle(URL)
    }

    struct Item: Sendable {
        /// What the confirmation and the summary call this. Written for the
        /// user, not after the code — "History, report, and backup index"
        /// rather than "Application Support".
        let label: String
        let target: Target

        /// The path to quote when something has to be finished by hand.
        var path: String? {
            switch target {
            case .launchAgent(let plist, _): plist.path
            case .directory(let url), .directoryKeepingExportDatabase(let url),
                .appBundle(let url): url.path
            case .loginItem, .permissions, .defaultsDomain: nil
            }
        }
    }

    /// What the permission reset runs.
    ///
    /// `tccutil reset All` from any account — a standard one included — also
    /// clears Kept's Full Disk Access and network-drive access, which macOS
    /// holds for the whole Mac. Found in testing on 2026-10-05: uninstalling
    /// from a test account silently broke the main account's nightly backup.
    /// So while Kept.app stays for other accounts, only Automation, the one
    /// grant kept per account, is reset.
    ///
    /// When Kept.app goes to the Trash, no account can run Kept, so everything
    /// is reset. Leaving the grants then helped no one and misled: System
    /// Settings hides an entry whose app is gone, so "remove it there" pointed
    /// at nothing, and a reinstall found Full Disk Access already on
    /// (2026-10-06).
    nonisolated static func tccResetArguments(
        bundleIdentifier: String, allAccounts: Bool
    ) -> [String] {
        ["reset", allAccounts ? "All" : "AppleEvents", bundleIdentifier]
    }

    /// Whether this account can move Kept.app to the Trash. /Applications
    /// takes an administrator to change, and in a standard account the app is
    /// almost certainly shared with an admin account that still uses it — so
    /// it is left out of the plan rather than tried and reported as a failure
    /// with "delete this yourself".
    static func canRemoveApp(_ bundleURL: URL? = bundleURLIfApp()) -> Bool {
        guard let folder = bundleURL?.deletingLastPathComponent() else { return false }
        return FileManager.default.isWritableFile(atPath: folder.path)
    }

    /// The bundle, when there is one. A bare `swift run` binary has no bundle
    /// to trash, no login item, and its defaults live in a process-name domain
    /// rather than a bundle-id one — so those steps drop out of the plan
    /// entirely rather than failing loudly at something that was never there.
    static func bundleURLIfApp(_ bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    /// Whether a file in Application Support is part of the export database:
    /// `export.db` itself, or one of SQLite's `export.db-…` companions, which
    /// have to survive alongside it or the database they belong to is torn.
    nonisolated static func isExportDatabase(_ name: String) -> Bool {
        name == "export.db" || name.hasPrefix("export.db-")
    }

    /// Everything to remove, in removal order.
    ///
    /// Every location is injected so the plan can be inspected by a test
    /// without a bundle, a LaunchAgent, or a real ~/Library to delete.
    ///
    /// - Parameter keepExportDatabase: the user's choice in the confirmation.
    ///   The database is what makes nightly runs incremental — about a
    ///   gigabyte, and hours of copying to rebuild — so a reinstall that finds
    ///   it carries on where the old install stopped rather than recopying the
    ///   whole library.
    /// - Parameter removeApp: whether Kept.app goes to the Trash; see
    ///   `canRemoveApp`.
    static func plan(
        bundleURL: URL? = bundleURLIfApp(),
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupport: URL = Config.appSupportDir,
        logs: URL = Config.logDir,
        launchAgentPlist: URL = StalenessAgent.plistURL,
        launchAgentLabel: String = StalenessAgent.label,
        keepExportDatabase: Bool = false,
        removeApp: Bool = canRemoveApp()
    ) -> [Item] {
        var items: [Item] = []
        if bundleURL != nil {
            items.append(Item(label: "Login item", target: .loginItem))
        }
        items.append(
            Item(
                label: "Daily backup check",
                target: .launchAgent(plist: launchAgentPlist, label: launchAgentLabel)))
        if let bundleIdentifier {
            let allAccounts = bundleURL != nil && removeApp
            items.append(
                Item(
                    label: allAccounts ? "Privacy permissions" : "Automation permission",
                    target: .permissions(
                        bundleIdentifier: bundleIdentifier, allAccounts: allAccounts)))
        }
        items.append(
            keepExportDatabase
                ? Item(
                    label: "History and report (backup index kept)",
                    target: .directoryKeepingExportDatabase(appSupport))
                : Item(
                    label: "History, report, and backup index",
                    target: .directory(appSupport)))
        items.append(Item(label: "Logs", target: .directory(logs)))
        if let bundleIdentifier {
            items.append(Item(label: "Settings", target: .defaultsDomain(bundleIdentifier)))
        }
        // Last: every step above either needs the bundle on disk or reads
        // better in a summary before "Kept.app".
        if let bundleURL, removeApp {
            items.append(
                Item(label: "Kept.app (moved to the Trash)", target: .appBundle(bundleURL)))
        }
        return items
    }

    struct Outcome: Sendable {
        struct Failure: Sendable {
            let label: String
            let reason: String
            let path: String?
        }

        var removed: [String] = []
        var failed: [Failure] = []

        var isClean: Bool { failed.isEmpty }
    }

    /// Works through the plan, and keeps going after a failure.
    ///
    /// Stopping at the first error would be the worst outcome available: a
    /// half-removed Kept with its LaunchAgent still loaded is exactly the mess
    /// this exists to prevent. Whatever could not be removed is reported with
    /// its path so the user can finish by hand.
    static func perform(_ plan: [Item]) async -> Outcome {
        var outcome = Outcome()
        for item in plan {
            do {
                try await remove(item.target)
                outcome.removed.append(item.label)
            } catch {
                outcome.failed.append(
                    Outcome.Failure(
                        label: item.label,
                        reason: (error as? UninstallError)?.message ?? error.localizedDescription,
                        path: item.path))
            }
        }
        return outcome
    }

    struct UninstallError: Error {
        let message: String
    }

    private static func remove(_ target: Target) async throws {
        switch target {
        case .loginItem:
            // The async overload, which this context resolves to; the sync one
            // is what `setLaunchAtLogin` calls.
            try await SMAppService.mainApp.unregister()

        case .launchAgent(let plist, let label):
            // bootout first. Deleting the plist alone leaves the job loaded in
            // launchd until the next login, still firing daily at a binary that
            // has gone. A job that was never loaded returns non-zero here and
            // that is not a failure — removing the plist is what has to succeed.
            _ = await ShellCommand.run(
                "/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 20)
            try removeIfPresent(plist)

        case .permissions(let bundleIdentifier, let allAccounts):
            // Scoped to this bundle identifier, so it cannot reach another
            // app's grants. Failure is reported rather than swallowed, because
            // the remedy is manual and the user needs telling.
            let result = await ShellCommand.run(
                "/usr/bin/tccutil",
                tccResetArguments(bundleIdentifier: bundleIdentifier, allAccounts: allAccounts),
                timeout: 20)
            guard result.status == 0 else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw UninstallError(
                    message: stderr.isEmpty ? "tccutil exited \(result.status)" : stderr)
            }

        case .directory(let url):
            try removeIfPresent(url)

        case .directoryKeepingExportDatabase(let url):
            // The one removal that goes inside the folder rather than taking
            // it whole, so it works through open folders and never a link
            // (NoFollow). Listing and deleting by path followed a link: with
            // Application Support/Kept pointing at ~/Documents, keeping the
            // index would have emptied Documents, with Full Disk Access.
            let parentPath = url.deletingLastPathComponent().path
            guard let parent = try? NoFollow.openRoot(parentPath) else { return }
            defer { close(parent) }
            switch NoFollow.kind(of: url.lastPathComponent, in: parent) {
            case .missing: return
            case .link: throw UninstallError(message: "It's a link, so Kept didn't follow it.")
            case .other: throw UninstallError(message: "It isn't a folder.")
            case .directory: break
            }
            let folder: Int32
            do {
                folder = try NoFollow.openDirectory(
                    [url.lastPathComponent], from: parent, creating: false, displayRoot: parentPath)
            } catch let failure as NoFollow.Failure {
                throw UninstallError(message: failure.description)
            }
            defer { close(folder) }
            // Hidden files included: the stale .backup.pid lock is one. Every
            // entry is attempted before reporting, in keeping with `perform` —
            // one stubborn file shouldn't leave the rest behind.
            var firstError: String?
            do {
                for name in try NoFollow.entries(of: folder) where !isExportDatabase(name) {
                    do {
                        try NoFollow.removeTree(name, in: folder)
                    } catch {
                        firstError = firstError ?? String(describing: error)
                    }
                }
            } catch {
                firstError = firstError ?? String(describing: error)
            }
            if let firstError { throw UninstallError(message: firstError) }

        case .defaultsDomain(let name):
            UserDefaults.standard.removePersistentDomain(forName: name)
            // The key that seals the saved backup folder belongs with the
            // settings it seals; left in the keychain it outlives the app.
            let status = SettingsSeal.deleteKey()
            guard status == errSecSuccess else {
                throw UninstallError(
                    message: "Couldn't remove “\(SettingsSeal.service)” from the keychain "
                        + "(\(status))")
            }

        case .appBundle(let url):
            // To the Trash rather than deleted outright: this is the one part of
            // an uninstall someone might regret within the minute, and macOS is
            // happy to move a bundle whose process is still running.
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// Nothing there is a success, not an error — a fresh install that never
    /// wrote a log has no log directory to remove.
    private static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
