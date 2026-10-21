# Persisted pipeline route

## User outcome

The pipeline runs the route the no-mistakes config holds: the OpenRouter DeepSeek floor route, and a call pinned to a model outside the chain lands on that route instead of the pinned model.

## Drive

Run `bash pipeline-quota-failover/run-proof.sh` from the repository root (the done-done journey `pipeline-route`). It drives the real wrapper `pipeline-quota-failover/pi-quota-failover` against a stub pi and a stub quota-axi in a throwaway HOME and captures the chain it holds, the fixture journey `pipeline-quota-failover/tests/pi-quota-failover-route.test.sh` and their exit codes in `$DONE_DONE_EVIDENCE_ROOT`.

The same wrapper's longer journey is `pipeline-quota-failover/tests/pi-quota-failover-e2e.sh`. `pipeline-quota-failover/README.md`, the root `README.md` and `.github/workflows/addons-ci.yml` name the same commands.

## Evidence

Capture the test command's output and exit status in done-done's run evidence directory. Never use a real home, a real pi or a real config.
