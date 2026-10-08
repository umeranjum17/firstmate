import os, pathlib, subprocess, time, shutil, json
ROOT=pathlib.Path.cwd(); E=pathlib.Path('/home/umer/.no-mistakes/evidence/01M4D5G9JMQRZ6ECQ22RKCM0EG'); F=ROOT/'.test-tmp/manual'; F.mkdir()
H=F/'Fleet Home'; subprocess.run(['bin/fm-lab-home.sh','create',str(H)],check=True)
P=F/'proc'; (P/'pressure').mkdir(parents=True)
(P/'meminfo').write_text('MemTotal: 67108864 kB\nMemAvailable: 41943040 kB\nSwapTotal: 33554432 kB\nSwapFree: 29360128 kB\n')
def pressure(n): (P/'pressure/memory').write_text(f'some avg10={n} avg60=0 avg300=0 total=1\n')
env=dict(os.environ,FM_HOME=str(H),HOME=str(H),TMPDIR=str(ROOT/'.test-tmp'),FM_HOST_MEMORY_PROC=str(P),FM_HOST_MEMORY_CGROUP_ROOT=str(F/'absent-cgroup'),FM_BACKEND='tmux',TMUX='',FM_HOST_MEMORY_SECS='1',FM_POLL='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_SECONDMATE_LIVENESS_SECS='99999999',FM_SIGNAL_GRACE='0')
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','ANDROID_HOME','ANDROID_SDK_ROOT']: env.pop(k,None)
log=(E/'live-cli.log').open('w')
def run(args,rc=0):
 r=subprocess.run(args,env=env,text=True,capture_output=True); log.write('$ '+' '.join(args)+'\n'+r.stdout+r.stderr+f'EXIT={r.returncode}\n'); log.flush(); assert r.returncode==rc,(args,r.stdout,r.stderr); return r.stdout+r.stderr
pressure(2); run(['bin/fm-jev-mem-guard.sh','--record',str(H/'state/host-memory.tsv')]);
pressure(25)
for flags in [['--mode','no-mistakes','--yolo','off'],['--scout']]:
 out=run(['bin/fm-spawn.sh','labqueued','projects/absent','--harness','claude']+flags,1); assert 'stays queued' in out and 'pressure at or above 20%' in out
assert not (H/'state/labqueued.meta').exists(); log.write('No task endpoint record created; refusal='+ (H/'state/admission-refused').read_text())
out=run(['bin/fm-spawn.sh','lablead','/','--secondmate','--harness','claude'],1); assert 'stays queued' in out
pressure(2); run(['bin/fm-jev-mem-guard.sh','--admit','labqueued','--state',str(H/'state')]); assert not (H/'state/admission-refused').exists()
# Calm host, pressured runtime cgroup: admission must still refuse.
C=F/'cgroup'; CG=C/f'user.slice/user-{os.getuid()}.slice/user@{os.getuid()}.service/app.slice/herdr-server.service'; CG.mkdir(parents=True); (CG/'memory.pressure').write_text('some avg10=43 avg60=0 avg300=0 total=1\n'); env['FM_HOST_MEMORY_CGROUP_ROOT']=str(C)
out=run(['bin/fm-jev-mem-guard.sh','--admit','labqueued','--state',str(H/'state')],1); assert 'cgroup 43%' in out
env['FM_HOST_MEMORY_CGROUP_ROOT']=str(F/'absent-cgroup')
(H/'config/host-memory').write_text('wait_pressure=nan\n'); run(['bin/fm-jev-mem-guard.sh','--config',str(H/'config/host-memory'),'--admit','labqueued','--state',str(H/'state')],2); (H/'config/host-memory').unlink()
# Real watcher and sampler, no worker or endpoint substitutes.
w=None
try:
 with (E/'watcher.stdout.log').open('w') as o,(E/'watcher.stderr.log').open('w') as e:
  w=subprocess.Popen(['bin/fm-watch.sh'],env=env,stdout=o,stderr=e)
  def until(fn):
   end=time.monotonic()+15
   while time.monotonic()<end:
    if fn(): return
    time.sleep(.1)
   raise AssertionError('condition timed out')
  record=H/'state/.host-memory-sampler.pid'; until(lambda:record.exists()); old=int(record.read_text().split('\t')[0]); until(lambda:len((H/'state/host-memory.tsv').read_text().splitlines())>=3)
  os.kill(old,15); until(lambda:record.exists() and int(record.read_text().split('\t')[0])!=old); new=int(record.read_text().split('\t')[0]); log.write(f'Watcher restarted sampler: {old} -> {new}\n')
  pressure(42); until(lambda:(H/'state/.host-memory-alerted').exists()); until(lambda:w.poll() is not None); assert w.returncode==0
  log.write('Durable queue:\n'+(H/'state/.wake-queue').read_text()); log.write('Interrupt ownership decision:\n'+(H/'state/host-memory-interrupts.tsv').read_text()); assert 'top consumer is not a task this home owns' in (H/'state/.host-memory-alerted').read_text()
finally:
 if w and w.poll() is None: w.terminate(); w.wait(timeout=10)
log.write('Sampler records:\n'+(H/'state/host-memory.tsv').read_text()); shutil.copyfile(H/'state/host-memory.tsv',E/'host-memory.tsv')
# Generated unit contract, no host service install.
r=run(['bin/fm-sentinel.sh','unit']); (E/'fm-sentinel.service').write_text(r)
# A PATH of real tools excludes Herdr and adb to prohibit fleet access and daemon starts.
B=F/'tools'; B.mkdir()
for tool in ['bash','python3','mkdir','dirname','rm','uname','readlink','jq','cat','sed','awk','grep','date','git','head','tr','ls','cut','find','sort','wc','basename','mv']:
 p=shutil.which(tool)
 if p: (B/tool).symlink_to(p)
D=dict(env,PATH=str(B),FM_DASHBOARD_PROC=str(P),FM_DEVICE_LOCK_DIR=str(F/'locks'))
(H/'state/admission-refused').write_text(f'{int(time.time())}\tlabqueued\thost memory under pressure: pressure at or above 20%\n')
r=subprocess.run(['/usr/bin/bash','bin/fm-dashboard.sh','build'],env=D,text=True,capture_output=True); log.write('$ isolated PATH bin/fm-dashboard.sh build\n'+r.stdout+r.stderr); assert r.returncode==0
for file in ['index.html','backlog.html','measure.html','data.json']: shutil.copyfile(H/'state/dashboard'/file,E/('dashboard-'+file))
log.write('Dashboard generated from the actual sampler history and admission record; unrelated probes unavailable intentionally.\n'); log.close()
print(json.dumps({'fixture':str(F),'dashboard':str(E/'dashboard-index.html')}))
