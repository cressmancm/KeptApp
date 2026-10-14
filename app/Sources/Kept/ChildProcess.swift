import Darwin
import Foundation
import Synchronization

/// A child process Kept owns together with everything it starts.
///
/// Foundation's Process leaves a child in Kept's own process group, and a
/// kill reaches only the child. osxphotos runs a cleanup command for each
/// file it sets aside, /bin/sh and then `Kept --hold-removed`, and those
/// inherit its output. Stop killed osxphotos alone: the shell and the helper
/// lived on and held the output open, so the backup never saw it end, and
/// could go on moving files after it had been stopped. Listing the
/// descendants before a kill, as the stall watchdog did, misses one started
/// between the listing and the kill, and finds none once the parent has died
/// and its children have passed to launchd (production review S7 and W1,
/// 2026-10-13).
///
/// So each child starts as the leader of a process group of its own, and
/// every kill goes to the whole group. The group outlives its leader while
/// any member lives, and macOS never hands its number to another process
/// meanwhile, so nothing the child starts can slip out of reach.
final class ChildProcess: Sendable {
    /// The child's pid, and its process group's.
    let pid: pid_t

    /// How long a killed group gets to end. SIGKILL can't be caught, but a
    /// process blocked in a call on a share that stopped answering dies only
    /// when the call returns, which may be never. It can do nothing more
    /// meanwhile: the kill is waiting for it the moment the call returns.
    static let grace: Duration = .seconds(10)

    private struct State {
        var status: Int32?
        /// Stopped waiting: killed, and still not gone after the grace.
        var abandoned = false
        /// The group has no members left. Never signalled again after this.
        var gone = false
        var waiters: [@Sendable (Int32?) -> Void] = []
    }

    private let state = Mutex(State())

    private init(pid: pid_t) { self.pid = pid }

    struct LaunchError: Error, CustomStringConvertible {
        let executable: String
        let code: Int32
        var description: String {
            "failed to launch \(executable): \(String(cString: strerror(code)))"
        }
    }

    /// Starts `executable` in a process group of its own. Only the three
    /// descriptors given reach it: every other one Kept has open is closed
    /// in the child. Signals start at their defaults, none blocked.
    static func launch(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        directory: URL? = nil,
        stdin: Int32,
        stdout: Int32,
        stderr: Int32
    ) throws -> ChildProcess {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        if let directory {
            posix_spawn_file_actions_addchdir(&actions, directory.path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        // 0: a new group, numbered after the child.
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else { throw LaunchError(executable: executable, code: result) }

        let child = ChildProcess(pid: pid)
        child.reapOnExit()
        return child
    }

    /// Waits for the child on a thread of its own, and records how it ended.
    private func reapOnExit() {
        let thread = Thread { [self] in
            var raw: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &raw, 0) } while reaped == -1 && errno == EINTR
            let status = reaped == pid ? Self.exitStatus(raw) : -1
            let waiters = state.withLock { state in
                state.status = status
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter(status) }
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// The exit code, or the signal that ended it, as Process reports them.
    static func exitStatus(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : signal
    }

    var hasExited: Bool { state.withLock { $0.status != nil } }

    /// How the child ended, once it has. nil when it was killed and is still
    /// there after the grace: see `terminate`.
    func exitStatus() async -> Int32? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            let once = Once(continuation)
            let settled = state.withLock { state -> Int32?? in
                if let status = state.status { return .some(status) }
                if state.abandoned { return .some(nil) }
                state.waiters.append { once.resume($0) }
                return .none
            }
            if let settled { once.resume(settled) }
        }
    }

    /// SIGKILLs the child and everything it started, and after the grace
    /// stops waiting for any of it that hasn't ended. SIGKILL, not SIGTERM: a
    /// process wedged in a call on a dead share may never handle a signal it
    /// can catch.
    func terminate(grace: Duration = ChildProcess.grace) {
        killGroup()
        let seconds = Double(grace.components.seconds)
            + Double(grace.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
            // Again, for anything started while the first went out.
            killGroup()
            let waiters = state.withLock { state -> [@Sendable (Int32?) -> Void] in
                guard state.status == nil else { return [] }
                state.abandoned = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter(nil) }
        }
    }

    /// SIGKILLs every process in the group. Once the group is gone its
    /// number is never signalled again: by then macOS may have given it to
    /// some other process.
    func killGroup() {
        guard !state.withLock({ $0.gone }) else { return }
        if kill(-pid, SIGKILL) != 0, errno == ESRCH {
            state.withLock { $0.gone = true }
        }
    }

    /// Whether anything in the group is still running. The leader counts
    /// until it has been reaped.
    var groupIsAlive: Bool {
        guard !state.withLock({ $0.gone }) else { return false }
        if kill(-pid, 0) == 0 || errno == EPERM { return true }
        state.withLock { $0.gone = true }
        return false
    }

    /// Kills whatever the child left behind once it has ended, and says
    /// whether all of it is gone within the grace.
    func endLeftovers(grace: Duration = ChildProcess.grace) async -> Bool {
        let deadline = ContinuousClock.now + grace
        while true {
            killGroup()
            if !groupIsAlive { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Resumes a continuation once, from whichever caller gets there first.
final class Once<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: Value) {
        let waiting = continuation.withLock { waiting in
            defer { waiting = nil }
            return waiting
        }
        waiting?.resume(returning: value)
    }
}

/// Reads a pipe to its end on a thread of its own.
///
/// Not `FileHandle.bytes`: every AsyncBytes in the process is served from one
/// serial queue, so a read blocked waiting on stderr left stdout undrained. A
/// child writing more than a pipe's 64KB to stdout then blocked forever,
/// never exited, and the run hung until its timeout. A thread of its own,
/// not a shared queue's, also means a read that never returns, its writer
/// stuck on a dead share, holds up nothing but itself.
enum PipeReader {
    static func start(
        _ handle: FileHandle,
        onData: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) {
        let thread = Thread {
            while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
                onData(chunk)
            }
            try? handle.close()
            onEnd()
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Writes `data` to a child's input on a thread of its own, then closes
    /// it so the child reads to the end. A child that stops reading, or
    /// dies, costs an error here rather than Kept a SIGPIPE.
    static func feed(_ data: Data, to handle: FileHandle) {
        let thread = Thread {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written == -1, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
            try? handle.close()
        }
        thread.qualityOfService = .utility
        thread.start()
    }
}

/// Splits a stream of bytes into lines, as they arrive. A line ends at "\n";
/// a "\r" before it is dropped.
struct LineSplitter {
    private var pending = Data()

    mutating func lines(in chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Self.line(pending[pending.startIndex..<end]))
            pending.removeSubrange(pending.startIndex...end)
        }
        return lines
    }

    /// What's left without a newline once the stream has ended.
    mutating func rest() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : Self.line(pending[...])
    }

    private static func line(_ bytes: Data.SubSequence) -> String {
        var bytes = bytes
        if bytes.last == UInt8(ascii: "\r") { bytes = bytes.dropLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
