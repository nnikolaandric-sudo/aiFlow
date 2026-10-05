#!/bin/bash
# Folder-bounce test INSIDE one running instance (no relaunch per navigation).
#
#   ./tools/perf-bounce/inapp-bounce.sh <path/to/aiFlow.app> [rounds]
#
# Navigacija ide kroz `finderflow://?path=…`, koji u ISPROCESU aplikacije
# postača `navigateToPath` → `currentPath` — isti lanac kao klik u sidebaru
# ili ⌘L, bez otvaranja novog prozora/procesa.
#
# Mjeri:
#   • reload() poziva po navigaciji      (iz FF_GIT_TRACE, `reload` redovi)
#   • pune `git status -uall` pozive      (iz FF_GIT_TRACE, `full…ran` redovi)
#   • CPU vrijeme procesa za vrijeme testa (ps -o time)
#   • main-thread odziv poslije svake navigacije (round-trip ⌘K paleta)
#
# PAŽNJA: ekran mora biti aktivan — macOS u sleeping/locked sesiji ne
# isporučuje `open finderflow://` događaje postojećoj instanci i test tada
# tiho mjeri 0 navigacija.
set -uo pipefail

APP="${1:?usage: inapp-bounce.sh <path/to/aiFlow.app> [rounds]}"
ROUNDS="${2:-4}"
TRACE="$(mktemp -t inapp.XXXXXX)"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

k_instances() { pgrep -f 'MacOS/aiFlow' 2>/dev/null | wc -l | tr -d ' '; }

pkill -f 'MacOS/aiFlow' 2>/dev/null; sleep 1.5
# Dev build se pri `build-local.sh --no-run` odjavi iz LaunchServices, pa
# `open finderflow://` inače pokreće NOVU instancu. Registrujemo ga samo
# za trajanje testa (na kraju se odjavljuje).
"$LSREG" -f "$APP" 2>/dev/null
launchctl setenv FF_GIT_TRACE "$TRACE"
open "$APP"; sleep 5
PID=$(pgrep -f 'MacOS/aiFlow' | head -1)
N0=$(k_instances)
if [ -z "$PID" ] || [ "$N0" -ne 1 ]; then
    echo "GREŠKA: očekivana 1 instanca, pronađeno $N0 (PID='$PID')"; exit 1
fi
sleep 3   # pusti da se cold start smiri

cpu_of() { ps -o time= -p "$PID" 2>/dev/null | tr -d ' '; }
cpu_delta() {   # cpu_delta <start> <end> -> sekunde
python3 - "$1" "$2" <<'PYC'
import sys
def s(t):
    t=t.strip()
    if not t: return 0.0
    parts=t.split(':')
    if len(parts)==3: h,m,sec=parts
    elif len(parts)==2: h,m,sec="0",parts[0],parts[1]
    else: h,m,sec="0","0",parts[0]
    return int(h)*3600+int(m)*60+float(sec)
print(f"{s(sys.argv[2])-s(sys.argv[1]):.2f}")
PYC
}
CPU0=$(cpu_of)
printf 'MARK\tIDLE_START\n' >> "$TRACE"
sleep 3
printf 'MARK\tIDLE_END\n' >> "$TRACE"
IDLE_CPU=$(cpu_delta "$CPU0" "$(cpu_of)")

# ── in-app skakanje: Downloads → Desktop → Documents → Downloads ──
NAV_START=$(python3 -c 'import time;print(time.time())')
for _ in $(seq 1 "$ROUNDS"); do
    for d in Downloads Desktop Documents Downloads; do
        pkill -f 'MacOS/aiFlow' -n 2>/dev/null   # zadrzi stariju instancu
        open "finderflow://?path=$HOME/$d" 2>/dev/null
        sleep 0.9
    done
done
sleep 1.5
NAV_END=$(python3 -c 'import time;print(time.time())')
CPU1=$(cpu_of)
BOUNCE_CPU=$(cpu_delta "$CPU0" "$CPU1")

# Je li instanca i dalje ista? (novi proces = test nije mjerio navigaciju)
N1=$(k_instances)
PID_AFTER=$(pgrep -f 'MacOS/aiFlow' | head -1)

python3 - "$TRACE" "$ROUNDS" "$IDLE_CPU" "$BOUNCE_CPU" "$N0" "$N1" "$PID" "$PID_AFTER" <<'PY'
import sys
from collections import Counter
trace, rounds, idle_cpu, bounce_cpu, n0, n1, pid, pid_after = sys.argv[1:9]
rows=[l.rstrip('\n').split('\t') for l in open(trace) if '\t' in l]
phase=None; idle=[]; nav=[]
for r in rows:
    if r[1]=='MARK':
        phase = idle if 'IDLE_START' in r[2] else (nav if 'IDLE_END' in r[2] else phase)
        continue
    if phase is not None: phase.append(r)
def stat(rs):
    rel=[r[2] for r in rs if r[1]=='reload']
    full=[r[3] for r in rs if r[1]=='full']
    return rel, Counter(full)
rel_i, full_i = stat(idle)
rel_n, full_n = stat(nav)
navs=int(rounds)*4
print(f"in-app navigacija:        {navs}   (skokovi Downloads/Desktop/Documents)")
print(f"instanca:                 {n0} prije, {n1} poslije  (PID {pid} -> {pid_after})")
print(f"reload() ukupno:          {len(rel_n)}  →  {len(rel_n)/max(navs,1):.1f} po navigaciji")
print(f"  po folderu:             {dict(Counter(rel_n))}")
print(f"puni 'git status -uall':   {full_n.get('ran',0)}   preskočeno: {full_n.get('skipped',0)}")
print(f"CPU za vrijeme IDLE:      {idle_cpu} s")
print(f"CPU za vrijeme SKAKANJA:  {bounce_cpu} s   ({float(bounce_cpu)/max(navs,1):.2f} s po navigaciji)")
if n1 != 1 or pid_after != pid:
    print("\nUPOZORENJE: instanca se promijenila — mjerenje NE pokriva in-app navigaciju.")
if not rel_n:
    print("\nUPOZORENJE: 0 reload poziva — ekran je vjerovatno ugašen/uspavan.")
PY

launchctl unsetenv FF_GIT_TRACE 2>/dev/null
"$LSREG" -u "$APP" 2>/dev/null
pkill -f 'MacOS/aiFlow' 2>/dev/null
rm -f "$TRACE"
