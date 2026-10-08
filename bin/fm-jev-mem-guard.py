#!/usr/bin/env python3
"""
fm-jev-mem-guard.py - host memory guard: measure, admit, and alert before an oomd kill.

Every fleet agent runs inside one agent-runtime service, and systemd-oomd kills
that service as a unit when its slice's memory pressure stays above the oomd
limit (on the reference host: "some" avg10 above 50% for 20 s). Host-wide
pressure is never below a slice's own, so classifying the host's
/proc/pressure/memory is a conservative early reading of the same signal.

Usage (bin/fm-jev-mem-guard.sh runs this with python3):
  fm-jev-mem-guard.sh [--config FILE] [--state-dir DIR ...]
      Print "<verdict>\t<summary>" for the host, naming the largest consumers.
  fm-jev-mem-guard.sh [--config FILE] --admit TASK --state DIR
      Admission for one agent launch (bin/fm-spawn.sh, bin/fm-control.sh relaunch).
      Exit 0 admits and removes DIR/admission-refused. Exit 1 refuses: prints the
      reason and writes DIR/admission-refused as "<epoch>\t<task>\t<reason>".
  fm-jev-mem-guard.sh [--config FILE] --record FILE [--state-dir DIR ...]
      One watcher sample (bin/fm-watch.sh host_memory_tick): appends
      "<epoch>\t<MemAvailable kB>\t<swap used kB>\t<pressure some avg10>\t<verdict>"
      to FILE, keeping the newest 2880 rows (a day at the 30 s cadence), and prints
      "<verdict>\t<summary>"; an ALERT summary names the largest consumers.

Verdicts: OK; WAIT (new agents wait); ALERT (pause or stop the largest consumer);
UNKNOWN (not measurable, for example no pressure file: admits and records nothing).
Thresholds come from config/host-memory (docs/configuration.md "Host memory guard").
Consumers are summed RSS plus swap per owner: the task whose FM_TASK_ID the process
carries, else the task or lead whose recorded worktree, task temp, or home holds its
working directory (task records in each --state-dir), else the process itself.
The proc root is FM_HOST_MEMORY_PROC (default /proc). Exit 2: usage or an invalid
config file, with the reason on stderr.
"""

import argparse
import os
import sys
import time

PROC = os.environ.get("FM_HOST_MEMORY_PROC") or "/proc"
DEFAULTS = {"wait_pressure": 20.0, "wait_available_gb": 12.0, "alert_pressure": 35.0, "alert_available_gb": 6.0}
KEEP_ROWS = 2880
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
            if not sep or key not in DEFAULTS or float(val) < 0:
                raise ValueError
            cfg[key] = float(val)
        except ValueError:
            die(f"invalid {path} line {n}: {raw!r} (expected KEY=number, keys: {', '.join(DEFAULTS)})")
    return cfg


def sample():
    """{available_kb, swap_used_kb, pressure}, or None when not measurable."""
    try:
        mem = {}
        for line in open(f"{PROC}/meminfo"):
            key, _, val = line.partition(":")
            if val.split() and val.split()[0].isdigit():
                mem[key.strip()] = int(val.split()[0])
        some = next(l for l in open(f"{PROC}/pressure/memory") if l.startswith("some "))
        pressure = float(dict(f.split("=", 1) for f in some.split()[1:])["avg10"])
        return {"available_kb": mem["MemAvailable"],
                "swap_used_kb": max(0, mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)),
                "pressure": pressure}
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
            f"{s['swap_used_kb'] / GIB_KB:.1f} GB swap used")


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
    """([(path, label)] longest path first, {task id: label}) from the task records."""
    metas = [(d, f[:-5], read_meta(os.path.join(d, f)))
             for d in state_dirs if os.path.isdir(d) for f in sorted(os.listdir(d)) if f.endswith(".meta")]
    lead_of = {os.path.realpath(m["home"]): tid for _, tid, m in metas if m.get("kind") == "secondmate" and m.get("home")}
    paths, tasks = [], {}
    for d, tid, m in metas:
        if m.get("kind") == "secondmate":
            if m.get("home"):
                paths.append((os.path.realpath(m["home"]), f"lead {tid}"))
            continue
        home = lead_of.get(os.path.realpath(os.path.dirname(os.path.abspath(d))), "main")
        tasks[tid] = f"task {tid} ({home})"
        paths += [(os.path.realpath(m[k]), tasks[tid]) for k in ("worktree", "tasktmp") if m.get(k)]
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
        label = None
        try:
            tid = next((e[11:].decode(errors="replace") for e in open(f"{base}/environ", "rb").read().split(b"\0")
                        if e.startswith(b"FM_TASK_ID=")), "")
            label = tasks.get(tid, f"task {tid}") if tid else None
        except OSError:
            pass
        if label is None:
            try:
                cwd = os.path.realpath(os.readlink(f"{base}/cwd"))
                label = next((l for p, l in paths if cwd == p or cwd.startswith(p + "/")), None)
            except OSError:
                pass
        label = label or f"{status.get('Name', '?').strip()} pid {pid}"
        group = groups.setdefault(label, [0, 0])
        group[0] += kb
        group[1] += 1
    ranked = sorted(groups.items(), key=lambda g: -g[1][0])[:top]
    return [f"{label} {kb / GIB_KB:.1f} GB" + (f" in {n} processes" if n > 1 else "") for label, (kb, n) in ranked]


def line(s, v, why, cons):
    if v == "UNKNOWN":
        return f"UNKNOWN\thost memory is not measurable here (no readable {PROC}/meminfo and {PROC}/pressure/memory)"
    text = summary(s) + "".join(f"; {w}" for w in why)
    return f"{v}\t{text}" + (f"; largest: {', '.join(cons)}" if cons else "")


def record(path, s, v):
    with open(path, "a") as f:
        f.write(f"{int(time.time())}\t{s['available_kb']}\t{s['swap_used_kb']}\t{s['pressure']:.2f}\t{v}\n")
    with open(path) as f:
        rows = f.readlines()
    if len(rows) > KEEP_ROWS + 120:
        with open(path + ".tmp", "w") as f:
            f.writelines(rows[-KEEP_ROWS:])
        os.replace(path + ".tmp", path)


def admit(task, state, s, v, why):
    rec = os.path.join(state, "admission-refused")
    if v in ("OK", "UNKNOWN"):
        if os.path.exists(rec):
            os.remove(rec)
        return 0
    reason = f"host memory under pressure: {'; '.join(why)} ({summary(s)})"
    os.makedirs(state, exist_ok=True)
    with open(rec + ".tmp", "w") as f:
        f.write(f"{int(time.time())}\t{task}\t{reason}\n")
    os.replace(rec + ".tmp", rec)
    print(reason)
    return 1


def main():
    parser = argparse.ArgumentParser(description="Host memory guard: measure, admit, and alert before an oomd kill.")
    parser.add_argument("--config", help="thresholds file (config/host-memory); absent means the defaults")
    parser.add_argument("--admit", metavar="TASK", help="admission for one agent launch; needs --state")
    parser.add_argument("--state", metavar="DIR", help="the launching home's state directory")
    parser.add_argument("--record", metavar="FILE", help="append one sample to FILE")
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
    print(line(s, v, why, cons))


if __name__ == "__main__":
    main()
