import Foundation
import Synchronization

/// Runs calls that can block forever, one at a time, on a thread of their own.
///
/// A `statfs`, an existence check or a directory listing on a network share
/// that has stopped answering doesn't fail: it blocks, sometimes for good.
/// Run from Swift concurrency, such a call holds one of the cooperative
/// pool's threads, of which there are about as many as cores. A few of them,
/// one per panel open, starved every task in the app, the engine's included:
/// the backup in progress never finished, `isRunning` stayed true, and every
/// later backup was dropped without a word. Here each call gets its own
/// thread, a lane runs one call at a time, and a caller can stop waiting.
final class BlockingLane: Sendable {
    enum Outcome<Value: Sendable>: Sendable {
        case finished(Value)
        /// The call took longer than the timeout. Its thread is left to
        /// finish, or not, on its own, and the lane stays busy until it does.
        case timedOut
        /// An earlier call, one that timed out, still hasn't returned.
        case busy
    }

    private let busy = Mutex(false)

    func run<Value: Sendable>(
        timeout: TimeInterval? = nil, _ work: @escaping @Sendable () -> Value
    ) async -> Outcome<Value> {
        let claimed = busy.withLock { busy in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard claimed else { return .busy }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<Value>, Never>) in
            let pending = Mutex<CheckedContinuation<Outcome<Value>, Never>?>(continuation)
            let finish: @Sendable (Outcome<Value>) -> Void = { outcome in
                let waiting = pending.withLock { waiting in
                    defer { waiting = nil }
                    return waiting
                }
                waiting?.resume(returning: outcome)
            }
            let thread = Thread { [self] in
                let value = work()
                busy.withLock { $0 = false }
                finish(.finished(value))
            }
            thread.qualityOfService = .utility
            thread.start()
            if let timeout {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    finish(.timedOut)
                }
            }
        }
    }
}
