#!/usr/bin/env bash
# jg-stuck-gate-lib.sh - deterministic stuck-worker detectors for jg-watch.sh.
# Sourced by the watcher, which supplies STATE, hash_pane, age_of and the
# window helpers. Each detector records a wait source
# (state/.wait-sources/<task>.<source>, rewritten on every sighting and removed
# once the cause is gone) and addons/wait-timers/README.md owns the ladder that
# climbs from there: worker's lead, Main, then a board card, again every
# interval while the source stays. No model decides any step.
#
#   question  a picker or question dialog on screen (Pi ask_user_question,
#             Claude AskUserQuestion, OpenCode question, Codex request_user_input),
#             whatever status the terminal shows for the pane
#   quota     a provider rate-limit or usage-limit banner at the bottom of the pane
#   silent    no status line and no pane change for JG_SILENT_SECS (default 900),
#             whatever the worker last declared; a future-dated pause and a
#             running validation are exempt

# jg_stuck_verdict: read a pane capture on stdin; print "question|quota <TAB>
# <line>" for the first stuck cause on screen, or nothing. Text signatures are
# harness-neutral so a new adapter is covered; every picker pairs a select/
# confirm hint with an escape hint, so worker prose alone does not match.
jg_stuck_verdict() {
  local buf tail12 line
  buf=$(cat)
  tail12=$(printf '%s\n' "$buf" | grep -v '^[[:space:]]*$' | tail -12)
  line=$(printf '%s\n' "$tail12" | grep -iE "${JG_STUCK_QUOTA_REGEX:-(you.ve hit your|usage limit|rate.?limit(ed| exceeded| reached)|quota (exceeded|exhausted|reached)|insufficient[_ ]quota|too many requests|credit balance is too low|limit resets)}" | head -1) || true
  if [ -n "$line" ]; then
    printf 'quota\t%s\n' "$(printf '%s' "$line" | tr -s '[:space:]' ' ' | cut -c1-200)"
    return 0
  fi
  if printf '%s\n' "$tail12" | grep -qiE '(enter|return)[^a-z]+(to )?(select|confirm|submit|choose)|(select|confirm|submit|choose)[^a-z]+(enter|return)' \
    && printf '%s\n' "$tail12" | grep -qiE 'esc[^a-z]+(to )?(cancel|dismiss|go back|back|skip|interrupt)|(cancel|dismiss|back)[^a-z]+esc'; then
    line=$(printf '%s\n' "$tail12" | grep -iE 'esc' | tail -1)
    printf 'question\t%s\n' "$(printf '%s' "$line" | tr -s '[:space:]' ' ' | cut -c1-200)"
  fi
}

# stuck_source_set: record or clear one watcher-written wait source.
stuck_source_set() {  # <task> <source> [text]
  local src="$STATE/.wait-sources/$1.$2"
  if [ -z "${3-}" ]; then rm -f "$src"; return 0; fi
  mkdir -p "$STATE/.wait-sources" && printf '%s: %s\n' "$2" "$3" > "$src" || exit 1
}

# stuck_gate_check: one poll of one window. <tail40> is its capture.
stuck_gate_check() {  # <window> <task> <key> <tail40> <kind>
  local w=$1 task=$2 key=$3 tail40=$4 kind=$5 verdict h seen last declared until okf
  [ -n "$task" ] || return 0
  verdict=$(printf '%s' "$tail40" | jg_stuck_verdict)
  stuck_source_set "$task" question ''
  stuck_source_set "$task" quota ''
  case "$verdict" in
    question$'\t'*) stuck_source_set "$task" question "${verdict#*$'\t'}" ;;
    quota$'\t'*) stuck_source_set "$task" quota "${verdict#*$'\t'}" ;;
  esac
  # Silence: a pane text change (spinner glyphs and counters ignored) or a
  # status line is progress. An idle lead is healthy by design.
  seen="$STATE/.silent-seen-$key"
  h=$(printf '%s' "$tail40" | LC_ALL=C tr -d '0-9' | LC_ALL=C tr -cd '[:print:]\n' | hash_pane)
  if [ "$(cat "$seen" 2>/dev/null)" != "$h" ]; then printf '%s' "$h" > "$seen"; fi
  stuck_source_set "$task" silent ''
  [ "$kind" != squad_lead ] || return 0
  last=$(last_status_line "$STATE/$task.status")
  case "$(status_line_verb "$last")" in done | failed) return 0 ;; esac
  [ "$(age_of "$seen")" -ge "${JG_SILENT_SECS:-900}" ] && [ "$(age_of "$STATE/$task.status")" -ge "${JG_SILENT_SECS:-900}" ] || return 0
  [ "$(age_of "$STATE/$task.progress")" -ge "${JG_SILENT_SECS:-900}" ] || return 0
  declared=$(status_declared_wait_line "$STATE/$task.status")
  if status_is_paused "$declared" && until=$(status_paused_until "$declared") && [ "$(date +%s)" -lt "$until" ]; then return 0; fi
  # A running validation sits on one screen by design; the proof costs a state
  # read, so it is taken at most once a minute.
  okf="$STATE/.silent-working-$key"
  if [ -f "$okf" ] && [ "$(age_of "$okf")" -lt 60 ]; then
    [ ! -s "$okf" ] || return 0
  else
    if crew_is_provably_working "$task"; then printf 'working' > "$okf"; return 0; fi
    : > "$okf"
  fi
  stuck_source_set "$task" silent "no status line or pane change for $(age_of "$seen")s"
}
