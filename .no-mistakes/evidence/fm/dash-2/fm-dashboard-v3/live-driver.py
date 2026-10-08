import os, pathlib, subprocess, time, urllib.request, json
from datetime import datetime, timedelta
root=pathlib.Path.cwd(); lab=root/'.validation-tmp/live'; home=lab/'home'
env=dict(os.environ, HOME=str(home), FM_HOME=str(home), PATH=str(lab/'tools'), FM_DEVICE_LOCK_DIR=str(home/'locks'), TMPDIR=str(root/'.validation-tmp'))
for k in list(env):
    if k.startswith(('HERDR_', 'TASKS_AXI_')) or k.endswith('_OVERRIDE'): env.pop(k)
(home/'locks').mkdir(exist_ok=True)
today=datetime.now().astimezone().date()
(home/'data/backlog.md').write_text(f'## Queued\n- [ ] new-item - Review the latest filing (repo: alpha) (kind: ship) (since {today})\n- [ ] held-item - Await approval (repo: alpha) (kind: ship) (hold: needs his call) (hold-kind: captain) (since {today})\n\n## Done\n')
(home/'data/captain-asks.tsv').write_text(f'release\t{int(time.time())-3600}\tApprove <script>alert(1)</script> release\thttps://example.invalid/release\n')
(home/'config/metrics-targets.tsv').write_text('metric\top\ttarget\np90_hours\t<=\t50\n')
start=datetime.now().astimezone().replace(hour=0,minute=0,second=0,microsecond=0)
metrics=home/'data/metrics/prs.tsv'
rows=['home\tmerged\tfirst_pass\tbuild_hours']
for day in (start-timedelta(days=1), start):
    for hours in (1,100): rows.append(f'main\t{day.isoformat()}\t1\t{hours}')
metrics.write_text('\n'.join(rows)+'\n')
subprocess.run(['bash',str(root/'bin/fm-dashboard.sh'),'build'],env=env,check=True)
log=open(lab/'server.log','w')
server=subprocess.Popen(['bash',str(root/'bin/fm-dashboard.sh'),'serve','--port','0'],env=env,stdout=log,stderr=log)
(lab/'pid').write_text(str(server.pid))
for _ in range(100):
    txt=(lab/'server.log').read_text()
    if 'serving http://' in txt: break
    time.sleep(.1)
url=txt.split('serving ')[1].splitlines()[0]
(lab/'url').write_text(url)
print(url)
def get(path):
    with urllib.request.urlopen(url+path,timeout=90) as r: return r.read().decode(),r.headers
for path in ('','flow','quota','backlog','measure'):
    body,_=get(path); print(path or '/', 'HTTP 200',len(body),'bytes')
flow,_=get('flow'); method,_=get('measure')
assert "Yesterday's cycle-time P50: 1 h." in flow
assert 'P85 100 h' in flow
assert '100 h' in method and 'missed' in method
assert 'took under' not in flow
body,_=get(''); assert '&lt;script&gt;alert(1)&lt;/script&gt;' in body and '<script>' not in body
body,headers=get('backlog?group=home'); assert 'fm_group=home' in headers['Set-Cookie']
for path in ('state/','../data/backlog.md','index.home.html'):
    try: get(path); raise AssertionError(path)
    except urllib.error.HTTPError as e: assert e.code==404; print(path,'HTTP 404')
print('Complete durations: P50 1 h, P85 100 h; p90 target 100 h missed. Escaped ask and grouping cookie verified.')
