#!/usr/bin/env bash
# fm-dashboard.sh - build the read-only fleet dashboard page for this home.
#
# Builds ONE self-contained HTML page (inline CSS and SVG, no script, no network
# reference), phone first. The top answers the common fleet questions at a
# glance: what waits on the captain, a strip of four numbers (running, finished
# but not landed, merged, queued) that each link to their list, and one health
# line each for leads, alerts, the machine and test devices. Below that: one row
# per home, devices and machine detail, the work lists (first rows shown, the
# rest one tap away), quality, seven-day trends, and missing data.
#
# Sources, all read-only and all optional:
#   bin/fm-bearings-snapshot.sh --json --all-in-flight --all-decisions
#       --all-queued --all-landed   in flight, decisions, queued, landed
#   data/metrics/prs.tsv            merged PRs (merged, first_pass, escaped, hours_to_merge)
#   data/captain-asks.tsv           Waiting on you: Main's fleet-wide headerless
#                                   id<TAB>since-epoch<TAB>text<TAB>url; physical row count,
#                                   malformed rows become notes, absent/empty means zero
#   gh api search/issues            Merged today AND yesterday: bounded local-day searches
#                                   over registered project clones (including Main), cached
#                                   5 minutes in state/dashboard/.merged-today.json;
#                                   on failure both figures use prs.tsv, marked "as of"
#   data/metrics/daily.tsv          per day and home counters (steers, stall_alarms, ...)
#   data/metrics/skills.tsv         per day, home and skill read counts
#   data/metrics/rings.tsv          leads the watcher woke itself
#   data/metrics/lanes.tsv          harness and model per home, task and PR (written by
#                                   config/fm-lane-record.sh); joined to prs.tsv by PR URL
#   data/fleet-pulse.tsv            per home flow rows (open, ready, donewait, oldestwait_h)
#   config/metrics-targets.tsv      metric, op (>= or <=), target
#   config/lane-target              open-lane target per home (default 4)
#   config/parked-homes             home ids the captain parked, one per line (# comments);
#                                   a parked home is left out of operational totals;
#                                   Main's ask list is fleet-wide, including parked homes
#   state/*.meta + *.status         Running now: ship/scout lanes, last verb working or
#                                   resolved, excluding open captain-hold keys; live homes
#   config/fm-flow-check.sh         `<home> --summary` per live home: Finished not landed
#                                   (column 5), Queued and ready (column 4); unavailable
#                                   homes use pulse rows, explicitly dated, never partial
#   data/metrics/daily.tsv          Alert counts: stall_alarms, relaunches, steers per local
#                                   calendar day; automatic wakes use rings.tsv row count
#                                   (daily.tsv self_rings only when rings.tsv unavailable)
#   data/defects.md                 "- " defect lines under "## <date>" headings
#   data/secondmates.md             registered homes (every one gets a row)
#   data/projects.md                this home's projects, and each registered
#                                   home's own data/projects.md, for home row labels
# Machine and devices, each probe read-only with a 5 s timeout; a failed probe shows
# "unknown" and its reason, never a guess or a zero:
#   adb devices -l                  connected phones and emulators (nothing else is asked of adb)
#   pgrep -a '^qemu-system'         running emulators (-avd, -port; VmRSS from <proc>/<pid>/status)
#   pgrep -cf 'appname=gradle[w]'   Gradle builds, counted as config/fm-mem-gate.sh counts them
#   systemctl --user show fm-heavy.slice   MemoryCurrent, MemoryHigh, MemoryMax
#   <proc>/meminfo, <proc>/pressure/memory   MemAvailable; "some avg10"
#   <locks>/fm-phone-<name>.lock + <proc>/locks   who holds a device now (flock by inode);
#   <locks>/fm-device-lock.log      the holder's pid, time and cwd, mapped to its home by
#                                   each home's state/*.meta worktree=, tasktmp= or task id;
#                                   an emulator matches a held lock its process ancestry took
#   <proc> is FM_DASHBOARD_PROC (default /proc), <locks> FM_DEVICE_LOCK_DIR (default /tmp);
#   FM_EMU_MAX, FM_GRADLE_MAX, FM_MEM_MIN_GB (defaults 2, 2, 12) mirror the memory gate's caps
# All day comparisons use the host timezone, including UTC timestamp conversion.
# Except captain-asks.tsv, TSV files are read by header name. A source that is absent or malformed hides
# its section behind a one-line note; it never fails the build. The snapshot's
# own parent-side ledger cache refresh is the only state it may touch besides
# the page.
#
# Usage:
#   fm-dashboard.sh [build]
#   fm-dashboard.sh serve [--bind ADDR] [--port N]
# build (the default) writes $FM_HOME/state/dashboard/index.html and prints its
# path. serve runs a small read-only web server (python3 stdlib, IPv4) that
# answers GET or HEAD for / and /index.html only; every other path is 404. It
# answers at once with the last built page, marked "updated N s ago", and keeps
# that page fresh itself: a side thread starts each rebuild early enough, by
# the last build's length, for the new page to land as the old one turns 60
# seconds old, whether or not anyone is looking, and the page reloads itself every 60
# seconds; only the very first load, with no page yet, waits for a build. It prints
# `serving http://ADDR:PORT/` once listening. ADDR defaults to 127.0.0.1 and
# PORT to 8787; port 0 picks a free port. There is no authentication: reach is
# whatever the bind address exposes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
out_dir="$FM_HOME/state/dashboard"
page="$out_dir/index.html"

usage() { echo "usage: fm-dashboard.sh [build] | serve [--bind ADDR] [--port N]" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "fm-dashboard: python3 is required" >&2; exit 1; }

cmd=${1:-build}
[ $# -gt 0 ] && shift
case "$cmd" in
  build) [ $# -eq 0 ] || usage ;;
  serve)
    bind=127.0.0.1 port=8787
    while [ $# -gt 0 ]; do
      case "$1" in
        --bind) [ $# -ge 2 ] || usage; bind=$2; shift 2 ;;
        --port) [ $# -ge 2 ] || usage; port=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    case "$port" in ''|*[!0-9]*) usage ;; esac
    exec python3 - "$0" "$FM_HOME" "$page" "$bind" "$port" <<'PY'
import http.server, os, subprocess, sys, threading, time
SCRIPT, HOME, PAGE, BIND, PORT = sys.argv[1:6]
MAX_AGE = 60
building = threading.Lock()
last_error = b''
last_took = 30.0  # seconds the last build took; a fleet snapshot alone can take 45 s under load

def build():  # call holding `building`; the build replaces the page in one rename
    global last_error, last_took
    start = time.time()
    try:
        r = subprocess.run(['bash', SCRIPT, 'build'], env=dict(os.environ, FM_HOME=HOME),
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        last_error = r.stderr if r.returncode else b''
        last_took = time.time() - start
    finally:
        building.release()

def age():
    try: return time.time() - os.path.getmtime(PAGE)
    except OSError: return None

class Handler(http.server.BaseHTTPRequestHandler):
    timeout = 10  # an idle preconnect must not hold the one-at-a-time server

    def send(self, code, body, ctype):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; img-src data:")
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(body)

    def do_GET(self):
        if self.path.split('?', 1)[0] not in ('/', '/index.html'):
            return self.send(404, b'not found\n', 'text/plain; charset=utf-8')
        a = age()
        if a is None:  # the first load ever waits for the first page
            with building: pass  # a build already under way finishes first
            if age() is None:
                building.acquire(); build()
            a = age()
            if a is None:
                return self.send(500, b'dashboard build failed: ' + last_error, 'text/plain; charset=utf-8')
        note = f' · updated {int(a)} s ago' + (' · refreshing' if building.locked() else '')
        if last_error: note += ' · last refresh failed, showing the last good page'
        with open(PAGE, 'rb') as f:
            body = f.read().replace(b'<!--age-->', note.encode(), 1)
        self.send(200, body, 'text/html; charset=utf-8')
    do_HEAD = do_GET

# ponytail: one request at a time; rebuilds run on a side thread, one at a time.
def refresh():  # rebuild on age, not on requests, so an idle phone never opens a minutes-old page
    while True:
        a = age()  # start early by the last build's length, so the new page lands as this one turns MAX_AGE
        if (a is None or a + last_took >= MAX_AGE) and building.acquire(blocking=False):
            build()
            if last_error: time.sleep(MAX_AGE)  # a failing build retries once a minute
        time.sleep(5)

threading.Thread(target=refresh, daemon=True).start()
srv = http.server.HTTPServer((BIND, int(PORT)), Handler)
print(f'serving http://{BIND}:{srv.server_address[1]}/', flush=True)
try: srv.serve_forever()
except KeyboardInterrupt: pass
PY
    ;;
  -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac

mkdir -p "$out_dir" || { echo "fm-dashboard: cannot create $out_dir" >&2; exit 1; }
# Per-run scratch names, so a manual build and a served rebuild never share files.
snap="$out_dir/.snapshot.$$.json"
snap_err="$out_dir/.snapshot.$$.err"
trap 'rm -f "$snap" "$snap_err" "$page.$$.tmp"' EXIT
# Raise the per-home bounds; a second mate's cached summary can still apply its own.
FM_HOME="$FM_HOME" FM_SNAPSHOT_SECONDMATE_QUEUED=500 FM_SNAPSHOT_SECONDMATE_DECISIONS=500 \
  "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json --all-in-flight --all-decisions \
  --all-queued --all-landed > "$snap" 2> "$snap_err" \
  || { rc=$?; : > "$snap"; printf 'fleet snapshot exited %s: %s\n' "$rc" "$(tail -n 1 "$snap_err")" >> "$snap_err"; }

python3 - "$FM_HOME" "$snap" "$snap_err" "$page.$$.tmp" <<'PY' || { echo "fm-dashboard: page build failed" >&2; exit 1; }
import html, json, math, os, re, subprocess, sys
from datetime import date, datetime, timedelta, timezone

HOME, SNAP, SNAP_ERR, OUT = sys.argv[1:5]
NOW = datetime.now().astimezone()
TODAY = NOW.date()
YDAY = TODAY - timedelta(days=1)
WEEK = [TODAY - timedelta(days=i) for i in range(6, -1, -1)]
notes = []  # (section, one-line reason) for every hidden or partial section

def esc(v): return html.escape(str(v), quote=True)
def num(v):
    try: v = float(v)
    except (TypeError, ValueError): return None
    return v if math.isfinite(v) else None
def count(v):  # a pulse count; producers write -1 or ? when they could not measure
    v = num(v)
    return int(v) if v is not None and v >= 0 and v.is_integer() else None
def fmt(v, digits=1):
    if v is None: return '–'
    return str(int(v)) if float(v).is_integer() else f'{v:.{digits}f}'
def local_day(ts):
    try: return datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone().date()
    except (AttributeError, ValueError): return None
def iso_day(s):
    try: return date.fromisoformat(s)
    except (TypeError, ValueError): return None

def tsv(rel, need, extra=()):
    """Rows of a TSV as dicts keyed by header name, or None with a note."""
    p = os.path.join(HOME, rel)
    if not os.path.isfile(p):
        notes.append((rel, 'not found')); return None
    try: lines = open(p, encoding='utf-8', errors='replace').read().splitlines()
    except OSError as e:
        notes.append((rel, f'unreadable: {e.strerror}')); return None
    head = lines[0].lstrip('# ').split('\t') if lines else []  # a config header may be a comment line
    missing = [c for c in need if c not in head]
    if missing:
        notes.append((rel, 'malformed: missing column ' + ', '.join(missing))); return None
    cols = head + list(extra[len(head):]) if extra[:len(head)] == tuple(head) else head
    rows = [dict(zip(cols, l.split('\t'))) for l in lines[1:] if l.strip() and not l.startswith('#')]
    good = [r for r in rows if all(r.get(c) for c in need)]
    if len(good) < len(rows): notes.append((rel, f'{len(rows) - len(good)} short row(s) skipped'))
    return good

# --- sources -------------------------------------------------------------
snap = None
try:
    snap = json.load(open(SNAP))
    if not isinstance(snap, dict) or snap.get('schema') != 'fm-bearings.v1': raise ValueError('unexpected schema')
except (OSError, ValueError) as e:
    err = ''
    try: err = open(SNAP_ERR, errors='replace').read().strip().splitlines()[-1]
    except (OSError, IndexError): pass
    notes.append(('fleet snapshot', err or str(e) or 'no output')); snap = None

prs = tsv('data/metrics/prs.tsv', ('home', 'merged', 'first_pass'))
daily = tsv('data/metrics/daily.tsv', ('day', 'home'))
skills = tsv('data/metrics/skills.tsv', ('day', 'home', 'skill', 'reads'))
rings = tsv('data/metrics/rings.tsv', ('day', 'home'))
# Older pulse files keep their first 6-column header while rows carry the later columns.
PULSE = ('time', 'home', 'merged2h', 'working', 'paused', 'blocked', 'open', 'ready', 'donewait',
         'oldestwait_h', 'min_since_working', 'leadkeys2h', 'rulewords')
pulse = tsv('data/fleet-pulse.tsv', ('time', 'home'), PULSE)
targets = tsv('config/metrics-targets.tsv', ('metric', 'op', 'target'))
lane_target = 4
try: lane_target = int(open(os.path.join(HOME, 'config/lane-target')).read().split()[0])
except (OSError, ValueError, IndexError): pass

def project_names(path):  # {name: has standing merge authority (+yolo)} from "- <name> [mode] - ..." lines, or None when absent
    try: return {m.group(1): '+yolo' in m.group(2).split()
                 for m in re.finditer(r'^- (\S+) \[([^\]]*)\]', open(path, encoding='utf-8', errors='replace').read(), re.M)}
    except OSError: return None
projects = {'main': project_names(os.path.join(HOME, 'data/projects.md'))}
if projects['main'] is None: notes.append(('data/projects.md', 'not found'))
registered = set()
home_dir = {'main': HOME}
try:
    for l in open(os.path.join(HOME, 'data/secondmates.md'), encoding='utf-8', errors='replace'):
        m = re.match(r'- (\S+) - ', l)
        if not m: continue
        registered.add(m.group(1))
        # The routing fields close the line; greedy .* lands on the last "(home:".
        f = re.match(r'.*\(home: ([^;]*);.*; projects: ([^;)]*)', l)
        if f: home_dir[m.group(1)] = f.group(1).strip()
        own = project_names(os.path.join(f.group(1).strip(), 'data/projects.md')) if f else None
        projects[m.group(1)] = own if own is not None else {x.strip(): False for x in f.group(2).split(',') if x.strip()} if f else {}
except OSError: pass  # no registered homes
parked = set()
try:
    for l in open(os.path.join(HOME, 'config/parked-homes'), encoding='utf-8', errors='replace'):
        if l.split('#', 1)[0].strip(): parked.add(l.split('#', 1)[0].strip())
except OSError: pass  # no parked homes

def merged_today_live():
    """Two bounded local-day counts from GitHub, with the same fleet scope for both."""
    cache = os.path.join(HOME, 'state/dashboard/.merged-today.json')
    try:
        c = json.load(open(cache))
        if not isinstance(c, dict): c = {}
    except (OSError, ValueError, KeyError, TypeError): c = {}
    repo_home = {}  # owner/name -> home: the home named like the repo, else the first home that clones it
    for h, d in sorted(home_dir.items()):
        for pj in sorted(os.listdir(os.path.join(d, 'projects')) if os.path.isdir(os.path.join(d, 'projects')) else []):
            u = subprocess.run(['git', '-C', os.path.join(d, 'projects', pj), 'remote', 'get-url', 'origin'],
                               capture_output=True, text=True).stdout.strip()
            r = re.sub(r'\.git$', '', re.sub(r'^.*github\.com[:/]', '', u))
            if '/' in r and (r not in repo_home or r.split('/')[1] == h): repo_home[r] = h
    if not repo_home: return None
    scope = ['merged-range-v1', sorted(repo_home.items()), sorted(parked), str(NOW.tzinfo)]
    scope = json.loads(json.dumps(scope))
    at, yh, th = c.get('at'), c.get('yesterday'), c.get('homes')
    if c.get('scope') == scope and c.get('day') == TODAY.isoformat() and isinstance(yh, dict) and isinstance(th, dict) and isinstance(at, (int, float)) and math.isfinite(at) and 0 <= NOW.timestamp() - at < 300:
        return c
    counts = {}
    for day in (TODAY, YDAY):
        since = datetime.combine(day, datetime.min.time()).astimezone().astimezone(timezone.utc)
        end = datetime.combine(day + timedelta(days=1), datetime.min.time()).astimezone().astimezone(timezone.utc) - timedelta(seconds=1)
        q = ' '.join(f'owner:{o}' for o in sorted({r.split('/')[0] for r in repo_home})) + \
            f' is:pr is:merged merged:{since:%Y-%m-%dT%H:%M:%SZ}..{end:%Y-%m-%dT%H:%M:%SZ}'
        try:
            r = subprocess.run(['gh', 'api', '-X', 'GET', 'search/issues', '--paginate', '--slurp', '-f', f'q={q}', '-f', 'per_page=100'],
                               capture_output=True, text=True, timeout=30)
            if r.returncode: raise ValueError((r.stderr.strip().splitlines() or [f'exit {r.returncode}'])[-1])
            pages = json.loads(r.stdout)
            if not pages or any(p.get('incomplete_results') or p.get('total_count', 0) > 1000 for p in pages):
                raise ValueError('search incomplete or exceeds GitHub search limit')
            items = {i['id']: i for p in pages for i in p['items']}
            if len(items) != pages[0]['total_count']: raise ValueError('search returned a partial count')
            homes = {h: 0 for h in set(repo_home.values()) - parked}
            for i in items.values():
                h = repo_home.get('/'.join(i['repository_url'].rstrip('/').split('/')[-2:]))
                if h in homes: homes[h] += 1
            counts['homes' if day == TODAY else 'yesterday'] = homes
        except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError) as e:
            notes.append(('GitHub merged-today search', str(e))); return None
    counts.update(day=TODAY.isoformat(), at=NOW.timestamp(), scope=scope)
    try:
        with open(cache + '.tmp', 'w') as f: json.dump(counts, f)
        os.replace(cache + '.tmp', cache)
    except OSError: pass  # no cache only means the next build searches again
    return counts
live_counts = merged_today_live()
live_merged = live_counts['homes'] if live_counts is not None else None

# Finished, not landed: counted now from each live home's records by the check the pulse runs.
fresh_done, fresh_ready = {}, {}
flow = os.path.join(HOME, 'config/fm-flow-check.sh')
if os.access(flow, os.X_OK):
    for h, d in home_dir.items():
        if h in parked: continue
        try:
            r = subprocess.run([flow, d, '--summary'], capture_output=True, text=True, timeout=30)
            v = count((r.stdout.split('\t') + [''] * 5)[4]) if r.returncode == 0 else None
            if v is None: notes.append(('config/fm-flow-check.sh', f'{h}: ' + ((r.stderr.strip().splitlines() or [f'exit {r.returncode}'])[-1] if r.returncode else 'no count in its summary')))
            else: fresh_done[h] = v
            ready = count((r.stdout.split('\t') + [''] * 4)[3]) if r.returncode == 0 else None
            if ready is not None: fresh_ready[h] = ready
        except (OSError, subprocess.TimeoutExpired) as e:
            notes.append(('config/fm-flow-check.sh', f'{h}: {e}'))

defects = None
dp = os.path.join(HOME, 'data/defects.md')
if os.path.isfile(dp):
    defects, cur = [], None
    for l in open(dp, encoding='utf-8', errors='replace'):
        h = re.match(r'## (\d{4}-\d\d-\d\d)', l)
        if l.startswith('## '): cur = h.group(1) if h else None
        elif l.startswith('- ') and cur:
            st = re.search(r'\b(OPEN|FIXED|RETRO)\b[^A-Za-z]*$', l.strip())
            defects.append(dict(day=cur, text=l[2:].strip(), status=st.group(1) if st else ''))
else:
    notes.append(('data/defects.md', 'not found'))

# --- derived numbers -----------------------------------------------------
def dsum(col, day, home=None):
    if daily is None: return None
    vals = [count(r.get(col)) for r in daily if iso_day(r['day']) == day and (home is None or r['home'] == home)]
    if any(v is None for v in vals):
        problem = ('data/metrics/daily.tsv', f'invalid {col} count for {day}')
        if problem not in notes: notes.append(problem)
        return None
    return sum(vals)

merged_on = {}
for p in prs or []:
    d = local_day(p['merged'])
    if d: merged_on.setdefault(d, []).append(p)
def merged(day, home=None):
    if prs is None: return None
    return len([p for p in merged_on.get(day, []) if home is None or p['home'] == home])
def merged_live(day): return None if prs is None else len([p for p in merged_on.get(day, []) if p['home'] not in parked])
def first_pass_pct(days):
    ps = [p for d in days for p in merged_on.get(d, [])]
    return 100 * sum(p['first_pass'] == '1' for p in ps) // len(ps) if ps else None  # floored, as the retro report does

latest = {}  # home -> latest measured pulse row
for r in pulse or []:
    if count(r.get('donewait')) is not None or count(r.get('open')) is not None:
        latest[r['home']] = r
def pulse_day(col, day):  # each home's last row of that day, summed
    rows = {}
    for r in pulse or []:
        if r['time'][:10] == day.isoformat() and count(r.get(col)) is not None: rows[r['home']] = count(r[col])
    return sum(rows.values()) if rows else None

def home_of_task(tid): return tid.split('/', 1)[0] if '/' in tid else 'main'
def owner_home(o): return 'main' if o in ('(main)', None, '') else o
in_flight = (snap or {}).get('in_flight') or []
asks, asks_known, ask_ids = [], True, set()
try:
    for n, line in enumerate(open(os.path.join(HOME, 'data/captain-asks.tsv'), encoding='utf-8', errors='replace'), 1):
        fields = line.rstrip('\r\n').split('\t')
        valid = len(fields) == 4 and fields[0].strip() and fields[2].strip() and re.fullmatch(r'[0-9]{1,10}', fields[1]) and fields[0] not in ask_ids
        if valid: ask_ids.add(fields[0])
        try: epoch = int(fields[1]) if valid else None
        except (ValueError, OverflowError): epoch = None
        if epoch is None: age = None
        elif epoch > int(NOW.timestamp()): age = None
        else: age = max(0, int(NOW.timestamp()) - epoch)
        asks.append((fields, age))
        if age is None: notes.append(('data/captain-asks.tsv', f'malformed row {n}'))
except FileNotFoundError: pass
except OSError as e:
    asks_known = False
    notes.append(('data/captain-asks.tsv', f'unreadable: {e.strerror}'))

running = {}
for h, d in sorted(home_dir.items()):
    if h in parked: continue
    running[h] = 0
    try:
        for filename in sorted(os.listdir(os.path.join(d, 'state'))):
            if not filename.endswith('.meta'): continue
            meta = dict(l.strip().split('=', 1) for l in open(os.path.join(d, 'state', filename), errors='replace') if '=' in l)
            if meta.get('kind') not in ('ship', 'scout'): continue
            try: ls = [l.strip() for l in open(os.path.join(d, 'state', filename[:-5] + '.status'), errors='replace') if l.strip()]
            except FileNotFoundError: ls = []
            keys = set()
            verb = 'working'
            for l in ls:
                v = re.match(r'^(?:\d{9,11}\s+)?([a-z][a-z-]*)', l)
                verb = v.group(1) if v else 'unknown'
                k = re.search(r'\[key=([^\]]+)\]', l)
                key = k.group(1) if k else 'default'
                if verb in ('done', 'failed'): keys.clear()
                elif verb in ('blocked', 'needs-decision'): keys.add(key)
                elif verb in ('resolved', 'captain-held'): keys.discard(key)
            running[h] += verb in ('working', 'resolved') and not any(k.startswith('captain-hold') for k in keys)
    except OSError as e:
        running[h] = None
        notes.append(('lane records', f'{h}: {e.strerror}'))
gates = (snap or {}).get('gates') or []
landed = (snap or {}).get('landed') or []
leads = {s.get('id'): s for s in (snap or {}).get('secondmates') or []}
measured = {p['home'] for p in prs or []} | {r['home'] for r in daily or []}
measured.discard('main')  # main carries only fleet-wide counters (captain messages, defects)

# Quality window: today and yesterday, matching the retro's default report.
QWIN = [YDAY, TODAY]
def window_metrics(home=None):
    ps = [p for d in QWIN for p in merged_on.get(d, []) if home is None or p['home'] == home]
    n = len(ps)
    def dw(col): return sum(dsum(col, d, home) or 0 for d in QWIN) if daily is not None else None
    hrs = sorted(v for v in (num(p.get('hours_to_merge')) for p in ps) if v is not None)
    per = lambda v: round(v / n, 2) if n and v is not None else None
    steers, dec, blk = dw('steers'), dw('decisions'), dw('blocks')
    return {
        'first_pass': (100 * sum(p['first_pass'] == '1' for p in ps) // n if n else None) if prs is not None else None,
        'escaped': sum((num(p.get('escaped')) or 0) > 0 for p in ps) if prs is not None else None,
        'p90_hours': hrs[int(0.9 * (len(hrs) - 1))] if hrs else None,
        'corrections_per_merge': per(dw('s_correct')),
        'interventions_per_merge': per(None if steers is None else steers + (dec or 0) + (blk or 0)),
        'captain_per_merge': per(dw('captain_msgs')),
        'stall_alarms': dw('stall_alarms'),
    }, n
QLABEL = {'first_pass': ('First-pass merges', '%'), 'escaped': ('Bugs that escaped', ''),
          'p90_hours': ('Slowest merges (p90)', ' h'), 'corrections_per_merge': ('Corrections per merge', ''),
          'interventions_per_merge': ('Main nudges per merge', ''), 'captain_per_merge': ('Captain messages per merge', ''),
          'stall_alarms': ('Lead stalls that reached Main', '')}
def misses(v, op, t): return v is not None and (v < t if op == '>=' else v > t)

# --- machine and devices: read-only probes, each with a short timeout ------
# A probe that fails says "unknown" and why; it never guesses a value or a zero.
PROC = os.environ.get('FM_DASHBOARD_PROC', '/proc')
LOCK_DIR = os.environ.get('FM_DEVICE_LOCK_DIR', '/tmp')
def env_int(name, default):
    try: return int(os.environ.get(name, default))
    except ValueError: return default
EMU_MAX, GRADLE_MAX, MEM_MIN_GB = env_int('FM_EMU_MAX', 2), env_int('FM_GRADLE_MAX', 2), env_int('FM_MEM_MIN_GB', 12)

def probe(cmd, ok=(0,)):
    """(stdout, None) from a read-only command, or (None, reason)."""
    try: r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    except FileNotFoundError: return None, f'{cmd[0]} not found'
    except subprocess.TimeoutExpired: return None, f'{cmd[0]} gave no answer in 5 s'
    except OSError as e: return None, f'{cmd[0]}: {e.strerror}'
    if r.returncode not in ok: return None, (r.stderr.strip().splitlines() or [f'{cmd[0]} exit {r.returncode}'])[-1]
    return r.stdout, None
def read(rel):
    try: return open(os.path.join(PROC, rel), errors='replace').read(), None
    except OSError as e: return None, f'{PROC}/{rel}: {e.strerror}'
def gb(kib): return kib / 1048576

def machine():
    m = {}
    t, err = read('meminfo')
    kv = dict(re.findall(r'^(\w+):\s+(\d+)', t or '', re.M))
    m['free'] = (gb(int(kv['MemAvailable'])), gb(int(kv['MemTotal']))) if 'MemAvailable' in kv and 'MemTotal' in kv else None
    m['free_why'] = err or 'no MemAvailable in meminfo'
    t, err = read('pressure/memory')
    p = re.search(r'^some avg10=([0-9.]+)', t or '', re.M)
    m['pressure'], m['pressure_why'] = (float(p.group(1)) if p else None), err or 'no "some avg10" line'
    out, err = probe(['systemctl', '--user', 'show', 'fm-heavy.slice', '-p', 'MemoryCurrent', '-p', 'MemoryHigh', '-p', 'MemoryMax'])
    kv = dict(l.split('=', 1) for l in (out or '').splitlines() if '=' in l)
    def size(v): return int(v) / 2**30 if (v or '').isdigit() else None
    m['heavy'] = (size(kv.get('MemoryCurrent')), size(kv.get('MemoryHigh')), size(kv.get('MemoryMax')))
    m['heavy_why'] = err or f"MemoryCurrent is {kv.get('MemoryCurrent', 'missing')}"
    out, err = probe(['pgrep', '-cf', 'appname=gradle[w]'], ok=(0, 1))  # the memory gate's own count
    m['gradle'], m['gradle_why'] = (int(out.split()[0]) if out and out.split()[0].isdigit() else None), err or 'no count'
    return m

def emulators():
    """[{pid, avd, port, rss}] from the running qemu processes, or (None, reason)."""
    out, err = probe(['pgrep', '-a', '^qemu-system'], ok=(0, 1))
    if out is None: return None, err
    emus = []
    for l in out.splitlines():
        pid, _, args = l.partition(' ')
        a = args.split()
        opt = lambda k: a[a.index(k) + 1] if k in a[:-1] else None
        st, _ = read(f'{pid}/status')
        rss = re.search(r'^VmRSS:\s+(\d+)', st or '', re.M)
        emus.append(dict(pid=pid, avd=opt('-avd') or '?', port=opt('-port'), rss=gb(int(rss.group(1))) if rss else None))
    return emus, None

def lock_holders():
    """{lock name: {held, pid, cwd, at, last, verb}} from the device locks, /proc/locks and the lock log."""
    t, err = read('locks')
    held = set(re.findall(r'^\d+:\s+FLOCK\s+\S+\s+\S+\s+\d+\s+(\S+)', t or '', re.M))
    locks = {}
    try: names = sorted(f for f in os.listdir(LOCK_DIR) if f.startswith('fm-phone-') and f.endswith('.lock'))
    except OSError: names = []
    for f in names:
        try: s = os.stat(os.path.join(LOCK_DIR, f))
        except OSError: continue
        key = f'{os.major(s.st_dev):02x}:{os.minor(s.st_dev):02x}:{s.st_ino}'
        locks[f[9:-5]] = dict(held=None if t is None else key in held)
    try:
        for l in open(os.path.join(LOCK_DIR, 'fm-device-lock.log'), errors='replace'):
            f = l.split()
            if len(f) < 3: continue
            at = datetime.fromisoformat(f[0].replace('Z', '+00:00')) if re.match(r'\d{4}-\d\d-\d\dT', f[0]) else None
            d = locks.setdefault(f[1], dict(held=None if t is None else False))
            d.update(last=at, verb=f[2])
            if f[2] == 'acquired':
                kv = dict(x.split('=', 1) for x in f[3:] if '=' in x)
                d.update(pid=kv.get('pid'), at=at, cwd=l.split(' cwd=', 1)[1].strip() if ' cwd=' in l else None)
    except OSError: pass
    return locks, err

def worktree_homes():  # every task's worktree and id, and each home itself, mapped to its home
    m = {}
    for h, d in home_dir.items():
        m[os.path.realpath(d)] = h
        try:
            for f in os.listdir(os.path.join(d, 'state')):
                if not f.endswith('.meta'): continue
                m[f[:-5]] = h  # a worker's own scratch dir is often named after its task id
                for l in open(os.path.join(d, 'state', f), errors='replace'):
                    k, _, v = l.strip().partition('=')
                    if k in ('worktree', 'tasktmp') and v: m[os.path.realpath(v)] = h
        except OSError: pass
    return m
def who(cwd, homes_by_path):
    if not cwd: return 'an unknown worker'
    p = os.path.realpath(cwd)
    while p not in homes_by_path and os.path.dirname(p) != p: p = os.path.dirname(p)
    h = homes_by_path.get(p)
    base = os.path.basename(cwd.rstrip('/'))
    h = h or homes_by_path.get(base) or homes_by_path.get(base.removeprefix('fm-'))
    return ('Main' if h == 'main' else h) if h else base
def ago(at):
    if at is None: return ''
    s = max(0, int(NOW.timestamp() - at.timestamp()))
    return 'under a minute' if s < 60 else f'{s // 60} min' if s < 3600 else f'{s // 3600} h {s % 3600 // 60} min' if s < 86400 else f'{s // 86400} d'
def ancestors(pid):
    seen = []
    for _ in range(40):
        t, _ = read(f'{pid}/stat')
        m = re.match(r'\d+ \(.*\) \S (\d+)', t or '', re.S)
        if not m or m.group(1) in ('0', '1'): break
        pid = m.group(1); seen.append(pid)
    return seen

def devices():
    """(rows, summary) for every adb device, every running emulator and every held device lock."""
    out, adb_err = probe(['adb', 'devices', '-l'])
    emus, emu_err = emulators()
    locks, lock_err = lock_holders()
    homes_by_path = worktree_homes()
    held_by_pid = {d['pid']: n for n, d in locks.items() if d.get('held') and d.get('pid')}
    rows, seen_locks = [], set()
    def holder(names, pids=()):
        """(text, tone) for the first held lock among names, else via a held lock an ancestor process took."""
        for n in names:
            d = locks.get(n)
            if d and d.get('held'):
                seen_locks.add(n); return f'In use by {who(d.get("cwd"), homes_by_path)} · {ago(d.get("at"))}', 'warn'
        for p in pids:
            if p in held_by_pid:
                d = locks[held_by_pid[p]]; seen_locks.add(held_by_pid[p])
                return f'In use by {who(d.get("cwd"), homes_by_path)} · {ago(d.get("at"))}', 'warn'
        if lock_err: return f'unknown: {lock_err}', ''  # no lock state, so free is a guess
        d = next((locks[n] for n in names if n in locks), None)
        if d and d.get('at'):
            return f'Free · last used by {who(d.get("cwd"), homes_by_path)} {ago(d.get("last"))} ago', 'ok'
        return 'Free', 'ok'
    emu_by_port = {e['port']: e for e in emus or [] if e['port']}
    serials = []
    for l in (out or '').splitlines()[1:]:
        f = l.split()
        if len(f) < 2: continue
        serials.append(f[0])
        kv = dict(x.split(':', 1) for x in f[2:] if ':' in x)
        e = emu_by_port.pop(f[0][9:], None) if f[0].startswith('emulator-') else None
        if e:
            name, sub = f'Emulator {e["avd"]}', f'{f[0]}' + (f' · {e["rss"]:.1f} GB in use' if e['rss'] is not None else '')
            text, tone = holder([f[0], e['avd']], ancestors(e['pid']))
        else:
            name, sub = (kv.get('model') or 'Device').replace('_', ' '), f'{f[0]}' + (' · USB' if 'usb' in kv else '')
            name = ('Emulator ' if f[0].startswith('emulator-') else 'Phone ') + name
            text, tone = holder([f[0]])
        if f[1] != 'device': text, tone = f'{f[1].capitalize()} · {text}', 'bad'
        rows.append((name, sub, text, tone))
    for e in emu_by_port.values() if emus is not None else []:  # running, but adb does not list it
        text, tone = holder([f'emulator-{e["port"]}', e['avd']], ancestors(e['pid']))
        rows.append((f'Emulator {e["avd"]}', 'not listed by adb' + (f' · {e["rss"]:.1f} GB in use' if e['rss'] is not None else ''), text, tone))
    for n, d in sorted(locks.items()):  # a held lock no device above accounts for
        if d.get('held') and n not in seen_locks and n not in serials:
            rows.append((f'Lock {n}', 'no matching device', f'Held by {who(d.get("cwd"), homes_by_path)} · {ago(d.get("at"))}', 'warn'))
    problems = [f'adb: {adb_err}'] if out is None else []
    if emus is None: problems.append(f'emulators: {emu_err}')
    if lock_err: problems.append(f'device locks: {lock_err}')
    return rows, len(serials) if out is not None else None, len(emus) if emus is not None else None, problems

mach = machine()
dev_rows, dev_count, emu_count, dev_problems = devices()

# --- html pieces ---------------------------------------------------------
def note(section, reason): return f'<p class="note">{esc(section)}: {esc(reason)}. This part is hidden.</p>'
def chip(text, tone=''): return f'<span class="chip {tone}">{esc(text)}</span>'
def dot(tone=''): return f'<i class="dot {tone}"></i>'
def link(text, url):
    return f'<a href="{esc(url)}" rel="noreferrer">{esc(text)}</a>' if re.match(r'https?://', url or '') else esc(text)
ANCHOR = {'Running now': 'running', 'Finished, not landed': 'homes', 'Merged today': 'landed', 'Queued and ready': 'queued'}
def tile(label, value, sub, tone=''):  # one cell of the work strip, linked to the list behind it
    return (f'<a class="m {tone}" href="#{ANCHOR.get(label, "work")}"><span class="ml">{esc(label)}</span>'
            f'<b class="mv">{value}</b><small>{sub}</small></a>')
def hrow(label, value, tone, href):
    return f'<a class="hr" href="#{href}">{dot(tone)}<span>{esc(label)}</span><b>{value}</b></a>'
def panel(title, body, id_='', extra=''):
    return f'<div class="panel"{f" id={id_}" if id_ else ""}><div class="ph"><h3>{esc(title)}</h3>{extra}</div>{body}</div>'

def bars(values):
    vals = [v for v in values if v is not None]
    top = max(vals) if vals and max(vals) > 0 else 1
    w, gap, h = 16, 5, 32
    parts = []
    for i, (d, v) in enumerate(zip(WEEK, values)):
        x = i * (w + gap)
        if v is None:
            parts.append(f'<rect x="{x}" y="{h-2}" width="{w}" height="2" class="b0"><title>{d:%a %d %b}: no data</title></rect>')
            continue
        bh = max(2, round(h * v / top))
        parts.append(f'<rect x="{x}" y="{h-bh}" width="{w}" height="{bh}" rx="2" class="{"bt" if d == TODAY else "b"}"><title>{d:%a %d %b}: {fmt(v)}</title></rect>')
    return f'<svg viewBox="0 0 {7*w+6*gap} {h}" class="spark" role="img" aria-label="last 7 days">{"".join(parts)}</svg>'

def trend(label, values, kind='count', week=None):
    """The header sums the week (count), shows its peak (level) or the week's rate (pct); never today alone, which the strip owns."""
    vals = [x for x in values if x is not None]
    if not vals: total = '<small>no data</small>'
    elif kind == 'count': total = f'{fmt(sum(vals))} <small>in 7 days</small>'
    elif kind == 'level': total = f'<small>peak</small> {fmt(max(vals))}'
    else: total = f'{fmt(week)}% <small>in 7 days</small>' if week is not None else '<small>no data</small>'
    return (f'<div class="trend"><div class="trh"><span>{esc(label)}</span><b>{total}</b></div>'
            f'{bars(values)}<div class="trf"><span>{WEEK[0]:%a}</span><span>today</span></div></div>')

def rows_more(rs, n=6, what='all'):  # the first rows, the rest one tap away
    return ''.join(rs[:n]) + (f'<details class="more"><summary>Show {what} {len(rs)}</summary>{"".join(rs[n:])}</details>' if len(rs) > n else '')
def row(main, meta='', right=''):
    return f'<div class="row"><div class="rm">{main}</div><div class="rx">{meta}{right}</div></div>'

STATE_WORDS = {'working': ('Working', 'ok'), 'paused': ('Waiting', 'warn'), 'blocked': ('Blocked', 'bad'),
               'needs-decision': ('Needs a decision', 'bad'), 'done': ('Finished', 'ok'), 'failed': ('Failed', 'bad'),
               'unknown': ('Status unclear', 'warn')}
# A lead's open decision is its own until Main puts it on the ask list, so it never reads "Waiting on you" here.
LEAD_WORDS = {'captain_decision': ('Holding a decision', 'warn'), 'externally_held': ('Waiting on someone else', 'warn'),
              'unknown': ('Records need tidy-up', 'bad'), 'working': ('Working', 'ok'), 'idle': ('Idle', ''),
              'active_child_work': ('Working', 'ok'), 'no_active_work': ('Idle', ''),
              'stale': ('Not responding', 'bad'), 'dead': ('Stopped', 'bad')}

# --- page ----------------------------------------------------------------

# 1. Work strip
t = []
if running and all(v is not None for v in running.values()):
    t.append(tile('Running now', sum(running.values()), ''))
def pulse_at(at):  # a pulse row's time as a reader says it: 14:05 today, else 06 Oct 14:05
    return at[11:16] if at[:10] == TODAY.isoformat() else f'{at[8:10]} {datetime.strptime(at[5:7], "%m"):%b} {at[11:16]}' if len(at) >= 16 else at
def done_waiting(h):  # (count, pulse time when it is not fresh)
    if h in fresh_done: return fresh_done[h], None
    r = latest.get(h, {})
    return (count(r['donewait']), r['time']) if count(r.get('donewait')) is not None else (None, None)
dws = [done_waiting(h) for h in (set(home_dir) | set(latest)) - parked]
if any(v is not None for v, _ in dws):
    nl = sum(v for v, _ in dws) if all(v is not None for v, _ in dws) else None
    old = min((at for _, at in dws if at), default=None)  # the oldest pulse row still in the total
    t.append(tile('Finished, not landed', fmt(nl), f'as of {esc(pulse_at(old))}' if old else '', 'warn' if nl else ''))
if live_merged is not None:
    t.append(tile('Merged today', sum(live_merged.values()), f'yesterday {sum(live_counts["yesterday"].values())} · GitHub as of {datetime.fromtimestamp(live_counts["at"]).strftime("%H:%M")}'))
elif prs is not None:
    asof = datetime.fromtimestamp(os.path.getmtime(os.path.join(HOME, 'data/metrics/prs.tsv'))).strftime('%H:%M')
    t.append(tile('Merged today', merged_live(TODAY), f'yesterday {merged_live(YDAY)} · as of {asof}'))
ready_rows = [(fresh_ready[h], None) if h in fresh_ready else (count(latest.get(h, {}).get('ready')), latest.get(h, {}).get('time'))
              for h in sorted((set(home_dir) | set(latest)) - parked)]
if ready_rows:
    ready = sum(v for v, _ in ready_rows) if all(v is not None for v, _ in ready_rows) else None
    old = min((at for _, at in ready_rows if at), default=None)
    t.append(tile('Queued and ready', fmt(ready), f'as of {esc(pulse_at(old))}' if old else ''))

# 2. Waiting on you: Main's ask list, every ask a link with its age
def age_words(s): return f'{s // 60} min' if s < 3600 else f'{s // 3600} h {s % 3600 // 60} min' if s < 86400 else f'{s // 86400} d {s % 86400 // 3600} h'
ask_rows = []
for fields, age in asks:
    if age is None:
        ask_rows.append(f'<div class="ask">{dot("bad")}<span>Ask record needs correction</span>{chip("Malformed row", "bad")}</div>')
    elif re.match(r'https?://', fields[3]):
        ask_rows.append(f'<a class="ask" href="{esc(fields[3])}" rel="noreferrer">{dot("warn")}<span>{esc(fields[2])}</span><time>{age_words(age)}</time></a>')
    else:
        ask_rows.append(f'<div class="ask">{dot("warn")}<span>{esc(fields[2])}</span><time>{age_words(age)}</time></div>')
if not asks_known: ask_body = note('ask list', 'unreadable')
elif not asks: ask_body = '<p class="calm">Nothing needs you right now.</p>'
else: ask_body = rows_more(ask_rows, 5)
asks_card = (f'<section class="asks {("warn" if asks else "ok") if asks_known else ""}" id="asks"><div class="ah"><h2>Waiting on you</h2>'
             f'<b class="an">{len(asks) if asks_known else "–"}</b></div>{ask_body}</section>')

# 3. Health: leads, alerts, machine, devices - one line each
health = []
live_leads = {h: s for h, s in leads.items() if h and h not in parked and not str(h).startswith('(')}
down = {e.get('id') for e in (snap or {}).get('unhealthy_endpoints') or []} & set(live_leads)
if snap is None: health.append(('Leads', 'unknown: fleet snapshot unavailable', '', 'homes'))
else:
    tidy = [h for h, s in live_leads.items() if h not in down and LEAD_WORDS.get(s.get('state'), ('', ''))[1] == 'bad']
    v = f'{len(live_leads) - len(down)} of {len(live_leads)} running' + (f' · {len(tidy)} need{"s" if len(tidy) == 1 else ""} tidy-up' if tidy else '')
    health.append(('Leads', v + (f' · not running: {", ".join(sorted(down))}' if down else ''), 'bad' if down else 'warn' if tidy else 'ok', 'homes'))

panels_q = []
if daily is not None:
    def rung(day):  # the ring log is appended every pass; the daily roll-up only every 2 h
        if rings is None: return dsum('self_rings', day)
        return len([r for r in rings if iso_day(r['day']) == day])
    st_t, sr_t, rl_t = dsum('stall_alarms', TODAY), rung(TODAY), dsum('relaunches', TODAY)
    st_y, sr_y, rl_y = dsum('stall_alarms', YDAY), rung(YDAY), dsum('relaunches', YDAY)
    if st_t is None or sr_t is None:
        verdict, tone = 'Alert counts unavailable: records need correction.', ''
    elif st_t and not sr_t:
        verdict, tone = f'Not automatic yet: {st_t} lead stall{"s" if st_t != 1 else ""} reached Main and the watcher woke no lead itself.', 'bad'
    elif st_t:
        verdict, tone = f'Partly automatic: the watcher woke {sr_t} lead{"s" if sr_t != 1 else ""} itself, but {st_t} stall{"s" if st_t != 1 else ""} still reached Main.', 'warn'
    else:
        verdict, tone = 'Working: no lead stall reached Main today.', 'ok'
    health.append(('Alerts', 'unknown: records need correction' if st_t is None or sr_t is None else
                   f'{st_t} stall{"s" if st_t != 1 else ""} reached Main today · {sr_t} woken automatically' if st_t else
                   'No stall reached Main today', tone, 'alerts'))
    woke = ''
    if rings is not None:
        names = {}
        for r in rings:
            if iso_day(r['day']) == TODAY: names[r['home']] = names.get(r['home'], 0) + 1
        woke = '<p class="small">Woken today: ' + (esc(', '.join(f'{h} ×{n}' if n > 1 else h for h, n in sorted(names.items()))) or 'none') + '</p>'
    else:
        woke = '<p class="small muted">Per-lead wake record not found yet.</p>'
    def stat(label, a, b, tone_=''):
        return f'<div class="stat {tone_}"><b>{fmt(a)}</b><span>{esc(label)}</span><i>yesterday {fmt(b)}</i></div>'
    panels_q.append(panel('Are the alerts working?', f'''<p class="verdict {tone}">{esc(verdict)}</p>
<div class="stats">{stat("stalls reached Main", st_t, st_y, "bad" if st_t and not sr_t else ("warn" if st_t else ""))}{stat("leads woken automatically", sr_t, sr_y)}{stat("stopped leads restarted", rl_t, rl_y)}{stat("Main messages to leads", dsum("steers", TODAY), dsum("steers", YDAY))}</div>{woke}''', 'alerts'))
else:
    health.append(('Alerts', 'unknown: data/metrics/daily.tsv not available', '', 'alerts'))
    panels_q.append(panel('Are the alerts working?', note('data/metrics/daily.tsv', 'not available'), 'alerts'))

free, psi, (hc_, hh_, hm_) = mach['free'], mach['pressure'], mach['heavy']
gate_wait = (free is not None and free[0] < MEM_MIN_GB) or (psi is not None and psi >= 40)
at_cap = ' and '.join(x for x, full in (('emulators', (emu_count or 0) >= EMU_MAX), ('builds', (mach['gradle'] or 0) >= GRADLE_MAX)) if full)
mv = ' · '.join(x for x in (f'{free[0]:.0f} GB free' if free else '', f'pressure {psi:.0f}%' if psi is not None else '') if x)
health.append(('Machine', (mv + (' · heavy jobs wait' if gate_wait else f' · {at_cap} at cap' if at_cap else '')) if mv else f'unknown: {mach["free_why"]}',
               'bad' if gate_wait else 'warn' if at_cap else 'ok' if mv else '', 'machine'))
in_use = sum(1 for r in dev_rows if r[2].startswith(('In use', 'Held')))
if dev_count is None: health.append(('Devices', f'unknown: {dev_problems[0]}', '', 'devices'))
else:
    health.append(('Devices', f'{dev_count} connected · {in_use} in use',
                   'bad' if any(r[3] == 'bad' for r in dev_rows) else 'ok', 'devices'))
issues = [h for h in health if h[2] in ('bad', 'warn')]
bad_n = sum(h[2] == 'bad' for h in issues)
pill = (chip(f'{bad_n} problem{"s" if bad_n != 1 else ""}', 'bad') if bad_n else
        chip(f'{len(issues)} to watch', 'warn') if issues else chip('Healthy', 'ok'))
health_card = (f'<section class="health" id="health"><h2>Fleet health</h2>'
               + ''.join(hrow(*h) for h in health) + '</section>')

# 4. Homes: one row per home, lead state, model and lane numbers
lrel = 'data/metrics/lanes.tsv'
lp = os.path.join(HOME, lrel)
lanes_rec = None
if os.path.isfile(lp) and os.path.getsize(lp) == 0: notes.append((lrel, 'empty'))
else: lanes_rec = tsv(lrel, ('home', 'task', 'kind', 'harness', 'model'))
if lanes_rec == []: notes.append((lrel, 'no rows yet')); lanes_rec = None
lead_model = {r['task']: r['model'] for r in lanes_rec or [] if r['kind'] == 'secondmate'}
homes = set(latest) | {r['home'] for r in daily or [] if iso_day(r['day']) in (TODAY, YDAY) and r['home'] != 'main'}
homes |= {home_of_task(i.get('id', '')) for i in in_flight} | {h for h in leads if h} | registered | {'main'}
hc, parked_rows = [], []
COLS = ('Open lanes', 'Working', 'Ready', 'To land', 'Oldest wait', 'Merged today', 'First pass', 'Stalls today')
for h in sorted(homes, key=lambda x: (x != 'main', x)):
    pj = projects.get(h)
    pj = f'<small>{esc(", ".join(pj))}</small>' if pj else ''
    if h in parked:
        parked_rows.append(f'<tr class="parked"><th><span class="hn">{dot()}<b>{esc(h)}</b>{chip("Parked")}</span>{pj}</th><td colspan="{len(COLS) + 1}"></td></tr>')
        continue
    r = latest.get(h, {})
    o, rd = (count(r.get(k)) for k in ('open', 'ready'))
    dw = done_waiting(h)[0]
    ow = num(r.get('oldestwait_h'))  # -1 means nothing is waiting
    lead = leads.get(h)
    lw = LEAD_WORDS.get((lead or {}).get('state'), (str((lead or {}).get('state', '')).replace('_', ' ').capitalize(), ''))
    if h in down: lw = ('Not running', 'bad')
    lanes = ''
    if o is not None:
        lanes = '<span class="lanes" aria-hidden="true">' + ''.join(
            f'<i class="{"on" if k < o else ""}{" over" if k >= lane_target else ""}"></i>' for k in range(max(lane_target, int(o)))) + '</span>'
    flag = ''
    if o is not None and o > lane_target: flag = chip('over target', 'warn')
    elif o is not None and o < lane_target and (rd or 0) > 0: flag = chip('free lanes, ready work', 'warn')
    stalls = dsum('stall_alarms', TODAY, h) if h in measured else None
    fp = window_metrics(h)[0]['first_pass'] if h in measured and prs is not None else None
    fp_t = next(((tr['op'], num(tr['target'])) for tr in targets or [] if tr['metric'] == 'first_pass'), None)
    mine = len([i for i in in_flight if home_of_task(i.get('id', '')) == h])
    model = lead_model.get(h, '').split('/')[-1]
    mt = live_merged[h] if live_merged is not None and h in live_merged else merged(TODAY, h) if prs is not None and h in measured else None
    def td(label, v, tone_=''):
        return f'<td class="{tone_}{" na" if v is None else ""}" data-l="{esc(label.lower())}">{"–" if v is None else v}</td>'
    old = f' · lanes as of {esc(r["time"][11:16])}' if r and r['time'] != max(x['time'] for x in latest.values()) else ''
    hc.append(f'<tr><th><span class="hn">{dot(lw[1]) if lead or h in down else dot()}<b>{esc("Main" if h == "main" else h)}</b>'
              f'<span class="hs {lw[1]}">{esc(lw[0]) if lead or h in down else ""}</span></span>{pj}</th>'
              f'<td class="model{"" if model else " na"}" data-l="lead">{esc(model) or "–"}</td>'
              + td(COLS[0], f'{lanes}<span>{fmt(o)}<small>/{lane_target}</small></span>{flag}' if o is not None else None, 'ol ')
              + td(COLS[1], mine if snap is not None else None)
              + td(COLS[2], fmt(rd) if rd is not None else None)
              + td(COLS[3], fmt(dw) if dw is not None else None, 'warn' if dw else '')
              + td(COLS[4], (f'{fmt(ow)} h' if ow >= 0 else 'none') if ow is not None else None, 'warn' if (ow or 0) >= 2 else '')
              + td(COLS[5], mt)
              + td(COLS[6], f'{fp}%' if fp is not None else None, 'bad' if fp is not None and fp_t and misses(fp, *fp_t) else '')
              + td(COLS[7], stalls, 'bad' if stalls else '') + f'</tr>{f"<tr class=sub><td colspan={len(COLS) + 2}>{old[3:]}</td></tr>" if old else ""}')
homes_sec = (f'<section id="homes"><h2>Homes</h2><div class="panel flush"><table class="homes"><thead><tr><th>Home</th><th>Lead</th>'
             + ''.join(f'<th>{c}</th>' for c in COLS) + f'</tr></thead><tbody>{"".join(hc + parked_rows)}</tbody></table></div>'
             f'<p class="small muted">Lane boxes show open lanes against the target of {lane_target}. First pass covers merges of the last 2 days.</p></section>')

# 5. Devices and machine
def drow(name, sub, text, tone):
    return f'<div class="dev">{dot(tone)}<div class="dn"><b>{esc(name)}</b><small>{esc(sub)}</small></div><span class="dw {tone}">{esc(text)}</span></div>'
dev_body = ''.join(drow(*r) for r in dev_rows) or ('<p class="empty">No device connected and no emulator running.</p>' if dev_count is not None else '')
dev_body += ''.join(f'<p class="note">unknown - {esc(p)}</p>' for p in dev_problems)
def meter(label, value, frac, tone, hint=''):
    bar = f'<span class="bar"><i class="{tone}" style="--w:{max(2, min(100, round(100 * frac)))}%"></i></span>' if frac is not None else ''
    return f'<div class="meter"><span>{esc(label)}</span><b class="{tone}">{value}</b>{bar}{f"<small>{esc(hint)}</small>" if hint else ""}</div>'
def unknown(why): return f'<span class="unk">unknown: {esc(why)}</span>'
ms = [
    meter('Free memory', f'{free[0]:.1f} GB <small>of {free[1]:.0f} GB</small>', free[0] / free[1] if free[1] else None,
          'bad' if free[0] < MEM_MIN_GB else 'ok', f'heavy jobs wait below {MEM_MIN_GB} GB')
    if free else meter('Free memory', unknown(mach['free_why']), None, ''),
    meter('Memory pressure', f'{psi:.0f}%', psi / 100, 'bad' if psi >= 40 else 'warn' if psi >= 20 else 'ok', 'share of the last 10 s some job waited on memory; heavy jobs wait at 40%')
    if psi is not None else meter('Memory pressure', unknown(mach['pressure_why']), None, ''),
    meter('Heavy jobs', f'{hc_:.1f} GB <small>of {hh_:.0f} GB</small>' if hh_ else f'{hc_:.1f} GB', hc_ / hh_ if hh_ else None,
          'warn' if hh_ and hc_ >= 0.9 * hh_ else 'ok', f'shared group for builds and emulators' + (f'; hard limit {hm_:.0f} GB' if hm_ else ''))
    if hc_ is not None else meter('Heavy jobs', unknown(mach['heavy_why']), None, ''),
    meter('Gradle builds', f'{mach["gradle"]} <small>of {GRADLE_MAX}</small>', mach['gradle'] / GRADLE_MAX if GRADLE_MAX else None,
          'warn' if mach['gradle'] >= GRADLE_MAX else 'ok', 'a new build waits at the cap')
    if mach['gradle'] is not None else meter('Gradle builds', unknown(mach['gradle_why']), None, ''),
    meter('Emulators', f'{emu_count} <small>of {EMU_MAX}</small>', emu_count / EMU_MAX if EMU_MAX else None,
          'warn' if emu_count >= EMU_MAX else 'ok', 'a new emulator waits at the cap')
    if emu_count is not None else meter('Emulators', unknown(next((p for p in dev_problems if p.startswith('emulators')), 'no answer')), None, ''),
]
ops_sec = (f'<section id="machine"><h2>Devices and machine</h2><div class="grid2">'
           + panel('Devices', dev_body, 'devices') + panel('Machine', ''.join(ms)) + '</div></section>')

# 6. Work lists
W = []
if snap is not None:
    rs = []
    for i in sorted(in_flight, key=lambda i: i.get('id', '')):
        sw, stone = STATE_WORDS.get(i.get('state'), (str(i.get('state') or 'unknown').capitalize(), ''))
        doing = i.get('doing') or ''
        extra = chip('Checks running', 'ok') if doing.startswith('validating') else ''
        why = f'<div class="why">{esc(doing)}</div>' if doing and i.get('state') in ('paused', 'blocked', 'needs-decision', 'failed') else ''
        h = home_of_task(i.get('id', ''))
        rs.append(row(f'{esc(i.get("name") or i.get("id"))}{why}', esc('Main' if h == 'main' else h), chip(sw, stone) + extra))
    W.append(panel('Open work', (rows_more(rs) or '<p class="empty">Nothing is open.</p>')
                   + '<p class="foot-note">Second mate work shows while it is working; paused or blocked work counts in each home\'s open lanes.</p>',
                   'running', f'<span class="cnt">{len(in_flight)}</span>'))
    rs = []
    real = lambda v: v not in (None, '', '-')
    for g in gates:
        if str(g.get('id', '')).startswith('('):  # a synthetic row about the records themselves, not queued work
            notes.append(('Main records', g.get('title') or g.get('id'))); continue
        why = f'<div class="why">{esc(g["reason"])}</div>' if real(g.get('reason')) else ''
        state = chip(f'after {g["blocked_by"]}') if real(g.get('blocked_by')) else (chip('Waiting', 'warn') if why else chip('Ready', 'ok'))
        rs.append(row(esc(g.get('title') or g.get('id')) + why,
                      esc({'main': 'Main'}.get(owner_home(g.get('owner')), owner_home(g.get('owner')))) + (f' · filed {esc(g["filed"])}' if real(g.get('filed')) else ''), state))
    W.append(panel('Queued', (rows_more(rs) or '<p class="empty">Nothing queued.</p>')
                   + '<p class="foot-note">Second mate homes may send only their first queued items; the Queued and ready number counts all ready work.</p>',
                   'queued', f'<span class="cnt">{len(rs)}</span>'))
    rs = [row(link(l.get('what') or l.get('id'), l.get('artifact')), esc('Main' if owner_home(l.get('owner')) == 'main' else l.get('owner')), '') for l in landed]
    W.append(panel('Recently landed', rows_more(rs) or '<p class="empty">Nothing landed recently.</p>', 'landed', f'<span class="cnt">{len(landed)}</span>'))
else:
    W.append(note('fleet snapshot', next((r for s, r in notes if s == 'fleet snapshot'), 'not available')))
if defects is not None:
    open_n = sum(d['status'] == 'OPEN' for d in defects)
    rs = [row(esc(d['text']), esc(d['day']), chip(d['status'].capitalize(), 'bad' if d['status'] == 'OPEN' else 'ok') if d['status'] else '')
          for d in reversed(defects[-15:])]
    W.append(panel('Defects log', rows_more(rs, 4, 'newest'), 'defects', f'<span class="cnt">{open_n} open of {len(defects)}</span>'))
work_sec = f'<section id="work"><h2>Work</h2><div class="grid2">{"".join(W)}</div></section>'

# 7. Quality and trends
if skills is not None or daily is not None:
    sk_t, sk_y = dsum('skill_reads', TODAY), dsum('skill_reads', YDAY)
    top = {}
    for r in skills or []:
        if iso_day(r['day']) == TODAY: top[r['skill']] = top.get(r['skill'], 0) + int(num(r['reads']) or 0)
    top = sorted(top.items(), key=lambda kv: (-kv[1], kv[0]))[:6]
    peak = top[0][1] if top else 1
    rows_ = ''.join(f'<div class="hbar"><span>{esc(k)}</span><i style="--w:{max(4, round(100*v/peak))}%"></i><b>{v}</b></div>' for k, v in top)
    delta = '' if sk_t is None or sk_y is None else (f'{"up" if sk_t >= sk_y else "down"} from {sk_y} yesterday')
    panels_q.append(panel('Are skills being used?', f'''<div class="big"><b>{fmt(sk_t)}</b><span>skill reads today · {esc(delta)}</span></div>
{rows_ or '<p class="small muted">No skill reads recorded today.</p>'}{'' if skills is not None else note('data/metrics/skills.tsv', 'not available')}'''))

if targets is not None and (prs is not None or daily is not None):
    vals, n = window_metrics()
    per_home = {h: window_metrics(h)[0] for h in sorted(measured)}
    rows_ = []
    for tr in targets:
        m, op, tv = tr['metric'], tr['op'], num(tr['target'])
        if m not in QLABEL or tv is None or op not in ('>=', '<='): continue
        label, unit = QLABEL[m]; v = vals.get(m)
        homes_missed = [f'{h} {fmt(hv[m], 2)}{unit}' for h, hv in per_home.items()
                        if tr.get('owner') == 'each home' and misses(hv.get(m), op, tv)]
        tone_ = 'bad' if misses(v, op, tv) or homes_missed else ('ok' if v is not None else '')
        rows_.append(f'<div class="q {tone_}"><span>{esc(label)}</span><b>{fmt(v, 2)}{unit if v is not None else ""}</b>'
                     f'<i>target {"at least" if op == ">=" else "at most"} {fmt(tv)}{unit}'
                     f'{" · missed in " + esc(", ".join(homes_missed)) if homes_missed else ""}</i></div>')
    words = [count(r.get('rulewords')) for r in (pulse or []) if count(r.get('rulewords')) is not None]
    rw = ''
    if len(words) >= 2:
        d = words[-1] - words[0]
        rw = f'<p class="small muted">Written rules: {fmt(words[-1])} words ({"+" if d > 0 else ""}{fmt(d)} since the first pulse).</p>'
    panels_q.append(panel('Is quality on target?', f'''<p class="small muted">Today and yesterday, {n} merge{"s" if n != 1 else ""}, whole fleet. Red means the fleet or a home missed the target.</p>
<div class="qs">{"".join(rows_) or '<p class="small muted">No known metrics in the targets file.</p>'}</div>{rw}'''))
elif targets is None:
    panels_q.append(panel('Is quality on target?', note('config/metrics-targets.tsv', 'not available')))

# Who does the work: model per lane, from the lane record
if lanes_rec is None:
    panels_q.append(panel('Who does the work', '<p class="small muted">No record yet.</p>'))
else:
    last = {}  # (home, task) -> its latest row; a row per model change or PR
    for r in lanes_rec:
        if r['kind'] != 'secondmate' and r['home'] not in parked: last[(r['home'], r['task'])] = r
    pr_lane = {r['pr']: r for r in lanes_rec if r.get('pr') and r['kind'] != 'secondmate' and r['home'] not in parked}
    by_url = {f"https://github.com/{p['repo']}/pull/{p['pr']}": p for p in prs or [] if p.get('repo') and p.get('pr')}
    groups = {}
    def grp(r): return groups.setdefault(f"{r['harness']} · {r['model']}", {'run': 0, 'merged': 0, 'fp': 0})
    for (h, tk), r in last.items():
        g = grp(r)
        if h in home_dir and os.path.isfile(os.path.join(home_dir[h], 'state', f'{tk}.meta')): g['run'] += 1
    for url, r in pr_lane.items():
        p = by_url.get(url)
        if p and local_day(p['merged']) in WEEK:
            g = grp(r); g['merged'] += 1; g['fp'] += p['first_pass'] == '1'
    def wrow(label, a, b, c, cls='wr'): return f'<div class="{cls}"><span>{label}</span><b>{a}</b><b>{b}</b><b>{c}</b></div>'
    rs = [wrow(esc(k), g['run'], g['merged'], f"{100 * g['fp'] // g['merged']}%" if g['merged'] else '–')
          for k, g in sorted(groups.items(), key=lambda kv: (-kv[1]['run'], -kv[1]['merged'], kv[0]))]
    first = min(r.get('first_seen', '') or '9' for r in lanes_rec)[:10]
    panels_q.append(panel('Who does the work', f'''{wrow("Worker model", "Running", "Merged, 7 days", "First pass", "wr wh")}
{rows_more(rs, 5) or '<p class="small muted">No worker lanes recorded.</p>'}<p class="small muted">Recorded since {esc(first)}; older work has no record.</p>'''))

tr = []
if prs is not None:
    tr.append(trend('Merged', [merged(d) for d in WEEK]))
    tr.append(trend('First-pass merges', [first_pass_pct([d]) for d in WEEK], 'pct', first_pass_pct(WEEK)))
if pulse is not None:
    tr.append(trend('Finished, not landed', [pulse_day('donewait', d) for d in WEEK], 'level'))
if daily is not None:
    tr.append(trend('Stalls reached Main', [dsum('stall_alarms', d) for d in WEEK]))
if tr: panels_q.append(panel('Last 7 days', f'<div class="trends">{"".join(tr)}</div>'))
quality_sec = f'<section id="quality"><h2>Quality and trends</h2><div class="grid2">{"".join(panels_q)}</div></section>'

missing = ''.join(f'<li><code>{esc(s)}</code>: {esc(r)}</li>' for s, r in notes)
missing_sec = (f'<section class="foot"><details><summary>Missing data <span class="cnt">{len(notes)}</span></summary><ul class="mini">{missing}</ul>'
               f'<p class="small muted">Each missing source only hides its own part.</p></details></section>') if missing else ''

CSS = '''
:root{--bg:#f6f6f7;--panel:#fff;--sunk:#f1f1f3;--line:#e5e5e9;--ink:#141417;--soft:#55555e;--faint:#8b8b94;
--ok:#15803d;--ok-bg:#e8f6ed;--warn:#b45309;--warn-bg:#fdf3e2;--bad:#c62828;--bad-bg:#fdeceb;--bar:#d4d4da;--bar-now:#141417;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--bg:#0b0b0d;--panel:#141417;--sunk:#1b1b1f;--line:#26262c;--ink:#ececef;--soft:#a3a3ad;--faint:#6e6e78;
--ok:#4ade80;--ok-bg:#12301f;--warn:#fbbf24;--warn-bg:#33270c;--bad:#f87171;--bad-bg:#3a1616;--bar:#34343c;--bar-now:#ececef}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",sans-serif;font-variant-numeric:tabular-nums}
main{max-width:1180px;margin:0 auto;padding:18px 16px 48px}
a{color:inherit;text-decoration:none}
header{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:14px}
h1{font-size:18px;font-weight:650;letter-spacing:-.01em;margin:0}.stamp{display:block;font-size:12px;color:var(--faint)}
h2{font-size:13px;font-weight:600;margin:0 0 10px;color:var(--soft)}
h3{font-size:14px;font-weight:600;margin:0}
section{margin-top:28px}.top section{margin-top:0}
.top{display:grid;gap:12px}
.panel,.asks,.health{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px;min-width:0}
.ph{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:8px}
.dot{display:inline-block;flex:none;width:8px;height:8px;border-radius:50%;background:var(--faint)}
.dot.ok{background:var(--ok)}.dot.warn{background:var(--warn)}.dot.bad{background:var(--bad)}
.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}
.asks .ah{display:flex;align-items:baseline;justify-content:space-between;gap:8px;margin-bottom:6px}.asks h2{margin:0;color:var(--ink);font-size:15px}
.an{font-size:22px;font-weight:650;line-height:1}.asks.warn{border-color:color-mix(in srgb,var(--warn) 45%,var(--line))}.asks.warn .an{color:var(--warn)}.asks.ok .an{color:var(--ok)}
.ask{display:flex;align-items:center;gap:10px;padding:9px 0;border-top:1px solid var(--line)}
.ask span{flex:1;min-width:0;overflow-wrap:anywhere}a.ask span{text-decoration:underline;text-decoration-color:var(--bar);text-underline-offset:3px}
.ask time{flex:none;font-size:12px;color:var(--faint)}
.calm{margin:0;color:var(--soft)}.calm::before{content:"";display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--ok);margin-right:8px}
.strip{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1px;background:var(--line);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.m{display:flex;flex-direction:column;background:var(--panel);padding:11px 14px;min-width:0}
.m:hover,.hr:hover{background:var(--sunk)}
.ml{font-size:12px;color:var(--soft)}.mv{font-size:24px;font-weight:650;letter-spacing:-.02em;line-height:1.2}
.m small{font-size:11.5px;color:var(--faint);line-height:1.3}.m.warn .mv{color:var(--warn)}.m.ok .mv{color:var(--ok)}
.health{padding:6px 0}.health h2{padding:8px 16px 2px;margin:0}
.hr{display:grid;grid-template-columns:auto 4.6em minmax(0,1fr) auto;align-items:center;gap:10px;padding:9px 16px;border-top:1px solid var(--line)}
.health h2+.hr{border-top:0}.hr span{color:var(--soft)}.hr b{font-weight:500;overflow-wrap:anywhere}.hr::after{content:"›";color:var(--faint)}
.chip{display:inline-block;font-size:11.5px;font-weight:550;padding:1px 7px;border-radius:6px;background:var(--sunk);color:var(--soft);white-space:nowrap;margin:2px 0 2px 4px}
.chip.ok{background:var(--ok-bg);color:var(--ok)}.chip.warn{background:var(--warn-bg);color:var(--warn)}.chip.bad{background:var(--bad-bg);color:var(--bad)}
.cnt{font-size:12px;color:var(--faint);font-weight:500}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,440px),1fr));gap:12px;align-items:start}
.flush{padding:0;overflow-x:auto}
table.homes{width:100%;border-collapse:collapse}
.homes th,.homes td{padding:9px 10px;border-top:1px solid var(--line);text-align:right;font-weight:400;white-space:nowrap;vertical-align:middle}
.homes thead th{border-top:0;font-size:11.5px;color:var(--faint);font-weight:500;vertical-align:bottom}
.homes th:first-child,.homes th:nth-child(2),.homes td.model{text-align:left}.homes thead th:first-child{padding-left:16px}.homes tbody th{padding-left:16px}
.hn{display:flex;align-items:center;gap:8px}.hn b{font-weight:600}.hs{font-size:12px}
.homes tbody th small{display:block;max-width:240px;overflow:hidden;text-overflow:ellipsis;font-size:11.5px;color:var(--faint);padding-left:16px}
.homes td.ol .chip{display:block;width:max-content;margin:3px 0 0 auto}.homes td.model{font-size:12px;color:var(--soft)}.homes td small{color:var(--faint)}.homes td.na{color:var(--faint)}
.homes tr.sub td{border-top:0;padding-top:0;text-align:left;font-size:11.5px;color:var(--faint);padding-left:32px}
.lanes{display:inline-flex;gap:3px;margin-right:8px;vertical-align:middle}.lanes i{width:9px;height:9px;border-radius:2px;border:1px solid var(--bar)}
.lanes i.on{background:var(--ink);border-color:var(--ink)}.lanes i.on.over{background:var(--warn);border-color:var(--warn)}
.dev{display:grid;grid-template-columns:auto minmax(0,1fr) auto;align-items:center;gap:4px 10px;padding:9px 0;border-top:1px solid var(--line)}
.ph+.dev{border-top:0}.dn b{display:block;font-weight:550;overflow-wrap:anywhere}.dn small{font-size:11.5px;color:var(--faint)}.dw{font-size:13px;text-align:right}.dw.ok{color:var(--soft)}
@media (max-width:599px){.dev{grid-template-columns:auto minmax(0,1fr)}.dw{grid-column:2;text-align:left}}
.meter{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px 10px;padding:9px 0;border-top:1px solid var(--line)}.ph+.meter{border-top:0}
.meter>span:first-child{color:var(--soft)}.meter b{font-weight:600}.meter b small{color:var(--faint);font-weight:400}
.bar{grid-column:1/-1;height:6px;border-radius:3px;background:var(--sunk);overflow:hidden}.bar i{display:block;height:100%;width:var(--w);background:var(--ok);border-radius:3px}
.bar i.warn{background:var(--warn)}.bar i.bad{background:var(--bad)}.meter>small{grid-column:1/-1;font-size:11.5px;color:var(--faint)}.unk{color:var(--faint);font-weight:400}
.row{padding:8px 0;border-top:1px solid var(--line)}#defects .rm{display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
.ph+.row{border-top:0}.rm{overflow-wrap:anywhere}.rm a{text-decoration:underline;text-decoration-color:var(--bar);text-underline-offset:3px}
.rx{display:flex;flex-wrap:wrap;align-items:center;gap:2px 8px;margin-top:2px;color:var(--faint);font-size:12px}.rx .chip{margin:0}
.why{font-size:12px;color:var(--faint);margin-top:2px}
.more{border-top:1px solid var(--line)}.more summary{cursor:pointer;list-style:none;padding:9px 0 2px;font-size:12.5px;color:var(--soft)}
.more summary::-webkit-details-marker{display:none}.more summary::after{content:" ›"}.more[open] summary{display:none}
.foot-note{font-size:11.5px;color:var(--faint);margin:8px 0 0}
.verdict{margin:0 0 10px;padding:7px 10px;border-radius:8px;font-size:13px;font-weight:550;background:var(--sunk)}
.verdict.ok{background:var(--ok-bg);color:var(--ok)}.verdict.warn{background:var(--warn-bg);color:var(--warn)}.verdict.bad{background:var(--bad-bg);color:var(--bad)}
.stats{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
.stat{display:flex;flex-direction:column;min-width:0}.stat b{font-size:20px;font-weight:650;line-height:1.2}
.stat span{font-size:12.5px;color:var(--soft)}.stat i{font-style:normal;font-size:11.5px;color:var(--faint)}.stat.bad b{color:var(--bad)}.stat.warn b{color:var(--warn)}
.big{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;margin-bottom:8px}.big b{font-size:24px;font-weight:650}.big span{font-size:12.5px;color:var(--soft)}
.hbar{display:grid;grid-template-columns:minmax(0,1.3fr) minmax(0,1fr) 2.4em;align-items:center;gap:8px;font-size:12.5px;margin:4px 0}
.hbar span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.hbar i{display:block;height:6px;border-radius:3px;background:var(--bar);width:var(--w)}.hbar b{text-align:right;font-weight:600}
.qs{display:grid;gap:5px;margin-top:8px}
.q{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:0 10px;padding:6px 10px;border-radius:8px;background:var(--sunk)}
.q span{font-size:13px}.q b{text-align:right}.q i{grid-column:1/-1;font-style:normal;font-size:11.5px;color:var(--faint)}
.q.bad{background:var(--bad-bg)}.q.bad b,.q.bad span{color:var(--bad)}.q.ok b{color:var(--ok)}
.wr{display:grid;grid-template-columns:minmax(0,1fr) repeat(3,4.4em);gap:8px;align-items:baseline;padding:6px 0;border-top:1px solid var(--line);font-size:13px}
.wr span{overflow-wrap:anywhere}.wr b{text-align:right;font-weight:600}.wh{font-size:11.5px;color:var(--faint);border-top:0}.wh b{font-weight:500}
.trends{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px 18px}
.trh{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:baseline;gap:8px;font-size:12.5px;color:var(--soft)}.trh b{font-size:16px;color:var(--ink);font-weight:650;white-space:nowrap}.trh b small{font-size:11px;color:var(--faint);font-weight:400}
.spark{display:block;width:100%;height:34px;margin:6px 0 2px}.spark .b{fill:var(--bar)}.spark .bt{fill:var(--bar-now)}.spark .b0{fill:var(--line)}
.trf{display:flex;justify-content:space-between;font-size:10.5px;color:var(--faint)}
.mini{margin:8px 0 0;padding-left:18px;font-size:12.5px;color:var(--soft)}.mini li{margin:2px 0;overflow-wrap:anywhere}
.small{font-size:12.5px;margin:8px 0 0}.muted{color:var(--faint)}
.note{font-size:12.5px;color:var(--faint);margin:6px 0 0}.empty{margin:4px 0;color:var(--faint)}
.foot details summary{cursor:pointer;color:var(--faint);font-size:12.5px}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
@media (min-width:600px){.strip{grid-template-columns:repeat(4,minmax(0,1fr))}}
@media (min-width:960px){main{padding:28px 32px 56px}.top{grid-template-columns:minmax(0,1.35fr) minmax(0,1fr);align-items:start}
.top>.asks{grid-column:1}.top>.strip{grid-column:1}.top>.health{grid-column:2;grid-row:1/span 2}}
@media (max-width:759px){.homes thead{display:none}.homes,.homes tbody{display:block}
.homes tr{display:flex;flex-wrap:wrap;gap:3px 14px;padding:10px 14px;border-top:1px solid var(--line)}.homes tbody tr:first-child{border-top:0}
.homes th,.homes td{padding:0;border:0;text-align:left;font-size:13px}.homes tbody th{flex:1 0 100%;padding:0 0 2px}
.homes td.na,.homes tr.parked td{display:none}.homes td::after{content:" " attr(data-l);color:var(--faint);font-size:12px}
.homes td.ol:not(.na){display:inline-flex;align-items:center;gap:0 4px;flex-wrap:wrap}.homes td.ol::after{order:1}.homes td.ol .chip{order:2;margin:0 0 0 4px}.homes td.model::after{content:none}.homes td.model::before{content:"lead ";color:var(--faint)}.homes td.model{flex:1 0 100%}
.homes tbody th{min-width:0;overflow:hidden}.homes tbody th small{padding-left:16px;max-width:none;white-space:nowrap}.homes tr.sub{padding-top:0;border-top:0}.homes tr.sub td::after{content:none}}
'''
stamp = NOW.strftime('%a %d %b, %H:%M')
doc = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="60">
<title>Fleet dashboard</title><style>{CSS}</style></head><body><main>
<header><div><h1>Fleet</h1><span class="stamp">Built {esc(stamp)}<!--age--></span></div><a href="#health">{pill}</a></header>
<div class="top">{asks_card}<nav class="strip" aria-label="Work">{"".join(t)}</nav>{health_card}</div>
{homes_sec}{ops_sec}{work_sec}{quality_sec}{missing_sec}</main></body></html>
'''
with open(OUT, 'w', encoding='utf-8') as f: f.write(doc)
PY
mv "$page.$$.tmp" "$page" || { echo "fm-dashboard: cannot write $page" >&2; exit 1; }
printf '%s\n' "$page"
