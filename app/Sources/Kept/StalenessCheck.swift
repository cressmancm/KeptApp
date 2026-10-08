import AppKit
import Foundation
import UserNotifications

/// The headless half of the app: `Kept --staleness-check`.
///
/// Kept can only report a problem while it is running, and the failures that
/// matter most are the ones where it isn't — quit by hand, killed by an
/// installer, never relaunched after a reboot. Twice in one week a backup was
/// silently skipped and nothing said so until someone thought to look.
///
/// A LaunchAgent runs this daily. launchd owns the schedule, so it fires
/// whether or not the menubar app is alive, and runs a missed calendar
/// interval on wake rather than skipping it. The process reads the run
/// history, posts a notification if the last good backup is older than the
/// threshold, and exits. It deliberately does not start the app, launch a
/// backup, or touch any state — the notification carries a "Launch Kept"
/// button so that stays the user's decision.
enum StalenessCheck {
    static let categoryIdentifier = "keptStaleBackup"
    static let launchActionIdentifier = "keptLaunchApp"

    /// Notification category shared by this check and the running app, so the
    /// "Launch Kept" button is registered whichever process posts.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: launchActionIdentifier,
                    title: "Open Kept",
                    // .foreground is what makes tapping start the app: macOS
                    // launches the bundle to deliver the response.
                    options: [.foreground])
            ],
            intentIdentifiers: [],
            options: [])
    }

    /// Entry point for the `--staleness-check` invocation. Never returns.
    static func runAndExit() -> Never {
        Preferences.registerDefaults()
        let defaults = UserDefaults.standard

        // Stamped before anything can return early, so it records "launchd
        // successfully started this", not "this had something to report".
        // Settings watches the age of this timestamp; a watchdog that cannot
        // be spawned is otherwise indistinguishable from a quiet one.
        defaults.set(Date.now, forKey: Preferences.stalenessLastRun)

        guard defaults.bool(forKey: Preferences.stalenessWarningEnabled) else {
            exit(0)
        }
        let threshold = max(1, defaults.integer(forKey: Preferences.stalenessDays))

        guard let message = staleMessage(
            history: RunHistory.load(), thresholdDays: threshold)
        else {
            exit(0)
        }

        // UNUserNotificationCenter delivers asynchronously; a process that
        // exits immediately after add() can lose the notification, so wait for
        // the callback (bounded, so a wedged notification daemon can't hang a
        // launchd job forever).
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])

        let content = KeptNotification.content(.stale(message: message))

        let done = DispatchSemaphore(value: 0)
        center.add(
            UNNotificationRequest(
                identifier: "staleness-\(threshold)", content: content, trigger: nil)
        ) { _ in done.signal() }
        _ = done.wait(timeout: .now() + 10)
        exit(0)
    }

    /// The notification body, or nil when the backup is recent enough to stay
    /// quiet. Pure, so the thresholds are testable without a notification
    /// daemon or a launchd job.
    static func staleMessage(
        history: [RunRecord], thresholdDays: Int, now: Date = .now,
        calendar: Calendar = .current
    ) -> String? {
        guard let lastSuccess = history.last(where: { $0.outcome == .success }) else {
            // Nothing has ever succeeded. Only worth saying once the app has
            // had a chance to try — a fresh install with no destination yet
            // should not start nagging.
            guard !history.isEmpty else { return nil }
            return "No backup has finished yet."
        }

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: lastSuccess.start),
            to: calendar.startOfDay(for: now)).day ?? 0
        guard days >= thresholdDays else { return nil }

        let age = days == 1 ? "1 day" : "\(days) days"
        return "The last good backup was \(age) ago."
    }
}
