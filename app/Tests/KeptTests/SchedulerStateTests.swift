import XCTest

@testable import Kept

/// When catch-up runs, against a scratch preferences suite and a history
/// passed in, so nothing here reads or writes Kept's real state.
@MainActor
final class SchedulerStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var scheduler: Scheduler!
    private var fired: [BackupTrigger] = []

    /// 10:00 today; the nightly slot it follows is 02:00 today.
    private var now: Date { at(hour: 10) }
    private var slot: Date { at(hour: 2) }

    private func at(hour: Int, minute: Int = 0, daysAgo: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: .now)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    override func setUp() async throws {
        defaults = SecurityTests.scratchDefaults(named: "KeptSchedulerStateTests", for: self)
        defaults.set(2, forKey: Scheduler.hourKey)
        defaults.set(0, forKey: Scheduler.minuteKey)
        defaults.set(BackupCadence.nightly.rawValue, forKey: Preferences.cadence)
        defaults.set(true, forKey: Preferences.catchUpEnabled)
        scheduler = Scheduler(defaults: defaults)
        fired = []
        scheduler.onFire = { [weak self] trigger in self?.fired.append(trigger) }
    }

    private func record(
        _ outcome: RunOutcome, hour: Int, minute: Int = 0, kind: FailureKind? = nil,
        trigger: BackupTrigger = .scheduled
    ) -> RunRecord {
        var record = RunRecord(trigger: trigger, start: at(hour: hour, minute: minute))
        record.outcome = outcome
        record.failureKind = kind
        return record
    }

    func testAMissedSlotStartsACatchUp() {
        scheduler.fireCatchUpIfMissed(now: now, history: [])
        XCTAssertEqual(fired, [.catchUp])
    }

    func testAServicedSlotDoesNot() {
        scheduler.fireCatchUpIfMissed(now: now, history: [record(.success, hour: 2, minute: 5)])
        XCTAssertEqual(fired, [])
    }

    /// Three tries a slot, from any trigger, then nothing until the next one.
    func testThreeFailedAttemptsUseUpTheSlot() {
        let failures = [
            record(.failed, hour: 2, minute: 5),
            record(.failed, hour: 3, minute: 10),
            record(.failed, hour: 4, minute: 15),
        ]
        scheduler.fireCatchUpIfMissed(now: now, history: failures)
        XCTAssertEqual(fired, [])

        scheduler.fireCatchUpIfMissed(now: now, history: Array(failures.prefix(2)))
        XCTAssertEqual(fired, [.catchUp])
    }

    /// A run stopped for Full Disk Access never reached the share: it counts
    /// toward neither the cap nor the cooldown, so turning access on starts
    /// the backup.
    func testLibraryAccessFailuresDontCount() {
        let blocked = [
            record(.failed, hour: 2, minute: 5, kind: .libraryAccess),
            record(.failed, hour: 3, minute: 10, kind: .libraryAccess),
            record(.failed, hour: 9, minute: 55, kind: .libraryAccess),
        ]
        scheduler.fireCatchUpIfMissed(now: now, history: blocked)
        XCTAssertEqual(fired, [.catchUp])
    }

    func testARecentAttemptCoolsDown() {
        scheduler.fireCatchUpIfMissed(now: now, history: [record(.failed, hour: 9, minute: 30)])
        XCTAssertEqual(fired, [])
    }

    /// A deferral attempted nothing, so it's free to retry at once.
    func testASkippedRunDoesntCoolDown() {
        scheduler.fireCatchUpIfMissed(now: now, history: [record(.skipped, hour: 9, minute: 55)])
        XCTAssertEqual(fired, [.catchUp])
    }

    /// The last setup screen names when the first backup starts. A slot that
    /// passed before setup finished wasn't promised, so it isn't caught up.
    func testASlotBeforeSetupFinishedIsntMissed() {
        defaults.set(at(hour: 9), forKey: Preferences.setupCompletedAt)
        scheduler.fireCatchUpIfMissed(now: now, history: [])
        XCTAssertEqual(fired, [])

        defaults.set(at(hour: 9, daysAgo: 1), forKey: Preferences.setupCompletedAt)
        scheduler.fireCatchUpIfMissed(now: now, history: [])
        XCTAssertEqual(fired, [.catchUp])
    }

    func testCatchUpOffOrManualNeverFires() {
        defaults.set(false, forKey: Preferences.catchUpEnabled)
        scheduler.fireCatchUpIfMissed(now: now, history: [])
        defaults.set(true, forKey: Preferences.catchUpEnabled)
        defaults.set(BackupCadence.manual.rawValue, forKey: Preferences.cadence)
        scheduler.fireCatchUpIfMissed(now: now, history: [])
        XCTAssertEqual(fired, [])
    }

    /// Under Manually there's no slot, so retries count from the last backup
    /// the user started.
    func testManualAttemptsCountFromTheLastBackUpNow() {
        defaults.set(BackupCadence.manual.rawValue, forKey: Preferences.cadence)
        let history = [
            record(.success, hour: 1, trigger: .manual),
            record(.failed, hour: 8, trigger: .manual),
            record(.failed, hour: 9, trigger: .retry),
        ]
        XCTAssertEqual(scheduler.attemptWindowStart(history, now: now), at(hour: 8))
        XCTAssertEqual(Scheduler.failedAttempts(history, since: at(hour: 8)), 2)
    }

    /// A timer that fires late slept through its time: the share gets the
    /// network grace a wake gets before it's tried.
    func testALateTimerWaitsForTheNetwork() {
        XCTAssertNil(Scheduler.graceBeforeFiring(scheduled: slot, now: slot.addingTimeInterval(2)))
        XCTAssertEqual(
            Scheduler.graceBeforeFiring(scheduled: slot, now: slot.addingTimeInterval(300)),
            Config.wakeGraceSecs)
    }

    // MARK: - Manually means manually (production review W6)

    /// A retry, catch-up or deferred night armed before the switch to
    /// Manually is dropped at the start, whatever armed it.
    func testOnlyAskedForBackupsStartWhenManual() {
        for trigger in [BackupTrigger.scheduled, .catchUp, .retry] {
            XCTAssertFalse(BackupController.mayStart(trigger, cadence: .manual), "\(trigger)")
            XCTAssertTrue(BackupController.mayStart(trigger, cadence: .nightly), "\(trigger)")
            XCTAssertTrue(BackupController.mayStart(trigger, cadence: .weekly), "\(trigger)")
        }
        XCTAssertTrue(BackupController.mayStart(.manual, cadence: .manual))
    }

    /// Production review C4, 2026-10-13: a folder chosen in setup, the window
    /// closed, and the timer or a wake started a backup before Full Disk
    /// Access and notifications were set up. Back Up Now still works.
    func testNothingStartsOnItsOwnBeforeSetupIsDone() {
        for trigger in [BackupTrigger.scheduled, .catchUp, .retry] {
            XCTAssertFalse(
                BackupController.mayStart(trigger, cadence: .nightly, setupDone: false), "\(trigger)")
            XCTAssertTrue(
                BackupController.mayStart(trigger, cadence: .nightly, setupDone: true), "\(trigger)")
        }
        XCTAssertTrue(BackupController.mayStart(.manual, cadence: .nightly, setupDone: false))
    }

    /// On battery, then Manually: plugging in used to start the night that
    /// was held back. Now it stops waiting.
    func testChoosingManuallyStopsWaitingForPower() {
        XCTAssertEqual(
            BackupController.statusDroppingAutomaticWork(.waitingForPower), .idle)
        // A failure stays on the panel: it's still the truth about the backup.
        let failed = BackupController.Status.failed(.volumeUnreachable, "Not there")
        XCTAssertEqual(BackupController.statusDroppingAutomaticWork(failed), failed)
        XCTAssertEqual(BackupController.statusDroppingAutomaticWork(.idle), .idle)
    }
}
