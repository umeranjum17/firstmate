#!/usr/bin/env bash
# jg-hold-release-lib.sh - hold-time rules that let a hold release itself.
#
# A hold that waits on a date or on other work must say so in a form the
# watcher can read, or nothing ever releases it. This library owns the two
# hold-time rules; bin/jg-hold-sweep.sh owns the release that follows.
#   - A future date in a hold reason without --until is refused: the date
#     would be prose only, and the hold would stay held after it passed.
#   - --waits-on <task:ID|pr:URL|key:SLUG> is stored as a trailing
#     "[waits-on=REF]" token in the reason, so no new backlog field is needed.
#     A captain-kind hold never takes it: a captain question is released only
#     by the captain's answer (bin/jg-captain-hold.sh).
#
# Source this file; it defines functions only.

# jg_hold_future_date <text>: print the first YYYY-MM-DD at or after today
# (UTC) named in the text; return 1 when there is none.
jg_hold_future_date() {
  local today d
  today=$(date -u +%Y-%m-%d)
  for d in $(printf '%s' "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}'); do
    [ "$d" \< "$today" ] && continue
    printf '%s' "$d"
    return 0
  done
  return 1
}

# jg_hold_reason_guard <reason> <until>: return 2 with the exact fix on stderr
# when the reason names an upcoming date and no --until is given.
jg_hold_reason_guard() {
  local d
  [ -z "$2" ] || return 0
  d=$(jg_hold_future_date "$1") || return 0
  printf 'the hold reason names %s but the hold has no --until, so nothing would release it: pass --until %s to release and wake on that day, or take the date out of the reason\n' "$d" "$d" >&2
  return 2
}

# jg_hold_waits_on_ref <reason>: print the REF of a "[waits-on=REF]" token.
jg_hold_waits_on_ref() {
  printf '%s' "$1" | sed -n 's/.*\[waits-on=\([^]]*\)\].*/\1/p' | head -1
}

# jg_hold_rewrite_args: rewrite the global ARGS (hold <id> ...) for tasks-axi.
# Moves --waits-on REF into the reason token and applies the date guard.
# Needs a tasks_axi function that runs against the right backlog.
jg_hold_rewrite_args() {
  local out=() i=0 n=${#ARGS[@]} a reason='' until='' kind='' waits='' id=${ARGS[1]:-} j
  while [ "$i" -lt "$n" ]; do
    a=${ARGS[$i]}
    case "$a" in
      --waits-on) waits=${ARGS[$((i + 1))]:-}; i=$((i + 2)); continue ;;
      --reason) reason=${ARGS[$((i + 1))]:-} ;;
      --until) until=${ARGS[$((i + 1))]:-} ;;
      --kind) kind=${ARGS[$((i + 1))]:-} ;;
    esac
    out+=("$a")
    i=$((i + 1))
  done
  jg_hold_reason_guard "$reason" "$until" || return 2
  if [ -n "$waits" ]; then
    [ "$kind" != captain ] || { echo "a captain hold is released only by the captain's answer; --waits-on does not apply" >&2; return 2; }
    case "$waits" in
      task:?*)
        if [ "${waits#task:}" = "$id" ] || ! tasks_axi show "${waits#task:}" >/dev/null 2>&1; then
          echo "--waits-on $waits must name another task in this backlog" >&2
          return 2
        fi
        ;;
      pr:https://*|key:?*) ;;
      *) echo "--waits-on must be task:<id>, pr:<https url>, or key:<status key>" >&2; return 2 ;;
    esac
    for j in "${!out[@]}"; do
      [ "${out[$j]}" = --reason ] && out[j + 1]="$reason [waits-on=$waits]"
    done
  fi
  ARGS=("${out[@]}")
}
