import Foundation
import Synchronization

struct CommandResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
}

enum ShellCommand {
    /// Runs an executable to completion, capturing output. If `timeout` elapses
    /// first, the process is SIGKILLed and `timedOut` is set — this is how a
    /// directory read on a zombie SMB mount (which hangs forever) gets bounded.
    /// Firing `stop` SIGKILLs it too.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval? = nil,
        environment: [String: String]? = nil,
        stop: StopSignal? = nil
    ) async -> CommandResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment ?? ChildEnvironment.sanitized()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Registered before launch so an early exit can't slip past it.
        let exited = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            return CommandResult(
                status: -1, stdout: "",
                stderr: "failed to launch \(executable): \(error.localizedDescription)",
                timedOut: false)
        }

        let watchdogFired = Mutex(false)
        var watchdog: Task<Void, Never>?
        if let timeout {
            watchdog = Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, process.isRunning else { return }
                watchdogFired.withLock { $0 = true }
                kill(process.processIdentifier, SIGKILL)
            }
        }

        let pid = process.processIdentifier
        let stopToken = stop?.onStop { kill(pid, SIGKILL) }

        async let outData = collect(outPipe.fileHandleForReading)
        async let errData = collect(errPipe.fileHandleForReading)
        for await _ in exited {}
        watchdog?.cancel()
        stop?.remove(stopToken)

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: await outData, as: UTF8.self),
            stderr: String(decoding: await errData, as: UTF8.self),
            timedOut: watchdogFired.withLock { $0 })
    }

    /// Output kept per stream. Every caller reads a line or two, or a short
    /// tail; past this a child that floods its output — a probe pointed at a
    /// huge or hostile folder, say — would otherwise grow Kept without limit.
    /// The pipe is still drained to the end, so the child never blocks on it.
    static let outputLimit = 4 << 20

    /// Drains one pipe on a thread of its own.
    ///
    /// Not `FileHandle.bytes`: every AsyncBytes in the process is served from
    /// one serial queue, so a read blocked waiting on stderr left stdout
    /// undrained. A child writing more than a pipe's 64KB to stdout then
    /// blocked forever, never exited, and the run hung until its timeout —
    /// or for good, without one, or once orphaned grandchildren held the pipe.
    private static func collect(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var data = Data()
                var truncated = false
                while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
                    let room = outputLimit - data.count
                    if chunk.count > room { truncated = true }
                    if room > 0 { data.append(chunk.prefix(room)) }
                }
                if truncated { data.append(contentsOf: Array("\n[output truncated]\n".utf8)) }
                continuation.resume(returning: data)
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
