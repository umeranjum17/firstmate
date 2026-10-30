#!/usr/bin/env bash
# tests/jg-board-gate.test.sh - the board-ask gate: a non-must ask is refused and
# routed to Overwatch, and a must ask is posted with its category.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-board-gate)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
CARD="$ROOT/bin/jg-question-card.sh"

setup() {  # <name> -> the case dir
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/fakebin" "$d/so/.sign-off"
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  cat > "$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
case "$cmd" in
  list) jq -c '{decisions: [.items[]]}' "$board" ;;
  raise)
    key='' title='' detail=''
    while [ "$#" -gt 0 ]; do
      case "$1" in --key) key=$2; shift ;; --title) title=$2; shift ;; --detail) detail=$2; shift ;; esac
      shift
    done
    jq --arg k "${key:-card}" --arg t "$title" --arg d "$detail" --arg f "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
      '.items += [{key: $k, kind: "decision", title: $t, detail: $d, filed: $f}]' "$board" > "$board.t" && mv "$board.t" "$board"
    printf '%s\n' "${key:-card}" ;;
esac
SH
  chmod +x "$d/fakebin/sign-off-axi"
  printf '%s\n' "$d"
}

run() {  # <case dir> <command...>
  local d=$1
  shift
  env PATH="$d/fakebin:$PATH" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" \
    SIGN_OFF_HOME="$d/so" "$@" 2>&1
}

ask() {  # <case dir> [post flags...]
  local d=$1
  shift
  run "$d" "$CARD" post --title "Rename the fleet word?" --ask-ref m1 --why "It reads oddly here." \
    --outcome yes="It is renamed." --outcome no="It stays." --recommend yes \
    --recommend-reason "It reads better." --default no "$@"
}

open_cards() { jq -r '[.items[] | select(.dismissed != true)] | length' "$1/so/.sign-off/decisions.json"; }

test_non_must_ask_is_refused_and_routed() {
  local d out
  d=$(setup refuse)
  out=$(ask "$d") && fail "a non-must ask posted under the when-it-matters leash: $out"
  assert_contains "$out" "needs a must category" "the refusal did not name the requirement"
  assert_contains "$out" "money, credential-login, physical-device" "the refusal did not name the category list"
  assert_contains "$out" "recorded for Overwatch: owd-" "the refusal did not name its Overwatch record"
  assert_equals "0" "$(open_cards "$d")" "a refused ask still reached the captain's board"
  assert_grep "- Ask: Rename the fleet word?" "$d/home/data/overwatch-decisions.md" "no Overwatch record for the refused ask"
  assert_grep "- Main decided: open" "$d/home/data/overwatch-decisions.md" "the record does not say Main answers it"
  pass "a non-must ask is refused, named, routed to Overwatch, never posted"
}

test_must_ask_is_posted_with_its_category() {
  local d out key detail
  d=$(setup accept)
  out=$(ask "$d" --must money) || fail "a must ask was refused: $out"
  key=$(printf '%s\n' "$out" | sed -n '1p')
  [ -n "$key" ] || fail "the post printed no card key: $out"
  detail=$(jq -r --arg k "$key" '.items[] | select(.key == $k) | .detail' "$d/so/.sign-off/decisions.json")
  assert_equals "must: money" "$detail" "the card does not carry its must category"
  printf 'leash: ask\n' > "$d/so/.sign-off/config.yaml"
  out=$(ask "$d" --title "Rename the other word?" --ask-ref m2) \
    || fail "the ask-me-first leash refused a plain ask: $out"
  pass "a must ask is posted with its category, and the ask-me-first leash still posts a plain one"
}

test_non_must_ask_is_refused_and_routed
test_must_ask_is_posted_with_its_category
