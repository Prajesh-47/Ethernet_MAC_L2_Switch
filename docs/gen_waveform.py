#!/usr/bin/env python3
"""
gen_waveform.py -- draw smoke-test step 1 from build/switch.vcd as docs/waveform.svg

    make wave        (runs the smoke test with +vcd, then this script)

Step 1: station A broadcasts one 64-byte frame into port 0. The picture shows
  - the frame arriving on GMII rx of port 0
  - store-and-forward: the ingress buffer only offers it (head_valid) after
    the last byte and the CRC verdict are in
  - the core granting all three other ports at once and forking the frame
  - three identical copies leaving on GMII tx of ports 1, 2 and 3
No packages needed: a minimal VCD reader is included.
"""
import sys

vcd_path, out = sys.argv[1], sys.argv[2]

# ---------------- minimal VCD reader ----------------
ids, scope, tv = {}, [], {}
with open(vcd_path) as f:
    in_defs, now = True, 0
    for line in f:
        tok = line.split()
        if not tok:
            continue
        if in_defs:
            if tok[0] == "$scope":
                scope.append(tok[2])
            elif tok[0] == "$upscope":
                scope.pop()
            elif tok[0] == "$var":
                code, name = tok[3], tok[4]
                ids.setdefault(code, []).append(".".join(scope + [name]))
                tv.setdefault(code, [])
            elif tok[0] == "$enddefinitions":
                in_defs = False
            continue
        c = tok[0][0]
        if c == "#":
            now = int(tok[0][1:])
        elif c in "01xzXZ" and len(tok) == 1:
            tv[tok[0][1:]].append((now, tok[0][0]))
        elif c in "bB":
            tv[tok[1]].append((now, tok[0][1:]))

def sig(name, bit=None):
    for code, names in ids.items():
        if any(n.endswith(name) and n.split(".")[-1] == name.split(".")[-1] and n.endswith("." + name) for n in names):
            vals = tv[code]
            if bit is None:
                return vals
            out_v = []
            for t, v in vals:
                v = v.rjust(bit + 1, "0")
                out_v.append((t, v[-1 - bit]))
            return out_v
    raise KeyError(name)

SIGS = [  # (label, vcd name, bit or None)
    ("port 0  rx_dv",          "tb_switch_smoke.rx_dv",  0),
    ("ingress 0 head_valid",   "dut.hv",                 0),
    ("core xfer (port 0)",     "dut.xfer",               0),
    ("core -> TX FIFO 1 valid", "dut.tx_v",              1),
    ("core -> TX FIFO 2 valid", "dut.tx_v",              2),
    ("core -> TX FIFO 3 valid", "dut.tx_v",              3),
    ("port 1  tx_en",          "tb_switch_smoke.tx_en",  1),
    ("port 2  tx_en",          "tb_switch_smoke.tx_en",  2),
    ("port 3  tx_en",          "tb_switch_smoke.tx_en",  3),
]

# window: from the first rx_dv rise to just after the last tx_en fall of step 1
rx = sig("tb_switch_smoke.rx_dv", 0)
t_rx = next(t for t, x in rx if x == "1")
tx3 = sig("tb_switch_smoke.tx_en", 3)
t_end = next(t for t, x in tx3 if x == "0" and t > t_rx)
t0, t1 = t_rx - 100_000, t_end + 150_000          # ps

def at(vals, t):
    v = "0"
    for tt, x in vals:
        if tt > t:
            break
        v = x
    return v

def segments(vals):
    pts = [(t0, at(vals, t0))] + [(t, x) for t, x in vals if t0 < t < t1]
    return [(t, pts[i + 1][0] if i + 1 < len(pts) else t1, x) for i, (t, x) in enumerate(pts)]

L, R, ROW, TOP = 200, 940, 30, 58
X = lambda t: L + (t - t0) / (t1 - t0) * (R - L)
W, H = R + 30, TOP + ROW * len(SIGS) + 50
ink, quiet, grid, rxc, swc, txc = "#1f2328", "#59636e", "#d1d9e0", "#0969da", "#8250df", "#1a7f37"
o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="12">',
     f'<rect width="{W}" height="{H}" fill="#ffffff"/>',
     f'<text x="20" y="26" font-size="14" font-weight="600" fill="{ink}" font-family="-apple-system, Segoe UI, Helvetica, Arial, sans-serif">'
     'One broadcast in on port 0: stored, checked, then forked to ports 1, 2 and 3 at once</text>']
step = 200_000
g = t0 + step
while g < t1:
    o.append(f'<line x1="{X(g):.1f}" x2="{X(g):.1f}" y1="{TOP - 8}" y2="{H - 36}" stroke="{grid}" stroke-dasharray="2 3"/>')
    o.append(f'<text x="{X(g):.1f}" y="{H - 20}" text-anchor="middle" fill="{quiet}" font-size="10">{(g - t0) / 1000:.0f} ns</text>')
    g += step
for i, (label, name, bit) in enumerate(SIGS):
    y = TOP + i * ROW
    yh, yl = y + 4, y + ROW - 8
    col = rxc if i == 0 else swc if i < 6 else txc
    o.append(f'<text x="{L - 12}" y="{(yh + yl) / 2 + 4:.1f}" text-anchor="end" fill="{ink}">{label}</text>')
    d, prev = [], None
    for s, e, x in segments(sig(name, bit)):
        yy = yh if x == "1" else yl
        if prev is None:
            d.append(f"M{X(s):.1f} {yy}")
        elif prev != yy:
            d.append(f"V{yy}")
        d.append(f"H{X(e):.1f}")
        prev = yy
    o.append(f'<path d="{" ".join(d)}" fill="none" stroke="{col}" stroke-width="1.6"/>')
o.append("</svg>")
open(out, "w").write("\n".join(o))
print(f"wrote {out}: {len(SIGS)} signals, {(t1 - t0) / 1000:.0f} ns window")
