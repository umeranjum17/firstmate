#!/usr/bin/env bash
# Real restored-shell E2E for home-local session-start Herdr projection cleanup.
# Every CLI operation is routed through one guarded named non-default lab, and
# lab teardown verifies that the default fleet session is byte-identical.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-session-cleanup-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config"
export FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/lab-state"
CALLER_HOME=$HOME
touch "$HOME_DIR/config/herdr-presentation-spaces"
printf '%s\n' herdr > "$HOME_DIR/config/backend"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-session-start-stale-projection-cleanup-r1)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  if [ -n "${LAB_BASE:-}" ]; then
    [ ! -e "$LAB_BASE" ] || { printf 'not ok - disposable HOME survived teardown\n' >&2; status=1; }
  fi
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
reject_lab() {
  if "$HERDR_LAB_HELPER" "$@" > "$TMP_ROOT/refusal.txt" 2>&1; then
    fail "unsafe lab operation succeeded: $*"
  fi
}
mkdir -m 755 "$FM_HERDR_LAB_STATE_DIR"
reject_lab provision "$HERDR_LAB_SESSION"
chmod 700 "$FM_HERDR_LAB_STATE_DIR"
mv "$FM_HERDR_LAB_STATE_DIR" "$TMP_ROOT/private-state"
ln -s "$TMP_ROOT/private-state" "$FM_HERDR_LAB_STATE_DIR"
reject_lab provision "$HERDR_LAB_SESSION"
rm "$FM_HERDR_LAB_STATE_DIR"
mv "$TMP_ROOT/private-state" "$FM_HERDR_LAB_STATE_DIR"
mkdir "$FM_HERDR_LAB_STATE_DIR/$HERDR_LAB_SESSION.xdg"
for action in prepare provision 'run status --json' 'viewer start' 'viewer stop' stop teardown; do
  case "$action" in
    'run status --json') reject_lab run "$HERDR_LAB_SESSION" status --json ;;
    'viewer start') reject_lab viewer start "$HERDR_LAB_SESSION" ;;
    'viewer stop') reject_lab viewer stop "$HERDR_LAB_SESSION" ;;
    *) reject_lab "$action" "$HERDR_LAB_SESSION" ;;
  esac
done
rmdir "$FM_HERDR_LAB_STATE_DIR/$HERDR_LAB_SESSION.xdg"
export CLAUDE_CONFIG_DIR="$HOME_DIR/owner-claude" PI_CODING_AGENT_DIR="$HOME_DIR/owner-pi"
export CODEX_HOME="$HOME_DIR/owner-codex" OPENAI_API_KEY=lab-synthetic-openai
export ANTHROPIC_API_KEY=lab-synthetic-key ANTHROPIC_AUTH_TOKEN=lab-synthetic-token
export CLAUDE_CODE_OAUTH_TOKEN=lab-synthetic-oauth CLAUDE_CODE_USE_BEDROCK=1
export FM_HERDR_LAB_FLEET_HOME="$CALLER_HOME" FM_HERDR_LAB_FLEET_QUERY=1
(
  . "$ROOT/tests/herdr-test-safety.sh"
  PREPARED_SESSION=$(fm_herdr_lab_name prepare-proof)
  trap 'herdr_safe_stop_and_delete "$PREPARED_SESSION" || exit 1' EXIT
  herdr_prepare_runtime "$PREPARED_SESSION" || exit 1
  prepared_base=$(fm_herdr_lab_xdg_base "$PREPARED_SESSION") || exit 1
  [ "$HOME" = "$prepared_base/home" ] && [ "$HOME" != "$CALLER_HOME" ] || exit 1
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source herdr || exit 1
  fm_backend_herdr_server_ensure "$PREPARED_SESSION" || exit 1
  fm_herdr_lab_stop "$PREPARED_SESSION" >/dev/null || exit 1
  fm_backend_herdr_server_ensure "$PREPARED_SESSION" || exit 1
  prepared=$(fm_backend_herdr_cli "$PREPARED_SESSION" workspace create --cwd "$ROOT" --label prepared-proof --no-focus) || exit 1
  prepared_pane=$(printf '%s' "$prepared" | jq -er '.result.root_pane.pane_id') || exit 1
  fm_backend_herdr_cli "$PREPARED_SESSION" pane run "$prepared_pane" \
    "printf '%s\\n' \"\$HOME\" \"\$CODEX_HOME\" \"\${OPENAI_API_KEY-unset}\" \"\${ANTHROPIC_API_KEY-unset}\" > '$TMP_ROOT/prepared-home.txt'" >/dev/null || exit 1
  attempt=0
  while [ ! -s "$TMP_ROOT/prepared-home.txt" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  printf '%s\n' "$prepared_base/home" "$prepared_base/home/.codex" unset unset > "$TMP_ROOT/expected-prepared-home.txt"
  cmp -s "$TMP_ROOT/prepared-home.txt" "$TMP_ROOT/expected-prepared-home.txt" || exit 1
) || fail 'prepare-based adapter startup or restart escaped the disposable environment'
[ "$HOME" = "$CALLER_HOME" ] || fail 'prepared journey changed caller context'
pass 'real prepare-based adapter startup and restart use disposable HOME and shed authentication'
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision isolated lab'
LAB_BASE=$(<"$FM_HERDR_LAB_STATE_DIR/$HERDR_LAB_SESSION.xdg-root")
printf '%s\n' "$HOME_DIR" > "$FM_HERDR_LAB_STATE_DIR/$HERDR_LAB_SESSION.xdg-root"
for action in prepare provision run stop teardown; do
  if [ "$action" = run ]; then
    reject_lab run "$HERDR_LAB_SESSION" status --json
  else
    reject_lab "$action" "$HERDR_LAB_SESSION"
  fi
done
reject_lab viewer start "$HERDR_LAB_SESSION"
reject_lab viewer stop "$HERDR_LAB_SESSION"
[ -f "$HOME_DIR/config/backend" ] || fail 'invalid pointer deleted unrelated home'
printf '%s\n' "$LAB_BASE" > "$FM_HERDR_LAB_STATE_DIR/$HERDR_LAB_SESSION.xdg-root"
mv "$LAB_BASE/config" "$LAB_BASE/saved-config"
ln -s "$HOME_DIR" "$LAB_BASE/config"
reject_lab run "$HERDR_LAB_SESSION" status --json
rm "$LAB_BASE/config"
mv "$LAB_BASE/saved-config" "$LAB_BASE/config"
pass 'real helper rejects public state, state symlinks, legacy roots and redirected disposable roots'

# Keep the lab helper as the only CLI transport. Production adapter calls have
# already appended the exact session; this shim strips that pair, refuses every
# other caller-supplied session, and delegates the command to helper run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
production_process_proof() {
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1 PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$1"; fm_backend_herdr_pane_idle_shell_pid "$2" "$3" >/dev/null' \
      _ "$ROOT/bin/fm-herdr-session-cleanup.sh" "$HERDR_LAB_SESSION" "$PANE"
}
focus_snapshot() {
  local list workspace tab tabs
  list=$(lab workspace list) || return 1
  workspace=$(printf '%s' "$list" | jq -er '[.result.workspaces[] | select(.focused == true)] | select(length == 1) | .[0].workspace_id') || return 1
  tab=$(printf '%s' "$list" | jq -er --arg workspace "$workspace" '[.result.workspaces[] | select(.workspace_id == $workspace)] | select(length == 1) | .[0].active_tab_id') || return 1
  tabs=$(lab tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '([.result.tabs[] | select(.focused == true)] | length) == 1 and ([.result.tabs[] | select(.focused == true)][0].tab_id == $tab)' >/dev/null || return 1
  printf '%s\t%s' "$workspace" "$tab"
}

ANCHOR=$(lab workspace create --cwd "$ROOT" --label captain-anchor --focus) || fail 'could not create focus anchor'
ANCHOR_TAB=$(printf '%s' "$ANCHOR" | jq -r '.result.tab.tab_id')
ANCHOR_PANE=$(printf '%s' "$ANCHOR" | jq -r '.result.root_pane.pane_id')
HOME_PROOF="$TMP_ROOT/pane-home.txt"
lab pane run "$ANCHOR_PANE" "printf '%s\\n' \"\$HOME\" \"\$XDG_CONFIG_HOME\" \"\$XDG_DATA_HOME\" \"\$XDG_STATE_HOME\" \"\$XDG_CACHE_HOME\" \"\$CLAUDE_CONFIG_DIR\" \"\$PI_CODING_AGENT_DIR\" \"\$CODEX_HOME\" \"\${OPENAI_API_KEY-unset}\" \"\${ANTHROPIC_API_KEY-unset}\" \"\${ANTHROPIC_AUTH_TOKEN-unset}\" \"\${CLAUDE_CODE_OAUTH_TOKEN-unset}\" \"\${CLAUDE_CODE_USE_BEDROCK-unset}\" > '$HOME_PROOF'" >/dev/null \
  || fail 'could not request lab pane HOME evidence'
attempt=0
while [ ! -s "$HOME_PROOF" ] && [ "$attempt" -lt 100 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -s "$HOME_PROOF" ] || fail 'lab pane did not write HOME evidence'
LAB_BASE=$(<"$FM_HERDR_LAB_STATE_DIR/$HERDR_LAB_SESSION.xdg-root")
SOCKET_PATH=$(lab session list --json | jq -r --arg name "$HERDR_LAB_SESSION" '.sessions[] | select(.name == $name) | .socket_path')
printf 'evidence: socket_path=%s bytes=%s\n' "$SOCKET_PATH" "${#SOCKET_PATH}"
[ "${#SOCKET_PATH}" -lt 100 ] || fail 'lab socket path is not safely below Unix socket capacity'
[ "$(head -n 1 "$HOME_PROOF")" = "$LAB_BASE/home" ] || fail 'lab pane HOME is not its disposable home'
[ "$(head -n 1 "$HOME_PROOF")" != "$CALLER_HOME" ] || fail 'lab pane inherited caller HOME'
printf '%s\n' "$LAB_BASE/home" "$LAB_BASE/config" "$LAB_BASE/data" "$LAB_BASE/state" "$LAB_BASE/cache" \
  "$LAB_BASE/home/.claude" "$LAB_BASE/home/.pi/agent" "$LAB_BASE/home/.codex" unset unset unset unset unset > "$TMP_ROOT/expected-home.txt"
cmp -s "$HOME_PROOF" "$TMP_ROOT/expected-home.txt" || fail 'lab pane HOME and XDG paths are inconsistent'
HOME_MARKER="fm-lab-home-proof-$HERDR_LAB_SESSION"
[ ! -e "$CALLER_HOME/.local/bin/$HOME_MARKER" ] || fail 'caller marker already exists'
lab pane run "$ANCHOR_PANE" "mkdir -p \"\$HOME/.local/bin\" && printf scratch > \"\$HOME/.local/bin/$HOME_MARKER\"" >/dev/null \
  || fail 'could not request scratch HOME write'
attempt=0
while [ ! -s "$LAB_BASE/home/.local/bin/$HOME_MARKER" ] && [ "$attempt" -lt 100 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
[ "$(<"$LAB_BASE/home/.local/bin/$HOME_MARKER")" = scratch ] || fail 'scratch HOME write did not finish'
[ ! -e "$CALLER_HOME/.local/bin/$HOME_MARKER" ] || fail 'lab HOME write touched caller HOME'
for credentials in .claude .codex .pi .config; do
  [ ! -e "$LAB_BASE/home/$credentials" ] || fail 'lab HOME contains inherited configuration or credentials'
done
pass 'real lab pane has disposable HOME, XDG and credential roots without inherited authentication'
"$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION" || fail 'isolated viewer start failed'
"$HERDR_LAB_HELPER" viewer stop "$HERDR_LAB_SESSION" || fail 'isolated viewer stop failed'
TOKEN=AbCdEfGhIjKlMnOpQrStUv
ID=restored-idle-shell
TITLE="└ $ID · p:$TOKEN"
CANDIDATE=$(lab workspace create --cwd "$ROOT" --label "$TITLE" --no-focus) || fail 'could not create projected child fixture'
WS=$(printf '%s' "$CANDIDATE" | jq -r '.result.workspace.workspace_id')
PANE=$(printf '%s' "$CANDIDATE" | jq -r '.result.root_pane.pane_id')
{
  printf 'version=1\n'
  printf 'task_id=%s\n' "$ID"
  printf 'projection_id=%s\n' "$TOKEN"
} > "$HOME_DIR/state/$ID.herdr-presentation"

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'could not stop named lab for restored-shell reproduction'
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not restore named lab layout'
lab tab focus "$ANCHOR_TAB" >/dev/null || fail 'could not restore the anchor focus after lab restart'
BEFORE_FOCUS=$(focus_snapshot) || fail 'could not capture exact pre-cleanup focus'
[ "$BEFORE_FOCUS" = "$(printf '%s\t%s' "$(printf '%s' "$ANCHOR" | jq -r '.result.workspace.workspace_id')" "$ANCHOR_TAB")" ] \
  || fail 'anchor focus does not match the exact intended workspace and tab'

WORKSPACES=$(lab workspace list) || fail 'could not inspect restored workspaces'
TABS=$(lab tab list --workspace "$WS") || fail 'could not inspect restored tabs'
PANES=$(lab pane list --workspace "$WS") || fail 'could not inspect restored panes'
[ "$(printf '%s' "$WORKSPACES" | jq --arg title "$TITLE" '[.result.workspaces[] | select(.label == $title)] | length')" = 1 ] \
  || fail 'restored projected title is not unique'
[ "$(printf '%s' "$TABS" | jq '.result.tabs | length')" = 1 ] || fail 'restored child is not one tab'
[ "$(printf '%s' "$PANES" | jq '.result.panes | length')" = 1 ] || fail 'restored child is not one pane'
if lab agent get "$PANE" >/dev/null 2>&1; then
  fail 'restored child unexpectedly retained a registered agent'
fi
attempt=0
while [ "$attempt" -lt 50 ]; do
  if production_process_proof; then
    break
  fi
  sleep 0.1
  attempt=$((attempt + 1))
done
[ "$attempt" -lt 50 ] || fail 'restored child did not converge to the exact childless idle-shell process-group shape'
pass 'real named lab reproduced the exact restored one-tab one-pane childless no-agent shell shape'

FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh" \
  || fail 'session-start cleanup command failed'
AFTER_FOCUS=$(focus_snapshot) || fail 'could not capture exact post-cleanup focus'
[ "$AFTER_FOCUS" = "$BEFORE_FOCUS" ] || fail 'exact workspace/tab focus changed during cleanup'
if lab pane get "$PANE" >/dev/null 2>&1; then
  fail 'exact stale pane survived cleanup'
fi
if lab workspace get "$WS" >/dev/null 2>&1; then
  fail 'last-pane side effect did not remove the stale projected child workspace'
fi
[ ! -e "$HOME_DIR/state/$ID.herdr-presentation" ] || fail 'matching journal survived confirmed exact pane closure'
pass 'real named lab cleanup closes only the exact stale pane and preserves exact focus'

FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh" \
  || fail 'idempotent repeat failed'
[ "$(focus_snapshot)" = "$BEFORE_FOCUS" ] || fail 'idempotent repeat changed focus'
lab pane get "$(printf '%s' "$ANCHOR" | jq -r '.result.root_pane.pane_id')" >/dev/null \
  || fail 'anchor pane was touched by cleanup'
STATUS=$(lab status --json) || fail 'could not read final named-lab version evidence'
pass 'real named lab cleanup is idempotent and leaves the default fleet session to the teardown tripwire'
printf 'evidence: herdr=%s protocol=%s default-session-tripwire=armed\n' \
  "$(printf '%s' "$STATUS" | jq -r '.client.version')" \
  "$(printf '%s' "$STATUS" | jq -r '.server.protocol')"
