import Synchronization
import XCTest

@testable import Kept

/// Production review S7 and W1 (with Astra A8 and A9, Fable F4 and F6),
/// 2026-10-13: Stop, the stall watchdog and the cleanup deadlines must end
/// everything a backup started, promptly, and nothing may go on moving or
/// deleting files afterwards.
final class ProcessGroupTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appending(path: "KeptProcessGroupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Anything a failed test left running.
        for pid in pids() { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: scratch)
    }

    private let fast = BackupEngine.Timing(
        probe: 1, slowProbe: 2,
        unmountSettle: .milliseconds(10), mountPoll: .milliseconds(10),
        mountTimeout: .milliseconds(300),
        stall: .seconds(1), stallCheck: .milliseconds(100), stallSampleSecs: 1,
        volumeCall: 5, expiry: 0.5, emptyFolders: 0.5, grace: .seconds(2))

    private var pidFile: String { scratch.appending(path: "pids").path }
    private var lateFile: String { scratch.appending(path: "late").path }

    /// The pids the scripts below recorded.
    private func pids() -> [pid_t] {
        ((try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { pid_t($0) }
    }

    private func assertAllEnded(file: StaticString = #filePath, line: UInt = #line) {
        let recorded = pids()
        XCTAssertFalse(recorded.isEmpty, "nothing was started", file: file, line: line)
        for pid in recorded {
            XCTAssertNotEqual(kill(pid, 0), 0, "pid \(pid) is still running", file: file, line: line)
        }
    }

    /// A cleanup command, as osxphotos runs one: a child of its own that
    /// shares the output, ignores SIGTERM, and would write a file late.
    private var lingeringHelper: String {
        """
        sh -c 'trap "" TERM; echo $$ >> "\(pidFile)"; sleep 30; echo late > "\(lateFile)"' &
        """
    }

    /// Waits until the cleanup command is running, so a test proves it's
    /// ended rather than never started.
    private var untilItsRunning: String {
        "while [ ! -s \"\(pidFile)\" ]; do sleep 0.01; done"
    }

    private func script(_ name: String, _ body: String) throws -> URL {
        let url = scratch.appending(path: "\(name)-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func backupFolder() throws -> Destination {
        let folder = scratch.appending(path: "Backup")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Destination(path: folder.path, isNetwork: false)
    }

    private func runLog() throws -> RunLog { try RunLog(in: scratch.appending(path: "logs")) }

    private func logText(_ log: RunLog) throws -> String {
        log.close()
        return try String(contentsOf: log.url, encoding: .utf8)
    }

    // MARK: - Stop

    /// Stop used to kill osxphotos alone. Its cleanup command held the output
    /// open, and the backup waited on it.
    func testStopEndsTheExportAndItsCleanupCommand() async throws {
        let python = try script("python", "echo started\n\(lingeringHelper)\nwait")
        let engine = BackupEngine(timing: fast, python: python, workingDirectory: scratch)
        nonisolated(unsafe) let log = try runLog()
        let folder = try backupFolder()
        let started = ContinuousClock.now
        let export = Task {
            try await engine.runExport(folder, log, onProgress: { _ in }, onLogTail: { _ in })
        }
        while pids().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        await engine.cancel()
        do {
            _ = try await export.value
            XCTFail("Expected the export to stop")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .cancelled)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        assertAllEnded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateFile))
    }

    /// osxphotos ending while a child it started still holds the output:
    /// the backup used to wait for the child.
    func testAnExportThatEndsBeforeItsChildIsNotKeptWaiting() async throws {
        let python = try script(
            "python", "echo started\n\(lingeringHelper)\n\(untilItsRunning)\nexit 0")
        let engine = BackupEngine(timing: fast, python: python, workingDirectory: scratch)
        nonisolated(unsafe) let log = try runLog()
        let started = ContinuousClock.now
        _ = try await engine.runExport(
            try backupFolder(), log, onProgress: { _ in }, onLogTail: { _ in })
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        assertAllEnded()
    }

    /// Fable F6: the watchdog listed the children, then killed the parent. A
    /// child started in between escaped, and held the output. A process
    /// group takes in every child, however late.
    func testTheStallWatchdogEndsEveryChildHoweverLate() async throws {
        let python = try script("python", """
            echo started
            while :; do sleep 30 & echo $! >> "\(pidFile)"; sleep 0.02; done
            """)
        let engine = BackupEngine(timing: fast, python: python, workingDirectory: scratch)
        nonisolated(unsafe) let log = try runLog()
        let started = ContinuousClock.now
        do {
            _ = try await engine.runExport(
                try backupFolder(), log, onProgress: { _ in }, onLogTail: { _ in })
            XCTFail("Expected the hung export to fail")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .exportFailed)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(30))
        assertAllEnded()
    }

    // MARK: - The cleanup helper

    func testExpiryPastItsDeadlineIsEndedAndTheBackupGoesOn() async throws {
        let helper = try script("kept", """
            echo $$ >> "\(pidFile)"
            echo "Deleted Removed from Photos/2026-01-01 (1 file): older than 90 days."
            \(lingeringHelper)
            sleep 30
            """)
        let engine = BackupEngine(timing: fast, helper: helper)
        nonisolated(unsafe) let log = try runLog()
        let started = ContinuousClock.now
        try await engine.expireRemovedPhotos(try backupFolder(), log)
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        assertAllEnded()
        let text = try logText(log)
        XCTAssertTrue(text.contains("Deleted Removed from Photos/2026-01-01"), text)
        XCTAssertTrue(text.contains("Stopped deleting expired removed photos"), text)
    }

    func testStopEndsExpiry() async throws {
        let helper = try script("kept", "echo $$ >> \"\(pidFile)\"\n\(lingeringHelper)\nsleep 30")
        var slow = fast
        slow.expiry = 60
        let engine = BackupEngine(timing: slow, helper: helper)
        nonisolated(unsafe) let log = try runLog()
        let folder = try backupFolder()
        let started = ContinuousClock.now
        let expiry = Task { try await engine.expireRemovedPhotos(folder, log) }
        while pids().count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        await engine.cancel()
        do {
            try await expiry.value
            XCTFail("Expected expiry to stop")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .cancelled)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        assertAllEnded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateFile))
    }

    /// The empty folders an export leaves are removed by the helper too,
    /// told the moved files on its input, and under its own deadline.
    func testEmptyFolderRemovalIsGivenTheMovedFilesAndADeadline() async throws {
        let received = scratch.appending(path: "received").path
        let helper = try script("kept", """
            echo $$ >> "\(pidFile)"
            cat > "\(received)"
            echo "Removed 1 empty folder."
            sleep 30
            """)
        let python = try script("python", """
            echo "Moved to Removed from Photos/2026-10-13/2024/05/01/IMG_1.jpg"
            echo "Moved to Removed from Photos/2026-10-13/2024/05/02/IMG_2.jpg"
            """)
        let engine = BackupEngine(
            timing: fast, python: python, workingDirectory: scratch, helper: helper)
        nonisolated(unsafe) let log = try runLog()
        let started = ContinuousClock.now
        _ = try await engine.runExport(
            try backupFolder(), log, onProgress: { _ in }, onLogTail: { _ in })
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        assertAllEnded()
        XCTAssertEqual(
            try String(contentsOfFile: received, encoding: .utf8),
            "2024/05/01/IMG_1.jpg\n2024/05/02/IMG_2.jpg\n")
        let text = try logText(log)
        XCTAssertTrue(text.contains("Removed 1 empty folder."), text)
        XCTAssertTrue(text.contains("Stopped removing empty folders"), text)
    }

    /// A killed child that hasn't ended may still be inside a call on the
    /// share. Nothing else touches the folder until it's gone.
    func testNothingTouchesTheFolderWhileAKilledChildLingers() async throws {
        let ran = scratch.appending(path: "ran").path
        let helper = try script("kept", "touch \"\(ran)\"")
        let engine = BackupEngine(timing: fast, helper: helper)
        let lingering = try ChildProcess.launch(
            "/bin/sleep", ["30"], environment: [:], stdin: 0, stdout: 1, stderr: 2)
        defer { lingering.killGroup() }
        await engine.remember(stuck: lingering)
        nonisolated(unsafe) let log = try runLog()
        let folder = try backupFolder()
        do {
            try await engine.expireRemovedPhotos(folder, log)
            XCTFail("Expected expiry to be refused")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .volumeUnreachable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran))

        lingering.killGroup()
        _ = await lingering.exitStatus()
        try await engine.expireRemovedPhotos(folder, log)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ran))
    }

    // MARK: - What the helper does

    func testTheHelperExpiresWhatsDueAndReportsIt() throws {
        let root = scratch.appending(path: "Backup")
        let holding = RemovedPhotos.holdingFolder(in: root)
        try FileManager.default.createDirectory(
            at: holding.appending(path: "2020-01-01"), withIntermediateDirectories: true)
        try Data().write(to: holding.appending(path: "2020-01-01/IMG_1.jpg"))
        let today = RemovedPhotos.folderName(for: .now)
        try FileManager.default.createDirectory(
            at: holding.appending(path: today), withIntermediateDirectories: true)

        let (status, output) = RemovedPhotos.maintenance(
            arguments: ["Kept", RemovedPhotos.expireFlag, "90"],
            environment: [RemovedPhotos.backupRootVariable: root.path], input: { Data() })
        XCTAssertEqual(status, 0)
        XCTAssertEqual(
            output, ["Deleted Removed from Photos/2020-01-01 (1 file): older than 90 days."])
        XCTAssertTrue(FileManager.default.fileExists(atPath: holding.appending(path: today).path))
    }

    func testTheHelperRemovesTheFoldersItIsToldOf() throws {
        let root = scratch.appending(path: "Backup")
        try FileManager.default.createDirectory(
            at: root.appending(path: "2024/05/01"), withIntermediateDirectories: true)
        let (status, output) = RemovedPhotos.maintenance(
            arguments: ["Kept", RemovedPhotos.removeEmptyFlag],
            environment: [RemovedPhotos.backupRootVariable: root.path],
            input: { Data("2024/05/01/IMG_1.jpg\n".utf8) })
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output, ["Removed 3 empty folders."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "2024").path))
    }

    func testTheHelperRefusesWhatItWasntBuiltFor() {
        let root = [RemovedPhotos.backupRootVariable: scratch.path]
        XCTAssertEqual(
            RemovedPhotos.maintenance(
                arguments: ["Kept", RemovedPhotos.expireFlag], environment: root,
                input: { Data() }).status, 64)
        // "Forever" isn't a retention setting.
        XCTAssertEqual(
            RemovedPhotos.maintenance(
                arguments: ["Kept", RemovedPhotos.expireFlag, "100000"], environment: root,
                input: { Data() }).status, 64)
        XCTAssertEqual(
            RemovedPhotos.maintenance(
                arguments: ["Kept", RemovedPhotos.expireFlag, "90"], environment: [:],
                input: { Data() }).status, 64)
    }

    // MARK: - Every command Kept runs

    /// A probe's leftover child used to hold its output, and the probe's
    /// result, until the child ended.
    func testACommandIsNotKeptWaitingByWhatItLeftRunning() async {
        let started = ContinuousClock.now
        let result = await ShellCommand.run(
            "/bin/sh", ["-c", "\(lingeringHelper)\n\(untilItsRunning)\necho hi"], timeout: 20)
        XCTAssertEqual(result.stdout, "hi\n")
        XCTAssertNil(result.stuck)
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        try? await Task.sleep(for: .milliseconds(100))
        assertAllEnded()
    }

    func testATimeoutEndsTheWholeCommand() async {
        let started = ContinuousClock.now
        let result = await ShellCommand.run(
            "/bin/sh", ["-c", "\(lingeringHelper) wait"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        assertAllEnded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateFile))
    }

    func testInputReachesTheCommand() async {
        let result = await ShellCommand.run("/bin/cat", input: Data("a\nb\n".utf8))
        XCTAssertEqual(result.stdout, "a\nb\n")
        XCTAssertEqual(result.status, 0)
    }

    func testOutputIsSplitIntoLinesAsItArrives() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.lines(in: Data("one\r\ntw".utf8)), ["one"])
        XCTAssertEqual(splitter.lines(in: Data("o\n\nthree".utf8)), ["two", ""])
        XCTAssertEqual(splitter.rest(), "three")
        XCTAssertNil(splitter.rest())
    }
}
