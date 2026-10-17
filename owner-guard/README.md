# owner-guard

The owner-details guard — the rule that keeps a lane from committing or
pushing the owner's private details to a public repo, shaped like
`delete-guard` (a refusal is final: no bypass flag, no env skip).

## Layout

- `owner-guard` — the guard. `pre-commit` scans the staged added lines;
  `pre-push` scans the added lines of every pushed commit the destination
  ref doesn't already have (for a new branch, every commit no
  remote-tracking ref has). Each added line is
  matched case-insensitively against every extended regex in the patterns
  file: `$FM_HOME/config/owner-details-patterns` when that home holds one,
  else the installing home's file (full-line `#` comments and blank lines
  ignored). A hit refuses with
  `file:line` plus a placeholder hint, never the pattern list. A missing or
  empty patterns file allows with one note line.
- `install.sh` — installs the guard, keeps the patterns file private (mode
  600, never created and never overwritten; the recorded patterns home is
  kept when the new home has no file), chains both hooks
  through the git-identity `hooks.d/` dir so every lane commit runs them,
  and points the user's global `core.hooksPath` at `global-hook.sh`
  wrappers so plain-shell commits and pushes are checked too. Each wrapper
  runs the guard (pre-commit and pre-push only), then the previous global
  hooks dir's hook and the repository's own hook, so repos with their own
  hooks keep working. Install is idempotent, records a replaced global
  hooksPath instead of dropping it, and `--uninstall` restores it; a
  repo-local `core.hooksPath` is never touched.
- `tests/owner-guard.test.sh` — fixture-repo proof (throwaway HOME and repo,
  made-up patterns only): matching commit refused, clean commit passes,
  matching push refused, removal-only commit passes, the repo's own hook
  still chains. The patterns file is never copied into the repo or a log.
- `tests/owner-guard-global.test.sh` — fixture proof for the machine-wide
  guard (throwaway HOME and global gitconfig, made-up patterns only):
  plain-shell and lane leaks refused, clean commits and pushes pass, the
  repo's own hooks and a previous global hooks dir still chain, double
  install is a no-op, uninstall restores the previous global hooksPath.

## Known limits

A refusal only fires when a client-side hook runs: `git commit --no-verify`
skips the pre-commit check, and a repo-local `core.hooksPath` (for example
a hook manager) replaces the global wrappers for that repo, so neither is
caught. The no-mistakes pipeline pins a per-worktree `core.hooksPath` and
pushes with client hooks skipped, so commits the pipeline itself authors
are unguarded; worker commits are still checked at commit time. Fixture
evidence for the bypass (made-up values only) is kept with the task
record, outside this repo.

## Daily scan

`scan-check` shallow-clones (depth 1) the default branch of every fleet
public repo at most once a day and matches every line against the same
patterns file the hook uses. The clone loop cannot finish inside the
watcher's timeout, so when a scan is due the check records the run, starts
the loop detached in the background, and returns at once with no output; a
finished loop with hits leaves its one wake line under the Main home's
`state/`, and the next check run prints it once and removes it. The repo list is
`config/owner-guard-repos` under the Main home (one `owner/repo` or clone
URL per line, full-line `#` comments allowed); when it is missing, the
account's public repos are listed through the forge CLI instead. The wake
line names each repo with its hit count and the
private `data/owner-details-scan/` report holding the full `file:line`
hits; a clean run, a run with no finished scan waiting, or a missing patterns
file prints nothing. Install with `install-scan.sh [--dry-run] [<home>]`
(the home defaults to the Main home); `tests/scan-e2e.sh` is the fixture
proof (one hit repo, one clean repo, made-up patterns only).

## Placeholders

Replace a refused detail with `you@example.com`, `~/firstmate`, `/home/you`.
