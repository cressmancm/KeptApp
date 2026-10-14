import XCTest

@testable import Kept

/// The uninstall plan is a list of things to delete, so the tests that matter
/// are the ones about what is *not* on it.
@MainActor
final class UninstallTests: XCTestCase {
    private let bundle = URL(filePath: "/Applications/Kept.app")
    private let identifier = "com.chipcressman.Kept"
    private let appSupport = URL(filePath: "/Users/test/Library/Application Support/Kept")
    private let logs = URL(filePath: "/Users/test/Library/Logs/Kept")
    private let plist = URL(
        filePath: "/Users/test/Library/LaunchAgents/com.chipcressman.Kept.staleness.plist")

    private func plan(
        bundleURL: URL? = nil, identifier: String? = nil, keepExportDatabase: Bool = false,
        removeApp: Bool = true
    ) -> [Uninstall.Item] {
        Uninstall.plan(
            bundleURL: bundleURL ?? bundle,
            bundleIdentifier: identifier ?? self.identifier,
            appSupport: appSupport,
            logs: logs,
            launchAgentPlist: plist,
            launchAgentLabel: "com.chipcressman.Kept.staleness",
            keepExportDatabase: keepExportDatabase,
            removeApp: removeApp)
    }

    /// The one guarantee both uninstall alerts make to the user. A destination
    /// is typically /Volumes/… or an ordinary folder outside ~/Library, and
    /// nothing in the plan may reach outside ~/Library or the bundle itself.
    func testPlanTouchesNothingOutsideLibraryAndTheBundle() {
        let library = "/Users/test/Library/"
        for keep in [false, true] {
            for item in plan(keepExportDatabase: keep) {
                guard let path = item.path else { continue }
                XCTAssertTrue(
                    path == bundle.path || path.hasPrefix(library),
                    "\(item.label) would delete \(path)")
            }
        }
    }

    func testPlanNeverReachesAVolume() {
        for keep in [false, true] {
            XCTAssertFalse(
                plan(keepExportDatabase: keep).compactMap(\.path)
                    .contains { $0.hasPrefix("/Volumes/") })
        }
    }

    /// The choice in the confirmation changes one step and nothing else: the
    /// rest of Application Support, the logs, and every other item still go.
    func testKeepingTheExportDatabaseChangesOnlyTheApplicationSupportStep() {
        let removeAll = plan().map(\.target)
        let keepDB = plan(keepExportDatabase: true).map(\.target)
        XCTAssertEqual(removeAll.count, keepDB.count)

        XCTAssertFalse(keepDB.contains {
            if case .directory(let url) = $0 { url == appSupport } else { false }
        })
        XCTAssertTrue(keepDB.contains {
            if case .directoryKeepingExportDatabase(let url) = $0 { url == appSupport } else { false }
        })
        XCTAssertTrue(keepDB.contains {
            if case .directory(let url) = $0 { url == logs } else { false }
        })
        XCTAssertFalse(removeAll.contains {
            if case .directoryKeepingExportDatabase = $0 { true } else { false }
        })
    }

    /// The database and SQLite's companion files are one thing — keeping
    /// export.db while deleting its journal would leave it torn.
    func testExportDatabaseMatchesItsCompanionsAndNothingElse() {
        for name in ["export.db", "export.db-wal", "export.db-shm", "export.db-journal"] {
            XCTAssertTrue(Uninstall.isExportDatabase(name), name)
        }
        for name in ["runs.json", "report.csv", ".backup.pid", "export.dbx", "old-export.db"] {
            XCTAssertFalse(Uninstall.isExportDatabase(name), name)
        }
    }

    /// Run for real against a scratch folder: everything but the database goes,
    /// hidden lock file included, and the folder itself stays to hold it.
    func testKeepingTheExportDatabaseRemovesEverythingElse() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "KeptUninstallTest-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let kept = ["export.db", "export.db-wal"]
        let removed = ["runs.json", "report.csv", "report-2025.csv", ".backup.pid"]
        for name in kept + removed {
            try Data("x".utf8).write(to: dir.appending(path: name))
        }

        let outcome = await Uninstall.perform([
            Uninstall.Item(label: "test", target: .directoryKeepingExportDatabase(dir))
        ])

        XCTAssertTrue(outcome.isClean)
        XCTAssertEqual(
            Set(try fm.contentsOfDirectory(atPath: dir.path)), Set(kept))
    }

    /// Application Support/Kept as a link to some other folder: keeping the
    /// index must not empty the folder it points at. Kept has Full Disk
    /// Access, so following the link would delete what the planter couldn't.
    func testKeepingTheExportDatabaseNeverFollowsALink() async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "KeptUninstallLink-\(UUID().uuidString)")
        let victim = scratch.appending(path: "Documents")
        let link = scratch.appending(path: "Kept")
        try fm.createDirectory(at: victim.appending(path: "Taxes"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: victim.appending(path: "Taxes/2025.pdf"))
        try Data("x".utf8).write(to: victim.appending(path: "notes.txt"))
        try fm.createSymbolicLink(at: link, withDestinationURL: victim)
        defer { try? fm.removeItem(at: scratch) }

        let outcome = await Uninstall.perform([
            Uninstall.Item(label: "test", target: .directoryKeepingExportDatabase(link))
        ])

        XCTAssertFalse(outcome.isClean)
        XCTAssertEqual(outcome.failed.first?.reason, "It's a link, so Kept didn't follow it.")
        XCTAssertEqual(
            Set(try fm.contentsOfDirectory(atPath: victim.path)), ["Taxes", "notes.txt"])
        XCTAssertTrue(fm.fileExists(atPath: victim.appending(path: "Taxes/2025.pdf").path))
    }

    /// Everything Kept installs has to be on the list, or an uninstall leaves
    /// the exact debris it exists to clear.
    func testPlanCoversEverythingKeptInstalls() {
        let targets = plan().map(\.target)
        XCTAssertTrue(targets.contains { if case .loginItem = $0 { true } else { false } })
        XCTAssertTrue(targets.contains { if case .launchAgent = $0 { true } else { false } })
        XCTAssertTrue(targets.contains { if case .permissions = $0 { true } else { false } })
        XCTAssertTrue(targets.contains { if case .defaultsDomain = $0 { true } else { false } })
        XCTAssertTrue(targets.contains { if case .appBundle = $0 { true } else { false } })
        let directories = targets.compactMap { target -> URL? in
            guard case .directory(let url) = target else { return nil }
            return url
        }
        XCTAssertEqual(Set(directories), [appSupport, logs])
    }

    /// The login item and the agent are resolved by the system against a bundle
    /// that still has to exist, so the bundle goes last.
    func testTheBundleIsRemovedLast() {
        let targets = plan().map(\.target)
        guard case .appBundle = targets.last else {
            return XCTFail("the app bundle is not the final step")
        }
    }

    /// `swift run` has no bundle to trash, no login item, and its defaults are
    /// not in a bundle-id domain. Those steps drop out rather than failing.
    func testBareBinaryPlanSkipsTheBundleSteps() {
        let targets = Uninstall.plan(
            bundleURL: nil, bundleIdentifier: nil,
            appSupport: appSupport, logs: logs,
            launchAgentPlist: plist, launchAgentLabel: "com.chipcressman.Kept.staleness"
        ).map(\.target)

        XCTAssertFalse(targets.contains { if case .appBundle = $0 { true } else { false } })
        XCTAssertFalse(targets.contains { if case .loginItem = $0 { true } else { false } })
        XCTAssertFalse(targets.contains { if case .defaultsDomain = $0 { true } else { false } })
        XCTAssertFalse(targets.contains { if case .permissions = $0 { true } else { false } })
        // The LaunchAgent and the state directories are written either way, so
        // they still have to be cleaned up.
        XCTAssertTrue(targets.contains { if case .launchAgent = $0 { true } else { false } })
        XCTAssertEqual(targets.filter { if case .directory = $0 { true } else { false } }.count, 2)
    }

    func testBundleDetectionIgnoresABareBinary() {
        XCTAssertNil(Uninstall.bundleURLIfApp(Bundle(for: Self.self)))
    }

    /// Nothing on the list may be nameless: both alerts read these labels out.
    func testEveryItemHasALabel() {
        XCTAssertTrue(plan().allSatisfy { !$0.label.isEmpty })
    }

    /// Full Disk Access belongs to the whole Mac. `reset All` cleared it from a
    /// standard test account and broke the main account's nightly backup, so
    /// while Kept.app stays, no permission is reset at all.
    func testNoPermissionIsResetWhileTheAppStays() {
        let targets = plan(removeApp: false).map(\.target)
        XCTAssertFalse(targets.contains { if case .permissions = $0 { true } else { false } })
    }

    /// With Kept.app going to the Trash no account can run Kept, so its
    /// grants go too. Left behind, they were invisible in System Settings and
    /// came back switched on with a reinstall.
    func testPermissionsAllGoWhenTheAppGoes() {
        let targets = plan(removeApp: true).map(\.target)
        XCTAssertTrue(targets.contains { if case .permissions = $0 { true } else { false } })
        XCTAssertEqual(
            Uninstall.tccResetArguments(bundleIdentifier: identifier),
            ["reset", "All", identifier])
    }

    /// From an account that can't change /Applications, the app is shared and
    /// stays: no "delete this yourself" for a file the user can't delete and
    /// another account still needs. Everything per-account still goes.
    func testAppStaysWhenThisAccountCantRemoveIt() {
        let targets = plan(removeApp: false).map(\.target)
        XCTAssertFalse(targets.contains { if case .appBundle = $0 { true } else { false } })
        XCTAssertTrue(targets.contains { if case .loginItem = $0 { true } else { false } })
        XCTAssertTrue(targets.contains { if case .launchAgent = $0 { true } else { false } })
        XCTAssertTrue(targets.contains { if case .defaultsDomain = $0 { true } else { false } })
        XCTAssertEqual(targets.filter { if case .directory = $0 { true } else { false } }.count, 2)
    }
}
