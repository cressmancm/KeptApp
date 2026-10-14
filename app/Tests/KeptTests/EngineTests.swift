import Synchronization
import XCTest

@testable import Kept

/// The engine's steps, run for real: reconnecting a share against scripted
/// commands, and the export against small shell scripts standing in for
/// osxphotos. Everything is written under a temporary folder.
final class EngineTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appending(path: "KeptEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private let fast = BackupEngine.Timing(
        probe: 1, slowProbe: 2,
        unmountSettle: .milliseconds(10), mountPoll: .milliseconds(10),
        mountTimeout: .milliseconds(300),
        stall: .seconds(1), stallCheck: .milliseconds(100), stallSampleSecs: 1,
        volumeCall: 5)

    private func runLog() throws -> RunLog { try RunLog(in: scratch.appending(path: "logs")) }

    // MARK: - Reconnecting a share

    private let share = Destination(
        path: "/Volumes/Photos/Backup", isNetwork: true,
        smbURL: "smb://chip@nas.local/Photos", mountPoint: "/Volumes/Photos")

    private static let mountedLine =
        "//chip@nas.local/Photos on /Volumes/Photos (smbfs, nodev, nosuid, mounted by chip)\n"

    func testAHealthyShareIsLeftAlone() async throws {
        let commands = FakeCommands { call, _ in
            switch call.executable {
            case "/sbin/mount": .ok(Self.mountedLine)
            default: .ok()
            }
        }
        let engine = BackupEngine(timing: fast, command: commands.runner)
        nonisolated(unsafe) let log = try runLog()
        try await engine.ensureMount(share, log)
        XCTAssertEqual(commands.executables, ["/sbin/mount", "/bin/ls"])
    }

    /// A NAS waking its disks can miss the first probe. It gets a second,
    /// longer one before anything forces it off.
    func testASlowShareGetsALongerSecondProbe() async throws {
        let probes = Mutex(0)
        let commands = FakeCommands { call, _ in
            switch call.executable {
            case "/sbin/mount": return .ok(Self.mountedLine)
            case "/bin/ls":
                let n = probes.withLock { n in n += 1; return n }
                return n == 1 ? .hung : .ok()
            default: return .ok()
            }
        }
        let engine = BackupEngine(timing: fast, command: commands.runner)
        nonisolated(unsafe) let log = try runLog()
        try await engine.ensureMount(share, log)
        XCTAssertEqual(commands.executables, ["/sbin/mount", "/bin/ls", "/bin/ls"])
        XCTAssertEqual(commands.calls.filter { $0.executable == "/bin/ls" }.map(\.timeout), [1, 2])
    }

    func testAStaleShareIsForcedOffAndRemounted() async throws {
        let share = Mutex((mounted: true, healthy: false))
        let commands = FakeCommands { call, _ in
            switch call.executable {
            case "/sbin/mount":
                return .ok(share.withLock { $0.mounted } ? Self.mountedLine : "")
            case "/bin/ls":
                return share.withLock { $0.healthy } ? .ok() : .hung
            case "/usr/sbin/diskutil":
                share.withLock { $0.mounted = false }
                return .ok()
            case "/usr/bin/osascript":
                share.withLock { $0 = (true, true) }
                return .ok()
            default:
                return .ok()
            }
        }
        let engine = BackupEngine(timing: fast, command: commands.runner)
        nonisolated(unsafe) let log = try runLog()
        try await engine.ensureMount(self.share, log)
        let order = commands.executables
        let unmount = try XCTUnwrap(order.firstIndex(of: "/usr/sbin/diskutil"))
        let mount = try XCTUnwrap(order.firstIndex(of: "/usr/bin/osascript"))
        XCTAssertLessThan(unmount, mount)
        XCTAssertEqual(order.last, "/bin/ls")
    }

    /// Stop used to wait out the reconnect: up to two minutes of mount script
    /// and a minute of waiting for the share.
    func testStopInterruptsAReconnect() async throws {
        let commands = FakeCommands { call, stop in
            guard call.executable == "/usr/bin/osascript" else { return .ok() }
            // A real child is SIGKILLed by the stop signal; this one notices.
            for _ in 0..<1000 where stop?.isStopped != true {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return CommandResult(status: 9, stdout: "", stderr: "", timedOut: false)
        }
        let engine = BackupEngine(timing: fast, command: commands.runner)
        nonisolated(unsafe) let log = try runLog()
        let started = ContinuousClock.now
        let target = share
        let reconnect = Task { try await engine.ensureMount(target, log) }
        while !commands.executables.contains("/usr/bin/osascript") {
            try await Task.sleep(for: .milliseconds(10))
        }
        await engine.cancel()
        do {
            try await reconnect.value
            XCTFail("Expected the reconnect to stop")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .cancelled)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
    }

    // MARK: - The export

    /// A stand-in for the bundled interpreter. Whatever arguments it gets, it
    /// runs `body`.
    private func fakePython(_ body: String) throws -> URL {
        let url = scratch.appending(path: "python-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func backupFolder() throws -> Destination {
        let folder = scratch.appending(path: "Backup")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Destination(path: folder.path, isNetwork: false)
    }

    private func export(with engine: BackupEngine, log: RunLog) async throws -> ExportProgress {
        nonisolated(unsafe) let log = log
        return try await engine.runExport(
            try backupFolder(), log, onProgress: { _ in }, onLogTail: { _ in })
    }

    func testAFailedExportIsRetriedOnce() async throws {
        let count = scratch.appending(path: "count").path
        let python = try fakePython("""
            n=$(cat "\(count)" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "\(count)"
            echo "Exporting IMG_1.jpg"
            [ "$n" -ge 2 ]
            """)
        let engine = BackupEngine(
            timing: fast, python: python, exportGuard: ExportGuardTests.source,
            workingDirectory: scratch)
        _ = try await export(with: engine, log: try runLog())
        XCTAssertEqual(try String(contentsOfFile: count, encoding: .utf8), "2\n")
    }

    func testAnExportThatKeepsFailingFails() async throws {
        let engine = BackupEngine(
            timing: fast, python: try fakePython("exit 1"),
            exportGuard: ExportGuardTests.source, workingDirectory: scratch)
        do {
            _ = try await export(with: engine, log: runLog())
            XCTFail("Expected the export to fail")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .exportFailed)
        }
    }

    /// The hang of 2026-07-31: output stops and never resumes. The watchdog
    /// kills it, both attempts, and the backup fails rather than hanging.
    func testAHungExportIsKilled() async throws {
        let python = try fakePython("echo started; exec sleep 60")
        let engine = BackupEngine(
            timing: fast, python: python, exportGuard: ExportGuardTests.source,
            workingDirectory: scratch)
        nonisolated(unsafe) let log = try runLog()
        let started = ContinuousClock.now
        do {
            _ = try await export(with: engine, log: log)
            XCTFail("Expected the export to fail")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .exportFailed)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(30))
        log.close()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(text.contains("hung and has been killed"), text)
    }

    func testStopEndsTheExport() async throws {
        let python = try fakePython("echo started; exec sleep 60")
        let engine = BackupEngine(
            timing: fast, python: python, exportGuard: ExportGuardTests.source,
            workingDirectory: scratch)
        nonisolated(unsafe) let log = try runLog()
        let folder = try backupFolder()
        let started = ContinuousClock.now
        let export = Task {
            try await engine.runExport(folder, log, onProgress: { _ in }, onLogTail: { _ in })
        }
        try await Task.sleep(for: .milliseconds(500))
        await engine.cancel()
        do {
            _ = try await export.value
            XCTFail("Expected the export to stop")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .cancelled)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
    }

    // MARK: - Pieces

    func testAStopSignalKillsARunningCommand() async {
        let stop = StopSignal()
        let started = ContinuousClock.now
        async let result = ShellCommand.run("/bin/sleep", ["30"], stop: stop)
        try? await Task.sleep(for: .milliseconds(200))
        stop.fire()
        let finished = await result
        XCTAssertNotEqual(finished.status, 0)
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
    }

    func testAStopSignalAlreadyFiredRunsAHandlerAtOnce() {
        let stop = StopSignal()
        stop.fire()
        let ran = Mutex(false)
        XCTAssertNil(stop.onStop { ran.withLock { $0 = true } })
        XCTAssertTrue(ran.withLock { $0 })
        stop.reset()
        XCTAssertFalse(stop.isStopped)
    }

    /// A call that hangs gives up its caller, and the lane refuses another
    /// until the hung one returns: one blocked thread at most, however often
    /// the panel opens.
    func testABlockingLaneTimesOutAndStaysBusy() async {
        let lane = BlockingLane()
        guard case .finished(let value) = await lane.run(timeout: 5, { 42 }) else {
            return XCTFail("Expected a quick call to finish")
        }
        XCTAssertEqual(value, 42)

        guard case .timedOut = await lane.run(timeout: 0.1, { Thread.sleep(forTimeInterval: 1) })
        else { return XCTFail("Expected a slow call to time out") }
        guard case .busy = await lane.run(timeout: 5, { 1 }) else {
            return XCTFail("Expected the lane to be busy")
        }
        try? await Task.sleep(for: .seconds(1.5))
        guard case .finished = await lane.run(timeout: 5, { 1 }) else {
            return XCTFail("Expected the lane to be free again")
        }
    }

    // MARK: - Kept's own files before Python (production review S4)

    /// Test Library Access ran the bundled Python without checking the
    /// bundle. Now a changed bundle starts nothing.
    func testTestLibraryAccessRunsNothingFromAChangedBundle() async throws {
        let marker = scratch.appending(path: "python-ran")
        let python = try fakePython("touch \"\(marker.path)\"")
        let engine = BackupEngine(
            timing: fast, python: python, exportGuard: ExportGuardTests.source, workingDirectory: scratch,
            appBundle: scratch.appending(path: "Kept.app"), appSeal: { _ in false })
        let result = await engine.accessTest()
        XCTAssertEqual(result, "Part of Kept has been changed. Reinstall it.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Checked before each launch of osxphotos, not only at the start.
    func testAnExportRunsNothingFromAChangedBundle() async throws {
        let marker = scratch.appending(path: "python-ran")
        let python = try fakePython("touch \"\(marker.path)\"")
        let engine = BackupEngine(
            timing: fast, python: python, exportGuard: ExportGuardTests.source, workingDirectory: scratch,
            appBundle: scratch.appending(path: "Kept.app"), appSeal: { _ in false })
        do {
            _ = try await export(with: engine, log: try runLog())
            XCTFail("A changed bundle was run")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .setupFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

/// Scripted stand-in for the engine's child processes.
final class FakeCommands: Sendable {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    typealias Responder = @Sendable (Call, StopSignal?) async -> CommandResult

    private let responder: Responder
    private let log = Mutex<[Call]>([])

    init(_ responder: @escaping Responder) {
        self.responder = responder
    }

    var calls: [Call] { log.withLock { $0 } }
    var executables: [String] { calls.map(\.executable) }

    var runner: BackupEngine.CommandRunner {
        { [self] executable, arguments, timeout, stop in
            let call = Call(executable: executable, arguments: arguments, timeout: timeout)
            log.withLock { $0.append(call) }
            return await responder(call, stop)
        }
    }
}

extension CommandResult {
    static func ok(_ stdout: String = "") -> CommandResult {
        CommandResult(status: 0, stdout: stdout, stderr: "", timedOut: false)
    }

    static func failed(_ stderr: String) -> CommandResult {
        CommandResult(status: 1, stdout: "", stderr: stderr, timedOut: false)
    }

    static let hung = CommandResult(status: 9, stdout: "", stderr: "", timedOut: true)
}
