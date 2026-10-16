#!/usr/bin/env bash
# Integration test for fleet-flow/bin/fm-flow-check.sh over a fixture Main home and one muxr home.
# Stub fm-tasks-axi.sh and fm-crew-state.sh in the fixture Main's bin/ stand in for the fork.
# Proves: a 5 h external-wait lane (paused or failed) stops counting toward the cap, a 3 h one,
# a working one, a captain-held one and a 5 h one that has resumed still count; only long-wait
# candidates are probed; --can-start frees the slot; --summary prints dry=1 and dry=0.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
CHECK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/fm-flow-check.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
main=$d/main home=$d/pool/8/firstmate now=$(date +%s)
mkdir -p "$main/bin" "$main/config" "$main/state" "$home/state" "$home/data" "$home/crew"
cat > "$main/bin/fm-tasks-axi.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = ready ] || exit 2
n=$(cat "$FM_HOME/ready-count"); echo "ready[$n]{id,state}:"
for i in $(seq 1 "$n"); do echo "  item-$i,queued"; done
EOF
cat > "$main/bin/fm-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$FM_HOME/probed"
echo "state: $(cat "$FM_HOME/crew/$1") · source: status-log · fixture"
EOF
chmod +x "$main/bin/"*.sh
lane() {  # <task> <status line> [crew state]
  printf 'kind=ship\n' > "$home/state/$1.meta"
  printf '%s\n' "$2" > "$home/state/$1.status"
  [ -z "${3:-}" ] || echo "$3" > "$home/crew/$1"
}
h=3600
lane ext5 "paused [at=$((now - 5 * h))]: waiting on byokit publish" paused
lane fail5 "failed [at=$((now - 6 * h))]: kept open for unlanded work" failed
lane ext3 "paused [at=$((now - 3 * h))]: waiting on quota reset" paused
lane work "working [at=$((now - 1 * h))]: building"
lane held5 "blocked [key=captain-hold-x] [at=$((now - 5 * h))]: captain decides the name" blocked
lane resumed5 "blocked [at=$((now - 5 * h))]: waiting on desklink release" working
fail=0
expect() {  # <name> <want> <got>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: want [$2] got [$3]"; fail=1; fi
}
run() { FM_MAIN_HOME=$main python3 "$CHECK" "$home" "$@"; }

# Cap 4, hard cap 6: six open lanes, but the two long external waits free their slots.
printf 'muxr 4\n' > "$main/config/lane-caps"
echo 2 > "$home/ready-count"
row=$(run --summary)
expect 'open lanes stay listed' 6 "$(cut -f2 <<<"$row")"
expect 'counted excludes only the 5 h paused and failed waits' 4 "$(cut -f8 <<<"$row")"
expect 'dry=0 while ready work waits' 0 "$(cut -f9 <<<"$row")"
expect 'only long-wait candidates are probed' 'ext5 fail5 resumed5' "$(sort -u "$home/probed" | paste -sd ' ')"
expect 'captain-held and short waits are never probed' '' "$(grep -xE 'held5|ext3|work' "$home/probed" || true)"
rc=0; out=$(run --can-start) || rc=$?
expect '--can-start passes with freed slots' '0 ' "$rc $out"

# --target reads landed lanes only: it must not spend the 15 s probe deadline inside the watcher's 30 s window.
rm -f "$home/probed"
out=$(run --target)
expect '--target probes no lanes' '' "$(cat "$home/probed" 2>/dev/null || true)"
expect '--target still prints the percentile line' 'muxr landed lanes 14d n=0 too few for P50/P85; red line uses 24h' "$out"

# Cap 4, nothing ready: the two long waits freed their slots and nothing refills them —
# dry even though 4 lanes still count (working = 1 is what the dry predicate reads).
printf 'muxr 4\n' > "$main/config/lane-caps"
echo 0 > "$home/ready-count"
expect 'dry=1 with no ready work and working < cap' 1 "$(run --summary | cut -f9)"

# A sixth counting lane fills the hard cap again: the rule frees waits, not the cap itself.
printf 'muxr 4\n' > "$main/config/lane-caps"
lane ext4 "paused [at=$((now - 4 * h + 60))]: waiting on quota reset" paused
lane work2 "working [at=$now]: building"
rc=0; out=$(run --can-start) || rc=$?
expect '--can-start refuses at the hard cap of counting lanes' '1 6 open lanes, hard cap 6: land or close a waiting lane first' "$rc $out"

[ "$fail" -eq 0 ] && echo "PASS: fm-flow-check lane slots" || { echo "FAIL: fm-flow-check lane slots"; exit 1; }
