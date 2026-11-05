# Roadmap

Where this project goes next, in order. The aim is to turn a well-verified simulation into a switch
that passes real traffic, with published measurements. Each phase lists what "done" means.

| Phase | Goal | Status |
| --- | --- | --- |
| 1 | Meet timing on an FPGA | **in progress**: `sys_clk` 56.6 MHz, needs at least 125 MHz |
| 2 | Measure throughput and latency | not started |
| 3 | Make it connectable to real hardware | not started |
| 4 | Pass real traffic on a board | not started, needs a board |
| 5 | Add depth | not started |

## Open decision: which board?

This decides the PHY interface, the toolchain and how many ports can be demonstrated, and it affects
phases 1, 3 and 4. Timing work currently targets a 45k ECP5 because its open-source tools run locally
and could run in CI. Choosing a board may change that target.

## Phase 1: meet timing

Detailed steps and history are in [fpga_timing.md](fpga_timing.md).

Done when:
- every clock meets its target on the chosen device across several seeds
- the whole-switch tests also run at the chosen system clock
- `make synth` runs in CI, and `make pnr` if run time allows
- the README states the final area and Fmax

## Phase 2: measure performance

The README covers correctness and drops, but not how fast the switch is.

- Sweep offered load and frame size, and record throughput and latency per port.
- Publish the curves. Expect two visible effects: head-of-line blocking and the 13-byte transmit gap.
- Add a pass/fail threshold, so a later change cannot quietly lose throughput.

Done when a `make` target produces the data and the README shows the curves.

## Phase 3: connect to real hardware

| Gap | Why it matters |
| --- | --- |
| RGMII | Many boards use it, and the MAC only speaks GMII |
| MDIO | Needed to configure and read the PHY |
| 10/100 Mbit | Only gigabit works, so a slower link partner cannot connect |
| `NUM_PORTS` parameter | Widths like `[191:0]` fix the design at 4 ports, and many boards have fewer |
| Readable counters | Statistics are only pulses today, with no register interface |

Done when the design builds for the chosen board with pin and I/O timing constraints.

## Phase 4: board bring-up

- Pass traffic between two PCs, and measure it with `iperf3`.
- Capture it in Wireshark, and confirm learning, flooding and filtering.
- Compare measured throughput with phase 2.
- Record a short demo.

Done when the README has real measurements and the demo.

## Phase 5: add depth

Pick based on what the project is for: design roles favour virtual output queues, verification roles
favour formal proofs, and a usable device favours VLANs and loop protection.

| Feature | Benefit |
| --- | --- |
| Virtual output queues | Removes head-of-line blocking, the main cause of drops at full load |
| Table aging | A station that moves and stays silent is no longer unreachable |
| Hash-based table in block RAM | Thousands of entries, not 16 (the shared lookup is already the right shape) |
| More descriptors | Each port holds only 8 queued frames, though 4 KB fits about 60 minimum-size frames |
| VLANs (802.1Q) | Needed for most real networks |
| Pause frames (802.3x) | Flow control instead of drops |
| Spanning tree or loop detection | A cable loop currently causes a broadcast storm |
| Jumbo frames | Frames over 1518 bytes are dropped today |
| Formal proofs of the arbiter and fork | Stronger evidence than simulation for deadlock and AXI rules |

## Smaller follow-ups

- Move the hand-injected bugs listed in [fpga_timing.md](fpga_timing.md#test-changes-that-came-with-this-work)
  into `make bugs` and the README table, so they keep being checked.
- Reduce the transmit gap from 13 to 12 byte times.
- Add a station-move scenario to `tb_switch`, which cannot currently catch `BUG_NO_MOVE`.
