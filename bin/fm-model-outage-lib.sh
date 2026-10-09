#!/usr/bin/env bash
# Model-error observation, called by fm-watch.sh before stale suppression.
# Native OpenCode errors bind to busy-gen and clear on a successful turn.
# Legacy OpenCode lanes use explicit error banners in the visible viewport,
# never scrollback. Idle failures alert immediately; unchanged error observations
# alert at the next poll even if retrying. Unknown/dead endpoints are not
# restarted by this observer. Existing waiting timers own overdue escalation.
# Each normalized error is one durable episode containing all affected lanes.
# The wake queue owns delivery; restart does not repeat an already queued alert.
# No settings/model changes or recovery. The existing blocked/wait escalation
# owns subsequent attention. Each poll scans only this home's recorded lanes.
# The standard 15s poll supports the 5m bound; slower custom schedules may not.

_FM_MODEL_ERROR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_MODEL_ERROR_DIR/fm-timeout-lib.sh"

fm_model_outage_tick() {
  local meta id backend target harness gen error hash old verdict rows file groups native
  local dir="$STATE/.model-outages" now batch uncertain=0
  now=$(date +%s) || return 1
  # The singleton watcher owns these records; never start a second monitor.
  [ ! -L "$dir" ] || return 1
  (umask 077; mkdir -p "$dir") || return 1
  batch=$(mktemp -d "$dir/.scan.XXXXXX") || return 1
  FM_MODEL_OUTAGE_IDLE_IDS=' '
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    fm_busy_token_valid "$id" || continue
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    harness=$(fm_meta_get "$meta" harness)
    gen=$(fm_busy_current_gen "$STATE" "$id") || gen=unarmed
    error=; native=0
    file="$STATE/$id.model-error-$gen.json"
    if [ -f "$file" ] && [ ! -L "$file" ]; then
      if error=$(jq -er --arg gen "$gen" 'select(.gen == $gen) | .error | select(type == "string")' "$file"); then native=1; else error=; fi
    fi
    [ "$harness" = opencode ] || [ "$native" = 1 ] || continue
    # Bound reads on every backend; a vanished/slow endpoint cannot hang the
    # rest of the fleet scan. Never discover another home's unrecorded panes.
    # shellcheck disable=SC2016 # The child expands its own positional arguments.
    rows=$(fm_run_timed 3 bash -c '. "$1/fm-backend.sh"; fm_backend_agent_state "$2" "$3" "$4" "$5"' \
      model-error "$_FM_MODEL_ERROR_DIR" "$backend" "$target" "$meta" "$id") || { uncertain=1; continue; }
    case "$rows" in alive) ;; dead|missing) rm -f "$dir/lane-$id"; continue ;; *) uncertain=1; continue ;; esac
    verdict=$(fm_busy_classify_semantic "$backend" "$target" "$harness" "$id" "$STATE")
    if [ "$native" = 0 ] && [ "$harness" = opencode ] && fm_backend_visible_capture_supported "$backend"; then
      # shellcheck disable=SC2016 # The child expands its own positional arguments.
      rows=$(fm_run_timed 3 bash -c '. "$1/fm-backend.sh"; fm_backend_visible_capture "$2" "$3"' \
        model-error "$_FM_MODEL_ERROR_DIR" "$backend" "$target") || { uncertain=1; continue; }
      # Only explicit error banners, not arbitrary mentions in a transcript.
      error=$(printf '%s\n' "$rows" | grep -Ei '^[[:space:]│┃]*((API|Provider|Model)?[[:space:]]*Error:|Upstream request failed|Model .+ is not supported|rate.?limit exceeded|insufficient quota|authentication failed)' \
        | grep -Ei '(api|provider|model|rate.?limit|quota|authentication|region|401|403|429|upstream)' | tail -1)
    fi
    error=$(printf '%s' "$error" | LC_ALL=C tr -c '[:print:]' ' ' | awk '{$1=$1; print}' | cut -c1-1000)
    if [ -z "$error" ]; then rm -f "$dir/lane-$id"; continue; fi
    hash=$(printf '%s' "$error" | hash_pane)
    if [ "${verdict%% *}" = idle ] && [ -f "$dir/alert-$hash" ]; then FM_MODEL_OUTAGE_IDLE_IDS="$FM_MODEL_OUTAGE_IDLE_IDS$id "; fi
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
  # Forget completed episodes only after the whole scan, not per lane.
  for file in "$dir"/alert-*; do
    [ -f "$file" ] || continue
    hash=${file##*/alert-}
    [ "$uncertain" = 1 ] || [ -f "$batch/$hash.lanes" ] || rm -f "$file"
  done
  groups=
  for file in "$batch"/*.ready; do
    [ -f "$file" ] || continue
    hash=${file##*/}; hash=${hash%.ready}
    [ ! -f "$dir/alert-$hash" ] || continue
    rows=$(paste -sd ',' "$batch/$hash.lanes")
    error=$(cat "$batch/$hash.error")
    verdict="check: model outage affected=[$rows]: $error"
    fm_wake_append check "model-outage-$hash" "$verdict" || { rm -rf "$batch"; return 1; }
    printf '%s\n' "$now" > "$dir/alert-$hash" || return 1
    groups="${groups}${verdict}"$'\n'
  done
  rm -rf "$batch"
  # All groups were queued before the first wake can exit the watcher.
  [ -z "$groups" ] || wake "${groups%$'\n'}"
  return 0
}

# Current-scan idle failures already reported as a grouped outage need no
# generic idle alert. Explicit worker decisions and waiting timers still run.
fm_model_outage_reported_idle() {
  case "${FM_MODEL_OUTAGE_IDLE_IDS:-}" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
