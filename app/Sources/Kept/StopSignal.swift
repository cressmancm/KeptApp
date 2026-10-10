import Foundation
import Synchronization

/// Stop, as one backup's child processes hear it.
///
/// Stop used to reach only osxphotos. Pressed while Kept was reconnecting a
/// share or testing it, it waited out the mount script, the minute spent
/// waiting for the share to appear and the read probe, several minutes in
/// all, before anything happened. Each child Kept starts for a backup now
/// registers here, and firing kills it at once.
final class StopSignal: Sendable {
    private struct State {
        var stopped = false
        var nextToken = 0
        var handlers: [Int: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    var isStopped: Bool { state.withLock { $0.stopped } }

    /// Clears a stop from the previous backup.
    func reset() {
        state.withLock { $0 = State() }
    }

    /// Marks the backup stopped and runs every registered handler.
    func fire() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            state.stopped = true
            defer { state.handlers = [:] }
            return Array(state.handlers.values)
        }
        for handler in handlers { handler() }
    }

    /// Runs `handler` when the backup is stopped, or now if it already is.
    /// Returns a token for `remove`, or nil when it ran immediately.
    @discardableResult
    func onStop(_ handler: @escaping @Sendable () -> Void) -> Int? {
        let token = state.withLock { state -> Int? in
            guard !state.stopped else { return nil }
            state.nextToken += 1
            state.handlers[state.nextToken] = handler
            return state.nextToken
        }
        if token == nil { handler() }
        return token
    }

    func remove(_ token: Int?) {
        guard let token else { return }
        _ = state.withLock { $0.handlers.removeValue(forKey: token) }
    }
}
