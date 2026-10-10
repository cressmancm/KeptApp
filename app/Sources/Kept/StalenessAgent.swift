import Foundation

/// The daily check's LaunchAgent: installing it, removing it, and noticing
/// when launchd isn't running it.
///
/// A plain user LaunchAgent under ~/Library/LaunchAgents, bootstrapped with
/// launchctl, rather than `SMAppService.agent`. That was measured, not
/// assumed: SMAppService validates the registered program against a
/// Team-ID-based code requirement, and Kept was self-signed then, with
/// `TeamIdentifier=not set`. launchd accepted the registration, reported the
/// job `.enabled`, and then refused every spawn with `last exit reason =
/// OS_REASON_CODESIGNING`: five silent failures, and three nights without a
/// backup that nothing reported. Releases are Developer ID signed now, but a
/// contributor's build can still be self-signed, and a plain agent runs under
/// either signature (verified: `last exit code = 0`).
enum StalenessAgent {
    static let label = "com.chipcressman.Kept.staleness"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /// Installs or removes the agent. Returns the problem to show in Settings,
    /// or nil when it's done.
    ///
    /// A failure is shown rather than swallowed: a watchdog that silently
    /// failed to install is worse than none, because the checkbox would claim
    /// protection that isn't there.
    static func apply(enabled: Bool, defaults: UserDefaults = .standard) async -> String? {
        let target = "gui/\(getuid())/\(label)"
        // Always bootout first: bootstrap fails outright if the label is
        // already loaded, so this is what makes reinstalls idempotent.
        _ = await ShellCommand.run("/bin/launchctl", ["bootout", target], timeout: 20)

        guard enabled else {
            try? FileManager.default.removeItem(at: plistURL)
            defaults.removeObject(forKey: Preferences.stalenessAgentInstalledAt)
            return nil
        }

        // The program path comes from the running bundle, not a hardcoded
        // /Applications, so a copy running from anywhere schedules itself.
        guard let executable = Bundle.main.executableURL?.path else {
            return "Could not locate the Kept executable."
        }
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plist(executable: executable).write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        let result = await ShellCommand.run(
            "/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path], timeout: 20)
        guard result.status == 0 else {
            return "launchctl bootstrap failed (\(result.status)) "
                + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The first time only. Kept bootstraps the agent at every launch, and
        // restamping each time would push "hasn't run yet" back forever on a
        // Mac that starts Kept daily.
        if defaults.object(forKey: Preferences.stalenessAgentInstalledAt) == nil {
            defaults.set(Date.now, forKey: Preferences.stalenessAgentInstalledAt)
        }
        return nil
    }

    /// `AssociatedBundleIdentifiers` ties the job to the app in System Settings
    /// → Login Items & Extensions. Without it, Background App Activity listed
    /// Kept twice: the app, and a second "Kept" with a generic exec icon that
    /// was this job.
    static func plist(
        executable: String,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.chipcressman.Kept"
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscaped(executable))</string>
                <string>--staleness-check</string>
            </array>
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key><integer>9</integer>
                <key>Minute</key><integer>0</integer>
            </dict>
            <key>RunAtLoad</key>
            <false/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>\(xmlEscaped(bundleIdentifier))</string>
            </array>
        </dict>
        </plist>
        """
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Complaint text when the check is switched on but launchd is not
    /// actually running it, else nil.
    ///
    /// The check runs daily, so a stamp older than three days means it has
    /// missed at least two firings — the failure that let this app go three
    /// nights without a backup and say nothing. Registration status cannot
    /// detect it: launchd reported the job as `.enabled` the whole time it was
    /// failing to spawn.
    static func staleWarning(
        enabled: Bool, defaults: UserDefaults = .standard, now: Date = .now
    ) -> String? {
        guard enabled else { return nil }
        guard let lastRun = defaults.object(forKey: Preferences.stalenessLastRun) as? Date else {
            // Never run. Only a complaint once it has had two chances to.
            guard let installed = defaults.object(
                forKey: Preferences.stalenessAgentInstalledAt) as? Date,
                now.timeIntervalSince(installed) > 2 * 86_400
            else { return nil }
            return "The daily check hasn't run yet."
        }
        let days = Int(now.timeIntervalSince(lastRun) / 86_400)
        guard days >= 3 else { return nil }
        return "The daily check hasn't run in \(days) days."
    }
}
