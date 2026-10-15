import XCTest

@testable import Kept

/// Production review W2, 2026-10-13: the lock was checked, then written, so
/// two backups starting at the same moment could both run. It's an exclusive
/// flock now (BackupLock), which removing Kept takes too (S8).
final class BackupLockTests: XCTestCase {
    private var lock: URL!

    override func setUp() {
        lock = FileManager.default.temporaryDirectory
            .appending(path: "KeptLock-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: lock)
    }

    private func acquired(_ attempt: BackupLock.Attempt) -> BackupLock? {
        if case .acquired(let held) = attempt { return held }
        return nil
    }

    /// Many at once, as two copies of Kept starting together would: exactly
    /// one gets it. Each attempt opens the file anew, as another process
    /// does, and flock tells those apart just the same.
    func testOfManyAtOnceExactlyOneRuns() async {
        let url = lock!
        let winners = await withTaskGroup(of: BackupLock?.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    guard case .acquired(let held) = BackupLock.acquire(at: url) else { return nil }
                    return held
                }
            }
            var held: [BackupLock] = []
            for await result in group { if let result { held.append(result) } }
            return held
        }
        XCTAssertEqual(winners.count, 1)
        winners.first?.release()
    }

    func testAHeldLockNamesItsHolderAndReleaseFreesIt() throws {
        let held = try XCTUnwrap(acquired(BackupLock.acquire(at: lock)))
        XCTAssertEqual(BackupLock.holder(at: lock), getpid())
        guard case .held(let pid) = BackupLock.acquire(at: lock) else {
            return XCTFail("A held lock was taken again")
        }
        XCTAssertEqual(pid, getpid())

        held.release()
        XCTAssertNil(BackupLock.holder(at: lock))
        // The pid is wiped, so Kept 1.3 doesn't take this process for a backup.
        XCTAssertEqual(try Data(contentsOf: lock), Data())
        XCTAssertNotNil(acquired(BackupLock.acquire(at: lock)))
    }

    /// Another process holds it, then dies without letting go: the lock goes
    /// with it. A pid left behind by a crash used to need a liveness check.
    func testAnotherProcessHoldsItUntilItDies() async throws {
        let perl = "/usr/bin/perl"
        guard FileManager.default.isExecutableFile(atPath: perl) else {
            throw XCTSkip("No perl to hold the lock from another process")
        }
        FileManager.default.createFile(atPath: lock.path, contents: Data("1\n".utf8))
        let ready = FileManager.default.temporaryDirectory.appending(path: "KeptLockReady-\(UUID())")
        defer { try? FileManager.default.removeItem(at: ready) }
        let holder = try ChildProcess.launch(
            perl,
            ["-e", "use Fcntl ':flock'; open(F, '<', $ARGV[0]) or die; flock(F, LOCK_EX) or die; "
                + "open(R, '>', $ARGV[1]); close(R); sleep 60", lock.path, ready.path],
            environment: [:], stdin: 0, stdout: 1, stderr: 2)
        defer { holder.terminate(grace: .seconds(1)) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        guard case .held = BackupLock.acquire(at: lock) else {
            return XCTFail("Taken while another process held it")
        }
        XCTAssertNotNil(BackupLock.holder(at: lock))

        holder.killGroup()
        _ = await holder.exitStatus()
        XCTAssertNil(BackupLock.holder(at: lock))
        XCTAssertNotNil(acquired(BackupLock.acquire(at: lock)))
    }

    /// A pid with no lock is a crash's, or from Kept 1.3, which never took
    /// one. Only a live copy of Kept counts.
    func testALeftoverPidCountsOnlyWhileItsKeptRuns() throws {
        try "99999999\n".write(to: lock, atomically: true, encoding: .utf8)
        XCTAssertNil(BackupLock.holder(at: lock))
        XCTAssertNotNil(acquired(BackupLock.acquire(at: lock)))
    }

    func testALinkInPlaceOfTheLockIsNotFollowed() throws {
        let target = lock.appendingPathExtension("target")
        defer { try? FileManager.default.removeItem(at: target) }
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        guard case .failed = BackupLock.acquire(at: lock) else {
            return XCTFail("The lock was taken through a link")
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }
}
