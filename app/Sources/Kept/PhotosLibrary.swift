import Foundation

/// Which Photos library Kept backs up, and whether it's the one the backup
/// came from.
///
/// Left to itself, osxphotos backs up the library Photos opened last. Open a
/// second library, even a new empty one, and the next backup compared the
/// mirror against it, found nothing it recognised, and set the whole backup
/// aside in Removed from Photos, to be deleted after the retention period
/// (production review S6, 2026-10-13). So Kept names the System Photo Library,
/// the one iCloud Photos syncs, and before every export checks that it holds
/// the photos already in the backup.
enum PhotosLibrary {
    /// The System Photo Library, as macOS records it, or nil when it can't
    /// be read. macOS 27 keeps it in photolibraryd's group container; 26 and
    /// earlier in its app container, which on 27 is still there without the
    /// key. The same order osxphotos uses. Reading either takes Full Disk
    /// Access, so callers check access first rather than raise a prompt.
    static func systemLibraryPath(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> String?
    {
        let plists = [
            "Library/Group Containers/group.com.apple.photolibraryd.private/Library/Preferences/"
                + "group.com.apple.photolibraryd.private.plist",
            "Library/Containers/com.apple.photolibraryd/Data/Library/Preferences/"
                + "com.apple.photolibraryd.plist",
        ]
        for relative in plists {
            guard let data = try? Data(contentsOf: home.appending(path: relative)),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                let path = plist["SystemLibraryPath"] as? String, !path.isEmpty
            else { continue }
            return path
        }
        return nil
    }

    /// The library's database, which the overlap check reads.
    static func database(ofLibrary library: String) -> String {
        URL(filePath: library, directoryHint: .isDirectory)
            .appending(path: "database/Photos.sqlite").path
    }

    /// How much of the backup a library accounts for.
    struct Overlap: Equatable, Sendable {
        /// Items in the library, deleted ones included.
        var inLibrary: Int
        /// Distinct photos in the backup, by Photos' own ID.
        var backedUp: Int
        /// Photos in the backup that are also in the library.
        var shared: Int

        /// Fewer than one in ten of the backed-up photos in this library: an
        /// empty library, or a different one. A library that was only moved
        /// keeps every ID, and pruning nine-tenths of a library at once is
        /// rare enough to ask about. A backup with nothing in it yet has
        /// nothing to protect.
        var isDifferentLibrary: Bool { backedUp > 0 && shared * 10 < backedUp }
    }

    /// `/usr/bin/sqlite3` arguments that count the overlap, both databases
    /// opened read-only. Photos.sqlite is opened as a plain path, and the
    /// backup index attached as an SQL string, so a quote in its path is
    /// doubled.
    static func overlapArguments(libraryDatabase: String, exportDatabase: String) -> [String] {
        let attached = exportDatabase.replacingOccurrences(of: "'", with: "''")
        return [
            "-readonly", "-bail", libraryDatabase,
            "ATTACH '\(attached)' AS kept; "
                + "SELECT (SELECT count(*) FROM ZASSET), "
                + "(SELECT count(DISTINCT uuid) FROM kept.export_data), "
                + "(SELECT count(*) FROM ZASSET WHERE ZUUID IN (SELECT uuid FROM kept.export_data));",
        ]
    }

    /// The counts from sqlite3's `a|b|c` line, or nil for anything else.
    static func parseOverlap(_ output: String) -> Overlap? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|").map { Int($0) }
        guard fields.count == 3, let inLibrary = fields[0], let backedUp = fields[1],
            let shared = fields[2]
        else { return nil }
        return Overlap(inLibrary: inLibrary, backedUp: backedUp, shared: shared)
    }

    /// The library's name as people see it in the Finder.
    static func displayName(_ library: String) -> String {
        let name = URL(filePath: library).lastPathComponent
        return name.hasSuffix(".photoslibrary") ? String(name.dropLast(".photoslibrary".count)) : name
    }
}
