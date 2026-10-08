import os, pathlib, shutil, subprocess, tempfile, time, re, html, json, sys
ROOT = pathlib.Path('/home/umer/.no-mistakes/worktrees/bde6b4035eae/01M4DDDY5SCXR7JQ20C0EH78VZ')
EVIDENCE = pathlib.Path('/home/umer/.no-mistakes/evidence/01M4DDDY5SCXR7JQ20C0EH78VZ')
fixture = pathlib.Path(tempfile.mkdtemp(prefix='.memory-validation-', dir=ROOT))
log = []
if '--dashboard-only' in sys.argv:
    log.append((EVIDENCE / 'authorized-scenarios.log').read_text())
    log.append('Setup repair: added missing basename executable to isolated PATH; retry dashboard only.')
def put(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
def run(args, env):
    r = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=60)
    log.append('$ ' + ' '.join(map(str,args)) + '\nexit=' + str(r.returncode) + '\n' + r.stdout + r.stderr)
    return r
def visible(path):
    text = re.sub(r'<(style|title)>.*?</\1>', ' ', path.read_text(), flags=re.S)
    return re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', text)))
try:
    env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('ANDROID_HOME','ANDROID_SDK_ROOT','TASKS_AXI_FILE')}
    proc = fixture / 'proc'
    put(proc / 'meminfo', 'MemTotal: 67108864 kB\nMemAvailable: 41943040 kB\nSwapTotal: 16777216 kB\nSwapFree: 15728640 kB\n')
    put(proc / 'pressure/memory', 'some avg10=2.00 avg60=0 avg300=0 total=1\n')
    group = f'user.slice/user-{os.getuid()}.slice/user@{os.getuid()}.service/app.slice/herdr-server.service'
    put(proc / 'self/cgroup', '0::/' + group + '/child\n')
    cgroup = fixture / 'cgroup'
    pressure = cgroup / group / 'memory.pressure'
    put(pressure, 'some avg10=58.88 avg60=0 avg300=0 total=1\n')
    state = fixture / 'admission-state'
    state.mkdir()
    admission_env = dict(env, FM_HOST_MEMORY_PROC=str(proc), FM_HOST_MEMORY_CGROUP_ROOT=str(cgroup))
    log.append('INPUT: calm host avg10=2.00%, available=40 GiB; runtime cgroup avg10=58.88%')
    if '--dashboard-only' not in sys.argv:
        high = run(['bin/fm-jev-mem-guard.sh', '--admit', 'bounded-build', '--state', str(state)], admission_env)
        assert high.returncode == 1, high
        record = (state / 'admission-refused').read_text()
        log.append('PERSISTED admission-refused:\n' + record)
        at, task, why = record.rstrip('\n').split('\t',2)
        assert task == 'bounded-build' and 'host 2%, cgroup 59%' in why and group in why
        shutil.copyfile(state / 'admission-refused', EVIDENCE / 'cgroup-admission-refused.tsv')
        put(pressure, 'some avg10=2.00 avg60=0 avg300=0 total=1\n')
        log.append('CONTROL INPUT: only runtime cgroup pressure changed to 2.00%')
        calm = run(['bin/fm-jev-mem-guard.sh', '--admit', 'bounded-build', '--state', str(state)], admission_env)
        assert calm.returncode == 0 and not (state / 'admission-refused').exists()
        log.append('OBSERVED: admission allowed and refusal record removed after cgroup pressure eases.')
    home = fixture / 'home'
    mate = home / 'mates/remote-lead'
    for h in (home, mate):
        for d in ('state','data','config'): (h / d).mkdir(parents=True,exist_ok=True)
        put(h / 'data/backlog.md', '## Queued\n')
        put(h / '.tasks.toml', 'backend = "markdown"\n[markdown]\narchive = "data/done-archive.md"\n')
        put(h / 'state/home-summary.json', json.dumps({'schema':'fm-secondmate-home-summary.v1', 'home':str(h), 'state':'no_active_work', 'generated_epoch':int(time.time()), 'endpoints':[]}))
    put(mate / 'state/admission-refused', f'{int(time.time())}\tlocal-pressure-task\tlocal pressure refusal\n')
    put(home / 'state/admission-refused', f'{int(time.time())}\tmain-pressure-task\tmain pressure refusal\n')
    # Real executable symlinks only. Omit backend/device probes so they report unavailable,
    # instead of touching the default Herdr session or starting a host adb server.
    tools = fixture / 'tools'
    tools.mkdir()
    for name in ('bash','python3','dirname','basename','tasks-axi','perl','sed','awk','grep','head','node','env','timeout','cat','date','mkdir','mktemp','rm','mv'):
        source = shutil.which(name)
        if source: (tools / name).symlink_to(source)
    dashboard_env = dict(env, PATH=str(tools), HOME=str(home), FM_HOME=str(home), FM_DEVICE_LOCK_DIR=str(fixture / 'locks'), FM_DASHBOARD_PROC=str(proc), TMPDIR=str(fixture))
    (fixture / 'locks').mkdir()
    registry = home / 'data/secondmates.md'
    put(registry, f'- remote-lead - local control (home: {mate}; scope: work; projects: alpha; added 2026-07-11)\n')
    log.append('CONTROL: registered local home containing local-pressure-task refusal.')
    local = run(['bin/fm-dashboard.sh','build'], dashboard_env)
    assert local.returncode == 0
    dashboard = home / 'state/dashboard'
    text = visible(dashboard / 'index.html')
    assert 'new agents wait (remote-lead)' in text and 'local-pressure-task' in text
    shutil.copyfile(dashboard / 'index.html', EVIDENCE / 'dashboard-local-control.html')
    log.append('OBSERVED local control: new agents wait (remote-lead); local-pressure-task.')
    put(registry, f'- remote-lead - remote (host: distant.invalid; root: /srv; home: {mate}; scope: work; projects: alpha; added 2026-07-11)\n')
    log.append('ADVERSARIAL: same home path now registered remote; coincident local refusal remains untouched.')
    remote = run(['bin/fm-dashboard.sh','build'], dashboard_env)
    assert remote.returncode == 0
    assert (mate / 'state/admission-refused').exists()
    for page in ('index','backlog','backlog.home','measure'):
        text = visible(dashboard / (page + '.html'))
        assert 'new agents wait (remote-lead)' not in text and 'local-pressure-task' not in text and 'local pressure refusal' not in text, page
        shutil.copyfile(dashboard / (page + '.html'), EVIDENCE / ('dashboard-remote-' + page + '.html'))
    text = visible(dashboard / 'index.html')
    assert 'new agents wait (Main)' in text and 'main-pressure-task' in text
    log.append('OBSERVED remote result: Main refusal still visible; remote lead not credited with local refusal on any of the four generated pages.')
    log.append('PASS: both authorized scenarios, each with one adversarial reading and one control; no lifecycle or credential actions.')
finally:
    shutil.rmtree(fixture)
    log.append('CLEANUP: removed all worktree fixture files.')
    (EVIDENCE / 'authorized-scenarios.log').write_text('\n'.join(log)+'\n')
    print('\n'.join(log))
