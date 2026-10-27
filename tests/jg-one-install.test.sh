#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# install.sh as one command: pinned installs, write-once defaults that survive the tool wiring, a no-op
# second run, and one row changed feeding every install path.
# The real install.sh, bin/jg-pin-lib.sh, bin/jg-bootstrap.sh and bin/jg-tool-wiring.sh run in a throwaway
# HOME with a stub npm, stub gh, and pre-placed curl-installed tools: no network, no system prefix, no real
# login touched. Every version this journey asserts is read from the pin table, never spelled here, so a
# bump moves the proof with the table instead of turning this script red.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/jg-one-install-test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export HOME=$work/h XDG_DATA_HOME=$work/h/.local/share XDG_CONFIG_HOME=$work/h/.config \
  XDG_CACHE_HOME=$work/h/.cache npm_config_cache=$work/npm-cache
export NPM_LOG=$work/npm.log JG_PIN_FILE_OVERRIDE=$work/pins
: > "$NPM_LOG"
mkdir -p "$work/stub" "$HOME"
fail() { printf 'fail: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }
pin() { awk -v t="$1" '$1 == t { v = $2; sub(/.*@/, "", v); print v }' "$JG_PIN_FILE_OVERRIDE"; }
bumped() { printf '%s\n' "$(pin "$1")" | awk -F. '{ $NF = $NF + 1 } 1' OFS=.; }

# A stub npm that records argv, answers `root -g`, and installs one bin printing the requested version.
# Installing done-done-axi also lays down the package tree the real one ships, because that is what makes
# bin/jg-bootstrap.sh wire done-done's own managed block into the home's config/brief-include.md.
cat > "$work/stub/npm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NPM_LOG"
[ "${1:-}" = root ] && { printf '%s\n' "$NPM_CONFIG_PREFIX/lib/node_modules"; exit 0; }
[ "${1:-}" = install ] || exit 0
spec= bins=
for a in "$@"; do case $a in install|-g) ;; *) spec=$a ;; esac; done
pkg=${spec%@*}; ver=${spec##*@}
case $pkg in
  */accounts) bins=byokit-accounts ;;
  done-done-axi) bins='done-done done-done-axi' ;;
  lookout-axi) bins='lookout lookout-axi' ;;
  *) bins=${pkg##*/} ;;
esac
mkdir -p "$NPM_CONFIG_PREFIX/bin"
for bin in $bins; do
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo %s; exit 0; }\nexit 0\n' "$ver" > "$NPM_CONFIG_PREFIX/bin/$bin"
  chmod +x "$NPM_CONFIG_PREFIX/bin/$bin"
done
if [ "$pkg" = done-done-axi ]; then
  dd=$NPM_CONFIG_PREFIX/lib/node_modules/done-done-axi
  mkdir -p "$dd/skills/done-done" "$dd/integrations/juggernaut"
  printf '# done-done\n' > "$dd/skills/done-done/SKILL.md"
  printf '%s\n' 'Seal evidence with done-done before reporting done.' > "$dd/integrations/juggernaut/brief-include.md"
  printf '#!/bin/sh\nexit 0\n' > "$dd/integrations/juggernaut/merge-gate"
  chmod +x "$dd/integrations/juggernaut/merge-gate"
fi
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$work/stub/gh"
chmod +x "$work/stub/npm" "$work/stub/gh"
# A PATH of stub, the system tools install.sh itself needs, and node only: the host's own copies of the
# pinned tools must stay invisible, or this journey would prove the host instead of the installer.
mkdir -p "$work/sys"
ln -s "$(command -v node)" "$work/sys/node"
export PATH=$work/stub:$work/sys:/usr/bin:/bin

# The curl-installed rows are already present at their floor, so this journey stays offline. They sit in
# the prefix install.sh installs into - ~/.local/bin of the throwaway HOME, which is also the prefix
# bin/jg-bootstrap.sh uses - so this is where every assertion below looks for an installed tool.
bin=$HOME/.local/bin
mkdir -p "$bin"
for t in no-mistakes treehouse; do
  v=$(awk -v t="$t" '$1 == t { print $2 }' "$ROOT/toolchain.versions")
  printf '#!/bin/sh\necho %s\n' "$v" > "$bin/$t"; chmod +x "$bin/$t"
done

# A local edit to the table is what a bump does, so the journey runs against a copy of it.
grep -E '^[^#]' "$ROOT/toolchain.versions" > "$JG_PIN_FILE_OVERRIDE"

out=$(bash "$ROOT/install.sh" --home "$work/home" 2>&1) || fail "first run exited nonzero: $out"
while read -r spec; do
  grep -q "install -g $spec" "$NPM_LOG" || fail "first run did not install $spec"
done < <(awk 'NF == 2 && $2 ~ /@[0-9]/ { print $2 }' "$JG_PIN_FILE_OVERRIDE")
for tool in done-done sign-off-axi first-draft-axi lookout-axi byokit-accounts quota-axi; do
  want=$(pin "$tool")
  got=$("$bin/$tool" --version) || fail "no $tool installed"
  [ "$got" = "$want" ] || fail "$tool is $got, pin table says $want"
done
[ -f "$work/home/config/brief-include.md" ] || fail "defaults: no config/brief-include.md written"
[ -f "$work/home/data/owner-rules.md" ] || fail "defaults: no data/owner-rules.md written"
printf '%s\n' "$out" | grep -q 'needs you: gh auth login' || fail "no gh auth line for an unauthenticated gh"
pass "one command installs the pinned set and writes the defaults"

# The defaults land before the tool wiring, so a fresh home keeps our rules AND done-done's own block.
# Written the other way round, installing done-done creates config/brief-include.md first and our rules
# are silently skipped as an existing file.
grep -qF 'Integration and end-to-end tests only' "$work/home/config/brief-include.md" \
  || fail "the tool wiring displaced our own brief-include defaults"
grep -qF 'Seal evidence with done-done' "$work/home/config/brief-include.md" \
  || fail "done-done's managed brief-include block is missing"
[ -x "$work/home/config/merge-gate" ] || fail "done-done's merge gate was not placed in the home"
pass "our defaults and the tool's own managed block both survive on a fresh home"

# A second run changes nothing, and never overwrites a file the user edited.
printf 'my own rule\n' >> "$work/home/config/brief-include.md"
before=$(wc -c < "$NPM_LOG")
out=$(bash "$ROOT/install.sh" --home "$work/home" 2>&1) || fail "second run exited nonzero: $out"
[ "$(wc -c < "$NPM_LOG")" = "$before" ] || fail "second run installed something: $(tail -n +1 "$NPM_LOG")"
grep -q '^my own rule$' "$work/home/config/brief-include.md" || fail "second run overwrote an edited default"
printf '%s\n' "$out" | grep -q "have $(pin done-done)" || fail "second run did not report an already-pinned tool"
pass "a second run is a no-op and leaves edited defaults alone"

# Changing one row changes what the install paths install: install.sh, then bootstrap's own installer.
dd_next=$(bumped done-done) quota_next=$(bumped quota-axi)
sed -i "s/^done-done done-done-axi@.*/done-done done-done-axi@$dd_next/" "$JG_PIN_FILE_OVERRIDE"
sed -i "s/^quota-axi quota-axi@.*/quota-axi quota-axi@$quota_next/" "$JG_PIN_FILE_OVERRIDE"
bash "$ROOT/install.sh" --home "$work/home" >/dev/null 2>&1 || fail "run after the bump exited nonzero"
grep -q "install -g done-done-axi@$dd_next" "$NPM_LOG" || fail "install.sh ignored the changed done-done row"
[ "$("$bin/done-done" --version)" = "$dd_next" ] || fail "done-done did not move to the new pin"
bash "$ROOT/bin/jg-bootstrap.sh" install quota-axi >/dev/null 2>&1 || fail "bootstrap install exited nonzero"
grep -q "install -g quota-axi@$quota_next" "$NPM_LOG" || fail "bootstrap install ignored the changed quota-axi row"
# Both paths install into one prefix: bootstrap's own install replaced the build install.sh had put there,
# rather than leaving a second copy in another directory for PATH order to choose between.
[ "$("$bin/quota-axi" --version)" = "$quota_next" ] || fail "bootstrap installed quota-axi outside install.sh's prefix"
pass "one changed row moves both install paths, install.sh and bin/jg-bootstrap.sh, into one prefix"
