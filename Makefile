# Ethernet_MAC_L2_Switch -- grows one milestone at a time
#   make crc     milestone 1: CRC-32 unit test
#   make tx      milestone 2: transmit MAC unit test
#   make rx      milestone 3: receive MAC unit test
#   make loop    milestone 4: full MAC (TX + RX + async FIFOs) in loopback
#   make ingress milestone 5: ingress (store-and-forward) buffer unit test
#   make table   milestone 5: MAC learning table unit test
#   make core    milestone 6: switch core (forwarding, arbitration, fork) unit test
#   make smoke   milestone 6: whole 4-port switch, 10 directed steps over GMII
#   make sim     milestone 7: whole switch, randomized, 4 independent rx clocks, 3 seeds
#   make congest milestone 8: whole switch at 100% load (drops allowed), 3 seeds
#   make sim125  whole switch at the minimum 125 MHz system clock: smoke, then both loads
#   make sysbugs milestone 8: every injected bug through the whole-switch test
#   make all     test + congest + sysbugs + mutants (~12 min)
#   make bugs    rebuild with each injected bug; fails if any test still passes
#   make mutants 28 more bugs as text edits on a copy of the RTL; fails if any is missed
#   make test    every test so far
#   make perf    throughput and latency sweep, writes docs/perf/ (a few minutes)
#   make perfcheck  fixed points against limits, fails if the switch gets slower
#   make demo    real Linux traffic (ping, TCP) through the switch RTL, no sudo (Linux only)
#   make lint    Verilator -Wall on the whole switch
#   make synth   FPGA synthesis (yosys), make pnr adds place-and-route (nextpnr-ecp5)
#   make wave    smoke test with a VCD (build/switch.vcd) + docs/waveform.svg
# Recipe lines start with '>' instead of a TAB (easier to copy-paste).
.RECIPEPREFIX := >
CDC    := rtl/cdc/reset_sync.v rtl/cdc/sync_2ff.v rtl/cdc/fifo_mem.v rtl/cdc/wptr_full.v rtl/cdc/rptr_empty.v rtl/cdc/async_fifo.v
MAC    := rtl/eth_mac_tx.v rtl/eth_mac_rx.v rtl/axis_skid.v rtl/eth_mac.v
SW     := rtl/ingress_buf.v rtl/mac_table.v rtl/switch_core.v rtl/eth_switch_4port.v
VFLAGS := --binary --timing -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Irtl -j 4

# run a unit-test binary: show its output, and FAIL the make target unless it
# printed "RESULT: PASS" (a plain "sim | grep" would always exit 0, so a failing
# test would look green in CI)
run = ./build/obj_$(1)/sim > build/$(1).log; grep -v finish build/$(1).log; grep -q "RESULT: PASS" build/$(1).log

.PHONY: lint wave crc tx rx loop ingress table core smoke sim congest bugs sysbugs mutants sim125 demo_build demo perf_build perf perfcheck test all clean synth pnr
# UNUSED* off: the FIFO keeps its binary pointers and fill level for debug, and
# the switch top does not use the ingress descriptor's length; nothing else is waived
lint:
> verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Irtl $(CDC) $(MAC) $(SW) --top-module eth_switch_4port
> @echo "RESULT: PASS (lint clean)"

crc:
> @mkdir -p build
> verilator $(VFLAGS) --Mdir build/obj_crc tb/tb_crc32.sv --top-module tb_crc32 -o sim > build/build_crc.log
> @$(call run,crc)

tx:
> @mkdir -p build
> verilator $(VFLAGS) --Mdir build/obj_tx rtl/eth_mac_tx.v tb/tb_mac_tx.sv --top-module tb_mac_tx -o sim > build/build_tx.log
> @$(call run,tx)

rx:
> @mkdir -p build
> verilator $(VFLAGS) --Mdir build/obj_rx rtl/eth_mac_rx.v tb/tb_mac_rx.sv --top-module tb_mac_rx -o sim > build/build_rx.log
> @$(call run,rx)

loop:
> @mkdir -p build
> verilator $(VFLAGS) -Wno-PINCONNECTEMPTY --Mdir build/obj_loop $(CDC) $(MAC) tb/tb_mac_loop.sv --top-module tb_mac_loop -o sim > build/build_loop.log
> @for cfg in "+SYS_MHZ=156.25" "+SYS_MHZ=125 +GMII_MHZ=125" "+SYS_MHZ=125.0125" "+SYS_MHZ=250" "+SYS_MHZ=100 +SLOW"; do \
>   out=$$(./build/obj_loop/sim +verilator+error+limit+1000 $$cfg); \
>   echo "$$out" | grep -E "^clocks|^loopback|ERROR"; echo "$$out" | grep -q "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }; \
> done; echo "RESULT: PASS (5 clock configurations)"

ingress:
> @mkdir -p build
> verilator $(VFLAGS) --Mdir build/obj_ingress rtl/ingress_buf.v tb/tb_ingress_buf.sv --top-module tb_ingress_buf -o sim > build/build_ingress.log
> @$(call run,ingress)

table:
> @mkdir -p build
> verilator $(VFLAGS) --Mdir build/obj_table rtl/mac_table.v tb/tb_mac_table.sv --top-module tb_mac_table -o sim > build/build_table.log
> @$(call run,table)

core:
> @mkdir -p build
> verilator $(VFLAGS) --Mdir build/obj_core rtl/switch_core.v tb/tb_switch_core.sv --top-module tb_switch_core -o sim > build/build_core.log
> @$(call run,core)

smoke:
> @mkdir -p build
> verilator $(VFLAGS) -Wno-PINCONNECTEMPTY --Mdir build/obj_smoke $(CDC) $(MAC) $(SW) tb/tb_switch_smoke.sv --top-module tb_switch_smoke -o sim > build/build_smoke.log
> @$(call run,smoke)

# no-drop mode (20% load): every expected copy must arrive. The first seed prints
# the full coverage table, the others one summary line each.
SEEDS := 1 2 3
sim:
> @mkdir -p build
> verilator $(VFLAGS) -Wno-PINCONNECTEMPTY --Mdir build/obj_sim $(CDC) $(MAC) $(SW) tb/tb_switch.sv --top-module tb_switch -o sim > build/build_sim.log
> @first=1; for s in $(SEEDS); do \
>   out=$$(./build/obj_sim/sim +N=300 +LOAD=20 +verilator+seed+$$s); \
>   if [ $$first = 1 ]; then echo "$$out" | grep -v finish; first=0; \
>   else echo "seed $$s: $$(echo "$$out" | grep -E '^coverage|^delivered|^RESULT' | tr '\n' ' ')"; fi; \
>   echo "$$out" | grep -q "RESULT: PASS" || { echo "RESULT: FAIL (seed $$s)"; exit 1; }; \
> done; echo "RESULT: PASS ($(words $(SEEDS)) seeds)"

# congestion mode (100% load): drops allowed; what arrives must be intact and
# in order, no ingress may starve, at least 25% must get through
congest:
> @mkdir -p build
> verilator $(VFLAGS) -Wno-PINCONNECTEMPTY --Mdir build/obj_sim $(CDC) $(MAC) $(SW) tb/tb_switch.sv --top-module tb_switch -o sim > build/build_sim.log
> @for s in $(SEEDS); do \
>   out=$$(./build/obj_sim/sim +N=300 +LOAD=100 +verilator+seed+$$s); \
>   echo "seed $$s: $$(echo "$$out" | grep -E '^delivered|^longest' | tr '\n' ' ')"; \
>   echo "$$out" | grep -q "RESULT: PASS" || { echo "$$out" | grep ERROR | head -5; echo "RESULT: FAIL (seed $$s)"; exit 1; }; \
> done; echo "RESULT: PASS ($(words $(SEEDS)) seeds at 100% load)"

# The system clock's minimum: each port moves one byte per clock at 125 MHz, so
# there is no margin here. Same rules as sim and congest.
sim125: smoke
> @out=$$(./build/obj_smoke/sim +SYS_MHZ=125); echo "smoke at 125 MHz: $$(echo "$$out" | grep -E '^RESULT')"; echo "$$out" | grep -q "RESULT: PASS" || { echo "$$out" | grep -E 'ERROR|FAIL' | head -5; exit 1; }
> verilator $(VFLAGS) -Wno-PINCONNECTEMPTY --Mdir build/obj_sim $(CDC) $(MAC) $(SW) tb/tb_switch.sv --top-module tb_switch -o sim > build/build_sim.log
> @for L in 20 100; do for s in $(SEEDS); do \
>   out=$$(./build/obj_sim/sim +N=300 +LOAD=$$L +SYS_MHZ=125 +verilator+seed+$$s); \
>   echo "load $$L% seed $$s: $$(echo "$$out" | grep -E '^delivered|^longest|^coverage' | tr '\n' ' ')"; \
>   echo "$$out" | grep -q "RESULT: PASS" || { echo "$$out" | grep ERROR | head -5; echo "RESULT: FAIL (load $$L%, seed $$s)"; exit 1; }; \
> done; done; echo "RESULT: PASS (whole switch at 125 MHz, 2 loads, $(words $(SEEDS)) seeds)"

# tb_perf, shared by the performance targets
perf_build:
> @mkdir -p build
> verilator $(VFLAGS) -Wno-PINCONNECTEMPTY --Mdir build/obj_perf $(CDC) $(MAC) $(SW) tb/tb_perf.sv --top-module tb_perf -o sim > build/build_perf.log

# full sweep (a few minutes): docs/perf/results.csv and the charts in docs/perf/
perf: perf_build
> python3 docs/perf_sweep.py
> python3 docs/gen_perf_charts.py

# a few fixed points against limits, so a change can't quietly lose throughput
perfcheck: perf_build
> @python3 docs/perf_check.py

# The RTL bridged to 4 TAP devices, one per network namespace (demo/run_demo.sh).
# Plain C++ harness, no --timing: it drives the clocks itself.
demo_build:
> @mkdir -p build
> verilator --cc --exe --build -O3 -j 4 -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Irtl $(CDC) $(MAC) $(SW) $(CURDIR)/demo/tap_switch.cpp --top-module eth_switch_4port -o tap_switch --Mdir build/obj_demo > build/build_demo.log

demo: demo_build
> @demo/run_demo.sh

wave:
> @mkdir -p build
> verilator $(VFLAGS) -Wno-PINCONNECTEMPTY --trace --Mdir build/obj_wave $(CDC) $(MAC) $(SW) tb/tb_switch_smoke.sv --top-module tb_switch_smoke -o sim > build/build_wave.log
> ./build/obj_wave/sim +vcd | grep -E "step  1|RESULT"
> python3 docs/gen_waveform.py build/switch.vcd docs/waveform.svg
> @echo "open with: gtkwave build/switch.vcd"

# each entry: <define>:<rtl file>:<testbench top>
BUGS := BUG_NO_REWIND:rtl/ingress_buf.v:tb_ingress_buf BUG_NO_MOVE:rtl/mac_table.v:tb_mac_table \
        BUG_NO_LEARN:rtl/mac_table.v:tb_mac_table BUG_RX_NO_CRC:rtl/eth_mac_rx.v:tb_mac_rx \
        BUG_PER_EGRESS_PRIORITY:rtl/switch_core.v:tb_switch_core BUG_FORK_ANY_READY:rtl/switch_core.v:tb_switch_core \
        BUG_FORK_GATED_VALID:rtl/switch_core.v:tb_switch_core BUG_NO_FILTER:rtl/switch_core.v:tb_switch_core
bugs:
> @mkdir -p build
> @for b in $(BUGS); do \
>   def=$${b%%:*}; rest=$${b#*:}; src=$${rest%%:*}; top=$${rest#*:}; \
>   verilator $(VFLAGS) +define+$$def --Mdir build/obj_$$def $$src tb/$$top.sv --top-module $$top -o sim > build/build_$$def.log || { echo "$$def: BUILD FAILED"; exit 1; }; \
>   if ./build/obj_$$def/sim | grep -q "RESULT: PASS"; then echo "$$def: NOT caught"; exit 1; else echo "$$def: caught"; fi; \
> done; echo "RESULT: PASS (every injected bug caught)"

# Every bug through the WHOLE-switch test, at 20% and 100% load. One bug is
# EXPECTED to slip past it -- the README explains why -- and is caught by a unit
# test instead. The target fails if any other bug is missed, or if that one is
# suddenly caught (then the explanation is out of date).
SYSBUGS := BUG_NO_REWIND BUG_NO_MOVE BUG_NO_LEARN BUG_RX_NO_CRC BUG_PER_EGRESS_PRIORITY \
           BUG_FORK_ANY_READY BUG_FORK_GATED_VALID BUG_NO_FILTER
SYSBUGS_MISSED := BUG_FORK_GATED_VALID
sysbugs:
> @mkdir -p build
> @for b in $(SYSBUGS); do \
>   verilator $(VFLAGS) -Wno-PINCONNECTEMPTY +define+$$b --Mdir build/sys_$$b $(CDC) $(MAC) $(SW) tb/tb_switch.sv --top-module tb_switch -o sim > build/build_sys_$$b.log || { echo "$$b: BUILD FAILED"; exit 1; }; \
>   want=caught; case " $(SYSBUGS_MISSED) " in *" $$b "*) want=missed;; esac; \
>   r=""; for L in 20 100; do \
>     if ./build/sys_$$b/sim +N=300 +LOAD=$$L | grep -q "RESULT: PASS"; then got=missed; else got=caught; fi; \
>     r="$$r  load $$L%: $$got"; \
>     [ $$got = $$want ] || { echo "$$b:$$r  <-- expected $$want"; exit 1; }; \
>   done; echo "$$b:$$r"; \
> done; echo "RESULT: PASS (whole-switch bug results as expected)"

# FPGA flow (not part of `make test`). synth needs only yosys; pnr also needs
# nextpnr-ecp5 and reports timing without failing, because it does not close yet.
RTL        := $(CDC) $(MAC) $(SW)
PNR_DEVICE ?= --um-45k
PNR_SPEED  ?= 8
PNR_SEEDS  ?= 1 2 3
synth:
> @mkdir -p build
> yosys -q -l build/synth_xc7.log -p "read_verilog -Irtl $(RTL); synth_xilinx -family xc7 -top eth_switch_4port -flatten; tee -o build/synth_xc7.stat stat"
> yosys -q -l build/synth_ecp5.log -p "read_verilog -Irtl $(RTL); synth_ecp5 -top eth_switch_4port -flatten -json build/synth_ecp5.json; tee -o build/synth_ecp5.stat stat"
> @for t in xc7 ecp5; do echo "=== $$t"; sed -n '/Number of cells/,$$p' build/synth_$$t.stat; done

pnr: synth
> @for s in $(PNR_SEEDS); do \
>   nextpnr-ecp5 $(PNR_DEVICE) --package CABGA381 --speed $(PNR_SPEED) --json build/synth_ecp5.json --lpf syn/clocks.lpf --lpf-allow-unconstrained --router router2 --timing-allow-fail --threads 4 --seed $$s --log build/pnr_ecp5.s$$s.log > /dev/null 2>&1 & \
> done; wait
> @set -- $(PNR_SEEDS); grep -E 'TRELLIS_COMB|TRELLIS_FF:|TRELLIS_RAMW|DP16KD' build/pnr_ecp5.s$$1.log | tail -4
> @for s in $(PNR_SEEDS); do \
>   printf 'seed %s: ' $$s; grep 'Max frequency for clock' build/pnr_ecp5.s$$s.log | tail -9 | sed -E "s/.*clock +'([^']+)': ([0-9.]+) MHz.*/\1 \2/" | awk '/sys_clk/{s=$$2} /rx_clk/{if(!r||$$2<r)r=$$2} /tx_clk/{if(!t||$$2<t)t=$$2} END{if(!s){print "no timing result"; exit 1} printf "sys_clk %.1f MHz, slowest rx %.1f MHz, slowest tx %.1f MHz\n",s,r,t}' || exit 1; \
> done

test: lint crc tx rx loop ingress table core smoke sim sim125 perfcheck bugs

# hand-written bugs applied to a copy of the RTL (the list is in tb/mutants.py),
# so the RTL needs no ifdef for each; fails if a test misses one
mutants:
> @python3 tb/mutants.py

all: test congest sysbugs mutants

clean:
> rm -rf build
