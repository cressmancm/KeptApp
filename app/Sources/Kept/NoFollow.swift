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

    /// Opens a folder by absolute path. The path itself may run through links
    /// — the backup folder is the user's own choice, and /Volumes paths often
    /// do — so only what lies beneath it is held to no-follow.
    static func openRoot(_ path: String) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.posix("Couldn't open \(path)") }
        return descriptor
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
    static func moveExclusive(
        _ name: String, from source: Int32, to destination: Int32, as newName: String
    ) -> Int32 {
        if renameatx_np(source, name, destination, newName, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let code = errno
        // A filesystem without exclusive rename (some SMB servers). The check
        // and the rename both happen inside folders already held open, so
        // nothing outside them can be reached either way.
        guard code == ENOTSUP || code == EINVAL else { return code }
        guard kind(of: newName, in: destination) == .missing else { return EEXIST }
        return renameat(source, name, destination, newName) == 0 ? 0 : errno
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
