#!/usr/bin/env bash
# Migrate the explicitly supported legacy fields in one Juggernaut home.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import os
import pathlib
import re
import shutil
import sys
import tarfile
import tempfile

# Each rule names one record path and one field. Unlisted legacy data is unknown.
RULES = (
    (re.compile(r"state/model-gate\.check-trust"), re.compile(rb"^fm-custom-check-v1$", re.M), b"jg-custom-check-v1"),
    (re.compile(r"config/crew"), re.compile(rb"^(FM_MODEL=)([^\r\n]*)$", re.M), rb"JG_MODEL=\2"),
    (re.compile(r"state/[^/]+\.status"), re.compile(rb"^fm-open-decision:" , re.M), b"jg-open-decision:"),
    (re.compile(r"data/records"), re.compile(rb"^projects/firstmate-addons$", re.M), b"projects/juggernaut-addons"),
)
LEGACY = re.compile(rb"FIRSTMATE_OP:|FIRSTMATE|firstmate-addons|firstmate|secondmate|crewmate|second mate|first mate|FM_|fm-|fm_")
KNOWN_NONRECORDS = (re.compile(r"state/model-gate\.check\.sh"),)

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


def transform(path, raw):
    rel = path.relative_to(home).as_posix()
    supported = [(pattern, field, replacement) for pattern, field, replacement in RULES if pattern.fullmatch(rel)]
    updated = raw
    if not supported and any(pattern.fullmatch(rel) for pattern in KNOWN_NONRECORDS):
        return updated
    if supported:
        _, field, replacement = supported[0]
        updated = field.sub(replacement, updated)
    if LEGACY.search(updated):
        raise ValueError(f'unclassified legacy content: {rel}')
    return updated


def files():
    found = []
    for part in ('config', 'state', 'data'):
        base = home / part
        for root, dirs, names in os.walk(base, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d != '.jg-migration')
            for name in sorted(names):
                path = pathlib.Path(root) / name
                rel = path.relative_to(home).as_posix()
                if path.is_symlink():
                    if LEGACY.search(os.readlink(path).encode()):
                        raise ValueError(f'unclassified legacy symbolic link: {rel}')
                    continue
                if not path.is_file():
                    raise ValueError(f'unclassifiable record: {rel}')
                raw = path.read_bytes()
                try:
                    raw.decode('utf-8')
                except UnicodeDecodeError:
                    if LEGACY.search(raw):
                        raise ValueError(f'unclassified legacy binary record: {rel}')
                    continue
                updated = transform(path, raw)
                if updated != raw:
                    found.append((path, raw, updated))
    return found

try:
    changes = files()
except (OSError, ValueError) as e:
    print(f'unknown: {e}', file=sys.stderr)
    sys.exit(3)

if a.check:
    for path, _, _ in changes:
        print(path.relative_to(home))
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
    journal.unlink()
    try:
        mig.rmdir()
    except OSError:
        pass
    print('rollback restored the journaled home')
PY
