#!/usr/bin/env bash
# Model-error observation, called by fm-watch.sh before stale suppression.
# OpenCode lanes use explicit provider banners in the visible viewport,
# never scrollback or worker-printed "Error:" lines. Unchanged error observations
# alert at the next scan even if retrying. Unknown/dead endpoints are not
# restarted by this observer. Existing waiting timers own overdue escalation.
# Scans run at most once per 60s, so an idle failure alerts at the first scan
# after it appears, up to 60s later. Each scan reads every recorded lane's
# liveness serially, bounded to 3s each, before the stale checks in the same
# poll, so a slow endpoint can delay them. Mid-turn OpenCode lanes skip the
# visible-capture read, so their errors are named once the lane is idle.
# Each normalized error is one durable episode; a lane joining an alerted episode
# sends one updated grouped wake naming the lanes failing in that scan.
# The wake queue owns delivery; restart does not repeat an already queued alert.
# No settings/model changes or recovery. The existing blocked/wait escalation
# owns subsequent attention. Each scan reads only this home's recorded lanes.

_FM_MODEL_ERROR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_MODEL_ERROR_DIR/fm-timeout-lib.sh"

fm_model_outage_text() {
  LC_ALL=C tr -c '[:print:]' ' ' | awk '{$1=$1; print}' | cut -c1-1000
}

fm_model_outage_tick() {
  local meta id backend target harness gen error hash old verdict rows groups mid line match key lanes alert kept
  local dir="$STATE/.model-outages" now batch last current
  now=$(date +%s) || return 1
  # The singleton watcher owns these records; never start a second monitor.
  [ ! -L "$dir" ] || return 1
  (umask 077; mkdir -p "$dir") || return 1
  last=$(cat "$dir/.scan-at" 2>/dev/null) || last=0
  [ $((now - last)) -ge 60 ] || [ $((now - last)) -lt 0 ] || return 0
  printf '%s\n' "$now" > "$dir/.scan-at" || return 1
  batch=$(mktemp -d "$dir/.scan.XXXXXX") || return 1
  trap 'rm -rf "$batch"; trap - RETURN' RETURN
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    fm_busy_token_valid "$id" || continue
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    harness=$(fm_meta_get "$meta" harness)
    gen=$(fm_busy_current_gen "$STATE" "$id") || gen=unarmed
    error=; key=
    [ "$harness" = opencode ] || continue
    # shellcheck disable=SC2016 # The child expands its own positional arguments.
    verdict=$(fm_run_timed 3 bash -c '. "$1/fm-backend.sh"; . "$1/fm-busy-lib.sh"; fm_busy_classify_semantic "$2" "$3" "$4" "$5" "$6"' \
      model-error "$_FM_MODEL_ERROR_DIR" "$backend" "$target" "$harness" "$id" "$STATE") \
      || continue
    mid=0
    if [ "${verdict%% *}" = busy ]; then mid=1; fi
    # Bound reads on every backend; a vanished/slow endpoint cannot hang the
    # rest of the fleet scan. Never discover another home's unrecorded panes.
    # shellcheck disable=SC2016 # The child expands its own positional arguments.
    rows=$(fm_run_timed 3 bash -c '. "$1/fm-backend.sh"; fm_backend_agent_state "$2" "$3" "$4" "$5"' \
      model-error "$_FM_MODEL_ERROR_DIR" "$backend" "$target" "$meta" "$id") || continue
    case "$rows" in alive) ;; dead|missing) rm -f "$dir/lane-$id"; continue ;; *) continue ;; esac
    if [ "$mid" = 0 ] && fm_backend_visible_capture_supported "$backend"; then
      # shellcheck disable=SC2016 # The child expands its own positional arguments.
      rows=$(fm_run_timed 3 bash -c '. "$1/fm-backend.sh"; fm_backend_visible_capture "$2" "$3"' \
        model-error "$_FM_MODEL_ERROR_DIR" "$backend" "$target") || continue
      # Only explicit provider/harness banners, never worker-printed output; a
      # wrapped banner keeps up to two continuation lines.
      match=$(printf '%s\n' "$rows" | grep -Ein '^[[:space:]│┃]*(Upstream request failed|Model .+ is not supported|rate.?limit exceeded|insufficient quota|authentication failed)' | tail -1)
      if [ -n "$match" ]; then
        line=${match%%:*}
        key=$(printf '%s\n' "$rows" | sed -n "${line}p")
        error=$(printf '%s\n' "$rows" | sed -n "${line},$((line + 2))p")
      fi
    fi
    error=$(printf '%s' "$error" | fm_model_outage_text)
    if [ -z "$error" ]; then rm -f "$dir/lane-$id"; continue; fi
    key=$(printf '%s' "${key:-$error}" | fm_model_outage_text)
    hash=$(printf '%s' "$key" | hash_pane)
    old=$(cat "$dir/lane-$id" 2>/dev/null) || old=
    printf '%s\n' "$target|$gen|$hash" > "$dir/lane-$id" || return 1
    printf '%s\n' "$id" >> "$batch/$hash.lanes"
    printf '%s\n' "$error" > "$batch/$hash.error"
    if [ "${verdict%% *}" = idle ] || [ "$old" = "$target|$gen|$hash" ]; then touch "$batch/$hash.ready"; fi
  done
  for file in "$dir"/lane-*; do
    [ -f "$file" ] || continue
    id=${file##*/lane-}
    [ -f "$STATE/$id.meta" ] || rm -f "$file"
  done
  # Forget episodes only after the whole scan, and only when no lane read failing.
  for file in "$dir"/alert-*; do
    [ -f "$file" ] || continue
    hash=${file##*/alert-}
    [ -f "$batch/$hash.lanes" ] || rm -f "$file"
  done
  groups=
  for lanes in "$batch"/*.lanes; do
    [ -f "$lanes" ] || continue
    hash=${lanes##*/}; hash=${hash%.lanes}
    alert="$dir/alert-$hash"
    [ -f "$alert" ] || : > "$alert" || return 1
    # The alert record holds the lanes named and still failing. A recovered lane
    # leaves it, so its later failure with the same error names it again.
    if [ -f "$batch/$hash.ready" ] && grep -qvxFf "$alert" "$lanes"; then
      current=$(sort -u "$lanes")
      rows=$(printf '%s\n' "$current" | paste -sd ',' -)
      error=$(cat "$batch/$hash.error")
      verdict="check: model outage affected=[$rows]: $error"
      fm_wake_append check "model-outage-$hash" "$verdict" || return 1
      groups="${groups}${verdict}"$'\n'
      kept=$current
    else
      kept=$(grep -Fxf "$alert" "$lanes" | sort -u)
    fi
    if [ -n "$kept" ]; then printf '%s\n' "$kept" > "$alert" || return 1; else : > "$alert" || return 1; fi
  done
  rm -rf "$batch"
  # All groups were queued before the first wake can exit the watcher.
  [ -z "$groups" ] || wake "${groups%$'\n'}"
  return 0
}
