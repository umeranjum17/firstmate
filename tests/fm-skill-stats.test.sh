#!/usr/bin/env bash
# Integration: run the real bin/fm-skill-stats.sh over isolated skill-read
# records and read the per-skill JSON the dashboard's Skills view consumes.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR" "$TMP/xdg" "$TMP/tmp"
HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" TMPDIR="$TMP/tmp" python3 - "$ROOT/bin/fm-skill-stats.sh" "$TMP" <<'PY'
import json, os, subprocess, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

script, tmp = sys.argv[1], Path(sys.argv[2])
main, mate = tmp / 'home', tmp / 'byokit'
NOW = 1700000000
DAY = 86400
(main / 'data/metrics').mkdir(parents=True, exist_ok=True)
(mate / 'data/metrics').mkdir(parents=True, exist_ok=True)
(main / 'state').mkdir(parents=True, exist_ok=True)
(mate / 'state').mkdir(parents=True, exist_ok=True)

def day(offset):
    return (datetime.fromtimestamp(NOW, timezone.utc) - timedelta(days=offset)).strftime('%Y-%m-%d')

(main / 'data/secondmates.md').write_text(
    f'- byokit - BYOKit (home: {mate}; scope: toolkit; projects: byokit)\n'
    '- distant - Remote (host: box; root: /srv; home: /srv/home; scope: x; projects: y)\n')

# Known skills come from each local home's skill directories.
for rel in ('skills', '.agents/skills'):
    for name in ('widget', 'gadget'):
        d = main / rel / name
        d.mkdir(parents=True, exist_ok=True)
        (d / 'SKILL.md').write_text('x')
spin = mate / '.agents/skills/spanner'
spin.mkdir(parents=True, exist_ok=True)
(spin / 'SKILL.md').write_text('x')

header = 'day\thome\tskill\treads\n'
rows = [
    f'{day(0)}\tmain\tused-heavy\t5\n',
    f'{day(1)}\tmain\tused-heavy\t3\n',
    f'{day(0)}\tmain\tshared\t2\n',
    f'{day(0)}\tbyokit\tshared\t4\n',
    f'{day(20)}\tmain\told\t10\n',
    f'{day(10)}\tmain\tgadget\t100\n',
]
(main / 'data/metrics/skills.tsv').write_text(header + ''.join(rows))

out = subprocess.check_output(['bash', script, '--json', '--now', str(NOW)],
                              env=dict(os.environ, FM_HOME=str(main), FM_DATA_OVERRIDE=''))
x = json.loads(out)

def skill(name):
    return next(s for s in x['skills'] if s['skill'] == name)
def home(name):
    return x['by_home'][name]

assert x['schema'] == 'fm-skill-stats.v1' and x['windows'] == [7, 30], 'schema and windows'
assert x['coverage']['rows'] == 6 and x['coverage']['skills'] == 4 and x['coverage']['homes'] == 2, 'coverage counts'
assert [s['skill'] for s in x['skills']][:2] == ['used-heavy', 'shared'], 'skills ranked by reads'
assert [s['skill'] for s in x['skills']][2:] == ['gadget', 'old'], 'zero-read-in-7d skills rank by the wider window'

heavy = skill('used-heavy')
assert heavy['w7'] == {'reads': 8, 'homes': 1} and heavy['w30']['reads'] == 8, 'window sums'
shared = skill('shared')
assert shared['w7'] == {'reads': 6, 'homes': 2}, 'reads counted per home across homes'
gadget = skill('gadget')
assert gadget['w7']['reads'] == 0 and gadget['w30']['reads'] == 100, 'a skill read only outside 7 days'

# Zero-read skills are the known directory skills with no reads in the window.
assert x['zero_read_w7'] == ['gadget', 'spanner', 'widget'], 'known skills with no 7-day reads'
assert x['zero_read_w30'] == ['spanner', 'widget'], 'known skills with no 30-day reads'

assert [s['skill'] for s in home('main')][:3] == ['used-heavy', 'shared', 'gadget'], 'per-home ranking'
assert [s['skill'] for s in home('byokit')] == ['shared'], 'per-home breakdown isolates each home'
assert any('distant' in n for n in x['limitations']), 'a remote home is disclosed as unreadable'

# Deterministic and read-only.
before = {str(p): p.stat().st_mtime_ns for p in main.rglob('*') if p.is_file()}
out2 = subprocess.check_output(['bash', script, '--json', '--now', str(NOW)],
                               env=dict(os.environ, FM_HOME=str(main), FM_DATA_OVERRIDE=''))
assert out2 == out, 'deterministic output'
assert before == {str(p): p.stat().st_mtime_ns for p in main.rglob('*') if p.is_file()}, 'reader writes nothing'

# An absent record is not an error: no rows, no crash, one coverage notice.
empty = tmp / 'empty'
empty.mkdir()
y = json.loads(subprocess.check_output(['bash', script, '--json', '--now', str(NOW)],
                                       env=dict(os.environ, FM_HOME=str(empty), FM_DATA_OVERRIDE='')))
assert y['skills'] == [] and y['by_home'] == {} and y['coverage']['rows'] == 0, 'absent record is empty, not fatal'
assert y['limitations'], 'the missing record is disclosed'
print('ok - per-skill reads, windows, per-home split and zero-read discovery')
PY
