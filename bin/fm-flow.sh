#!/usr/bin/env bash
# fm-flow.sh - read-only durable flow data; no endpoint, network or cache writes.
# Usage: FM_HOME=<home> fm-flow.sh --json [--now <unix-seconds>]
# Reads this home and recursively registered local homes, state/*.meta/status,
# state/fleet-ledger.jsonl (docs/fleet-ledger.md), and data/backlog.md.
# Output fm-flow.v1: homes, lanes, queue, bottlenecks, executed_24h/7d,
# time_to_merge (median, nearest-rank P85, UTC seven-day trend), and limitations.
# Times are seconds. null means unknown, including unstamped status lines.
# Pickup and cleanup use ledger events, NOT file birth/mtime or spawn_gen
# (relaunch changes spawn_gen). pr_ready is NOT pr_opened or checks_green.
# Ledger status timestamps are capture times; live logs use their own [at=].
# Bottlenecks sum CURRENT recorded wait ages, not historical or causal losses.
# Keyed waits close only on matching resolved/captain-held, not working/done.
# Historical results cover retained records only, not a complete forge history.
# Coverage: queue holds/dependencies and recorded waits/lifecycle. Capacity,
# dispatch-admission reasons and stage-clock/liveness probes are not collected.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${1:-}" = --json ] || { echo 'usage: fm-flow.sh --json [--now <unix-seconds>]' >&2; exit 2; }
shift
now=$(date +%s)
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --now ] || exit 2
  now=$2
fi
case "$now" in ''|*[!0-9]*) echo 'fm-flow: --now requires Unix seconds' >&2; exit 2 ;; esac
exec python3 - "${FM_HOME:-$SCRIPT_DIR/..}" "$now" <<'PY'
import base64, json, math, re, statistics, sys
from datetime import datetime, timezone
from pathlib import Path
ROOT, NOW = Path(sys.argv[1]).resolve(), int(sys.argv[2])
notes, homes, lanes, queue = [], {}, [], []
def read(path, optional=False):
    try:
        return path.read_text(errors='replace').splitlines()
    except OSError as e:
        if not optional or not isinstance(e, FileNotFoundError):
            notes.append({'source': str(path), 'reason': str(e)})
        return None

def stamp(value):
    return value if type(value) is int and 0 <= value <= NOW else None

def age(start, end=NOW):
    return end - start if start is not None and end is not None and end >= start else None

def events(path):
    out = []
    for line in read(path, True) or []:
        head, sep, text = line.partition(':')
        v = re.match(r'^(?:\d{9,11}\s+)?([a-z-]+)\b', head)
        if not sep or not v:
            continue
        ats, keys = re.findall(r'\[at=(\d+)\]', head), re.findall(r'\[key=([^\]]+)\]', head)
        out.append({'state': v[1], 'ts': stamp(int(ats[0])) if len(ats) == 1 else None,
                    'key': keys[0] if len(keys) == 1 else 'default', 'text': text.strip()})
    return out

pending = [('main', ROOT)]
seen = set()
while pending:
    name, home = pending.pop(0)
    if home in seen:
        continue
    seen.add(home)
    homes[name] = home
    for line in read(home / 'data/secondmates.md', True) or []:
        m = re.match(r'^- ([\w.-]+) - .*\(home: ([^;]+);', line)
        if m:
            path = Path(m[2].strip())
            if path.is_absolute():
                pending.append((m[1], path.resolve()))
            else:
                notes.append({'source': name, 'reason': 'remote home unavailable to local reader'})

for name, home in sorted(homes.items()):
    records = {}
    ledger = read(home / 'state/fleet-ledger.jsonl')
    for n, line in enumerate(ledger or [], 1):
        try:
            e = json.loads(line)
            if not isinstance(e, dict) or e.get('v') != 1 or not isinstance(e.get('task'), str):
                raise ValueError('unsupported record')
            if not isinstance(e.get('event'), str) or stamp(e.get('ts')) is None:
                raise ValueError('invalid event/time')
            if e['event'] not in ('task.dispatched', 'task.status', 'task.pr_ready', 'task.merged', 'task.cleaned_up'):
                continue
            if e['event'] == 'task.status' and any(e.get(k) is not None and not isinstance(e[k], str)
                                                  for k in ('state', 'key', 'text')):
                raise ValueError('invalid status fields')
            records.setdefault(e['task'], []).append(e)
        except (ValueError, TypeError) as err:
            notes.append({'source': str(home / 'state/fleet-ledger.jsonl'), 'line': n, 'reason': str(err)})
    # Parent return-channel merge records survive child cleanup; no endpoint reads.
    for e in events(ROOT / 'state' / (name + '.status')) if name != 'main' else []:
        if e['state'] == 'done' and e['key'].startswith('merged-') and e['ts'] is not None:
            task = e['key'][7:]
            records.setdefault(task, []).append(dict(e, event='task.merged'))
    try:
        metas = sorted((home / 'state').glob('*.meta')) if (home / 'state').is_dir() else None
    except OSError as e:
        metas = None
        notes.append({'source': str(home / 'state'), 'reason': str(e)})
    if metas is None:
        notes.append({'source': name, 'reason': 'lane inventory unavailable'})
    live = {}
    for path in metas or []:
        content = read(path)
        if content is None:
            continue
        meta = dict(l.split('=', 1) for l in content if '=' in l)
        if meta.get('kind') in ('ship', 'scout'):
            live[path.stem] = meta
            records.setdefault(path.stem, [])
    for task, es in sorted(records.items()):
        if any(e.get('kind') == 'secondmate' for e in es):
            continue
        es.sort(key=lambda e: e['ts'])
        times = {k: next((e['ts'] for e in es if e['event'] == 'task.' + k), None)
                 for k in ('dispatched', 'pr_ready', 'merged', 'cleaned_up')}
        status = events(home / 'state' / (task + '.status')) if task in live else []
        basis = 'emitted' if status else 'captured'
        if not status:
            status = [e for e in es if e['event'] == 'task.status']
        working = next((e['ts'] for e in status if e.get('state') == 'working'), None)
        waits = {}
        for e in status:
            key = e.get('key') or 'default'
            if e.get('state') in ('blocked', 'needs-decision'):
                waits.setdefault(key, e)
            elif e.get('state') in ('resolved', 'captain-held'):
                waits.pop(key, None)
        last = status[-1] if status else {}
        state = last.get('state', 'unknown')
        if sum(e['event'] == 'task.dispatched' for e in es) > 1:
            times = dict(times, dispatched=None, pr_ready=None, cleaned_up=None)
            working = None
            notes.append({'source': name + '/' + task, 'reason': 'reused task id: lifecycle attribution unknown'})
        # Stage entry is the first event in the trailing run, not the preceding event.
        trailing = []
        for e in reversed(status):
            if e.get('state') != state:
                break
            trailing.append(e)
        start = trailing[-1]['ts'] if trailing else None
        row = {'home': name, 'task': task, 'open': task in live, 'stage': state,
               'seconds_in_stage': age(start), 'reason': last.get('text') or 'unknown: no status reason',
               'timestamp_basis': basis, 'open_waits': [dict(key=k, since=e['ts'],
                   seconds=age(e['ts']), reason=e.get('text', ''),
                   cause='captain' if k.startswith('captain-hold') else
                         'lead' if e.get('state') == 'needs-decision' else 'unknown')
                   for k, e in sorted(waits.items())],
               'times': dict(times, working=working, first_commit=None, pr_opened=None, checks_green=None),
               'durations': {'pickup_to_working': age(times['dispatched'], working),
                   'time_to_merge': age(times['dispatched'], times['merged']),
                   'merge_to_cleanup': age(times['merged'], times['cleaned_up'])}}
        lanes.append(row)
    backlog = read(home / 'data/backlog.md')
    section, rows = '', []
    for line in backlog or []:
        if line.startswith('## '):
            section = line[3:].strip()
        m = re.match(r'^- \[([ xX])\] (\S+) - (.*)', line)
        if m:
            rows.append((section, m[2], m[3]))
    done = {t for s, t, _ in rows if s == 'Done'}
    for section, task, text in rows:
        if section != 'Queued':
            continue
        deps = [d for d in re.findall(r'blocked-by:\s+([^\s)]+)', text) if d not in done]
        hold = re.search(r'\(hold:\s*([^)]*)\)', text)
        reason = 'dependency: ' + ', '.join(deps) if deps else None
        if hold and not reason:
            reason = hold[1]
            if reason.startswith('fm-hold-v1:'):
                try:
                    reason = base64.b64decode(reason[11:], validate=True).decode()
                except (ValueError, UnicodeError):
                    reason = 'unknown: malformed hold reason'
            reason = 'hold: ' + reason
        queue.append({'home': name, 'task': task,
                      'why': ' '.join(reason.split()) if reason else 'unknown: dispatch admission not recorded'})

bottlenecks = []
for cause in ('captain', 'lead', 'unknown'):
    items = []
    for lane in lanes:
        if not lane['open']:
            continue
        classes = {w['cause'] for w in lane['open_waits']}
        lane_cause = next(iter(classes)) if len(classes) == 1 else 'unknown'
        matching = lane['open_waits'] if lane_cause == cause else []
        if matching:
            durations = [w['seconds'] for w in matching]
            items.append({'home': lane['home'], 'task': lane['task'], 'waits': matching,
                          'seconds': max(durations) if all(d is not None for d in durations) else None})
    if items:
        known = [i['seconds'] for i in items if i['seconds'] is not None]
        bottlenecks.append({'cause': cause, 'items': items, 'known_lane_hours': sum(known) / 3600,
                            'unknown_items': len(items) - len(known)})
bottlenecks.sort(key=lambda b: (-b['known_lane_hours'], b['cause']))
def executed(seconds):
    return [l for l in lanes if l['times']['merged'] is not None and NOW - seconds <= l['times']['merged'] <= NOW]
def summary(rows):
    values = sorted(l['durations']['time_to_merge'] for l in rows if l['durations']['time_to_merge'] is not None)
    return {'known': len(values), 'unknown': len(rows) - len(values),
            'median_seconds': statistics.median(values) if values else None,
            'p85_seconds': values[math.ceil(.85 * len(values)) - 1] if values else None}
trend = []
today = NOW // 86400
for day in range(today - 6, today + 1):
    rows = [l for l in executed(7 * 86400) if l['times']['merged'] // 86400 == day]
    trend.append(dict(day=datetime.fromtimestamp(day * 86400, timezone.utc).strftime('%Y-%m-%d'), **summary(rows)))
print(json.dumps({'schema': 'fm-flow.v1', 'at': NOW, 'homes': sorted(homes), 'lanes': lanes,
                  'queue': queue, 'bottlenecks': bottlenecks, 'executed_24h': executed(86400),
                  'executed_7d': executed(7 * 86400), 'time_to_merge': summary(executed(7 * 86400)),
                  'time_to_merge_by_home': {h: summary([l for l in executed(7 * 86400) if l['home'] == h]) for h in sorted(homes)},
                  'trend_7d': trend, 'limitations': notes + [{'source': 'coverage', 'reason':
                  'Retained records only; missing pickup/PR/check/cleanup times stay unknown. '
                  'Wait ages are recorded waits, not proof of idle workers. Capacity, clocks and admission probes not collected.'}]},
                 sort_keys=True, allow_nan=False))
PY
