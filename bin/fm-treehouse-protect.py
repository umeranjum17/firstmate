#!/usr/bin/env python3
"""Protect recorded task copies before Treehouse allocation (no Git mutations).

Usage: python3 fm-treehouse-protect.py <project> <state-dir>...
Called by fm-spawn and fm-home-seed under their shared project lock.
Only entries already in a Treehouse pool for this Git repository are leased.
Copies are never moved, reset or returned, and existing leases are preserved.
JSON replacement holds Treehouse's own native state lock (flock on POSIX, LockFileEx on Windows).
Unreadable state or conflicting records refuse allocation.
A recorded copy that is missing from Treehouse state, marked destroying, or no longer a git worktree is skipped with a warning.
"""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def common_dir(path):
    return Path(subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        text=True, stderr=subprocess.PIPE).strip()).resolve()


def lock_state(file):
    if os.name != "nt":
        import fcntl
        fcntl.flock(file, fcntl.LOCK_EX)
        return
    import ctypes
    from ctypes import wintypes
    import msvcrt
    class Overlapped(ctypes.Structure):
        _fields_ = [("internal", ctypes.c_size_t), ("internal_high", ctypes.c_size_t),
                    ("offset", wintypes.DWORD), ("offset_high", wintypes.DWORD),
                    ("event", wintypes.HANDLE)]
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.LockFileEx.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD,
                                 wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(Overlapped)]
    if not kernel.LockFileEx(msvcrt.get_osfhandle(file.fileno()), 2, 0, 1, 0, ctypes.byref(Overlapped())):
        raise ctypes.WinError(ctypes.get_last_error())
    # Closing the file releases the lock, on both platforms.


def warn_skipped(task, path, reason):
    print(f"warning: not protecting recorded copy {path} of task {task}: {reason}", file=sys.stderr)


def protect(project, states):
    common = common_dir(project)
    pools = {}
    for state in states:
        for meta in sorted(Path(state).glob("*.meta")):
            if meta.is_symlink() or not meta.is_file():
                continue
            values = dict(line.split("=", 1) for line in meta.read_text().splitlines() if "=" in line)
            for field in ("worktree", "home"):
                path = Path(values.get(field, "")).resolve()
                pool = path.parent.parent
                state_file = pool / "treehouse-state.json"
                if not values.get(field) or not path.is_dir() or not state_file.exists():
                    continue
                if state_file.is_symlink() or not state_file.is_file():
                    raise ValueError(f"unsafe Treehouse state: {state_file}")
                try:
                    copy_common = common_dir(path)
                except subprocess.CalledProcessError:
                    warn_skipped(meta.stem, path, "no longer a git worktree")
                    continue
                if copy_common != common:
                    continue
                owners = pools.setdefault(pool, {})
                if path in owners and owners[path] != meta.stem:
                    raise ValueError(f"copy {path} is recorded by both {owners[path]} and {meta.stem}")
                owners[path] = meta.stem
    for pool, owners in pools.items():
        state_file = pool / "treehouse-state.json"
        lock_file = pool / "treehouse-state.lock"
        if lock_file.is_symlink():
            raise ValueError(f"unsafe Treehouse lock: {lock_file}")
        with lock_file.open("a+b") as lock:
            lock_state(lock)
            data = json.loads(state_file.read_text())
            entries = data["worktrees"]
            found = set()
            changed = False
            for entry in entries:
                path = Path(entry["path"]).resolve()
                if path not in owners:
                    continue
                if path in found:
                    raise ValueError(f"duplicate Treehouse entry: {path}")
                found.add(path)
                if entry.get("destroying"):
                    warn_skipped(owners[path], path, "Treehouse is destroying it")
                    continue
                if entry.get("leased"):
                    continue
                entry.update(leased=True, lease_holder=owners[path],
                             leased_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
                changed = True
            for path in set(owners) - found:
                warn_skipped(owners[path], path, "missing from Treehouse state")
            if changed:
                temporary = None
                try:
                    with tempfile.NamedTemporaryFile(mode="w", dir=pool, delete=False) as output:
                        temporary = output.name
                        os.chmod(temporary, state_file.stat().st_mode & 0o777)
                        json.dump(data, output, indent=2)
                        output.flush()
                        os.fsync(output.fileno())
                    os.replace(temporary, state_file)
                    if os.name != "nt":
                        directory = os.open(pool, os.O_RDONLY)
                        try:
                            os.fsync(directory)
                        finally:
                            os.close(directory)
                finally:
                    if temporary and os.path.exists(temporary):
                        os.unlink(temporary)


if __name__ == "__main__":
    try:
        if len(sys.argv) < 3:
            raise ValueError(__doc__)
        protect(sys.argv[1], sys.argv[2:])
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        sys.exit(f"error: cannot protect recorded Treehouse copies: {detail}")
