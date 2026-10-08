import CryptoKit
import Foundation

/// Where the mirror goes — the app's one location setting. Captured once at
/// selection time from the chosen folder's volume, so the app can remount a
/// network share at 2 AM without ever asking the user for a URL.
struct Destination: Codable, Equatable, Sendable {
    var path: String
    /// Volume lacked MNT_LOCAL when selected.
    var isNetwork: Bool
    /// smb://user@host/share — present only when the volume is smbfs.
    var smbURL: String?
    /// The volume's mount point (e.g. /Volumes/PhotoBackup) when network.
    var mountPoint: String?

    var displayName: String { URL(filePath: path).lastPathComponent }

    /// The volume's SF Symbol, shared by Settings and the onboarding folder
    /// screen so the same drive is never drawn two different ways.
    var symbolName: String {
        isNetwork ? "externaldrive.connected.to.line.below" : "externaldrive"
    }
}

extension Destination {
    /// Captures volume facts about a chosen folder.
    static func from(folder: URL) -> Destination {
        var fs = statfs()
        guard statfs(folder.path, &fs) == 0 else {
            return Destination(path: folder.path, isNetwork: false)
        }
        let isLocal = (fs.f_flags & UInt32(MNT_LOCAL)) != 0
        let fstype = fixedCString(fs.f_fstypename)
        let mountPoint = fixedCString(fs.f_mntonname)
        let mountFrom = fixedCString(fs.f_mntfromname)
        return Destination(
            path: folder.path,
            isNetwork: !isLocal,
            smbURL: fstype == "smbfs" ? smbURL(fromMountFrom: mountFrom) : nil,
            mountPoint: isLocal ? nil : mountPoint)
    }

    /// statfs reports an SMB source as "//user@host/share".
    static func smbURL(fromMountFrom raw: String) -> String? {
        guard raw.hasPrefix("//") else { return nil }
        return "smb:" + raw
    }

    /// Whether a stored share URL is still shaped like one.
    ///
    /// `smbURL` is captured from the OS at selection time, but it round-trips
    /// through UserDefaults, so by the time it is replayed into AppleScript it
    /// is untrusted input. Anything carrying quotes, backslashes, newlines or
    /// other punctuation that means something to a script interpreter is
    /// rejected outright rather than escaped — a share URL never needs them.
    static func isWellFormedSMBURL(_ raw: String) -> Bool {
        guard raw.hasPrefix("smb://"), raw.count <= 512 else { return false }
        guard let components = URLComponents(string: raw),
            components.scheme == "smb",
            let host = components.host, !host.isEmpty
        else { return false }

        let forbidden = CharacterSet(charactersIn: "\"'\\`$;&|<>(){}\n\r\t")
        guard raw.rangeOfCharacter(from: forbidden) == nil else { return false }
        guard raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        guard raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        return true
    }

    /// Folders the mirror must never be pointed at.
    ///
    /// The export runs with `--cleanup`, which deletes everything in the
    /// destination that osxphotos did not put there. Pointed at a home folder
    /// or a system directory that is not a backup — it is a wipe. Only exact
    /// matches are refused: `~/Pictures` is blocked, `~/Pictures/Mirror` is a
    /// perfectly good destination.
    ///
    /// With `resolvingLinks`, also checked with links resolved, so
    /// "/Volumes/Macintosh HD" (a link to "/") or a folder linked to the home
    /// folder is caught. That reads the disk, and on a stale network mount a
    /// read can hang for good — so it is done when the folder is picked, while
    /// it is known to be live, and not by the engine before its mount probe.
    /// The picked value is sealed (DestinationStore), so it can't change after.
    static func isUnsafeMirrorRoot(path: String, resolvingLinks: Bool = false) -> Bool {
        let url = URL(filePath: path)
        if isUnsafeMirrorRoot(standardized: url.standardizedFileURL.path) { return true }
        return resolvingLinks && isUnsafeMirrorRoot(standardized: url.resolvingSymlinksInPath().path)
    }

    private static func isUnsafeMirrorRoot(standardized path: String) -> Bool {
        let standardized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let homes = Set([homeURL.standardizedFileURL.path, homeURL.resolvingSymlinksInPath().path]
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })

        if standardized.isEmpty { return true }  // "/"
        if homes.contains(standardized) { return true }

        let systemRoots = [
            "Applications", "Library", "System", "Users", "Volumes",
            "bin", "sbin", "usr", "etc", "var", "tmp", "private", "cores", "opt",
            // What /etc, /var and /tmp are links to.
            "private/etc", "private/var", "private/tmp",
        ]
        if systemRoots.contains(standardized) { return true }

        let homeFolders = [
            "Desktop", "Documents", "Downloads", "Library", "Movies", "Music",
            "Pictures", "Public", "Applications",
        ]
        return homes.contains { home in
            homeFolders.contains { standardized == "\(home)/\($0)" }
        }
    }

    /// True when the folder holds nothing that --cleanup could destroy.
    /// Finder cruft and the Synology folders the export keeps anyway don't
    /// count as content.
    static func isEffectivelyEmpty(entries: [String]) -> Bool {
        entries.allSatisfy { name in
            name == ".DS_Store" || name == "#recycle" || name == "@eaDir"
        }
    }

    private static func fixedCString<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// Capacity of the volume the mirror lives on.
struct VolumeStats: Equatable, Sendable {
    var freeBytes: Int64
    var totalBytes: Int64
}

extension Destination {
    /// Cheap liveness check for the status lines — a `statfs` and an existence
    /// test, no subprocess. An unmounted share leaves no /Volumes entry, so
    /// this is enough to tell "Not mounted" from "Mounted". It deliberately
    /// does not detect a *stale* mount; only the engine's read probe does
    /// that, and it costs a child process.
    var isMounted: Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
            isDir.boolValue
        else { return false }
        return volumeStats() != nil
    }

    func volumeStats() -> VolumeStats? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let blockSize = Int64(fs.f_bsize)
        return VolumeStats(
            freeBytes: Int64(fs.f_bavail) * blockSize,
            totalBytes: Int64(fs.f_blocks) * blockSize)
    }

}

/// UserDefaults-backed storage: a JSON blob under one key, and its seal under
/// another. See SettingsSeal for why the seal exists.
///
/// A destination without a valid seal loads as no destination at all, and the
/// panel asks for a folder. That includes one saved before seals existed: it
/// is indistinguishable from one written by someone else, so it is chosen
/// again once rather than trusted.
enum DestinationStore {
    static let key = "destination"
    static let sealKey = "destinationSeal"

    static func load(
        defaults: UserDefaults = .standard, sealingKey: SymmetricKey? = SettingsSeal.key()
    ) -> Destination? {
        guard let data = defaults.data(forKey: key),
            let seal = defaults.data(forKey: sealKey),
            let sealingKey,
            SettingsSeal.verify(data, seal: seal, key: sealingKey)
        else { return nil }
        return try? JSONDecoder().decode(Destination.self, from: data)
    }

    static func save(
        _ destination: Destination,
        defaults: UserDefaults = .standard, sealingKey: SymmetricKey? = SettingsSeal.rotatedKey()
    ) {
        guard let data = try? JSONEncoder().encode(destination) else { return }
        defaults.set(data, forKey: key)
        if let sealingKey {
            defaults.set(SettingsSeal.seal(data, key: sealingKey), forKey: sealKey)
        } else {
            defaults.removeObject(forKey: sealKey)
        }
    }
}
