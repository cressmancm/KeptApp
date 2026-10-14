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


def install(root):
    """Holds the export in `root` to the rules above."""
    global _root, _root_key
    _root = root
    _root_key = [_key(part) for part in _parts(root)]

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


def main():
    if len(sys.argv) < 2 or not sys.argv[1].startswith("/"):
        print("usage: kept_export.py <backup folder> <osxphotos arguments...>", file=sys.stderr)
        return 2
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
