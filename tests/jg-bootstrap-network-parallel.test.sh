#!/usr/bin/env bash
# Concurrent deferred-network squad_lead probes must keep every per-mate
# diagnostic complete, attributed, and fail-closed.
#
# The session-start network stage used to walk remote squad_leads one after
# another. The public contract that must survive concurrency is not a particular
# worker scheduler: it is that each mate still emits its own SQUAD_LEAD_LIVENESS
# / SQUAD_LEAD_SYNC line, that those lines cannot splice into each other, and
# that a dirty or unreachable mate still refuses rather than proceeding. This
# suite drives bin/jg-bootstrap.sh's network-only phase through JG_SSH_BIN, so
# it exercises the same remote probe path a real session start uses.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${JG_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(jg_test_tmproot jg-bootstrap-network-parallel)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
mkdir -p "$TMP_ROOT/no-addons"
export JG_BACKEND_CMUX_BUNDLE_BIN="$TMP_ROOT/no-bundled-cmux"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID \
  2>/dev/null || true

command -v python3 >/dev/null 2>&1 \
  || fail "python3 is required to decode the jg-on.sh argv payload"

REAL_GIT=$(command -v git) || fail "git is required"
REAL_MKTEMP=$(command -v mktemp) || fail "mktemp is required"
jg_git_identity fmtest fmtest@example.invalid

[ -z "${JG_TEST_EVIDENCE_FILE:-}" ] || : > "$JG_TEST_EVIDENCE_FILE"

write_remote_registry_line() { # <file> <id> <host> <root> <home>
  printf -- '- %s - %s delivery (host: %s; root: %s; home: %s; scope: test work; projects: alpha; added 2026-08-02)\n' \
    "$2" "$2" "$3" "$4" "$5" >> "$1"
}

install_fake_ssh() {
  local fakebin=$1
  cat > "$fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
log=${JG_FAKE_SSH_LOG:?}
sleep_s=${JG_FAKE_SSH_SLEEP:-0.4}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=${1:-}
entry=${2:-}
shift 2 || true
[ "$entry" = jg-remote-entrypoint.sh ] || exit 92
argv_b64=${4:-}
cmd=$(python3 -c 'import sys, base64
raw = base64.b64decode(sys.argv[1])
parts = [p.decode() for p in raw.split(b"\0") if p]
print(parts[0] if parts else "")
print(parts[1] if len(parts) > 1 else "")
print(parts[2] if len(parts) > 2 else "")
' "$argv_b64")
command_name=$(printf '%s\n' "$cmd" | sed -n '1p')
subcommand=$(printf '%s\n' "$cmd" | sed -n '2p')
item_rel=$(printf '%s\n' "$cmd" | sed -n '3p')
slow=0
case "$command_name" in
  jg-remote-doctor.sh) slow=1 ;;
  jg-remote-squad-lead-control.sh)
    case "$subcommand" in state|sync) slow=1 ;; esac
    ;;
esac
if [ "$slow" -eq 1 ]; then
  printf 'START %s %s %s\n' "$host" "$command_name" "$subcommand" >> "$log"
  # Do not let scheduler latency turn the concurrency assertion into a race
  # between equal sleeps. If the fetch worker was launched concurrently, give
  # it a bounded opportunity to publish its START record.
  waited=0
  while ! grep -q '^START fleet-fetch ' "$log" && [ "$waited" -lt 500 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  sleep "$sleep_s"
  printf 'END %s %s %s\n' "$host" "$command_name" "$subcommand" >> "$log"
else
  printf 'QUICK %s %s %s\n' "$host" "$command_name" "$subcommand" >> "$log"
fi
case "$host" in
  "${JG_FAKE_SSH_UNREACHABLE_HOST:-host-bravo}")
    exit 255
    ;;
esac
case "$command_name" in
  jg-remote-doctor.sh)
    exit 0
    ;;
  jg-remote-squad-lead-control.sh)
    case "$subcommand" in
      state)
        printf 'alive\n'
        exit 0
        ;;
      route)
        printf 'backend=herdr\n'
        exit 0
        ;;
      sync)
        case "$host" in
          "${JG_FAKE_SSH_FAIL_HOST:-host-alpha}")
            printf 'synthetic tracked-file sync refusal for %s\n' "$host"
            exit 1
            ;;
          "${JG_FAKE_SSH_DIRTY_HOST:-host-charlie}")
            printf 'remote squad_lead checkout is dirty; sync skipped\n'
            exit 1
            ;;
        esac
        printf 'current: test\n'
        exit 0
        ;;
    esac
    exit 0
    ;;
  jg-remote-inherit.sh)
    case "$subcommand" in
      put) printf 'unchanged: %s\n' "$item_rel" ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/fake-ssh"
}

install_slow_git() {
  local fakebin=$1 real_git=$2 log=$3
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
set -eu
slow=0
for arg in "\$@"; do
  if [ "\$arg" = fetch ]; then
    slow=1
    break
  fi
done
if [ "\$slow" -eq 1 ]; then
  printf 'START fleet-fetch git fetch\n' >> '$log'
  waited=0
  while ! grep -q '^START host-.* jg-remote-doctor.sh ' '$log' && [ "\$waited" -lt 500 ]; do
    sleep 0.01
    waited=\$((waited + 1))
  done
  sleep "\${JG_FAKE_GIT_FETCH_SLEEP:-0.4}"
  printf 'END fleet-fetch git fetch\n' >> '$log'
fi
exec '$real_git' "\$@"
SH
  chmod +x "$fakebin/git"
}

starts_before_first_end() { # <log> <pattern>
  awk -v pat="$2" '
    $0 ~ pat && $1 == "START" { starts++ }
    $0 ~ pat && $1 == "END" {
      print starts + 0
      found = 1
      exit
    }
    END { if (!found) print starts + 0 }
  ' "$1"
}

test_remote_probe_scheduling_keeps_per_mate_lines() { # <parallel|fallback>
  local mode=$1
  local dir home primary fakebin log out n doctor_overlap liveness_starts fetch_starts
  local alpha_root alpha_home bravo_root bravo_home charlie_root charlie_home
  dir="$TMP_ROOT/parallel-lines-$mode"
  home="$dir/home"
  primary="$dir/primary"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$primary"
  git init -q -b main "$primary"
  cp -R "$ROOT/bin" "$primary/bin"
  printf 'test primary\n' > "$primary/AGENTS.md"
  git -C "$primary" add AGENTS.md bin
  git -C "$primary" commit -qm 'seed primary default branch'
  fakebin=$(jg_fakebin "$dir")
  jg_fake_exit0 "$fakebin" gh treehouse tmux node
  log="$dir/probe.log"
  : > "$log"
  install_fake_ssh "$fakebin"
  install_slow_git "$fakebin" "$REAL_GIT" "$log"
  if [ "$mode" = fallback ]; then
    cat > "$fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in *jg-bootstrap-par.XXXXXX*) exit 1 ;; esac
exec '$REAL_MKTEMP' "\$@"
SH
    chmod +x "$fakebin/mktemp"
  fi

  alpha_root="$dir/remote/alpha/root"
  alpha_home="$dir/remote/alpha/home"
  bravo_root="$dir/remote/bravo/root"
  bravo_home="$dir/remote/bravo/home"
  charlie_root="$dir/remote/charlie/root"
  charlie_home="$dir/remote/charlie/home"
  mkdir -p "$alpha_root" "$alpha_home" "$bravo_root" "$bravo_home" "$charlie_root" "$charlie_home"

  : > "$home/data/squad_leads.md"
  write_remote_registry_line "$home/data/squad_leads.md" alpha host-alpha "$alpha_root" "$alpha_home"
  write_remote_registry_line "$home/data/squad_leads.md" bravo host-bravo "$bravo_root" "$bravo_home"
  write_remote_registry_line "$home/data/squad_leads.md" charlie host-charlie "$charlie_root" "$charlie_home"

  jg_write_squad_lead_meta "$home/state/alpha.meta" "$alpha_home"
  printf 'remote_host=host-alpha\n' >> "$home/state/alpha.meta"
  jg_write_squad_lead_meta "$home/state/bravo.meta" "$bravo_home"
  printf 'remote_host=host-bravo\n' >> "$home/state/bravo.meta"
  jg_write_squad_lead_meta "$home/state/charlie.meta" "$charlie_home"
  printf 'remote_host=host-charlie\n' >> "$home/state/charlie.meta"

  jg_git_init_commit "$home/projects/alpha"
  jg_git_add_origin "$home/projects/alpha" "$dir/alpha.origin.git"

  out=$(
    PATH="$fakebin:$BASE_PATH" \
    JG_HOME="$home" \
    JG_ROOT_OVERRIDE="$primary" \
    JG_BOOTSTRAP_NETWORK=only \
    JG_SSH_BIN="$fakebin/fake-ssh" \
    JG_FAKE_SSH_LOG="$log" \
    JG_FAKE_SSH_SLEEP=0.4 \
    JG_FAKE_SSH_UNREACHABLE_HOST=host-bravo \
    JG_FAKE_SSH_FAIL_HOST=host-alpha \
    JG_FAKE_SSH_DIRTY_HOST=host-charlie \
    JG_FAKE_GIT_FETCH_SLEEP=0.4 \
    JG_ADDONS_DIR="$TMP_ROOT/no-addons" JG_INHERITABLE_CONFIG='' \
    JG_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/jg-bootstrap.sh" 2>&1
  )

  assert_contains "$out" \
    "SQUAD_LEAD_LIVENESS: squad_lead bravo: skipped: remote host unavailable or endpoint state unknown; route preserved on host-bravo" \
    "an unreachable mate must fail closed with its own liveness line"
  assert_contains "$out" \
    "SQUAD_LEAD_SYNC: squad_lead bravo: skipped:" \
    "an unreachable mate must also fail closed on convergence rather than disappearing"
  assert_contains "$out" \
    "SQUAD_LEAD_SYNC: squad_lead charlie: skipped: remote tracked-file sync failed on host-charlie:" \
    "a dirty remote mate must fail closed with its own sync line"
  assert_contains "$out" "dirty" \
    "the dirty mate's skip line must still name dirtiness"

  n=$(printf '%s\n' "$out" | grep -c 'SQUAD_LEAD_LIVENESS: squad_lead bravo:' || true)
  [ "$n" -eq 1 ] || fail "bravo liveness line was lost or duplicated (count=$n)"$'\n'"$out"
  n=$(printf '%s\n' "$out" | grep -c 'SQUAD_LEAD_SYNC: squad_lead charlie:' || true)
  [ "$n" -eq 1 ] || fail "charlie sync line was lost or duplicated (count=$n)"$'\n'"$out"
  n=$(printf '%s\n' "$out" | sed -n 's/^SQUAD_LEAD_SYNC: squad_lead \([^:]*\):.*/\1/p' | tr '\n' ' ')
  [ "$n" = "alpha bravo bravo charlie " ] \
    || fail "sync diagnostics were lost, duplicated, or replayed outside spawn order: $n"$'\n'"$out"

  assert_not_contains "$out" \
    "SQUAD_LEAD_LIVENESS: squad_lead alpha: skipped: remote host unavailable or endpoint state unknown" \
    "a reachable mate must not inherit the unreachable mate's liveness skip"
  assert_contains "$out" \
    "SQUAD_LEAD_SYNC: squad_lead alpha: skipped: remote tracked-file sync failed on host-alpha: synthetic tracked-file sync refusal for host-alpha" \
    "the first worker's diagnostic must retain its own host and complete message"
  assert_not_contains "$out" \
    "SQUAD_LEAD_SYNC: squad_lead alpha: skipped: remote tracked-file sync failed on host-alpha: remote squad_lead checkout is dirty" \
    "the first worker must not inherit the dirty mate's reason"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      SQUAD_LEAD_LIVENESS:\ squad_lead\ [A-Za-z0-9._-]*:*|SQUAD_LEAD_SYNC:\ squad_lead\ [A-Za-z0-9._-]*:*) ;;
      *) fail "a per-mate line was interleave-corrupted: $line" ;;
    esac
    n=0
    case "$line" in *" squad_lead alpha:"*) n=$((n + 1)) ;; esac
    case "$line" in *" squad_lead bravo:"*) n=$((n + 1)) ;; esac
    case "$line" in *" squad_lead charlie:"*) n=$((n + 1)) ;; esac
    [ "$n" -le 1 ] || fail "a per-mate line named more than one mate: $line"
  done <<EOF
$(printf '%s\n' "$out" | grep '^SQUAD_LEAD_' || true)
EOF

  doctor_overlap=$(starts_before_first_end "$log" 'jg-remote-doctor.sh')
  if [ "$mode" = parallel ]; then
    [ "$doctor_overlap" -ge 2 ] \
      || fail "remote liveness probes did not overlap (starts before first doctor end=$doctor_overlap)"$'\n'"$(cat "$log")"
  else
    [ "$doctor_overlap" -eq 1 ] \
      || fail "mktemp failure did not select sequential liveness fallback (starts before first doctor end=$doctor_overlap)"$'\n'"$(cat "$log")"
  fi

  liveness_starts=$(grep -c '^START .* jg-remote-squad-lead-control.sh state$' "$log" || true)
  [ "$liveness_starts" -ge 2 ] \
    || fail "expected concurrent remote state probes, got $liveness_starts"$'\n'"$(cat "$log")"

  fetch_starts=$(grep -c '^START fleet-fetch ' "$log" || true)
  [ "$fetch_starts" -ge 1 ] \
    || fail "clone refresh did not start a fetch to overlap with squad_lead probes"$'\n'"$(cat "$log")"
  awk '
    /^START fleet-fetch / { fleet = 1; if (remote) overlap = 1; next }
    /^END fleet-fetch / { fleet = 0; next }
    /^START host-/ { remote++; if (fleet) overlap = 1; next }
    /^END host-/ { remote-- }
    END { exit !overlap }
  ' "$log" || fail "clone refresh did not overlap the squad_lead sweeps"$'\n'"$(cat "$log")"

  awk '
    /END .* jg-remote-squad-lead-control.sh state$/ { last_liveness = NR }
    /START .* jg-remote-squad-lead-control.sh sync$/ && !first_sync { first_sync = NR }
    END { exit !(last_liveness && first_sync && last_liveness < first_sync) }
  ' "$log" || fail "convergence began before all liveness probes finished"$'\n'"$(cat "$log")"

  if [ -n "${JG_TEST_EVIDENCE_FILE:-}" ]; then
    {
      printf '=== %s bootstrap network output ===\n%s\n' "$mode" "$out"
      printf '=== %s remote operation timeline ===\n' "$mode"
      cat "$log"
    } >> "$JG_TEST_EVIDENCE_FILE"
  fi

  pass "bootstrap network ($mode): per-mate output stays intact, fail-closed, and correctly sequenced"
}

test_remote_inheritance_failure_names_its_own_error_not_an_unchanged_item() {
  local dir home primary fakebin log out sm_root sm_home line
  dir="$TMP_ROOT/inherit-failure"
  home="$dir/home"
  primary="$dir/primary"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$primary"
  git init -q -b main "$primary"
  cp -R "$ROOT/bin" "$primary/bin"
  printf 'test primary\n' > "$primary/AGENTS.md"
  git -C "$primary" add AGENTS.md bin
  git -C "$primary" commit -qm 'seed primary default branch'
  fakebin=$(jg_fakebin "$dir")
  jg_fake_exit0 "$fakebin" gh treehouse tmux node
  log="$dir/probe.log"
  : > "$log"
  install_fake_ssh "$fakebin"

  sm_root="$dir/remote/sm/root"
  sm_home="$dir/remote/sm/home"
  mkdir -p "$sm_root" "$sm_home"

  : > "$home/data/squad_leads.md"
  write_remote_registry_line "$home/data/squad_leads.md" sm host-sm "$sm_root" "$sm_home"
  jg_write_squad_lead_meta "$home/state/sm.meta" "$sm_home"
  printf 'remote_host=host-sm\n' >> "$home/state/sm.meta"

  jg_git_init_commit "$home/projects/alpha"
  jg_git_add_origin "$home/projects/alpha" "$dir/alpha.origin.git"

  printf '{}\n' > "$home/config/crew-dispatch.json"
  printf 'codex\n' > "$home/config/crew-harness"
  # Header omits "must not be edited there" so the local check fails before
  # any ssh call for this item, after the two config items above already
  # reported "unchanged:" from the (faked) remote.
  cat > "$home/data/captain-shared.md" <<'EOF'
# Shared captain preferences

This file is main-authoritative in the main juggernaut home.
In squad_lead homes it is read-only in squad_lead homes.
Route new captain-preference discoveries to the main juggernaut through marked status or a document pointer.
EOF

  out=$(
    PATH="$fakebin:$BASE_PATH" \
    JG_HOME="$home" \
    JG_ROOT_OVERRIDE="$primary" \
    JG_BOOTSTRAP_NETWORK=only \
    JG_SSH_BIN="$fakebin/fake-ssh" \
    JG_FAKE_SSH_LOG="$log" \
    JG_FAKE_SSH_SLEEP=0 \
    JG_FAKE_GIT_FETCH_SLEEP=0 \
    JG_INHERITABLE_CONFIG='crew-dispatch.json crew-harness' \
    JG_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/jg-bootstrap.sh" 2>&1
  )

  line=$(printf '%s\n' "$out" | grep '^SQUAD_LEAD_SYNC: squad_lead sm: skipped: remote inheritance failed on host-sm:' || true)
  [ -n "$line" ] || fail "expected a remote inheritance failure line: $out"
  case "$line" in
    *"shared captain preferences"*) ;;
    *) fail "the failure reason should name the shared captain header problem, got: $line" ;;
  esac
  case "$line" in
    *"unchanged:"*) fail "the failure reason must not report an earlier unchanged item, got: $line" ;;
  esac

  if [ -n "${JG_TEST_EVIDENCE_FILE:-}" ]; then
    printf '=== inherit-failure bootstrap output ===\n%s\n' "$out" >> "$JG_TEST_EVIDENCE_FILE"
  fi

  pass "a remote inheritance failure reports its own error line, not an earlier unchanged item"
}

test_remote_probe_scheduling_keeps_per_mate_lines parallel
test_remote_probe_scheduling_keeps_per_mate_lines fallback
test_remote_inheritance_failure_names_its_own_error_not_an_unchanged_item
echo "# all jg-bootstrap-network-parallel tests passed"
