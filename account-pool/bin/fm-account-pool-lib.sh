#!/usr/bin/env bash
# fm-account-pool-lib.sh - account-pool add-on, launch side: config/account-pool parsing, the
# `byokit-accounts pick` call, the launch prefix its answer applies, and fm_account_hook,
# the one entry point bin/fm-spawn.sh calls. Sourced from $FM_ADDONS_DIR/account-pool/bin/;
# a home without the add-on never defines any of this and its hook lines are no-ops.
# A pick answers with folder paths only, so no secret reaches a launch line, record or log.

# shellcheck source=/dev/null
type fm_run_timed >/dev/null 2>&1 || . "${SCRIPT_DIR:?sourced from a bin/ script}/fm-timeout-lib.sh"

FM_ACCOUNT_POOL_PICK_SECONDS=${FM_ACCOUNT_POOL_PICK_SECONDS:-120}

# fm_account_pool_tool <harness>: the pool tool, or non-zero for an unmapped one.
fm_account_pool_tool() {
  case "$1" in
  claude) printf '%s\n' claude ;;
  codex) printf '%s\n' codex ;;
  pi | pi-signed) printf '%s\n' pi ;;
  *) return 1 ;;
  esac
}

# fm_account_pool_store_var <tool>: the environment variable a launch assigns
# the picked account folder to, or non-zero for an unmapped tool.
fm_account_pool_store_var() {
  case "$1" in
  claude) printf '%s\n' CLAUDE_CONFIG_DIR ;;
  codex) printf '%s\n' CODEX_HOME ;;
  pi) printf '%s\n' PI_CODING_AGENT_DIR ;;
  *) return 1 ;;
  esac
}

# fm_account_pool_config <config-dir>: "command<TAB>state" for a usable
# config/account-pool; nothing when the file is absent; one error otherwise.
fm_account_pool_config() {
  local config=$1 file command state line
  file=$config/account-pool
  command=byokit-accounts
  state=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/account-pool must be a readable regular file naming the pool folder: $file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in
    command=*) command=${line#command=} ;;
    state=*) state=${line#state=} ;;
    esac
  done <"$file"
  case "$state" in
  /*) ;;
  *)
    echo "error: config/account-pool must name the pool folder with one absolute state=<pool folder> line (blank lines and # comments are ignored): $file" >&2
    return 1
    ;;
  esac
  case "$command" in
  /*) ;;
  */*)
    echo "error: config/account-pool's command= must be an absolute path to byokit-accounts: $file" >&2
    return 1
    ;;
  esac
  printf '%s\t%s\n' "$command" "$state"
}

# fm_account_pool_detail <pick-json>: one fragment naming each account row and
# why it cannot take a worker. Reads names and states only.
fm_account_pool_detail() {
  jq -r '[ .rows[]? | select(type == "object") | "\(.name // .id // "an account") " +
    (if .state == "resting" then "resting" elif .state == "signed_out" then "signed out"
     elif .state == "signing" then "still signing in" elif .state == "not_included" then "not set up"
     else "not ready" end) ] | join(", ")' <<<"${1:-}" 2>/dev/null
}

# fm_account_pool_select <harness> <config-dir> [<want>]: "id<TAB>var<TAB>folder<TAB>unset names"
# for a mapped harness with a usable pool; nothing when the pool is off; an error and non-zero on
# any refusal, never an ambient login fallback. <want> is a relaunch's --account choice: an id adds
# --prefer and the answer must be exactly that account; `next` picks plainly.
fm_account_pool_select() {
  local harness=$1 config=$2 want=${3:-} tool store_var cfg command state out errf rc id var folder shed reason detail shed_bad=0
  local -a prefer_arg=()
  tool=$(fm_account_pool_tool "$harness") || return 0
  cfg=$(fm_account_pool_config "$config") || return 1
  [ -n "$cfg" ] || return 0
  store_var=$(fm_account_pool_store_var "$tool") || return 1
  command=${cfg%%$'\t'*}
  state=${cfg#*$'\t'}
  errf=$(mktemp "${TMPDIR:-/tmp}/fm-account-pool.XXXXXX") || {
    echo "error: config/account-pool cannot create a temporary file to run '$command'" >&2
    return 1
  }
  case "$want" in
    '' | next) ;;
    *) prefer_arg=(--prefer "$want") ;;
  esac
  out=$(fm_run_timed "$FM_ACCOUNT_POOL_PICK_SECONDS" "$command" pick "$tool" --json "${prefer_arg[@]}" --state "$state" 2>"$errf")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # A failed pick answers with the contract JSON on stdout and one sentence on stderr.
    reason=
    if printf '%s' "$out" | jq -e '.ok == false' >/dev/null 2>&1; then
      reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
      detail=$(fm_account_pool_detail "$out")
    fi
    [ -n "$reason" ] || reason=$(sed -n '1{s/^error: //;p;}' "$errf" 2>/dev/null)
    [ -n "$reason" ] || reason='the pool command could not run'
    rm -f "$errf"
    echo "error: config/account-pool cannot start a $tool worker: $reason${detail:+ ($detail)}; add or sign in to an account with '$command add $tool', then retry" >&2
    return 1
  fi
  rm -f "$errf"
  id=$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null)
  var=$(printf '%s' "$out" | jq -r 'if (.set | type) == "object" and (.set | length) == 1 then (.set | keys[0]) else empty end' 2>/dev/null)
  folder=$(printf '%s' "$out" | jq -r --arg v "$var" 'if $v == "" then empty else (.set[$v] // empty) end' 2>/dev/null)
  if ! shed=$(printf '%s' "$out" | jq -r '
      .unset // []
      | if type == "array" and all(.[]; type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*\\z"))
        then .[] else error("the unset list is not an array of variable names") end' 2>/dev/null); then
    shed=
    shed_bad=1
  fi
  shed=$(printf '%s' "$shed" | tr '\n' ' ')
  shed=${shed% }
  case "$id" in '' | *[!A-Za-z0-9._-]*) id= ;; esac
  case "$var" in "$store_var") ;; *) var= ;; esac
  case "$folder" in /*) ;; *) folder= ;; esac
  if [ -n "$folder" ] && { [ ! -d "$folder" ] || [ ! -r "$folder" ] || [ ! -x "$folder" ]; }; then
    folder=
  fi
  if [ -z "$id" ] || [ -z "$var" ] || [ -z "$folder" ] || [ "$shed_bad" = 1 ]; then
    echo "error: config/account-pool's '$command' answered with an unusable $tool account selection; expected an account id and one absolute account folder, with no secret" >&2
    return 1
  fi
  case "$want" in
    '' | next) ;;
    *)
      if [ "$id" != "$want" ]; then
        echo "error: config/account-pool's '$command' answered with account '${id:-none}' rather than the requested account '$want' for a $tool worker; the pool only prefers an account that is ready, so '$want' may be resting, signed out, or another tool's account" >&2
        return 1
      fi
      ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$id" "$var" "$folder" "$shed"
}


# fm_account_pool_tuple_field <tuple> <index>: field <index> (1-based) of a tab-separated tuple.
fm_account_pool_tuple_field() { cut -f"$2" <<<"$1"; }

# --- fm_account_hook: the entry point of bin/fm-spawn.sh's hook lines -------
# fm_account_hook <event> [args]: an unknown event is a no-op, so a hook line
# from a newer fork never fails against an older add-on checkout.

# raw-launch <config-dir>: a raw launch command cannot carry the picked account.
fm_account_hook_raw_launch() {
  [ -e "$1/account-pool" ] || [ -L "$1/account-pool" ] || return 0
  echo "error: config/account-pool does not support raw launch commands; use a named harness such as --harness claude, --harness codex, or --harness pi so the selected account cannot be overridden" >&2
  return 1
}

# spawn-pick <harness> <config-dir> <pin-tuple>: sets POOL_ACCOUNT (the pick's
# tuple) and POOL_ACCOUNT_ID/VAR/FOLDER/UNSET, and exports a picked Claude root
# so trust registration writes the store the worker will read. A pin wins.
fm_account_hook_spawn_pick() {
  local harness=$1 config=$2 pin=${3:-}
  POOL_ACCOUNT='' POOL_ACCOUNT_ID='' POOL_ACCOUNT_VAR='' POOL_ACCOUNT_FOLDER='' POOL_ACCOUNT_UNSET=''
  [ -z "$pin" ] || return 0
  POOL_ACCOUNT=$(fm_account_pool_select "$harness" "$config") || return 1
  [ -n "$POOL_ACCOUNT" ] || return 0
  POOL_ACCOUNT_ID=$(fm_account_pool_tuple_field "$POOL_ACCOUNT" 1)
  POOL_ACCOUNT_VAR=$(fm_account_pool_tuple_field "$POOL_ACCOUNT" 2)
  POOL_ACCOUNT_FOLDER=$(fm_account_pool_tuple_field "$POOL_ACCOUNT" 3)
  POOL_ACCOUNT_UNSET=$(fm_account_pool_tuple_field "$POOL_ACCOUNT" 4)
  [ "$POOL_ACCOUNT_VAR" != CLAUDE_CONFIG_DIR ] || export CLAUDE_CONFIG_DIR=$POOL_ACCOUNT_FOLDER
}

# record-line: the task record's account= line, only for a pick.
fm_account_hook_record_line() {
  [ -z "${POOL_ACCOUNT:-}" ] || echo "account=$POOL_ACCOUNT_ID"
}

# spawn-line: appends account=<id> to SPAWN_ACCOUNT (the spawned line), only for a pick.
fm_account_hook_spawn_line() {
  [ -z "${POOL_ACCOUNT:-}" ] || SPAWN_ACCOUNT="${SPAWN_ACCOUNT:-} account=$POOL_ACCOUNT_ID"
}

# launch-prefix <harness> <pin-tuple>: runs after Kun's launch-prefix chain. A
# pick (no pin) replaces the ambient CLAUDE_CONFIG_DIR forward that chain adds
# with `env -u <name> ... <VAR>=<folder>`; the picked folder is the only secret-free input.
fm_account_hook_launch_prefix() {
  local name prefix=env own
  [ -n "${POOL_ACCOUNT:-}" ] && [ -z "${2:-}" ] || return 0
  if [ "$1" = claude ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    own="CLAUDE_CONFIG_DIR=$(shell_quote "$CLAUDE_CONFIG_DIR") "
    LAUNCH=${LAUNCH#"$own"}
  fi
  for name in $POOL_ACCOUNT_UNSET; do prefix="$prefix -u $name"; done
  LAUNCH="$prefix $POOL_ACCOUNT_VAR=$(shell_quote "$POOL_ACCOUNT_FOLDER") $LAUNCH"
}

fm_account_hook() {
  local event=${1:-}
  shift || true
  case "$event" in
    raw-launch | spawn-pick | record-line | spawn-line | launch-prefix)
      "fm_account_hook_${event//-/_}" "$@" ;;
    *) return 0 ;;
  esac
}
