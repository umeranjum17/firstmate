#!/usr/bin/env bash
# Public setup and resolution journey against a fake BYOKit Accounts API.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
w=$(mktemp -d "${TMPDIR:-/tmp}/fm-ai-engine-test.XXXXXX")
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/home"
cat > "$w/fake-byokit.mjs" <<'FAKE'
export const machineStore = (member, seal) => ({ member, seal });
export const osKeyringSeal = (options) => options;
export class Accounts {
  async list() {
    if (process.env.FAKE_BYOKIT_STATE === 'signed_out') return [];
    return [
      { id: 'chatgpt.work', name: 'Work', provider: 'chatgpt', email: 'work@example.test', state: 'ready', billing: 'subscription' },
      { id: 'claude.max', name: 'Personal', provider: 'claude', state: 'ready', billing: 'subscription', accessToken: 'must-not-write' },
    ];
  }
}
FAKE
export FM_HOME="$w/home" FM_BYOKIT_API_MODULE="$w/fake-byokit.mjs" USER=fixture
printf '2\n' | node "$ROOT/bin/fm-ai-engine.mjs" setup >"$w/setup.out"
[ "$(node "$ROOT/bin/fm-ai-engine.mjs" resolve)" = '{"id":"claude.max","name":"Personal","provider":"claude"}' ] || { echo 'failed: resolver did not return the selected signed-in account' >&2; exit 1; }
[ "$(node -e 'const x=require(process.argv[1]); console.log(JSON.stringify(x.account))' "$FM_HOME/config/ai-engine.json")" = '{"id":"claude.max","name":"Personal","provider":"claude"}' ] || { echo 'failed: config did not store only the account reference' >&2; exit 1; }
if grep -q 'must-not-write\|accessToken\|email' "$FM_HOME/config/ai-engine.json"; then echo 'failed: config contains private account data' >&2; exit 1; fi
if FAKE_BYOKIT_STATE=signed_out node "$ROOT/bin/fm-ai-engine.mjs" setup >"$w/no-account.out" 2>&1; then echo 'failed: setup continued without a signed-in account' >&2; exit 1; fi
grep -q 'ChatGPT through a BYOKit Accounts client' "$w/no-account.out" || { echo 'failed: no signed-in account did not show the provider sign-in step' >&2; exit 1; }
if FAKE_BYOKIT_STATE=signed_out node "$ROOT/bin/fm-ai-engine.mjs" resolve >"$w/revoked.out" 2>&1; then echo 'failed: resolver used an account that is no longer signed in' >&2; exit 1; fi
grep -q 'Sign in to claude' "$w/revoked.out" || { echo 'failed: resolver did not name the missing provider' >&2; exit 1; }
echo 'ok: setup stores only a selected account reference; resolver rechecks it; signed-out setup stops with a sign-in step'
