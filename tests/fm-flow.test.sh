#!/usr/bin/env bash
# Integration: query the real flow CLI over isolated durable fleet records.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/xdg" "$TMP/tmp"
HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" TMPDIR="$TMP/tmp" python3 - "$ROOT/bin/fm-flow.sh" "$TMP" <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path
script, tmp = sys.argv[1], Path(sys.argv[2])
main, child = tmp / 'main', tmp / 'child'
for h in (main, child):
    (h / 'state').mkdir(parents=True)
    (h / 'data').mkdir()
    (h / 'data/backlog.md').write_text('## Queued\n')
(main / 'data/secondmates.md').write_text(f'- child - Worker (home: {child}; scope: app; projects: app)\n')
(child / 'data/secondmates.md').write_text(f'- main - Parent (home: {main}; scope: fleet; projects: app)\n')
(main / 'data/backlog.md').write_text('## Queued\n- [ ] next - Next blocked-by: prior\n'
    '- [ ] held - Held (hold: fm-hold-v1:V2FpdCBmb3IgVW1lcg==)\n'
    '- [ ] ready - Ready blocked-by: finished\n## Done\n- [x] finished - Completed\n')
(child / 'state/live.meta').write_text('kind=ship\nspawn_gen=s99.1.2\n')
(child / 'state/live.status').write_text('working [at=10]: building\n'
    'needs-decision [at=20] [key=captain-hold-a]: choose scope\n'
    'blocked [at=25] [key=external]: external credential\n'
    'done [at=30]: implemented\nresolved [at=40] [key=external]: credential ready\n'
    'working [at=50]: resumed\nworking [at=60]: still working\n')
(child / 'state/unknown.meta').write_text('kind=scout\n')
(child / 'state/unknown.status').write_text('blocked: missing timestamp\n')
ledger = [dict(v=1, task='closed', ts=t, event='task.' + event) for t, event in
          [(10, 'dispatched'), (20, 'status'), (35, 'pr_ready'), (70, 'merged'), (80, 'cleaned_up')]]
ledger[1].update(state='working', text='building')
(child / 'state/fleet-ledger.jsonl').write_text('\n'.join(map(json.dumps, ledger + [ledger[3]])) + '\n{bad}\n')
def files():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for h in (main, child) for p in h.rglob('*') if p.is_file()}
def run():
    return subprocess.check_output(['bash', script, '--json', '--now', '100'], env=dict(os.environ, FM_HOME=str(main)))
before = files()
a = run()
assert a == run() and files() == before, 'deterministic and read-only'
x = json.loads(a)
assert x['homes'] == ['child', 'main'], 'registry cycle deduplicated'
live = next(l for l in x['lanes'] if l['task'] == 'live')
assert live['seconds_in_stage'] == 50 and len(live['open_waits']) == 1
assert live['open_waits'][0]['seconds'] == 80, 'done/working do not close keyed wait'
assert live['times']['dispatched'] is None, 'spawn incarnation is not pickup'
closed = x['executed_24h'][0]
assert len(x['executed_24h']) == 1 and closed['durations']['time_to_merge'] == 60
assert closed['durations']['merge_to_cleanup'] == 10
assert closed['times']['pr_opened'] is None and closed['times']['checks_green'] is None
assert x['time_to_merge']['median_seconds'] == x['time_to_merge']['p85_seconds'] == 60
assert {q['task']: q['why'] for q in x['queue']} == {'next': 'dependency: prior', 'held': 'hold: Wait for Umer',
    'ready': 'unknown: dispatch admission not recorded'}
assert next(b for b in x['bottlenecks'] if b['cause'] == 'unknown')['unknown_items'] == 1
assert any(n.get('line') == 7 for n in x['limitations']), 'malformed durable record disclosed'
assert len(x['trend_7d']) == 7
grand = tmp / 'grand'
(grand / 'state').mkdir(parents=True)
(grand / 'data').mkdir()
(grand / 'data/backlog.md').write_text('## Queued\n')
(grand / 'data/secondmates.md').write_text(f'- main - Parent (home: {main}; scope: fleet; projects: app)\n')
with open(child / 'data/secondmates.md', 'a') as f:
    f.write(f'- grand - Worker (home: {grand}; scope: app; projects: app)\n')
(child / 'state/grand.status').write_text('done [at=70] [key=merged-gtask]: merged\n')
with open(child / 'state/fleet-ledger.jsonl', 'a') as f:
    f.write(json.dumps(dict(v=1, task='reused', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='reused', ts=70, event='task.merged')) + '\n')
    f.write(json.dumps(dict(v=1, task='reused', ts=90, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullstage', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullstage', ts=20, event='task.status', state=None, key='k', text='t')) + '\n')
    f.write(json.dumps(dict(v=1, task='restale', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='restale', ts=20, event='task.status', state='blocked', key='k', text='stale')) + '\n')
    f.write(json.dumps(dict(v=1, task='restale', ts=90, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullwait', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullwait', ts=20, event='task.status', state='blocked', key='k', text=None)) + '\n')
    f.write(json.dumps(dict(v=1, task='relive', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='relive', ts=90, event='task.dispatched')) + '\n')
(child / 'state/relive.meta').write_text('kind=ship\n')
(child / 'state/relive.status').write_text('working [at=20]: building\nblocked [at=25] [key=stale-key]: waiting\n')
y = json.loads(run())
assert y['homes'] == ['child', 'grand', 'main'], 'nested home discovered'
bytask = {(l['home'], l['task']): l for l in y['lanes']}
assert bytask[('grand', 'gtask')]['times']['merged'] == 70, 'nested return-channel merge found'
assert bytask[('grand', 'gtask')]['durations']['time_to_merge'] is None, 'no guessed pickup'
assert 'gtask' in {l['task'] for l in y['executed_24h']}
assert bytask[('child', 'reused')]['times']['merged'] is None, 'reused id keeps no merge'
assert 'reused' not in {l['task'] for l in y['executed_24h']}
assert bytask[('child', 'nullstage')]['stage'] == 'unknown', 'null ledger state stays unknown'
restale = bytask[('child', 'restale')]
assert restale['stage'] == 'unknown' and restale['open_waits'] == [], 'reuse drops pre-dispatch status'
assert restale['seconds_in_stage'] is None and restale['times']['working'] is None
assert restale['reason'] == 'unknown: no status reason'
assert 'restale' not in {l['task'] for l in y['executed_24h']}
assert bytask[('child', 'nullwait')]['open_waits'][0]['reason'] == '', 'null wait text coerced'
relive = bytask[('child', 'relive')]
assert relive['open'] and relive['timestamp_basis'] == 'emitted'
assert relive['stage'] == 'unknown' and relive['open_waits'] == [], 'live reuse drops pre-dispatch status'
assert relive['seconds_in_stage'] is None and relive['times']['working'] is None
assert relive['reason'] == 'unknown: no status reason'
(main / 'config').mkdir()
(main / 'config/fm-flow-check.sh').write_text("clock = 30 if L['verb'] == 'needs-decision' else 50\n")
(main / 'config/lane-caps').write_text('main 0\n')
for task, reason in [('memory', 'fm-mem-gate: waiting (free 1 GB)'), ('credential', 'waiting for login'),
                     ('ci', 'waiting for CI queue'), ('merge', 'waiting for merge'),
                     ('mention', 'memory gate code fixed; waiting for new instructions')]:
    (child / 'state' / (task + '.meta')).write_text('kind=ship\n')
    (child / 'state' / (task + '.status')).write_text(f'blocked [at=10] [key=wait]: {reason}\n')
(child / 'state/mixed.meta').write_text('kind=ship\n')
(child / 'state/mixed.status').write_text('blocked [at=10] [key=a]: fm-mem-gate: waiting (free 1 GB)\n'
    'blocked [at=30] [key=a2]: fm-mem-gate: waiting (free 1 GB)\n'
    'blocked [key=a0]: fm-mem-gate: waiting (free 1 GB)\n'
    'needs-decision [at=20] [key=b]: waiting for merge\n')
(child / 'state/partknown.meta').write_text('kind=ship\n')
(child / 'state/partknown.status').write_text('blocked [at=10] [key=a]: fm-mem-gate: waiting (free 1 GB)\n'
    'blocked [key=b]: fm-mem-gate: waiting (free 1 GB)\n')
(child / 'state/smallmerge.meta').write_text('kind=ship\n')
(child / 'state/smallmerge.status').write_text('blocked [at=90] [key=wait]: waiting for merge\n')
z = json.loads(run())
new = {l['task']: l for l in z['lanes'] if l['open']}
for task, expected in [('memory', 'memory_gate'), ('credential', 'credential_external'),
                       ('ci', 'ci_queue'), ('merge', 'review_merge'), ('mention', 'unknown')]:
    assert new[task]['open_waits'][0]['cause'] == expected
    assert new[task]['stage_clock']['seconds'] == 50 and new[task]['stage_clock']['overdue'] is True
    assert new[task]['ci'] is None, 'no reported CI is not a zero or green'
mem_bucket = next(b for b in z['bottlenecks'] if b['cause'] == 'memory_gate')
merge_bucket = next(b for b in z['bottlenecks'] if b['cause'] == 'review_merge')
mem_item = next(i for i in mem_bucket['items'] if i['task'] == 'mixed')
merge_item = next(i for i in merge_bucket['items'] if i['task'] == 'mixed')
assert mem_item['seconds'] is None, 'unstamped same-cause wait keeps full total unknown'
assert mem_item['known_seconds'] == 90 and len(mem_item['waits']) == 3, 'within-cause maximum, not sum'
assert mem_item['unknown_waits'] == 1
assert merge_item['seconds'] == 80 and merge_item['known_seconds'] == 80
assert mem_bucket['known_lower_bound_lane_hours'] == (90 + 90 + 90) / 3600
assert mem_bucket['unknown_items'] == 2 and mem_bucket['unknown_waits'] == 2
part = next(i for i in mem_bucket['items'] if i['task'] == 'partknown')
assert part['seconds'] is None and part['known_seconds'] == 90 and part['unknown_waits'] == 1
assert [b['cause'] for b in z['bottlenecks']].index('memory_gate') < [b['cause'] for b in z['bottlenecks']].index('review_merge'), 'known lower bound ranks first'
assert mem_item['overlap'] is True and merge_item['overlap'] is True
assert mem_bucket['additive'] is False and merge_bucket['additive'] is False
assert next(i for i in mem_bucket['items'] if i['task'] == 'memory')['overlap'] is False
assert 'mixed' not in {i['task'] for i in next(b for b in z['bottlenecks'] if b['cause'] == 'unknown')['items']}
assert {q['task']: q['why'] for q in z['queue']}['ready'] == 'lane cap: 0 recorded active lanes, cap 0'
assert new['unknown']['stage_clock']['overdue'] is None, 'unstamped stage never guessed overdue'
scenarios = {
    'keyclose': [('blocked', 10, 'a', 'waiting for login'),
                 ('resolved', 20, None, '[key=a] login restored')],
    'noteopens': [('blocked', 10, None, '[key=a] waiting for login'),
                  ('blocked', 20, None, '[key=b] waiting for merge'),
                  ('captain-held', 30, 'a', 'held')],
    'reopened': [('blocked', 10, 'a', 'waiting for login'),
                 ('blocked', 20, None, '[key=a] waiting for merge'),
                 ('blocked', 30, 'b', 'waiting for merge')],
    'precedence': [('blocked', 10, 'a', '[key=b] waiting for login'),
                   ('resolved', 20, 'b', 'answered')],
    'pause': [('paused', 10, None, 'waiting for memory gate')],
    'repause': [('paused', 10, None, 'waiting for login'),
                ('paused', 20, None, 'waiting for memory gate')],
    'resumed': [('paused', 10, None, 'waiting for memory gate'),
                ('working', 20, None, 'building')],
    'decisionpause': [('blocked', 10, 'a', 'waiting for merge'),
                      ('paused', 20, None, 'waiting for memory gate')],
    'unknownpause': [('paused', None, None, 'waiting for memory gate')],
}
for representation in ('emitted', 'captured'):
    for task, entries in scenarios.items():
        task = representation + '-' + task
        (child / 'state' / (task + '.meta')).write_text('kind=ship\n')
        if representation == 'emitted':
            lines = [state + (f' [at={ts}]' if ts is not None else '') +
                     (f' [key={key}]' if key else '') + ': ' + text + '\n'
                     for state, ts, key, text in entries]
            (child / 'state' / (task + '.status')).write_text(''.join(lines))
        else:
            if any(ts is None for _, ts, _, _ in entries):
                continue
            with open(child / 'state/fleet-ledger.jsonl', 'a') as f:
                for state, ts, key, text in entries:
                    stored_key = key or (text.split(']', 1)[0][5:] if text.startswith('[key=') else None)
                    f.write(json.dumps(dict(v=1, task=task, ts=ts, event='task.status',
                                           state=state, key=stored_key, text=text)) + '\n')
result = json.loads(run())
rows = {l['task']: l for l in result['lanes']}
for representation in ('emitted', 'captured'):
    def lane(task):
        return rows[representation + '-' + task]
    assert lane('keyclose')['open_waits'] == [], 'note-head resolution closes the stated key'
    waits = lane('noteopens')['open_waits']
    assert [(w['key'], w['reason'], w['cause'], w['seconds']) for w in waits] == [
        ('b', 'waiting for merge', 'review_merge', 80)], 'distinct note-head keys and normalized reasons'
    waits = lane('reopened')['open_waits']
    assert [(w['key'], w['cause'], w['seconds']) for w in waits] == [
        ('a', 'review_merge', 80), ('b', 'review_merge', 70)], 'latest opener replaces cause and age'
    bucket = next(b for b in result['bottlenecks'] if b['cause'] == 'review_merge')
    item = next(i for i in bucket['items'] if i['task'] == representation + '-reopened')
    assert item['seconds'] == item['known_seconds'] == 80, 'distinct same-cause keys retain maximum'
    waits = lane('precedence')['open_waits']
    assert len(waits) == 1 and waits[0]['key'] == 'a' and waits[0]['reason'] == '[key=b] waiting for login'
    for task, seconds in [('pause', 90), ('repause', 80)]:
        waits = lane(task)['open_waits']
        assert len(waits) == 1 and waits[0]['key'] is None
        assert waits[0]['cause'] == 'memory_gate' and waits[0]['seconds'] == seconds
        bucket = next(b for b in result['bottlenecks'] if b['cause'] == 'memory_gate')
        item = next(i for i in bucket['items'] if i['task'] == representation + '-' + task)
        assert item['seconds'] == seconds and item['unknown_waits'] == 0
    assert lane('resumed')['open_waits'] == [], 'working ends the current declared pause'
    waits = lane('decisionpause')['open_waits']
    assert [(w['key'], w['cause'], w['seconds']) for w in waits] == [
        ('a', 'review_merge', 90), (None, 'memory_gate', 80)], 'pause does not overwrite keyed decision'
wait = rows['emitted-unknownpause']['open_waits'][0]
assert wait['seconds'] is None and wait['since'] is None, 'unstamped pause stays unknown'
(main / 'config/fm-flow-check.sh').write_text('unrecognized clock policy\n')
assert next(l for l in json.loads(run())['lanes'] if l['task'] == 'memory')['stage_clock']['seconds'] is None
bad = subprocess.run(['bash', script, '--json', '--now', 'bad'], capture_output=True)
assert bad.returncode == 2
print('PASS: real flow CLI, two homes, queue, keyed waits, retained lifecycle, unknowns, read-only determinism')
PY
