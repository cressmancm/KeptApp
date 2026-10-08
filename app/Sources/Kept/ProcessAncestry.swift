import Darwin
import Foundation

/// Who started this process, by executable path.
///
/// `Kept --hold-removed` is meant to be run by osxphotos, which Kept itself
/// started: Kept → python3 → /bin/sh → Kept. macOS judges a process's privacy
/// access by the app responsible for it, so the same command started any
/// other way — by launchd, from a LaunchAgent anyone running as this user can
/// write — runs with Kept's own Full Disk Access. Requiring a running copy of
/// this very executable somewhere above it closes that door: an outside
/// process cannot put one there, because Kept never runs a caller's command.
enum ProcessAncestry {
    /// Enough for Kept → python3 → sh → Kept with room to spare; the walk
    /// stops at launchd long before this on any real chain.
    static let maxDepth = 8

    static func isDescendantOfOwnExecutable() -> Bool {
        guard let own = executablePath(of: getpid()) else { return false }
        return ancestorExecutables().contains(own)
    }

    /// Executable paths of this process's ancestors, nearest first, stopping
    /// at launchd.
    static func ancestorExecutables(maxDepth: Int = maxDepth) -> [String] {
        var paths: [String] = []
        var pid = getppid()
        for _ in 0..<maxDepth where pid > 1 {
            guard let path = executablePath(of: pid) else { break }
            paths.append(path)
            guard let parent = parentPID(of: pid) else { break }
            pid = parent
        }
        return paths
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Every process descended from `pid`, children before grandchildren.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var queue = [pid]
        while !queue.isEmpty, found.count < 4096 {
            let parent = queue.removeFirst()
            let count = proc_listchildpids(parent, nil, 0)
            guard count > 0 else { continue }
            var children = [pid_t](repeating: 0, count: Int(count) + 16)
            let filled = proc_listchildpids(
                parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            guard filled > 0 else { continue }
            let kids = children.prefix(Int(filled)).filter { $0 > 0 }
            found.append(contentsOf: kids)
            queue.append(contentsOf: kids)
        }
        return found
    }
}
