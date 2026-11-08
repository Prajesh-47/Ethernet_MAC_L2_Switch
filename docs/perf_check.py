#!/usr/bin/env python3
"""
perf_check.py -- fail if the switch gets slower

    make perfcheck    (part of make test)

Runs a few fixed points and compares them with limits set below the measured
results in docs/performance.md, so seed variation doesn't trip them. If a change
legitimately moves a number, update the limit and say why in the commit.
No packages needed.
"""
import subprocess
import sys

SIM = "build/obj_perf/sim"
# pattern, size, load, frames, then limits. None means not checked.
#   min_mbps: delivered, all ports   max_drop: %   max_p50 / max_p99: ns
CHECKS = [
    ("pair",    64,   10, 300, None, 0.0, 200, 300, "unloaded latency"),
    ("pair",    64,   95, 500, 3650, 0.0, 250, 400, "no contention, smallest frames"),
    ("pair",  1518,   95, 100, 3550, 0.0, 250, 400, "no contention, largest frames"),
    ("pair",    64,  100, 500, 3990, 0.0, 250, 400, "full line rate, smallest frames (12-byte TX gap)"),
    ("pair",  1518,  100, 100, 3800, 0.0, 250, 400, "full line rate, largest frames"),
    ("uniform", 64,  100, 800, 2800, None, None, None, "saturation, smallest frames"),
    ("uniform", 1518, 100, 150, 2500, None, None, None, "saturation, largest frames"),
    ("incast", 512,  100, 200, 950, None, None, None, "one output at full rate"),
]


def main():
    failed = 0
    for pat, size, load, frames, min_mbps, max_drop, max_p50, max_p99, what in CHECKS:
        cmd = [SIM, f"+PATTERN={pat}", f"+SIZE={size}", f"+LOAD={load}", f"+N={frames}", "+verilator+seed+1"]
        out = subprocess.run(cmd, capture_output=True, text=True, check=False).stdout
        perf = [line for line in out.splitlines() if line.startswith("PERF,")]
        bad = []
        if "RESULT: PASS" not in out or len(perf) != 1:
            bad.append("integrity checks failed")
            delivered = drop = p50 = p99 = float("nan")
        else:
            f = perf[0].split(",")
            delivered, drop, p50, p99 = float(f[6]), float(f[9]), float(f[12]), float(f[13])
            if min_mbps is not None and delivered < min_mbps:
                bad.append(f"delivered below {min_mbps} Mb/s")
            if max_drop is not None and drop > max_drop:
                bad.append(f"drops above {max_drop}%")
            if max_p50 is not None and p50 > max_p50:
                bad.append(f"p50 above {max_p50} ns")
            if max_p99 is not None and p99 > max_p99:
                bad.append(f"p99 above {max_p99} ns")
        state = "FAIL: " + "; ".join(bad) if bad else "ok"
        print(f"  {pat:7} {size:4} B {load:3}%: {delivered:6.0f} Mb/s, drop {drop:5.1f}%, "
              f"p50 {p50:6.0f} ns, p99 {p99:6.0f} ns  [{what}] {state}")
        failed += bool(bad)
    if failed:
        sys.exit(f"RESULT: FAIL ({failed} of {len(CHECKS)} performance limits missed)")
    print(f"RESULT: PASS ({len(CHECKS)} performance limits met)")


if __name__ == "__main__":
    main()
