# Pipeline route switch

## Drive

Run `bash pipeline-quota-failover/tests/switch-route.test.sh` from the repository root. The test drives the real script against a fixture no-mistakes config and a stub pi on PATH, and verifies that a switch edits only `agent` and `agent_config.<agent>.model`, writes a backup first, leaves the config alone when the model does not answer PONG, and restores that backup.

## Evidence

Capture the test command's output and exit status in done-done's run evidence directory. Never use a real home, a real model or a real config.
