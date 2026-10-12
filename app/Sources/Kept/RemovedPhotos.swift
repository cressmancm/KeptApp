import Foundation

/// Photos deleted from the library stay in the backup for a while before the
/// mirror lets them go.
///
/// `--cleanup` used to delete them on the next backup, so a photo deleted by
/// mistake was gone from both places within a day. Now osxphotos hands each
/// file it would delete to `Kept --hold-removed` (its `--cleanup-command`),
/// which moves it into "Removed from Photos/<date>/" at the top of the backup
/// folder, keeping its original path beneath that. A `--keep` rule stops the
/// command being run on the folder's own files, and every backup first
/// deletes the dated folders older than the retention setting. Nothing is
/// kept forever.
///
/// osxphotos runs WITHOUT `--cleanup`. Its cleanup builds the list of files
/// to keep before the command runs, so on 2026-10-06 it deleted every file
/// the command had just moved: a `--keep` rule only protects files that
/// already existed. Without `--cleanup` osxphotos deletes nothing, the
/// command moves everything cleanup would have deleted, and Kept removes the
/// folders that leaves empty (`removeEmptyFolders`).
enum RemovedPhotos {
    /// Visible on purpose: restoring a photo is a drag out of the Finder.
    static let folderName = "Removed from Photos"
    static let retentionChoices = [30, 90, 365]
    static let defaultRetentionDays = 90

    /// Starts every line the helper writes into the run log, so the engine can
    /// count them.
    static let logPrefix = "Moved to \(folderName)/"

    /// Environment variables the engine sets for the cleanup command. Passed
    /// this way rather than spliced into the command, because osxphotos
    /// renders the command as a template and runs it through a shell: a path
    /// with braces or quotes in it would be mangled by one or the other.
    static let executableVariable = "KEPT_EXECUTABLE"
    static let backupRootVariable = "KEPT_BACKUP_ROOT"

    /// What osxphotos runs for each file. `{filepath|shell_quote}` is its own
    /// template, quoted for the shell (verified against osxphotos 0.77.2 with a
    /// file named `it's a {pic}.jpg`).
    static let cleanupCommand =
        "\"$\(executableVariable)\" --hold-removed {filepath|shell_quote}"

    /// The stored setting, held to the offered choices so a hand-edited value
    /// can't mean "forever".
    static func retentionDays(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: Preferences.removedRetentionDays)
        return retentionChoices.contains(stored) ? stored : defaultRetentionDays
    }

    static func holdingFolder(in backupRoot: URL) -> URL {
        backupRoot.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// "2026-10-06", in the local calendar: the day the user would say the
    /// photo was removed.
    static func folderName(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    struct HoldError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Holding a file

    /// Moves one file the mirror would delete into today's dated folder, under
    /// its original path. Returns where it went, or nil if it was already gone.
    ///
    /// Refuses anything outside the backup folder: the path comes from
    /// osxphotos' command line, and a move is the one thing here that could
    /// carry a file somewhere it doesn't belong. A file already in the holding
    /// folder is left where it is (nil): osxphotos can come across one it was
    /// just handed, because it walks the folder while files are moved into it.
    @discardableResult
    static func hold(_ file: URL, backupRoot: URL, now: Date = .now) throws -> URL? {
        let root = backupRoot.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else {
            throw HoldError(description: "\(path) is outside the backup folder \(root)")
        }
        let relative = String(path.dropFirst(root.count + 1))
        guard relative != folderName, !relative.hasPrefix(folderName + "/") else {
            return nil
        }

        // No folder between the backup folder and either end of the move may
        // be a link. Anyone who can write to the share can plant one, and the
        // Mac resolves it locally: "Removed from Photos/2026-10-06" pointing at
        // ~/Library/LaunchAgents would turn the next move into a file written
        // there. osxphotos never descends through a linked folder, so a source
        // path that runs through one didn't come from it either. NoFollow does
        // the whole move through open folder descriptors, so a link swapped in
        // partway has nothing to redirect.
        let components = relative.split(separator: "/").map(String.init)
        let sourceFolders = Array(components.dropLast())
        guard let name = components.last else { return nil }

        do {
            let rootFolder = try NoFollow.openRoot(root)
            defer { close(rootFolder) }
            let source = try NoFollow.openDirectory(
                sourceFolders, from: rootFolder, creating: false, displayRoot: root)
            defer { close(source) }
            guard NoFollow.kind(of: name, in: source) != .missing else { return nil }

            let targetFolders = [folderName, folderName(for: now)] + sourceFolders
            let target = try NoFollow.openDirectory(
                targetFolders, from: rootFolder, creating: true, displayRoot: root)
            defer { close(target) }

            // The same path can be removed twice in a day (a photo re-added,
            // then deleted again). Both copies are kept: "IMG_1.jpg",
            // "IMG_1 2.jpg". Exclusive renames, so a name taken in between is
            // skipped rather than overwritten.
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var newName = name
            var copy = 2
            while true {
                let status = NoFollow.moveExclusive(name, from: source, to: target, as: newName)
                if status == 0 { break }
                guard status == EEXIST else {
                    throw NoFollow.Failure.posix("Couldn't move \(path)", status)
                }
                newName = ext.isEmpty ? "\(stem) \(copy)" : "\(stem) \(copy).\(ext)"
                copy += 1
            }
            return URL(filePath: ([root] + targetFolders + [newName]).joined(separator: "/"))
        } catch let failure as NoFollow.Failure {
            throw HoldError(description: failure.description)
        }
    }

    /// `Kept --hold-removed <file>`: the cleanup command's entry point. Prints
    /// one line for the run log and exits. A non-zero exit makes osxphotos stop
    /// before its cleanup deletes anything, so a file that couldn't be moved
    /// is never deleted instead.
    static func runHoldAndExit(arguments: [String]) -> Never {
        // Only as osxphotos' cleanup command, under a backup this binary
        // started. Run any other way — say from a LaunchAgent someone else
        // wrote — Kept is judged as itself, Full Disk Access and all, and would
        // move any file it can read into any folder the caller names.
        guard ProcessAncestry.isDescendantOfOwnExecutable() else {
            FileHandle.standardError.write(Data(
                "Kept: --hold-removed only runs as part of a Kept backup\n".utf8))
            exit(77)
        }
        let environment = ProcessInfo.processInfo.environment
        guard let index = arguments.firstIndex(of: "--hold-removed"),
            index + 1 < arguments.count,
            let root = environment[backupRootVariable], !root.isEmpty
        else {
            FileHandle.standardError.write(Data(
                "Kept: --hold-removed needs a file and \(backupRootVariable)\n".utf8))
            exit(64)
        }
        let rootURL = URL(filePath: root, directoryHint: .isDirectory)
        let file = URL(filePath: arguments[index + 1])
        do {
            if let target = try hold(file, backupRoot: rootURL) {
                let holding = holdingFolder(in: rootURL).standardizedFileURL.path
                let day = target.path.dropFirst(holding.count + 1)
                print("Moved to \(folderName)/\(day)")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data(
                "Kept couldn't move \(file.path) to \(folderName): \(error)\n".utf8))
            exit(1)
        }
    }

    /// Files the cleanup command must never be run on: Synology's recycle
    /// bin and index folders, and the holding folder itself (the leading slash
    /// anchors it to the top of the backup folder). Gitignore syntax, so
    /// "#recycle" is escaped: unescaped, a line starting with "#" is a comment,
    /// and the recycle bin would have been moved into the holding folder.
    ///
    /// Then what a disk keeps for itself, which only shows up when the backup
    /// folder is a disk's root. osxphotos skips hidden files but not the
    /// files inside hidden folders, so the disk's trash (.Trashes), Spotlight
    /// index and the like would be moved too; nothing Kept exports is hidden.
    /// The Windows equivalents cover a disk shared with a PC. And any Photos
    /// library, at any depth: picking a folder that holds one is refused, but
    /// one deeper down would otherwise be moved out file by file.
    static let keepRules = [
        "\\#recycle", "@eaDir", "**/@eaDir", "/\(folderName)",
        ".*", "*.photoslibrary", "/System Volume Information", "/$RECYCLE.BIN",
    ]

    /// Makes sure the backup folder's `.osxphotos_keep` holds `keepRules`,
    /// keeping any other lines already in it.
    ///
    /// A file rather than `--keep` flags, because osxphotos refuses `--keep`
    /// without `--cleanup` — which Kept no longer passes — but reads this file
    /// whenever a cleanup command runs. A dot-file, so nothing ever deletes it.
    /// Throws if it can't be written: without these rules osxphotos would hand
    /// Synology's own folders to the cleanup command to move.
    ///
    /// Read and written without following a link: anyone who can write to the
    /// share could otherwise make `.osxphotos_keep` a link to a text file on
    /// this Mac, and the rewrite would copy that file's contents onto the
    /// share. A link there is replaced by a real file, and so is a named pipe
    /// or other special file, which reading would otherwise wait on forever.
    static func writeKeepRules(backupRoot: URL) throws {
        let name = ".osxphotos_keep"
        do {
            let root = try NoFollow.openRoot(backupRoot.standardizedFileURL.path)
            defer { close(root) }
            let existing = try NoFollow.readRegularFile(name, in: root)
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            let lines = existing.split(whereSeparator: \.isNewline).map(String.init)
            let missing = keepRules.filter { !lines.contains($0) }
            guard !missing.isEmpty || NoFollow.kind(of: name, in: root) == .link else { return }
            var text = existing
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            if !lines.contains(where: { $0.hasPrefix("# Kept") }) {
                text += "# Kept: folders its cleanup never touches. Lines Kept didn't add are kept.\n"
            }
            if !missing.isEmpty { text += missing.joined(separator: "\n") + "\n" }
            try NoFollow.writeAtomically(Data(text.utf8), as: name, in: root)
        } catch {
            throw BackupError(
                "Kept couldn't write to the backup folder: \(error)", kind: .setupFailed)
        }
    }

    /// The original path a "Moved to …" log line names, relative to the backup
    /// folder: "Moved to Removed from Photos/2026-10-06/2024/03/IMG_1.jpg" is
    /// "2024/03/IMG_1.jpg".
    static func originalPath(fromLogLine line: String) -> String? {
        guard line.hasPrefix(logPrefix) else { return nil }
        let rest = line.dropFirst(logPrefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let path = rest[rest.index(after: slash)...]
        return path.isEmpty ? nil : String(path)
    }

    /// Removes the folders moved files left empty, from each file's own folder
    /// up toward the backup folder, stopping at the first that still holds
    /// something. Only those folders: a full walk of the backup on a NAS
    /// would cost minutes every night. Returns what it removed, relative.
    ///
    /// The paths come from osxphotos' output, so they are walked through open
    /// folders without following links, and only an empty real folder can go:
    /// `rmdir` refuses anything else.
    @discardableResult
    static func removeEmptyFolders(backupRoot: URL, movedFrom paths: [String]) -> [String] {
        let root = backupRoot.standardizedFileURL.path
        guard let rootFolder = try? NoFollow.openRoot(root) else { return [] }
        defer { close(rootFolder) }
        var candidates = Set<[String]>()
        for path in paths {
            var components = path.split(separator: "/").map(String.init).dropLast()
            // Nothing from a log line may step outside the backup folder.
            guard components.allSatisfy({ $0 != "." && $0 != ".." }) else { continue }
            while !components.isEmpty {
                candidates.insert(Array(components))
                components = components.dropLast()
            }
        }
        var removed: [String] = []
        // Deepest first, so a parent is only judged after its children.
        for folder in candidates.sorted(by: { $0.count > $1.count }) {
            guard folder.first != folderName, let name = folder.last else { continue }
            guard let parent = try? NoFollow.openDirectory(
                Array(folder.dropLast()), from: rootFolder, creating: false, displayRoot: root)
            else { continue }
            if unlinkat(parent, name, AT_REMOVEDIR) == 0 {
                removed.append(folder.joined(separator: "/"))
            }
            close(parent)
        }
        return removed
    }

    // MARK: - Expiry

    struct Expired: Equatable {
        let name: String
        let fileCount: Int
    }

    /// Deletes every dated folder whose retention has run out — a folder from
    /// 2026-10-06 kept for 90 days goes on the first backup from 2027-01-04 —
    /// and anything else in the holding folder, which nothing here put there.
    /// Removes the holding folder itself once it's empty.
    ///
    /// Returns what was deleted, and log lines for anything that wasn't.
    /// Failures are collected rather
    /// than thrown: one undeletable folder shouldn't keep the rest, or stop
    /// the backup.
    static func expire(
        backupRoot: URL, retentionDays: Int, now: Date = .now, calendar: Calendar = .current
    ) -> (expired: [Expired], errors: [String]) {
        let root = backupRoot.standardizedFileURL.path
        guard let rootFolder = try? NoFollow.openRoot(root) else { return ([], []) }
        defer { close(rootFolder) }
        switch NoFollow.kind(of: folderName, in: rootFolder) {
        case .directory:
            break
        case .link:
            // A link here would make every entry of wherever it points a
            // candidate for deletion — a home folder, if someone with write
            // access to the share aimed it there. Left alone, and logged.
            return ([], ["\(folderName) is a link, not a folder; nothing it points to was deleted."])
        case .missing, .other:
            return ([], [])
        }
        guard let holding = try? NoFollow.openDirectory(
            [folderName], from: rootFolder, creating: false, displayRoot: root)
        else {
            return ([], ["\(folderName) is a link, not a folder; nothing it points to was deleted."])
        }
        defer { close(holding) }
        let entries = (try? NoFollow.entries(of: holding)) ?? []

        let today = calendar.startOfDay(for: now)
        var expired: [Expired] = []
        var errors: [String] = []
        for name in entries where !name.hasPrefix(".") {
            if let day = dayFormatter.date(from: name),
                folderName(for: day) == name,
                let expiry = calendar.date(
                    byAdding: .day, value: retentionDays, to: calendar.startOfDay(for: day)),
                expiry > today {
                continue
            }
            let count = NoFollow.fileCount(name, in: holding)
            do {
                try NoFollow.removeTree(name, in: holding)
                expired.append(Expired(name: name, fileCount: count))
            } catch {
                errors.append("Couldn't delete \(folderName)/\(name): \(error)")
            }
        }
        let remaining = (try? NoFollow.entries(of: holding)) ?? ["?"]
        if remaining.allSatisfy({ $0.hasPrefix(".") }) {
            try? NoFollow.removeTree(folderName, in: rootFolder)
        }
        return (expired, errors)
    }
}
