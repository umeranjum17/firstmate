#!/usr/bin/env bash
# Wake Main when the Claude window burns ahead of time. The leads and many workers share one account, so an empty
# 5 h window stops Main and every lead until it resets. Fires when the 5 h window is under 35% with more than 60 min
# to its reset (again on each 10% step), or once when the week is at or under 40% left. At most one read per 10 min.
# Usage: $0 [quota-json-file] (file = test input; CQ_MARK then names the repeat-state file, default a fresh temp file).
# The burn rate alone never wakes: Opus (effort medium) may take build work while the week is above 40% left. At or
# under 40% left the one week wake names the action and carries the burn rate.
# ponytail: fixed thresholds; tune here if the number of Opus lanes changes.
set -u
FM_MAIN=${FM_MAIN_HOME:-$HOME/firstmate}
MARK=$FM_MAIN/state/.claude-quota.last
now=$(date +%s)
if [ $# -eq 0 ]; then
  [ -f "$MARK" ] && [ $((now - $(stat -c %Y "$MARK"))) -lt 600 ] && exit 0
  j=$(timeout 60 quota-axi --json 2>/dev/null) || exit 0
else
  j=$(cat "$1"); MARK=${CQ_MARK:-$(mktemp)}
fi
HIST=$FM_MAIN/state/.claude-quota.hist; [ $# -eq 0 ] || HIST=${CQ_HIST:-$(mktemp)}
out=$(printf '%s' "$j" | HIST=$HIST PREV=$(cat "$MARK" 2>/dev/null) python3 -I -c '
import json,sys,datetime as D
try:
    x=[p for p in json.load(sys.stdin)["providers"] if p.get("provider")=="claude"][0]
    W={w["id"]:w for w in x["windows"]}; f,w=W["five_hour"],W["seven_day"]
except Exception: sys.exit()
P=lambda s: D.datetime.fromisoformat(s.replace("Z","+00:00"))
left=int((P(f["resetsAt"])-D.datetime.now(D.timezone.utc)).total_seconds()//60)
fp,wp,wr=f["percentRemaining"],w["percentRemaining"],w["resetsAt"]
import os,time
now=time.time(); hp=os.environ["HIST"]
try: h=[tuple(map(float,l.split())) for l in open(hp) if l.strip()]
except Exception: h=[]
h=[x for x in h if now-x[0]<5*3600]+[(now,wp)]
open(hp,"w").write("".join(f"{int(a)} {int(b)}\n" for a,b in h[-40:]))
old=[x for x in h if now-x[0]>=3600]
rate=(old[0][1]-wp)/((now-old[0][0])/3600) if old else 0
reset_h=(P(wr)-D.datetime.now(D.timezone.utc)).total_seconds()/3600
five,low=fp<35 and left>60,wp<=40
if not (five or low): sys.exit()
s5,sw=(str(fp//10) if five else "-"),str(int(low)); prev=os.environ.get("PREV","").split("|")
print(f"{s5}|{sw}")
if five and prev[:1]!=[s5]: print(f"claude-quota: Claude 5 h window {fp}% left with {left} min to its reset; week {wp}% left (resets {wr}). Opus burns ahead of the window: move the newest Opus workers (never Main or the leads) to GLM 5.3 Flash (pi zai/glm-5.3-flash) or Go Muse / DeepSeek (never Step 5) until the 5 h window resets; at week <= 40% left also drop Opus from the ordinary dispatch rules")
burn=f", burning {rate:.1f}%/h over the last {(now-old[0][0])/3600:.1f} h = empty in {wp/rate:.0f} h" if rate>0 else ""
if low and prev[1:2]!=[sw]: print(f"claude-quota: Claude week {wp}% left{burn}; it resets in {reset_h:.0f} h ({wr}). At or under 40% left: no new Opus build workers; leads move build work to the GLM/Go mix (GLM 5.3 Flash pi zai/glm-5.3-flash, Go Muse / DeepSeek within the Go pace; never Main or the leads, never Step 5); Main reports this to the captain")
')
[ -n "$out" ] || { : > "$MARK"; exit 0; }
printf '%s' "${out%%$'\n'*}" > "$MARK"
case $out in *$'\n'*) printf '%s\n' "${out#*$'\n'}" ;; esac
