#!/usr/bin/env bash
# The fork's real wait-timer journey (tests/fm-wait-timers.test.sh drives the real
# watcher cycle and drain, only the terminal API is a fixture) with the timer
# library reached through the step-B hook lines. Present -> the journey passes;
# absent -> the hook lines are a no-op under set -e (kun behavior).
# FM_TEST_FORK names a read-only Firstmate checkout.
set -euo pipefail
addons=$(cd "$(dirname "$0")/../.." && pwd)
: "${FM_TEST_FORK:?set FM_TEST_FORK to a Firstmate checkout}"
d=$(mktemp -d)
cleanup() {
  rc=$?
  if [ "$rc" -eq 0 ]; then rm -rf -- "$d"; else printf 'fixture retained: %s\n' "$d" >&2; fi
}
trap cleanup EXIT
export HOME=$d/user TMPDIR=$d/tmp
mkdir -p "$HOME" "$TMPDIR" "$d/fork"
cp -a "$FM_TEST_FORK/bin" "$FM_TEST_FORK/tests" "$d/fork/"
rm -f "$d/fork/bin/fm-wait-timers-lib.sh"   # step B deletes the fork-only copy
# Step-B simulation on the private copy only: the exact hook lines.
python3 - "$d/fork/bin" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
loader = '[ ! -r "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/wait-timers/bin/fm-wait-timers-lib.sh" ] || . "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/wait-timers/bin/fm-wait-timers-lib.sh"'
def edit(name, pairs):
    p = root / name
    s = p.read_text()
    for old, new in pairs:
        assert old in s, (name, old)
        s = s.replace(old, new)
    p.write_text(s)
edit('fm-watch.sh', [
    ('. "$SCRIPT_DIR/fm-wait-timers-lib.sh"', loader),
    ('  fm_wait_timers_tick || {\n    echo "watcher: waiting-state timer check failed" >&2\n    exit 1\n  }',
     '  if declare -F fm_wait_timers_tick >/dev/null; then fm_wait_timers_tick || { echo "watcher: waiting-state timer check failed" >&2; exit 1; }; fi')])
edit('fm-push-transition-lib.sh', [
    ('. "$FM_PUSH_TRANSITION_LIB_DIR/fm-wait-timers-lib.sh"', loader),
    ('  [ -z "$task" ] || fm_wait_timer_push_delivered "$task" "$window" || exit 1',
     '  if [ -n "$task" ] && declare -F fm_wait_timer_push_delivered >/dev/null; then fm_wait_timer_push_delivered "$task" "$window" || exit 1; fi')])
PY
bash -n "$d/fork/bin/fm-watch.sh" "$d/fork/bin/fm-push-transition-lib.sh"

# Present: the unmodified fork journey over the add-on library.
(cd "$d/fork" && env -u FM_TASK_ID FM_HOME="$d/fork" FM_ADDONS_DIR="$addons" bash tests/fm-wait-timers.test.sh) > "$d/present.out" 2>&1 \
  || { echo "FAIL: wait-timer journey with the add-on present" >&2; tail -20 "$d/present.out" >&2; exit 1; }

# Absent: the same lines load nothing, define nothing, and survive set -e.
( set -e; FM_HOME="$d/fork"; FM_ADDONS_DIR="$d/none"
  [ ! -r "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/wait-timers/bin/fm-wait-timers-lib.sh" ] || exit 1
  if declare -F fm_wait_timers_tick >/dev/null; then exit 1; fi
  if declare -F fm_wait_timer_push_delivered >/dev/null; then exit 1; fi ) \
  || { echo "FAIL: absent add-on must be a no-op" >&2; exit 1; }
echo "ok: wait-timers present -> fork journey passes; absent -> kun behavior"
