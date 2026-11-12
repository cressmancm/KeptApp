import XCTest

@testable import Kept

/// Covers the write-at-start / reconcile-at-launch scheme that makes a run
/// survive its own process dying.
final class RunHistoryTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appending(path: "KeptHistoryTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func record(_ outcome: RunOutcome?) -> RunRecord {
        var record = RunRecord(trigger: .scheduled, start: Date(timeIntervalSince1970: 1_800_000_000))
        record.outcome = outcome
        return record
    }

    func testUpsertAppendsThenReplacesInPlace() throws {
        var run = record(nil)
        try RunHistory.upsert(run, to: url)
        XCTAssertEqual(RunHistory.load(from: url).count, 1)

        run.outcome = .success
        run.exported = 12
        try RunHistory.upsert(run, to: url)

        let loaded = RunHistory.load(from: url)
        XCTAssertEqual(loaded.count, 1, "same id must update, not append a second row")
        XCTAssertEqual(loaded[0].outcome, .success)
        XCTAssertEqual(loaded[0].exported, 12)
    }

    func testDistinctRunsBothPersist() throws {
        try RunHistory.upsert(record(.success), to: url)
        try RunHistory.upsert(record(.failed), to: url)
        XCTAssertEqual(RunHistory.load(from: url).count, 2)
    }

    /// The gap this whole scheme exists to close: a process that dies mid-run
    /// used to leave no trace, so an interrupted backup was indistinguishable
    /// from a night nothing was scheduled.
    func testReconcileClosesOutARunLeftWithoutAnOutcome() throws {
        try RunHistory.upsert(record(nil), to: url)
        let now = Date(timeIntervalSince1970: 1_800_009_999)

        let reconciled = RunHistory.reconcileInterrupted(in: url, now: now)
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled[0].outcome, .interrupted)
        XCTAssertEqual(reconciled[0].end, now)
        XCTAssertNotNil(reconciled[0].message)

        // Persisted, not just returned.
        XCTAssertEqual(RunHistory.load(from: url).first?.outcome, .interrupted)
    }

    func testReconcileLeavesFinishedRunsAlone() throws {
        try RunHistory.upsert(record(.success), to: url)
        try RunHistory.upsert(record(.failed), to: url)
        let outcomes = RunHistory.reconcileInterrupted(in: url).map(\.outcome)
        XCTAssertEqual(outcomes, [.success, .failed])
    }

    /// An interrupted run must not satisfy the schedule, or quitting mid-run
    /// would silently consume the night.
    func testAnInterruptedRunDoesNotServiceTheSlot() {
        var run = RunRecord(
            trigger: .scheduled, start: Date(timeIntervalSince1970: 1_800_000_100))
        run.outcome = .interrupted
        XCTAssertFalse(Scheduler.slotWasServiced(
            [run], since: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func testInterruptedReadsAsGreyNotRed() {
        XCTAssertEqual(
            RunOutcomeStyle.color(for: .interrupted), RunOutcomeStyle.color(for: .cancelled),
            "stopped is not broken")
        XCTAssertNotEqual(RunOutcomeStyle.color(for: .interrupted), RunOutcomeStyle.color(for: .failed))
    }

    func testRowDetailNamesTheState() {
        var run = record(.interrupted)
        XCTAssertEqual(RunFormatting.rowDetail(run), "Interrupted")
        run.outcome = nil
        XCTAssertEqual(RunFormatting.rowDetail(run), "Running…")
    }

    /// A long run of failures or battery deferrals must not push the last
    /// good backup out of the history: everything that says how old the
    /// backup is measures from it.
    func testTrimmingNeverDropsTheLatestSuccess() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var success = RunRecord(trigger: .scheduled, start: start)
        success.outcome = .success
        try RunHistory.upsert(success, to: url)
        for index in 1...(Config.historyLimit + 10) {
            var skipped = RunRecord(trigger: .catchUp, start: start + Double(index) * 3600)
            skipped.outcome = .skipped
            try RunHistory.upsert(skipped, to: url)
        }
        let loaded = RunHistory.load(from: url)
        XCTAssertEqual(loaded.count, Config.historyLimit)
        XCTAssertEqual(loaded.first?.id, success.id)
        XCTAssertEqual(loaded.filter { $0.outcome == .success }.count, 1)
        XCTAssertEqual(loaded.map(\.start), loaded.map(\.start).sorted())
    }

    // MARK: - A wait for the share

    private func shareWait(_ hours: Double, folder: UUID? = nil) -> RunRecord {
        let start = Date(timeIntervalSince1970: 1_800_000_000) + hours * 3600
        var record = RunRecord(trigger: .scheduled, start: start)
        record.destinationID = folder
        record.end = start + 30
        record.outcome = .skipped
        record.deferral = .shareAway
        record.logPath = "/logs/\(hours).log"
        return record
    }

    /// A trip used to add a failed run with every try, three a night. A wait
    /// is one row, from its first try to its last.
    func testAWaitForTheShareIsOneRecord() throws {
        let first = shareWait(0)
        try RunHistory.upsert(RunRecord(trigger: .scheduled, start: first.start), to: url)
        var saved = try RunHistory.upsertDeferral(first, to: url)
        XCTAssertEqual(saved.id, first.id)
        for hours in [1.0, 2, 24, 25] {
            saved = try RunHistory.upsertDeferral(shareWait(hours), to: url)
        }
        let loaded = RunHistory.load(from: url).filter { $0.outcome == .skipped }
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, first.id)
        XCTAssertEqual(loaded.first?.start, first.start)
        XCTAssertEqual(loaded.first?.end, shareWait(25).end)
        XCTAssertEqual(loaded.first?.logPath, "/logs/25.0.log")
        XCTAssertEqual(saved.id, first.id)
    }

    /// Anything in between ends the wait, and the next one starts its own row.
    func testABackupInBetweenStartsANewWait() throws {
        try RunHistory.upsertDeferral(shareWait(0), to: url)
        try RunHistory.upsert(record(.success), to: url)
        try RunHistory.upsertDeferral(shareWait(30), to: url)
        var power = shareWait(31)
        power.deferral = .power
        try RunHistory.upsertDeferral(power, to: url)
        try RunHistory.upsertDeferral(shareWait(32), to: url)
        XCTAssertEqual(
            RunHistory.load(from: url).map(\.deferral), [.shareAway, nil, .shareAway, .power, .shareAway])
    }

    /// Each backup folder has its own history, and its own waits.
    func testAWaitIsPerFolder() throws {
        let other = UUID()
        try RunHistory.upsertDeferral(shareWait(0), to: url)
        try RunHistory.upsertDeferral(shareWait(1, folder: other), to: url)
        try RunHistory.upsertDeferral(shareWait(2), to: url)
        let loaded = RunHistory.load(from: url)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.end, shareWait(2).end)
    }

    /// Records from before Kept kept a reason still load.
    func testOldRecordsDecodeWithoutADeferral() throws {
        let json = #"[{"id":"7C8E2A3B-0F5D-4C1A-9E6B-2D4F8A1C3E5B","trigger":"scheduled","#
            + #""start":"2026-10-01T02:00:00Z","outcome":"skipped","message":"Skipped"}]"#
        let records = try XCTUnwrap(RunHistory.decode(Data(json.utf8)))
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.deferral)
    }
}
