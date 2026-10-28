#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2088
# Behavior tests for the watcher-arm PreToolUse seatbelt (docs/arm-pretool-check.md).
#
# bin/jg-arm-command-policy.mjs is the single owner of command classification.
# This suite drives the stable shell transport through all five harness entry
# forms and asserts the per-harness wiring contract without spawning a harness.
# Empirical harness evidence lives in docs/arm-pretool-check.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/jg-arm-pretool-check.sh"
POLICY="$ROOT/bin/jg-arm-command-policy.mjs"

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

matrix_case A01 allow 'bin/jg-watch-arm.sh'
matrix_case A02 allow './bin/jg-watch-arm.sh --restart'
matrix_case A03 allow 'exec bin/jg-watch-arm.sh'
matrix_case A04 allow 'bin/jg-watch-checkpoint.sh --seconds 180'
matrix_case A05 allow 'exec bin/jg-watch-checkpoint.sh --seconds 180'
matrix_case A06 allow "$ROOT/bin/jg-watch-checkpoint.sh --seconds 180"
matrix_case A07 allow "cd '$ROOT'; exec bin/jg-watch-arm.sh"
matrix_case A08 allow "cd '../juggernaut'; bin/jg-watch-checkpoint.sh --seconds 180"
matrix_case A09 allow "export JG_HOME='$ROOT'; bin/jg-watch-checkpoint.sh --seconds 180"
matrix_case A10 allow 'source config/x-mode.env; bin/jg-watch-checkpoint.sh --seconds 180'
matrix_case A11 allow "source 'config/x-mode.env'; bin/jg-watch-checkpoint.sh --seconds 180"
matrix_case A12 allow "source './config/x-mode.env'; bin/jg-watch-checkpoint.sh --seconds 180"
matrix_case A13 allow "source '$ROOT/config/x-mode.env'; bin/jg-watch-checkpoint.sh --seconds 180"
matrix_case A14 allow "[ -f 'config/x-mode.env' ] && source 'config/x-mode.env'; exec bin/jg-watch-arm.sh"
matrix_case A15 allow "cd $ROOT && exec bin/jg-watch-arm.sh"
matrix_case A16 allow "export JG_HOME=$ROOT && bin/jg-watch-checkpoint.sh --seconds 180"
matrix_case A17 allow $'source "config/x-mode.env"\nbin/jg-watch-checkpoint.sh --seconds 180'

matrix_case R01 allow "pgrep -fl '/bin/jg-watch.sh' || true"
matrix_case R02 allow "ps aux | rg '/bin/jg-watch.sh'"
matrix_case R03 allow "rg -n 'jg-watch-arm.sh &' docs tests"
matrix_case R04 allow "rg -n 'bin/jg-watch-arm.sh; echo bad' docs"
matrix_case R05 allow "git grep 'jg-watch-checkpoint.sh && echo bad'"
matrix_case R06 allow "sed -n '/jg-watch-checkpoint.sh/p' docs/arm-pretool-check.md"
matrix_case R07 allow 'assert_contains "$content" '\''jg-watch-arm.sh &'\'''
matrix_case R08 allow "printf '%s\\n' 'bin/jg-watch-checkpoint.sh --seconds 180 >/tmp/out'"
matrix_case R09 allow "tmux send-keys -t isolated-pi-lab 'bin/jg-watch-arm.sh &' Enter"
matrix_case R10 allow "tmux send-keys -t isolated-pi-lab \"printf '%s\\n' 'bin/jg-watch-arm.sh &'\"; tmux send-keys -t isolated-pi-lab Enter"
matrix_case R11 allow "python3 -c 'print(\"bin/jg-watch-arm.sh; echo data\")'"
matrix_case R12 allow "bash -lc \"rg -n 'jg-watch-arm.sh &' docs\""
matrix_case R13 allow "echo 'pkill -f jg-watch'"
matrix_case R14 allow "rg -n 'pkill -f jg-watch' docs tests"
matrix_case R15 allow "echo ok # bin/jg-watch-arm.sh &"
matrix_case R16 allow $'# bin/jg-watch-arm.sh &\necho ok'
matrix_case R17 allow "printf '%s\\n' 'jg-watch.sh; a && b || c > out' | sed -n '1p'"
matrix_case R18 allow "sh -c 'tmux send-keys -t lab \"bin/jg-watch-arm.sh &\" Enter'"
matrix_case R19 allow "eval 'printf \"%s\\n\" \"bin/jg-watch-arm.sh &\"'"
matrix_case R20 allow "bash -s sentinel <<< 'echo jg-watch.sh'"
matrix_case R21 allow "bash -- -s sentinel <<< 'bin/jg-watch.sh'"

matrix_case D01 deny 'bin/jg-watch-arm.sh &'
matrix_case D02 deny 'nohup bin/jg-watch-arm.sh'
matrix_case D03 deny 'bin/jg-watch-arm.sh & disown'
matrix_case D04 deny '(bin/jg-watch-arm.sh) &'
matrix_case D05 deny "bash -lc 'bin/jg-watch-arm.sh &'"
matrix_case D06 deny '$(bin/jg-watch-arm.sh)'
matrix_case D07 deny 'echo "$(bin/jg-watch-checkpoint.sh --seconds 180)"'
matrix_case D08 deny 'cat <(bin/jg-watch-arm.sh)'
matrix_case D09 deny 'bin/jg-watch-arm.sh >/tmp/out'
matrix_case D10 deny 'bin/jg-watch-checkpoint.sh --seconds 180 </dev/null'
matrix_case D11 deny 'bin/jg-watch-arm.sh 2>&1 | head -2'
matrix_case D12 deny 'bin/jg-watch-arm.sh | cat'
matrix_case D13 deny 'bin/jg-watch-checkpoint.sh --seconds 180 | timeout 1 cat'
matrix_case D14 deny 'echo before; bin/jg-watch-arm.sh'
matrix_case D15 deny 'bin/jg-watch-checkpoint.sh --seconds 180; echo after'
matrix_case D16 deny 'true && bin/jg-watch-arm.sh'
matrix_case D17 deny 'bin/jg-watch-checkpoint.sh --seconds 180 || true'
matrix_case D18 deny $'bin/jg-watch-arm.sh\nbin/jg-watch-checkpoint.sh --seconds 180'
matrix_case D19 deny "pkill -f '/bin/jg-watch.sh'"
matrix_case D20 deny "command pkill -f '/bin/jg-watch.sh'"
matrix_case D21 deny "/usr/bin/pkill -f '/bin/jg-watch.sh'"
matrix_case D22 deny "sudo pkill -f '/bin/jg-watch.sh'"
matrix_case D23 deny 'kill "$(pgrep -f '\''/bin/jg-watch.sh'\'')"'
matrix_case D24 deny $'bin/jg-watc\\\nh-arm.sh &'
matrix_case D25 deny 'sudo -u root bin/jg-watch-arm.sh &'
matrix_case D26 deny 'env -u PATH bin/jg-watch-arm.sh &'
matrix_case D27 deny "bash -c \$'bin/jg-watch-arm.sh &'"
matrix_case D28 deny $'bash <<\'EOF\'\nbin/jg-watch-arm.sh &\nEOF'
matrix_case D29 deny "WATCHER='bin/jg-watch-arm.sh &' bash -c 'eval \"\$WATCHER\"'"
matrix_case D30 deny "p=\$(pgrep -f '/bin/jg-watch.sh'); kill \"\$p\""
matrix_case D31 deny "env -S 'bin/jg-watch-arm.sh &'"
matrix_case D32 deny "env --split-string='$ROOT/bin/jg-watch-arm.sh &'"
matrix_case D33 deny 'bin/jg-"watch-arm.sh" &'
matrix_case D34 deny "WATCHER='bin/jg-watch-arm.sh'; \"\$WATCHER\" &"
matrix_case D35 deny "bash -c -- 'bin/jg-watch-arm.sh &'"
matrix_case D36 deny 'bash bin/jg-watch-arm.sh &'
matrix_case D37 deny '. bin/jg-watch-arm.sh &'
matrix_case D38 deny "bash <<< 'bin/jg-watch-arm.sh &'"
matrix_case D39 deny "eval 'true;' 'bin/jg-watch-arm.sh &'"
matrix_case D40 deny 'timeout 30 bin/jg-watch-arm.sh &'
matrix_case D41 deny 'gtimeout 30 bin/jg-watch-arm.sh &'
matrix_case D42 deny 'bin/jg-watch-{arm,checkpoint}.sh &'
matrix_case D43 deny 'bin/jg-watch-arm.sh* &'
matrix_case D44 deny "pattern='jg-watch'; pkill -f \"\$pattern\""
matrix_case D45 deny "p=\$(pgrep -f '/bin/jg-watch.sh'); q=\$p; kill \$q"
matrix_case D46 deny '$JG_HOME/bin/jg-watch-arm.sh &'
matrix_case D47 deny '$HOME/juggernaut/bin/jg-watch-arm.sh | cat'
matrix_case D48 deny '~/juggernaut/bin/jg-watch-arm.sh &'
matrix_case D49 deny 'bin/jg-watch.sh'
matrix_case D50 deny '$JG_HOME/bin/jg-watch.sh'
matrix_case D51 deny '~/juggernaut/bin/jg-watch.sh --restart'
matrix_case D52 deny "bin/jg-\$'\x77'atch-arm.sh &"
matrix_case D53 deny 'bin/jg-$"watch"-arm.sh &'
matrix_case D54 deny 'bin/jg-watch-$"arm".sh &'
matrix_case D55 deny 'while true; do pkill -f jg-watch; done'
matrix_case D56 deny 'for x in 1; do pkill -f jg-watch; done'
matrix_case D57 deny 'case x in x) pkill -f jg-watch ;; esac'
matrix_case D58 deny 'until false; do kill $(pgrep -f jg-watch); done'
matrix_case D59 deny $'bash -s sentinel <<\'EOF\'\nbin/jg-watch.sh\nEOF'
matrix_case D60 deny "bash -s sentinel <<< 'bin/jg-watch.sh'"
matrix_case D61 deny "bash -s -- one two <<< 'bin/jg-watch-arm.sh &'"
matrix_case D62 deny "bash -xs sentinel <<< 'bin/jg-watch.sh'"
matrix_case D63 deny "sh -s sentinel <<< 'bin/jg-watch.sh'"
matrix_case D64 deny 'bash -s bin/jg-watch.sh'
matrix_case D65 deny "bash -s -- -c harmless <<< 'bin/jg-watch.sh'"

matrix_case E01 allow "bin/jg-watch-checkpoint.sh --seconds '180;still-one-arg'"
matrix_case E02 allow "bin/jg-watch-checkpoint.sh --label 'jg-watch-arm.sh; literal argument'"
matrix_case E03 allow 'bin/jg-watch-arm.sh # output > file &'
matrix_case E04 allow $'# setup comment with jg-watch.sh; && >\nsource "config/x-mode.env"\nbin/jg-watch-checkpoint.sh --seconds 180'
matrix_case E05 deny "JG_HOME=$ROOT bin/jg-watch-checkpoint.sh --seconds 180"
matrix_case E06 deny "env JG_HOME=$ROOT bin/jg-watch-arm.sh"
matrix_case E07 deny "source '/tmp/not-juggernaut/config/x-mode.env'; bin/jg-watch-checkpoint.sh --seconds 180"
matrix_case E08 deny "bash -lc 'bin/jg-watch-checkpoint.sh --seconds 180'"
matrix_case E09 deny '(bin/jg-watch-checkpoint.sh --seconds 180)'
matrix_case E10 deny "eval 'bin/jg-watch-arm.sh &'"
matrix_case E11 deny "exec bash -lc 'bin/jg-watch-arm.sh &'"
matrix_case E12 allow 'bash -lc "$WATCHER_COMMAND" # jg-watch-arm.sh'
matrix_case E13 allow "printf '%s\\n' 'argument has ; and jg-watch-arm.sh and &&'"
matrix_case E14 allow '$JG_HOME/bin/jg-teardown.sh &'
matrix_case E15 allow '$JG_HOME/bin/jg-watch-arm.sh'
matrix_case E16 allow '~/juggernaut/bin/jg-watch-checkpoint.sh --seconds 180'
matrix_case E17 allow 'for f in 1; do echo jg-watch; done'

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/jg-arm-policy-matrix.XXXXXX")
JG_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")
trap jg_test_cleanup EXIT

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[(watcher-(background|pipeline|redirection|bundled|nested|direct)|broad-watcher-kill|unclassifiable-protected-command)\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry a stable reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
    pass "matrix ${MATRIX_IDS[$i]}: ${MATRIX_EXPECTED[$i]} through all five entry forms"
  done
}

assert_policy() {
  local id=$1 expected=$2 command=$3 output
  output=$(node "$POLICY" --root "$ROOT" --home "$ROOT" --command "$command") \
    || fail "$id direct policy invocation failed"
  case "$output" in
    "$expected"|"$expected"$'\t'*) : ;;
    *) fail "$id direct policy expected $expected, got: $output" ;;
  esac
  pass "direct policy $id: $expected"
}

test_direct_policy_contract() {
  local heredoc_data heredoc_watcher
  assert_policy direct-data-pkill allow "echo 'pkill -f jg-watch'"
  assert_policy direct-broad-pkill $'deny\tbroad-watcher-kill' "pkill -f '/bin/jg-watch.sh'"
  assert_policy direct-loop-broad-pkill $'deny\tbroad-watcher-kill' 'while true; do pkill -f jg-watch; done'
  assert_policy direct-loop-broad-kill-pgrep $'deny\tbroad-watcher-kill' 'until false; do kill $(pgrep -f jg-watch); done'
  assert_policy direct-loop-no-kill-allowed allow 'for f in 1; do echo jg-watch; done'
  assert_policy direct-pipeline $'deny\twatcher-pipeline' 'bin/jg-watch-arm.sh | cat'
  assert_policy direct-leading-redirection $'deny\twatcher-redirection' '>/tmp/out bin/jg-watch-arm.sh'
  assert_policy direct-unclassifiable $'deny\tunclassifiable-protected-command' "bin/jg-watch-arm.sh 'unterminated"
  assert_policy direct-unsupported $'deny\tunclassifiable-protected-command' 'if true; then bin/jg-watch-arm.sh; fi'
  assert_policy direct-constructed-payload $'deny\twatcher-nested' "WATCHER='bin/jg-watch-arm.sh &'; bash -lc \"\$WATCHER\""
  assert_policy direct-parameter-export allow 'export JG_HOME=${HOME}; bin/jg-watch-checkpoint.sh --seconds 180'
  assert_policy direct-expanded-arm-blessed allow '$JG_HOME/bin/jg-watch-arm.sh'
  assert_policy direct-expanded-arm-background $'deny\twatcher-background' '$JG_HOME/bin/jg-watch-arm.sh &'
  assert_policy direct-expanded-arm-pipeline $'deny\twatcher-pipeline' '$HOME/juggernaut/bin/jg-watch-arm.sh | cat'
  assert_policy direct-watch-not-blessed $'deny\twatcher-direct' 'bin/jg-watch.sh'
  assert_policy direct-watch-expanded $'deny\twatcher-direct' '$JG_HOME/bin/jg-watch.sh'
  assert_policy direct-watch-safe-shape $'deny\twatcher-direct' 'cd /tmp; bin/jg-watch.sh'
  heredoc_data=$'cat <<\'EOF\'\nbin/jg-watch-arm.sh &\nEOF'
  heredoc_watcher=$'bin/jg-watch-arm.sh <<\'EOF\'\ndata only\nEOF'
  assert_policy direct-heredoc-data allow "$heredoc_data"
  assert_policy direct-heredoc-watcher $'deny\twatcher-redirection' "$heredoc_watcher"
}

# --- CLI parsing -------------------------------------------------------------

test_command_equals_form() {
  "$CHECK" --command='bin/jg-watch-arm.sh &' >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "--command=<val> form must parse the same as --command <val>"
  pass "--command=<val> equals-form parses correctly"
}

test_background_flag_accepted_and_non_gating() {
  local rc_bg rc_nobg
  "$CHECK" --command 'exec bin/jg-watch-arm.sh' --background true >/dev/null 2>&1
  rc_bg=$?
  "$CHECK" --command 'exec bin/jg-watch-arm.sh' >/dev/null 2>&1
  rc_nobg=$?
  [ "$rc_bg" -eq 0 ] || fail "--background true must not change the allow decision on its own, got exit $rc_bg"
  [ "$rc_bg" -eq "$rc_nobg" ] || fail "--background flag must be accepted without altering the decision"
  pass "--background is accepted for interface parity and is never itself a deny signal"
}

test_unknown_flag_errors() {
  "$CHECK" --bogus-flag >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "an unrecognized flag must exit non-zero, not silently allow"
  pass "unknown CLI flag is rejected"
}

# --- stdin JSON mode ----------------------------------------------------------

test_stdin_grok_schema_deny() {
  local out rc
  out=$(printf '%s' '{"toolInput":{"command":"bin/jg-watch-arm.sh &","background":false},"toolName":"run_terminal_command"}' | "$CHECK" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "grok toolInput.command schema must be read and denied, got exit $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 || fail "stdout must carry Grok's {\"decision\":\"deny\",...} shape: $out"
  pass "stdin grok schema (toolInput.command): denied with Grok-shaped stdout JSON"
}

test_stdin_claude_codex_schema_allow() {
  local rc
  printf '%s' '{"tool_input":{"command":"exec bin/jg-watch-arm.sh"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "claude/codex tool_input.command schema must be read and allowed for the blessed shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): blessed shape allowed"
}

test_stdin_claude_codex_schema_deny() {
  local rc
  printf '%s' '{"tool_input":{"command":"bin/jg-watch-arm.sh &"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "claude/codex tool_input.command schema must be denied for the backgrounded shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): backgrounded shape denied"
}

test_stdin_unrelated_command_allowed() {
  local rc
  printf '%s' '{"tool_input":{"command":"ls -la"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "an unrelated command must pass through allowed, got exit $rc"
  pass "stdin: unrelated command is a fast allow"
}

test_prefilter_is_strict_superset() {
  local rc
  # A command with no jg-watch substring is fast-allowed by the transport
  # prefilter without ever invoking the classifier.
  "$CHECK" --command 'ls -la /bin && echo done' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a command with no jg-watch substring must be fast-allowed, got exit $rc"
  # A deniable protected execution carries the jg-watch bytes, so the prefilter
  # must delegate to the classifier and the deny must survive.
  "$CHECK" --command 'bin/jg-watch-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a deniable jg-watch command, not fast-allow it, got exit $rc"
  # A broad watcher kill also contains the jg-watch bytes and must still deny.
  "$CHECK" --command "pkill -f '/bin/jg-watch.sh'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a broad watcher kill, not fast-allow it, got exit $rc"
  # Obfuscated protected paths lose the literal jg-watch bytes (a line
  # continuation or a quote splits them), yet the classifier reconstructs them.
  # The prefilter normalizes those bytes first, so both must still delegate and
  # deny rather than slip through as a fast allow.
  "$CHECK" --command "$(printf 'bin/jg-watc\\\nh-arm.sh &')" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a line-continuation-split protected path, not fast-allow it, got exit $rc"
  "$CHECK" --command 'bin/jg-"watch-arm.sh" &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a quote-split protected path, not fast-allow it, got exit $rc"
  # A quoting-decoder marker ($' ANSI-C or $" locale) hides the jg-watch bytes
  # from the cheap byte strip but the classifier reconstructs them, so the
  # prefilter must delegate on the marker rather than fast-allow. Without this
  # the byte strip loses the encoded character and slips the command through.
  "$CHECK" --command "bin/jg-\$'\x77'atch-arm.sh &" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate an ANSI-C-encoded protected path, not fast-allow it, got exit $rc"
  "$CHECK" --command 'bin/jg-$"watch"-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a locale-string-encoded protected path, not fast-allow it, got exit $rc"
  # The marker is specifically $ followed by a quote, not any $ expansion: an
  # ordinary $VAR that is not a watcher reference still takes the fast path.
  "$CHECK" --command '$JG_HOME/bin/jg-teardown.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign \$VAR non-watcher command must still fast-allow, got exit $rc"
  "$CHECK" --command 'echo "$HOME/scratch" && ls -la' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign \$HOME command must still fast-allow, got exit $rc"
  # A benign command that only mentions jg-watch as data still reaches the
  # classifier and is allowed there, proving the prefilter owns no verdict.
  "$CHECK" --command "echo 'pkill -f jg-watch'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign jg-watch-substring command must be classified and allowed, got exit $rc"
  pass "transport prefilter is a strict superset: non-jg-watch fast-allows, every jg-watch and quoting-decoder-marker command reaches the classifier"
}

# --- fail-open ----------------------------------------------------------------

test_failopen_empty_stdin() {
  local rc
  printf '' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "empty stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: empty stdin"
}

test_failopen_garbage_stdin() {
  local rc
  printf 'not json at all {{{' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "unparseable stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: unparseable JSON on stdin"
}

test_failopen_missing_jq() {
  local dir fakebin rc real
  dir=$(jg_test_tmproot jg-arm-pretool-check)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  local tool
  for tool in bash grep sed tr; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" bash -c "printf '%s' '{\"tool_input\":{\"command\":\"bin/jg-watch-arm.sh &\"}}' | '$CHECK'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq must fail open (exit 0) rather than crash-deny, got exit $rc"
  pass "fail-open: missing jq on stdin path"
}

test_failopen_missing_node() {
  local dir fakebin rc real tool
  dir=$(jg_test_tmproot jg-arm-pretool-node)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  for tool in bash dirname; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" "$CHECK" --command 'bin/jg-watch-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing node must fail open (exit 0), got exit $rc"
  pass "fail-open: missing classifier runtime"
}

# --- --claude output shaping ---------------------------------------------------

test_claude_mode_stdout_empty_on_deny() {
  local out err rc stderr_file
  # Keep stderr capture under TMPDIR so concurrent isolation-proof workers do
  # not share a fixed global /tmp path.
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/jg-arm-pretool-check-claude-stderr.XXXXXX")
  out=$("$CHECK" --claude --command 'bin/jg-watch-arm.sh &' 2>"$stderr_file")
  rc=$?
  err=$(cat "$stderr_file" 2>/dev/null)
  rm -f "$stderr_file"
  [ "$rc" -eq 2 ] || fail "--claude deny must still exit 2, got $rc"
  [ -z "$out" ] || fail "--claude deny must leave stdout EMPTY (Claude Code only honors a stderr-only deny), got: $out"
  printf '%s' "$err" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || fail "--claude deny must put hookSpecificOutput.permissionDecision=deny on stderr: $err"
  pass "--claude: stdout empty, stderr carries hookSpecificOutput deny JSON"
}

test_default_mode_stdout_has_grok_json_on_deny() {
  local out rc
  out=$("$CHECK" --command 'bin/jg-watch-arm.sh &' 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "default deny must exit 2, got $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 \
    || fail "default (non-claude) deny must put Grok's decision JSON on stdout: $out"
  pass "default mode: stdout carries Grok-shaped decision JSON on deny"
}

test_allow_is_silent_both_modes() {
  local out1 out2
  out1=$("$CHECK" --command 'exec bin/jg-watch-arm.sh' 2>&1)
  out2=$("$CHECK" --claude --command 'exec bin/jg-watch-arm.sh' 2>&1)
  [ -z "$out1" ] || fail "default allow must be silent, got: $out1"
  [ -z "$out2" ] || fail "--claude allow must be silent, got: $out2"
  pass "allow is silent on both stdout and stderr in default and --claude mode"
}

# --- harness wiring: each adapter invokes the shared checker -----------------

# --- shellcheck (belt-and-suspenders; CI/CONTRIBUTING.md also runs this) -----
#
# Delegated to bin/jg-lint.sh rather than calling shellcheck directly, because
# that script is the single owner of the lint definition - the file set, the
# pinned version, and the options, including --external-sources. Calling the
# linter directly here would be a second, weaker copy of that definition, and it
# disagreed with the owner the moment this checker sourced a shared library.

test_shellcheck_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/jg-lint.sh" "$CHECK" 2>&1)     || fail "bin/jg-arm-pretool-check.sh is not lint-clean under the pinned definition: $out"
  pass "bin/jg-arm-pretool-check.sh is clean under bin/jg-lint.sh"
}

test_full_acceptance_matrix
test_direct_policy_contract
test_command_equals_form
test_background_flag_accepted_and_non_gating
test_unknown_flag_errors
test_stdin_grok_schema_deny
test_stdin_claude_codex_schema_allow
test_stdin_claude_codex_schema_deny
test_stdin_unrelated_command_allowed
test_prefilter_is_strict_superset
test_failopen_empty_stdin
test_failopen_garbage_stdin
test_failopen_missing_jq
test_failopen_missing_node
test_claude_mode_stdout_empty_on_deny
test_default_mode_stdout_has_grok_json_on_deny
test_allow_is_silent_both_modes
test_shellcheck_clean
