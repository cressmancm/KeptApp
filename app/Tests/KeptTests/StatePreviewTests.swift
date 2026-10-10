#if KEPT_REVIEW_TOOLS
import XCTest

@testable import Kept

/// The preview catalogue is only useful if each entry actually reaches the
/// screen it names — a scenario that quietly resolves to `.idle` would look
/// like a working preview and review nothing.
@MainActor
final class StatePreviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func snapshot(_ scenario: PreviewScenario) -> StatePreview.Snapshot {
        StatePreview.snapshot(for: scenario, now: now)
    }

    func testEveryScenarioReachesTheStateItNames() {
        for scenario in PreviewScenario.allCases {
            let preview = snapshot(scenario)
            switch scenario.group {
            case .running:
                guard case .running = preview.status else {
                    return XCTFail("\(scenario.rawValue) is not a running state")
                }
            case .healthy:
                // Idle *with* something to be healthy about — an empty history
                // renders the neutral "Ready to back up" row instead.
                XCTAssertEqual(preview.status, .idle, scenario.rawValue)
                XCTAssertFalse(preview.history.isEmpty, scenario.rawValue)
            case .setup:
                let isReadyState = preview.status == .idle && preview.history.isEmpty
                XCTAssertTrue(
                    isReadyState || preview.status == .needsDestination
                        || preview.status == .needsPhotosAccess,
                    scenario.rawValue)
            case .trouble:
                let isTrouble: Bool = switch preview.status {
                case .failed, .waitingForPower: true
                default: false
                }
                XCTAssertTrue(isTrouble, scenario.rawValue)
            }
        }
    }

    /// The panel switches on all six; every one has to be reachable or a screen
    /// has no preview at all.
    func testEveryPanelStateIsCovered() {
        let statuses = PreviewScenario.allCases.map { snapshot($0).status }
        XCTAssertTrue(statuses.contains(.idle))
        XCTAssertTrue(statuses.contains(.needsDestination))
        XCTAssertTrue(statuses.contains(.needsPhotosAccess))
        XCTAssertTrue(statuses.contains(.waitingForPower))
        XCTAssertTrue(statuses.contains { if case .running = $0 { true } else { false } })
        XCTAssertTrue(statuses.contains { if case .failed = $0 { true } else { false } })
    }

    /// Each of the five failure kinds gets its own copy in FailureCopy, so each
    /// needs its own entry here.
    func testEveryFailureKindHasAScenario() {
        let kinds = PreviewScenario.allCases.compactMap { scenario -> FailureKind? in
            guard case .failed(let kind, _) = snapshot(scenario).status else { return nil }
            return kind
        }
        for kind in [
            FailureKind.volumeUnreachable, .diskFull, .exportFailed, .cancelled, .setupFailed,
        ] {
            XCTAssertTrue(kinds.contains(kind), "no scenario produces \(kind.rawValue)")
        }
    }

    /// Every export phase, so the running panel's determinate/indeterminate
    /// split can be checked in both directions.
    func testEveryExportPhaseHasAScenario() {
        let phases = PreviewScenario.allCases.compactMap { scenario -> ExportProgress.Phase? in
            guard case .running(let progress) = snapshot(scenario).status else { return nil }
            return progress.phase
        }
        for phase in [
            ExportProgress.Phase.starting, .scanning, .exporting, .cleaning, .finishing,
        ] {
            XCTAssertTrue(phases.contains(phase), "no scenario produces \(phase.rawValue)")
        }
    }

    /// `lastSuccess` and the Recent runs list both read the tail of the array,
    /// so a preview history built newest-first would silently describe the
    /// wrong run.
    func testHistoryIsOldestFirst() {
        for scenario in PreviewScenario.allCases {
            let starts = snapshot(scenario).history.map(\.start)
            XCTAssertEqual(starts, starts.sorted(), scenario.rawValue)
        }
    }

    /// A fabricated run must not be able to open a real log file.
    func testPreviewRunsCarryNoLogPath() {
        for scenario in PreviewScenario.allCases {
            XCTAssertTrue(
                snapshot(scenario).history.allSatisfy { $0.logPath == nil }, scenario.rawValue)
        }
    }

    /// The whole point of the failed panel's subtitle is the gap since the last
    /// good copy, which needs a success sitting behind the failure.
    func testFailureScenariosStillHaveAGoodCopyBehindThem() {
        for scenario in PreviewScenario.allCases {
            let snapshot = snapshot(scenario)
            guard case .failed = snapshot.status else { continue }
            XCTAssertNotNil(
                snapshot.history.last(where: { $0.outcome == .success }), scenario.rawValue)
            XCTAssertNotEqual(snapshot.history.last?.outcome, .success, scenario.rawValue)
        }
    }

    func testLabelsAreUnique() {
        let labels = Set(PreviewScenario.allCases.map(\.label))
        XCTAssertEqual(labels.count, PreviewScenario.allCases.count)
    }
}
#endif
