import Foundation

/// Per-run log file in logs/<timestamp>.log.
final class RunLog {
    let url: URL
    private let handle: FileHandle

    init(at date: Date = .now) throws {
        try FileManager.default.createDirectory(at: Config.logDir, withIntermediateDirectories: true)
        url = Config.logDir.appending(path: "\(Self.fileStamp(date)).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    /// Timestamped line, matching the script's `log()` format.
    func log(_ message: String) {
        appendRaw("\(Self.lineStamp(.now))  \(message)")
    }

    /// Verbatim line (osxphotos output and subprocess chatter).
    func appendRaw(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    func close() {
        try? handle.close()
    }

    static func fileStamp(_ date: Date) -> String {
        format(date, "yyyy-MM-dd_HHmmss")
    }

    static func lineStamp(_ date: Date) -> String {
        format(date, "yyyy-MM-dd HH:mm:ss")
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
