import Darwin
import Foundation

/// File operations inside the backup folder that never follow a link, and
/// never re-resolve a path between checking it and acting on it.
///
/// Anyone who can write to the share can plant a link the Mac resolves
/// locally. Checking each folder with lstat and then acting on its path leaves
/// a gap: the folder can be swapped for a link in between. So every step here
/// works from an open folder descriptor — each folder opened with O_NOFOLLOW
/// relative to the one above it, and every rename, create and delete done
/// relative to a descriptor — and a link swapped in after the check has
/// nothing left to redirect.
enum NoFollow {
    struct Failure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }

        static func posix(_ what: String, _ code: Int32 = errno) -> Failure {
            Failure("\(what): \(String(cString: strerror(code)))")
        }
    }

    enum Kind { case missing, directory, link, other }

    /// What `name` is inside `directory`, without following it.
    static func kind(of name: String, in directory: Int32) -> Kind {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .link
        default: return .other
        }
    }

    /// Opens a folder by absolute path, which must be the folder's real path:
    /// no link anywhere along it. It used to be allowed to run through links,
    /// as the user's own choice, and that let anything running as the user
    /// swap the chosen folder for a link to another folder on the same disk,
    /// which every check then passed: the export, the moves and the deletions
    /// all happened in the link's target (production review S2, 2026-10-13).
    /// The folder is chosen by its real path (Destination.from), so a link
    /// here means it was swapped since. The system's own /tmp, /var and /etc,
    /// links into /private, are taken as what they are.
    static func openRoot(_ path: String) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.posix("Couldn't open \(path)") }
        guard let real = realPath(of: descriptor), isSamePath(real, path) else {
            close(descriptor)
            throw Failure("\(path) leads somewhere else through a link")
        }
        return descriptor
    }

    /// Where an open file or folder really is, from the file system.
    static func realPath(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Whether two absolute paths name the same place without a link between
    /// them: equal once the system's /tmp, /var and /etc are spelled with
    /// /private, ignoring case as a Mac's disks usually do.
    static func isSamePath(_ real: String, _ given: String) -> Bool {
        func canonical(_ path: String) -> String {
            var path = URL(filePath: path).standardizedFileURL.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            for system in ["/tmp", "/var", "/etc"]
            where path == system || path.hasPrefix(system + "/") {
                path = "/private" + path
            }
            return path.lowercased()
        }
        return canonical(real) == canonical(given)
    }

    /// Opens `components` as nested folders beneath `base`, one at a time,
    /// refusing a link at any level. With `creating`, missing folders are
    /// made. Returns a descriptor the caller closes; `base` is left open.
    static func openDirectory(
        _ components: [String], from base: Int32, creating: Bool, displayRoot: String
    ) throws -> Int32 {
        var current = dup(base)
        guard current >= 0 else { throw Failure.posix("Couldn't open \(displayRoot)") }
        var shown = displayRoot
        for component in components {
            shown += "/" + component
            // ".." would climb out of the folder being walked; "" and "." mean
            // nothing in a path Kept builds, so they mean someone else built it.
            guard !component.isEmpty, component != ".", component != "..",
                !component.contains("/")
            else {
                close(current)
                throw Failure("\(shown) isn't a folder name Kept will follow")
            }
            if creating, mkdirat(current, component, 0o755) != 0, errno != EEXIST {
                let code = errno
                close(current)
                throw Failure.posix("Couldn't create \(shown)", code)
            }
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            let kind = next < 0 ? kind(of: component, in: current) : .directory
            close(current)
            guard next >= 0 else {
                switch kind {
                case .link: throw Failure("\(shown) is a link, not a folder; not following it")
                case .other: throw Failure("\(shown) is in the way of a folder Kept needs")
                case .missing, .directory: throw Failure.posix("Couldn't open \(shown)", code)
                }
            }
            current = next
        }
        return current
    }

    /// Names in an open folder, "." and ".." left out.
    static func entries(of directory: Int32) throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw Failure.posix("Couldn't list a folder")
        }
        defer { closedir(stream) }
        // fdopendir starts wherever the shared descriptor offset is.
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// Moves `name` from one open folder to another, as `newName`, refusing to
    /// replace anything already there. Never follows a link: a link being
    /// moved is moved as itself.
    ///
    /// Some SMB servers can't rename without replacing (ENOTSUP), and can't
    /// make hard links either: the NAS this was written against is one, so
    /// it takes the fallback for every photo set aside. Checking that the
    /// name was free and then renaming let a file that arrived in between be
    /// overwritten (production review W8, 2026-10-13). Refusing outright
    /// would stop every backup there. So the name is reserved first, with an
    /// exclusive create the server does in one step, and the move then
    /// replaces only that placeholder, once it's checked to still be the one
    /// made.
    static func moveExclusive(
        _ name: String, from source: Int32, to destination: Int32, as newName: String,
        exclusiveRename: (Int32, String, Int32, String) -> Int32 = { from, name, to, newName in
            renameatx_np(from, name, to, newName, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        }
    ) -> Int32 {
        let code = exclusiveRename(source, name, destination, newName)
        guard code == ENOTSUP || code == EINVAL else { return code }

        let placeholder = openat(
            destination, newName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard placeholder >= 0 else { return errno }
        var made = stat()
        let identified = fstat(placeholder, &made) == 0
        close(placeholder)
        var now = stat()
        guard identified, fstatat(destination, newName, &now, AT_SYMLINK_NOFOLLOW) == 0,
            now.st_ino == made.st_ino, now.st_dev == made.st_dev, now.st_size == 0
        else {
            // Replaced since it was made: whatever is there now isn't Kept's.
            return EEXIST
        }
        guard renameat(source, name, destination, newName) == 0 else {
            let failed = errno
            // The placeholder, only if it's still Kept's.
            if fstatat(destination, newName, &now, AT_SYMLINK_NOFOLLOW) == 0,
                now.st_ino == made.st_ino, now.st_dev == made.st_dev
            {
                unlinkat(destination, newName, 0)
            }
            return failed
        }
        return 0
    }

    /// Deletes `name` from an open folder: a file or link as itself, a folder
    /// with everything in it, descending only through real folders.
    static func removeTree(_ name: String, in directory: Int32) throws {
        switch kind(of: name, in: directory) {
        case .missing:
            return
        case .link, .other:
            guard unlinkat(directory, name, 0) == 0 else { throw Failure.posix(name) }
        case .directory:
            let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw Failure.posix(name) }
            var firstError: Error?
            do {
                for entry in try entries(of: child) {
                    do { try removeTree(entry, in: child) } catch { firstError = firstError ?? error }
                }
            } catch {
                firstError = firstError ?? error
            }
            close(child)
            if let firstError { throw firstError }
            guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else { throw Failure.posix(name) }
        }
    }

    /// Regular files beneath `name` in an open folder (1 for a file, 0 for a
    /// link), counted without following links.
    static func fileCount(_ name: String, in directory: Int32) -> Int {
        switch kind(of: name, in: directory) {
        case .missing, .link: return 0
        case .other: return 1
        case .directory:
            let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return 0 }
            defer { close(child) }
            return ((try? entries(of: child)) ?? []).reduce(0) { $0 + fileCount($1, in: child) }
        }
    }

    /// The contents of a regular file in an open folder, or nil when there is
    /// none. A link counts as none, so it is never read through, and so does
    /// a special file: a named pipe, socket or device.
    ///
    /// Opened non-blocking. Opening a named pipe for reading otherwise waits
    /// for a writer, which never comes: one planted at `.osxphotos_keep` hung
    /// the backup before the type check below could refuse it. Reads from a
    /// regular file ignore the flag.
    static func readRegularFile(_ name: String, in directory: Int32) throws -> Data? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP { return nil }
            throw Failure.posix("Couldn't read \(name)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.posix("Couldn't read \(name)") }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return try handle.readToEnd() ?? Data()
        case S_IFDIR: throw Failure("\(name) isn't a regular file")
        default: return nil
        }
    }

    /// Writes `data` as `name` in an open folder: to a fresh temporary file,
    /// then renamed over the old one. The rename replaces whatever was at
    /// `name` — a planted link included — rather than writing through it.
    static func writeAtomically(_ data: Data, as name: String, in directory: Int32) throws {
        let temporary = ".\(name).kept-\(UUID().uuidString)"
        let descriptor = openat(
            directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Failure.posix("Couldn't write \(name)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            unlinkat(directory, temporary, 0)
            throw Failure("Couldn't write \(name): \(error.localizedDescription)")
        }
        guard renameat(directory, temporary, directory, name) == 0 else {
            let code = errno
            unlinkat(directory, temporary, 0)
            throw Failure.posix("Couldn't write \(name)", code)
        }
    }
}
