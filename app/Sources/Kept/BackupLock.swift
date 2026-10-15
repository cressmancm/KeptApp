import Darwin
import Foundation

/// The backup lock: an exclusive flock on `.backup.pid`, held for as long
/// as a backup runs, or a removal of Kept.
///
/// It used to be a pid written into the file after checking that no live
/// copy of Kept was named there: two steps, so two backups starting at the
/// same moment, in two copies of Kept, could both find it free and both run
/// (production review W2, 2026-10-13). flock is one step, and macOS lets go
/// of it when the process dies however it dies, so a crash leaves nothing
/// behind to tell apart from a live backup. The pid is still written, for
/// the log, and wiped on release.
final class BackupLock: @unchecked Sendable {
    private let descriptor: Int32
    private var released = false

    private init(descriptor: Int32) { self.descriptor = descriptor }

    enum Attempt {
        case acquired(BackupLock)
        /// Another backup has it: that process, when it could be read.
        case held(pid: Int32?)
        /// The file couldn't be opened, so nothing can be known.
        case failed(String)
    }

    /// How long to keep trying while the lock is only held for a look: see
    /// `holder`. A backup holds it far longer than this.
    static let patience: Duration = .milliseconds(500)

    static func acquire(at url: URL = Config.lockFileURL) -> Attempt {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            return .failed("Couldn't open \(url.path): \(String(cString: strerror(errno)))")
        }
        let deadline = ContinuousClock.now + patience
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, ContinuousClock.now < deadline else {
                close(descriptor)
                return .held(pid: holder(at: url))
            }
            usleep(10_000)
        }
        let pid = Data("\(getpid())\n".utf8)
        ftruncate(descriptor, 0)
        _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        return .acquired(BackupLock(descriptor: descriptor))
    }

    /// Lets go: the pid is wiped first, so a version of Kept that still
    /// reads only the pid doesn't take this process for a running backup.
    func release() {
        guard !released else { return }
        released = true
        ftruncate(descriptor, 0)
        close(descriptor)
    }

    deinit { release() }

    /// Whether a backup holds the lock, from this process or another, and if
    /// so its pid (0 when it can't be read). nil when it's free.
    ///
    /// Looking means holding it shared for a moment, which is why `acquire`
    /// keeps trying for a little while before it calls the lock taken.
    static func holder(at url: URL = Config.lockFileURL) -> Int32? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let pid = readPid(descriptor)
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            // Free. A pid with no lock is from Kept 1.3 or earlier, which
            // never took one: running mid-update, it still counts.
            if let pid, pid != getpid(), kill(pid, 0) == 0, BackupEngine.isKept(pid: pid) {
                return pid
            }
            return nil
        }
        return pid ?? 0
    }

    private static func readPid(_ descriptor: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return Int32(
            String(decoding: buffer[0..<count], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
