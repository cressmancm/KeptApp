import Foundation
import Synchronization

struct CommandResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    /// Killed, and still not gone after the grace: blocked, most likely, on
    /// a share that stopped answering. It can do nothing more, but Kept
    /// mustn't start anything that touches the same folder until it's gone.
    var stuck: ChildProcess? = nil
}

enum ShellCommand {
    /// Runs an executable to completion, capturing output. If `timeout` elapses
    /// first, the process is SIGKILLed and `timedOut` is set — this is how a
    /// directory read on a zombie SMB mount (which hangs forever) gets bounded.
    /// Firing `stop` SIGKILLs it too. `input` is written to its standard input.
    ///
    /// The kill takes everything the command started with it, and so does
    /// the command ending: nothing Kept runs is meant to outlive it, and a
    /// leftover holding the output open kept the run from ever returning.
    /// See ChildProcess.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval? = nil,
        environment: [String: String]? = nil,
        input: Data = Data(),
        stop: StopSignal? = nil
    ) async -> CommandResult {
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let child: ChildProcess
        do {
            child = try ChildProcess.launch(
                executable, arguments,
                environment: environment ?? ChildEnvironment.sanitized(),
                stdin: inPipe.fileHandleForReading.fileDescriptor,
                stdout: outPipe.fileHandleForWriting.fileDescriptor,
                stderr: errPipe.fileHandleForWriting.fileDescriptor)
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }
        // The child has its own copies. With these still open here, its
        // output would never end.
        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        PipeReader.feed(input, to: inPipe.fileHandleForWriting)
        let stdout = Collected(outPipe.fileHandleForReading)
        let stderr = Collected(errPipe.fileHandleForReading)

        let watchdogFired = Mutex(false)
        var watchdog: Task<Void, Never>?
        if let timeout {
            watchdog = Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, !child.hasExited else { return }
                watchdogFired.withLock { $0 = true }
                child.terminate()
            }
        }
        let stopToken = stop?.onStop { child.terminate() }

        let status = await child.exitStatus()
        watchdog?.cancel()
        stop?.remove(stopToken)
        let ended = await child.endLeftovers()

        return CommandResult(
            status: status ?? -1,
            stdout: String(decoding: await stdout.data(), as: UTF8.self),
            stderr: String(decoding: await stderr.data(), as: UTF8.self),
            timedOut: watchdogFired.withLock { $0 },
            stuck: status == nil || !ended ? child : nil)
    }

    /// Output kept per stream. Every caller reads a line or two, or a short
    /// tail; past this a child that floods its output — a probe pointed at a
    /// huge or hostile folder, say — would otherwise grow Kept without limit.
    /// The pipe is still drained to the end, so the child never blocks on it.
    static let outputLimit = 4 << 20

    /// One stream's output, drained as it comes.
    private final class Collected: Sendable {
        private struct State {
            var data = Data()
            var truncated = false
            var ended = false
            var waiter: Once<Void>?
        }

        private let state = Mutex(State())

        init(_ handle: FileHandle) {
            PipeReader.start(
                handle,
                onData: { [self] chunk in
                    state.withLock { state in
                        let room = ShellCommand.outputLimit - state.data.count
                        if chunk.count > room { state.truncated = true }
                        if room > 0 { state.data.append(chunk.prefix(room)) }
                    }
                },
                onEnd: { [self] in
                    let waiter = state.withLock { state in
                        state.ended = true
                        return state.waiter
                    }
                    waiter?.resume(())
                })
        }

        /// Everything read, once the stream ends, or what there is after the
        /// grace: a leftover stuck on a dead share can hold it open for good.
        func data(grace: Duration = ChildProcess.grace) async -> Data {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = Once(continuation)
                let ended = state.withLock { state in
                    if !state.ended { state.waiter = once }
                    return state.ended
                }
                if ended { return once.resume(()) }
                let seconds = Double(grace.components.seconds)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                    once.resume(())
                }
            }
            return state.withLock { state in
                var data = state.data
                if state.truncated { data.append(contentsOf: Array("\n[output truncated]\n".utf8)) }
                return data
            }
        }
    }
}

/// The environment every child process gets.
///
/// Kept's own environment is whatever launched it chose — and a LaunchAgent
/// anyone running as this user can write may launch it with any variables at
/// all. Children run with Kept's Full Disk Access, so they get an allow-list
/// rather than a copy: locale, identity, and HOME and TMPDIR read from the
/// system rather than from the inherited values (osxphotos depends on all
/// three), and a fixed PATH, so nothing that resolves a program by name can be
/// pointed at someone else's.
enum ChildEnvironment {
    static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

    static func sanitized(
        from inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment: [String: String] = ["PATH": path]
        for (key, value) in inherited
        where key == "LANG" || key.hasPrefix("LC_") || key == "__CF_USER_TEXT_ENCODING" {
            environment[key] = value
        }
        if let account = getpwuid(getuid()) {
            environment["USER"] = String(cString: account.pointee.pw_name)
            environment["LOGNAME"] = String(cString: account.pointee.pw_name)
            environment["HOME"] = String(cString: account.pointee.pw_dir)
        }
        environment["TMPDIR"] = systemTemporaryDirectory()
        return environment
    }

    /// This user's private temporary folder, as the system assigns it.
    private static func systemTemporaryDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return "/tmp/" }
        return String(decoding: buffer.prefix(length - 1).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
