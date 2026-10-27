#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# install-all.sh - the one entry point that installs every add-on in this catalog for one fleet home.
#
# Usage: install-all.sh [--dry-run] <jg-home>        (JG_HOME may name the home instead)
#
# Each add-on keeps its own installer and its own contract: this script only runs them in a working order with the
# argument shape each documents, and names the add-ons that have no installer instead of inventing one. --dry-run
# reaches every installer that supports it. A rerun is a rerun of each installer's idempotent install and exits 0 when
# it lands the same wiring; two add-ons share `config/launch-env-hook` and two share `config/merge-gate`, so each keeps
# a chain that already runs it, and an installer that still refuses says so here by name.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

dry=0
home=${JG_HOME:-}
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    -h | --help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'install-all: unknown option %s\n' "$a" >&2; exit 2 ;;
    *)
      if [ -n "$home" ] && [ "$home" != "$a" ]; then
        printf 'install-all: one home per run (got %s and %s)\n' "$home" "$a" >&2
        exit 2
      fi
      home=$a
      ;;
  esac
done
if [ -z "$home" ]; then
  printf 'install-all: name the home: install-all.sh [--dry-run] <jg-home> (or set JG_HOME)\n' >&2
  exit 2
fi
if [ ! -d "$home" ]; then
  printf 'install-all: no such home directory: %s\n' "$home" >&2
  exit 2
fi
export JG_HOME=$home

# name:kind, in a working order: route-change reads pipeline-quota-failover's wrapper, guards precede anything that
# chains to them, and the account pool precedes the checks that read it.
#   plain       install.sh [--dry-run]
#   home        install.sh [--dry-run] <jg-home>
#   env         JG_HOME=<jg-home> install.sh [--dry-run]
#   all         install.sh [--dry-run] --all <jg-home>   (the home and every active local squad_lead home it lists)
#   home-nodry, all-nodry   the same without --dry-run support: printed, not run, under --dry-run
#   verify      install.sh <jg-home> is that add-on's wiring check, not an install: its incomplete report is printed
#               and never fails this run
plan=(
  kill-guard:plain
  read-guard:plain
  delete-guard:home
  host-memory:plain
  pipeline-literal-delete:plain
  pipeline-quota-failover:plain
  route-change:plain
  account-pool:verify
  claude-accounts:home-nodry
  quota-axi-pool:plain
  git-identity:home
  repo-guard:plain
  fleet-flow:plain
  fleet-pulse:home
  fleet-stall:env
  key-in-env-check:env
  zai-quota-check:env
  nm-drain:home
  merge-on-green:home
  quota-failover:all
  limit-prompt-move:all-nodry
  model-gate:env
  owner-guard:home
  owner-rules:home
  pane-titles:home
  backlog-lock-reclaim:home
  bearings-board:home
  parked-homes:verify
  sentinel:home
  supervisor-guard:home
  task-priority:plain
  tickets-sync:env
  lookout-adapter:plain
)

failed=''
installed=0
for entry in "${plan[@]}"; do
  name=${entry%%:*}
  kind=${entry##*:}
  script=$here/$name/install.sh
  if [ ! -f "$script" ]; then
    printf 'install-all: %s has no installer at %s\n' "$name" "$script" >&2
    failed="$failed $name"
    continue
  fi
  args=()
  dryable=1
  case $kind in
    plain) ;;
    home) args=("$home") ;;
    env) ;;
    all) args=(--all "$home") ;;
    home-nodry) args=("$home") dryable=0 ;;
    all-nodry) args=(--all "$home") dryable=0 ;;
    verify) args=("$home") ;;
    *) printf 'install-all: %s has an unknown kind %s\n' "$name" "$kind" >&2; failed="$failed $name"; continue ;;
  esac
  # A wiring check reports the home's state; an incomplete home is information, not a failed install.
  if [ "$kind" = verify ]; then
    printf '\n== %s: bash %s/install.sh %s\n' "$name" "$name" "$home"
    bash "$script" "$home" || printf 'install-all: %s wiring incomplete (see the lines above; it changes nothing)\n' "$name"
    continue
  fi
  # Lookout replaces the dashboard service and needs its own clone; without it there is nothing to point at.
  if [ "$name" = lookout-adapter ] && [ -z "${LOOKOUT_DIR:-}" ]; then
    printf '\n== %s: skipped, set LOOKOUT_DIR to the Lookout clone to install it\n' "$name"
    continue
  fi
  [ "$dry" = 0 ] || args=(--dry-run "${args[@]}")
  printf '\n== %s: bash %s/install.sh%s\n' "$name" "$name" "${args[*]:+ ${args[*]}}"
  if [ "$dry" = 1 ] && [ "$dryable" = 0 ]; then
    printf 'would-run %s/install.sh%s (this installer has no --dry-run of its own)\n' "$name" "${args[*]:+ ${args[*]//--dry-run/}}"
    continue
  fi
  if ! bash "$script" "${args[@]}"; then
    printf 'install-all: %s failed\n' "$name" >&2
    failed="$failed $name"
    continue
  fi
  installed=$((installed + 1))
done

# owner-guard is installed by its daily owner-details scan too: the catalog's install path ran that second installer.
scan=$here/owner-guard/install-scan.sh
if [ -f "$scan" ]; then
  printf '\n== owner-guard scan: bash owner-guard/install-scan.sh%s\n' "$([ "$dry" = 0 ] || printf ' --dry-run')"
  if [ "$dry" = 1 ]; then
    bash "$scan" --dry-run "$home" || { printf 'install-all: owner-guard scan failed\n' >&2; failed="$failed owner-guard-scan"; }
  else
    bash "$scan" "$home" || { printf 'install-all: owner-guard scan failed\n' >&2; failed="$failed owner-guard-scan"; }
  fi
fi

# Everything else in the catalog on purpose: no installer to run, and saying so beats pretending to wire it in.
printf '\n== no installer to run (setup lives in the add-on):'
missing=0
for dir in "$here"/*/; do
  name=$(basename "$dir")
  case $name in docs | .agents | .github | tests) continue ;; esac
  [ -f "$dir/install.sh" ] && continue
  printf ' %s' "$name"
  missing=$((missing + 1))
done
printf '\n   %s add-ons; docs/addons-reference.md#install and each README own their wiring.\n' "$missing"

printf '\ninstall-all: %s installed, %s without an installer' "$installed" "$missing"
if [ -n "$failed" ]; then
  printf ', failed:%s\n' "$failed" >&2
  exit 1
fi
printf '.\n'
