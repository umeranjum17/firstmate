#!/usr/bin/env bash
# juggernaut-name-gate.sh - the Juggernaut rename's done gate.
#
# Fails while the pre-rename vocabulary survives. One gate, two scopes:
#
#   --visible   Phase 1: the surface a visitor reads (VISIBLE_PATHS below).
#               Fails on the old product name and the old role words in prose:
#               firstmate, first mate, crewmate, scout, second mate, second-mate,
#               and the fm-task<n> task-id form. Markdown code spans and fenced
#               blocks are the literals a live home still uses - a command, a
#               path, an environment variable, a skill name - so they are read as
#               code; an old word joined to a path or identifier
#               (`data/secondmates.md`, `firstmate-addons`, `from-firstmate`,
#               `config/firstmate-role`) is the same literal and is left to the
#               Phase 2 renames.
#   (default)   The whole tracked tree, content and tracked file names: the
#               Phase 2 done gate. It also counts what Phase 1 left, so
#               `--visible` and the default scope are two runs of this command.
#
# Usage:
#   bin/juggernaut-name-gate.sh                 # whole-tree report, exit 1 if any
#   bin/juggernaut-name-gate.sh --visible       # Phase 1 visible-surface gate
#   bin/juggernaut-name-gate.sh --root <dir>    # measure another checkout
#   bin/juggernaut-name-gate.sh --self-test     # prove the gate still bites
#
# Add --verbose to either scope to list each visible leftover by file and line.
#
# Exit status: 0 when nothing outside the allow list remains, 1 while leftovers
# remain, 2 on a usage or environment error.
#
# Allow list, and nothing else:
#   1. The upstream credit line in README.md and the MIT licence notice in
#      LICENSE, which name the original project.
#   2. Git history: this gate reads tracked content and names only, never commits
#      or messages. A preserved forge-given ref is history too, so the archival
#      record that keeps the retired repositories' branch and pull request links
#      (BACKLOG.md) may carry the old names those links were minted under.
#   3. A compatibility alias while a running home still calls the old name: one
#      exact path per alias, whose comment names the caller and the condition
#      that removes the entry. There is no blanket old-prefix exemption, so an
#      alias covers nothing but itself.
set -eu

# Whole-tree scope: the old product name and the old script prefix.
BASE_PATTERN='firstmate|secondmate|fm[-_]'
# Role vocabulary and the old task-id form, counted separately in both scopes.
ROLE_PATTERN='first mate|first-mate|crewmate|scout|second mate|second-mate|fm-task[0-9]+'
# Prose scan for --visible, as one POSIX ERE (case-insensitive, matched on a
# lowercased copy of each prose segment).
VISIBLE_PATTERN='first[ -]?mates?|crewmates?|second[ -]?mates?|scouts?|fm-task[0-9]+'
# The surface a visitor reads. Everything else in the tree is Phase 2's.
VISIBLE_PATH_RE='^(README|AGENTS|CONTRIBUTING|VISION|GROK_BOT|CLAUDE)\.md$|^(docs|skills|\.agents/skills)/.*\.md$'

# Exact tracked paths that may still carry the old name.
# Phase 1 renames user-facing text only, so no alias is needed yet; Phase 2 adds
# one line per alias as it ships, for example:
#   "bin/fm-update.sh"   # alias; called by live home state/juggernaut-rename; drop when no home calls it
ALLOWED_FILES=(
  "bin/juggernaut-name-gate.sh"    # this gate: it must name what it forbids
  "bin/juggernaut-name-gate.allow" # the alias list: each line names the old path it keeps alive
  "BACKLOG.md"                  # archival record of the two retired repositories, called by nothing: its preserved branch and pull request links must keep their historical names; drop this entry when the last item and branch listed in it is closed
)

# Lines inside a tracked file that may keep the old name, as "path|extended-regex".
ALLOWED_LINES=(
  "README.md|Juggernaut is a fork of \[Firstmate\]" # upstream credit, never removed
)

die() {
  printf 'juggernaut-name-gate.sh: %s\n' "$*" >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode=whole
verbose=0
scan_root="$ROOT"
self_test=0
while [ "$#" -gt 0 ]; do
  case "$1" in
  --visible) mode=visible ;;
  --verbose) verbose=1 ;;
  --self-test) self_test=1 ;;
  --root)
    [ -n "${2:-}" ] || die "--root needs a directory"
    scan_root="$2"
    shift
    ;;
  --help | -h)
    self_test=-1
    ;;
  *)
    die "unknown argument: $1 (try --help)"
    ;;
  esac
  shift
done

usage() {
  sed -n '3,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Build the exemption maps the scans share: allow-listed paths, and the exact
# path:line pairs that ALLOWED_LINES protects.
prepare_allow() {
  local work="$1"
  : >"$work/allowed-files"
  : >"$work/exempt-lines"
  local entry allow_path allow_re
  for entry in ${ALLOWED_FILES[@]+"${ALLOWED_FILES[@]}"}; do printf '%s\n' "$entry" >>"$work/allowed-files"; done
  # bin/juggernaut-name-gate.allow: one exact tracked path per line (first word),
  # then the caller that still uses it and the slice that deletes it.
  if [ -f bin/juggernaut-name-gate.allow ]; then
    while IFS= read -r entry; do
      case "$entry" in '' | '#'*) continue ;; esac
      printf '%s\n' "${entry%%[[:space:]]*}" >>"$work/allowed-files"
    done <bin/juggernaut-name-gate.allow
  fi
  for entry in ${ALLOWED_LINES[@]+"${ALLOWED_LINES[@]}"}; do
    allow_path=${entry%%|*}
    allow_re=${entry#*|}
    [ -f "$allow_path" ] || continue
    grep -nE -- "$allow_re" "$allow_path" | while IFS=: read -r allow_lineno _; do
      printf '%s:%s\n' "$allow_path" "$allow_lineno" >>"$work/exempt-lines"
    done
  done
  return 0
}

# Phase 1: old vocabulary in the prose a visitor reads.
visible_report() {
  local root="$1" verbose="$2" work files
  [ -d "$root/.git" ] || [ -f "$root/.git" ] || die "$root is not a git checkout"
  cd "$root" || die "cannot enter $root"
  work=$(mktemp -d) || die "cannot create a temporary directory"
  # shellcheck disable=SC2064 # the path is already resolved and must not change
  trap "rm -rf -- '$work'" EXIT
  prepare_allow "$work"
  files="$work/visible-files"
  git ls-files | grep -E "$VISIBLE_PATH_RE" >"$files" || true
  [ -s "$files" ] || die "no visible files found under $root"
  local -a targets=()
  mapfile -t targets <"$files"

  awk -v exempt_file="$work/exempt-lines" -v verbose="$verbose" -v pat="$VISIBLE_PATTERN" '
    BEGIN {
      while ((getline line < exempt_file) > 0) if (line != "") exempt[line] = 1
    }
    FILENAME != previous {
      previous = FILENAME
      infence = 0
      scanned++
    }
    {
      if ($0 ~ /^[ \t]*(```|~~~)/) { infence = !infence; next }
      if (infence) next
      if ((FILENAME ":" FNR) in exempt) { exempted++; next }
      n = split($0, parts, "`")
      for (i = 1; i <= n; i += 2) {
        s = tolower(parts[i])
        while (match(s, pat)) {
          token = substr(s, RSTART, RLENGTH)
          left = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
          rpos = RSTART + RLENGTH
          right = (rpos <= length(s)) ? substr(s, rpos, 1) : ""
          s = substr(s, rpos)
          if (left ~ /[a-z0-9_\/.@#=-]/ || right ~ /[a-z0-9_\/@#-]/) { named++; continue }
          total++
          if (!(FILENAME in file_seen)) { file_seen[FILENAME] = 1; file_count++ }
          if (verbose) {
            text = $0
            if (length(text) > 160) text = substr(text, 1, 157) "..."
            printf "%s:%d: %s - %s\n", FILENAME, FNR, token, text
          }
        }
      }
    }
    END {
      printf "visible leftovers: %d prose occurrences in %d of %d files\n", total + 0, file_count + 0, scanned + 0
      printf "  allow-listed lines skipped: %d\n", exempted + 0
      printf "  name-shaped fragments left to the Phase 2 renames: %d\n", named + 0
      exit (total > 0)
    }
  ' "${targets[@]}"
}

report() {
  local root="$1"
  [ -d "$root/.git" ] || [ -f "$root/.git" ] || die "$root is not a git checkout"
  cd "$root" || die "cannot enter $root"

  local work allow_files exempt tracked role_occ
  work=$(mktemp -d) || die "cannot create a temporary directory"
  # shellcheck disable=SC2064 # the path is already resolved and must not change
  trap "rm -rf -- '$work'" EXIT
  prepare_allow "$work"
  allow_files="$work/allowed-files"
  exempt="$work/exempt-lines"
  tracked="$work/tracked"

  git ls-files >"$tracked" || die "git ls-files failed"
  role_occ=$(git grep -I -o -n -i -E "$ROLE_PATTERN" -- . 2>/dev/null | grep -vcE '^BACKLOG\.md:|^bin/juggernaut-name-gate\.sh:' || true)
  role_occ=${role_occ:-0}

  awk -v allow_files="$allow_files" -v exempt="$exempt" -v tracked="$tracked" -v role_occ="$role_occ" '
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
      while ((getline name < tracked) > 0) {
        if (name in allowed_file) continue
        if (tolower(name) !~ /firstmate|fm-|crewmate|scout|secondmate/) continue
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
      kind = (tolower(text) == "firstmate") ? "word" : "prefix"
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
      total = word_occ + prefix_occ + role_occ
      leftovers = total + name_hits
      printf "leftovers: %d (%d text occurrences in %d files, %d file names)\n", \
        leftovers, total, content_file_count + 0, name_hits
      printf "  text  old product word (any case): %d occurrences in %d files\n", word_occ + 0, word_files + 0
      printf "  text  old role vocabulary: %d occurrences\n", role_occ + 0
      printf "  text  old script prefix (%s): %d occurrences in %d files\n", "fm-", prefix_occ + 0, prefix_files + 0
      printf "  names tracked paths carrying the old name: %d files\n", name_hits
      n = split("docs bin agents tests other", order, " ")
      for (k = 1; k <= n; k++) {
        s = order[k]
        if (!(s in surface_files)) continue
        printf "    %-6s %6d occurrences in %5d files\n", s, surface_occ[s] + 0, surface_files[s] + 0
      }
      if (worst != "") printf "  heaviest file: %s (%d occurrences)\n", worst, worst_occ
      exit (leftovers > 0)
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
  mkdir -p "$st_dir/docs"
  printf '%s\n' "Juggernaut is a fork of [Firstmate](https://example.invalid)." >"$st_dir/README.md"
  printf '%s\n' "The Overwatch dispatches Operators; Recon reports findings." >"$st_dir/docs/clean.md"
  printf '%s\n' "A squad home reads \`bin/fm-spawn.sh\` and \`data/secondmates.md\`." >>"$st_dir/docs/clean.md"
  git -C "$st_dir" add -A >/dev/null 2>&1 && git -C "$st_dir" commit -qm base >/dev/null 2>&1

  out=$("${BASH_SOURCE[0]}" --root "$st_dir" --visible) || fail "allow-listed credit line and code-span literals should pass: $out"
  case "$out" in "visible leftovers: 0 "*) ;; *) fail "expected zero visible leftovers, got: $out" ;; esac
  printf 'ok - allow-listed upstream credit line and code-span literals pass\n'

  printf '%s\n' "Ask the firstmate to brief the crewmate." >>"$st_dir/docs/clean.md"
  git -C "$st_dir" add -A >/dev/null 2>&1 && git -C "$st_dir" commit -qm leftover >/dev/null 2>&1
  out=$("${BASH_SOURCE[0]}" --root "$st_dir" --visible) && fail "old role words in prose should fail the visible gate"
  case "$out" in "visible leftovers: 2 "*) ;; *) fail "expected 2 visible leftovers, got: $out" ;; esac
  printf 'ok - old product and role words in prose are counted\n'

  out=$("${BASH_SOURCE[0]}" --root "$st_dir" --visible --verbose) || true
  case "$out" in *"docs/clean.md:"*) ;; *) fail "verbose mode should name the offending file: $out" ;; esac
  printf 'ok - verbose mode names the offending file and line\n'

  git -C "$st_dir" show HEAD:docs/clean.md | head -2 >"$st_dir/docs/clean.md"
  git -C "$st_dir" add -A >/dev/null 2>&1 && git -C "$st_dir" commit -qm clean >/dev/null 2>&1
  out=$("${BASH_SOURCE[0]}" --root "$st_dir" --visible) || fail "a clean visible surface should pass: $out"
  printf 'ok - a clean visible surface reports zero leftovers\n'

  printf '%s\n' "#!/usr/bin/env bash" >"$st_dir/fm-old.sh"
  printf '%s\n' "run bin/fm-old.sh and the fm-task4 record" >"$st_dir/docs/clean.md"
  git -C "$st_dir" add -A >/dev/null 2>&1 && git -C "$st_dir" commit -qm phase2 >/dev/null 2>&1
  out=$("${BASH_SOURCE[0]}" --root "$st_dir" --visible) && fail "an old task-id form in prose should fail the visible gate"
  case "$out" in "visible leftovers: 1 "*) ;; *) fail "expected 1 visible leftover, got: $out" ;; esac
  out=$("${BASH_SOURCE[0]}" --root "$st_dir") && fail "the whole-tree scope should still fail on internal names"
  printf 'ok - old task-id prose fails Phase 1, internal names still fail the whole-tree scope\n'
}

if [ "$self_test" = 1 ]; then
  self_test
  exit 0
fi
if [ "$self_test" = -1 ]; then
  usage
  exit 0
fi
if [ "$mode" = visible ]; then
  visible_report "$scan_root" "$verbose"
else
  report "$scan_root"
fi
