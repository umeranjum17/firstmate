#!/usr/bin/env python3
"""
fm-jev-mem-guard.py - host memory guard: measure, admit, and alert before an oomd kill.

Every fleet agent runs inside one agent-runtime service, and systemd-oomd kills
that service as a unit when its slice's memory pressure stays above the oomd
limit (on the reference host: "some" avg10 above 50% for 20 s). Read host
and runtime cgroup pressure independently and classify the worse reading.
Admission refusal and watcher interrupts cannot guarantee avoidance of an oomd kill.

Usage (bin/fm-jev-mem-guard.sh runs this with python3):
  fm-jev-mem-guard.sh [--config FILE] [--state-dir DIR ...]
      Print "<verdict>\t<summary>" for the host, naming the largest consumers.
  fm-jev-mem-guard.sh [--config FILE] --admit TASK --state DIR
      Admission for one agent launch (bin/fm-spawn.sh, bin/fm-control.sh relaunch).
      Exit 0 admits and removes DIR/admission-refused. Exit 1 refuses: prints the
      reason and writes DIR/admission-refused as "<epoch>\t<task>\t<reason>".
  fm-jev-mem-guard.sh [--config FILE] --record FILE [--state-dir DIR ...]
      One independent sampler sample (bin/fm-host-memory-sampler.sh): appends
      "<epoch>\t<MemAvailable kB>\t<swap used kB>\t<pressure some avg10>\t<verdict>"
      to FILE, keeping the newest 8640 rows (a day at the 10 s cadence), and prints
      "<verdict>\t<summary>"; an ALERT summary names the largest consumers.

  --owned-top-task DIR appends a tab and the top consumer's task ID only when
      that consumer is a task recorded in DIR (for the watcher's interrupt).

Verdicts: OK; WAIT (new agents wait); ALERT (watcher attempts one owned-task interrupt);
UNKNOWN (not measurable, for example no pressure file: admits and records nothing).
Thresholds come from config/host-memory (docs/configuration.md "Host memory guard").
Consumers are summed RSS plus swap per owner: recorded worktree, task temp, or
home paths qualify the process's working directory; FM_TASK_ID disambiguates tasks
within that home (task records in each --state-dir), else the process is unowned.
The proc root is FM_HOST_MEMORY_PROC (default /proc). Exit 2: usage or an invalid
config file, with the reason on stderr.
"""

import argparse
import math
import os
import sys
import tempfile
import time

PROC = os.environ.get("FM_HOST_MEMORY_PROC") or "/proc"
DEFAULTS = {"wait_pressure": 20.0, "wait_available_gb": 12.0, "alert_pressure": 35.0, "alert_available_gb": 6.0}
KEEP_ROWS = 8640
CGROUP_ROOT = os.environ.get("FM_HOST_MEMORY_CGROUP_ROOT") or "/sys/fs/cgroup"
GIB_KB = 1048576


def die(msg):
    print(f"fm-jev-mem-guard: {msg}", file=sys.stderr)
    sys.exit(2)


def load_config(path):
    cfg = dict(DEFAULTS)
    if not path or not os.path.exists(path):
        return cfg
    try:
        lines = open(path).read().splitlines()
    except OSError as e:
        die(f"cannot read {path}: {e.strerror}")
    for n, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, val = (p.strip() for p in line.partition("="))
        try:
            if not sep or key not in DEFAULTS or not math.isfinite(float(val)) or float(val) < 0:
                raise ValueError
            cfg[key] = float(val)
        except ValueError:
            die(f"invalid {path} line {n}: {raw!r} (expected KEY=number, keys: {', '.join(DEFAULTS)})")
    return cfg


def pressure_at(path):
    some = next(l for l in open(path) if l.startswith("some "))
    value = float(dict(f.split("=", 1) for f in some.split()[1:])["avg10"])
    if not math.isfinite(value) or value < 0:
        raise ValueError
    return value


def cgroup_pressure():
    uid = os.getuid()
    user = f"user.slice/user-{uid}.slice"
    paths = {user, f"{user}/user@{uid}.service/app.slice/herdr-server.service"}
    try:
        for line in open(f"{PROC}/self/cgroup"):
            if not line.startswith("0::"):
                continue
            group = line.strip()[3:].lstrip("/")
            parts = group.split("/")
            if "herdr-server.service" in parts:
                paths.add("/".join(parts[:parts.index("herdr-server.service") + 1]))
            paths.update("/".join(parts[:i + 1]) for i, part in enumerate(parts)
                         if part.startswith("user-") and part.endswith(".slice"))
    except OSError:
        pass
    readings = []
    root = os.path.realpath(CGROUP_ROOT)
    for group in paths:
        path = os.path.realpath(os.path.join(root, group, "memory.pressure"))
        if not path.startswith(root + os.sep):
            continue
        try:
            readings.append((pressure_at(path), group))
        except (OSError, StopIteration, KeyError, ValueError):
            pass
    return max(readings) if readings else (None, None)


def sample():
    """{available_kb, swap_used_kb, pressure}, or None when not measurable."""
    try:
        mem = {}
        for line in open(f"{PROC}/meminfo"):
            key, _, val = line.partition(":")
            if val.split() and val.split()[0].isdigit():
                mem[key.strip()] = int(val.split()[0])
        host = pressure_at(f"{PROC}/pressure/memory")
        cgroup, group = cgroup_pressure()
        return {"available_kb": mem["MemAvailable"],
                "swap_used_kb": max(0, mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)),
                "pressure": max(host, cgroup) if cgroup is not None else host,
                "host_pressure": host, "cgroup_pressure": cgroup, "cgroup": group}
    except (OSError, StopIteration, KeyError, ValueError):
        return None


def verdict(s, cfg):
    if s is None:
        return "UNKNOWN", []
    gb = s["available_kb"] / GIB_KB
    for level in ("alert", "wait"):
        why = []
        if s["pressure"] >= cfg[f"{level}_pressure"]:
            why.append(f"pressure at or above {cfg[f'{level}_pressure']:g}%")
        if gb < cfg[f"{level}_available_gb"]:
            why.append(f"available memory below {cfg[f'{level}_available_gb']:g} GB")
        if why:
            return level.upper(), why
    return "OK", []


def summary(s):
    return (f"pressure {s['pressure']:.0f}% (10 s average), {s['available_kb'] / GIB_KB:.1f} GB available, "
            f"{s['swap_used_kb'] / GIB_KB:.1f} GB swap used; " +
            (f"host {s['host_pressure']:.0f}%, cgroup {s['cgroup_pressure']:.0f}% ({s['cgroup']})"
             if s['cgroup_pressure'] is not None else "cgroup pressure unreadable; host-only classification"))


def read_meta(path):
    meta = {}
    try:
        for line in open(path, errors="replace"):
            key, sep, val = line.rstrip("\n").partition("=")
            if sep:
                meta[key] = val
    except OSError:
        pass
    return meta


def owners(state_dirs):
    """Home-qualified owners, indexed by recorded paths and task IDs."""
    metas = [(d, f[:-5], read_meta(os.path.join(d, f)))
             for d in state_dirs if os.path.isdir(d) for f in sorted(os.listdir(d)) if f.endswith(".meta")]
    lead_of = {os.path.realpath(m["home"]): tid for _, tid, m in metas if m.get("kind") == "secondmate" and m.get("home")}
    paths, tasks = [], {}
    for d, tid, m in metas:
        if m.get("kind") == "secondmate":
            if m.get("home"):
                owner = (os.path.realpath(d), tid, f"lead {tid}")
                tasks.setdefault(tid, []).append(owner)
                paths.append((os.path.realpath(m["home"]), owner))
            continue
        home = lead_of.get(os.path.realpath(os.path.dirname(os.path.abspath(d))), "main")
        owner = (os.path.realpath(d), tid, f"task {tid} ({home})")
        tasks.setdefault(tid, []).append(owner)
        paths += [(os.path.realpath(m[k]), owner) for k in ("worktree", "tasktmp") if m.get(k)]
        paths.append((os.path.realpath(os.path.dirname(d)), (os.path.realpath(d), "", f"lead {home}")))
    paths.sort(key=lambda p: -len(p[0]))
    return paths, tasks


def consumers(state_dirs, top=3):
    # ponytail: summed RSS counts shared pages once per process; fine for ranking owners, not for accounting.
    paths, tasks = owners(state_dirs)
    groups = {}
    try:
        pids = [p for p in os.listdir(PROC) if p.isdigit()]
    except OSError:
        return []
    for pid in pids:
        base = f"{PROC}/{pid}"
        try:
            status = dict(l.split(":", 1) for l in open(f"{base}/status", errors="replace") if ":" in l)
            kb = sum(int(status[k].split()[0]) for k in ("VmRSS", "VmSwap") if k in status)
        except (OSError, ValueError, IndexError):
            continue
        if kb < 10240:
            continue
        owner = None
        tid = ""
        matches = []
        try:
            tid = next((e[11:].decode(errors="replace") for e in open(f"{base}/environ", "rb").read().split(b"\0")
                        if e.startswith(b"FM_TASK_ID=")), "")
            matches = tasks.get(tid, [])
        except OSError:
            pass
        try:
            cwd = os.path.realpath(os.readlink(f"{base}/cwd"))
            owner = next((o for p, o in paths if cwd == p or cwd.startswith(p + "/")), None)
            if matches and owner not in matches:
                homes = [o for o in matches if cwd == os.path.dirname(o[0]) or
                         cwd.startswith(os.path.dirname(o[0]) + "/")]
                owner = max(homes, key=lambda o: len(o[0])) if homes else None
        except OSError:
            pass
        owner = owner or ("", "", f"{status.get('Name', '?').strip()} pid {pid}")
        group = groups.setdefault(owner, [0, 0])
        group[0] += kb
        group[1] += 1
    ranked = sorted(groups.items(), key=lambda g: -g[1][0])[:top]
    return [(owner, f"{owner[2]} {kb / GIB_KB:.1f} GB" + (f" in {n} processes" if n > 1 else ""))
            for owner, (kb, n) in ranked]


def line(s, v, why, cons):
    if v == "UNKNOWN":
        return f"UNKNOWN\thost memory is not measurable here (no readable {PROC}/meminfo and {PROC}/pressure/memory)"
    text = summary(s) + "".join(f"; {w}" for w in why)
    return f"{v}\t{text}" + (f"; largest: {', '.join(cons)}" if cons else "")


def replace_text(path, text):
    fd, tmp = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def record(path, s, v):
    with open(path, "a") as f:
        f.write(f"{int(time.time())}\t{s['available_kb']}\t{s['swap_used_kb']}\t{s['pressure']:.2f}\t{v}\n")
    with open(path) as f:
        rows = f.readlines()
    if len(rows) > KEEP_ROWS + 120:
        replace_text(path, "".join(rows[-KEEP_ROWS:]))


def admit(task, state, s, v, why):
    rec = os.path.join(state, "admission-refused")
    if v in ("OK", "UNKNOWN"):
        try:
            os.remove(rec)
        except FileNotFoundError:
            pass
        return 0
    reason = f"host memory under pressure: {'; '.join(why)} ({summary(s)})"
    os.makedirs(state, exist_ok=True)
    replace_text(rec, f"{int(time.time())}\t{task}\t{reason}\n")
    print(reason)
    return 1


def main():
    parser = argparse.ArgumentParser(description="Host memory guard: measure, admit, and alert before an oomd kill.")
    parser.add_argument("--config", help="thresholds file (config/host-memory); absent means the defaults")
    parser.add_argument("--admit", metavar="TASK", help="admission for one agent launch; needs --state")
    parser.add_argument("--state", metavar="DIR", help="the launching home's state directory")
    parser.add_argument("--record", metavar="FILE", help="append one sample to FILE")
    parser.add_argument("--owned-top-task", metavar="DIR", help="append the top task ID if owned by DIR")
    parser.add_argument("--state-dir", action="append", default=[], help="state directory whose task records map consumers")
    args = parser.parse_args()
    if args.admit and not args.state:
        die("--admit needs --state")
    cfg = load_config(args.config)
    s = sample()
    v, why = verdict(s, cfg)
    if args.admit:
        sys.exit(admit(args.admit, args.state, s, v, why))
    if args.record and s is not None:
        record(args.record, s, v)
    cons = consumers(args.state_dir) if v == "ALERT" or (not args.record and v != "UNKNOWN") else []
    output = line(s, v, why, [text for _, text in cons])
    if args.owned_top_task:
        task = cons[0][0][1] if cons and cons[0][0][0] == os.path.realpath(args.owned_top_task) else ""
        output += "\t" + task
    print(output)


if __name__ == "__main__":
    main()
