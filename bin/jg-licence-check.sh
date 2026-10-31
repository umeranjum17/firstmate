#!/usr/bin/env bash
# jg-licence-check.sh - report every dependency whose declared licence is outside this home's allowlist.
#
# A dependency is adopted the moment it enters a manifest, so a licence nobody agreed to can arrive with one
# line. This check reads the allowlist, then the repo's dependency manifests, and reports each dependency the
# allowlist does not cover. The only manifests read, each when present, are package.json - every dependencies
# and devDependencies entry, licensed by package-lock.json's entry for that package - and requirements.txt,
# whose requirement lines carry no licence at all and are therefore unknown.
#
# Usage: jg-licence-check.sh [--root DIR] [--allowlist FILE]
#        jg-licence-check.sh arm | disarm
#
# Allowlist: ${JG_HOME:-<checkout>}/config/licences-allowlist when it exists, else the checkout's
# defaults/licences-allowlist, one licence per line, `#` starting a comment. An SPDX expression passes only
# when every part of it is on the list; AND, OR and WITH are separators, not licences.
#
# Output: one line per dependency to report, then a summary count line, and nothing at all when every
# dependency is allowed. The exit is 0 even with findings, because the printed lines are the wake. A
# dependency with no declared licence is reported as unknown, never passed, and a root with none of the
# manifests prints nothing because there is no dependency to check.
#   outside-allowlist <manifest> <dependency> <licence>
#   unknown-licence   <manifest> <dependency>
#   licence-check: <n> dependencies checked, <m> reported
# arm writes state/licence-check.check.sh and binds it with jg-check-register.sh; disarm retires it with
# jg-check-unregister.sh.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$REPO_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
ROOT=$REPO_ROOT
ALLOWLIST=$JG_HOME/config/licences-allowlist
[ -f "$ALLOWLIST" ] || ALLOWLIST=$REPO_ROOT/defaults/licences-allowlist

die() { printf 'jg-licence-check: %s\n' "$1" >&2; exit "${2:-1}"; }

# One licence field per dependency of one package.json, `name<TAB>licence`, with an empty licence when the
# lockfile does not declare one.
# shellcheck disable=SC2016 # the $n and $l are jq variables, not shell ones.
JQ_DEPS='
  [ ((.dependencies // {}) | keys[]), ((.devDependencies // {}) | keys[]) ] | unique[]
  | . as $n
  | [ $n, ($l[0] | (.packages["node_modules/" + $n].license // .dependencies[$n].license // "")) ] | @tsv'

dep_lines() { # dep_lines <root>: print "manifest<TAB>dependency<TAB>licence" for every manifest entry.
  local pkg=$1/package.json lock=$1/package-lock.json req=$1/requirements.txt
  [ ! -f "$pkg" ] || jq -e . "$pkg" >/dev/null 2>&1 || { printf 'unreadable-manifest %s\n' "$pkg"; return 0; }
  [ ! -f "$pkg" ] || jq -r --slurpfile l <(if [ -f "$lock" ]; then cat -- "$lock"; else printf '{}'; fi) "$JQ_DEPS" "$pkg" \
    | awk -v p="$pkg" '{ print p "\t" $0 }'
  [ ! -f "$req" ] || sed -n 's/^[[:space:]]*\([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p' "$req" \
    | awk -v p="$req" '{ print p "\t" $0 }'
}

allowed() { # allowed <declared licence>: 0 when every licence in it is on the allowlist.
  local lic tok
  lic=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '()' ' ' | tr -s '[:space:]' ' ')
  [ -n "${lic// /}" ] || return 1
  for tok in $lic; do
    case $tok in and | or | with) continue ;; esac
    case $ALLOW in *" $tok "*) ;; *) return 1 ;; esac
  done
  return 0
}

cmd_check() {
  local total=0 bad=0 manifest name lic
  [ -f "$ALLOWLIST" ] || die "no allowlist at $ALLOWLIST" 3
  ALLOW=" $(tr '[:upper:]' '[:lower:]' <"$ALLOWLIST" | sed 's/#.*//' | tr -s '[:space:]' ' ') "
  while IFS=$'\t' read -r manifest name lic; do
    total=$((total + 1))
    if allowed "$lic"; then continue; fi
    bad=$((bad + 1))
    [ -n "${lic// /}" ] && printf 'outside-allowlist %s %s %s\n' "$manifest" "$name" "$lic" \
      || printf 'unknown-licence %s %s\n' "$manifest" "$name"
  done < <(dep_lines "$ROOT")
  [ "$bad" -eq 0 ] && return 0
  printf 'licence-check: %s dependencies checked, %s reported\n' "$total" "$bad"
}

cmd_arm() {
  local shim=$STATE/licence-check.check.sh tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  tmp=$(umask 077; mktemp "$STATE/.jg-licence-check.XXXXXX") || die "cannot write the check shim"
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q\n' "$JG_HOME" "$SCRIPT_DIR/jg-licence-check.sh" >"$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$shim"; } || { rm -f -- "$tmp"; die "cannot write the check shim"; }
  JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" licence-check >/dev/null || die "cannot register the check"
  printf 'armed: licence-check\n'
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --root) ROOT=${2:?--root needs a directory}; shift 2 ;;
    --allowlist) ALLOWLIST=${2:?--allowlist needs a file}; shift 2 ;;
    arm | check) CMD=$1; shift ;;
    disarm) CMD=disarm; shift ;;
    *) die "unknown argument: $1 (see the header comment)" 2 ;;
  esac
done
case ${CMD:-check} in
  check) cmd_check ;;
  arm) cmd_arm ;;
  disarm) JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-unregister.sh" licence-check ;;
esac
