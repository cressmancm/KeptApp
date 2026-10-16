"""Runs osxphotos so that nothing it does in the backup folder follows a link.

    python3 -I -B kept_export.py <backup folder> <osxphotos arguments...>

Kept's own work in the backup folder never follows a link (NoFollow.swift),
but osxphotos' does: it makes the date folders and copies each photo by path.
Anyone who can write to the share can plant a link there, say a "2026" folder
that's really a link to a folder on this Mac, which the Mac resolves locally.
The export then put photos in that folder, and with --update overwrote what
was there (production review S3, 2026-10-13). Checking the backup folder for
links before the export takes too long on a share of any size (over ten
minutes for this Mac's backup, 2026-10-14), and a link planted after the
check would be missed anyway.

So every write osxphotos makes in the backup folder is checked as it's made:

- Its own file operations (osxphotos' FileUtil: copy, makedirs, rename,
  unlink, rmdir, utime) and its sidecar writes are replaced with ones that
  open each folder from the backup folder down with O_NOFOLLOW and act
  relative to the folder they opened. A link swapped in at any moment has
  nothing to redirect.
- Anything else Python does in the backup folder is checked by an audit hook
  just before it happens. That is a check and then the act, so a link swapped
  in between them isn't caught.

A link is refused, never followed, and never removed: osxphotos records the
error, carries on with the rest, and this exits with LINK_REFUSED, which Kept
reports. Copies Kept doesn't make itself, the cleanup command's, go through
Kept's own helper, which refuses links too.

The backup folder must be given by its real path, as Kept stores it
(Destination.from): it is opened by path for each operation and must still be
that same folder.

    python3 -I -B kept_export.py <backup folder> --spot-check <export.db> <library> <count> <seconds>

checks that a random sample of files already in the backup still match their
originals, reading them the same way (spot_check).
"""

import builtins
import errno
import fcntl
import os
import runpy
import shutil
import stat
import sys
import threading
import unicodedata

# Kept reads this exit status as "a link in the backup folder was refused".
LINK_REFUSED = 75

_state = threading.local()
_refused = set()
_refused_lock = threading.Lock()
_root = ""
_root_key = []


class LinkRefused(OSError):
    """A link in the backup folder, where a folder or file should be.

    ELOOP, not a PermissionError: osxphotos retries those, and a link is
    still a link a second later."""

    def __init__(self, shown):
        super().__init__(errno.ELOOP, f"Kept won't follow a link in the backup folder: {shown}")
        with _refused_lock:
            first = shown not in _refused
            _refused.add(shown)
        if first:
            print(f"Kept: {shown} in the backup folder is a link. Not following it.",
                  file=sys.stderr, flush=True)


class _Ours:
    """While Kept's own code acts: the audit hook leaves it alone."""

    def __enter__(self):
        self.outer = getattr(_state, "ours", False)
        _state.ours = True

    def __exit__(self, *_):
        _state.ours = self.outer


def _key(part):
    # A Mac's disks and shares usually ignore case, and names may arrive in
    # either Unicode form.
    return unicodedata.normalize("NFD", part).casefold()


def _parts(path):
    parts = [part for part in path.split("/") if part not in ("", ".")]
    # The system's own /tmp, /var and /etc are links into /private.
    if parts and parts[0] in ("tmp", "var", "etc"):
        parts.insert(0, "private")
    return parts


def _inside(path):
    """The names below the backup folder that `path` goes through, or None
    when it isn't in the backup folder. [] is the backup folder itself."""
    if isinstance(path, int) or path is None:
        return None
    try:
        path = os.fsdecode(os.fspath(path))
    except TypeError:
        return None
    if not path.startswith("/"):
        path = os.path.join(os.getcwd(), path)
    parts = _parts(path)
    if len(parts) < len(_root_key) or [_key(p) for p in parts[: len(_root_key)]] != _root_key:
        return None
    below = parts[len(_root_key):]
    if ".." in below:
        # Climbing out through whatever a folder below really is.
        raise LinkRefused("/".join(below))
    return below


def _open_root():
    descriptor = os.open(_root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        real = fcntl.fcntl(descriptor, fcntl.F_GETPATH, bytes(1024)).split(b"\0", 1)[0]
        if [_key(p) for p in _parts(os.fsdecode(real))] != _root_key:
            raise LinkRefused(".")
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def _open_folders(names, creating=False, mode=0o777):
    """Opens the backup folder, then each of `names` inside the one before,
    never through a link. Returns a descriptor the caller closes."""
    with _Ours():
        current = _open_root()
        try:
            for depth, name in enumerate(names):
                if creating:
                    try:
                        os.mkdir(name, mode, dir_fd=current)
                    except FileExistsError:
                        pass
                try:
                    following = os.open(
                        name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=current)
                except OSError as error:
                    if _is_link(name, current):
                        raise LinkRefused("/".join(names[: depth + 1])) from error
                    raise
                os.close(current)
                current = following
        except BaseException:
            os.close(current)
            raise
        return current


def _is_link(name, folder):
    try:
        return stat.S_ISLNK(os.stat(name, dir_fd=folder, follow_symlinks=False).st_mode)
    except OSError:
        return False


def _open_in(names, flags, mode=0o666):
    """Opens the file `names` leads to, never through a link, `names[-1]`
    included."""
    folder = _open_folders(names[:-1])
    try:
        with _Ours():
            try:
                return os.open(names[-1], flags | os.O_NOFOLLOW | os.O_CLOEXEC, mode, dir_fd=folder)
            except OSError as error:
                if _is_link(names[-1], folder):
                    raise LinkRefused("/".join(names)) from error
                raise
    finally:
        os.close(folder)


def _check(path):
    """For what Kept doesn't do itself: that nothing on the way to `path`, or
    `path` itself, is a link. Then it happens by path."""
    names = _inside(path)
    if not names:
        return
    folder = _open_folders(names[:-1])
    try:
        with _Ours():
            if _is_link(names[-1], folder):
                raise LinkRefused("/".join(names))
    finally:
        os.close(folder)


# MARK: - osxphotos' file operations, done relative to open folders


def _copy(original):
    def copy(cls, src, dest):
        names = _inside(dest)
        if names is None:
            return original(cls, src, dest)
        src = os.fspath(src)
        if names:
            folder = _open_folders(names[:-1])
            try:
                with _Ours():
                    try:
                        is_folder = stat.S_ISDIR(
                            os.stat(names[-1], dir_fd=folder, follow_symlinks=False).st_mode)
                    except FileNotFoundError:
                        is_folder = False
            finally:
                os.close(folder)
        else:
            is_folder = True
        if is_folder:
            names = names + [os.path.basename(src)]
        descriptor = _open_in(names, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
        try:
            with open(src, "rb") as source, os.fdopen(descriptor, "wb", closefd=False) as target:
                shutil.copyfileobj(source, target, 1 << 20)
            # As shutil.copy does.
            os.fchmod(descriptor, stat.S_IMODE(os.stat(src).st_mode))
        finally:
            os.close(descriptor)
        return True

    return classmethod(copy)


def _makedirs(original):
    def makedirs(cls, name, mode=0o777, exist_ok=False):
        names = _inside(name)
        if names is None:
            return original(cls, name, mode=mode, exist_ok=exist_ok)
        if not names:
            if not exist_ok:
                raise FileExistsError(errno.EEXIST, "File exists", os.fspath(name))
            return
        parent = _open_folders(names[:-1], creating=True, mode=mode)
        try:
            with _Ours():
                try:
                    os.mkdir(names[-1], mode, dir_fd=parent)
                except FileExistsError:
                    if not exist_ok:
                        raise
            os.close(_open_folders(names))
        finally:
            os.close(parent)

    return classmethod(makedirs)


def _remove(original, remove):
    def act(cls, path):
        names = _inside(path)
        if names is None:
            return original(cls, path)
        if not names:
            raise PermissionError(errno.EPERM, "Not removing the backup folder", os.fspath(path))
        folder = _open_folders(names[:-1])
        try:
            with _Ours():
                remove(names[-1], dir_fd=folder)
        finally:
            os.close(folder)

    return classmethod(act)


def _rename(original):
    def rename(cls, src, dest):
        source, target = _inside(src), _inside(dest)
        if source is None and target is None:
            return original(cls, src, dest)
        if not source or not target:
            # One end outside the backup folder: by path, after a check.
            _check(src)
            _check(dest)
            with _Ours():
                os.rename(os.fspath(src), os.fspath(dest))
            return dest
        from_folder = _open_folders(source[:-1])
        try:
            to_folder = _open_folders(target[:-1])
            try:
                with _Ours():
                    os.rename(source[-1], target[-1], src_dir_fd=from_folder, dst_dir_fd=to_folder)
            finally:
                os.close(to_folder)
        finally:
            os.close(from_folder)
        return dest

    return classmethod(rename)


def _utime(original, set_file_dates, creation):
    def utime(cls, path, times):
        names = _inside(path)
        if not names:
            return original(cls, path, times)
        descriptor = _open_in(names, os.O_RDONLY)
        try:
            with _Ours():
                # As osxphotos does, for shares that otherwise lose the times.
                fcntl.fcntl(descriptor, fcntl.F_NOCACHE, 1)
                os.utime(descriptor, times)
        finally:
            os.close(descriptor)
        # The creation date is set by path, through Foundation: a check, then
        # the act.
        import datetime

        _check(path)
        set_file_dates(os.fspath(path), datetime.datetime.fromtimestamp(times[1]), creation)

    return classmethod(utime)


_MODES = {"r": os.O_RDONLY, "w": os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
          "a": os.O_WRONLY | os.O_CREAT | os.O_APPEND, "x": os.O_WRONLY | os.O_CREAT | os.O_EXCL}


def _open(file, mode="r", *args, **kwargs):
    """open(), for modules that write sidecars into the backup folder."""
    names = _inside(file)
    if not names or "opener" in kwargs:
        return builtins.open(file, mode, *args, **kwargs)
    flags = _MODES[next(c for c in mode if c in _MODES)]
    if "+" in mode:
        flags = (flags & ~os.O_WRONLY) | os.O_RDWR
    descriptor = _open_in(names, flags)
    try:
        return builtins.open(descriptor, mode, *args, **kwargs)
    except BaseException:
        os.close(descriptor)
        raise


# MARK: - Everything else


# Audit events that act on a path, and which of their arguments are paths.
_EVENTS = {
    "open": (0,),
    "os.mkdir": (0,), "os.rename": (0, 1), "os.remove": (0,), "os.rmdir": (0,),
    "os.utime": (0,), "os.chmod": (0,), "os.chown": (0,), "os.chflags": (0,),
    "os.lchflags": (0,), "os.link": (0, 1), "os.symlink": (1,), "os.truncate": (0,),
    "os.setxattr": (0,), "os.removexattr": (0,),
    "shutil.copyfile": (1,), "shutil.copystat": (1,), "shutil.copytree": (1,),
    "shutil.move": (0, 1), "shutil.rmtree": (0,),
}
# The events among those that can name a folder to act relative to. Only
# Kept's code here does that.
_DIR_FD = {"os.mkdir": 2, "os.rename": 2, "os.remove": 1, "os.rmdir": 1, "os.utime": 3,
           "os.chmod": 2, "os.chown": 3, "os.link": 2, "os.symlink": 2, "shutil.rmtree": 1}


def _audit(event, args):
    paths = _EVENTS.get(event)
    if paths is None or getattr(_state, "ours", False):
        return
    if event in _DIR_FD and len(args) > _DIR_FD[event] and args[_DIR_FD[event]] is not None:
        return
    for index in paths:
        if index < len(args):
            _check(args[index])


def _set_root(root):
    global _root, _root_key
    _root = root
    _root_key = [_key(part) for part in _parts(root)]


def install(root):
    """Holds the export in `root` to the rules above."""
    _set_root(root)

    import osxphotos.fileutil as fileutil
    import osxphotos.sidecars as sidecars

    makers = {
        "copy": _copy,
        "makedirs": _makedirs,
        "unlink": lambda original: _remove(original, os.unlink),
        "rmdir": lambda original: _remove(original, os.rmdir),
        "rename": _rename,
        "utime": lambda original: _utime(
            original, fileutil.set_file_dates, fileutil.FileDateType.CREATION),
    }
    # Each class's own version of each, wherever osxphotos defines one.
    # FileUtilNoOp, for --dry-run, writes nothing and is left alone.
    replaced = {}
    for cls in (fileutil.FileUtilMacOS, fileutil.FileUtilShUtil, fileutil.FileUtil):
        for name, make in makers.items():
            if name in vars(cls):
                replaced[f"{cls.__name__}.{name}"] = (cls, name, make(vars(cls)[name].__func__))
    # osxphotos' own retries, on a share that stops answering for a moment
    # (--retry), wrapped around these as around the methods they replace.
    retrying = fileutil.retry_all_methods()(
        type("Guarded", (), {key.replace(".", "_"): method
                             for key, (_, _, method) in replaced.items()}))
    for key, (cls, name, _) in replaced.items():
        setattr(cls, name, vars(retrying)[key.replace(".", "_")])
    # The sidecars module's own name for open(), ahead of the built-in.
    sidecars.open = _open
    sys.addaudithook(_audit)


# MARK: - Spot-check (production review C2)

SPOT_CHECK = "--spot-check"


def _library_sources(library):
    """For each photo, the files in the library osxphotos may have copied."""
    import osxphotos

    photos = osxphotos.PhotosDB(dbfile=library)

    def sources(uuid):
        photo = photos.get_photo(uuid)
        # get_photo finds photos in Recently Deleted too, which the export
        # leaves out and whose copies it sets aside, though the backup index
        # still names them. Their copies aren't missing; they're kept in
        # Removed from Photos.
        if photo is None or photo.intrash:
            return []
        paths = (photo.path, photo.path_edited, photo.path_raw, photo.path_live_photo,
                 photo.path_edited_live_photo)
        return [path for path in paths if path]

    return sources


def _source_for(candidates, size, mtime):
    """The file osxphotos copied: the one still the size and age it was then
    (osxphotos' own signature, whole seconds). None when none is: not on
    this Mac (Optimize Mac Storage), or changed since, which the export
    copies again by itself."""
    for path in candidates:
        try:
            info = os.stat(path)
        except OSError:
            continue
        if stat.S_ISREG(info.st_mode) and info.st_size == size and int(info.st_mtime) == int(mtime):
            return path
    return None


def _compare(source, names, deadline):
    """"same", "different", "missing", "unreadable", or "unchecked" when
    time ran out partway."""
    import time

    try:
        descriptor = _open_in(names, os.O_RDONLY)
    except LinkRefused:
        raise
    except (FileNotFoundError, NotADirectoryError):
        return "missing"
    except OSError:
        return "unreadable"
    try:
        # Read from the share, not from what this Mac remembers of it.
        fcntl.fcntl(descriptor, fcntl.F_NOCACHE, 1)
        with open(source, "rb") as original, os.fdopen(descriptor, "rb", closefd=False) as copy:
            while True:
                if time.monotonic() > deadline:
                    return "unchecked"
                expected = original.read(1 << 20)
                try:
                    actual = copy.read(1 << 20)
                except OSError:
                    return "unreadable"
                if expected != actual:
                    return "different"
                if not expected:
                    return "same"
    finally:
        os.close(descriptor)


def spot_check(root, export_db, library, count, seconds, sources=None):
    """Compares a random sample of backed-up files with their originals in
    the Photos library, byte for byte. A copy that's damaged or can't be
    read loses its signature in the backup index, so the next
    backup's --update copies it again over the same name. Prints a line per
    file and a summary; returns the summary's counts."""
    import contextlib
    import sqlite3
    import time

    deadline = time.monotonic() + seconds
    _set_root(root)
    with contextlib.closing(sqlite3.connect(f"file:{export_db}?mode=ro", uri=True)) as db:
        rows = db.execute(
            "SELECT id, filepath, uuid, src_size, src_mtime FROM export_data "
            "WHERE src_size IS NOT NULL AND src_mtime IS NOT NULL AND dest_size IS NOT NULL "
            "AND error IS NULL ORDER BY random() LIMIT ?", (count,)).fetchall()
    if rows and sources is None:
        sources = _library_sources(library)
    same, damaged, skipped = 0, [], 0
    for index, (row_id, filepath, uuid, size, mtime) in enumerate(rows):
        source = _source_for(sources(uuid), size, mtime)
        names = _parts(filepath)
        if source is None or not names or ".." in names:
            skipped += 1
            continue
        try:
            result = _compare(source, names, deadline)
        except LinkRefused:
            # Not damage: the next export refuses the link and says so.
            skipped += 1
            continue
        if result == "unchecked":
            skipped += len(rows) - index
            break
        if result == "missing":
            # Not something to copy again: --update copies any copy it still
            # needs that's gone, by itself. One that's gone after an export
            # was set aside, an earlier copy of a photo whose date changed,
            # say, which the index still names.
            skipped += 1
            continue
        if result == "same":
            same += 1
        else:
            print(f"Spot-check: {result}: {filepath}", flush=True)
            damaged.append(row_id)
    if damaged:
        # No longer a signature osxphotos accepts, so the next --update
        # copies the photo again, over the same name, which the row still
        # holds for it.
        with contextlib.closing(sqlite3.connect(export_db)) as db, db:
            db.executemany(
                "UPDATE export_data SET dest_mode = NULL, dest_size = NULL, dest_mtime = NULL "
                "WHERE id = ?", [(row_id,) for row_id in damaged])
    print(f"Spot-check summary: {same + len(damaged)} checked, {len(damaged)} damaged, "
          f"{skipped} skipped", flush=True)
    return same + len(damaged), len(damaged), skipped


def main():
    if len(sys.argv) < 2 or not sys.argv[1].startswith("/"):
        print("usage: kept_export.py <backup folder> <osxphotos arguments...>", file=sys.stderr)
        print(f"       kept_export.py <backup folder> {SPOT_CHECK} <export.db> <library> "
              "<count> <seconds>", file=sys.stderr)
        return 2
    if sys.argv[2:3] == [SPOT_CHECK]:
        if len(sys.argv) != 7:
            print("spot-check: expected <export.db> <library> <count> <seconds>", file=sys.stderr)
            return 2
        spot_check(sys.argv[1], sys.argv[3], sys.argv[4], int(sys.argv[5]), float(sys.argv[6]))
        return 0
    install(sys.argv[1])
    sys.argv = ["osxphotos"] + sys.argv[2:]
    status = 0
    try:
        runpy.run_module("osxphotos", run_name="__main__", alter_sys=True)
    except SystemExit as exit:
        status = exit.code
    except BaseException:
        if not _refused:
            raise
        import traceback

        traceback.print_exc()
    if _refused:
        print(f"Kept: refused {len(_refused)} link(s) in the backup folder.", file=sys.stderr, flush=True)
        return LINK_REFUSED
    return status


if __name__ == "__main__":
    sys.exit(main())
