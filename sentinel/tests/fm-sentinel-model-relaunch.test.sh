#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
mkdir -p "$d/home/fixture/users/user-017" "$d/home/fixture/users/user-009" "$d/stubs"
cat >"$d/home/fixture/users/user-009/fm-backend.sh" <<'SH'
fm_backend_source() { return 0; }
fm_backend_of_meta() { sed -n 's/^backend=//p' "$1"; }
fm_meta_get() { sed -n "s/^$2=//p" "$1" | head -n 1; }
fm_backend_herdr_cli() {
  local pane=
  while [ "$#" -gt 0 ]; do [ "$1" != --pane ] || { shift; pane=$1; }; shift || true; done
  case "$pane" in match) model=claude-sonnet-5-5 ;; mismatch) model= ;; *) return 2 ;; esac
  if [ -n "$model" ]; then
    printf '{"result":{"process_info":{"foreground_processes":[{"name":"claude","argv":["claude","--resume","abc","--model","%s"]}]}}}\n' "$model"
  else
    printf '{"result":{"process_info":{"foreground_processes":[{"name":"claude","argv":["claude","--resume","abc"]}]}}}\n'
  fi
}
SH
cat >"$d/home/fixture/users/user-009/fm-gate-refuse-lib.sh" <<'SH'
fm_refuse_if_gate_agent() { return 0; }
SH
cat >"$d/home/fixture/users/user-009/fm-wake-lib.sh" <<'SH'
fm_lock_try_acquire() { return 0; }
fm_lock_release() { :; }
SH
: >"$d/home/fixture/users/user-009/fm-supervision-lib.sh"
: >"$d/home/fixture/users/user-009/fm-operational-input.sh"
: >"$d/home/fixture/users/user-009/fm-classify-lib.sh"
for cmd in fm-control.sh fm-secondmate-restart.sh; do
  cat >"$d/home/fixture/users/user-009/$cmd" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$RELAUNCH_LOG"
SH
  chmod +x "$d/home/fixture/users/user-009/$cmd"
done
for row in 'match:match' 'mismatch:mismatch'; do
  IFS=: read -r id pane <<<"$row"
  cat >"$d/home/fixture/users/user-017/$id.meta" <<EOF
harness=claude
model=claude-sonnet-5-5
kind=scout
backend=herdr
herdr_session=default
herdr_pane_id=$pane
EOF
done
: > "$d/relaunch.log"
PATH="$PATH" RELAUNCH_LOG="$d/relaunch.log" FM_HOME="$d/home" FM_SENTINEL_MODEL_EVENT=fixture-event \
  "$ROOT/sentinel/bin/fm-sentinel.sh" model-reconcile
[ "$(wc -l < "$d/relaunch.log")" -eq 1 ]
grep -q '^fm-control.sh mismatch relaunch --model claude-sonnet-5-5$' "$d/relaunch.log"
PATH="$PATH" RELAUNCH_LOG="$d/relaunch.log" FM_HOME="$d/home" FM_SENTINEL_MODEL_EVENT=fixture-event \
  "$ROOT/sentinel/bin/fm-sentinel.sh" model-reconcile
[ "$(wc -l < "$d/relaunch.log")" -eq 1 ]
printf 'PASS: only mismatched Claude process relaunches once per event\n'
