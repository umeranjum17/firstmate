#!/usr/bin/env bash
# jg-hold-sweep.sh - release holds that have run out, and flag asks nobody answered.
#
# Usage: jg-hold-sweep.sh holds
#        jg-hold-sweep.sh asks [--record]
#
# bin/jg-watch.sh runs each subcommand on a timer and turns its output into a
# check wake for this home's own Overwatch (a Squad Lead for a Squad Lead home).
# Both print the wake reason on stdout and exit 0 when there is something to act
# on, 1 when there is nothing, and 3 when the backlog could not be read.
#
# holds: a queued task held with a non-captain kind is released through
#   `tasks-axi unhold` when either
#   - its --until date has arrived, or
#   - its reason carries a "[waits-on=REF]" token (jg-tasks-axi.sh hold
#     --waits-on) and REF has closed: task:<id> is Done or gone, pr:<url> is
#     merged or closed on the forge, key:<slug> has a `resolved` status line in
#     this home.
#   A ref that cannot be read leaves the hold held. A captain-kind hold is never
#   touched: it waits for the captain's answer, whatever date or ref it names.
#
# asks: an open `blocked` or `needs-decision` status record (the
#   jg-classify-lib.sh fold) stamped [at=<epoch>] more than N hours ago, where N
#   is config/stale-ask-hours (a positive integer, default 4). The wake tells
#   Overwatch to decide each one or escalate it. An answer closes the record, so
#   an answered ask never shows again; an unanswered one is raised again every N
#   hours. Records a captain-hold relay or a supervisor library opened, and
#   records with no [at=] stamp (unknown age), are left out. `--record` marks the
#   listed asks as raised and is called only after the wake was queued.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
export JG_HOME
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"

# shellcheck source=bin/jg-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-classify-lib.sh"
# shellcheck source=bin/jg-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-timeout-lib.sh"
# shellcheck source=bin/jg-hold-release-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-hold-release-lib.sh"

ta() { "$SCRIPT_DIR/jg-tasks-axi.sh" "$@"; }

# 0 closed, 1 still open, 2 cannot tell
ref_closed() {  # <ref>
  local ref=$1 out state f verb
  case "$ref" in
    task:*)
      if out=$(ta show "${ref#task:}" 2>&1); then
        state=$(printf '%s\n' "$out" | sed -n 's/^  state: //p' | head -1)
        [ "$state" = "done" ] && return 0
        return 1
      fi
      case "$out" in *NOT_FOUND*) return 0 ;; esac
      return 2
      ;;
    pr:*)
      state=$(jg_run_timed 15 gh pr view "${ref#pr:}" --json state -q .state 2>/dev/null) || return 2
      case "$state" in MERGED|CLOSED) return 0 ;; OPEN) return 1 ;; esac
      return 2
      ;;
    key:*)
      for f in "$STATE"/*.status; do
        verb=$(status_key_closing_verb "$f" "${ref#key:}")
        [ "$verb" = resolved ] && return 0
      done
      return 1
      ;;
  esac
  return 2
}

sweep_holds() {
  local rows id until kind held today reason ref why='' released='' n=0
  today=$(date -u +%Y-%m-%d)
  rows=$(ta list --state queued --fields hold_until,hold_kind,held) || return 3
  # The last three fields never hold a comma, so they parse from the right.
  rows=$(printf '%s\n' "$rows" | awk -F, '/^tasks\[/ { on = 1; next } !/^  / { on = 0 } on {
    id = substr($1, 3); n = NF
    for (i = n - 2; i <= n; i++) gsub(/"/, "", $i)
    print id "\t" $(n - 2) "\t" $(n - 1) "\t" $n }')
  while IFS=$'\t' read -r id until kind held; do
    [ -n "$id" ] || continue
    case "$kind" in -|captain) continue ;; esac
    reason=
    if [ "$until" != - ] && [ ! "$until" \> "$today" ]; then
      why="its --until date $until arrived"
    elif [ "$held" = yes ]; then
      reason=$(ta show "$id" | sed -n 's/^  hold_reason: //p' | head -1)
      ref=$(jg_hold_waits_on_ref "$reason")
      [ -n "$ref" ] || continue
      ref_closed "$ref" || continue
      why="$ref closed"
    else
      continue
    fi
    ta unhold "$id" >/dev/null 2>&1 || continue
    released="${released:+$released, }$id ($why)"
    n=$((n + 1))
  done <<EOF
$rows
EOF
  [ "$n" -gt 0 ] || return 1
  printf 'check: hold released: %s - the held work is dispatchable again: dispatch it now, or hold it again with a new reason\n' "$released"
}

stale_ask_hours() {
  local raw
  raw=$(cat "$CONFIG/stale-ask-hours" 2>/dev/null)
  case "$raw" in ''|*[!0-9]*|0) raw=4 ;; esac
  printf '%s' "$raw"
}

# The [at=] epoch of the latest <verb> line for <key> in a status file.
ask_opened_at() {  # <status-file> <key> <verb>
  local line verb key at='' found=
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" verb
    [ "$verb" = "$3" ] || continue
    _jg_decision_key "$line" default key || continue
    [ "$key" = "$2" ] || continue
    found=$(status_line_at_epoch "$line") && at=$found
  done < "$1"
  [ -n "$at" ] && printf '%s' "$at"
}

sweep_asks() {  # [record]
  local limit now f task key verb note at id last list='' marks='' seen mark
  limit=$(( $(stale_ask_hours) * 3600 ))
  now=$(date +%s)
  mark="$STATE/.stale-ask-raised"
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    task=${f##*/}; task=${task%.status}
    while IFS=$'\t' read -r key verb note; do
      case "$verb" in blocked|needs-decision) ;; *) continue ;; esac
      at=$(ask_opened_at "$f" "$key" "$verb") || continue
      [ $(( now - at )) -ge "$limit" ] || continue
      id="$task|$key|$verb|$at"
      last=$(awk -F'\t' -v i="$id" '$1 == i { print $2 }' "$mark" 2>/dev/null)
      if [ -n "$last" ] && [ $(( now - last )) -lt "$limit" ]; then
        marks="$marks$id"$'\t'"$last"$'\n'
        continue
      fi
      marks="$marks$id"$'\t'"$now"$'\n'
      list="${list:+$list; }$task $verb $(( (now - at) / 3600 ))h: $(printf '%.80s' "$note" | tr '\t\r\n' '   ')"
    done <<EOF
$(status_own_open_decisions "$f")
EOF
  done
  if [ "${1:-}" = record ]; then
    printf '%s' "$marks" > "$mark"
    return 0
  fi
  [ -n "$list" ] || return 1
  printf 'check: stale ask, no answer for over %sh: %s - decide each now (answer it with jg-send --resolve-key) or escalate it to the captain as a board card\n' "$(stale_ask_hours)" "$list"
}

case "${1:-}" in
  holds) sweep_holds ;;
  asks) sweep_asks "$([ "${2:-}" = --record ] && echo record)" ;;
  -h|--help|'')
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    ;;
  *) echo "jg-hold-sweep: unknown subcommand: $1" >&2; exit 2 ;;
esac
