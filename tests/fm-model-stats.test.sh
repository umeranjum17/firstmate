#!/usr/bin/env bash
# Integration: run the real bin/fm-model-stats.sh over isolated durable fleet
# records and read the per-model JSON the dashboard's Models view consumes.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR" "$TMP/xdg" "$TMP/tmp"
HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" TMPDIR="$TMP/tmp" python3 - "$ROOT/bin/fm-model-stats.sh" "$TMP" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

script, tmp = sys.argv[1], Path(sys.argv[2])
main, mate = tmp / 'home', tmp / 'byokit'
NOW = 1700000000
DAY = 86400
for h in (main, mate):
    (h / 'data/metrics').mkdir(parents=True, exist_ok=True)
    (h / 'state').mkdir(parents=True, exist_ok=True)

def iso(epoch):
    from datetime import datetime, timezone
    return datetime.fromtimestamp(epoch, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

(main / 'data/secondmates.md').write_text(
    f'- byokit - BYOKit (home: {mate}; scope: toolkit; projects: byokit)\n')

# Task outcomes: authoritative, never sampled.
outcome_header = 'home\ttask\tkind\tproject\tmodels\tstarted\tended\toutcome\tpr\n'
main_outcomes = (
    'main\tt1\tship\tacme\tclaude:claude-opus-5-5:medium\t%d\t%d\tmerged\thttps://github.com/acme/app/pull/1\n' % (NOW - 2 * DAY, NOW - DAY) +
    'main\tt2\tship\tacme\tclaude:claude-opus-5-5:medium;pi:opencode-go/muse-spark-1.3-contributor:high\t%d\t%d\tmerged\thttps://github.com/acme/app/pull/2\n' % (NOW - 3 * DAY, NOW - 2 * DAY) +
    'main\tt3\tship\tacme\tpi:opencode-go/muse-spark-1.3-contributor:medium\t%d\t%d\tcancelled\t\n' % (NOW - 5 * DAY, NOW - 4 * DAY) +
    'main\tt4\tscout\tacme\tpi:opencode-go/muse-spark-1.3-contributor:medium\t%d\t%d\tscout\t\n' % (NOW - DAY, NOW - DAY) +
    'main\tt5\tship\tacme\tpi:opencode-go/muse-spark-1.3-contributor:medium\t%d\t%d\tmerged\thttps://github.com/acme/app/pull/5\n' % (NOW - 20 * DAY, NOW - 19 * DAY))
(main / 'data/metrics/task-outcomes.tsv').write_text(outcome_header + main_outcomes)
(mate / 'data/metrics/task-outcomes.tsv').write_text(
    outcome_header +
    'byokit\tb1\tship\tbyokit\tpi:opencode-go/deepseek-v4.1-flash:medium\t%d\t%d\tmerged\thttps://github.com/acme/tool/pull/11\n' % (NOW - 2 * DAY, NOW - DAY))

# Merged-PR ledger, joined by PR URL.
pr_header = ('home\trepo\tpr\tcreated\tmerged\thours_to_merge\tbuild_hours\tcommits\tcommits_after_open\t'
             'rework_ci\trework_pipeline\trework_other\treverted\tescaped\tfirst_pass\tbot\ttitle\n')
def prow(home, repo, pr, merged, first_pass, commits_after_open=0, rci=0, rp=0, ro=0):
    return '%s\t%s\t%s\t%s\t%s\t0\t0\t1\t%d\t%d\t%d\t%d\t0\t0\t%d\t0\tt\n' % (
        home, repo, pr, iso(merged - 3600), iso(merged), commits_after_open, rci, rp, ro, first_pass)
(main / 'data/metrics/prs.tsv').write_text(pr_header +
    prow('main', 'acme/app', 1, NOW - DAY, 1) +
    prow('main', 'acme/app', 2, NOW - 2 * DAY, 0, commits_after_open=2, rci=1, rp=1) +
    prow('main', 'acme/app', 5, NOW - 19 * DAY, 1) +
    prow('main', 'acme/app', 3, NOW - 2 * DAY, 1) +
    prow('byokit', 'acme/tool', 11, NOW - DAY, 1))

# Sampled lane ledger: one task the outcome record predates (oldkind), plus a
# duplicate of t1 that must be ignored because the outcome record owns it.
lane_header = 'first_seen\thome\ttask\tkind\tproject\tharness\tmodel\teffort\tmode\tpr\n'
(main / 'data/metrics/lanes.tsv').write_text(lane_header +
    '%s\tmain\toldkind\tship\tacme\tpi\topencode-go/muse-spark-1.3-contributor\tmedium\tno-mistakes\thttps://github.com/acme/app/pull/3\n' % iso(NOW - 3 * DAY) +
    '%s\tmain\tt1\tship\tacme\tclaude\tclaude-opus-5-5\tmedium\tno-mistakes\thttps://github.com/acme/app/pull/1\n' % iso(NOW - 2 * DAY))

out = subprocess.check_output(['bash', script, '--json', '--now', str(NOW)],
                              env=dict(os.environ, FM_HOME=str(main), FM_DATA_OVERRIDE=''))
x = json.loads(out)

def model(rows, name):
    return next(m for m in rows if m['model'] == name)
def home_model(home, name):
    return next(m for m in x['by_home'][home] if m['model'] == name)

assert x['schema'] == 'fm-model-stats.v1' and x['windows'] == [7, 30], 'schema and windows'
assert x['coverage']['outcome_rows'] == 6 and x['coverage']['sampled_tasks'] == 1, 'source coverage'
assert sorted(x['by_home']) == ['byokit', 'main'], 'both homes present'

opus = model(x['models'], 'claude-opus-5-5')
w7 = opus['w7']
assert w7['n_finished'] == 1 and w7['merged'] == 1 and w7['ended_ship'] == 1, 'opus finished cohort'
assert w7['merge_rate'] == 1.0 and w7['merge_rate_sample'] == 1, 'opus merge rate over recorded outcomes'
assert w7['p50_hours'] == 24.0 and w7['p75_hours'] == 24.0 and w7['timed_merges'] == 1, 'opus time to merge'
assert w7['first_pass_n'] == 1 and w7['first_pass_rate'] == 1.0, 'opus first pass'
assert w7['switches'] == 0 and w7['switch_share'] == 0.0, 'opus has no switches'

muse = model(x['models'], 'opencode-go/muse-spark-1.3-contributor')
m7 = muse['w7']
# t2 (merged, switched in), t3 (cancelled), t4 (scout), oldkind (sampled merged).
assert m7['n_finished'] == 4, 'muse finished cohort includes the sampled task'
assert m7['merged'] == 2 and m7['ended_ship'] == 2, 'muse merged and ended ship'
assert m7['merge_rate'] == 0.5 and m7['merge_rate_sample'] == 2, 'sampled merges do not inflate the rate'
assert m7['unknown_outcome'] == 0 and m7['sampled'] is True, 'sampled cohort is disclosed'
assert m7['cancelled_failed'] == 1, 'cancelled task counted'
assert m7['switches'] == 1 and m7['switch_share'] == 0.25, 'a mid-task model change counts as a switch'
assert m7['first_pass_n'] == 1 and m7['first_pass_sample'] == 2 and m7['first_pass_rate'] == 0.5, 'first-pass join'
assert m7['rework'] == 1 and m7['rework_ci'] == 1 and m7['rework_pipeline'] == 1, 'rework join'

deep = home_model('byokit', 'opencode-go/deepseek-v4.1-flash')
assert deep['provider'] == 'OpenCode Go' and deep['name'] == 'DeepSeek', 'model naming'
assert deep['w7']['merge_rate'] == 1.0 and deep['w7']['n_finished'] == 1, 'per-home breakdown'

# The 30-day window reaches the older merged task.
assert muse['w30']['n_finished'] >= 5 and muse['w30']['merged'] >= 3, '30-day window includes older work'
assert opus['w30']['n_finished'] == 1, 'opus 30-day still one task'

# Deterministic and read-only.
before = {str(p): p.stat().st_mtime_ns for p in main.rglob('*') if p.is_file()}
out2 = subprocess.check_output(['bash', script, '--json', '--now', str(NOW)],
                               env=dict(os.environ, FM_HOME=str(main), FM_DATA_OVERRIDE=''))
assert out2 == out, 'deterministic output'
assert before == {str(p): p.stat().st_mtime_ns for p in main.rglob('*') if p.is_file()}, 'reader writes nothing'

# Degrades safely with no sources at all.
empty = tmp / 'empty'
empty.mkdir()
y = json.loads(subprocess.check_output(['bash', script, '--json', '--now', str(NOW)],
                                       env=dict(os.environ, FM_HOME=str(empty), FM_DATA_OVERRIDE='')))
assert y['models'] == [] and y['coverage']['outcome_rows'] == 0, 'an empty home is not an error'
assert y['limitations'], 'missing sources are disclosed'
print('ok - per-model aggregation, windows, per-home split and sampled fallback')
PY
