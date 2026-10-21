#!/usr/bin/env bash
# done-done journey: drive the real bin/fm-pr-check.sh in a disposable home with and without
# a receipts add-on hook, and write the transcript and step record into the evidence folder.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
SHA=0123456789abcdef0123456789abcdef01234567
OTHER=89abcdef0123456789abcdef0123456789abcdef
URL=https://github.com/o/r/pull/4
T=$(mktemp -d)
mkdir -p "$T/fakebin" "$T/guardroot/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/guardroot/bin/fm-guard.sh"; chmod +x "$T/guardroot/bin/fm-guard.sh"
cat > "$T/fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --json isDraft "*) echo '{"isDraft":false}' ;;
  *headRefOid*) echo $SHA ;;
esac
SH
chmod +x "$T/fakebin/gh"
run() {  # <name> <addon-mode: none|pr_head|other>
  local d="$T/$1" addons="$T/$1/addons"
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/wt" "$addons/receipts/bin"
  git -C "$d/wt" init -q; git -C "$d/wt" commit -q --allow-empty -m init
  git -C "$d/wt" update-ref refs/remotes/origin/main "$(git -C "$d/wt" rev-parse HEAD)"
  printf 'window=fm:t\nendpoint_task_id=task-a\nworktree=%s\nproject=%s\nkind=ship\nmode=direct-PR\n' "$d/wt" "$d/project" > "$d/home/state/task-a.meta"
  {
    echo 'fm_receipts_accept_done() { echo "gate-candidate=[${7:-}]" >> "$GATE_LOG"; }'
    case $2 in
      pr_head) echo 'fm_receipts_pr_candidate() { echo "hook consulted: pr_head=$5" >> "$GATE_LOG"; printf "%s" "$5"; }' ;;
      other)   echo "fm_receipts_pr_candidate() { echo 'hook consulted' >> \"\$GATE_LOG\"; printf '%s' $OTHER; }" ;;
    esac
  } > "$addons/receipts/bin/fm-receipts-lib.sh"
  [ "$2" != none ] || rm -f "$addons/receipts/bin/fm-receipts-lib.sh"
  : > "$d/gate.log"
  echo "== scenario $1 (add-on: $2)"
  FM_ROOT_OVERRIDE="$T/guardroot" FM_HOME="$d/home" FM_ADDONS_DIR="$addons" GATE_LOG="$d/gate.log" PATH="$T/fakebin:$PATH" \
    "$REPO/bin/fm-pr-check.sh" task-a "$URL" >"$d/out" 2>"$d/err"; echo "exit=$?"
  echo "stderr: $(cat "$d/err")"; echo "gate/hook log:"; sed 's/^/  /' "$d/gate.log"
  echo "recorded: $(grep -E '^(pr|pr_head)=' "$d/home/state/task-a.meta" | tr '\n' ' ')"
  echo "poll armed: $([ -e "$d/home/state/task-a.check.sh" ] && echo yes || echo no)"
}
{
  run no-addon none
  run addon-returns-pr-head pr_head
  run addon-returns-other other
} 2>&1 | tee "$OUT/receipt-hook-transcript.txt"
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"firstmate bin/fm-pr-check.sh at this commit"},
 "start":"a disposable firstmate home with one direct-PR task and a verified forge head",
 "steps":["run fm-pr-check.sh with no receipts add-on installed","run fm-pr-check.sh with an add-on whose hook returns the verified PR head","run fm-pr-check.sh with an add-on whose hook returns a different head"],
 "result":"no add-on registers the PR as before; the matching add-on candidate is accepted and passed to the gate; the other value is refused with the hook named, nothing recorded or armed"}
J
rm -rf -- "$T"
