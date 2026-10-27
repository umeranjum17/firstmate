#!/usr/bin/env bash
# A re-install is a no-op, not an error: two add-on pairs share one hook file and each used to refuse the other's
# re-chain. Real installers, three runs, one throwaway home: every run succeeds, the chain settles, both sides run.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-install-all.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

home=$tmp/home
mkdir -p "$home/config" "$home/bin" "$home/state" "$home/data" "$tmp/user"
export HOME=$tmp/user
export XDG_DATA_HOME=$HOME/.local/share XDG_CONFIG_HOME=$HOME/.config
# Keep the guard's global hooks path inside the fixture, never the runner's real git configuration.
export GIT_CONFIG_GLOBAL=$HOME/.gitconfig GIT_CONFIG_SYSTEM=/dev/null
printf '[user]\n\tname = Fixture Owner\n\temail = fixture@example.invalid\n' >"$GIT_CONFIG_GLOBAL"

# The four installers that fight over the two hook files, in install-all.sh's order.
install_pairs() {  # install_pairs <round>
  local round=$1 addon
  for addon in git-identity pane-titles owner-guard owner-rules; do
    bash "$here/$addon/install.sh" "$home" >"$tmp/$round-$addon.log" 2>&1 || {
      printf 'not ok - %s failed on run %s:\n' "$addon" "$round" >&2
      cat "$tmp/$round-$addon.log" >&2
      exit 1
    }
  done
}

chain_state() {  # chain_state: every chain file's content digest, in a fixed order
  local f
  for f in "$home/config/launch-env-hook" \
    "$XDG_DATA_HOME/fm-pane-titles/previous-launch-env-hook" \
    "$home/config/merge-gate" \
    "$home/config/merge-gate.pre-owner-rules" \
    "$home/config/merge-gate.pre-owner-guard"; do
    if [ -e "$f" ]; then printf '%s %s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "${f#"$tmp"/}"; fi
  done
  return 0
}

install_pairs one
install_pairs two
chain_after_two=$(chain_state)
install_pairs three

[ "$(chain_state)" = "$chain_after_two" ] || {
  printf 'not ok - a repeat install changed the hook chains:\n' >&2
  diff <(printf '%s\n' "$chain_after_two") <(chain_state) >&2 || true
  exit 1
}
printf 'ok - a repeat install succeeds and settles the two shared hook files\n'

# A repeat install adds no files either: the backup a chained hook earns is kept once, not once per run.
count_backups() { local n=0 f; for f in "$home/config"/launch-env-hook.bak-git-identity-*; do [ -e "$f" ] && n=$((n + 1)); done; printf '%s\n' "$n"; }
backups=$(count_backups)
install_pairs four
[ "$(count_backups)" -eq "$backups" ] ||
  { printf 'not ok - a repeat install added another hook backup\n' >&2; exit 1; }
printf 'ok - a repeat install adds no hook backup\n'

# Both sides of each pair still run: pane-titles' shim execs the launcher, and walking the merge gate's
# chained prev= links reaches both gates without ever revisiting a file. A repeat install that re-chained a
# gate already in the chain would close a loop here, and the merge gate would exec itself forever.
if ! grep -q 'fm-pane-titles/launch-env-hook' "$home/config/launch-env-hook"; then
  printf 'not ok - the launch-env hook no longer runs pane-titles\n' >&2
  exit 1
fi
gate=$home/config/merge-gate
seen=' '
found_guard=0 found_rules=0
depth=0
while [ -e "$gate" ] && [ "$depth" -lt 8 ]; do
  case $seen in
    *" $gate "*) printf 'not ok - the merge gate chains back to %s: it would exec itself forever\n' "$gate" >&2; exit 1 ;;
  esac
  seen="$seen$gate "
  if grep -q 'fm-owner-guard' "$gate"; then found_guard=1; fi
  if grep -q 'fm-owner-rules-gate.sh' "$gate"; then found_rules=1; fi
  gate=$(sed -n 's/^prev=//p' "$gate" | head -1)
  [ -n "$gate" ] || break
  depth=$((depth + 1))
done
[ "$found_guard" -eq 1 ] && [ "$found_rules" -eq 1 ] ||
  { printf 'not ok - the merge gate lost a side (owner-guard=%s owner-rules=%s)\n' "$found_guard" "$found_rules" >&2; exit 1; }
printf 'ok - both sides of each shared hook file still run, and the merge gate chain has no loop\n'

printf '%s\n' "PASS install-all re-install is a no-op"
