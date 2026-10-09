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

    func testUpsertAppendsThenReplacesInPlace() {
        var run = record(nil)
        RunHistory.upsert(run, to: url)
        XCTAssertEqual(RunHistory.load(from: url).count, 1)

        run.outcome = .success
        run.exported = 12
        RunHistory.upsert(run, to: url)

        let loaded = RunHistory.load(from: url)
        XCTAssertEqual(loaded.count, 1, "same id must update, not append a second row")
        XCTAssertEqual(loaded[0].outcome, .success)
        XCTAssertEqual(loaded[0].exported, 12)
    }

    func testDistinctRunsBothPersist() {
        RunHistory.upsert(record(.success), to: url)
        RunHistory.upsert(record(.failed), to: url)
        XCTAssertEqual(RunHistory.load(from: url).count, 2)
    }

    /// The gap this whole scheme exists to close: a process that dies mid-run
    /// used to leave no trace, so an interrupted backup was indistinguishable
    /// from a night nothing was scheduled.
    func testReconcileClosesOutARunLeftWithoutAnOutcome() {
        RunHistory.upsert(record(nil), to: url)
        let now = Date(timeIntervalSince1970: 1_800_009_999)

        let reconciled = RunHistory.reconcileInterrupted(in: url, now: now)
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled[0].outcome, .interrupted)
        XCTAssertEqual(reconciled[0].end, now)
        XCTAssertNotNil(reconciled[0].message)

        // Persisted, not just returned.
        XCTAssertEqual(RunHistory.load(from: url).first?.outcome, .interrupted)
    }

    func testReconcileLeavesFinishedRunsAlone() {
        RunHistory.upsert(record(.success), to: url)
        RunHistory.upsert(record(.failed), to: url)
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
    func testTrimmingNeverDropsTheLatestSuccess() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var success = RunRecord(trigger: .scheduled, start: start)
        success.outcome = .success
        RunHistory.upsert(success, to: url)
        for index in 1...(Config.historyLimit + 10) {
            var skipped = RunRecord(trigger: .catchUp, start: start + Double(index) * 3600)
            skipped.outcome = .skipped
            RunHistory.upsert(skipped, to: url)
        }
        let loaded = RunHistory.load(from: url)
        XCTAssertEqual(loaded.count, Config.historyLimit)
        XCTAssertEqual(loaded.first?.id, success.id)
        XCTAssertEqual(loaded.filter { $0.outcome == .success }.count, 1)
        XCTAssertEqual(loaded.map(\.start), loaded.map(\.start).sorted())
    }
}
