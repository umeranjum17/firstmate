#!/usr/bin/env bash
# Behavior tests for the per-adapter semantic busy-state wiring that
# bin/fm-spawn.sh installs under the contract owned by bin/fm-busy-lib.sh.
#
# These tests run the REAL fm-spawn against a fake tmux pane and an isolated
# git worktree, then drive the generated adapter artifact (the Pi extension,
# the OpenCode plugin) in a plain Node host, so the artifact, the real
# bin/fm-busy-event.sh writer, and the real classifier are exercised together
# with no live harness session.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-adapter-wiring)

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi opencode claude codex gemini)
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  # Every case here is a ship spawn, which carries an explicit delivery contract
  # (AGENTS.md section 7); these tests are about busy-state wiring, so they pass a
  # fixed valid one.
  local home=$1 wt=$2 fakebin=$3
  shift 3
  GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

classify() {  # <harness> <id> <state-dir>
  fm_busy_classify tmux fake:w "$1" "$2" "$3"
}

# drive_pi_ext <ext-path> <mode>: load the generated Pi extension in a plain
# Node host and fire one lifecycle handler. Modes: agent-start, settle-idle,
# settle-continuing, turn-end.
drive_pi_ext() {
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; }, events: { on: (name, fn) => { handlers[name] = fn; } } });
const ctx = { isIdle: () => process.env.MODE !== "settle-continuing" };
// Pi 1.0.0's invalidated runner: every ctx read throws after the session is disposed.
const staleCtx = { isIdle: () => { throw new Error("This extension ctx is stale after session replacement or reload"); } };
switch (process.env.MODE) {
  case "agent-start": await handlers["agent_start"]({}, ctx); break;
  case "settle-idle": await handlers["agent_settled"]({}, ctx); break;
  case "settle-continuing": await handlers["agent_settled"]({}, ctx); break;
  case "settle-stale": await handlers["agent_settled"]({}, staleCtx); break;
  case "settle-then-start":
    await handlers["agent_settled"]({}, ctx);
    await handlers["agent_start"]({}, ctx);
    break;
  case "turn-end": await handlers["turn_end"]({}, ctx); break;
  case "progress": await handlers["codex-native:progress"]({ type: "commandExecution", phase: "completed" }); break;
  case "text_delta": case "thinking_delta": case "toolcall_delta": case "empty-delta": case "message-start":
    await handlers["message_update"]({ assistantMessageEvent: {
      type: process.env.MODE === "empty-delta" ? "text_delta" : process.env.MODE,
      delta: process.env.MODE === "empty-delta" ? "" : "new streamed bytes",
    }});
    break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (["turn-end", "progress"].includes(process.env.MODE)) {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_pi_extension_semantic_lifecycle() {
  local rec id=busy-pi-1 out state ext mode
  rec=$(make_spawn_case pi-lifecycle pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"

  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_pi_ext "$ext" progress) || fail "native progress drive failed: $out"
  [ -f "$state/$id.progress" ] || fail "native progress did not write its separate marker"
  [ ! -e "$state/$id.turn-ended" ] || fail "native progress fabricated a completed turn"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "native progress changed semantic state: $out"
  for mode in text_delta thinking_delta toolcall_delta empty-delta message-start; do
    rm -f "$state/$id.progress"
    out=$(drive_pi_ext "$ext" "$mode") || fail "$mode drive failed: $out"
    case "$mode" in
      empty-delta|message-start) [ ! -e "$state/$id.progress" ] || fail "$mode fabricated progress" ;;
      *) [ -f "$state/$id.progress" ] || fail "$mode did not record streaming progress" ;;
    esac
    [ ! -e "$state/$id.turn-ended" ] || fail "$mode fabricated a completed turn"
    out=$(classify pi "$id" "$state")
    [ "$out" = "busy fm-spawn" ] || fail "$mode changed semantic busy state: $out"
  done
  out=$(drive_pi_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "agent_settled drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "agent_settled with isIdle must classify 'idle pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "agent_start must classify 'busy pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" settle-continuing) || fail "continuing settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a settle while another run continues must stay busy, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "final settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "the final settle must classify idle, got '$out'"
  pass "pi extension reports agent_start busy, settles idle only via ctx.isIdle(), and keeps turn_end a notification"
}

# 2026-10-05: Pi quitting on a signal mid-run settles through a disposed
# session whose ctx throws. The handler must not throw into Pi's shutdown, and
# the record must leave busy without claiming idle.
test_pi_extension_stale_ctx_settles_unknown() {
  local rec id=busy-pi-stale-ctx out state ext
  rec=$(make_spawn_case pi-stale-ctx pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  out=$(drive_pi_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  out=$(drive_pi_ext "$ext" settle-stale) || fail "a stale-ctx settle threw: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "unknown pi-ext" ] || fail "a stale-ctx settle must classify 'unknown pi-ext', got '$out'"
  pass "pi extension settles a disposed session to unknown without throwing"
}

test_pi_extension_serializes_settle_before_next_start() {
  local rec id=busy-pi-order out state ext
  rec=$(make_spawn_case pi-order pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"

  out=$(drive_pi_ext "$ext" settle-then-start) || fail "settle/start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a fresh agent_start after agent_settled must win, got '$out'"
  pass "pi extension awaits agent_settled before the next agent_start without a test delay"
}

test_pi_extension_stale_incarnation_rejected() {
  local rec id=busy-pi-2 out state ext
  rec=$(make_spawn_case pi-stale pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  # A re-arm (a rewired incarnation) supersedes the gen embedded in the old
  # extension file: its late events must be rejected and never change state.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  out=$(drive_pi_ext "$ext" settle-idle) || fail "stale settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale extension event must not change state, got '$out'"
  out=$(drive_pi_ext "$ext" progress) || fail "stale progress drive failed: $out"
  [ ! -e "$state/$id.progress" ] || fail "stale native progress refreshed the new incarnation"
  out=$(drive_pi_ext "$ext" text_delta) || fail "stale streaming drive failed: $out"
  [ ! -e "$state/$id.progress" ] || fail "stale streaming refreshed the new incarnation"
  pass "pi extension events from a superseded incarnation are rejected as stale"
}

# drive_oc_plugin <plugin-path> <events-json-lines...>: load the generated
# OpenCode plugin in a plain Node host and feed it one event per argument, in
# order, through the same hooks.event entry OpenCode calls.
drive_oc_plugin() {
  local plugin=$1
  shift
  PLUGIN_PATH="$plugin" node --input-type=module - "$@" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const hooks = await mod.FmBusyState({});
for (const arg of process.argv.slice(2)) {
  await hooks.event({ event: JSON.parse(arg) });
}
EOF
}

oc_status() {  # <sessionID> <type>
  printf '{"type":"session.status","properties":{"sessionID":"%s","status":{"type":"%s"}}}' "$1" "$2"
}

oc_idle() {  # <sessionID>
  printf '{"type":"session.idle","properties":{"sessionID":"%s"}}' "$1"
}

test_opencode_plugin_semantic_lifecycle() {
  local rec id=busy-oc-1 out state plugin
  rec=$(make_spawn_case oc-lifecycle opencode "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "opencode spawn should succeed: $out"
  state="$HOME_DIR/state"
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  assert_present "$plugin" "opencode spawn did not write the busy-state plugin"

  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  out=$(drive_oc_plugin "$plugin" "$(oc_status ses_main busy)") || fail "busy drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "session busy must classify 'busy opencode-plugin', got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_status ses_child busy)" \
    "$(oc_status ses_child idle)") || fail "child-session drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "a child session's idle must not clear the worker, got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main retry)" \
    "$(oc_status ses_main idle)") || fail "retry/idle drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "the latched session's idle must classify idle, got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_idle ses_main)") || fail "session.idle drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "session.idle no longer touches the notification marker"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "session.idle for the latched session must classify idle, got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses2 busy)" \
    "$(oc_idle ses_other)") || fail "other-session idle drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "the marker touch must stay a notification for every session.idle"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "another session's idle must not clear the latched busy, got '$out'"
  local gen error_file
  gen=$(cat "$state/$id.busy-gen"); error_file="$state/$id.model-error-$gen.json"
  out=$(drive_oc_plugin "$plugin" "$(oc_status ses_main busy)" \
    '{"type":"session.error","properties":{"sessionID":"ses_main","error":{"data":{"message":"Upstream request failed: region denied"}}}}' \
    "$(oc_idle ses_main)") || fail "error drive failed: $out"
  jq -e '.error=="Upstream request failed: region denied"' "$error_file" >/dev/null || fail 'native failure not persisted through idle'
  out=$(drive_oc_plugin "$plugin" "$(oc_status ses_main busy)" "$(oc_idle ses_main)") || fail "recovery drive failed: $out"
  jq -e '.error==""' "$error_file" >/dev/null || fail 'successful turn did not clear the native failure'
  out=$(drive_oc_plugin "$plugin" "$(oc_status ses_main busy)" \
    '{"type":"session.status","properties":{"sessionID":"ses_main","status":{"type":"retry","message":"Upstream request failed: retrying"}}}' \
    "$(oc_idle ses_main)") || fail "retry recovery drive failed: $out"
  jq -e '.error==""' "$error_file" >/dev/null || fail 'a retry that recovers must not latch a persisted outage'
  pass "opencode plugin classifies from session.status, scoped to the latched worker session"
}

run_claude_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd"
}

test_claude_hooks_semantic_lifecycle() {
  local rec id=busy-cl-1 out state settings
  rec=$(make_spawn_case claude-lifecycle claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "claude spawn did not write hook settings"
  jq -e . "$settings" >/dev/null || fail "claude hook settings are not valid JSON"
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "claude hook settings lack $ev"
  done

  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  run_claude_hook "$settings" Stop || fail "Stop hook command failed"
  [ -f "$state/$id.turn-ended" ] || fail "Stop no longer touches the notification marker"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "Stop must classify 'idle claude-hook', got '$out'"

  run_claude_hook "$settings" UserPromptSubmit || fail "UserPromptSubmit hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy claude-hook" ] || fail "UserPromptSubmit must classify 'busy claude-hook', got '$out'"

  run_claude_hook "$settings" StopFailure || fail "StopFailure hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "StopFailure must classify idle so an API error cannot strand busy, got '$out'"

  run_claude_hook "$settings" UserPromptSubmit
  run_claude_hook "$settings" SessionEnd || fail "SessionEnd hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  pass "claude hooks open on UserPromptSubmit and close on Stop, StopFailure, and SessionEnd"
}

test_claude_hooks_stale_incarnation_harmless() {
  local rec id=busy-cl-2 out state settings
  rec=$(make_spawn_case claude-stale claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  run_claude_hook "$settings" UserPromptSubmit \
    || fail "a stale-gen hook must still exit 0 so Claude's lifecycle is never broken"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "claude hook events from a superseded incarnation are rejected without breaking the hook"
}

test_codex_unverified_until_a_semantic_source_exists() {
  local rec id=busy-cx-1 out state
  rec=$(make_spawn_case codex-unverified codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "codex spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "codex must not arm a busy contract with no verified semantic source"
  assert_absent "$WT_DIR/.codex/hooks.json" "codex must not install unverified busy hooks"
  assert_contains "$out" 'spawned '"$id"' harness=codex' "codex spawn did not complete normally"
  out=$(classify codex "$id" "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must classify 'unknown codex-unverified', got '$out'"
  out=$(fm_busy_classify tmux fake:w codex "$id" "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "unknown codex-unverified" ] || fail "codex must not fall back to footer text, got '$out'"
  pass "codex classifies unknown until a semantic source is verified, never idle or footer-matched"
}

# Gemini's hooks are PROJECT hooks in the worktree's own .gemini/settings.json,
# and gemini's hook contract requires each command to print a JSON object on
# stdout and nothing else, so these drive the real command and check both the
# classification and that stdout stays parseable JSON.
run_gemini_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd"
}

test_gemini_hooks_semantic_lifecycle() {
  local rec id=busy-gm-1 out state settings
  rec=$(make_spawn_case gemini-lifecycle gemini "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "gemini spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$state/$id.gemini-settings.json"
  assert_present "$settings" "gemini spawn did not write hook settings"
  jq -e . "$settings" >/dev/null || fail "gemini hook settings are not valid JSON"
  for ev in BeforeAgent AfterAgent SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "gemini hook settings lack $ev"
  done
  # The worktree's own .gemini/settings.json is the PROJECT's committed file;
  # firstmate must never write it, or a project's configuration is clobbered.
  assert_absent "$WT_DIR/.gemini/settings.json" \
    "gemini spawn must not write the project's own .gemini/settings.json"

  out=$(classify gemini "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(run_gemini_hook "$settings" AfterAgent) || fail "AfterAgent hook command failed"
  printf '%s' "$out" | jq -e . >/dev/null \
    || fail "AfterAgent must print only a JSON object on stdout, got '$out'"
  [ -f "$state/$id.turn-ended" ] || fail "AfterAgent no longer touches the notification marker"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "idle gemini-hook" ] || fail "AfterAgent must classify 'idle gemini-hook', got '$out'"

  out=$(run_gemini_hook "$settings" BeforeAgent) || fail "BeforeAgent hook command failed"
  printf '%s' "$out" | jq -e . >/dev/null \
    || fail "BeforeAgent must print only a JSON object on stdout, got '$out'"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "busy gemini-hook" ] || fail "BeforeAgent must classify 'busy gemini-hook', got '$out'"

  # SessionEnd fires TWICE for one /quit on gemini-cli 0.58.0, so the second
  # delivery must be a harmless no-op rather than a state change or a failure.
  run_gemini_hook "$settings" SessionEnd >/dev/null || fail "SessionEnd hook command failed"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "idle gemini-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  run_gemini_hook "$settings" SessionEnd >/dev/null || fail "a repeated SessionEnd must still exit 0"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "idle gemini-hook" ] || fail "a repeated SessionEnd must stay idle, got '$out'"
  pass "gemini hooks open on BeforeAgent and close on AfterAgent and a repeated SessionEnd"
}

test_gemini_hooks_stale_incarnation_harmless() {
  local rec id=busy-gm-2 out state settings
  rec=$(make_spawn_case gemini-stale gemini "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "gemini spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$state/$id.gemini-settings.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  run_gemini_hook "$settings" BeforeAgent >/dev/null \
    || fail "a stale-gen hook must still exit 0 so gemini's lifecycle is never broken"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "gemini hook events from a superseded incarnation are rejected without breaking the hook"
}

test_raw_gemini_launch_has_no_semantic_wiring() {
  local rec id=busy-gm-raw out state
  rec=$(make_spawn_case gemini-raw gemini "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" 'gemini --debug')
  expect_code 0 $? "raw gemini spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "raw gemini launch must not arm a busy generation"
  assert_absent "$state/$id.gemini-settings.json" "raw gemini launch must not write hook settings"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "unknown missing" ] || fail "raw gemini launch must classify unknown, got '$out'"
  pass "raw gemini launch remains unwired and classifies unknown"
}

test_gemini_is_refused_as_a_secondmate() {
  local rec id=busy-gm-3 out
  rec=$(make_spawn_case gemini-secondmate gemini "$id")
  read_case_record "$rec"
  # A secondmate spawn carries no delivery contract, so this one deliberately
  # bypasses run_spawn's ship-only --mode/--yolo arguments.
  out=$(GROK_HOME="$HOME_DIR/grok-home" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" --secondmate "$id" gemini) && {
    fail "a gemini secondmate must be refused, it has no primary supervision protocol: $out"
  }
  assert_contains "$out" 'crewmate/scout adapter only' \
    "refusing a gemini secondmate must name the crewmate/scout boundary: $out"
  pass "gemini is refused as a secondmate because it has no primary supervision protocol"
}

test_kimi_and_grok_install_no_unverified_wiring() {
  local state out
  state="$TMP_ROOT/gates/state"
  mkdir -p "$state"
  [ -z "$(fm_busy_sources_for_harness kimi)" ] \
    || fail "standalone kimi must trust no semantic source until it is verified"
  [ -z "$(fm_busy_sources_for_harness grok)" ] \
    || fail "grok must trust no semantic source while its structured path is unverified"
  out=$(fm_busy_classify tmux fake:w kimi gate-k "$state" '🌒 · thinking')
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi must classify unknown, not from its spinner, got '$out'"
  out=$(fm_busy_classify tmux fake:w grok gate-g "$state" 'Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok must classify through its isolated fallback, got '$out'"
  pass "kimi and grok install no unverified semantic wiring and classify through their own gates"
}

# run_outage_fixture <case-dir> <state-dir> <body>: runs the real
# fm_model_outage_tick from a copied lib over fixture lanes. Backend liveness,
# the lane verdict, and the wake sink are faked; busy-gen and the native error
# files are the real on-disk contract. The body calls tick, and lane <id>
# <verdict> <liveness> [error] to set a lane. Wakes land in <case-dir>/wakes.
run_outage_fixture() {
  local case_dir=$1 state=$2 body=$3 bin
  bin="$case_dir/bin"
  mkdir -p "$bin" "$state" "$case_dir/liveness"
  cp "$ROOT/bin/fm-model-outage-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" "$bin/"
  cat > "$bin/fm-backend.sh" <<'EOF'
fm_backend_agent_state() { cat "$FAKE_LIVENESS/$4" 2>/dev/null || printf alive; }
fm_backend_visible_capture_supported() { return 1; }
EOF
  cat > "$bin/fm-busy-lib.sh" <<'EOF'
fm_busy_classify_semantic() {
  local verdict
  verdict=$(cat "$STATE/$4.verdict")
  if [ "$verdict" = hang ]; then sleep 30; printf 'idle opencode-plugin\n'; return 0; fi
  printf '%s\n' "$verdict"
}
EOF
  (
    export STATE="$state" FAKE_LIVENESS="$case_dir/liveness"
    # shellcheck source=/dev/null
    . "$bin/fm-model-outage-lib.sh"
    fm_meta_get() { printf opencode; }
    fm_backend_target_of_meta() { printf 'fake:%s' "${1##*/}"; }
    fm_backend_of_meta() { printf fake; }
    hash_pane() { md5sum | cut -c1-12; }
    wake() { :; }
    fm_wake_append() { printf '%s\n' "$3" >> "$case_dir/wakes"; }
    lane() {  # <id> <verdict> <liveness> [error]
      : > "$state/$1.meta"
      printf 'g1\n' > "$state/$1.busy-gen"
      printf '%s\n' "$2" > "$state/$1.verdict"
      printf '%s\n' "$3" > "$case_dir/liveness/$1"
      printf '{"gen":"g1","error":"%s"}\n' "${4-Upstream request failed: region denied}" > "$state/$1.model-error-g1.json"
    }
    tick() { rm -f "$STATE/.model-outages/.scan-at"; fm_model_outage_tick; }
    "$body"
  ) || fail "model-outage scans failed"
  if compgen -G "$state/.model-outages/.scan.*" >/dev/null; then fail "a scan batch directory leaked"; fi
}

staggered_union_scans() {
  lane alpha "idle opencode-plugin" alive
  tick
  lane bravo "idle opencode-plugin" alive
  lane charlie "busy opencode-plugin" missing
  tick
  tick
}

# A lane joining an alerted episode sends one updated wake naming the union; a
# dead mid-turn lane is not named.
test_model_outage_staggered_lane_joins_union_wake() {
  local case_dir="$TMP_ROOT/model-outage-union" expected
  run_outage_fixture "$case_dir" "$case_dir/state" staggered_union_scans
  expected=$(printf '%s\n' \
    'check: model outage affected=[alpha]: Upstream request failed: region denied' \
    'check: model outage affected=[alpha,bravo]: Upstream request failed: region denied')
  [ "$(cat "$case_dir/wakes")" = "$expected" ] \
    || fail "a lane joining an alerted episode must send one union wake and nothing for a dead lane, got: $(cat "$case_dir/wakes")"
  pass "a staggered lane joins its alerted outage in one union wake; a dead mid-turn lane is not named"
}

recovered_lane_scans() {
  lane alpha "idle opencode-plugin" alive
  tick
  lane alpha "idle opencode-plugin" alive ""
  lane bravo "idle opencode-plugin" alive
  tick
  lane alpha "idle opencode-plugin" alive
  tick
}

# A recovered lane leaves the wake: a lane that fails after recovering is named
# again, and the wake lists the lanes failing in that scan.
test_model_outage_recovered_lane_leaves_wake() {
  local case_dir="$TMP_ROOT/model-outage-recovered" expected
  run_outage_fixture "$case_dir" "$case_dir/state" recovered_lane_scans
  expected=$(printf '%s\n' \
    'check: model outage affected=[alpha]: Upstream request failed: region denied' \
    'check: model outage affected=[bravo]: Upstream request failed: region denied' \
    'check: model outage affected=[alpha,bravo]: Upstream request failed: region denied')
  [ "$(cat "$case_dir/wakes")" = "$expected" ] \
    || fail "a recovered lane must leave the wake and re-alert on re-failure, got: $(cat "$case_dir/wakes")"
  pass "a recovered lane leaves the alert record and re-alerts when it fails again"
}

unreadable_hold_scans() {
  lane alpha "idle opencode-plugin" alive
  lane bravo "idle opencode-plugin" alive
  tick
  lane bravo "idle opencode-plugin" unreadable
  lane alpha "idle opencode-plugin" alive ""
  tick
  lane alpha "idle opencode-plugin" alive
  tick
}

# A lane that becomes unreadable keeps its named place, and a recovered lane that
# fails again with the same error is named again.
test_model_outage_unreadable_lane_does_not_pin_recovered_episode() {
  local case_dir="$TMP_ROOT/model-outage-unreadable" expected
  run_outage_fixture "$case_dir" "$case_dir/state" unreadable_hold_scans
  expected=$(printf '%s\n' \
    'check: model outage affected=[alpha,bravo]: Upstream request failed: region denied' \
    'check: model outage affected=[alpha]: Upstream request failed: region denied')
  [ "$(cat "$case_dir/wakes")" = "$expected" ] \
    || fail "an unreadable lane must not pin a recovered episode, got: $(cat "$case_dir/wakes")"
  pass "a persistently unreadable lane does not pin a recovered episode"
}

hung_verdict_scans() {
  lane delta "hang" alive
  tick
}

# A hung verdict read is bounded like the other per-lane reads: it cannot block
# the scan or name a lane.
test_model_outage_hung_verdict_is_bounded() {
  local case_dir="$TMP_ROOT/model-outage-hung" started elapsed
  started=$(date +%s)
  run_outage_fixture "$case_dir" "$case_dir/state" hung_verdict_scans
  elapsed=$(( $(date +%s) - started ))
  [ ! -e "$case_dir/wakes" ] || fail "a hung verdict must not name a lane, got: $(cat "$case_dir/wakes")"
  [ "$elapsed" -lt 20 ] || fail "a hung verdict read blocked the scan for ${elapsed}s"
  pass "a hung verdict read is bounded and names no lane"
}

errored_then_healthy_turn_scans() {
  drive_oc_plugin "$plugin" "$(oc_status ses_main busy)" "$error_event" || fail "error drive failed"
  tick
  drive_oc_plugin "$plugin" "$(oc_status ses_main busy)" || fail "healthy turn drive failed"
  tick
  tick
}

# A recorded session error must not outlive the next turn: a healthy busy turn
# spanning more than one scan sends no outage wake.
test_model_outage_healthy_turn_after_error_does_not_alert() {
  local rec id=busy-oc-2 state plugin error_event case_dir out
  rec=$(make_spawn_case oc-healthy-turn opencode "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "opencode spawn should succeed: $out"
  state="$HOME_DIR/state"
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  error_event='{"type":"session.error","properties":{"sessionID":"ses_main","error":{"data":{"message":"Upstream request failed: region denied"}}}}'
  case_dir="$TMP_ROOT/model-outage-healthy-turn"
  printf '%s\n' "busy opencode-plugin" > "$state/$id.verdict"
  run_outage_fixture "$case_dir" "$state" errored_then_healthy_turn_scans
  [ ! -e "$case_dir/wakes" ] \
    || fail "a healthy turn after a recorded error must not alert, got: $(cat "$case_dir/wakes")"
  pass "a healthy turn after a recorded error clears it and sends no outage wake"
}

test_pi_extension_semantic_lifecycle
test_pi_extension_serializes_settle_before_next_start
test_pi_extension_stale_ctx_settles_unknown
test_pi_extension_stale_incarnation_rejected
test_kimi_and_grok_install_no_unverified_wiring
test_opencode_plugin_semantic_lifecycle
test_claude_hooks_semantic_lifecycle
test_claude_hooks_stale_incarnation_harmless
test_gemini_hooks_semantic_lifecycle
test_gemini_hooks_stale_incarnation_harmless
test_raw_gemini_launch_has_no_semantic_wiring
test_gemini_is_refused_as_a_secondmate
test_codex_unverified_until_a_semantic_source_exists
test_model_outage_staggered_lane_joins_union_wake
test_model_outage_recovered_lane_leaves_wake
test_model_outage_unreadable_lane_does_not_pin_recovered_episode
test_model_outage_hung_verdict_is_bounded
test_model_outage_healthy_turn_after_error_does_not_alert

echo "all fm-busy-adapter-wiring tests passed"
