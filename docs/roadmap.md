# Roadmap

Where this project goes next, in order. **No FPGA board is available, so everything here must be possible
without physical hardware.** The aim is a switch design with published measurements, stronger proof of
correctness, and a demonstration using real network traffic in simulation. Each phase lists what "done" means.

| Phase | Goal | Status |
| --- | --- | --- |
| 1 | Bring FPGA timing as close to the target as two more fixes allow | **in progress**: `sys_clk` 98-102 MHz at speed grade 8, target 125 MHz |
| 2 | Measure throughput and latency | not started |
| 3 | Pass real Linux traffic through the simulated switch | not started, virtual network devices checked |
| 4 | Prove key properties with formal verification | not started |
| 5 | Add features, tested in simulation | not started |

## What having no board changes

**Dropped.** These can't be tested or demonstrated without hardware, so they aren't planned:

- board bring-up
- pin assignments and I/O timing constraints
- RGMII and MDIO
- 10/100 Mbit support for real link partners

**What FPGA results now mean.** Place-and-route is still useful evidence that the design is realistic, but
it no longer leads to a real device. Results should always say "post-route estimate on a reference device",
never "runs on an FPGA".

**What this project can't claim.** The design has never run on hardware. Simulation doesn't prove real PHY
behaviour, signal timing at the pins, or metastability behaviour.

## Phase 1: finish timing, with a limit

**Reference device: ECP5-45 at speed grade 8**, since no specific chip needs to be supported. Its
open-source tools run locally and in CI. `make pnr` now uses it by default, with three seeds, and the
register slice before each TX FIFO is done.

1. Look at the reset network.
2. Add a whole-switch test at the chosen system clock, because those tests only run at 156.25 MHz today.
3. Add `make synth` to CI, and `make pnr` if run time allows.

**Limit.** Stop after the reset work, even if `sys_clk` is short of 125 MHz. Without a real
chip, more timing work has rapidly falling value. Record the final result and the remaining gap plainly.

Done when the reset work is measured across seeds and the README states the final area, Fmax and any gap.
Details are in [fpga_timing.md](fpga_timing.md).

## Phase 2: measure performance

The README covers correctness and drops, but not how fast the switch is. Simulation measures this well,
because it counts exact clock cycles.

- Sweep offered load and frame size, and record throughput and latency per port.
- Publish the curves. Expect two visible effects: head-of-line blocking and the 13-byte transmit gap.
- Add a pass/fail threshold, so a later change cannot quietly lose throughput.

Done when a `make` target produces the data and the README shows the curves.

## Phase 3: real traffic through the simulated switch

This replaces the board demonstration. A Verilator harness connects each simulated port to a Linux virtual
network device (TAP), with each one inside its own network namespace:

```
ns0: ping / iperf3 <-> tap0 <-> | GMII port 0                 |
ns1: ping / iperf3 <-> tap1 <-> | GMII port 1   switch RTL    |
ns2: ping / iperf3 <-> tap2 <-> | GMII port 2   in Verilator  |
ns3: ping / iperf3 <-> tap3 <-> | GMII port 3                 |
```

Real Linux network stacks would then generate ARP, ping and TCP traffic, and the actual RTL would learn,
flood and forward it. Captures can be opened in Wireshark.

- **Checked so far:** on this machine, creating TAP and veth devices works in a user and network
  namespace, without sudo. The harness itself isn't built.
- **Expected limit:** simulation runs far slower than real time, and this speed hasn't been measured. It
  will show correct behaviour, but not gigabit speed. Throughput numbers must come from phase 2.
- **Possible problem:** slow simulation could trigger TCP timeouts, so `ping` and ARP are the first goal.
- **Tools needed:** `tcpdump` or `tshark`, and `iperf3`. All are available through `apt`.

Done when `ping` works between namespaces through the RTL, a capture shows learning and then unicast
forwarding, and a single `make` target runs the demonstration.

## Phase 4: formal verification

Simulation only checks the cases it happens to run. Formal tools prove a property for all cases. The async
FIFO already has such proofs in its own repo, so this extends the same approach.

Candidate properties:

- **Arbiter:** no deadlock, no starvation, and an output port never has two owners.
- **Fork:** AXI-Stream rules hold on every output, and each copy gets each byte once.
- **Ingress buffer:** pointers stay in range, and a dropped frame leaves no trace.
- **MAC table:** an address never appears twice, and a stale lookup never reaches `lk_valid`.

`yosys-smtbmc` is installed, and solvers such as `z3` are available through `apt`.

Done when `make formal` proves these, the results are in CI, and the README lists what is proven and how deep.

## Phase 5: add features

All of these can be fully tested in simulation. Start with those that show up in the phase 2 curves.

| Feature | Benefit |
| --- | --- |
| Virtual output queues | Removes head-of-line blocking, the main cause of drops at full load |
| Table aging | A station that moves and stays silent is no longer unreachable |
| Hash-based table in block RAM | Thousands of entries, not 16 (the shared lookup is already the right shape) |
| More descriptors | Each port holds only 8 queued frames, though 4 KB fits about 60 minimum-size frames |
| Readable counters | Statistics are only pulses today, with no register interface |
| `NUM_PORTS` parameter | Widths like `[191:0]` fix the design at 4 ports |
| VLANs (802.1Q) | Needed for most real networks |
| Pause frames (802.3x) | Flow control instead of drops |
| Loop detection or spanning tree | A cable loop currently causes a broadcast storm |
| Jumbo frames | Frames over 1518 bytes are dropped today |

## Optional: ASIC flow

An open-source ASIC flow could produce a chip layout with area, timing and power estimates, and no hardware
is needed. It looks possible, with memory as the main work, but it hasn't been run. It needs Docker or Nix
installed, and starts with a small trial. See the [assessment](asic_assessment.md).

## Smaller follow-ups

- Move the hand-injected bugs listed in [fpga_timing.md](fpga_timing.md#test-changes-that-came-with-this-work)
  into `make bugs` and the README table, so they keep being checked.
- Reduce the transmit gap from 13 to 12 byte times.
- Add a station-move scenario to `tb_switch`, which cannot currently catch `BUG_NO_MOVE`.
