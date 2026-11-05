# Project guide: how this switch works, explained from the start

This guide explains the whole project without assuming you can read Verilog. Read it from the top once.
After that, use it as a reference while you look at the code.

For the short technical summary, see the [README](../README.md). For FPGA numbers, see the
[timing log](fpga_timing.md). For what comes next, see the [roadmap](roadmap.md).

## Contents

1. [What we are building](#1-what-we-are-building)
2. [What travels on the cable](#2-what-travels-on-the-cable)
3. [Hardware ideas you need](#3-hardware-ideas-you-need)
4. [The journey of one frame](#4-the-journey-of-one-frame)
5. [Every block in detail](#5-every-block-in-detail)
6. [How we know it works](#6-how-we-know-it-works)
7. [From code to a real chip](#7-from-code-to-a-real-chip)
8. [Where the project stands](#8-where-the-project-stands)
9. [How to explore it yourself](#9-how-to-explore-it-yourself)
10. [Test yourself](#10-test-yourself)
11. [Glossary](#11-glossary)

---

## 1. What we are building

An **Ethernet switch** is the box with several network sockets that connects computers on a local
network. A computer sends a message into one socket, and the switch works out which socket leads to
the recipient and sends it only there.

Think of a mailroom with four doors:

- Letters arrive at any door, each with a **to** and a **from** address.
- The clerk knows which door leads to each person.
- A letter's **from** address teaches the clerk where that person is, with no setup needed.
- If the clerk doesn't know the recipient yet, a copy goes out of every other door. The right person
  picks it up, and their reply teaches the clerk where they are.

That is what "learning switch" means, and "Layer 2" means it only looks at these local hardware
addresses, not internet addresses.

This project builds it as **digital hardware**, not software. No processor runs a program here. The
code describes circuits that all operate at once, which is why it looks and behaves so differently
from normal programming.

It has two main parts:

- **MAC (Media Access Controller):** one per port. It speaks the Ethernet rules: it formats frames for
  sending and checks frames it receives.
- **Switch logic:** decides where each frame goes and moves it there.

```
             +--------------------------------------------------+
  port 0 <-> | MAC <-> ingress buffer -+                        |
  port 1 <-> | MAC <-> ingress buffer -+-> switch core -> MACs  |
  port 2 <-> | MAC <-> ingress buffer -+        ^               |
  port 3 <-> | MAC <-> ingress buffer -+   MAC table            |
             +--------------------------------------------------+
```

One thing connects each MAC to the actual cable but isn't part of this project: the **PHY**, a separate
chip that converts between electrical signals on the cable and digital bytes.

---

## 2. What travels on the cable

Data moves in units called **frames**. This is one frame, in the order it is sent:

```
| Preamble | SFD | Destination | Source | Type | Payload     | FCS |   gap   |
| 7 bytes  |  1  |     6       |   6    |  2   | 46-1500     |  4  | 12+ idle|
| 0x55...  |0xD5 |<------------- 64 to 1518 bytes ---------------->|         |
```

| Field | What it is for |
| --- | --- |
| **Preamble** | Repeated `0x55` bytes that say "a frame is starting" |
| **SFD** (start frame delimiter) | `0xD5`: the real data starts on the next byte |
| **Destination** | The MAC address of the recipient |
| **Source** | The MAC address of the sender, which is what the switch learns from |
| **Type** | What the payload contains. This switch ignores it |
| **Payload** | The actual data. If it is short, the sender pads it with zeros |
| **FCS** (frame check sequence) | A 4-byte checksum, used to detect corruption |
| **Gap** | Silence between frames, at least 12 byte times |

**MAC addresses** are 6 bytes, such as `02:00:00:00:00:01`. The lowest bit of the first byte is special.
If it is 1, the frame is **multicast**, meaning it's for a group. The all-ones address
`FF:FF:FF:FF:FF:FF` is **broadcast**, meaning it's for everyone. In the code, this bit is `dst[40]`.

**Speed.** Gigabit Ethernet moves 1 byte every 8 ns, which is 125 million bytes per second. That's where
the number **125 MHz** comes from throughout the project. A full-size frame of 1,518 bytes takes about
12 microseconds to arrive.

**The checksum (CRC).** The sender runs all the frame's bytes through a fixed mathematical formula and
appends the result as the FCS. The receiver runs the same formula over everything, including the FCS.
A clean frame always ends on the same constant, `0xDEBB20E3`, so any other value means the frame was
damaged. A neat result is that the receiver doesn't need to know where the FCS begins.

---

## 3. Hardware ideas you need

**Clock.** A signal that ticks at a steady rate. Almost everything changes only on a tick. At 125 MHz, a
tick comes every 8 ns. A "cycle" or "clock" is one tick.

**Flip-flop.** A one-bit memory cell. On each tick it copies its input and holds it until the next tick.
Also called a register. A bigger number like a 48-bit address uses 48 of them.

**Combinational logic.** Gates that calculate an answer from their inputs continuously, such as "are
these two addresses equal?". The answer takes time to settle.

A digital circuit is mostly this pattern repeated:

```
flip-flop -> combinational logic -> flip-flop
```

**The timing rule.** This is the most important constraint in the project. The logic between two
flip-flops must settle before the next tick. If a path takes 17 ns and the clock ticks every 8 ns, the
second flip-flop captures a wrong answer. The slowest such path sets the top speed of the whole design,
called **Fmax**.

**Pipelining.** The fix for a slow path is to split it in two with flip-flops in the middle. Each piece
then fits in one tick. The answer arrives a few ticks later, but the circuit runs at a faster clock.
It's like an assembly line, where each station does a small job.

**Clock domains.** Parts of a design run on different clocks. Here, each port's receiver runs on a clock
from its PHY, and the switch logic runs on its own faster clock. Those clocks aren't in step. Passing
data between them safely needs special care, covered in [the clock crossing section](#clock-crossing-rtlcdc).

**Handshake (AXI4-Stream).** Blocks pass data using two signals: the sender raises `tvalid` for "I have
a byte", and the receiver raises `tready` for "I can take it". A byte moves on a tick where both are
high. Two more signals travel with it: `tlast` marks a frame's final byte, and `tuser` carries an
extra flag, used here to say "this frame is bad". There are two rules that bugs in this project have
broken before: once `tvalid` is up, it and the data must hold until taken, and `tvalid` must not wait
on `tready`.

**Back-pressure.** When a receiver lowers `tready`, the sender has to wait. This is how a slow part of
the design holds back a fast one. Note that a cable can't be held back: bytes keep arriving whether we
are ready or not.

**FIFO (first in, first out).** A queue. Bytes go in one end and come out the other in the same order.
It smooths out differences in timing between blocks.

**FPGA.** A chip full of small programmable logic blocks, flip-flops, memory and wiring. You can load a
circuit onto it without manufacturing a custom chip. Its main resources are:

- **LUT (look-up table):** a small programmable logic function.
- **Block RAM:** dedicated memory blocks. They're compact and fast, but they deliver data one tick
  after you ask for it. This caused a redesign, described in [the ingress buffer section](#ingress-buffer-rtlingress_bufv).
- **Routing:** the wires between blocks, which take real time. Most of this design's delay is routing.

**RTL and Verilog.** Verilog is the language used to describe circuits. "RTL" (register-transfer level)
means describing what moves between flip-flops on each tick. A key line to recognise is:

```verilog
always @(posedge clk) counter <= counter + 1;   // on every tick, the flip-flops load counter + 1
```

---

## 4. The journey of one frame

Follow a frame from a computer on port 0 to a computer on port 2.

**1. Bytes arrive.** The PHY delivers one byte every 8 ns. The receive MAC finds the preamble and SFD,
then strips them off.

**2. The frame is checked as it arrives.** The MAC feeds each byte through the CRC and counts the
length. The verdict is only known when the frame ends.

**3. It crosses clock domains.** Bytes pass through an asynchronous FIFO from the 125 MHz receive clock
to the 156.25 MHz system clock.

**4. It's stored.** The ingress buffer writes the bytes into its 4 KB memory. This design is
**store-and-forward**: it holds the complete frame before sending any of it, because only then does it
know whether the frame is good. A full-size frame therefore waits about 12 microseconds here.

**5. Keep or discard.** At the final byte, the buffer checks the verdict, the length and whether
everything fitted. If it fails, the write pointer moves back to the frame's start, and it's as if the
frame never existed. If it passes, the frame joins a queue of up to 8 frames.

**6. The switch learns the sender.** The buffer tells the MAC table: "this source address is on port 0".

**7. The destination is looked up.** Once this frame reaches the front of its queue, the table searches
for its destination, and the answer comes back within a few cycles.

**8. A decision is made.**

| Destination | Action |
| --- | --- |
| Broadcast or multicast | Send to every other port (flood) |
| Unknown | Flood |
| Known, on another port | Send to that port |
| Known, on the same port it came from | Discard (filter). That station already heard it |

**9. It waits for its output.** The frame can only start when its output port is idle. For a flood, it
needs every destination port free at once.

**10. It moves through the crossbar.** The core connects the buffer to the output, and the frame flows
one byte per tick into the transmit FIFO. A flood goes to three outputs in step.

**11. It crosses back.** The transmit FIFO carries bytes to the 125 MHz transmit clock.

**12. It goes out.** The transmit MAC sends the preamble and SFD, then the bytes, pads if needed, adds a
fresh FCS and observes the gap. The PHY puts it on the cable.

---

## 5. Every block in detail

### CRC (`rtl/crc32.vh`)

A function that updates the checksum with one byte. It's used by both the transmitter and the receiver.
It's a small piece of XOR logic. The test checks it against the published value for
`"123456789"`, `0xCBF43926`.

### Receive MAC (`rtl/eth_mac_rx.v`)

**Job:** turn the byte stream from the PHY into clean frames with a good or bad verdict.

**The problem it solves:** the FCS must not be passed on, but you only learn you've been reading the FCS
when the frame ends. So bytes travel through a 5-byte delay line. When the frame ends, the line holds
the last data byte plus the 4 FCS bytes, so the FCS is never sent onward.

**A frame is marked bad if:**

- the CRC doesn't match
- it's under 64 bytes (a "runt") or over 1,518 bytes
- the PHY flagged an error with `rx_er`
- bytes were lost because the next stage was full

It runs as a small state machine: idle, in preamble, in data, then finishing.

### Transmit MAC (`rtl/eth_mac_tx.v`)

**Job:** take frame bytes and put a correctly formed frame on the wire.

It's a state machine with six steps: idle, preamble, data, pad, FCS, gap.

- **Padding:** if the frame is under 60 bytes, zeros are added so it reaches 64 with the FCS.
- **Underrun:** if bytes stop arriving mid-frame, the wire can't wait, so it raises `tx_er`. The
  receiver then discards the frame rather than accept a damaged one. The switch is designed so this
  doesn't happen, and the tests treat it as an error.
- **The gap** is 13 byte times, one more than the minimum. This is allowed, but slightly wasteful.

### Clock crossing (`rtl/cdc/`)

**The problem.** If a signal changes just as a flip-flop in another clock domain samples it, that
flip-flop can get stuck between 0 and 1 for a moment. This is called **metastability**. Two defences
are used here.

**Two flip-flops in a row (`sync_2ff.v`).** The first may go metastable, but it almost always settles
before the second samples it. This makes failures vanishingly rare, not impossible.

**Gray code.** The FIFO must share its read and write positions across clocks. With a normal binary
counter, going from `0111` to `1000` changes four bits at once. If they're sampled mid-change, the
other side could read a position that's wildly wrong. In Gray code, only one bit changes per step. So
the worst case is reading the old position, which is safe: the FIFO merely looks slightly fuller or
emptier than it is, for a moment.

**Asynchronous FIFO (`async_fifo.v`).** This puts it together: memory that one clock writes and another
reads, plus the pointers. `wptr_full.v` runs the write side and `rptr_empty.v` runs the read side.
`fifo_mem.v` is the memory, `reset_sync.v` gives each clock domain a clean reset.

Each port has two FIFOs of 32 entries, one per direction. These files came from a separate
[Asynchronous_FIFO](https://github.com/Prajesh-47/Asynchronous_FIFO) project, which has its own formal
proofs. Change them in that repo first.

### MAC wrapper (`rtl/eth_mac.v`)

Connects the receive MAC, transmit MAC and both FIFOs into one port. It also tells the switch when the
transmit FIFO is empty, which is how the core knows the output is idle. That flag is stored in a
flip-flop for timing, and new data clears it straight away. So it can be a tick late saying "empty", but
it never says "empty" while data is on its way.

It also holds a **register slice** (`rtl/axis_skid.v`) just before the transmit FIFO. This is a pipeline stage
with a handshake: because `tready` now comes from a flip-flop, the sender learns about a stall one tick late,
so a spare register catches the one extra byte that can arrive.

### Ingress buffer (`rtl/ingress_buf.v`)

**Job:** hold frames until they are approved and their output is free. One per port.

**Write side.** Bytes go into a 4 KB memory, and `wr_ptr` tracks the position. `frm_start` remembers
where the current frame began, which is what makes the rewind possible. A frame is kept only if the MAC
said good, it's at least 14 bytes (a full header), all of it fit, and the queue has room. It never
applies back-pressure, because the cable can't be held back.

**The descriptor queue.** Each kept frame gets a small record: its length and destination. This is what
lets the switch see the next frame's destination without touching the memory. The queue holds 8, which
is sometimes the real limit: 4 KB could hold about 60 minimum-size frames, but only 8 get queued.

**Read side.** This part was redesigned for block RAM, which answers one tick after you ask:

```
memory -> RAM output register -> 4-entry prefetch FIFO -> out to the core
```

Without the small FIFO, a "not ready" signal from the output would have to reach the RAM's address
in the same tick, making a long timing path. With it, that signal stops at the FIFO.

Two details matter here:

- There are two pointers: `fetch_ptr` (what was read from memory) and `rd_ptr` (what was actually
  delivered). Space is freed by `rd_ptr`, so capacity behaves exactly as it did before.
- The first byte appears 3 ticks after the core says go. After that there are no gaps, so the transmit
  side doesn't run dry.

**`just_popped`.** After a frame leaves, `head_valid` goes low for one tick. It's a signal to the MAC
table that the front of the queue changed. See the next section for why it's needed.

### MAC table (`rtl/mac_table.v`)

**Job:** remember which port each address is on. It has 16 entries.

**The original design and its problem.** The first version compared all 16 stored addresses with four
lookups and one learn request in the same tick. That's a lot of logic and long wires, and it became the
slowest path in the design. It was also large, at about 9,200 LUTs on its own.

**The current design** has one set of comparators shared in turn, through three stages:

```
Stage S (select):  a waiting learn request goes first, otherwise the next port's lookup
Stage A (compare): compare that address with all 16 entries
Stage B (commit):  a lookup stores its result, a learn updates the table
```

**Why lookups repeat.** A frame might wait thousands of cycles for its output. Meanwhile, the destination
station could move to another port. Looking it up repeatedly keeps the answer current.

**Why there's a `lk_valid` signal.** The answer no longer arrives instantly, so the table raises
`lk_valid` to say "this result is ready, and it belongs to the current frame".

**The stale-result problem.** Suppose a lookup for frame A is still in the pipeline when frame A leaves
and frame B reaches the front. Without care, B would be forwarded using A's answer and go out of the
wrong port. That's why `just_popped` exists: when `head_valid` drops, the table clears the port's result
and throws away lookups in progress. The tests specifically check this, by breaking it on purpose.

**Learning.** Only one learn runs at a time, taking 3 ticks. If two were in the pipeline together, both
could miss the same new address and insert it twice. A known address gets its port updated, which is
how a station that moves gets found. A new address replaces the oldest entry.

**Known limits.** There's no aging, so a station that moves and stays silent stays unreachable until it
next transmits, and an active station can be evicted just for being oldest.

### Switch core (`rtl/switch_core.v`)

**Job:** decide where each frame goes, choose who goes next, and move the bytes.

**The destination mask.** For each input, it calculates a 4-bit mask of output ports from the table in
[step 8 of the journey](#4-the-journey-of-one-frame). An empty mask means filter the frame.

**Arbitration.** Outputs are shared, so when two frames want the same one, the core chooses. An output
is free when nobody owns it and its transmit FIFO is empty.

**Two steps, one tick each.** The mask and "I want to send" request are first stored in flip-flops, and
arbitration uses those stored values on the next tick. Pipelining like this has a catch: for one tick, a
stored value describes the recent past. Right after a frame starts, its stored request is still high. If
the table changed at that instant, the mask could name a different free port and the frame could start
twice. So the request is ignored once the input is `active`. A special test phase keeps changing table
answers while frames wait, specifically to exercise this.

**Deadlock, and how it's avoided.** A flood needs several outputs at once. Suppose input A holds port 2
and waits for port 3, while input B holds port 3 and waits for port 2. Both would wait forever. Here,
an input only starts when it has **every** port it needs, and all outputs share **one** round-robin
pointer. The top-priority input wins every free port it wants, so it eventually gets its full set. The
pointer then moves on, so nobody starves. There's a deliberate bug, `BUG_PER_EGRESS_PRIORITY`, that
removes this so you can watch the test catch it.

**The fork.** A flood streams one input to up to three outputs. Outputs can accept bytes at different
moments, so `done[e]` remembers which ones already took the current byte. The input moves on only when
all have. An output's `tvalid` drops only after its own handshake, keeping to the AXI rules. An earlier
version broke this, and the unit test found 146,408 violations.

**Why the transmit FIFO must be empty.** Every copy starts from an empty FIFO and drains at the same 125
MHz. So a lock-stepped flood can't starve one copy mid-frame. The cost is a small delay between frames.

**Head-of-line blocking.** Each input has one queue. If the front frame waits for a busy output, frames
behind it wait too, even if their outputs are idle. It's like a car waiting to turn right holding up
everyone behind it who's going straight. This is a large part of why 36-44% of copies are dropped at
100% load. Virtual output queues would fix it, and they're on the roadmap.

### Top level (`rtl/eth_switch_4port.v`)

This holds no logic of its own. It wires together four MACs, four ingress buffers, the table and the
core. The Verilog packs all ports into wide buses: `gmii_rxd` is 32 bits, with port `p` using 8 of them.
That's why you see `8*p +: 8`, which means "8 bits starting at position 8 times p". It's also why the
port count is currently fixed at 4.

---

## 6. How we know it works

Hardware bugs are expensive to find later, so testing is the largest part of this project. There's more
testbench code than design code.

**The main ideas:**

| Term | Meaning |
| --- | --- |
| **Testbench** | Code that simulates the circuit, feeds it inputs and checks its outputs |
| **Self-checking** | The test decides pass or fail by itself, and prints `RESULT: PASS` |
| **Reference model** | A separate, simple description of correct behaviour, written from the spec rather than the RTL |
| **Scoreboard** | Records what should come out, then compares it to what does |
| **Randomized testing** | Random traffic finds situations nobody thought to write by hand |
| **Coverage** | Proof the interesting cases really happened. Here, 24 bins, and a miss fails the test |
| **Liveness** | Checks that nothing waits forever |
| **Seed** | The starting number for the randomness. A different seed gives different traffic, and the same seed repeats it |

**The testbenches, smallest to largest:**

| Test | What it checks |
| --- | --- |
| `tb_crc32` | The checksum against a separate bit-by-bit version |
| `tb_mac_tx` | Preamble, padding, FCS, gap, underrun signalling |
| `tb_mac_rx` | Verdicts for good, bad CRC, runt, oversize, PHY error and lost data |
| `tb_mac_loop` | One MAC looped back through both FIFOs at 5 clock setups |
| `tb_ingress_buf` | Every keep or drop decision, a completely full buffer, no gaps in output |
| `tb_mac_table` | Results against a model, results that follow the table, no stale results, eviction order |
| `tb_switch_core` | Forwarding rules, AXI rules, waiting for lookups, deadlock |
| `tb_switch_smoke` | The whole switch through 10 hand-written steps |
| `tb_switch` | The whole switch under random traffic, 4 unrelated receive clocks, both light and full load |

**Why test at both levels?** Some bugs can't be seen from the outside. `BUG_FORK_GATED_VALID` breaks the
AXI rules but never causes wrong data in this switch, because all outputs back-pressure at the same
moment. Only the core's unit test, which back-pressures outputs separately, catches it. It could cause
real failures if the core were reused elsewhere.

**Injected bugs: testing the tests.** A passing test proves little if it couldn't have failed. So the
design contains 8 deliberate bugs, switched on at build time with `ifdef`. `make bugs` builds each one
and fails if its test doesn't catch it. During the MAC table work, a hand-injected bug revealed a real
hole in the new test: a port that never refreshed its result went unnoticed, because the test never held
an address long enough. The test was then strengthened.

**What simulation can't prove.** It checks the logic around the synchronizers, not metastability itself.
It also says nothing about whether the design is fast enough for a chip, which is the next section.

---

## 7. From code to a real chip

A simulation just computes behaviour. Getting onto an FPGA has more steps:

```
Verilog -> synthesis -> place and route -> timing report -> bitstream -> load onto FPGA
           (yosys)      (nextpnr)                           (not done yet)
```

- **Synthesis** turns the code into the FPGA's actual parts: LUTs, flip-flops, block RAMs.
- **Place and route** decides where each part goes on the chip and which wires connect them.
- **Timing report** gives the real delay of every path, and so the Fmax.

Our reference device is an ECP5-45, chosen because its open-source tools run on this machine. **No board is
planned for this project**, so these results are estimates of what the design could do on a chip, not proof
that it does.

**Why this exposed new problems.** A simulator doesn't care how big or slow a circuit is. Every test
passed, but the first attempt at synthesis didn't even finish:

| Step | What was wrong | Fix | Logic used | `sys_clk` |
| --- | --- | --- | --- | --- |
| 1 | Memories became 32,768 flip-flops per port, because of how the code was written | Write memory in its own block | 80% | about 20 MHz, estimate only, wouldn't finish routing |
| 2 | Memory was built from LUTs | Use block RAM, add a prefetch FIFO | 34% | 24.9 MHz |
| 3 | The MAC table did too much in one tick | Share comparators, three stages | 20% | 48.1 MHz |
| 4 | An index calculation became a hardware multiplier | Write explicit muxes | 19% | 56.6 MHz |
| 5 | The transmit FIFO's fill calculation ran straight into the arbiter | Store the "empty" flag in a flip-flop | 19% | 62.3 MHz |
| 6 | A length check accidentally used 32-bit arithmetic | Rewrite it without the addition | 19% | 67.3 MHz |
| 7 | One tick had to choose destinations and arbitrate | Split into two ticks | 19% | 70.4 MHz |
| 8 | A subtraction fed a signal driving 48 flip-flops | Compare pointers, send the request a tick later | 19% | 73.4 MHz |

Those rows all used the slowest speed grade. At the fastest grade, the same design reached 92-97 MHz, and:

| Step | What was wrong | Fix | Logic used | `sys_clk` |
| --- | --- | --- | --- | --- |
| 9 | One tick ran from an input buffer through the crossbar into a transmit FIFO | Add a register slice | 19% | 98-102 MHz |

**What these numbers mean.** About 100 MHz means a tick must last at least 10 ns. The minimum for `sys_clk`
is 125 MHz, which is 8 ns. It can't go lower, because each port moves one byte per tick and bytes arrive
at 125 MHz. So the slowest path must get about 25% faster.

**Why it takes several rounds.** Fixing the slowest path only reveals the next slowest. That's normal
for this work, and is why we fix, measure and repeat.

**Why one measurement isn't enough.** Placement starts from a random seed. Three seeds of the same design
gave 69-73 MHz, so a gain of 3 MHz might only be luck. The later rows in this table are less certain than
they look.

**Wires are now the main delay.** In the slowest paths, logic takes 1.4-3.1 ns and routing takes 8-10 ns.
That points away from the code's logic and towards how the design sits on the chip.

**The chip itself matters.** FPGAs of the same family come in speed grades. On identical code, the fastest
ECP5 grade reaches 92-97 MHz, against 69-73 MHz for the slowest. That's a bigger jump than the last several
code fixes together. No board is planned for this project, so the fastest grade will be the reference for reported numbers.

Full details are in the [timing log](fpga_timing.md).

---

## 8. Where the project stands

**Working and tested in simulation:**

- Complete MAC with CRC, padding and error detection
- Safe clock crossing
- Store-and-forward buffering, learning, flooding, filtering
- Deadlock-free arbitration and a correct fork

**In progress:**

- Meeting FPGA timing. It routes, but on the reference device `sys_clk` reaches about 100 MHz of a required 125 MHz

**Out of scope, because no FPGA board is available:**

- It has never run on hardware, and isn't planned to.
- There's no RGMII, which many boards use, and no MDIO, which is how a PHY is configured.
- There's no 10/100 support for slower link partners.

**Not done yet, and planned in simulation:**

- Throughput and latency have never been measured.
- Real network traffic hasn't been passed through the simulated switch.
- Key properties aren't formally proven yet.
- There's no aging, VLAN support, pause frames or loop protection.

The [roadmap](roadmap.md) sets out the order for all of this.

---

## 9. How to explore it yourself

**Read the code in this order.** Each file builds on the previous one:

1. `rtl/crc32.vh`: very short, and a gentle start
2. `rtl/eth_mac_tx.v`: a clean state machine, and the best first real module
3. `rtl/eth_mac_rx.v`: the same ideas, plus the delay line
4. `rtl/cdc/sync_2ff.v`, then `rtl/cdc/wptr_full.v`: clock crossing
5. `rtl/ingress_buf.v`: pointers, rewind, the prefetch FIFO
6. `rtl/mac_table.v`: the pipeline
7. `rtl/switch_core.v`: the hardest. Save it for last
8. `rtl/eth_switch_4port.v`: how it all connects

**Reading Verilog.** Five patterns cover most of this code:

| You see | It means |
| --- | --- |
| `always @(posedge clk ...)` with `<=` | Flip-flops: all update together on the tick |
| `always @(*)` with `=` | Combinational logic: recalculates continuously |
| `assign x = a && b;` | A wire driven by logic |
| `if (!rst_n)` at the top of a block | What the flip-flops do during reset |
| `` `ifdef BUG_... `` | A deliberate bug for testing, off in normal builds |

The hardest habit to unlearn is reading top to bottom like a program. Everything happens at once, and
`<=` assignments all use the values from before the tick.

**Run things:**

```bash
make smoke   # watch the 10 directed steps pass; the easiest one to follow
make rx      # one unit test
make sim     # the whole switch under random traffic
make bugs    # watch each injected bug get caught
make test    # most of the suite
make wave    # create build/switch.vcd
gtkwave build/switch.vcd   # look at the actual signals
```

**Look at the waveform.** The most useful learning step is to open `gtkwave`, and find the signals from
the [journey of a frame](#4-the-journey-of-one-frame): `gmii_rx_dv`, `head_valid`, `xfer`, `gmii_tx_en`.
`docs/waveform.svg` shows this for one broadcast.

**Try breaking something.** Change a line, such as the CRC constant, run its test and read the failure.
Then undo it with `git checkout -- <file>`.

---

## 10. Test yourself

<details><summary>Why does the switch wait for the whole frame before forwarding it?</summary>

The CRC verdict only exists after the last byte. Storing first means a damaged frame can be dropped
rather than forwarded. The cost is latency: about 12 microseconds for a full-size frame.
</details>

<details><summary>Why does an unknown destination get flooded instead of dropped?</summary>

The recipient may exist but hasn't transmitted yet, so the switch can't know its port. Flooding reaches
it, and its reply teaches the switch where it is.
</details>

<details><summary>Why is the system clock faster than the 125 MHz ports?</summary>

It gives margin, because each port moves a byte per tick. At 100 MHz, `tb_mac_loop` shows frames being
damaged, though always flagged. 125 MHz is the minimum, and 156.25 MHz is the current design target.
</details>

<details><summary>Why are FIFO pointers sent across clocks in Gray code?</summary>

Only one bit changes per step, so sampling it mid-change gives either the old or the new value. Both are
safe. With binary, several bits change at once and a wildly wrong value could be read.
</details>

<details><summary>What would go wrong without <code>just_popped</code>?</summary>

A lookup for the previous frame could finish after the next frame reached the front, so the new frame
would be sent using the wrong answer. Removing it made `tb_switch` fail.
</details>

<details><summary>How does the flood logic avoid deadlock?</summary>

An input starts only with all its ports, and all outputs share one priority pointer. The top-priority
input wins every free port it wants, so two inputs can't each hold what the other needs forever.
</details>

<details><summary>Why did block RAM need a prefetch FIFO?</summary>

Block RAM answers one tick after being asked. The small FIFO supplies bytes without gaps and stops
`tready` from reaching the RAM address, which would be a long timing path.
</details>

<details><summary>All tests pass, so why couldn't this run on a chip yet?</summary>

Simulation ignores real delays. The slowest path takes about 10 ns, but the clock needs a tick every 8 ns.
It also lacks the RGMII and MDIO support that real boards generally need, though those are out of scope because no board is planned.
</details>

---

## 11. Glossary

| Term | Meaning |
| --- | --- |
| **Arbiter** | Logic that chooses one of several requesters |
| **AXI4-Stream** | The `tvalid`/`tready` handshake used between blocks |
| **Back-pressure** | A receiver lowering `tready` to make a sender wait |
| **Block RAM** | A dedicated FPGA memory block, with a registered read |
| **Broadcast** | A frame for everyone, sent to `FF:FF:FF:FF:FF:FF` |
| **CDC** | Clock domain crossing: moving a signal between unrelated clocks |
| **Combinational** | Logic with no memory, whose output follows its inputs |
| **Crossbar** | Connects any input to any output |
| **CRC / FCS** | The checksum, and the frame field that carries it |
| **Egress / ingress** | Going out of / coming into the switch |
| **Eviction** | Removing a table entry to make room |
| **Flood** | Sending a frame out of every port except the one it came in on |
| **Fmax** | The fastest clock a design can run at |
| **Fork** | One input streaming to several outputs in step |
| **Frame** | One unit of Ethernet data |
| **GMII** | The 8-bit, 125 MHz interface between MAC and PHY |
| **Gray code** | Counting where only one bit changes per step |
| **Head-of-line blocking** | A waiting frame holding up those behind it |
| **IFG** | Inter-frame gap: the silence between frames |
| **LUT** | Look-up table: a small programmable logic function |
| **MAC** | Media access controller, or the address it uses |
| **MDIO** | The management bus used to configure a PHY |
| **Metastability** | A flip-flop briefly stuck between 0 and 1 |
| **Multicast** | A frame for a group of stations |
| **PHY** | The chip connecting a MAC to the cable |
| **Pipeline** | Splitting work across several ticks with flip-flops |
| **Place and route** | Choosing where the circuit sits on the chip, and its wiring |
| **RGMII** | A version of GMII with fewer pins, common on boards |
| **Round-robin** | Taking turns fairly |
| **RTL** | Register-transfer level: how hardware code describes a circuit |
| **Runt** | A frame shorter than the 64-byte minimum |
| **Store-and-forward** | Holding a complete frame before sending it |
| **Synthesis** | Converting code into FPGA parts |
| **Underrun** | The transmitter running out of bytes mid-frame |
| **Unicast** | A frame for one station |
| **VLAN** | Dividing one network into separate virtual ones |
