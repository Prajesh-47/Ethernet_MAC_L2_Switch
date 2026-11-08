#!/usr/bin/env python3
"""
perf_sweep.py -- run tb_perf across a grid of patterns, frame sizes and loads

    make perf       (builds the test, runs this, then draws the charts)

Writes docs/perf/results.csv with one row per run. Any run that doesn't print
RESULT: PASS stops the sweep: a failed run's numbers mean nothing.
No packages needed.
"""
import concurrent.futures
import os
import subprocess
import sys

SIM = "build/obj_perf/sim"
OUT = "docs/perf/results.csv"
PATTERNS = ["pair", "uniform", "incast"]
SIZES = [64, 128, 256, 512, 1024, 1518]
LOADS = [10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 100]
SEEDS = [1, 2, 3]
# fewer frames at larger sizes, because each one takes longer to simulate
FRAMES = {64: 800, 128: 600, 256: 500, 512: 300, 1024: 200, 1518: 150}
COLUMNS = ("pattern,size,load,senders,offered_mbps,delivered_mbps,sent,delivered,"
           "drop_pct,lat_min,lat_avg,lat_p50,lat_p99,lat_max").split(",")


def run(job):
    pattern, size, load, seed = job
    cmd = [SIM, f"+PATTERN={pattern}", f"+SIZE={size}", f"+LOAD={load}",
           f"+N={FRAMES[size]}", f"+verilator+seed+{seed}"]
    out = subprocess.run(cmd, capture_output=True, text=True, check=False).stdout
    perf = [line for line in out.splitlines() if line.startswith("PERF,")]
    if "RESULT: PASS" not in out or len(perf) != 1:
        errors = [line for line in out.splitlines() if "ERROR" in line or "RESULT" in line]
        raise RuntimeError(f"{job} failed: {errors[:3]}")
    return job, perf[0][len("PERF,"):]


def main():
    jobs = [(p, s, l, seed) for p in PATTERNS for s in SIZES for l in LOADS for seed in SEEDS]
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
        for n, (job, row) in enumerate(pool.map(run, jobs), 1):
            results[job] = row
            if n % 50 == 0:
                print(f"  {n} of {len(jobs)} runs", flush=True)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="ascii") as f:
        f.write("seed," + ",".join(COLUMNS) + "\n")
        for job in jobs:
            f.write(f"{job[3]},{results[job]}\n")
    print(f"wrote {OUT}: {len(jobs)} runs, all passed their integrity checks")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        sys.exit(f"RESULT: FAIL ({e})")
