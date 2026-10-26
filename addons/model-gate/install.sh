#!/usr/bin/env bash
# Install model-gate for one firstmate home, or take it away with --remove: the gate on PATH, the allow-list, the
# opencode per-provider whitelist (so an off-list model is not even pickable there) and the fleet check that restores
# that whitelist and warns when an off-list model was used anyway. Idempotent; the allow-list file is never overwritten
# and never deleted. Usage: install.sh [--dry-run] [--remove]   (FM_HOME names the home that runs the check)
set -euo pipefail
dry=0 remove=0
for a in "$@"; do case $a in --dry-run) dry=1 ;; --remove) remove=1 ;; *) echo 'usage: install.sh [--dry-run] [--remove]' >&2; exit 2 ;; esac; done
FM_HOME=${FM_HOME:?set FM_HOME to the firstmate home that runs the check}
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/bin/fm-model-gate
share=${XDG_DATA_HOME:-$HOME/.local/share}/fm-model-gate
bin=$share/fm-model-gate
link=$HOME/.local/bin/fm-model-gate
list=${FM_MODEL_GATE_LIST:-$FM_HOME/config/model-allow-list.json}
check=$FM_HOME/state/model-gate.check.sh
say() { printf '%s %s\n' "$1" "$2"; }

if [ "$remove" = 1 ]; then
  "$src" opencode --remove
  if [ -e "$check" ] && [ -x "$FM_HOME/bin/fm-check-unregister.sh" ]; then
    [ "$dry" = 1 ] && say would-run "fm-check-unregister.sh model-gate" \
      || env -u FM_STATE_OVERRIDE FM_HOME="$FM_HOME" "$FM_HOME/bin/fm-check-unregister.sh" model-gate || true
  fi
  for f in "$check" "$link"; do
    [ -e "$f" ] || continue
    [ "$f" != "$link" ] || [ "$(readlink -f "$f")" = "$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")" ] || continue
    [ "$dry" = 1 ] && say would-remove "$f" || { rm -f -- "$f"; say removed "$f"; }
  done
  [ ! -d "$share" ] || { [ "$dry" = 1 ] && say would-remove "$share" || { rm -f -- "$bin"; rmdir -- "$share" 2>/dev/null; say removed "$share"; }; }
  say kept "$list"
  exit 0
fi

if [ -e "$bin" ] && cmp -s "$src" "$bin"; then say unchanged "$bin"; else
  [ "$dry" = 1 ] && say would-write "$bin" || { mkdir -p "$share"; install -m 755 "$src" "$bin"; say wrote "$bin"; }
fi
if [ "$(readlink -f "$link" 2>/dev/null)" = "$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")" ]; then say unchanged "$link"; else
  [ "$dry" = 1 ] && say would-link "$link -> $bin" || { mkdir -p "${link%/*}"; ln -sfn "$bin" "$link"; say linked "$link -> $bin"; }
fi
# One owner for the list: this file, seeded once. Then the provider layer, then the check that restores it and reports.
if [ -e "$list" ]; then say unchanged "$list"; else
  [ "$dry" = 1 ] && say would-write "$list" || { mkdir -p "${list%/*}"; printf '{\n  "ollama-cloud": ["deepseek-v4.1-flash"]\n}\n' > "$list"; say wrote "$list"; }
fi
if [ "$dry" = 1 ]; then "$src" opencode --dry-run; else "$src" opencode; fi
if [ "$dry" = 1 ]; then say would-install "$check"; else
  mkdir -p "$FM_HOME/state"
  install -m 700 "$src" "$check"
  say installed "$check"
  [ ! -x "$FM_HOME/bin/fm-check-register.sh" ] || "$FM_HOME/bin/fm-check-register.sh" model-gate
fi
