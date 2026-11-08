#!/usr/bin/env python3
"""
check_capture.py -- did every frame go exactly where a learning switch sends it?

    python3 demo/check_capture.py build/demo      (run by make demo)

Reads frames.csv written by the harness: every frame that went into the switch
("in") or came out of it ("out"), per port, with a hash of its bytes. Replays
the "in" frames, in time order, through a reference learning switch:

    destination broadcast, multicast or not yet learned -> every other port (flood)
    destination learned on another port                 -> that port only
    destination learned on the same port                -> nowhere (filtered)
    the source is learned on the ingress port after the decision

Then requires the switch's real outputs to match: each expected copy must come
out, unchanged, on its port, and nothing else may come out anywhere.
The demo's traffic never has two ports sending to one, so a correct switch
drops nothing, and a missing copy is an error too.
No packages needed.
"""
import csv
import sys
from collections import defaultdict

NP = 4


def main(d):
    rows = list(csv.DictReader(open(f"{d}/frames.csv")))
    for r in rows:
        r["time_ns"] = int(r["time_ns"])
        r["port"] = int(r["port"])
    rows.sort(key=lambda r: r["time_ns"])
    ins = [r for r in rows if r["dir"] == "in"]
    outs = {e: [r for r in rows if r["dir"] == "out" and r["port"] == e] for e in range(NP)}
    used = {e: [False] * len(outs[e]) for e in range(NP)}

    table = {}
    errors = 0
    counts = defaultdict(int)
    story = []
    lat = []
    for f in ins:
        p, dst, src = f["port"], f["dst"], f["src"]
        multicast = int(dst[:2], 16) & 1
        if multicast or dst not in table:
            expect, kind = set(range(NP)) - {p}, "flood"
        elif table[dst] == p:
            expect, kind = set(), "filter"
        else:
            expect, kind = {table[dst]}, "forward"
        counts[kind] += 1
        got = set()
        for e in expect:                      # earliest unused identical frame after it went in
            for k, o in enumerate(outs[e]):
                if not used[e][k] and o["hash"] == f["hash"] and o["time_ns"] > f["time_ns"]:
                    used[e][k] = True
                    got.add(e)
                    lat.append((int(f["len"]), o["time_ns"] - f["time_ns"]))
                    break
        if got != expect:
            errors += 1
            if errors <= 10:
                print(f"  ERROR: {kind} frame {src} -> {dst} from port {p} at {f['time_ns']} ns: "
                      f"expected on {sorted(expect)}, came out on {sorted(got) or 'none (dropped)'}")
        if len(story) < 6 and (kind != "flood" or not multicast or f["ethertype"] == "0806"):
            what = {"0806": "ARP", "0800": "IPv4"}.get(f["ethertype"], f["ethertype"])
            story.append(f"  {what:4} {src} -> {dst}  port {p} -> {kind:7} out {sorted(got) or '-'}")
        if not (int(src[:2], 16) & 1):
            table[src] = p
    for e in range(NP):                       # anything left over came out where it shouldn't
        for k, o in enumerate(outs[e]):
            if not used[e][k]:
                errors += 1
                if errors <= 10:
                    print(f"  ERROR: unexpected frame {o['src']} -> {o['dst']} out of port {e} at {o['time_ns']} ns")

    print("  first frames (the switch learns from the first exchange, then stops flooding):")
    for s in story:
        print("  " + s)
    print(f"  frames in {len(ins)}: flooded {counts['flood']}, forwarded to one port {counts['forward']}, "
          f"filtered {counts['filter']}")
    print(f"  copies out {sum(len(v) for v in outs.values())}, all matched to an expected copy: {'yes' if errors == 0 else 'no'}")
    print("  learned: " + ", ".join(f"{m} on port {q}" for m, q in sorted(table.items(), key=lambda x: x[1])))
    # first preamble byte in to first preamble byte out, so it includes receiving
    # the whole frame (store-and-forward)
    for name, lo, hi in (("60-128 B", 60, 128), ("1400-1514 B", 1400, 1514)):
        v = sorted(x for n, x in lat if lo <= n <= hi)
        if v:
            print(f"  latency, {name} frames ({len(v)}): median {v[len(v) // 2]} ns, first byte in to first byte out "
                  f"(simulated time, includes receiving the whole frame)")
    if counts["flood"] == 0 or counts["forward"] == 0:
        errors += 1
        print("  ERROR: the capture needs both flooded and forwarded frames to show learning")
    if errors:
        print(f"capture check: FAIL ({errors} errors)")
        sys.exit(1)
    print("capture check: PASS")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/demo")
