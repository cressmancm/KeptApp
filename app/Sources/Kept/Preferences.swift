import Foundation

/// How often the backup runs. `manual` disarms the scheduler entirely; the
/// only way a backup starts then is the Back Up Now button.
enum BackupCadence: String, CaseIterable, Sendable {
    case nightly, weekly, manual

    var label: String {
        switch self {
        case .nightly: "Nightly"
        case .weekly: "Weekly"
        case .manual: "Manually"
        }
    }
}

/// UserDefaults keys and their defaults, in one place.
///
/// Key names are additive on purpose — nothing here renames or migrates an
/// existing key, so an install from before the Kept rename keeps its schedule,
/// destination, and login-item state.
enum Preferences {
    static let notifyOnFailure = "notifyOnFailure"
    static let notifyAlways = "notifyAlways"
    static let cadence = "backupCadence"
    /// 1 = Sunday, matching Calendar's weekday numbering.
    static let weeklyWeekday = "backupWeeklyWeekday"
    static let catchUpEnabled = "catchUpEnabled"

    /// The staleness watchdog: a LaunchAgent that checks how old the last good
    /// backup is, on a schedule launchd owns — so it still fires when Kept
    /// itself is not running, which is precisely when nothing else would notice.
    static let stalenessWarningEnabled = "stalenessWarningEnabled"
    static let stalenessDays = "stalenessDays"
    /// Stamped by every headless run of the check. Proof the LaunchAgent can
    /// actually be spawned — registration alone proved nothing, as five
    /// consecutive EX_CONFIG spawn failures demonstrated.
    static let stalenessLastRun = "stalenessLastRun"

    // Popover disclosure state, so the panel reopens the way it was left.
    static let recentRunsExpanded = "recentRunsExpanded"
    static let liveLogExpanded = "liveLogExpanded"

    /// Set only when the first-run flow is seen through to its last screen.
    /// Until then Kept raises no system permission dialog at all — the flow
    /// exists to explain each one before it appears — and closing the window
    /// early brings it back on the next launch.
    static let hasCompletedOnboarding = "hasCompletedOnboarding"

    /// How long photos deleted from the library stay in the backup's
    /// "Removed from Photos" folder. One of RemovedPhotos.retentionChoices.
    static let removedRetentionDays = "removedRetentionDays"

    /// When the first-run flow was seen through. Scheduled times before it
    /// don't count as missed (Scheduler.fireCatchUpIfMissed).
    static let setupCompletedAt = "setupCompletedAt"

    /// When the daily check was first set up, so "hasn't run yet" can be told
    /// from "hasn't had the chance". The app bundle's date used to stand in,
    /// and a release built days before it was installed warned at once.
    static let stalenessAgentInstalledAt = "stalenessAgentInstalledAt"

    /// Whether Kept asks GitHub once a day for a newer version (UpdateCheck).
    static let checkForUpdates = "checkForUpdates"
    /// When the last check finished, and the newer version it found, if any,
    /// so the panel can say so without asking again after a relaunch.
    static let updateCheckedAt = "updateCheckedAt"
    static let availableUpdateVersion = "availableUpdateVersion"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            notifyOnFailure: true,
            notifyAlways: false,
            cadence: BackupCadence.nightly.rawValue,
            weeklyWeekday: 1,
            catchUpEnabled: true,
            stalenessWarningEnabled: true,
            stalenessDays: 3,
            recentRunsExpanded: false,
            liveLogExpanded: false,
            hasCompletedOnboarding: false,
            removedRetentionDays: RemovedPhotos.defaultRetentionDays,
            checkForUpdates: true,
        ])
    }

    static var currentCadence: BackupCadence { cadence(in: .standard) }

    static func cadence(in defaults: UserDefaults) -> BackupCadence {
        BackupCadence(rawValue: defaults.string(forKey: cadence) ?? "") ?? .nightly
    }
}
