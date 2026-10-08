#!/usr/bin/env bash
# Waiting-state timers, called once per fm-watch.sh poll, independent of pane
# churn, busy proofs, and stale/wedge suppression. Configuration and defaults:
# docs/configuration.md "Waiting-state escalation".
# Each recorded task owns one durable episode under state/.waiting-timers/.
# The effective declaration is an own open blocker/decision, else a declared
# pause. Admitted Herdr agent.list blocked overrides it immediately, scoped to
# recorded panes only (admission policy: configuration reference above).
# Time starts at first observation and survives watcher restarts.
# Changing state/declaration/endpoint clears and re-arms the episode. Parent
# reports use the existing local/remote parent channel, never a captain alert.
# A waiting-timer-* key belongs to this library; it resolves that report when
# the episode ends. Main has no parent: further human escalation is judgment.
# Source through fm-watch.sh; the watcher supplies hashing and wake emission.

_FM_WAIT_TIMER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_WAIT_TIMER_DIR/fm-parent-channel-lib.sh"

fm_wait_timer_save() {  # <record> <signature> <since> <owner> <parent> <key>
  local file=$1 temp="${1%/*}/.${1##*/}.tmp.$$"
  shift
  printf '%s\t%s\t%s\t%s\t%s\n' "$@" > "$temp" && mv "$temp" "$file"
}

fm_wait_timer_report() {  # <status-line>
  local rc=0
  fm_parent_channel_report "$FM_HOME" "$STATE" "$1" || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "waiting timers: parent channel publication failed (code $rc; inspect identity/binding or destination permissions)" >&2
    return 1
  }
}

fm_wait_timer_owner_delivered() {
  [ "$1" -eq 0 ] || return 0
  fm_wait_timer_save "$FM_WAIT_OWNER_RECORD" "$FM_WAIT_OWNER_SIGNATURE" "$FM_WAIT_OWNER_SINCE" "$(date +%s)" 0 "$FM_WAIT_OWNER_KEY"
}

fm_wait_timers_tick() {
  local alert=${FM_WAIT_ALERT_SECS:-300} escalate=${FM_WAIT_ESCALATE_SECS:-900}
  local meta task backend window session native sessions='|' blocked='|' rows actor=Main
  local dir="$STATE/.waiting-timers" now record declaration verb signature old since owner parent key age reason until harness
  for native in "$alert" "$escalate"; do
    case "$native" in ''|*[!0-9]*|0* ) echo "waiting timers: thresholds must be positive decimal seconds" >&2; return 1 ;; esac
    [ "${#native}" -le 9 ] || { echo "waiting timers: threshold exceeds nine digits" >&2; return 1; }
  done
  [ "$escalate" -gt "$alert" ] || { echo "waiting timers: escalation must be later than owner alert" >&2; return 1; }
  now=$(date +%s) || return 1
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || actor='owning lead'
  # One bounded native read per recorded session, not one per lane. A failed
  # read stops the poll with its real cause rather than clearing blocked timers.
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    backend=$(fm_meta_get "$meta" backend)
    [ "$backend" = herdr ] || continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    fm_backend_source herdr || return 1
    fm_backend_herdr_parse_target "$window" || return 1
    session=$FM_BACKEND_HERDR_SESSION
    case "$sessions" in *"|$session|"*) continue ;; esac
    sessions="$sessions$session|"
    native=$(FM_BACKEND_HERDR_TIMEOUT=$FM_BACKEND_HERDR_READ_TIMEOUT fm_backend_herdr_cli "$session" agent list) || return 1
    rows=$(printf '%s' "$native" | jq -er '
      if (.result.agents | type) != "array" then error("agent.list missing agents array")
      else [.result.agents[] | select(.agent_status == "blocked") |
        if (.pane_id | type) == "string" then .pane_id else error("blocked agent missing pane_id") end] | join("\n") end') || return 1
    while IFS= read -r window; do
      [ -z "$window" ] || blocked="$blocked$session:$window|"
    done <<EOF
$rows
EOF
  done
  # Removed tasks also end their parent report, even when cleanup removed the
  # status log and metadata before the next poll.
  for record in "$dir"/*; do
    [ -f "$record" ] || continue
    task=${record##*/}
    [ ! -L "$record" ] || { echo "waiting timers: symlink episode $record" >&2; return 1; }
    [ ! -f "$STATE/$task.meta" ] || continue
    IFS=$'\t' read -r old since owner parent key < "$record" || return 1
    if [ "$parent" = 1 ] && [ -e "$FM_HOME/.fm-secondmate-home" ]; then
      fm_wait_timer_report "resolved [key=$key]: waiting-timer-cleared: $task removed" || return 1
    fi
    rm -f "$record" || return 1
  done
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}; task=${task%.meta}
    _fm_parent_channel_id_valid "$task" || { echo "waiting timers: invalid task id in $meta" >&2; return 1; }
    window=$(fm_backend_target_of_meta "$meta")
    declaration=''
    harness=$(fm_meta_get "$meta" harness)
    if [ "$harness" != cursor ]; then
      case "$blocked" in
        *"|$window|"*) [ -z "$window" ] || declaration=herdr-blocked ;;
      esac
    fi
    if [ -z "$declaration" ]; then
      rows=$(status_own_open_decisions "$STATE/$task.status")
      while IFS=$'\t' read -r old verb native; do
        case "$verb" in blocked|needs-decision) declaration="$verb [key=$old]: $native" ;; esac
      done <<EOF
$rows
EOF
      [ -n "$declaration" ] || declaration=$(status_declared_wait_line "$STATE/$task.status")
      status_is_paused "$declaration" || case "$declaration" in blocked*|needs-decision*) ;; *) declaration='' ;; esac
    fi
    if task_captain_call_open "$task"; then
      declaration=''
    elif status_is_paused "$declaration" && until=$(status_paused_until "$declaration") && [ "$now" -lt "$until" ]; then
      declaration=''
    fi
    record="$dir/$task"
    old=''; since=$now; owner=0; parent=0; key="waiting-timer-$task-$now-$$-$RANDOM"
    if [ -e "$record" ] || [ -L "$record" ]; then
      [ -f "$record" ] && [ ! -L "$record" ] || { echo "waiting timers: invalid episode $record" >&2; return 1; }
      IFS=$'\t' read -r old since owner parent key < "$record" || return 1
      case "$since:$owner:$parent:$key" in
        *[!0-9A-Za-z._:-]*) echo "waiting timers: corrupt episode $record" >&2; return 1 ;;
      esac
      case "$since" in ''|*[!0-9]*) echo "waiting timers: invalid episode time $record" >&2; return 1 ;; esac
      [ "${#since}" -le 12 ] && [ -n "$key" ] || { echo "waiting timers: corrupt episode identity $record" >&2; return 1; }
      case "$owner" in ''|*[!0-9]*) echo "waiting timers: invalid owner time $record" >&2; return 1 ;; esac
      [ "${#owner}" -le 12 ] || return 1
      case "$parent" in 0|1) ;; *) echo "waiting timers: invalid episode levels $record" >&2; return 1 ;; esac
      if [ "$owner" -eq 1 ]; then owner=0; fi
    fi
    signature=$(printf '%s' "$window|$declaration" | hash_pane)
    if [ -z "$declaration" ] || [ "$old" != "$signature" ]; then
      if [ "$parent" -eq 1 ] && [ -e "$FM_HOME/.fm-secondmate-home" ]; then
        fm_wait_timer_report "resolved [key=$key]: waiting-timer-cleared: $task changed state" || return 1
      fi
      rm -f "$record" || return 1
      [ -n "$declaration" ] || continue
      since=$now; owner=0; parent=0; key="waiting-timer-$task-$now-$$-$RANDOM"
      mkdir -p "$dir" || return 1
      fm_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" || return 1
    fi
    age=$((now - since))
    verb=$(status_line_verb "$declaration")
    [ "$declaration" != herdr-blocked ] || verb=herdr-blocked
    if [ "$age" -ge "$alert" ] && [ "$owner" -eq 0 ]; then
      reason="check: waiting-state $task ($verb, observed ${age}s, level=owner; $actor must recheck and unblock)"
      if ! fm_wake_queued_keys check | grep -Fx "$key-owner" >/dev/null; then
        fm_wake_append check "$key-owner" "$reason" || return 1
      fi
      FM_WAIT_OWNER_RECORD=$record
      FM_WAIT_OWNER_SIGNATURE=$signature
      FM_WAIT_OWNER_SINCE=$since
      FM_WAIT_OWNER_KEY=$key
      FM_WAKE_POST_OUTPUT_ACTION=fm_wait_timer_owner_delivered
      wake "$reason"
    fi
    if ! status_is_paused "$declaration" && [ "$owner" -gt 1 ] && [ "$((now - owner))" -ge "$((escalate - alert))" ] && [ "$parent" -eq 0 ]; then
      if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
        fm_wait_timer_report "blocked [key=$key]: waiting-timer-overdue: $task ($verb, observed ${age}s); owning lead has not cleared the wait; Main must unblock or steer the lead" || return 1
      fi
      parent=1
      fm_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" || return 1
    fi
  done
  return 0
}
