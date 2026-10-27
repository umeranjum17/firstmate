#!/usr/bin/env bash
# Migrate one Juggernaut home from Firstmate names to Juggernaut names.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import os
import pathlib
import shutil
import sys
import tarfile
import tempfile

REPLACEMENTS = (
    (b'FIRSTMATE_OP:', b'JUGGERNAUT_OP:'),
    (b'FIRSTMATE', b'JUGGERNAUT'),
    (b'firstmate-addons', b'juggernaut-addons'),
    (b'firstmate', b'juggernaut'),
    (b'secondmate', b'squad-lead'),
    (b'crewmate', b'operator'),
    (b'second mate', b'Squad Lead'),
    (b'first mate', b'Overwatch'),
    (b'FM_', b'JG_'),
    (b'fm-', b'jg-'),
    (b'fm_', b'jg_'),
    (b'.fm-', b'.jg-'),
)

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--home', required=True, help='the single home to migrate')
p.add_argument('--slice', default='records', help='journal slice name (default: records)')
g = p.add_mutually_exclusive_group(required=True)
for mode in ('check', 'apply', 'verify', 'rollback'):
    g.add_argument('--' + mode, action='store_true')
a = p.parse_args()
home = pathlib.Path(a.home).resolve()
if not home.is_dir():
    p.error('--home must be an existing directory')
for name in ('config', 'state', 'data'):
    if not (home / name).is_dir():
        p.error(f'home is missing {name}/')
if not a.slice or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in a.slice):
    p.error('--slice must contain only letters, digits, _ or -')
mig = home / 'state/.jg-migration'
journal = mig / f'{a.slice}.journal'


def files():
    found = []
    for part in ('config', 'state', 'data'):
        base = home / part
        for root, dirs, names in os.walk(base, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d != '.jg-migration')
            for name in sorted(names):
                path = pathlib.Path(root) / name
                if path.is_symlink():
                    target = os.readlink(path).encode()
                    if any(old in target for old, _ in REPLACEMENTS):
                        raise ValueError(f'unclassifiable symbolic link: {path.relative_to(home)}')
                    continue
                if not path.is_file():
                    raise ValueError(f'unclassifiable record: {path.relative_to(home)}')
                raw = path.read_bytes()
                try:
                    raw.decode('utf-8')
                except UnicodeDecodeError:
                    if any(old in raw for old, _ in REPLACEMENTS):
                        raise ValueError(f'unclassifiable binary record: {path.relative_to(home)}')
                    continue
                updated = raw
                for old, new in REPLACEMENTS:
                    updated = updated.replace(old, new)
                if updated != raw:
                    found.append((path, raw, updated))
    return found


def digest_tree():
    import hashlib
    h = hashlib.sha256()
    for part in ('config', 'state', 'data'):
        for root, dirs, names in os.walk(home / part, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d != '.jg-migration')
            for name in sorted(names):
                path = pathlib.Path(root) / name
                rel = str(path.relative_to(home)).encode()
                h.update(rel + b'\0')
                if path.is_symlink():
                    h.update(b'L' + os.readlink(path).encode())
                else:
                    h.update(b'F' + path.read_bytes())
    return h.hexdigest()

try:
    changes = files()
except (OSError, ValueError) as e:
    print(f'unknown: {e}', file=sys.stderr)
    sys.exit(3)

if a.check:
    for path, _, _ in changes:
        print(f'{path.relative_to(home)}')
    if not changes:
        print('no rewrites required')
    sys.exit(0)
if a.verify:
    if changes:
        print('not migrated: ' + ', '.join(str(x[0].relative_to(home)) for x in changes), file=sys.stderr)
        sys.exit(1)
    print('verified: no supported legacy names remain')
    sys.exit(0)
if a.apply:
    if journal.exists():
        if not changes:
            print('already applied')
            sys.exit(0)
        print('existing journal does not match current home', file=sys.stderr)
        sys.exit(3)
    mig.mkdir(parents=True, exist_ok=True)
    with tarfile.open(journal, 'w:gz') as archive:
        for part in ('config', 'state', 'data'):
            archive.add(home / part, arcname=part, recursive=True,
                        filter=lambda info: None if '.jg-migration' in pathlib.PurePosixPath(info.name).parts else info)
    for path, _, updated in changes:
        fd, temp = tempfile.mkstemp(dir=path.parent, prefix='.jg-migrate-')
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(updated)
                stream.flush()
                os.fsync(stream.fileno())
            shutil.copystat(path, temp, follow_symlinks=False)
            os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
    print(f'applied {len(changes)} rewrites; journal: {journal.relative_to(home)}')
    sys.exit(0)
if a.rollback:
    if not journal.is_file():
        print('migration journal not found', file=sys.stderr)
        sys.exit(1)
    with tarfile.open(journal, 'r:gz') as archive:
        archive.extractall(home, filter='data')
    shutil.rmtree(mig)
    print('rollback restored the journaled home')
PY
