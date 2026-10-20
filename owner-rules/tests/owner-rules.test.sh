#!/usr/bin/env bash
# owner-rules e2e: the real fm-brief.sh of a firstmate checkout that carries the brief-inherit seam.
# Usage: owner-rules/tests/owner-rules.test.sh <firstmate-checkout>
# Proves a no-owner-ask refusal, a no-risk-reason refusal and a clean pass (brief written), plus the
# exemptions and the no-op when the add-on is not installed.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
FM=${1:-}
[ -n "$FM" ] && [ -x "$FM/bin/fm-brief.sh" ] && grep -q fm_brief_inherit_shared "$FM/bin/fm-brief.sh" \
  || { echo "usage: $0 <firstmate-checkout with the brief-inherit seam>" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/owner-rules-e2e.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
export HOME=$work/user XDG_DATA_HOME=$work/data
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }

home=$work/home; mkdir -p "$home/config" "$home/data" "$home/state"
cat > "$home/data/backlog.md" <<'BL'
# Backlog

## In flight
- [ ] with-ask - [captain-ask] Ship a thing (repo: sample) (kind: ship)
  A body line.
- [ ] with-main - Plain title (repo: sample) (kind: ship)
  type: Main7 asked for this.
- [ ] no-ask - Plain title (repo: sample) (kind: ship)
  Nothing names an owner.
- [ ] risky - [captain-ask] Rotate keys (repo: sample) (kind: ship)
  risk: security
- [ ] two-risks - [captain-ask] Both (repo: sample) (kind: ship)
  risk: security
  risk: release
- [ ] bad-risk - [captain-ask] Not listed (repo: sample) (kind: ship)
  risk: because
## Done
- [x] with-ask-longer - Main9 something
BL
# brief <id> <args...>: stderr, then rc= on the last line.
brief() {
  local id=$1 out rc; shift
  out=$(FM_HOME=$home FM_ADDONS_DIR=$addons bash "$FM/bin/fm-brief.sh" "$id" sample "$@" 2>&1 >/dev/null); rc=$?
  printf '%s%src=%s\n' "$out" "${out:+$'\n'}" "$rc"
}
ASK='owner-rules: no owner ask: name the [captain-ask] item or the MainNNN order this lane serves (add it to the backlog item for no-ask)'
RISK='owner-rules: mode no-mistakes needs one listed risk reason (release, security, migration, large-change, shared-protocol) in the backlog item for with-ask; use direct-PR plus a done-done check'

# not installed: no check, even for an entry with no owner ask
is "not installed: no-ask lane is briefed" "$(brief no-ask --mode direct-PR | tail -1)" "rc=0"
rm -rf -- "$home/data/no-ask"

"$addons/owner-rules/install.sh" "$home" >/dev/null
is "refusal 1: no owner ask" "$(brief no-ask --mode direct-PR)" "$ASK
rc=1"
[ ! -e "$home/data/no-ask" ] && ok "refusal 1 wrote no brief" || no "refusal 1 left data/no-ask"
is "refusal 1: missing entry is also no owner ask" "$(brief ghost --mode direct-PR | tail -2 | head -1 | cut -c1-27)" "owner-rules: no owner ask: "
is "refusal 1: a scout still needs an owner ask" "$(brief no-ask --scout | tail -1)" "rc=1"
is "refusal 2: no-mistakes without a risk reason" "$(brief with-ask --mode no-mistakes)" "$RISK
rc=1"
[ ! -e "$home/data/with-ask" ] && ok "refusal 2 wrote no brief" || no "refusal 2 left data/with-ask"
is "refusal 2: two risk lines" "$(brief two-risks --mode no-mistakes | tail -1)" "rc=1"
is "refusal 2: unlisted reason" "$(brief bad-risk --mode no-mistakes | tail -1)" "rc=1"

is "pass: [captain-ask] title, direct-PR" "$(brief with-ask --mode direct-PR)" "rc=0"
[ -s "$home/data/with-ask/brief.md" ] && ok "pass wrote the brief" || no "pass wrote no brief"
is "pass: MainNNN in the body" "$(brief with-main --mode direct-PR)" "rc=0"
is "pass: no-mistakes with one listed risk" "$(brief risky --mode no-mistakes)" "rc=0"
is "pass: scout is exempt from the risk rule" "$(brief with-ask-longer --scout)" "rc=0"
is "pass: prefix id does not match a longer id" "$(brief with-ask --scout | tail -1)" "rc=1"
FM_HOME=$home FM_ADDONS_DIR=$addons FM_SECONDMATE_CHARTER=x bash "$FM/bin/fm-brief.sh" sm --secondmate --no-projects >/dev/null 2>&1 \
  && ok "pass: secondmate charter is exempt" || no "secondmate charter refused"

"$addons/owner-rules/uninstall.sh" "$home" >/dev/null
is "uninstalled: check is off again" "$(brief no-ask --mode direct-PR | tail -1)" "rc=0"

# the leads skill quotes each real refusal line (with $id / $what in place of the runtime value)
n=0
while IFS= read -r q; do
  n=$((n + 1))
  grep -qF -- "${q#owner-rules: }" "$addons/owner-rules/bin/fm-owner-rules-lib.sh" "$addons/owner-rules/bin/fm-owner-rules-gate.sh" \
    && ok "skill quote matches the code: ${q:0:40}" || no "skill quote not in lib or gate: $q"
done < <(grep '^owner-rules: ' "$addons/owner-rules/skill/SKILL.md")
is "skill quotes all four refusals" "$n" "4"

[ "$fails" -eq 0 ] && echo "PASS owner-rules" || { echo "FAIL owner-rules: $fails"; exit 1; }
