#!/usr/bin/env bash
# fm-sentinel.sh - recovery that runs OUTSIDE the agent runtime.
#
# Every Firstmate watcher, Stop-hook arm, and away daemon runs inside the Herdr
# server's process tree, so when the server is killed (an out-of-memory kill of
# its service unit, for example) they all die with it. Herdr restarts and
# resumes the agent sessions it recorded, but nothing re-arms supervision: a
# Claude primary whose turn had ended sits at its prompt, leads and workers sit
# idle, and Herdr resumes each agent in its pane's creation folder, which for a
# freshly spawned worker is the PRIMARY checkout rather than its worktree. This
# script is the piece that must live in its own process (a systemd user service
# from `unit`), never inside Herdr.
#
# Usage (FM_HOME is required; the backend session defaults to Herdr's default):
#   FM_HOME=<home> fm-sentinel.sh tick       one pass; what a scheduler runs
#   FM_HOME=<home> fm-sentinel.sh loop       tick every FM_SENTINEL_INTERVAL seconds
#   FM_HOME=<home> fm-sentinel.sh reconcile  nudge or relaunch this home's direct reports
#   FM_HOME=<home> fm-sentinel.sh unit       print a systemd user service running `loop`
#
# tick, under the home's state/.sentinel.lock:
#   1. Reads the Herdr server identity for FM_SENTINEL_HERDR_SESSION (default the
#      backend's own HERDR_SESSION, else `default`) as the inode and bind time of its API socket, which the server
#      recreates on every start. A stopped server is left alone: its supervisor
#      restarts it, and this script never starts one.
#   2. On the first identity it records it in state/.sentinel-herdr-identity.
#      On a changed identity it runs `reconcile`, records the new identity, and
#      leaves a pending restart wake in state/.sentinel-wake-pending.
#   3. Wakes the primary session when a restart wake is pending, or when
#      supervision is needed and the watcher beacon is older than the grace
#      (bin/fm-supervision-lib.sh owns that predicate). A beacon-only wake is
#      repeated at most once per FM_SENTINEL_REWAKE_SECS for one beacon age.
#      The primary is the Herdr pane whose agent session is state/.lock-session.
#      The wake is typed only when that pane reads not busy and its composer
#      reads exactly empty, as the away daemon's injection does, so it never
#      lands mid-turn or on top of the captain's typing; a deferred wake stays
#      pending for the next tick. The typed text is an operational-input
#      doorbell whose record says what happened; handling it is an ordinary
#      turn, and that turn's end re-arms supervision through the primary's own
#      re-arm owner (docs/watcher-continuity.md).
#
# reconcile, for each local direct report in state/*.meta on Herdr:
#   - A secondmate whose agent is alive gets one recovery order through
#     bin/fm-send.sh, telling it to run this same reconcile in its own home and
#     end its turn so its supervision re-arms. A dead secondmate is left to the
#     watcher's secondmate liveness relaunch; a remote one is skipped.
#   - A ship or scout whose current state (bin/fm-crew-state.sh) is not done or
#     failed is relaunched in its recorded worktree through bin/fm-control.sh
#     when its agent is dead, missing, or alive outside that worktree, and is
#     sent one continue nudge through bin/fm-send.sh when it is alive inside it.
#   - A done or failed ship or scout alive outside its worktree is exited
#     through bin/fm-control.sh, so no worker stays live in a primary checkout.
#   Orders and nudges are fire-and-forget with a delivery id derived from the
#   task and the server identity (FM_SENTINEL_EPISODE, which a secondmate's
#   order passes on), so a repeat delivers nothing new.
#   One line per task goes to stdout and state/.sentinel.log.
#
# Knobs: FM_SENTINEL_HERDR_SESSION (HERDR_SESSION, else default), FM_SENTINEL_INTERVAL (60),
# FM_SENTINEL_REWAKE_SECS (1800), FM_GUARD_GRACE (300).
# Exit: 0 after a pass (including deferred work), 1 when the pass hit an error
# it logged, 2 for usage or a missing FM_HOME.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '14,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  tick|loop|reconcile|unit) CMD=$1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ -n "${FM_HOME:-}" ] || { echo "fm-sentinel: FM_HOME must be set explicitly" >&2; exit 2; }
FM_HOME=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || { echo "fm-sentinel: FM_HOME is not a directory" >&2; exit 2; }
export FM_HOME
STATE="$FM_HOME/state"
SESSION=${FM_SENTINEL_HERDR_SESSION:-${HERDR_SESSION:-default}}
INTERVAL=${FM_SENTINEL_INTERVAL:-60}
REWAKE=${FM_SENTINEL_REWAKE_SECS:-1800}
GRACE=${FM_GUARD_GRACE:-300}
LOG="$STATE/.sentinel.log"

if [ "$CMD" = unit ]; then
  unit_quote() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//%/%%}
    printf '"%s"' "$value"
  }
  cat <<EOF
[Unit]
Description=Firstmate sentinel for ${FM_HOME//%/%%} (recovers supervision after an agent-runtime restart)

[Service]
Environment=$(unit_quote "FM_HOME=$FM_HOME")
Environment=$(unit_quote "PATH=$PATH")
ExecStart=$(unit_quote "$SCRIPT_DIR/fm-sentinel.sh") loop
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
  exit 0
fi

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
fm_backend_source herdr || { echo "fm-sentinel: cannot load the Herdr adapter" >&2; exit 1; }

say() {
  printf '%s\n' "$*"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true
}

# Inode and bind time of the server's API socket; empty when it is not running.
herdr_identity() {
  local status sock
  status=$(fm_backend_herdr_cli "$SESSION" status --json 2>/dev/null) || return 0
  [ "$(printf '%s' "$status" | jq -r '.server.running // false' 2>/dev/null)" = true ] || return 0
  sock=$(printf '%s' "$status" | jq -r '.server.socket // empty' 2>/dev/null)
  [ -S "$sock" ] || return 0
  # shellcheck disable=SC2012 # the socket path is Herdr's own, and ls -i is the portable inode read.
  printf '%s:%s\n' "$(ls -di "$sock" | awk '{print $1}')" "$(fm_path_mtime "$sock")"
}

# Run one recovery action, logging its outcome; a failure sets RECONCILE_RC.
act() {  # <task-id> <done-message> <command...>
  local id=$1 done=$2 out
  shift 2
  if out=$("$@" 2>&1); then
    say "$id: $done"
  else
    say "$id: FAILED ($done): $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    RECONCILE_RC=1
  fi
}

delivery_id() {
  printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16
}

reconcile() {  # <episode>
  local episode=$1 meta id kind target agent cwd wt current note
  RECONCILE_RC=0
  note="A Herdr server restart stopped this task's agent; this relaunch put it back in its recorded worktree. Continue the task from the local copy as it stands."
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$(fm_backend_of_meta "$meta")" = herdr ] || continue
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || { say "$id: skipped (remote)"; continue; }
    kind=$(fm_meta_get "$meta" kind)
    target=$(fm_backend_target_of_meta "$meta")
    agent=$(fm_backend_agent_state herdr "$target" "$meta" "$id" 2>/dev/null)
    if [ "$kind" = secondmate ]; then
      if [ "$agent" != alive ]; then
        say "$id: secondmate agent $agent; left to the watcher's secondmate liveness relaunch"
        continue
      fi
      act "$id" "ordered to recover" "$SCRIPT_DIR/fm-send.sh" "$id" --fire-and-forget "$(delivery_id "$id:$episode")" \
        "The Herdr server restarted, so every agent and watcher in it stopped and Herdr resumed the sessions, some in a primary checkout instead of their worktree. In your own home run: FM_HOME=$(fm_meta_get "$meta" home) FM_SENTINEL_EPISODE=$episode $SCRIPT_DIR/fm-sentinel.sh reconcile. Then run bin/fm-session-start.sh if this session was resumed, reconcile your lanes, and end the turn so your supervision re-arms."
      continue
    fi
    case "$kind" in ship|scout) ;; *) continue ;; esac
    current=$(FM_CREW_STATE_NO_FORGE=1 "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | awk '{print $2}')
    wt=$(fm_canonical_existing_dir "$(fm_meta_get "$meta" worktree)")
    cwd=
    if [ "$agent" = alive ]; then
      cwd=$(fm_canonical_existing_dir "$(fm_backend_herdr_current_path "$target")")
    fi
    if [ -z "$wt" ]; then
      case "$agent:$current" in
        alive:done|alive:failed)
          act "$id" "$current, was live in ${cwd:-an unreadable folder}; exited" "$SCRIPT_DIR/fm-control.sh" "$id" exit
          ;;
        *)
          say "$id: worktree missing; skipped"
          RECONCILE_RC=1
          ;;
      esac
      continue
    fi
    case "$agent:$current" in
      alive:done|alive:failed)
        case "$cwd/" in
          "$wt"/*) say "$id: $current, in its worktree; left alone" ;;
          *) act "$id" "$current, was live in ${cwd:-an unreadable folder}; exited" \
               "$SCRIPT_DIR/fm-control.sh" "$id" exit ;;
        esac
        ;;
      *:done|*:failed) say "$id: $current, agent $agent; left alone" ;;
      alive:*)
        case "$cwd/" in
          "$wt"/*)
            act "$id" "alive in its worktree; nudged" \
              "$SCRIPT_DIR/fm-send.sh" "$id" --fire-and-forget "$(delivery_id "$id:$episode")" \
              "The Herdr server restarted and resumed this session. Continue your task from where you left off; if you were waiting on a backgrounded command, check whether it is still running."
            ;;
          *)
            act "$id" "was live in ${cwd:-an unreadable folder}; relaunched in $wt" \
              "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note "$note"
            ;;
        esac
        ;;
      *)
        act "$id" "agent $agent; relaunched in $wt" \
          "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note "$note"
        ;;
    esac
  done
  return "$RECONCILE_RC"
}

# The Herdr pane whose agent session is this home's locked primary session.
primary_target() {
  local sid panes
  sid=$(head -n 1 "$STATE/.lock-session" 2>/dev/null)
  [ -n "$sid" ] || return 1
  panes=$(fm_backend_herdr_cli "$SESSION" api snapshot 2>/dev/null \
    | jq -r --arg sid "$sid" '.result.snapshot.agents[]? | select(.agent_session.value == $sid) | .pane_id' 2>/dev/null)
  [ -n "$panes" ] && [ "$(printf '%s\n' "$panes" | wc -l)" -eq 1 ] || return 1
  printf '%s:%s\n' "$SESSION" "$panes"
}

wake_primary() {  # <body>
  local target doorbell verdict rec
  target=$(primary_target) || { say "primary: no single Herdr pane runs session $(head -n 1 "$STATE/.lock-session" 2>/dev/null); wake deferred"; return 1; }
  [ "$(fm_backend_busy_state herdr "$target")" != busy ] || { say "primary: $target mid-turn; wake deferred"; return 1; }
  [ "$(fm_backend_composer_state herdr "$target")" = empty ] || { say "primary: $target composer not empty; wake deferred"; return 1; }
  fm_operational_record_write "$STATE" watcher "$1" doorbell || { say "primary: could not write the wake record"; return 1; }
  verdict=$(fm_backend_send_text_submit herdr "$target" "$doorbell" 3 0.5 0.5 2>/dev/null)
  if [ "$verdict" != empty ]; then
    if fm_operational_doorbell_path "$doorbell" rec 2>/dev/null; then rm -f "$rec"; fi
    say "primary: wake typed into $target but not confirmed ($verdict)"; return 1;
  fi
  say "primary: woke $target"
}

tick() {
  local id prev beat woken_beat age last body rc=0
  id=$(herdr_identity)
  [ -n "$id" ] || return 0
  prev=$(cat "$STATE/.sentinel-herdr-identity" 2>/dev/null)
  if [ "$prev" != "$id" ]; then
    if [ -n "$prev" ]; then
      say "herdr session $SESSION restarted (socket $prev -> $id)"
      if reconcile "$id"; then
        printf '%s\n' "The Herdr server restarted at $(date -u +%Y-%m-%dT%H:%M:%SZ), which stopped every agent and watcher in it. The sentinel already reconciled this home's direct reports; its lines are in $LOG. Run bin/fm-session-start.sh if this session was resumed, reconcile what remains, then end the turn so supervision re-arms." \
          >"$STATE/.sentinel-wake-pending"
        printf '%s\n' "$id" >"$STATE/.sentinel-herdr-identity"
      else
        rc=1
      fi
    else
      printf '%s\n' "$id" >"$STATE/.sentinel-herdr-identity"
    fi
  fi
  if [ -f "$STATE/.sentinel-wake-pending" ]; then
    wake_primary "$(cat "$STATE/.sentinel-wake-pending")" && rm -f "$STATE/.sentinel-wake-pending"
    return "$rc"
  fi
  fm_supervision_unhealthy "$STATE" "$GRACE" || return "$rc"
  beat=$(fm_path_mtime "$STATE/.last-watcher-beat")
  read -r last woken_beat <"$STATE/.sentinel-wake-last" 2>/dev/null || true
  age=$(( $(date +%s) - ${last:-0} ))
  [ "${woken_beat:-}" != "${beat:-none}" ] || [ "$age" -ge "$REWAKE" ] || return "$rc"
  body="Supervision is needed but the watcher beacon is $FM_SUP_BEACON_DESC old and no turn is running, so nothing is watching the fleet. Run bin/fm-session-start.sh if this session was resumed, reconcile, then end the turn so supervision re-arms."
  wake_primary "$body" && printf '%s %s\n' "$(date +%s)" "${beat:-none}" >"$STATE/.sentinel-wake-last"
  return "$rc"
}

locked() {
  local lock="$STATE/.sentinel.lock" rc=0
  fm_lock_try_acquire "$lock" || return 0
  "$@" || rc=$?
  fm_lock_release "$lock"
  if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 1000 ]; then
    tail -n 500 "$LOG" >"$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
  fi
  return "$rc"
}

case "$CMD" in
  tick) locked tick ;;
  reconcile) locked reconcile "${FM_SENTINEL_EPISODE:-$(herdr_identity)}" ;;
  loop)
    while :; do
      locked tick || true
      sleep "$INTERVAL"
    done
    ;;
esac
