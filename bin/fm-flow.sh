#!/usr/bin/env bash
# fm-flow.sh - read-only flow data, no endpoint or cache writes.
# Usage: FM_HOME=<home> fm-flow.sh --json [--now <unix-seconds>] [--checks]
# --checks reads durable GitHub check-run records through gh-axi (5 s per call).
# These live observations carry their own timestamp, independent of --now.
# It reports queued/running counts on the recorded PR head, never infers green
# from an empty check list; missing, stale or incomplete results stay unknown.
# Why-lines classify explicitly named waits only, not arbitrary prose mentions.
# Stage clocks read the installed config/fm-flow-check.sh policy expression;
# an unrecognized/missing policy yields unknown, not a copied default.
# config/lane-caps supplies recorded-active lane caps; no free worker is inferred.
# Reads this home and recursively registered local homes: state/*.meta/status,
# state/fleet-ledger.jsonl (docs/fleet-ledger.md), and queued tasks through the
# home-addressed fm-tasks-axi.sh consumer (including archived dependency completions).
# Missing/unavailable backlog backends are unknown, never a stale Markdown fallback.
# Registered remote homes remain listed, with unavailable lanes/backlog/lifecycle
# disclosed in limitations; remote paths are not read locally and no SSH is used.
# Output fm-flow.v1: homes, lanes, queue, bottlenecks, executed_24h/7d,
# time_to_merge (median, nearest-rank P85, UTC seven-day trend), and limitations.
# Times are seconds. null means unknown, including unstamped status lines.
# Pickup and cleanup use ledger events, NOT file birth/mtime or spawn_gen
# (relaunch changes spawn_gen). pr_ready is NOT pr_opened or checks_green.
# Ledger status timestamps are capture times; live logs use their own [at=].
# Bottlenecks attribute each open (lane, cause) separately at its maximum recorded wait age;
# cross-cause ages on one lane overlap in time: reported sums are non-additive recorded waits,
# never allocated causal or lane-hours-lost durations. Full seconds stay null when any
# same-cause wait is unstamped; known_seconds carries the max known age, cause totals carry
# known_lane_hours alongside known_lower_bound_lane_hours, and ranking uses the lower bound.
# Key/note parsing is owned by fm-classify-lib.sh: keys may be in the status head
# or note head. Each key retains its latest opener's reason and timestamp;
# keyed waits close only on matching resolved/captain-held, not working/done.
# A current paused status also contributes a non-decision wait since that latest
# pause line; leaving paused removes it without closing any keyed waits.
# Historical results cover retained records only, not a complete forge history.
# Capacity and worker-liveness probes are not collected.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${1:-}" = --json ] || { echo 'usage: fm-flow.sh --json [--now <unix-seconds>] [--checks]' >&2; exit 2; }
shift
now=$(date +%s) checks=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --now) [ "$#" -ge 2 ] || exit 2; now=$2; shift 2 ;;
    --checks) checks=1; shift ;;
    *) exit 2 ;;
  esac
done
case "$now" in ''|*[!0-9]*) echo 'fm-flow: --now requires Unix seconds' >&2; exit 2 ;; esac
exec python3 - "${FM_HOME:-$SCRIPT_DIR/..}" "$now" "$checks" "$SCRIPT_DIR/fm-classify-lib.sh" <<'PY'
import json, math, os, re, statistics, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path
ROOT, NOW = Path(sys.argv[1]).resolve(), int(sys.argv[2])
notes, homes, lanes, queue, metadata = [], {}, [], [], {}
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

def parse_status(lines):
    if not lines:
        return []
    parsed = subprocess.check_output(['bash', '-c', '''
source "$1"
while IFS= read -r -d '' line; do
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || key=''
    epoch=$(status_line_at_epoch "$line") || epoch=''
    note=$(status_line_note "$line")
    printf '%s\\0%s\\0%s\\0%s\\0' "$verb" "$key" "$epoch" "$note"
done
''', 'fm-flow', sys.argv[4]], input=''.join(line + '\0' for line in lines).encode())
    fields = parsed.decode().split('\0')[:-1]
    return [dict(state=v, key=k or None, ts=stamp(int(t)) if t else None, text=n)
            for v, k, t, n in zip(*[iter(fields)] * 4)]

def events(path):
    lines = [line for line in read(path, True) or [] if ':' in line]
    return [e for e in parse_status(lines) if re.fullmatch(r'[a-z-]+', e['state'])]

def captured_status(records):
    lines = []
    for e in records:
        text = e.get('text') or ''
        lines.append(f"{e.get('state') or ''}: {text}")
    parsed = parse_status(lines)
    for e, p in zip(records, parsed):
        key = e.get('key')
        if key and p['key'] != key:
            p['key'], p['text'] = key, (e.get('text') or '').lstrip()
        p['ts'] = e['ts']
    return parsed

def cause(key, event):
    if key.startswith('captain-hold'):
        return 'captain'
    text = event.get('text') or ''
    if re.search(r'^(?:fm-mem-gate: waiting|waiting (?:for|on) (?:the )?memory gate)\b', text, re.I):
        return 'memory_gate'
    if re.search(r'^(?:waiting (?:for|on)|missing|expired|invalid|needs?) .*\b(?:credentials?|login|authentication)\b', text, re.I):
        return 'credential_external'
    if re.search(r'^waiting (?:for|on) (?:an? |the )?(?:external|SSH|network|MacBook)\b', text, re.I):
        return 'credential_external'
    if re.search(r'^(?:waiting (?:for|on)|awaiting) (?:the )?CI queue\b', text, re.I):
        return 'ci_queue'
    if re.search(r'^(?:waiting (?:for|on)|awaiting) (?:the )?(?:review|merge)\b', text, re.I):
        return 'review_merge'
    return 'lead' if event.get('state') == 'needs-decision' else 'unknown'

clock_source = ROOT / 'config/fm-flow-check.sh'
policy = '\n'.join(read(clock_source, True) or [])
clock = re.search(r"^\s*clock = (\d+) if L\['verb'\] == 'needs-decision' else (\d+)\s*$", policy, re.M)
clocks = {'needs-decision': int(clock[1]), 'blocked': int(clock[2]), 'paused': int(clock[2])} if clock else {}
if not clock:
    notes.append({'source': str(clock_source), 'reason': 'stage clock policy unknown'})
caps = {}
for line in read(ROOT / 'config/lane-caps', True) or []:
    fields = line.split()
    if len(fields) == 2 and fields[1].isdigit():
        caps[fields[0]] = int(fields[1])
    elif line.strip() and not line.lstrip().startswith('#'):
        notes.append({'source': 'config/lane-caps', 'reason': 'malformed cap row'})

def backlog_rows(name, home):
    try:
        result = subprocess.run(['bash', '-c', '''
. "$1/fm-tasks-axi-lib.sh"
. "$1/fm-backlog-transition-lib.sh"
fm_backlog_tasks_axi_addressing "$FM_HOME/data" || exit 2
if [ -n "$FM_BACKLOG_AXI_FILE" ] && { [ ! -f "$FM_BACKLOG_AXI_FILE" ] || [ ! -r "$FM_BACKLOG_AXI_FILE" ]; }; then
    printf 'backlog unavailable: %s\\n' "$FM_BACKLOG_AXI_FILE" >&2
    exit 2
fi
exec bash "$1/fm-tasks-axi.sh" list --state queued --fields blocked_by,held,hold_reason
''', 'fm-flow', str(Path(sys.argv[4]).parent)], capture_output=True, text=True, timeout=20,
            env=dict(os.environ, FM_HOME=str(home), FM_DATA_OVERRIDE=''))
        if result.returncode:
            raise ValueError(result.stderr.strip() or 'backlog consumer failed')
        lines = result.stdout.splitlines()
        decoder = json.JSONDecoder()
        for i, line in enumerate(lines):
            if line.startswith('tasks: 0 '):
                return []
            table = re.fullmatch(r'tasks\[(\d+)\]\{([^}]+)\}:', line)
            if not table:
                continue
            columns, count = table[2].split(','), int(table[1])
            rows = []
            for body in lines[i + 1:i + 1 + count]:
                body, fields = body.strip(), []
                while body:
                    if body.startswith('"'):
                        value, end = decoder.raw_decode(body)
                    else:
                        end = body.find(',')
                        end = len(body) if end < 0 else end
                        value = body[:end]
                    fields.append(value)
                    body = body[end:]
                    if body and not body.startswith(','):
                        raise ValueError('invalid backlog table separator')
                    body = body[1:]
                if len(fields) != len(columns):
                    raise ValueError('incomplete backlog row')
                row = dict(zip(columns, fields))
                if not {'id', 'blocked_by', 'held', 'hold_reason'} <= row.keys():
                    raise ValueError('missing backlog fields')
                rows.append(row)
            if len(rows) != count:
                raise ValueError('incomplete backlog table')
            return rows
        raise ValueError('no backlog table in consumer output')
    except (OSError, ValueError, subprocess.TimeoutExpired) as err:
        notes.append({'source': name + '/backlog', 'reason': 'unknown: ' + str(err)})
        return []

pending = [('main', ROOT, None)]
seen = set()
registering = {}
while pending:
    name, home, parent = pending.pop(0)
    if home in seen:
        continue
    seen.add(home)
    homes[name] = home
    registering[name] = parent
    for line in read(home / 'data/secondmates.md', True) or []:
        m = re.match(r'^- ([\w.-]+) - .*\((?:host:\s*([^;]+);\s*root:\s*([^;]+);\s*)?home:\s*([^;]+);', line)
        if m:
            if m[2]:
                homes[m[1]] = None
                notes.append({'source': m[1], 'host': m[2].strip(), 'home': m[4].strip(),
                              'reason': 'remote home unavailable to local reader; lanes, backlog and lifecycle unknown'})
                continue
            path = Path(m[4].strip())
            if path.is_absolute():
                pending.append((m[1], path.resolve(), home))
            else:
                notes.append({'source': m[1], 'reason': 'home unavailable to local reader'})

for name, home in sorted(homes.items()):
    if home is None:
        continue
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
    reg = registering.get(name)
    for e in events(reg / 'state' / (name + '.status')) if reg is not None else []:
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
            metadata[(name, path.stem)] = meta
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
            status = captured_status([e for e in es if e['event'] == 'task.status'])
        if sum(e['event'] == 'task.dispatched' for e in es) > 1:
            times = dict(times, dispatched=None, pr_ready=None, merged=None, cleaned_up=None)
            notes.append({'source': name + '/' + task, 'reason': 'reused task id: lifecycle attribution unknown'})
            latest = max(e['ts'] for e in es if e['event'] == 'task.dispatched')
            status = [e for e in status if e.get('ts') is not None and e['ts'] >= latest]
        working = next((e['ts'] for e in status if e.get('state') == 'working'), None)
        waits = {}
        for e in status:
            key = e.get('key')
            if key is None:
                continue
            if e.get('state') in ('blocked', 'needs-decision'):
                waits[key] = e
            elif e.get('state') in ('resolved', 'captain-held'):
                waits.pop(key, None)
        last = status[-1] if status else {}
        state = last.get('state') or 'unknown'
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
                   seconds=age(e['ts']), reason=e.get('text') or '',
                   cause=cause(k, e))
                   for k, e in sorted(waits.items())],
               'times': dict(times, working=working, first_commit=None, pr_opened=None, checks_green=None),
               'durations': {'pickup_to_working': age(times['dispatched'], working),
                   'time_to_merge': age(times['dispatched'], times['merged']),
                   'merge_to_cleanup': age(times['merged'], times['cleaned_up'])}}
        if state == 'paused':
            row['open_waits'].append(dict(key=None, since=last['ts'], seconds=age(last['ts']),
                                          reason=last.get('text') or '', cause=cause(last.get('key') or '', last)))
        seconds = clocks.get(state)
        row['stage_clock'] = {'seconds': seconds, 'source': str(clock_source) if seconds is not None else None,
                              'overdue': row['seconds_in_stage'] >= seconds
                              if seconds is not None and row['seconds_in_stage'] is not None else None}
        lanes.append(row)
    for item in backlog_rows(name, home):
        deps = item['blocked_by']
        reason = 'dependency: ' + ', '.join(deps.split(',')) if deps != 'none' else None
        if item['held'] == 'yes' and not reason:
            reason = 'hold: ' + item['hold_reason']
        queue.append({'home': name, 'task': item['id'],
                      'why': ' '.join(reason.split()) if reason else 'unknown: dispatch admission not recorded'})

active = {h: sum(l['open'] and l['home'] == h and l['stage'] in ('working', 'resolved') and
                 not any(w['cause'] == 'captain' for w in l['open_waits']) for l in lanes) for h in homes}
for q in queue:
    if q['why'].startswith('unknown:') and q['home'] in caps and active[q['home']] >= caps[q['home']]:
        q['why'] = f"lane cap: {active[q['home']]} recorded active lanes, cap {caps[q['home']]}"

def api(path, projection):
    result = subprocess.run(['gh-axi', 'api', path, '--jq', projection, '--full'],
                            capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise ValueError('gh-axi query failed: ' + (result.stderr.strip() or result.stdout.strip())[-300:])
    return result.stdout

def check_runs(meta):
    url = meta.get('pr', '')
    m = re.fullmatch(r'https://github.com/([\w.-]+/[\w.-]+)/pull/(\d+)', url)
    if not m:
        raise ValueError('canonical GitHub PR URL not recorded')
    pull = api(f'/repos/{m[1]}/pulls/{m[2]}', '{head: .head.sha}|tojson')
    head = re.search(r'^head: "?([0-9a-f]{40})"?$', pull, re.M)
    if not head or not meta.get('pr_head') or meta['pr_head'] != head[1]:
        raise ValueError('PR head is missing or differs from the recorded head')
    counts = api(f'/repos/{m[1]}/commits/{head[1]}/check-runs?per_page=100',
                 '{total: .total_count, returned: (.check_runs|length), '
                 'queued: ([.check_runs[]|select(.status=="queued")]|length), '
                 'running: ([.check_runs[]|select(.status=="in_progress")]|length), '
                 'completed: ([.check_runs[]|select(.status=="completed")]|length)}|tojson')
    values = {}
    for field in ('total', 'returned', 'queued', 'running', 'completed'):
        found = re.search(r'^' + field + r': (\d+)$', counts, re.M)
        if not found:
            raise ValueError('invalid check-run counts from gh-axi')
        values[field] = int(found[1])
    if values['total'] != values['returned'] or values['returned'] != sum(values[k] for k in ('queued', 'running', 'completed')):
        raise ValueError('check-run coverage incomplete; counts unknown')
    return dict(values, head=head[1], observed_at=int(time.time()), source=url,
                phase='unreported' if not values['total'] else 'mixed' if values['queued'] and values['running']
                else 'queued' if values['queued'] else 'running' if values['running'] else 'reported_complete')

for lane in lanes:
    if not lane['open']:
        continue
    lane['ci'] = None
    meta = metadata[(lane['home'], lane['task'])]
    if sys.argv[3] != '1' or not meta.get('pr'):
        continue
    try:
        lane['ci'] = check_runs(meta)
        if lane['ci']['queued'] and lane['stage'] in ('paused', 'blocked', 'needs-decision', 'done'):
            lane['open_waits'].append({'key': None, 'since': None, 'seconds': None, 'cause': 'ci_queue',
                                      'source': 'forge', 'reason': f"{lane['ci']['queued']} reported checks queued; wait start unknown"})
    except (OSError, ValueError, subprocess.TimeoutExpired) as err:
        notes.append({'source': lane['home'] + '/' + lane['task'] + '/checks', 'reason': str(err)})

bottlenecks = []
for cause_name in ('captain', 'lead', 'ci_queue', 'memory_gate', 'credential_external', 'review_merge', 'unknown'):
    items = []
    for lane in lanes:
        if not lane['open']:
            continue
        grouped = {}
        for w in lane['open_waits']:
            grouped.setdefault(w['cause'], []).append(w)
        matching = grouped.get(cause_name, [])
        if matching:
            durations = [w['seconds'] for w in matching]
            known = [d for d in durations if d is not None]
            items.append({'home': lane['home'], 'task': lane['task'], 'waits': matching,
                          'seconds': max(durations) if all(d is not None for d in durations) else None,
                          'known_seconds': max(known) if known else None,
                          'unknown_waits': len(durations) - len(known),
                          'overlap': len(grouped) > 1})
    if items:
        full = [i['seconds'] for i in items if i['seconds'] is not None]
        lower = [i['known_seconds'] for i in items if i['known_seconds'] is not None]
        bottlenecks.append({'cause': cause_name, 'items': items, 'known_lane_hours': sum(full) / 3600,
                            'known_lower_bound_lane_hours': sum(lower) / 3600,
                            'unknown_items': len(items) - len(full),
                            'unknown_waits': sum(i['unknown_waits'] for i in items), 'additive': False})
bottlenecks.sort(key=lambda b: (-b['known_lower_bound_lane_hours'], -b['known_lane_hours'], b['cause']))
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
                  'Wait ages are recorded waits, not proof of idle workers. Bottleneck items report the maximum '
                  'recorded wait age per (lane, cause); a lane in several cause buckets overlaps in time, so cause '
                  'sums are non-additive and never causal lane-hours lost. Items keep full seconds null when any '
                  'same-cause wait is unstamped and report the known lower bound separately. Capacity and free-worker availability not collected. '
                  'CI counts cover reported check runs only, not all required contexts or a green verdict.'}]},
                 sort_keys=True, allow_nan=False))
PY
