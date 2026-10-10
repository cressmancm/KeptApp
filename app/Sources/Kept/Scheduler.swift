import AppKit
import Foundation

/// Fires the backup at the configured time and replicates launchd's
/// missed-job behavior: a scheduled time that passes while the Mac is asleep
/// (or the app isn't running) triggers a catch-up run on wake/launch.
///
/// Cadence widens that to weekly and to manual-only; manual disarms the timer
/// altogether, so `nextFire` is nil and nothing runs unattended.
@MainActor
final class Scheduler {
    static let hourKey = "scheduleHour"
    static let minuteKey = "scheduleMinute"

    var onFire: ((BackupTrigger) -> Void)?
    /// Fired whenever the next fire date is recomputed, so an open window can
    /// follow along — `nextFire` itself is not observable.
    var onRearm: ((Date?) -> Void)?
    private(set) var nextFire: Date?
    private var timerTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [hourKey: 2, minuteKey: 0])
    }

    // Held to valid ranges. The date math below force-unwraps a calendar
    // match, and a stored hour of 25 — a hand edit, a damaged plist — has no
    // match: Kept crashed at launch, every launch. A weekday outside 1...7
    // matched nothing either, and silently made a weekly schedule never fire.
    var scheduledHour: Int { Self.clamped(defaults.integer(forKey: Self.hourKey), 0...23) }
    var scheduledMinute: Int { Self.clamped(defaults.integer(forKey: Self.minuteKey), 0...59) }
    var cadence: BackupCadence { Preferences.cadence(in: defaults) }
    var weeklyWeekday: Int {
        Self.clamped(defaults.integer(forKey: Preferences.weeklyWeekday), 1...7)
    }

    nonisolated static func clamped(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
    var catchUpEnabled: Bool { defaults.bool(forKey: Preferences.catchUpEnabled) }

    func start() {
        rearm()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rearm()
                // Give the network a moment before a catch-up run tries to mount.
                try? await Task.sleep(for: .seconds(Config.wakeGraceSecs))
                self?.fireCatchUpIfMissed()
            }
        }
    }

    func rearm() {
        timerTask?.cancel()
        guard let fire = Self.nextFireDate(
            after: .now, cadence: cadence, weekday: weeklyWeekday,
            hour: scheduledHour, minute: scheduledMinute)
        else {
            // Manual cadence: no timer, and nothing for the UI to promise.
            nextFire = nil
            onRearm?(nil)
            return
        }
        nextFire = fire
        onRearm?(fire)
        timerTask = Task { [weak self] in
            // Capped sleeps: a single long sleep can drift across system sleep,
            // so wake at least hourly and re-check the wall clock.
            while Date.now < fire {
                let remaining = fire.timeIntervalSinceNow
                try? await Task.sleep(for: .seconds(max(1, min(remaining, 3600))))
                if Task.isCancelled { return }
            }
            // Late means the Mac slept through the time and has just woken,
            // and the share was tried before the network was back: that
            // failure cost one of the slot's three tries. The wait is the one
            // a wake gets. After a full wake, the wake observer's rearm
            // cancels this and its catch-up runs instead; after a dark wake,
            // which posts no wake notification, this fires.
            if let grace = Self.graceBeforeFiring(scheduled: fire, now: .now) {
                try? await Task.sleep(for: .seconds(grace))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.onFire?(.scheduled)
            self.rearm()
        }
    }

    /// Catch-up: if the most recent scheduled time has not produced a good
    /// backup, run now.
    ///
    /// A slot counts as serviced only by a **success**. This used to accept any
    /// run that started, mirroring launchd's "don't re-run a job that fired and
    /// failed" — but launchd is scheduling jobs, and this is guarding a backup.
    /// A night that failed leaves the library just as unprotected as a night
    /// that never ran, and on 2026-08-05 that distinction meant plugging in the
    /// next morning did nothing at all, because a failed 02:04 attempt had
    /// "serviced" the 02:00 slot.
    ///
    /// The hour of quiet after a real attempt is what keeps a broken NAS from
    /// turning every wake and every plug-in into another failed run.
    ///
    /// A time that passed before setup finished was never promised, so it
    /// isn't missed. The last setup screen says when the first backup starts,
    /// and without this the first copy, often hours long, started at the next
    /// wake or plug-in instead.
    func fireCatchUpIfMissed(now: Date = .now, history: [RunRecord]? = nil) {
        guard catchUpEnabled else { return }
        guard let lastScheduled = Self.lastFireDate(
            before: now, cadence: cadence, weekday: weeklyWeekday,
            hour: scheduledHour, minute: scheduledMinute)
        else { return }
        if let setupDone = defaults.object(forKey: Preferences.setupCompletedAt) as? Date,
            lastScheduled < setupDone
        {
            return
        }

        let history = history ?? RunHistory.load()
        guard !Self.slotWasServiced(history, since: lastScheduled) else { return }
        // The cap that automatic retries also count against: three tries a
        // slot, then the failure waits for the next one or for the user.
        guard Self.failedAttempts(history, since: lastScheduled) < Config.maxAttemptsPerSlot
        else { return }
        if let lastAttempt = Self.lastCooldownAttempt(history),
            now.timeIntervalSince(lastAttempt) < Config.catchUpCooldownSecs {
            return
        }
        onFire?(.catchUp)
    }

    /// When the last run that counts toward the catch-up cooldown started.
    /// Deferrals are free to retry immediately; only real attempts cool down.
    /// A run stopped for library access never reached the destination, so it
    /// doesn't count either: turning access back on should start the backup.
    nonisolated static func lastCooldownAttempt(_ history: [RunRecord]) -> Date? {
        history.last(where: { $0.outcome != .skipped && $0.failureKind != .libraryAccess })?
            .start
    }

    /// Failed runs since `slot` that count toward its cap. A run stopped for
    /// library access isn't one: it never reached the backup folder, and
    /// turning access back on should start the backup.
    nonisolated static func failedAttempts(_ history: [RunRecord], since slot: Date) -> Int {
        history.filter {
            $0.start >= slot && $0.outcome == .failed && $0.failureKind != .libraryAccess
        }.count
    }

    /// Where the current slot's attempts are counted from: the last scheduled
    /// time, or under Manually, the last backup the user started.
    func attemptWindowStart(_ history: [RunRecord], now: Date = .now) -> Date? {
        Self.lastFireDate(
            before: now, cadence: cadence, weekday: weeklyWeekday,
            hour: scheduledHour, minute: scheduledMinute)
            ?? history.last(where: { $0.trigger == .manual })?.start
    }

    /// The wait before a scheduled backup that fires late, or nil when it
    /// fires on time. A timer that isn't asleep fires within a second or two.
    nonisolated static func graceBeforeFiring(scheduled: Date, now: Date) -> TimeInterval? {
        now.timeIntervalSince(scheduled) > 60 ? Config.wakeGraceSecs : nil
    }

    nonisolated static func slotWasServiced(
        _ history: [RunRecord], since scheduled: Date
    ) -> Bool {
        history.contains { $0.start >= scheduled && $0.outcome == .success }
    }

    // MARK: - Pure date math (testable)

    /// nil when the cadence is manual — there is no next fire.
    nonisolated static func nextFireDate(
        after date: Date, cadence: BackupCadence, weekday: Int,
        hour: Int, minute: Int, calendar: Calendar = .current
    ) -> Date? {
        switch cadence {
        case .manual:
            return nil
        case .nightly:
            return nextFireDate(after: date, hour: hour, minute: minute, calendar: calendar)
        case .weekly:
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute, weekday: weekday),
                matchingPolicy: .nextTime,
                direction: .forward)
        }
    }

    nonisolated static func lastFireDate(
        before date: Date, cadence: BackupCadence, weekday: Int,
        hour: Int, minute: Int, calendar: Calendar = .current
    ) -> Date? {
        switch cadence {
        case .manual:
            return nil
        case .nightly:
            return lastFireDate(before: date, hour: hour, minute: minute, calendar: calendar)
        case .weekly:
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute, weekday: weekday),
                matchingPolicy: .nextTime,
                direction: .backward)
        }
    }

    nonisolated static func nextFireDate(
        after date: Date, hour: Int, minute: Int, calendar: Calendar = .current
    ) -> Date {
        calendar.nextDate(
            after: date,
            matching: DateComponents(hour: hour, minute: minute),
            matchingPolicy: .nextTime,
            direction: .forward)!
    }

    nonisolated static func lastFireDate(
        before date: Date, hour: Int, minute: Int, calendar: Calendar = .current
    ) -> Date {
        calendar.nextDate(
            after: date,
            matching: DateComponents(hour: hour, minute: minute),
            matchingPolicy: .nextTime,
            direction: .backward)!
    }
}
