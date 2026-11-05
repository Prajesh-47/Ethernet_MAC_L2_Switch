# FPGA timing log

What the design achieves on an FPGA, how to reproduce it, and what each change did.
Add a row and a section here whenever a change moves these numbers.

## Current status

**The design routes but does not meet timing, and it has not run on hardware.**

ECP5-45 (`LFE5UM-45F`, CABGA381, speed grade 6), one placement seed, I/O pins unconstrained:

| Clock | Target | Achieved |
| --- | --- | --- |
| `sys_clk` | 156.25 MHz (125 MHz is the minimum, see [Clock targets](#clock-targets)) | **67.3 MHz** |
| `gmii_rx_clk[3:0]` | 125 MHz | 104–127 MHz (one of the four passes) |
| `gmii_tx_clk[3:0]` | 125 MHz | 94–110 MHz |

| Resource | Used | Available |
| --- | --- | --- |
| Logic cells (`TRELLIS_COMB`) | 8,467 (19%) | 43,848 |
| Flip-flops | 3,180 (7%) | 43,848 |
| Block RAM (`DP16KD`) | 8 (7%) | 108 |
| Distributed RAM write ports | 120 (2%) | 5,481 |

Xilinx 7-series has synthesis results only (1,948 `FDCE` flip-flops, 4 `RAMB36E1`). The open-source
flow here has no Xilinx place-and-route, so there are no Xilinx timing numbers.

## Reproducing the numbers

```bash
sudo apt install yosys nextpnr-ecp5 fpga-trellis

make synth   # about 1 minute: cell counts for both families, build/synth_*.log
make pnr     # a few more minutes: utilization and Fmax, full report in build/pnr_ecp5.log
```

`make pnr` passes `--timing-allow-fail`, so it reports a timing failure without failing the target.
Neither target is part of `make test` or CI yet.

To see a critical path, open `build/pnr_ecp5.log` and search for the **last**
`Critical path report for clock` entry naming that clock. Earlier entries are pre-route estimates.

## History

Each row is post-route unless marked otherwise. All rows use the same device and seed.

| Change | Logic cells | `sys_clk` | Slowest `sys_clk` path afterwards |
| --- | --- | --- | --- |
| Original RTL | did not finish synthesis in 280 s | none | one flip-flop per memory bit |
| Infer the ingress memory as LUT RAM | 35,320 (80%) | about 20 MHz, **pre-route only**: routing did not finish in 25 min | not reported |
| Move it to block RAM with a prefetch FIFO | 15,268 (34%) | 24.9 MHz | MAC table learn logic, about 40 ns |
| Share one comparator bank in the MAC table | 9,102 (20%) | 48.1 MHz | learn arbiter through an inferred multiplier |
| Replace the multiplier with explicit muxes | 8,636 (19%) | 56.6 MHz | TX FIFO fill level through the egress arbiter |
| Register the TX FIFO empty flag | 8,629 (19%) | 62.3 MHz | ingress commit decision, through a 32-bit carry chain |
| Simplify the ingress length check | 8,467 (19%) | 67.3 MHz | queue read through the destination mask and grant logic to `own_v` |

### Memory written in an async-reset block

Yosys cannot infer RAM from an array assigned inside `always @(posedge clk or negedge rst_n)`. It
builds one flip-flop per bit instead, about 32,768 per port here. The writes moved to their own
`always @(posedge clk)` block in `rtl/ingress_buf.v`. Congestion-mode results stayed identical, so
this did not change cycle behaviour.

### Block RAM and prefetch (`rtl/ingress_buf.v`)

Block RAM has a registered read, so the old combinational `out_tdata` could not stay. The read side
now has three parts:

```
mem (registered read) -> rd_data -> 4-entry prefetch FIFO -> out_t*
```

- **Timing:** `out_tready` stops at the FIFO and never reaches the RAM address.
- **Throughput:** a read is issued whenever the FIFO has room for it and for the read already in
  progress. Once a frame has started it runs at one byte per clock with no gaps, which the
  no-underrun guarantee depends on.
- **Latency:** the first byte appears 3 clocks after `xfer` rises.
- **Capacity:** there are two pointers. `fetch_ptr` tracks reads and `rd_ptr` tracks delivery, and
  space is released by `rd_ptr`. The buffer holds exactly the same bytes as before, so the reference
  model in `tb_ingress_buf` did not change.

### Shared MAC table lookup (`rtl/mac_table.v`)

The old table compared four lookups and one learn against all 16 entries in the same cycle, and went
from the learn arbiter to a table write in one cycle. It now has one comparator bank and three stages:

```
S: pick the waiting learn, otherwise the next lookup port -> register the address
A: compare the address with all entries                    -> register the match vector
B: a lookup stores its result, a learn updates the table
```

This changed the interfaces, and each change has a reason:

- **`lk_valid` on the table and core.** A result now arrives a few cycles after the address, so the
  core waits for it before starting or dropping a frame.
- **`head_valid` drops for one cycle after every pop (`just_popped`).** This is how the table learns
  that `head_dst` changed. It clears `lk_valid` and discards lookups in stages A and B, so a frame
  can never be forwarded on its predecessor's result.
- **Lookups repeat while `lk_en` is high.** A frame can wait thousands of cycles for its ports, and
  its result must follow the table during that wait, for example if a station moves.
- **One learn at a time, 3 cycles each.** The second learn of an address compares against a table
  that already contains the first, so an address cannot be inserted twice. Four ports learning at
  once is well below the limit, because a frame takes far longer than 12 cycles to arrive.

Limits measured by `tb_mac_table`: at most 8 cycles waiting for a lookup result and 11 waiting for a
learn grant. A result may lag the table by up to 12 cycles, which the test allows for explicitly.

### Inferred multiplier

`ln_mac[48*sel +: 48]` looks like a plain index, but on ECP5 Yosys mapped it to a `MULT18X18D`
costing 3.9 ns. Explicit `case` muxes removed it. Use a `case` for variable indexing by a width that
is not a power of two. Multiplying by a power of two is only a shift, so `8*owner[e]` is fine.

### Registered TX FIFO empty flag (`rtl/eth_mac.v`)

The flag came from a Gray-to-binary decode and a subtraction, then fed straight into the arbiter. It is
now a flip-flop. Simply delaying it would be unsafe, because the arbiter uses it to prove a port is
idle: a late flag could still say "empty" just after a write. So any write also clears it directly:

```verilog
tx_fifo_empty <= (tx_fill == 0) && !(tx_tvalid && tx_tready);
```

The flag can stay low a cycle too long, which only delays a grant, but it never reads high while the
writer's view of the FIFO holds data. `tb_mac_loop` now checks that rule on every clock, and that the
flag really does rise when idle.

### Ingress length check (`rtl/ingress_buf.v`)

`wcnt + 1 >= 14` widened to 32 bits because the literal `1` is 32 bits, which built a long carry chain.
`wcnt >= 13` gives the same answer for every value. Congestion-mode results stayed identical, as expected.

The GMII clocks moved in both directions after this change, though nothing in those domains changed
(for example, `gmii_rx_clk[0]` went from 125 to 104 MHz). Treat small differences between single-seed
runs as placement variation.

## Where the time goes now

Routing is about 75% of each path below. Reducing logic levels should also reduce routing, because
fewer long nets span the device.

| Clock | Slowest path | Delay | Logic / routing |
| --- | --- | --- | --- |
| `sys_clk` | `q_rd` -> `q_dst` read -> `mask` -> `req`/`gnt`/`start` -> `own_v` | 14.8 ns | 4.0 / 10.8 ns |
| `gmii_tx_clk[3]` | `u_tx.st` -> `s_tready` -> FIFO read pointer -> `rempty_next` | 10.6 ns | 3.0 / 7.6 ns |
| `gmii_rx_clk[0]` | `rx_rst_n` -> FIFO write pointer -> `wfull_next` | 9.6 ns | 2.7 / 6.9 ns |

The GMII paths shown are the slowest clock of each direction in this run. The worst path can differ by
port because placement differs.

## Next steps

In order:

1. **Register the grant decision** in `rtl/switch_core.v`, so `req` -> `gnt` -> `start` -> `own_v`
   is not one long path. Keep the shared round-robin pointer, because it is what prevents deadlock.
2. **Fix the GMII paths** in `rtl/eth_mac_tx.v` and `rtl/eth_mac_rx.v`, such as precomputing the
   `nbytes` comparison. The FIFO pointer paths need more care, see [Constraints](#constraints-on-this-work).
3. **Try more seeds** with `--seed` once the results are close. One seed says little about margin.

## Clock targets

- `sys_clk` cannot go below 125 MHz: each port moves one byte per clock at 125 MHz, and a slower
  system clock starves the TX path. `tb_mac_loop` shows the damage at 100 MHz (188 of 211 frames
  flagged bad, none silently corrupt).
- 125 MHz is the sensible target for ECP5 at speed grade 6. `tb_mac_loop` passes at 125 MHz, but the
  whole-switch tests (`tb_switch`, `tb_switch_smoke`) only run at 156.25 MHz. Add a 125 MHz run before
  relying on that target.
- If ECP5 at speed grade 6 cannot reach 125 MHz, the fallback is a faster speed grade or a different
  FPGA. The choice of board is still open.

## Constraints on this work

- `rtl/cdc/` is copied from the Asynchronous_FIFO repo, which holds its formal proofs. Change it
  there first and re-run the proofs, as `rtl/cdc/README.md` says.
- `syn/clocks.lpf` sets clock frequencies only. Paths between clock domains appear in the log as
  cross-domain reports, not as failures of these targets.
- No I/O timing is constrained yet. That needs a real board and its pin assignments.

## Tooling notes

- `ltp` in Yosys is not useful on a mapped netlist here: it follows paths through vendor flip-flops,
  and it reported false loops and a path 684 cells long.
- Fmax printed before routing is an estimate. Only trust the last set of `Max frequency` lines.
- `nextpnr-ecp5` only offers device flags such as `--um-45k` when that device's chip database is
  installed. Without it, the error is `unrecognised option`, which looks like a wrong flag.
- `--router router2` routes this design much faster than the default router.

## Test changes that came with this work

- `tb_ingress_buf` checks that a stalled output holds its value, that a frame has no internal gaps,
  and that `xfer` gets its first byte within 3 clocks.
- `tb_mac_table` is now a request/response test. It checks the `lk_valid` rules, and it holds some
  addresses for up to 300 cycles to prove results follow the table.
- `tb_switch_core` drives garbage on `lk_hit` and `lk_port` until `lk_valid` rises, with a random
  delay, to prove the core waits.

These bugs were injected by hand, once each, and are **not** part of `make bugs` yet:

| Injected bug | Test | Result |
| --- | --- | --- |
| Prefetch ignores FIFO room | `tb_ingress_buf` | caught |
| Prefetch allows only one byte at a time | `tb_ingress_buf` | caught |
| Space released on fetch, not delivery | `tb_ingress_buf` | caught |
| `tlast` one byte early | `tb_ingress_buf` | caught |
| `drop` does not advance `fetch_ptr` | `tb_ingress_buf` | caught |
| Result not cleared when `lk_en` falls | `tb_mac_table` | caught |
| Stage A lookup not discarded when `lk_en` falls | `tb_mac_table` | caught |
| Learns allowed to overlap in the pipeline | `tb_mac_table` | caught |
| Result never refreshed after the first answer (hit, then port) | `tb_mac_table` | caught, after strengthening the test |
| Core ignores `lk_valid` | `tb_switch_core` | caught |
| No `head_valid` gap after a pop | `tb_switch` | caught |
| TX empty flag not cleared by a write | `tb_mac_loop` | caught |
| TX empty flag never rises | `tb_mac_loop` | caught |
| RAM read on every cycle, not only on `rd_en` | `tb_ingress_buf` | passes: no behaviour change, since the extra value is never used |
