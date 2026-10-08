## Known untested scenarios

- Pi worker completing the reported conflicting `git rebase --continue` journey: untested because the PATH launcher invokes forbidden global `mise use -g`; no global mise command was run.
- Herdr worker completing Git operations without opening an editor: untested because two isolated lab provisioning attempts timed out.
- Local secondmate launch receiving editor protection: untested because the fixture requires a secondmate home outside the repository, conflicting with this phase's workspace boundary.

These are known coverage gaps, not passing scenarios or demonstrated product failures. The user requested disclosure in the PR body rather than further live attempts. The outer PR phase owns copying this section into the PR body; this test phase did not modify a PR.

Focused recheck on `7bfcdf5ebec951462179bb77c27387f46f6720eb`: existing `test_worker_git_editors` and `test_relaunch_rebuilds_the_switch` from `tests/fm-spawn-compact-adviser-disable.test.sh` both passed (exit 0), selected through a temporary sibling script with the same definitions and only those two invocations. Real Git conflict continuation and interactive rebase passed in ordinary and cleared environments; relaunch executed emitted commands through fixture harness probes, not live Pi or Herdr. Log: `focused-editor-recheck.log`. Temporary script and fixture directory were removed. No source change was warranted; no full suite, linter, formatter, static analysis, global mise, CI retry, or pipeline control was run.
