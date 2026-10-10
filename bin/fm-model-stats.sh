#!/usr/bin/env bash
# fm-model-stats.sh - per-model fleet statistics for the dashboard's Models view.
# Usage: FM_HOME=<home> fm-model-stats.sh --json [--now <unix-seconds>]
#
# Read-only: it writes nothing and never touches an endpoint. It reads this
# home, then every locally registered home discovered recursively through each
# home's data/secondmates.md, and combines three durable sources:
#   <home>/data/metrics/task-outcomes.tsv  the authoritative record written once
#     per task end by bin/fm-task-outcome.sh at teardown, carrying the model
#     history (harness:model:effort in launch order), spawn and end times,
#     outcome and PR URL. Never sampled.
#   <home>/data/metrics/lanes.tsv          the older sampled lane ledger. Used
#     only for tasks the outcomes file predates, marked sampled=true.
#   <home>/data/metrics/prs.tsv            one row per merged PR; joined by PR
#     URL for time-to-merge, first-pass, rework, revert and escape counts.
#
# Output fm-model-stats.v1 (times in seconds, null means unknown):
#   at, now, windows [7, 30]
#   models[w]    one entry per model over the window, largest finished first
#   by_home[w]   the same entries keyed by home, for the per-home breakdown
#   coverage     which sources were present, how many task rows each supplied,
#                and whether any sampled task contributed
#   limitations  human-readable coverage notices (the dashboard shows the count)
#
# A task is attributed to the model it ended on; a task whose history names more
# than one model also counts as a switch. Merge rate is merged ship tasks over
# finished ship tasks with a recorded terminal outcome; tasks with an unknown
# outcome (sampled lanes with no merged PR) are reported in unknown_outcome and
# left out of the denominator so a sampled row never fabricates a verdict.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${1:-}" = --json ] || { echo 'usage: fm-model-stats.sh --json [--now <unix-seconds>]' >&2; exit 2; }
shift
now=$(date +%s)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --now) [ "$#" -ge 2 ] || exit 2; now=$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
case "$now" in ''|*[!0-9]*) echo 'fm-model-stats: --now requires Unix seconds' >&2; exit 2 ;; esac
exec python3 - "${FM_HOME:-$SCRIPT_DIR/..}" "$now" <<'PY'
import json, math, os, re, statistics, sys
from datetime import datetime, timezone
from pathlib import Path

ROOT, NOW = Path(sys.argv[1]).resolve(), int(sys.argv[2])
WINDOWS = (7, 30)
DAY = 86400

def read_tsv(path):
    try:
        lines = Path(path).read_text(errors='replace').splitlines()
    except OSError:
        return None
    if not lines:
        return []
    cols = lines[0].split('\t')
    rows = []
    for line in lines[1:]:
        if line == '':
            continue
        fields = line.split('\t')
        if len(fields) != len(cols):
            continue
        rows.append(dict(zip(cols, fields)))
    return rows

def to_epoch(value):
    if value is None:
        return None
    value = value.strip()
    if re.fullmatch(r'\d+', value):
        return int(value)
    try:
        return int(datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp())
    except ValueError:
        return None

# Model display naming, matching the board's family table so the same model is
# named and coloured the same way in every view. The raw model id stays the
# grouping key, so DeepSeek on two providers stays two rows.
FAMILIES = (('opus', 'opus', 'Opus'), ('sonnet', 'sonnet', 'Sonnet'), ('fable', 'fable', 'Fable'),
            ('haiku', 'haiku', 'Haiku'), ('-sol', 'sol', 'Sol'), ('muse-spark', 'muse', 'Muse Spark'),
            ('qwen', 'qwen', 'Qwen'), ('grok', 'grok', 'Grok'), ('gemini', 'gemini', 'Gemini'),
            ('kimi', 'kimi', 'Kimi'), ('deepseek', 'deepseek', 'DeepSeek'), ('glm', 'glm', 'GLM'),
            ('gpt', 'gpt', 'GPT'))
PROVIDERS = {'ollama': 'Ollama', 'opencode-go': 'OpenCode Go', 'openai-codex': 'OpenAI Codex',
             'anthropic': 'Anthropic', 'google': 'Google', 'xai': 'xAI', 'moonshot': 'Moonshot',
             'zhipu': 'Zhipu', 'z-ai': 'Z.AI', 'mistral': 'Mistral'}

def model_info(raw):
    raw = (raw or '').strip()
    if raw in ('', '-', 'default', 'unknown'):
        return dict(model=raw or 'unknown', name='Not recorded', family='other', provider='')
    provider, _, name = raw.partition('/')
    if not name:
        provider, name = '', raw
    family, label = 'other', name
    low = raw.lower()
    for pat, fid, disp in FAMILIES:
        if pat in low:
            family, label = fid, disp
            break
    return dict(model=raw, name=label, family=family, provider=PROVIDERS.get(provider, provider))

def parse_incarnation(token):
    head, _, rest = token.partition(':')
    model, _, effort = rest.rpartition(':')
    if not model:
        model, effort = rest, 'default'
    return (head or 'default', model or 'default', effort or 'default')

def pr_key(url):
    m = re.fullmatch(r'https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)', (url or '').strip())
    return (m[1], m[2]) if m else None

# --- homes ---------------------------------------------------------------
homes, seen = {}, set()
pending = [('main', ROOT)]
while pending:
    name, home = pending.pop(0)
    if home in seen:
        continue
    seen.add(home)
    homes[name] = home
    try:
        lines = (home / 'data/secondmates.md').read_text(errors='replace').splitlines()
    except OSError:
        continue
    for line in lines:
        m = re.match(r'^- ([\w.-]+) - .*\((?:host:\s*([^;]+);\s*root:\s*([^;]+);\s*)?home:\s*([^;]+);', line)
        if not m:
            continue
        if m.group(2):
            homes[m.group(1)] = None
            continue
        path = Path(m.group(4).strip())
        if path.is_absolute():
            pending.append((m.group(1), path.resolve()))

# --- sources -------------------------------------------------------------
prs = read_tsv(ROOT / 'data/metrics/prs.tsv')
lanes = read_tsv(ROOT / 'data/metrics/lanes.tsv')
prs_by_key = {}
merged_at_by_key = {}
for row in prs or []:
    key = (row.get('repo') or '', row.get('pr') or '')
    if not key[1]:
        continue
    prs_by_key[key] = row
    when = to_epoch(row.get('merged'))
    if when is not None:
        merged_at_by_key[key] = when

outcome_rows, outcome_homes, sampled_rows = 0, [], 0
tasks = {}
def add_task(home, task, kind, project, models, started, ended, outcome, pr, sampled):
    tasks[(home, task)] = dict(home=home, task=task, kind=kind or 'ship', project=project or '-',
                               models=models, started=started, ended=ended, outcome=outcome, pr=pr or '',
                               sampled=sampled)
for name, home in homes.items():
    if home is None:
        continue
    rows = read_tsv(home / 'data/metrics/task-outcomes.tsv')
    if rows is None:
        continue
    outcome_homes.append(name)
    for row in rows:
        outcome_rows += 1
        models = [parse_incarnation(t) for t in (row.get('models') or '').split(';') if t]
        add_task(name, row.get('task') or '', row.get('kind') or 'ship', row.get('project') or '-',
                 models, to_epoch(row.get('started')), to_epoch(row.get('ended')),
                 row.get('outcome') or 'unknown', row.get('pr') or '', False)
# lanes.tsv fallback: only for (home, task) the outcomes file does not cover.
lane_groups = {}
for row in lanes or []:
    home, task = row.get('home') or '', row.get('task') or ''
    if not home or not task or (home, task) in tasks:
        continue
    key = (home, task)
    lane_groups.setdefault(key, []).append(row)
for (home, task), rows in lane_groups.items():
    sampled_rows += 1
    ordered = sorted(rows, key=lambda r: r.get('first_seen') or '')
    models, pr = [], ''
    for row in ordered:
        models.append((row.get('harness') or 'default', row.get('model') or 'default', row.get('effort') or 'default'))
        pr = row.get('pr') or pr
    started = to_epoch(ordered[0].get('first_seen')) if ordered else None
    key = pr_key(pr)
    merged_at = merged_at_by_key.get(key) if key else None
    outcome = 'merged' if merged_at is not None else 'unknown'
    add_task(home, task, ordered[0].get('kind') or 'ship', ordered[0].get('project') or '-',
             models, started, None, outcome, pr, True)

def row_for(pr):
    key = pr_key(pr)
    return prs_by_key.get(key) if key else None

TERMINAL = ('merged', 'closed', 'cancelled', 'failed')
def percentile(values, q):
    return values[math.ceil(q * len(values)) - 1] if values else None

def stats_for(cohort, window):
    lo = NOW - DAY * window
    n_started = sum(1 for t in cohort if t['started'] is not None and t['started'] >= lo and t['started'] <= NOW)
    finished = []
    for t in cohort:
        merge_row = row_for(t['pr'])
        merge_at = to_epoch(merge_row.get('merged')) if merge_row else None
        effective_end = t['ended'] if t['ended'] is not None else merge_at
        if effective_end is not None and lo <= effective_end <= NOW:
            finished.append((t, merge_row, merge_at))
    merged = [x for x in finished if x[0]['kind'] == 'ship' and
              (x[0]['outcome'] == 'merged' or x[2] is not None)]
    # Merge rate needs a real denominator: a sampled lane only proves the merges
    # it recorded, never the tasks that ended without one, so sampled rows are
    # left out of the rate and reported through unknown_outcome instead. The raw
    # merged count still includes them as a known lower bound.
    merged_recorded = [x for x in merged if not x[0]['sampled']]
    ended_ship = [x for x in finished if x[0]['kind'] == 'ship' and x[0]['outcome'] in TERMINAL
                  and not x[0]['sampled']]
    hours = sorted((x[2] - x[0]['started']) / 3600.0 for x in merged
                   if x[0]['started'] is not None and x[2] is not None and x[2] >= x[0]['started'])
    first_rows = [x[1] for x in merged_recorded if x[1] is not None]
    def total(field):
        return sum(int(x[1].get(field) or 0) for x in merged_recorded if x[1] is not None)
    rework = [x for x in merged_recorded if x[1] is not None and int(x[1].get('commits_after_open') or 0) > 0]
    switches = sum(1 for t, _, _ in finished if len({m for _, m, _ in t['models']}) > 1)
    out = dict(
        n_started=n_started,
        n_finished=len(finished),
        merged=len(merged),
        ended_ship=len(ended_ship),
        merge_rate=(round(len(merged_recorded) / len(ended_ship), 4) if ended_ship else None),
        p50_hours=(round(statistics.median(hours), 2) if hours else None),
        p75_hours=(round(percentile(hours, .75), 2) if hours else None),
        timed_merges=len(hours),
        first_pass_n=sum(1 for r in first_rows if r.get('first_pass') == '1'),
        first_pass_sample=len(first_rows),
        first_pass_rate=(round(sum(1 for r in first_rows if r.get('first_pass') == '1') / len(first_rows), 4) if first_rows else None),
        rework=len(rework),
        rework_ci=total('rework_ci'),
        rework_pipeline=total('rework_pipeline'),
        rework_other=total('rework_other'),
        reverted=total('reverted'),
        escaped=sum(1 for x in merged_recorded if x[1] is not None and int(x[1].get('escaped') or 0) > 0),
        cancelled_failed=sum(1 for t, _, _ in finished if t['outcome'] in ('cancelled', 'failed')),
        switches=switches,
        switch_share=(round(switches / len(finished), 4) if finished else None),
        unknown_outcome=sum(1 for t, _, _ in finished if t['outcome'] == 'unknown'),
        sampled=any(t['sampled'] for t, _, _ in finished),
    )
    out['merge_rate_sample'] = len(ended_ship)
    out['switch_sample'] = len(finished)
    return out

MAXW = max(WINDOWS)
def model_rows(cohort):
    groups = {}
    for t in cohort:
        final = t['models'][-1][1] if t['models'] else 'default'
        groups.setdefault(final, []).append(t)
    rows = []
    for raw, members in groups.items():
        info = model_info(raw)
        entry = dict(info)
        for window in WINDOWS:
            entry[f'w{window}'] = stats_for(members, window)
        rows.append(entry)
    rows.sort(key=lambda e: (-(e[f'w{max(WINDOWS)}']['n_finished']), -(e[f'w{min(WINDOWS)}']['n_finished']), e['model']))
    return rows

all_models = model_rows(list(tasks.values()))
by_home = {}
for name, home in sorted(homes.items()):
    if home is None:
        continue
    cohort = [t for t in tasks.values() if t['home'] == name]
    by_home[name] = model_rows(cohort)

limitations = []
if outcome_rows == 0:
    limitations.append('No task-outcome records yet; per-model figures come from the sampled lane ledger only and do not cover every task.')
elif sampled_rows:
    limitations.append(f'{sampled_rows} tasks predate the outcome record and come from the sampled lane ledger (marked sampled).')
if prs is None:
    limitations.append('No merged-PR record found; time-to-merge, first-pass, rework, revert and escape counts stay unknown.')
if not outcome_homes:
    limitations.append('No home has a task-outcome record yet.')
for name, home in homes.items():
    if home is None:
        limitations.append(f'{name} is a registered remote home; its task outcomes are not readable locally.')

print(json.dumps({
    'schema': 'fm-model-stats.v1',
    'at': NOW,
    'now': NOW,
    'windows': list(WINDOWS),
    'models': all_models,
    'by_home': by_home,
    'coverage': dict(outcome_rows=outcome_rows, sampled_tasks=sampled_rows,
                     outcome_homes=sorted(outcome_homes), prs_rows=len(prs or []), lanes_rows=len(lanes or [])),
    'limitations': limitations,
}, sort_keys=True, allow_nan=False))
PY
