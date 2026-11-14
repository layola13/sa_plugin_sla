#!/usr/bin/env python3
"""RSS-envelope runner: run a command in its own session; sample the
process group's total RSS every ~25 ms; if it exceeds CAP_MB, SIGKILL
the group and exit 137 (OOM-kill semantics). Otherwise exit with the
child's rc. Prints the measured group peak at the end.

Usage: rss_envelope_run.py <cap_mb> <out_log> <cmd...>
"""
import os
import signal
import subprocess
import sys
import time

cap_mb = float(sys.argv[1])
out_log = sys.argv[2]
cmd = sys.argv[3:]


def group_rss_mb(pgid: int) -> float:
    total_kb = 0
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/stat", "rb") as fh:
                parts = fh.read().split()
            if int(parts[4]) != pgid:
                continue
            with open(f"/proc/{pid}/status") as fh:
                for line in fh:
                    if line.startswith("VmRSS:"):
                        total_kb += int(line.split()[1])
                        break
        except (OSError, ValueError, IndexError):
            continue
    return total_kb / 1024.0


start = time.monotonic()
peak = 0.0
exceeded = False
with open(out_log, "wb") as out_fh:
    proc = subprocess.Popen(cmd, stdout=out_fh, stderr=subprocess.STDOUT,
                            start_new_session=True)
    pgid = proc.pid
    while True:
        rss = group_rss_mb(pgid)
        peak = max(peak, rss)
        if rss > cap_mb:
            exceeded = True
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            break
        if proc.poll() is not None:
            break
        time.sleep(0.025)
    rc = proc.wait()
wall = time.monotonic() - start
if exceeded:
    print(f"ENVELOPE_EXCEEDED cap_mb={cap_mb:.0f} peak_rss_mb={peak:.1f} wall_s={wall:.2f}")
    sys.exit(137)
print(f"ENVELOPE_OK rc={rc} peak_rss_mb={peak:.1f} wall_s={wall:.2f} cap_mb={cap_mb:.0f}")
sys.exit(rc)
