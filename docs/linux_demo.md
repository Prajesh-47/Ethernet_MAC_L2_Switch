# Real Linux traffic through the switch

`make demo` connects the switch RTL, running in Verilator, to four Linux network namespaces. Each namespace is a
separate host with its own network stack. Real `ping` and TCP traffic then goes through the actual RTL, which learns,
floods and forwards it. It needs no sudo and no board, and takes about 5 seconds.

```
ns0: 10.0.0.1 <-> tap0 <-> | GMII port 0                |
ns1: 10.0.0.2 <-> tap1 <-> | GMII port 1   switch RTL   |
ns2: 10.0.0.3 <-> tap2 <-> | GMII port 2   in Verilator |
ns3: 10.0.0.4 <-> tap3 <-> | GMII port 3                |
```

## What it shows

From one run:

```
== ns0 ping 10.0.0.2
   64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=5.71 ms
   3 packets transmitted, 3 received, 0% packet loss, time 1042ms
== TCP: ns1 sends 256 KB to ns2, which returns its SHA-256
   256 KB in 0.5 s (4227 kb/s), SHA-256 matches
== capture check
  first frames (the switch learns from the first exchange, then stops flooding):
    ARP  02:00:00:00:00:01 -> ff:ff:ff:ff:ff:ff  port 0 -> flood   out [1, 2, 3]
    ARP  02:00:00:00:00:02 -> 02:00:00:00:00:01  port 1 -> forward out [0]
    IPv4 02:00:00:00:00:01 -> 02:00:00:00:00:02  port 0 -> forward out [1]
    IPv4 02:00:00:00:00:02 -> 02:00:00:00:00:01  port 1 -> forward out [0]
  frames in 354: flooded 4, forwarded to one port 350, filtered 0
  copies out 362, all matched to an expected copy: yes
  latency, 60-128 B frames (186): median 792 ns, first byte in to first byte out
  latency, 1400-1514 B frames (181): median 12384 ns, first byte in to first byte out
RESULT: PASS (real Linux traffic through the switch RTL)
```

- **Learning, as it happens.** The first ARP request is a broadcast, so it floods to every other port. The switch
  learns host 1's port from it. The reply goes back to port 0 alone, because host 1 is known by then. Every later
  frame goes to one port only.
- **Every frame checked.** `demo/check_capture.py` replays every frame Linux sent through a reference learning switch,
  and requires the RTL's outputs to match exactly: each copy on the right port, unchanged, and nothing anywhere else.
- **Latency agrees with the [performance measurements](performance.md).** For a 64-byte frame, 792 ns is 576 ns to
  receive it plus the 170 ns measured by `tb_perf`, plus up to half a clock of sampling in the harness. For a full-size
  frame, it's 12.2 µs to receive plus the same.

## Why the capture check matters

A run with the table's learning switched off (`BUG_NO_LEARN`) still passes every `ping` and the TCP transfer. Flooding
delivers every frame, just to every port, and TCP quietly resends the frames that are lost when the extra copies fill
the buffers. Working Linux traffic alone doesn't prove that the switch learns. On that run, the capture check fails with
about 665 errors (it varies a little between runs), starting with the first frame that should have gone to one port.

To repeat it:

```bash
verilator --cc --exe --build -O3 -Irtl +define+BUG_NO_LEARN rtl/cdc/*.v rtl/eth_mac*.v rtl/axis_skid.v \
  rtl/ingress_buf.v rtl/mac_table.v rtl/switch_core.v rtl/eth_switch_4port.v $PWD/demo/tap_switch.cpp \
  --top-module eth_switch_4port -o tap_switch --Mdir build/obj_demo_nolearn
SIM=build/obj_demo_nolearn/tap_switch demo/run_demo.sh
```

## How it works

| File | Role |
| --- | --- |
| `demo/tap_switch.cpp` | Verilator harness: the RTL, its clocks, and a GMII driver and monitor per port, bridged to a TAP device |
| `demo/run_demo.sh` | Creates the namespaces and hosts, runs the traffic, then the check |
| `demo/tcp_check.py` | A TCP transfer whose SHA-256 is compared end to end |
| `demo/check_capture.py` | The reference learning switch that every frame is checked against |

**No sudo.** The script re-runs itself in a user namespace, where it is root over its own network namespaces only.
The harness opens `tap0` to `tap3` there. Each host is a network namespace held open by a `sleep`, and its TAP device is
then moved into it. The harness's open file stays attached to the device across the move. That is what lets one process
serve four hosts that can't otherwise see each other.

**Into the switch.** A frame read from a TAP device has no FCS and may be under 60 bytes, such as a 42-byte ARP. The
harness pads it to 60 bytes and adds the FCS, as a real network card would. It then drives the frame on GMII with the
preamble, SFD and a 12-byte gap.

**Out of the switch.** Each burst on GMII tx is checked for the preamble, SFD and FCS, and for `tx_er`. The FCS is then
removed, and the frame is written to the TAP device. A bad frame is reported and not passed on.

**Clocks.** All four GMII clocks and the system clock run at their real frequencies, 125 MHz and 156.25 MHz. The
harness drives them directly, without Verilator's timing mode.

**Pausing.** Simulated time only moves while there's work, and for 200 µs after the last activity, which is enough for
any frame still in the switch to come out. The design has no timers, so pausing changes nothing, and an idle network
costs no CPU.

## Outputs

In `build/demo/`:

| File | Contents |
| --- | --- |
| `port0.pcap` to `port3.pcap` | Every frame on that port, both directions, for Wireshark. Timestamps are simulated time, in nanoseconds |
| `frames.csv` | One line per frame per port: time, direction, length, addresses, EtherType and a hash of the bytes |
| `switch.log` | The harness's summary: frames per port, floods, drops, and simulation speed |

`tcpdump` isn't needed. The harness writes the captures itself.

## Limits

- **About 220× slower than real time.** 4.4 ms of simulated traffic takes about 1 s. Ping times of 2-8 ms and TCP at a
  few Mb/s measure the simulation, not the switch. Throughput figures come from [performance.md](performance.md).
- **Simulated time in captures stops while idle,** so gaps between exchanges are shorter than they were in real time.
  Times within an exchange are exact.
- **One host per port, IPv4 only.** IPv6 is switched off in each host, so the captures hold only the demo's traffic.
  With it on, the multicast frames that IPv6 sends at start-up would flood, which also works.
- **No contention.** No two hosts send to the same port at once, so a correct switch drops nothing, and the check treats
  any missing copy as an error. Congestion is tested by `make congest` and `make perf`.
- **Ideal clocks.** All GMII clocks are in phase and exactly 125 MHz. `tb_switch` covers independent receive clocks.
- **Linux only.** It needs TAP devices, user namespaces and `/dev/net/tun`. Some systems restrict unprivileged user
  namespaces. Ubuntu 24.04 does by default, through AppArmor, which is why this isn't in CI yet.
