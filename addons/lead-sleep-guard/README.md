# Lead sleep guard

In an OpenCode squad-lead (secondmate) home, a bash command that sleeps, watches or polls in the foreground is refused.
A lead stuck in a foreground wait misses its inbox doorbell; the message says to end the turn and let the watcher wake it.

A home counts as a lead home when the session directory, the call's `workdir` or `JG_HOME` holds a regular `.jg-squad-lead-home` file (a symlink does not count).
Main, ships and every other harness are untouched.
Matching is on command position (`sleep`, `watch`, also after `;`, `&&`, `|`, `do`, `then`), so `echo sleep` is allowed; a `sleep` in a loop body is caught by the same rule.
This is a cooperative hook that prevents a known mistake, not a security boundary.

Install with `lead-sleep-guard/install.sh` after merging; remove with `uninstall.sh`.
Verify without installing: `bash lead-sleep-guard/tests/lead-sleep-guard.test.sh`.
