#!/usr/bin/env bash
# End-to-end: replay 16 Oct's Claude readings through the real check in its file-argument mode, then drive install.sh
# against a throwaway firstmate home and HOME. Usage: claude-quota/tests/claude-quota.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/data TMPDIR=$d CQ_MARK=$d/mark CQ_HIST=$d/hist
FM=$d/fm
mkdir -p "$HOME" "$FM/state" "$FM/bin"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else printf 'FAIL: %s\n  want text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
# quota-axi --json shape; arguments: 5 h % left, minutes to its reset, week % left.
reading() {
  python3 -I -c 'import json,sys,datetime as D
n=D.datetime.now(D.timezone.utc); iso=lambda m: (n+D.timedelta(minutes=m)).isoformat()
print(json.dumps({"providers":[{"provider":"claude","windows":[
  {"id":"five_hour","percentRemaining":int(sys.argv[1]),"resetsAt":iso(int(sys.argv[2]))},
  {"id":"seven_day","percentRemaining":int(sys.argv[3]),"resetsAt":iso(8000)}]}]}))' "$@" > "$d/q.json"
}

# (a) Replay. The week readings are 16 Oct's 14 burn-rate wakes from Main's supervision log (79% -> 53%), each of
# which woke Main, then the next readings in state/.claude-quota.hist. The 5 h readings and the week tail under 45%
# are made up: no log keeps them. The history starts at 98% 4 h back (16 Oct 02:57-07:05Z went 98% -> 87%), so the
# burn rate stays above the old rule's line all replay. Each row: label, 5 h %, min to 5 h reset, week %.
echo "$(($(date +%s) - 14400)) 98" > "$CQ_HIST"
wakes='' five_low='' week_out=''
while read -r label fp mins wp; do
  reading "$fp" "$mins" "$wp"
  out=$("$SRC/claude-quota.check.sh" "$d/q.json")
  [ -z "$out" ] || wakes="$wakes $label"
  [ "$label" != 5h-low ] || five_low=$out
  [ "$label" != week-40 ] || week_out=$out
done <<'ROWS'
w79 90 280 79
w76 85 250 76
w75 80 230 75
w73 72 200 73
w70 66 170 70
w69 60 150 69
w67 54 120 67
w65 47 100 65
w63 41 80 63
w63b 37 70 63
w59 100 299 59
w58 91 270 58
5h-34 34 120 55
5h-31 31 100 55
5h-28 28 80 53
5h-late 22 50 53
w52 100 299 52
w45 80 240 45
w41 70 200 41
week-40 70 200 40
week-39 60 180 39
w37 50 150 37
5h-low 30 90 33
w29 90 280 29
ROWS
check "a: wakes only on the 5 h rule and the first reading at or under 40% left (41 quiet, 40 once, no second at 39)" "$wakes" " 5h-34 5h-28 week-40 5h-low"
has "a: the week wake names the action" "$week_out" "At or under 40% left: no new Opus build workers; leads move build work to the GLM/Go mix"
has "a: ... with the burn rate" "$week_out" "burning "
has "a: Main reports to the captain" "$week_out" "Main reports this to the captain"
check "a: the week wake is one line" "$(printf '%s\n' "$week_out" | wc -l)" 1
has "a: a 5 h wake under 40% is the 5 h line" "$five_low" "Claude 5 h window 30% left"
check "a: ... alone (no second week line)" "$(printf '%s\n' "$five_low" | wc -l)" 1

# (b) install --dry-run: prints the steps, writes nothing.
# shellcheck disable=SC2016 # expands in the stub, not here
printf '#!/bin/sh\necho "$FM_HOME|${FM_STATE_OVERRIDE-unset}|$*" >> "%s/register.calls"\n' "$d" > "$FM/bin/fm-check-register.sh"
chmod +x "$FM/bin/fm-check-register.sh"
printf '#!/usr/bin/env bash\necho old check\n' > "$FM/state/claude-quota.check.sh"
chmod 700 "$FM/state/claude-quota.check.sh"
before=$(find "$d" | sort)
out=$("$SRC/install.sh" --dry-run "$FM")
has "b: dry run names the backup" "$out" "would back up: $FM/state/claude-quota.check.sh -> $FM/state/claude-quota.check.sh.bak-claude-quota-"
has "b: dry run names the register" "$out" "would run: $FM/bin/fm-check-register.sh claude-quota"
check "b: dry run wrote nothing" "$(find "$d" | sort)" "$before"

# (c) install: backs up the old check, writes the exec shim (mode 700), re-registers with FM_STATE_OVERRIDE dropped.
export FM_STATE_OVERRIDE=
"$SRC/install.sh" "$FM" > /dev/null
check "c: old check backed up" "$(cat "$FM"/state/claude-quota.check.sh.bak-claude-quota-*)" "$(printf '#!/usr/bin/env bash\necho old check')"
check "c: shim mode" "$(stat -c %a "$FM/state/claude-quota.check.sh")" 700
check "c: registered once, override dropped" "$(cat "$d/register.calls")" "$FM|unset|claude-quota"
rm -f -- "$CQ_MARK"
reading 30 90 33
check "c: the shim runs the installed check" "$("$FM/state/claude-quota.check.sh" "$d/q.json" | wc -l)" 2
"$SRC/install.sh" "$FM" > /dev/null
check "c: rerun makes no second backup" "$(find "$FM/state" -name '*.bak-claude-quota-*' | wc -l)" 1
check "c: rerun registers again" "$(wc -l < "$d/register.calls")" 2

[ "$fails" -eq 0 ] && echo "all claude-quota checks passed" || { echo "$fails check(s) failed"; exit 1; }
