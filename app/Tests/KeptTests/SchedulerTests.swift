import XCTest

@testable import Kept

final class SchedulerTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testNextFireLaterToday() {
        let now = date(2026, 7, 24, 1, 0)
        let next = Scheduler.nextFireDate(after: now, hour: 2, minute: 0, calendar: calendar)
        XCTAssertEqual(next, date(2026, 7, 24, 2, 0))
    }

    func testNextFireTomorrowWhenTimePassed() {
        let now = date(2026, 7, 24, 14, 30)
        let next = Scheduler.nextFireDate(after: now, hour: 2, minute: 0, calendar: calendar)
        XCTAssertEqual(next, date(2026, 7, 25, 2, 0))
    }

    func testNextFireSkipsExactNow() {
        // nextDate(after:) is strictly after — firing at exactly 02:00 must arm for tomorrow.
        let now = date(2026, 7, 24, 2, 0)
        let next = Scheduler.nextFireDate(after: now, hour: 2, minute: 0, calendar: calendar)
        XCTAssertEqual(next, date(2026, 7, 25, 2, 0))
    }

    func testLastFireEarlierToday() {
        let now = date(2026, 7, 24, 14, 30)
        let last = Scheduler.lastFireDate(before: now, hour: 2, minute: 0, calendar: calendar)
        XCTAssertEqual(last, date(2026, 7, 24, 2, 0))
    }

    func testLastFireYesterdayWhenBeforeScheduledTime() {
        let now = date(2026, 7, 24, 1, 0)
        let last = Scheduler.lastFireDate(before: now, hour: 2, minute: 0, calendar: calendar)
        XCTAssertEqual(last, date(2026, 7, 23, 2, 0))
    }

    func testCatchUpComparison() {
        // Ran yesterday 2 AM, Mac slept through last night's 2 AM, woke at 9 AM:
        // last run start < most recent scheduled time -> catch-up needed.
        let lastRun = date(2026, 7, 23, 2, 0)
        let now = date(2026, 7, 24, 9, 0)
        let lastScheduled = Scheduler.lastFireDate(before: now, hour: 2, minute: 0, calendar: calendar)
        XCTAssertTrue(lastRun < lastScheduled)

        // Ran (or attempted) this morning at 2 AM -> no catch-up.
        let ranToday = date(2026, 7, 24, 2, 0)
        XCTAssertFalse(ranToday < lastScheduled)
    }

    // MARK: - Cadence

    func testWeeklyFiresOnTheChosenWeekday() {
        // Saturday Jul 25 2026; weekday 4 is Wednesday in Calendar's numbering.
        let now = date(2026, 7, 25, 10, 0)
        let next = Scheduler.nextFireDate(
            after: now, cadence: .weekly, weekday: 4, hour: 2, minute: 0, calendar: calendar)
        XCTAssertEqual(next, date(2026, 7, 29, 2, 0))
    }

    func testManualCadenceHasNoNextOrLastFire() {
        let now = date(2026, 7, 25, 10, 0)
        XCTAssertNil(Scheduler.nextFireDate(
            after: now, cadence: .manual, weekday: 1, hour: 2, minute: 0, calendar: calendar))
        XCTAssertNil(Scheduler.lastFireDate(
            before: now, cadence: .manual, weekday: 1, hour: 2, minute: 0, calendar: calendar))
    }

    func testNightlyCadenceMatchesThePlainNightlyMath() {
        let now = date(2026, 7, 25, 10, 0)
        XCTAssertEqual(
            Scheduler.nextFireDate(
                after: now, cadence: .nightly, weekday: 1, hour: 2, minute: 0, calendar: calendar),
            Scheduler.nextFireDate(after: now, hour: 2, minute: 0, calendar: calendar))
    }

    // MARK: - What counts as servicing a scheduled slot

    private func run(_ start: Date, _ outcome: RunOutcome) -> RunRecord {
        var record = RunRecord(trigger: .scheduled, start: start)
        record.outcome = outcome
        return record
    }

    func testOnlyASuccessServicesTheSlot() {
        let slot = date(2026, 8, 5, 2, 0)
        XCTAssertTrue(Scheduler.slotWasServiced(
            [run(date(2026, 8, 5, 2, 4), .success)], since: slot))
    }

    /// Regression: a failed 02:04 attempt "serviced" the 02:00 slot, so
    /// plugging in the next morning did nothing at all.
    func testAFailedRunDoesNotServiceTheSlot() {
        let slot = date(2026, 8, 5, 2, 0)
        XCTAssertFalse(Scheduler.slotWasServiced(
            [run(date(2026, 8, 5, 2, 4), .failed)], since: slot))
    }

    /// A run deferred for battery must leave the slot open, or the deferral
    /// would quietly consume the night it was trying to protect.
    func testADeferredRunDoesNotServiceTheSlot() {
        let slot = date(2026, 8, 5, 2, 0)
        XCTAssertFalse(Scheduler.slotWasServiced(
            [run(date(2026, 8, 5, 2, 0), .skipped)], since: slot))
    }

    func testRunsBeforeTheSlotDoNotCount() {
        let slot = date(2026, 8, 5, 2, 0)
        XCTAssertFalse(Scheduler.slotWasServiced(
            [run(date(2026, 8, 4, 2, 0), .success)], since: slot))
    }

    func testALaterSuccessAfterAFailureServicesTheSlot() {
        let slot = date(2026, 8, 5, 2, 0)
        XCTAssertTrue(Scheduler.slotWasServiced(
            [run(date(2026, 8, 5, 2, 4), .failed), run(date(2026, 8, 5, 9, 0), .success)],
            since: slot))
    }

    func testWeeklyCatchUpLooksBackToThePreviousWeek() {
        // Thursday Jul 30, a day after the Wednesday fire.
        let now = date(2026, 7, 30, 10, 0)
        let last = Scheduler.lastFireDate(
            before: now, cadence: .weekly, weekday: 4, hour: 2, minute: 0, calendar: calendar)
        XCTAssertEqual(last, date(2026, 7, 29, 2, 0))
    }

    /// Turning Full Disk Access back on must start the missed backup at once,
    /// so a run stopped for access doesn't start the hour-long cooldown.
    /// Deferrals don't either; a real failure does.
    func testCooldownIgnoresAccessFailuresAndDeferrals() {
        var blocked = run(date(2026, 10, 6, 2, 0), .failed)
        blocked.failureKind = .libraryAccess
        let deferred = run(date(2026, 10, 6, 3, 0), .skipped)
        var unreachable = run(date(2026, 10, 5, 2, 0), .failed)
        unreachable.failureKind = .volumeUnreachable

        XCTAssertEqual(
            Scheduler.lastCooldownAttempt([unreachable, blocked, deferred]),
            date(2026, 10, 5, 2, 0))
        XCTAssertNil(Scheduler.lastCooldownAttempt([blocked, deferred]))
    }

    /// Retries and catch-up share one cap of three tries a slot. Access
    /// failures, deferrals and anything before the slot don't count.
    func testFailedAttemptsCountOnlyRealFailuresInTheSlot() {
        let slot = date(2026, 10, 9, 2, 0)
        var blocked = run(date(2026, 10, 9, 2, 1), .failed)
        blocked.failureKind = .libraryAccess
        let history = [
            run(date(2026, 10, 8, 2, 0), .failed),
            run(date(2026, 10, 9, 2, 0), .failed),
            blocked,
            run(date(2026, 10, 9, 3, 0), .skipped),
            run(date(2026, 10, 9, 4, 0), .failed),
        ]
        XCTAssertEqual(Scheduler.failedAttempts(history, since: slot), 2)
        XCTAssertLessThan(
            Scheduler.failedAttempts(history, since: slot), Config.maxAttemptsPerSlot)
        let capped = history + [run(date(2026, 10, 9, 5, 0), .failed)]
        XCTAssertEqual(Scheduler.failedAttempts(capped, since: slot), Config.maxAttemptsPerSlot)
    }
}
