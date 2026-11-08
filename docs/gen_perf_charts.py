#!/usr/bin/env python3
"""
gen_perf_charts.py -- draw docs/perf/*.svg from docs/perf/results.csv

    make perf       (runs the sweep, then this script)

Each point is the mean of the seeds. No packages needed.
"""
import collections
import csv
import math

CSV = "docs/perf/results.csv"
PATTERNS = [("pair", "Paired, no contention"), ("uniform", "Uniform random"), ("incast", "Three ports into one")]
SIZES = [64, 1518]
W, H = 900, 420
TOP, BOTTOM, LEFT, RIGHT, GAP = 92, 54, 64, 96, 40

STYLE = """
<style>
  text { font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; fill: #52514e; font-size: 13px; }
  .bg { fill: #fcfcfb; }
  .title { fill: #0b0b0b; font-size: 17px; font-weight: 600; }
  .panel { fill: #0b0b0b; font-size: 14px; font-weight: 600; }
  .label { fill: #0b0b0b; font-size: 12px; }
  .grid { stroke: #e3e2de; stroke-width: 1; }
  .line { fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
  .dot { stroke: #fcfcfb; stroke-width: 2; }
  .l1 { stroke: #2a78d6; } .l2 { stroke: #eb6834; } .l3 { stroke: #1baf7a; }
  .d1 { fill: #2a78d6; } .d2 { fill: #eb6834; } .d3 { fill: #1baf7a; }
  @media (prefers-color-scheme: dark) {
    text { fill: #c3c2b7; }
    .bg { fill: #1a1a19; }
    .title, .panel, .label { fill: #f0efec; }
    .grid { stroke: #3a3a37; }
    .dot { stroke: #1a1a19; }
    .l1 { stroke: #3987e5; } .l2 { stroke: #d95926; } .l3 { stroke: #199e70; }
    .d1 { fill: #3987e5; } .d2 { fill: #d95926; } .d3 { fill: #199e70; }
  }
</style>
"""


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;")


def load():
    groups = collections.defaultdict(list)
    with open(CSV, encoding="ascii") as f:
        for r in csv.DictReader(f):
            groups[(r["pattern"], int(r["size"]), int(r["load"]))].append(r)
    return groups


def mean(rows, col):
    return sum(float(r[col]) for r in rows) / len(rows)


def chart(path, title, ylabel, col, ticks, ymap, fmt, unit):
    groups = load()
    loads = sorted({k[2] for k in groups})
    pw = (W - LEFT - RIGHT - GAP - RIGHT) / 2
    ph = H - TOP - BOTTOM
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
         f'aria-label="{esc(title)}">', f"<title>{esc(title)}</title>", STYLE,
         f'<rect class="bg" width="{W}" height="{H}"/>',
         f'<text class="title" x="{LEFT}" y="28">{esc(title)}</text>']
    # legend
    lx = LEFT
    for n, (_, name) in enumerate(PATTERNS, 1):
        o.append(f'<line class="l{n}" x1="{lx}" y1="50" x2="{lx + 22}" y2="50" stroke-width="2"/>')
        o.append(f'<circle class="dot d{n}" cx="{lx + 11}" cy="50" r="5"/>')
        o.append(f'<text x="{lx + 30}" y="55">{esc(name)}</text>')
        lx += 52 + 7.6 * len(name)
    for i, size in enumerate(SIZES):
        x0 = LEFT + i * (pw + RIGHT + GAP)
        o.append(f'<text class="panel" x="{x0}" y="{TOP - 8}">{size}-byte frames</text>')

        def px(v):
            return x0 + pw * v / 100

        def py(v):
            return TOP + ph * (1 - ymap(v))

        for t in ticks:
            o.append(f'<line class="grid" x1="{x0}" x2="{x0 + pw}" y1="{py(t):.1f}" y2="{py(t):.1f}"/>')
            if i == 0:
                o.append(f'<text x="{x0 - 8}" y="{py(t) + 4:.1f}" text-anchor="end">{fmt(t)}</text>')
        for t in (0, 25, 50, 75, 100):
            o.append(f'<text x="{px(t):.1f}" y="{TOP + ph + 20}" text-anchor="middle">{t}%</text>')
        o.append(f'<text x="{x0 + pw / 2:.1f}" y="{TOP + ph + 42}" text-anchor="middle">Offered load per sending port</text>')
        if i == 0:
            o.append(f'<text transform="translate(16 {TOP + ph / 2}) rotate(-90)" text-anchor="middle">{esc(ylabel)}</text>')
        ends = []
        for n, (pat, name) in enumerate(PATTERNS, 1):
            pts = [(l, mean(groups[(pat, size, l)], col)) for l in loads]
            line = " ".join(f"{px(l):.1f},{py(v):.1f}" for l, v in pts)
            o.append(f'<polyline class="line l{n}" points="{line}"/>')
            for l, v in pts:
                o.append(f'<circle class="dot d{n}" cx="{px(l):.1f}" cy="{py(v):.1f}" r="4.5">'
                         f"<title>{esc(name)}, {size} B, {l}% load: {fmt(v)}{unit}</title></circle>")
            ends.append((py(pts[-1][1]), pts[-1][1]))
        # direct labels at the line ends, only where they don't collide (the legend always identifies them)
        ends.sort(key=lambda e: e[0])
        last_y = -100
        for y, v in ends:
            if y - last_y >= 15:
                o.append(f'<text class="label" x="{x0 + pw + 9:.1f}" y="{y + 4:.1f}">{fmt(v)}{unit}</text>')
                last_y = y
    o.append("</svg>")
    with open(path, "w", encoding="ascii") as f:
        f.write("\n".join(o) + "\n")
    print(f"wrote {path}")


def ns(v):
    return f"{v / 1000:.3g} µs".encode("ascii", "xmlcharrefreplace").decode() if v >= 1000 else f"{v:.0f} ns"


LOG_LO, LOG_HI = math.log10(100), math.log10(200000)
chart("docs/perf/throughput.svg", "Delivered throughput against offered load", "Delivered, all ports (Mb/s)",
      "delivered_mbps", [0, 1000, 2000, 3000, 4000], lambda v: v / 4000, lambda v: f"{v:,.0f}", "")
chart("docs/perf/latency.svg", "99th percentile latency against offered load (log scale)", "Latency, delivered frames",
      "lat_p99", [100, 1000, 10000, 100000], lambda v: (math.log10(v) - LOG_LO) / (LOG_HI - LOG_LO), ns, "")
