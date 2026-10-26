#!/usr/bin/env bash
# bin/jg-backend-hometag-lib.sh - shared per-installation home-tag derivation
# for session-provider backends whose container has ONE namespace shared by
# every juggernaut home on the machine, with no native per-home split (cmux's
# one app-global workspace list, zellij's one shared "juggernaut" session's
# tab bar). Without a per-home discriminator embedded in the actual
# title/name, two juggernaut homes (two squad_leads, a primary plus a
# squad_lead, or two independent primary installations) whose task ids
# happen to collide can send/peek/close each other's tabs - the gap a
# captain-directed no-mistakes review gate caught for cmux
# (docs/cmux-backend.md) and this same tag mechanism was later ported to
# zellij to close for the same reason (docs/zellij-backend.md "Home-scoped
# tab titles").
#
# jg_backend_hometag() derives a short, stable tag: a readable prefix
# ("juggernaut" for the primary home, "2ndmate-<id>" for a squad_lead home
# carrying .jg-squad-lead-home) plus a short hash of the resolved JG_ROOT
# path, so distinct installations - including multiple primaries on one
# machine - never collide even though they share one backend-global
# namespace. Callers source this file AFTER resolving their own
# JG_HOME/JG_ROOT fallbacks (both adapters already do this for their own
# purposes before any other function runs).
#
# Moving/relocating a juggernaut installation changes its JG_ROOT path and
# therefore its tag; titles created under the old tag simply stop matching -
# an accepted limitation, no worse than the existing fact that a task's
# recorded absolute worktree path does not survive a move either.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
. "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"

JG_BACKEND_HOMETAG_SQUAD_LEAD_MARKER=".jg-squad-lead-home"

jg_backend_hometag() {
  local marker id prefix root hash
  marker=$(jg_compat_marker "$JG_HOME")
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="2ndmate-$id"
    else
      prefix="juggernaut"
    fi
  else
    prefix="juggernaut"
  fi
  root=$(cd "$JG_ROOT" 2>/dev/null && pwd -P) || root=$JG_ROOT
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$root" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s-%s' "$prefix" "$hash"
}
