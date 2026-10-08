import pathlib, subprocess, os, time, urllib.request, re, html
root=pathlib.Path.cwd(); lab=root/'.validation-tmp/live'; home=lab/'home'; url=(lab/'url').read_text()
env=dict(os.environ,HOME=str(home),FM_HOME=str(home),PATH=str(lab/'tools'),FM_DEVICE_LOCK_DIR=str(home/'locks'),TMPDIR=str(root/'.validation-tmp'))
for k in list(env):
    if k.startswith(('HERDR_','TASKS_AXI_')) or k.endswith('_OVERRIDE'): env.pop(k)
p=home/'data/metrics/prs.tsv'; rows=p.read_text().splitlines()
a=rows[2].split('\t'); a[-1]=''; rows[2]='\t'.join(a)
a=rows[4].split('\t'); a[-1]='?'; rows[4]='\t'.join(a)
p.write_text('\n'.join(rows)+'\n')
pback=home/'data/backlog.md'
pback.write_text(pback.read_text().split('- [ ] follow-up')[0])
subprocess.run(['bash',str(root/'bin/fm-tasks-axi.sh'),'add','follow-up','Brand new observed filing','--repo','alpha','--kind','ship'],env=env,check=True)
subprocess.run(['bash',str(root/'bin/fm-dashboard.sh'),'build'],env=env,check=True)
def get(path):
    return urllib.request.urlopen(url+path).read().decode()
flow=get('flow'); method=get('measure')
assert "Yesterday's cycle time unknown." in flow
assert 'Cycle time unknown: missing or invalid merge durations.' in flow
assert 'P50 1 h' not in flow and 'P85 1 h' not in flow
assert re.search(r'Slowest merges.*?unknown',method,re.S)
assert 'Brand new observed filing' in flow and '1 item first seen today.' in flow
print('Flow: Yesterday\'s cycle time unknown. Cycle time unknown: missing or invalid merge durations.')
print('Method: Slowest merges (p90), target at most 50 h, now unknown.')
print('Flow latest filings: 1 item first seen today; Brand new observed filing.')
for name in ('flow','measure'):
    (pathlib.Path('/home/umer/.no-mistakes/evidence/01M4CG7XE13QK778BCYM433TX0')/(name+'-incomplete.html')).write_text(get(name))
