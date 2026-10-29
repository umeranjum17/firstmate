#!/usr/bin/env bash
# The stuck-worker escalation chain (addons/wait-timers/README.md): a stuck
# operator goes to its owning lead, a stuck lead goes to Main, and only what
# Main cannot settle becomes a board card; every rung fires again while the
# wait stays open. Real watcher and drain cycles over a copy of this checkout's
# bin/ and add-ons; only the terminal, the board, and the steer and interrupt
# endpoints are recorders. One test per scenario row.
set -eu

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-escalation-chain)
FORK="$TMP_ROOT/fork"
mkdir -p "$FORK"
cp -a "$ROOT/bin" "$ROOT/addons" "$FORK/"
# The steer and interrupt endpoints record their calls in the calling home.
for f in jg-send.sh jg-control.sh; do
  # shellcheck disable=SC2016 # the recorder expands its own arguments when run
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> "$JG_HOME/sent"\n' "${f%.sh}" > "$FORK/bin/$f"
done

# A home with a recorded terminal (fake:<n> panes listed in $JG_FAKE_PANES,
# each showing $h/panes/<n>, an agent in the foreground) and a recording board.
home() {  # <name> -> home path
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/config" "$h/home" "$h/tmp" "$h/fakebin" "$h/panes"
  jg_test_track_watcher_state "$h/state"
  cat > "$h/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
t=; prev=
for a in "$@"; do [ "$prev" = -t ] && t=$a; prev=$a; done
listed() { case " ${JG_FAKE_PANES:-} " in *" ${1#fake:} "*) return 0 ;; esac; return 1; }
case "${1:-}" in
  list-windows) for p in ${JG_FAKE_PANES:-}; do printf '%s\n' "$p"; done ;;
  capture-pane) listed "$t" || exit 1; cat "$JG_HOME/panes/${t#fake:}" 2>/dev/null || printf 'all quiet\n> \n' ;;
  display-message)
    listed "$t" || exit 1
    case "$*" in *pane_tty*) printf '/dev/pts/fake\n' ;; *pane_current_command*) printf 'claude\n' ;; *) printf '%%1\n' ;; esac ;;
  *) exit 1 ;;
esac
SH
  cat > "$h/fakebin/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in *" -t "*) printf '  100   100   100 claude\n'; exit 0 ;; esac
for p in /bin/ps /usr/bin/ps; do [ ! -x "$p" ] || exec "$p" "$@"; done
exit 1
SH
  cat > "$h/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
log="$JG_HOME/cards"
case "${1:-}" in
  raise)
    key=; prev=
    for a in "$@"; do [ "$prev" = --key ] && key=$a; prev=$a; done
    printf 'raise %s\n' "$*" >> "$log"
    grep -Fxq "$key" "$log.open" 2>/dev/null || printf '%s\n' "$key" >> "$log.open" ;;
  list) printf '{"decisions":[%s]}\n' "$(sed 's/.*/{"key":"&"}/' "$log.open" 2>/dev/null | paste -sd, -)" ;;
  dismiss)
    printf 'dismiss %s\n' "$2" >> "$log"
    { grep -Fxv "$2" "$log.open" 2>/dev/null || true; } > "$log.tmp"; mv "$log.tmp" "$log.open" ;;
esac
SH
  chmod +x "$h/fakebin/"*
  printf '%s\n' "$h"
}

# One watcher cycle; Main drains and acknowledges its wakes unless absent.
# While Main is absent the next cycle is the successor the arm path starts
# over its unread wakes, which keeps supervising instead of re-announcing them.
cycle() {  # <home> [absent]
  local h=$1 rc=0 seq gen pid successor=0
  [ "${2:-}" != absent ] || successor=1
  env -u JG_TASK_ID JG_WATCH_HANDLING_SUCCESSOR="$successor" HOME="$h/home" TMPDIR="$h/tmp" PATH="$h/fakebin:$PATH" \
    JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_CONFIG_OVERRIDE="$h/config" JG_ADDONS_DIR="$FORK/addons" \
    JG_POLL=1 JG_SIGNAL_GRACE=1 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS="${LIVENESS:-99999999}" JG_BUSY_TURN_MAX_SECS=999999 JG_STALE_ESCALATE_SECS=999999 \
    JG_SQUAD_LEAD_WAKE_STALL_SECS=999999 JG_WAIT_ALERT_SECS=2 JG_WAIT_ESCALATE_SECS=4 JG_WAIT_CARD_SECS=6 \
    JG_PROMPT_REALERT_SECS=900 JG_FAKE_PANES="${PANES:-}" "$FORK/bin/jg-watch.sh" > "$h/out" 2> "$h/err" &
  pid=$!
  wait_for_exit "$pid" 40 || rc=$?
  case "$rc" in 0|124) ;; *) fail "watcher failed ($rc): $(cat "$h/err")" ;; esac
  cat "$h/out" >> "$h/events"
  [ "${2:-}" != absent ] || return 0
  JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" "$FORK/bin/jg-wake-drain.sh" > "$h/drain" 2> "$h/ack"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$h/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$h/ack")
  [ -z "$seq" ] || JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" "$FORK/bin/jg-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}

lead_meta() {  # <home> <id> <pane> <lead-home> [harness]
  printf 'kind=squad_lead\nmode=squad_lead\nbackend=tmux\nwindow=fake:%s\nharness=%s\nhome=%s\n' "$3" "${5:-claude}" "$4" > "$1/state/$2.meta"
  : > "$1/state/$2.status"
  prime_status_seen "$1/state" "$1/state/$2.status"
}

# Move every recorded time of an episode back by <secs>, as if it had waited.
backdate() {  # <home> <task> <secs>
  local f="$1/state/.waiting-timers/$2" sig since owner parent key misses card last v out=()
  IFS=$'\t' read -r sig since owner parent key misses card last < "$f"
  for v in "$since" "$owner" "$parent" "${card:-0}" "${last:-0}"; do
    if [ "$v" -gt 1 ]; then out+=("$((v - $3))"); else out+=("$v"); fi
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sig" "${out[0]}" "${out[1]}" "${out[2]}" "$key" "${misses:-0}" "${out[3]}" "${out[4]}" > "$f"
}

# What the owning lead appends to Main's state/<lead>.status when its worker's
# wait is overdue (the parent channel), stamped <age> seconds ago.
overdue_report() {  # <main> <lead> <worker> <age>
  local since=$(($(date +%s) - $4))
  printf 'blocked [key=waiting-timer-0000aaaa-%s-g%s-q]: waiting-timer-overdue: %s (needs-decision key=q, observed %ss, since=%s); owning lead has not cleared the wait; Main must unblock or steer the lead; source=[needs-decision [key=q]: pick a database]\n' \
    "$3" "$since" "$3" "$4" "$since" >> "$1/state/$2.status"
  prime_status_seen "$1/state" "$1/state/$2.status"
}

TRUST=$'Quick safety check: Is this a project you created or one you trust?\n  1. Yes, I trust this folder\n  2. No, exit\nEnter to confirm'

test_lead_idle_is_steered_without_interrupt() {
  local m
  m=$(home lead-idle)
  lead_meta "$m" lead1 1 "$m/lead-home"
  "$FORK/bin/jg-busy-event.sh" arm "$m/state" lead1 --state idle --source claude-hook --event stop >/dev/null
  overdue_report "$m" lead1 w1 0
  PANES=1 cycle "$m"
  grep -q '^jg-send lead1 --fire-and-forget [0-9a-f]\{16\} Your worker w1 has been stuck .*on: needs-decision \[key=q\]: pick a database' "$m/sent" \
    || fail "an idle lead was not told which worker is stuck and on what: $(cat "$m/sent" 2>&1)"
  ! grep -q '^jg-control' "$m/sent" || fail "an idle lead was interrupted"
  [ ! -s "$m/cards" ] || fail "a card was posted before the worker had waited long enough"
  # The nudge fires again every interval while the report stays open.
  f=$(ls "$m/state/.waiting-relay/"*)
  IFS=$'\t' read -r first nudged card < "$f"
  printf '%s\t%s\t%s\n' "$first" "$((nudged - 1000))" "$card" > "$f"
  PANES=1 cycle "$m"
  [ "$(grep -c '^jg-send lead1 ' "$m/sent")" -eq 2 ] || fail "the nudge did not fire again after the interval"
  pass "an idle lead with a stuck worker is steered at once, naming the worker and its wait, and again every interval"
}

test_busy_lead_is_interrupted_first() {
  local m
  m=$(home lead-busy)
  lead_meta "$m" lead1 1 "$m/lead-home"
  "$FORK/bin/jg-busy-event.sh" arm "$m/state" lead1 >/dev/null
  overdue_report "$m" lead1 w1 0
  PANES=1 cycle "$m"
  [ "$(sed -n 1p "$m/sent")" = "jg-control lead1 interrupt" ] || fail "a busy lead was not interrupted first: $(cat "$m/sent" 2>&1)"
  sed -n 2p "$m/sent" | grep -q '^jg-send lead1 --fire-and-forget .*Your worker w1' || fail "the interrupted lead was not told about its worker"
  pass "a lead busy mid-turn is interrupted, then told its worker is blocked"
}

test_lead_stuck_on_a_prompt_reaches_the_board() {
  local m
  m=$(home lead-prompt)
  lead_meta "$m" lead1 1 "$m/lead-home"
  printf '%s\n' "$TRUST" > "$m/panes/1"
  PANES=1 cycle "$m"
  grep -q '^stale: fake:1 (permission prompt: claude launch trust dialog; path -; not answered: a trust dialog is never auto-approved)' "$m/events" \
    || fail "Main was not woken at first sight of the lead's prompt: $(cat "$m/events")"
  [ -f "$m/state/.wait-sources/lead1.prompt" ] || fail "the prompt was not handed to the chain"
  backdate "$m" lead1 10
  PANES=1 cycle "$m"
  grep -q 'check: waiting-state lead1 (prompt, .*level=main' "$m/events" || fail "the lead's prompt did not reach Main's rung: $(cat "$m/events")"
  PANES=1 cycle "$m"
  grep -q -- '--key waiting-timer-[0-9a-f]*-lead1-g[0-9]*-prompt-card .*--title Unblock stuck lead? .*--guard security' "$m/cards" \
    || fail "the lead's prompt did not become a guarded board card: $(cat "$m/cards" 2>&1)"
  [ "$(grep -c "stale: fake:1 (permission prompt" "$m/events")" -eq 1 ] || fail "the gate re-alerted instead of the chain"
  printf 'all quiet\n> \n' > "$m/panes/1"
  PANES=1 cycle "$m"
  PANES=1 cycle "$m"
  grep -q '^dismiss waiting-timer-.*-lead1-.*-prompt-card' "$m/cards" || fail "the card stayed after the prompt was answered"
  [ ! -e "$m/state/.waiting-timers/lead1" ] || fail "the episode outlived the prompt"
  pass "a lead stuck on a prompt wakes Main at once, reaches Main's rung, then a board card that closes when it clears"
}

test_dead_lead_still_reaches_the_board_and_relaunch_represents() {
  local m l f
  m=$(home dead-main)
  lead_meta "$m" lead1 1 "$m/lead-home"
  overdue_report "$m" lead1 w1 100
  PANES='' cycle "$m"
  grep -q '^jg-send lead1 .*Your worker w1' "$m/sent" || fail "a dead lead got no durable steer"
  ! grep -q '^jg-control' "$m/sent" || fail "a dead lead was interrupted"
  grep -q -- '--key waiting-timer-0000aaaa-w1-.*-q-card' "$m/cards" 2>/dev/null \
    || fail "a dead lead's stuck worker never reached the board: $(cat "$m/cards" 2>&1)"
  # The relaunched lead re-presents its open waits on its first cycle.
  l=$(home dead-lead)
  printf 'lead1\n' > "$l/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$m" > "$l/.jg-squad-lead-parent"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$l/state/w1.meta"
  printf 'needs-decision [key=q]: pick a database\n' > "$l/state/w1.status"
  prime_status_seen "$l/state" "$l/state/w1.status"
  printf 'session-one\n' > "$l/state/.lock-session"
  PANES=1 cycle "$l"
  backdate "$l" w1 10
  PANES=1 cycle "$l"
  backdate "$l" w1 10
  PANES=1 cycle "$l"
  f="$m/state/lead1.status"
  [ "$(grep -c 'waiting-timer-overdue: w1 ' "$f")" -eq 2 ] || fail "the lead did not report its overdue worker: $(cat "$f")"
  : > "$l/events"
  printf 'session-two\n' > "$l/state/.lock-session"
  PANES=1 cycle "$l"
  [ "$(grep -c 'waiting-timer-overdue: w1 ' "$f")" -eq 3 ] || fail "the relaunched lead did not re-report its stuck worker to Main: $(cat "$f")"
  grep -q 'check: waiting-state w1 (needs-decision key=q, .*level=owner; still open, owning lead must recheck' "$l/events" \
    || fail "the relaunched lead was not re-presented its stuck worker in one cycle: $(cat "$l/events")"
  pass "a dead lead's stuck worker still reaches the board, and after relaunch the lead re-presents it within one cycle"
}

test_lead_supervision_not_running_is_a_main_wait() {
  local m lh
  m=$(home sup-main)
  lh="$m/lead-home"
  mkdir -p "$lh/state"
  printf 'kind=ship\n' > "$lh/state/child.meta"
  lead_meta "$m" lead1 1 "$lh"
  LIVENESS=1 PANES=1 cycle "$m"
  grep -q 'check: squad_lead lead1 supervision not running' "$m/events" || fail "a lead with work and no watcher was not a Main event: $(cat "$m/events") $(cat "$m/err")"
  grep -q '^jg-send lead1 --fire-and-forget .*Re-arm your supervision' "$m/sent" || fail "the lead was not told to re-arm"
  backdate "$m" lead1 10
  LIVENESS=1 PANES=1 cycle "$m"
  grep -q 'check: waiting-state lead1 (supervision, .*level=main' "$m/events" || fail "the dead hop did not escalate on the chain: $(cat "$m/events")"
  touch "$lh/state/.last-watcher-beat"
  LIVENESS=1 PANES=1 cycle "$m"
  LIVENESS=1 PANES=1 cycle "$m"
  [ ! -e "$m/state/.wait-sources/lead1.supervision" ] || fail "the wait stayed after the lead's watcher came back"
  [ ! -e "$m/state/.waiting-timers/lead1" ] || fail "the episode stayed after the lead's watcher came back"
  pass "a lead whose own supervision is down is a Main wait that escalates until its watcher is back"
}

test_worker_dead_prompt_and_question_differ() {
  local m
  m=$(home worker-kinds)
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nharness=claude\n' > "$m/state/wp.meta"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:2\nharness=claude\n' > "$m/state/wq.meta"
  printf 'kind=ship\nbackend=tmux\nwindow=fake:3\nharness=claude\n' > "$m/state/wd.meta"
  printf '%s\n' "$TRUST" > "$m/panes/1"
  printf 'needs-decision [key=q]: pick a database\n' > "$m/state/wq.status"
  : > "$m/state/wp.status"; : > "$m/state/wd.status"
  for f in wp wq wd; do prime_status_seen "$m/state" "$m/state/$f.status"; done
  # A prompt recorded before the worker died is no longer seen by the gate.
  mkdir -p "$m/state/.wait-sources"
  printf 'prompt: claude launch trust dialog; path -\n' > "$m/state/.wait-sources/wd.prompt"
  touch -d '-10 minutes' "$m/state/.wait-sources/wd.prompt"
  PANES='1 2' cycle "$m"
  grep -q '^stale: fake:1 (permission prompt' "$m/events" || fail "a worker on a prompt did not wake Main at first sight"
  backdate "$m" wq 10
  PANES='1 2' cycle "$m"
  grep -q 'check: waiting-state wq (needs-decision key=q, .*level=owner' "$m/events" || fail "an open question did not reach its owner: $(cat "$m/events")"
  PANES='1 2' cycle "$m"
  ! grep -q 'waiting-state wd ' "$m/events" || fail "a dead worker's lapsed prompt rode the chain"
  [ ! -e "$m/state/.waiting-timers/wd" ] || fail "a dead worker kept a wait episode"
  pass "a prompt wakes Main at first sight, an open question rides the owner rung, and a dead worker's old prompt lapses"
}

test_two_hops_stuck_at_once() {
  local m
  m=$(home two-hops)
  lead_meta "$m" lead1 1 "$m/lead-home"
  printf '%s\n' "$TRUST" > "$m/panes/1"
  overdue_report "$m" lead1 w1 100
  PANES=1 cycle "$m"
  backdate "$m" lead1 10
  PANES=1 cycle "$m"
  PANES=1 cycle "$m"
  grep -q -- '--key waiting-timer-[0-9a-f]*-lead1-.*-prompt-card' "$m/cards" || fail "the stuck lead got no card: $(cat "$m/cards" 2>&1)"
  grep -q -- '--key waiting-timer-0000aaaa-w1-.*-q-card' "$m/cards" || fail "its stuck worker got no card: $(cat "$m/cards" 2>&1)"
  pass "a lead stuck on a prompt and its stuck worker each reach the board"
}

test_main_absent_board_card_still_fires() {
  local m
  m=$(home main-absent)
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\nharness=claude\n' > "$m/state/w1.meta"
  printf 'blocked [key=dep]: waiting on the vendor\n' > "$m/state/w1.status"
  prime_status_seen "$m/state" "$m/state/w1.status"
  PANES=1 cycle "$m" absent
  backdate "$m" w1 10
  PANES=1 cycle "$m" absent
  PANES=1 cycle "$m" absent
  PANES=1 cycle "$m" absent
  grep -q 'level=main' "$m/events" || fail "Main's rung never fired: $(cat "$m/events")"
  grep -q -- '--key waiting-timer-[0-9a-f]*-w1-.*-dep-card' "$m/cards" || fail "no card while Main was absent: $(cat "$m/cards" 2>&1) $(cat "$m/err")"
  [ -s "$m/state/.wake-queue" ] || fail "the fixture did not keep Main's wakes unread"
  pass "with Main absent and its wakes unread, the board card still fires"
}

test_lead_idle_is_steered_without_interrupt
test_busy_lead_is_interrupted_first
test_lead_stuck_on_a_prompt_reaches_the_board
test_dead_lead_still_reaches_the_board_and_relaunch_represents
test_lead_supervision_not_running_is_a_main_wait
test_worker_dead_prompt_and_question_differ
test_two_hops_stuck_at_once
test_main_absent_board_card_still_fires
