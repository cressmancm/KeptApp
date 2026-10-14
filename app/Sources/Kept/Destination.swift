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
    /// The local volume's UUID when the folder was chosen, so a different
    /// disk mounted under the same name is never taken for it. nil for a
    /// network share (`smbURL` identifies that), a volume without a UUID, and
    /// a folder chosen before Kept recorded one.
    var volumeUUID: String?
    /// Which choice of folder this is. Runs record it, so a newly chosen
    /// folder has no backups until one finishes there. nil for a folder
    /// chosen before Kept kept it; the runs from then have none either.
    var id: UUID?
    /// When the folder was chosen, so the daily check can tell a folder that
    /// has never been backed up from one that was only just chosen. nil for a
    /// folder chosen before Kept kept it.
    var chosenAt: Date?
    /// True from choosing this folder until a backup finishes: that backup
    /// takes the System Photo Library as it finds it, without comparing it
    /// with the backup (PhotosLibrary). Choosing the folder is how you say a
    /// changed library is the one you mean, and it covers one backup, not
    /// every library after it. Set without reading the library, which can
    /// happen in setup before Full Disk Access is on.
    var libraryConfirmed: Bool?

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
        let uuid = isLocal
            ? (try? folder.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
            : nil
        return Destination(
            path: folder.path,
            isNetwork: !isLocal,
            smbURL: fstype == "smbfs" ? smbURL(fromMountFrom: mountFrom) : nil,
            mountPoint: isLocal ? nil : mountPoint,
            volumeUUID: uuid)
    }

    /// `picked`, as the folder Kept will now back up to. Choosing the current
    /// folder again only refreshes what Kept knows about its disk, so it
    /// keeps its identity and its backups; any other folder is new and starts
    /// with none.
    static func adopting(_ picked: Destination, replacing current: Destination?, now: Date = .now)
        -> Destination
    {
        var adopted = picked
        if let current, current.path == picked.path {
            adopted.id = current.id
            adopted.chosenAt = current.chosenAt
        } else {
            adopted.id = UUID()
            adopted.chosenAt = now
        }
        return adopted
    }

    /// statfs reports an SMB source as "//user@host/share". A space is
    /// encoded, in case one ever arrives raw, so the result parses as a URL.
    static func smbURL(fromMountFrom raw: String) -> String? {
        guard raw.hasPrefix("//") else { return nil }
        return "smb:" + raw.replacingOccurrences(of: " ", with: "%20")
    }

    /// Why the volume now at `path` isn't the one chosen, or nil when it is.
    ///
    /// The seal (SettingsSeal) protects the saved path, but a path is only a
    /// name. Anything running as this user can mount a disk image, or its own
    /// share, under the same name once the real one is gone, and a backup
    /// would then copy the whole library onto it. A different disk the user
    /// plugs in with the same name is just as wrong the other way: its files
    /// aren't from the library, so they'd be moved to "Removed from Photos".
    /// So the volume itself is compared: its UUID for a local disk, its server
    /// and share for SMB. Read after the mount probe, so statfs can't hang.
    func volumeMismatch() -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else {
            return "Kept couldn't check which disk “\(displayName)” is on."
        }
        let isLocal = (fs.f_flags & UInt32(MNT_LOCAL)) != 0
        let different = "“\(displayName)” is on a different disk than the one you chose. "
            + "Connect that disk, or choose the folder again in Settings."
        if isNetwork {
            guard !isLocal else { return different }
            guard let smbURL else { return nil }  // AFP or NFS: nothing recorded to compare
            let mountedFrom = Self.smbURL(fromMountFrom: Self.fixedCString(fs.f_mntfromname))
            guard let mountedFrom, Self.isSameShare(smbURL, mountedFrom),
                mountPoint == nil || mountPoint == Self.fixedCString(fs.f_mntonname)
            else {
                return "The share at \(mountPoint ?? path) isn't the one you chose. "
                    + "Eject it, or choose the folder again in Settings."
            }
            return nil
        }
        guard isLocal else { return different }
        guard let volumeUUID else { return nil }
        let current = (try? URL(filePath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?
            .volumeUUIDString
        return current == volumeUUID ? nil : different
    }

    /// Same server and share, however the server was named when mounted.
    /// Finder may mount a Bonjour host as "nas._smb._tcp.local" one day and
    /// "nas.local" the next, and the user name and port don't identify the
    /// share. Share names are case-insensitive on SMB.
    static func isSameShare(_ a: String, _ b: String) -> Bool {
        func key(_ raw: String) -> String? {
            guard let components = URLComponents(string: raw), components.scheme == "smb",
                var host = components.host?.lowercased(), !host.isEmpty
            else { return nil }
            if host.hasSuffix(".") { host.removeLast() }
            for suffix in ["._smb._tcp.local", ".local"] where host.hasSuffix(suffix) {
                host.removeLast(suffix.count)
                break
            }
            let share = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
            return host + "/" + share
        }
        guard let left = key(a), let right = key(b) else { return false }
        return left == right
    }

    /// Whether a stored share URL is still shaped like one.
    ///
    /// The URL reaches `osascript` as an argument and is read back out of
    /// `argv`, never spliced into script text, so no character in it can turn
    /// into code. What's still refused is anything that isn't an SMB URL with
    /// a host, and characters no share name can contain: control characters,
    /// raw whitespace (a mount source encodes it), and `" \ < > |`. This used
    /// to refuse shell punctuation too, which also refused real share names:
    /// `Photos$`, `Chip's Photos` and `A&B` are all legal on SMB, and a share
    /// named that way would have failed every night with no way to fix it.
    static func isWellFormedSMBURL(_ raw: String) -> Bool {
        guard raw.hasPrefix("smb://"), raw.count <= 1024 else { return false }
        guard raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            raw.rangeOfCharacter(from: CharacterSet(charactersIn: "\"\\<>|")) == nil
        else { return false }
        guard let components = URLComponents(string: raw),
            components.scheme == "smb",
            let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    /// Folders the mirror must never be pointed at.
    ///
    /// Everything in the backup folder that osxphotos did not put there is
    /// moved to "Removed from Photos" and deleted after the retention period.
    /// Pointed at a home folder or a system directory, that is a slow wipe. Only exact
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

    /// Why a folder that isn't a system folder still can't hold the backup.
    enum Refusal: Equatable {
        /// It is a Photos library, or inside one.
        case insidePhotosLibrary
        /// It has a Photos library in it: an external disk's root, often.
        case holdsPhotosLibrary
        /// A cloud folder's root, such as iCloud Drive. Moving its files would
        /// sync to every device signed in to it.
        case cloudFolder
    }

    /// The path-only checks, cheap enough for the engine to repeat before
    /// every run. `entries` (the folder's top level) is read when the folder
    /// is picked, while it's known to be live.
    static func refusal(path: String, entries: [String] = []) -> Refusal? {
        let components = URL(filePath: path).standardizedFileURL.pathComponents
        if components.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) {
            return .insidePhotosLibrary
        }
        if isCloudFolderRoot(components) { return .cloudFolder }
        if entries.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) {
            return .holdsPhotosLibrary
        }
        return nil
    }

    /// iCloud Drive and the folders cloud apps sync through
    /// (~/Library/CloudStorage/Dropbox, …), and the folder each one starts at.
    /// A folder inside one of them is the user's call; the root is everything
    /// they have stored there.
    private static func isCloudFolderRoot(_ components: [String]) -> Bool {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library").standardizedFileURL.pathComponents
        guard components.count > library.count,
            Array(components.prefix(library.count)) == library
        else { return false }
        let rest = Array(components.dropFirst(library.count))
        switch rest[0] {
        case "Mobile Documents":
            return rest.count <= 2
        case "CloudStorage":
            // Google Drive syncs from "My Drive" inside its folder.
            return rest.count <= 2 || (rest.count == 3 && rest[2] == "My Drive")
        default:
            return false
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

    fileprivate static func fixedCString<T>(_ field: T) -> String {
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

    /// The last three are the one-time move from the login keychain, where a
    /// build without the provisioning profile keeps its key: a folder sealed
    /// with that key is sealed again with a fresh data-protection key, and
    /// the old key deleted, so moving to a release build doesn't make anyone
    /// choose their folder again. It trusts the login-keychain key once, which
    /// is no more than that build did. Only evaluated when the current key
    /// doesn't verify.
    static func load(
        defaults: UserDefaults = .standard,
        sealingKey: SymmetricKey? = SettingsSeal.key(),
        legacyKey: @autoclosure () -> SymmetricKey? = SettingsSeal.legacyKeyForMigration(),
        resealingKey: @autoclosure () -> SymmetricKey? = SettingsSeal.rotatedKey(),
        legacyMigrated: () -> Void = { SettingsSeal.deleteLegacyKey() }
    ) -> Destination? {
        guard let data = defaults.data(forKey: key),
            let seal = defaults.data(forKey: sealKey)
        else { return nil }
        if let sealingKey, SettingsSeal.verify(data, seal: seal, key: sealingKey) {
            return try? JSONDecoder().decode(Destination.self, from: data)
        }
        guard let legacy = legacyKey(), SettingsSeal.verify(data, seal: seal, key: legacy),
            let fresh = resealingKey()
        else { return nil }
        defaults.set(SettingsSeal.seal(data, key: fresh), forKey: sealKey)
        legacyMigrated()
        return try? JSONDecoder().decode(Destination.self, from: data)
    }

    /// The saved folder without checking its seal, and without touching the
    /// keychain. Only for the daily check, which uses it to pick out the
    /// folder's backups from the history and decides nothing about where
    /// anything is written. Anything that can rewrite the setting can rewrite
    /// the history too, so the seal would add nothing there.
    static func peek(defaults: UserDefaults = .standard) -> Destination? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Destination.self, from: $0) }
    }

    /// Saves the folder with its seal, or nothing at all. Returns false when
    /// there's no key to seal it with — the keychain locked or refusing — in
    /// which case what was saved before is left as it was. Saving it unsealed
    /// used to look like success until the next launch, which then found no
    /// folder at all.
    @discardableResult
    static func save(
        _ destination: Destination,
        defaults: UserDefaults = .standard,
        sealingKey: @autoclosure () -> SymmetricKey? = SettingsSeal.rotatedKey()
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(destination), let sealingKey = sealingKey()
        else { return false }
        defaults.set(data, forKey: key)
        defaults.set(SettingsSeal.seal(data, key: sealingKey), forKey: sealKey)
        return true
    }
}
