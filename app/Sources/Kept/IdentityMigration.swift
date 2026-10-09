import Foundation

/// The one-time move from Kept's first bundle identifier, com.chip.Kept, to
/// com.chipcressman.Kept, a domain the developer owns (2026-10-09, before the
/// identifier was registered with Apple).
///
/// The backup index, history, report and logs live in folders named "Kept",
/// so they carry over by themselves: the next backup to the same folder picks
/// up where the last one stopped. What's keyed to the identifier has to be
/// moved or redone:
///
/// - Preferences are copied across, except what must be set up again: the
///   backup folder (its seal was made with a key the new identity can't
///   read without a keychain prompt), "setup done" (so setup runs again,
///   which is how Full Disk Access gets turned on for the new identity), and
///   "login item registered" (so it's registered under the new one).
/// - The old daily-check job is stopped and its file deleted, or it would go
///   on running beside the new one.
/// - The old identity's privacy permissions are reset, so System Settings
///   doesn't list a Kept that's switched on but no longer exists.
///
/// Left behind, because the new identity can't remove them without a prompt:
/// the old login item entry, which macOS drops on its own once nothing with
/// that identifier is installed, and the old settings key in the login
/// keychain (a 32-byte item named "Kept settings seal" under
/// com.chip.Kept.settings-seal), which nothing reads any more.
enum IdentityMigration {
    static let oldIdentifier = "com.chip.Kept"
    static let oldStalenessLabel = "com.chip.Kept.staleness"

    /// Preferences that are not carried over. See the type's comment.
    static let notCarried: Set<String> = [
        DestinationStore.key, DestinationStore.sealKey,
        Preferences.hasCompletedOnboarding, "didRegisterLoginItem",
    ]

    /// Runs in the menubar app, before anything reads preferences. Does
    /// nothing once the old preferences are gone, which is after its first run.
    /// Only from a real Kept.app: the old preferences are on disk whatever is
    /// running, and a test or `swift run` must never move or delete them.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleURL.pathExtension == "app",
            Bundle.main.bundleIdentifier != oldIdentifier,
            let old = defaults.persistentDomain(forName: oldIdentifier), !old.isEmpty
        else { return }
        for (key, value) in carriedPreferences(old) where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.removePersistentDomain(forName: oldIdentifier)

        let uid = getuid()
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(oldStalenessLabel)"])
        try? FileManager.default.removeItem(
            at: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/LaunchAgents/\(oldStalenessLabel).plist"))
        run("/usr/bin/tccutil", ["reset", "All", oldIdentifier])
    }

    static func carriedPreferences(_ old: [String: Any]) -> [String: Any] {
        old.filter { !notCarried.contains($0.key) }
    }

    private static func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = ChildEnvironment.sanitized()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
