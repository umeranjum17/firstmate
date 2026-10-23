#!/usr/bin/env bash
# Shared fork guard for captain asks. Callers supply tasks_axi (home addressing),
# SCRIPT_DIR, and fail; these checks run before any close or archive mutation.
# A [captain-ask] row leaves the backlog only with the captain's answer or a merged PR.
guard_captain_ask() {  # <id>
  local show pr title
  [ -n "$1" ] || return 0
  show=$(tasks_axi show "$1" --full 2>/dev/null) \
    || fail "cannot read $1 to check whether it is a [captain-ask] item; it stays in the backlog until the read succeeds"
  title=$(printf '%s\n' "$show" | sed -n 's/^  title: //p' | head -1)
  case "$title" in
    '') fail "cannot read the title of $1 to check whether it is a [captain-ask] item; it stays in the backlog" ;;
    *'[captain-ask]'*) ;;
    *) return 0 ;;
  esac
  "$SCRIPT_DIR/fm-captain-hold.sh" answered "$1" && return 0
  for pr in $(printf '%s\n' "$show" | sed -n 's/^  links: //p' | grep -o 'pr:[^" ,]*' | sed 's/^pr://'); do
    [ "$(gh pr view "$pr" --json state -q .state 2>/dev/null)" = MERGED ] && return 0
  done
  fail "$1 is a [captain-ask] item with no recorded captain answer (bin/fm-captain-hold.sh answer) and no merged PR (tasks-axi update --pr); it cannot leave the backlog"
}

# Conservative preflight: do not archive any section with an unanswered ask.
guard_captain_ask_prune() {  # <state>
  local listing ids id count data root backend
  data=$(fm_backlog_data_absolute "$DATA") || fail "cannot resolve backlog data before pruning"
  root=$(fm_backlog_root "$data") || fail "$FM_BACKLOG_TRANSITION_ERROR"
  backend=$(fm_tasks_axi_backend "$root") || fail "cannot read backlog backend before pruning"
  [ "$backend" = markdown ] || return 0
  listing=$(tasks_axi list --state "$1") || fail "cannot read $1 tasks before pruning"
  count=$(printf '%s\n' "$listing" | sed -n 's/^count: //p')
  ids=$(printf '%s\n' "$listing" | sed -nE 's/^  ([A-Za-z0-9._-]+),.*/\1/p')
  [ "$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l | tr -d ' ')" = "$count" ] \
    || fail "cannot read every $1 task before pruning"
  for id in $ids; do guard_captain_ask "$id"; done
}
