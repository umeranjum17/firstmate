#!/usr/bin/env bash
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
. "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
# juggernaut-name-gate.sh - the Juggernaut rename's done gate.
#
# Fails while the pre-rename product name survives in tracked files. It checks
# both tracked content and tracked file names, because a rename can leave the
# old name in prose, a comment, a script name, an environment variable, a path,
# or an executable name. Content is read text-only, so binaries are skipped.
#
# What it forbids (case-insensitively, and in file names as well as content):
#   first mate / firstmate, second mate / secondmate, crewmate, and the old
#   script, variable and path prefixes fm- and fm_.
#
# Usage:
#   bin/juggernaut-name-gate.sh                 # report leftovers, exit 1 if any
#   bin/juggernaut-name-gate.sh --root <dir>    # measure another checkout
#   bin/juggernaut-name-gate.sh --self-test     # prove the gate still bites
#
# Exit status: 0 when nothing outside the allow list remains, 1 while leftovers
# remain, 2 on a usage or environment error. The leftover count is printed by
# this one command, so a before/after comparison is two runs of it.
#
# Allow list, and nothing else (map: "The done gate"):
#   1. The upstream credit line in README.md and the MIT licence notice in
#      LICENSE, which name the original project. ALLOWED_LINES below holds the
#      exact credit line; LICENSE keeps its notice intact and mentions no name.
#   2. Git history. This gate reads tracked content and names only, never
#      commits or messages, so history is untouched by construction.
#   3. A compatibility alias while a running home still calls the old name.
#      bin/juggernaut-name-gate.allow holds one exact tracked path per line,
#      each with the caller that still calls it and the slice that removes it.
#      There is no blanket old-prefix exemption, so an alias covers nothing but
#      itself. An archival record of a retired repository is the second case:
#      the links it preserves have to keep the names the forge gave them.
#
# This gate's own path and its allow file are allow-listed because they define
# the strings they search for; they are the two files that must keep them.
set -eu

BASE_PATTERN='first[ -]?mate|second ?mate|crewmate|fm[-_]'
# The one pattern the allow file's own lines are matched against, so a stale
# entry (a path that no longer exists, or that no longer carries an old name)
# is reported instead of quietly widening the exemption.
NAME_PATTERN='first[ -]?mate|second ?mate|crewmate|fm[-_]'
PREFIX_PATTERN='^fm[-_]'

# Lines inside a tracked file that may keep the old name, as "path|extended-regex".
ALLOWED_LINES=(
  "README.md|^Juggernaut is a fork of \[Firstmate\]" # upstream credit, never removed
)

die() {
  printf 'juggernaut-name-gate.sh: %s\n' "$*" >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

report() {
  local root="$1" entry allow_file
  [ -d "$root/.git" ] || [ -f "$root/.git" ] || die "$root is not a git checkout"
  cd "$root" || die "cannot enter $root"

  local allow_files exempt tracked stale_file stale
  gate_work=$(mktemp -d) || die "cannot create a temporary directory"
  # shellcheck disable=SC2064 # the path is already resolved and must not change
  trap "rm -rf -- '$gate_work'" EXIT
  allow_files="$gate_work/allowed-files"
  exempt="$gate_work/exempt-lines"
  tracked="$gate_work/tracked"
  stale="$gate_work/stale"
  : >"$allow_files"
  : >"$exempt"
  : >"$stale"
  # This gate and its allow file must keep the names they forbid.
  printf '%s\n' "bin/juggernaut-name-gate.sh" "bin/juggernaut-name-gate.allow" >>"$allow_files"
  allow_file="$root/bin/juggernaut-name-gate.allow"
  if [ -f "$allow_file" ]; then
    while IFS= read -r entry; do
      case "$entry" in '' | '#'*) continue ;; esac
      entry=${entry%%[[:space:]]*}
      [ -n "$entry" ] || continue
      printf '%s\n' "$entry" >>"$allow_files"
      if [ ! -e "$entry" ] || ! printf '%s' "$entry" | grep -qiE -- "$NAME_PATTERN"; then
        printf '%s\n' "$entry" >>"$stale"
      fi
    done <"$allow_file"
  fi
  for entry in ${ALLOWED_LINES[@]+"${ALLOWED_LINES[@]}"}; do
    allow_path=${entry%%|*}
    allow_re=${entry#*|}
    [ -f "$allow_path" ] || continue
    grep -nE -- "$allow_re" "$allow_path" | while IFS=: read -r allow_lineno _; do
      printf '%s:%s\n' "$allow_path" "$allow_lineno" >>"$exempt"
    done
  done

  git ls-files >"$tracked" || die "git ls-files failed"

  awk -v allow_files="$allow_files" -v exempt="$exempt" -v tracked="$tracked" \
    -v stale="$stale" -v name_re="$NAME_PATTERN" -v prefix_re="$PREFIX_PATTERN" '
    function classify(path) {
      if (path ~ /^docs\//) return "docs"
      if (path ~ /^bin\//) return "bin"
      if (path ~ /^\.agents\//) return "agents"
      if (path ~ /^tests\//) return "tests"
      return "other"
    }
    BEGIN {
      while ((getline entry < allow_files) > 0) if (entry != "") allowed_file[entry] = 1
      while ((getline entry < exempt) > 0) if (entry != "") exempt_line[entry] = 1
      while ((getline entry < stale) > 0) if (entry != "") stale_entry[entry] = 1
      while ((getline name < tracked) > 0) {
        if (name in allowed_file) continue
        if (tolower(name) !~ name_re) continue
        name_hits++
      }
    }
    {
      i = index($0, ":")
      path = substr($0, 1, i - 1)
      rest = substr($0, i + 1)
      j = index(rest, ":")
      lineno = substr(rest, 1, j - 1)
      text = substr(rest, j + 1)
      if (path in allowed_file) next
      if ((path ":" lineno) in exempt_line) next
      kind = (tolower(text) ~ prefix_re) ? "prefix" : "word"
      if (kind == "word") { word_occ++; word_file[path] = 1 }
      else { prefix_occ++; prefix_file[path] = 1 }
      surface[path] = classify(path)
      file_occ[path]++
      content_files[path] = 1
    }
    END {
      for (p in word_file) word_files++
      for (p in prefix_file) prefix_files++
      for (p in content_files) {
        content_file_count++
        surface_files[surface[p]]++
      }
      for (p in file_occ) {
        surface_occ[surface[p]] += file_occ[p]
        if (file_occ[p] > worst_occ) { worst_occ = file_occ[p]; worst = p }
      }
      total = word_occ + prefix_occ
      leftovers = total + name_hits
      printf "leftovers: %d (%d text occurrences in %d files, %d file names)\n", \
        leftovers, total, content_file_count + 0, name_hits
      printf "  text  old product word (any case): %d occurrences in %d files\n", word_occ + 0, word_files + 0
      printf "  text  old prefix (fm-/fm_): %d occurrences in %d files\n", prefix_occ + 0, prefix_files + 0
      printf "  names tracked paths carrying the old name: %d files\n", name_hits
      n = split("docs bin agents tests other", order, " ")
      for (k = 1; k <= n; k++) {
        s = order[k]
        if (!(s in surface_files)) continue
        printf "    %-6s %6d occurrences in %5d files\n", s, surface_occ[s] + 0, surface_files[s] + 0
      }
      if (worst != "") printf "  heaviest file: %s (%d occurrences)\n", worst, worst_occ
      stale_count = 0
      for (p in stale_entry) { stale_count++; printf "  stale allow entry: %s\n", p > "/dev/stderr" }
      exit (leftovers > 0 || stale_count > 0)
    }
  ' < <(git grep -I -o -n -i -E "$BASE_PATTERN" -- . || true)
}

self_test() {
  local out
  fail() { printf 'not ok - %s\n' "$*"; exit 1; }
  st_dir=$(mktemp -d) || die "cannot create a self-test directory"
  trap 'rm -rf -- "$st_dir"' EXIT
  git -C "$st_dir" init -q || die "cannot initialise a self-test repository"
  git -C "$st_dir" config user.email gate@example.invalid
  git -C "$st_dir" config user.name gate
  mkdir -p "$st_dir/bin"
  printf '%s\n' "Juggernaut is a fork of [Firstmate](https://example.invalid)." >"$st_dir/README.md"
  printf '%s\n' "clean line" >"$st_dir/clean.md"
  printf '%s\n' "# allow list" >"$st_dir/bin/juggernaut-name-gate.allow"
  git -C "$st_dir" add -A >/dev/null 2>&1 && git -C "$st_dir" commit -qm base >/dev/null 2>&1

  out=$("${BASH_SOURCE[0]}" --root "$st_dir") || fail "allow-listed credit line should pass: $out"
  printf 'ok - allow-listed upstream credit line passes\n'

  printf '%s\n' "old name: Firstmate home" "run bin/fm-old.sh" "the second mate reports" \
    "the secondmate home" "an old crewmate" "export FM_HOME=/tmp/x" >>"$st_dir/clean.md"
  printf '%s\n' "#!/usr/bin/env bash" >"$st_dir/fm-old.sh"
  printf '%s\n' "#!/usr/bin/env bash" >"$st_dir/firstmate-thing.sh"
  git -C "$st_dir" add -A >/dev/null 2>&1 && git -C "$st_dir" commit -qm leftover >/dev/null 2>&1
  out=$("${BASH_SOURCE[0]}" --root "$st_dir") && fail "leftovers should fail the gate"
  # six content matches in clean.md plus two old-named files
  case "$out" in "leftovers: 8 ("*) ;; *) fail "expected 8 leftovers, got: $out" ;; esac
  printf 'ok - old words, old prefixes, spaced old words, and file names are counted\n'

  printf "%s\n" "fm-old.sh" >>"$st_dir/bin/juggernaut-name-gate.allow"
  out=$("${BASH_SOURCE[0]}" --root "$st_dir") && fail "allow list should not hide the prose"
  case "$out" in "leftovers: 7 ("*) ;; *) fail "expected 7 leftovers after allowing one name, got: $out" ;; esac
  printf 'ok - an allow-list entry covers exactly one path\n'

  printf '%s\n' "gone/fm-nothing.sh" >>"$st_dir/bin/juggernaut-name-gate.allow"
  out=$("${BASH_SOURCE[0]}" --root "$st_dir" 2>/dev/null) && fail "a stale allow entry should fail"
  printf 'ok - a stale allow-list entry fails the gate\n'

  printf '%s\n' "# allow list" >"$st_dir/bin/juggernaut-name-gate.allow"
  git -C "$st_dir" rm -q fm-old.sh firstmate-thing.sh
  printf '%s\n' "clean line" >"$st_dir/clean.md"
  git -C "$st_dir" add -A >/dev/null 2>&1 && git -C "$st_dir" commit -qm clean >/dev/null 2>&1
  out=$("${BASH_SOURCE[0]}" --root "$st_dir") || fail "a clean tree should pass: $out"
  case "$out" in "leftovers: 0 ("*) ;; *) fail "a clean tree must report zero, got: $out" ;; esac
  printf 'ok - a clean tree reports zero leftovers\n'
}

case "${1:-}" in
--self-test) self_test ;;
--root)
  [ -n "${2:-}" ] || die "--root needs a directory"
  report "$2"
  ;;
--help | -h)
  usage
  ;;
"") report "$ROOT" ;;
*)
  die "unknown argument: $1 (try --help)"
  ;;
esac
