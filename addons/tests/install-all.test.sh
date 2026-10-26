#!/usr/bin/env bash
# A re-install must be a no-op, not an error. Two add-on pairs share one hook file - git-identity and
# pane-titles chain config/launch-env-hook, owner-guard and owner-rules chain config/merge-gate - and each
# pair used to refuse the other side's re-chain on the second run. This runs the real installers three
# times over one throwaway home and proves every run succeeds, the chain settles, and no side stops running.
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
    [ -e "$f" ] && printf '%s %s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "${f#"$tmp"/}"
  done
}

install_pairs one
install_pairs two
chain_after_two=$(chain_state)
install_pairs three

[ "$(chain_state)" = "$chain_after_two" ] || {
  printf 'not ok - the third run changed the hook chains:\n' >&2
  diff <(printf '%s\n' "$chain_after_two") <(chain_state) >&2 || true
  exit 1
}
printf 'ok - a repeated install succeeds and settles the two shared hook files\n'

# Both sides of each pair still run: pane-titles' shim execs the launcher, and the owner-rules gate is
# reachable from whatever head the merge gate chains.
grep -q 'fm-pane-titles/launch-env-hook' "$home/config/launch-env-hook" ||
  { printf 'not ok - the launch-env hook no longer runs pane-titles\n' >&2; exit 1; }
gate=$home/config/merge-gate
depth=0
while [ -e "$gate" ] && [ "$depth" -lt 8 ]; do
  grep -q 'fm-owner-rules-gate.sh' "$gate" && break
  gate=$(sed -n 's/^prev=//p' "$gate" | head -1)
  [ -n "$gate" ] || break
  depth=$((depth + 1))
done
grep -q 'fm-owner-rules-gate.sh' "$gate" 2>/dev/null ||
  { printf 'not ok - the merge gate no longer runs the owner-rules gate\n' >&2; exit 1; }
printf 'ok - both sides of each shared hook file still run after the repeated installs\n'

printf '%s\n' "PASS install-all re-install is a no-op"
