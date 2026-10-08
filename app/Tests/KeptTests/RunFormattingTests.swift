import XCTest

@testable import Kept

final class RunFormattingTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func record(
        _ start: Date, outcome: RunOutcome?, exported: Int? = nil, seconds: TimeInterval? = nil
    ) -> RunRecord {
        var record = RunRecord(trigger: .scheduled, start: start)
        record.outcome = outcome
        record.exported = exported
        record.end = seconds.map { start.addingTimeInterval($0) }
        return record
    }

    // Times are formatted in the machine's locale, so these assert the part
    // the function actually decides: which day word it picked.
    func testFriendlyDateUsesDayWords() {
        let now = date(2026, 7, 25, 14, 0)
        XCTAssertTrue(
            RunFormatting.friendlyDate(date(2026, 7, 25, 11, 4), now: now, calendar: calendar)
                .hasPrefix("Today, "))
        XCTAssertTrue(
            RunFormatting.friendlyDate(date(2026, 7, 24, 16, 52), now: now, calendar: calendar)
                .hasPrefix("Yesterday, "))
        let older = RunFormatting.friendlyDate(
            date(2026, 7, 23, 2, 0), now: now, calendar: calendar)
        XCTAssertFalse(older.hasPrefix("Today"))
        XCTAssertFalse(older.hasPrefix("Yesterday"))
        XCTAssertTrue(older.contains("Jul 23"))
    }

    func testRowDetailRenamesExportedToNew() {
        let run = record(date(2026, 7, 25, 2, 0), outcome: .success, exported: 2, seconds: 33 * 60)
        XCTAssertEqual(RunFormatting.rowDetail(run), "2 new · 33 min")
    }

    func testRowDetailForNonSuccessOutcomes() {
        let start = date(2026, 7, 25, 2, 0)
        XCTAssertEqual(RunFormatting.rowDetail(record(start, outcome: .failed)), "Failed")
        XCTAssertEqual(RunFormatting.rowDetail(record(start, outcome: .skipped)), "Skipped")
        XCTAssertEqual(RunFormatting.rowDetail(record(start, outcome: .cancelled)), "Stopped")
    }

    func testDurationUnits() {
        XCTAssertEqual(RunFormatting.duration(45), "45 sec")
        XCTAssertEqual(RunFormatting.duration(33 * 60), "33 min")
        XCTAssertEqual(RunFormatting.duration(72 * 60), "1 hr 12 min")
    }

    /// Every row is one run, newest first, under its day; the list stops at
    /// the limit however many days that covers.
    func testRecentRunsAreGroupedUnderDaysNewestFirst() {
        let now = date(2026, 7, 25, 14, 0)
        let history = [
            record(date(2026, 7, 22, 2, 0), outcome: .success),
            record(date(2026, 7, 24, 2, 0), outcome: .failed),
            record(date(2026, 7, 24, 3, 0), outcome: .failed),
            record(date(2026, 7, 24, 9, 0), outcome: .success),
            record(date(2026, 7, 25, 2, 0), outcome: .success),
        ]
        let groups = RunFormatting.recentRunGroups(
            history, limit: 4, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.heading), ["Today", "Yesterday"])
        XCTAssertEqual(groups[0].runs.map(\.outcome), [.success])
        // A messy night shows every attempt, latest first.
        XCTAssertEqual(groups[1].runs.map(\.outcome), [.success, .failed, .failed])
    }

    func testOlderDaysAreNamedWithTheirDate() {
        let now = date(2026, 10, 6, 14, 0)
        let heading = RunFormatting.dayHeading(
            date(2026, 10, 4, 2, 0), now: now, calendar: calendar)
        XCTAssertTrue(heading.contains("Oct"), heading)
        XCTAssertTrue(heading.contains("4"), heading)
        XCTAssertTrue(heading.contains("Sun"), heading)
    }

    /// The collapsed header shares its line with the section name, so it
    /// drops the duration a full row shows.
    func testLastRunSummaryIsShortEnoughForTheHeader() {
        let now = date(2026, 7, 25, 14, 0)
        var run = record(date(2026, 7, 25, 2, 4), outcome: .success)
        run.exported = 31
        run.end = run.start.addingTimeInterval(4 * 60)
        let summary = RunFormatting.lastRunSummary(run, now: now, calendar: calendar)
        XCTAssertTrue(summary.hasPrefix("Today, "), summary)
        XCTAssertTrue(summary.hasSuffix(" · 31 new"), summary)
        XCTAssertEqual(
            RunFormatting.lastRunSummary(
                record(date(2026, 7, 25, 2, 4), outcome: .failed), now: now, calendar: calendar)
                .components(separatedBy: " · ").last,
            "Failed")
    }

    func testNextRunPhraseCallsAnEarlyMorningRunTonight() {
        let now = date(2026, 7, 25, 22, 0)
        let phrase = RunFormatting.nextRunPhrase(
            date(2026, 7, 26, 2, 0), cadence: .nightly, now: now, calendar: calendar)
        XCTAssertTrue(phrase.hasPrefix("Next backup tonight at "), phrase)
    }

    func testNextRunPhraseUsesTomorrowForDaytimeRuns() {
        let now = date(2026, 7, 25, 22, 0)
        let phrase = RunFormatting.nextRunPhrase(
            date(2026, 7, 26, 14, 0), cadence: .nightly, now: now, calendar: calendar)
        XCTAssertTrue(phrase.hasPrefix("Next backup tomorrow at "), phrase)
    }

    /// Regression: a weekly schedule six days from firing read "Next backup
    /// Sunday at 2:00 AM", which is indistinguishable at a glance from a
    /// nightly one — the reason a backup silently went from nightly to weekly
    /// without anyone noticing. It must name the cadence and give a real date.
    func testWeeklyPhraseStatesTheCadenceAndAnExplicitDate() {
        // Monday, looking at a run that fires the following Sunday.
        let phrase = RunFormatting.nextRunPhrase(
            date(2026, 8, 2, 2, 0), cadence: .weekly,
            now: date(2026, 7, 27, 7, 50), calendar: calendar)
        XCTAssertTrue(phrase.hasPrefix("Next backup Sunday, "), phrase)
        XCTAssertTrue(phrase.contains("Aug 2"), phrase)
        XCTAssertTrue(phrase.hasSuffix("· weekly"), phrase)
    }

    func testNightlyAndWeeklyAreNeverConfusable() {
        let now = date(2026, 7, 27, 7, 50)
        let nightly = RunFormatting.nextRunPhrase(
            date(2026, 7, 28, 2, 0), cadence: .nightly, now: now, calendar: calendar)
        let weekly = RunFormatting.nextRunPhrase(
            date(2026, 8, 2, 2, 0), cadence: .weekly, now: now, calendar: calendar)
        XCTAssertFalse(nightly.contains("weekly"), nightly)
        XCTAssertTrue(weekly.contains("weekly"), weekly)
        XCTAssertNotEqual(nightly, weekly)
    }

    /// Past tomorrow, never a bare weekday — "Wednesday" two days out and
    /// "Sunday" six days out look identically imminent.
    func testAnythingPastTomorrowGetsARealDate() {
        let now = date(2026, 7, 27, 10, 0)
        let phrase = RunFormatting.nextRunPhrase(
            date(2026, 7, 29, 2, 0), cadence: .nightly, now: now, calendar: calendar)
        XCTAssertTrue(phrase.contains("Jul 29"), phrase)
        XCTAssertFalse(phrase.contains("Wednesday"), phrase)
    }

    func testShortFormForSettings() {
        let now = date(2026, 7, 27, 22, 0)
        XCTAssertEqual(
            RunFormatting.nextRunShort(
                date(2026, 7, 28, 2, 0), cadence: .nightly, now: now, calendar: calendar
            ).hasPrefix("Next: tonight, "), true)
        XCTAssertEqual(
            RunFormatting.nextRunShort(nil, cadence: .manual, now: now, calendar: calendar),
            "Only when you start one")
    }

    /// Onboarding's last screen promises a first run, so the sentence has to
    /// stay a sentence in every case — including the two where there is no time
    /// to name and the copy would otherwise trail off mid-clause.
    func testFirstBackupPhraseIsAlwaysAWholeSentence() {
        let now = date(2026, 7, 27, 22, 0)
        let nightly = RunFormatting.firstBackupPhrase(
            date(2026, 7, 28, 2, 0), cadence: .nightly, now: now, calendar: calendar)
        XCTAssertTrue(nightly.hasPrefix("The first backup starts tonight at "), nightly)
        XCTAssertTrue(nightly.hasSuffix("."), nightly)

        for phrase in [
            RunFormatting.firstBackupPhrase(nil, cadence: .manual, now: now, calendar: calendar),
            RunFormatting.firstBackupPhrase(nil, cadence: .nightly, now: now, calendar: calendar),
        ] {
            XCTAssertTrue(phrase.hasSuffix("."), phrase)
        }
    }

    /// The destination card is assembled from probe results that may not have
    /// arrived. Whatever is missing comes out as a shorter paragraph, never as
    /// a dangling clause or an empty value.
    func testFirstCopyPlanDropsWhatTheProbeCannotAnswer() {
        let full = RunFormatting.firstCopyPlan(
            mounted: true, freeBytes: 1_850_000_000_000, itemCount: 46_920)
        XCTAssertTrue(full.hasPrefix("Connected · "), full)
        XCTAssertTrue(full.contains("about"), full)

        let unprobed = RunFormatting.firstCopyPlan(
            mounted: true, freeBytes: nil, itemCount: nil)
        XCTAssertTrue(unprobed.hasPrefix("Connected."), unprobed)
        XCTAssertFalse(unprobed.contains("about"), unprobed)
        XCTAssertTrue(unprobed.contains("only changes are copied"), unprobed)

        let offline = RunFormatting.firstCopyPlan(
            mounted: false, freeBytes: nil, itemCount: nil)
        XCTAssertTrue(offline.hasPrefix("Not connected."), offline)
    }

    func testManualCadenceMakesNoPromise() {
        XCTAssertEqual(
            RunFormatting.nextRunPhrase(nil, cadence: .manual, calendar: calendar),
            "Backups are manual")
    }

    /// Regression: the subtitle read "3 hours ago" for a run 12 hours old,
    /// because the relative phrase was measured against the real clock instead
    /// of a reference date the caller controls. It has to move with `now`.
    func testHealthySubtitleMeasuresAgainstTheGivenTime() {
        let start = date(2026, 7, 26, 8, 25)
        var record = RunRecord(trigger: .scheduled, start: start)
        record.outcome = .success
        record.mirroredCount = 46_929

        let soonAfter = RunFormatting.healthySubtitle(
            record, now: date(2026, 7, 26, 11, 25))
        let muchLater = RunFormatting.healthySubtitle(
            record, now: date(2026, 7, 26, 20, 33))

        XCTAssertNotEqual(soonAfter, muchLater, "subtitle must track the reference time")
        XCTAssertTrue(soonAfter.contains("3"), soonAfter)
        XCTAssertTrue(muchLater.contains("12"), muchLater)
    }

    /// The mirror holds the library as osxphotos snapshotted it at run *start*,
    /// so the subtitle measures from `start`. Using `end` would understate the age of the copy by the whole
    /// duration of the run — six and a half hours, on 2026-07-30.
    func testHealthySubtitleIsAsOfTheRunStartNotItsEnd() {
        var record = RunRecord(trigger: .scheduled, start: date(2026, 7, 30, 2, 0))
        record.outcome = .success
        record.end = date(2026, 7, 30, 8, 32)

        let subtitle = RunFormatting.healthySubtitle(record, now: date(2026, 7, 30, 9, 10))
        XCTAssertTrue(subtitle.hasPrefix("Last backup "), subtitle)
        XCTAssertTrue(subtitle.contains("7"), "should measure from 02:00, not 08:32 — \(subtitle)")
        XCTAssertFalse(subtitle.contains("36"), "must not report the finish time — \(subtitle)")
    }

    /// The item count is gone on purpose: osxphotos counts hidden, shared and
    /// burst items that the Photos app leaves out of its own total, so the two
    /// numbers disagreed by ~13,000 and read as a bug.
    func testHealthySubtitleQuotesNoLibraryTotal() {
        var record = RunRecord(trigger: .scheduled, start: date(2026, 7, 26, 8, 25))
        record.outcome = .success
        record.mirroredCount = 46_929
        let subtitle = RunFormatting.healthySubtitle(record, now: date(2026, 7, 26, 20, 33))
        XCTAssertFalse(subtitle.contains("46"), subtitle)
        XCTAssertFalse(subtitle.contains("mirrored"), subtitle)
    }

    func testTimeRemainingSuppressesTrivialEstimates() {
        XCTAssertNil(RunFormatting.timeRemaining(nil))
        XCTAssertNil(RunFormatting.timeRemaining(10))
        XCTAssertEqual(RunFormatting.timeRemaining(12 * 60), "about 12 min left")
    }
}
