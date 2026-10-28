# quota-axi-pool

## User outcome

Dispatch `quota-axi --json` Claude runway matches `jg-model-pool`'s account reading. Install over an existing foreign `~/.local/bin/quota-axi` symlink records its resolved target as upstream and restores that link on uninstall.

## Drive

`bash quota-axi-pool/tests/quota-axi-pool.test.sh` or `done-done run quota-axi-pool` (`bash quota-axi-pool/run-proof.sh`). Fixture Umer A/B, stub upstream ambient 11%; temp-HOME install over a fake foreign symlink (never real `~/.local/bin`); no login copy, no network.

`bash quota-axi-pool/tests/quota-axi-pool-recursion.test.sh` proves the wrapper cannot recurse through its own pick: the wrapper installed the way `install.sh` installs it, first on PATH, a stub upstream that records its callers, a stand-in pool tool that records its own invocation and exits. The Claude accounts reader must reach the upstream without the wrapper delegating, `JG_QUOTA_AXI_POOL_DEPTH=1` must send the wrapper straight upstream without delegating, and the same call without the variable must delegate carrying depth 1 (the control that makes the guard assertion mean something). No network, no login folder.

## Capture

`result.log` and `steps.json` under `$DONE_DONE_EVIDENCE_ROOT` (screen: none). Assert A=70 then B=40 after A attempted; ambient without pool; unknown under floor; refuse with no upstream; install records resolved upstream and original link target; reinstall keeps them; uninstall restores the original link. For the recursion journey, assert the reader's run finishes, calls the upstream once and the pool tool never, and that the depth guard is what stopped the delegated call.
