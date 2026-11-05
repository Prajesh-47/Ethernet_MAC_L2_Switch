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
#   make sysbugs milestone 8: every injected bug through the whole-switch test
#   make all     test + congest + sysbugs (~10 min)
#   make bugs    rebuild with each injected bug; fails if any test still passes
#   make test    every test so far
# Recipe lines start with '>' instead of a TAB (easier to copy-paste).
.RECIPEPREFIX := >
CDC    := rtl/cdc/reset_sync.v rtl/cdc/sync_2ff.v rtl/cdc/fifo_mem.v rtl/cdc/wptr_full.v rtl/cdc/rptr_empty.v rtl/cdc/async_fifo.v
MAC    := rtl/eth_mac_tx.v rtl/eth_mac_rx.v rtl/eth_mac.v
SW     := rtl/ingress_buf.v rtl/mac_table.v rtl/switch_core.v rtl/eth_switch_4port.v
VFLAGS := --binary --timing -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Irtl -j 4

.PHONY: crc tx rx loop ingress table core smoke sim congest bugs sysbugs test all clean
crc:
> @mkdir -p build
> verilator $(VFLAGS) --Mdir build/obj_crc tb/tb_crc32.sv --top-module tb_crc32 -o sim > build/build_crc.log
> ./build/obj_crc/sim | grep -v finish

tx:
> @mkdir -p build
> verilator $(VFLAGS) --Mdir build/obj_tx rtl/eth_mac_tx.v tb/tb_mac_tx.sv --top-module tb_mac_tx -o sim > build/build_tx.log
> ./build/obj_tx/sim | grep -v finish

rx:
> @mkdir -p build
> verilator $(VFLAGS) --Mdir build/obj_rx rtl/eth_mac_rx.v tb/tb_mac_rx.sv --top-module tb_mac_rx -o sim > build/build_rx.log
> ./build/obj_rx/sim | grep -v finish

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
> ./build/obj_ingress/sim | grep -v finish

table:
> @mkdir -p build
> verilator $(VFLAGS) --Mdir build/obj_table rtl/mac_table.v tb/tb_mac_table.sv --top-module tb_mac_table -o sim > build/build_table.log
> ./build/obj_table/sim | grep -v finish

core:
> @mkdir -p build
> verilator $(VFLAGS) --Mdir build/obj_core rtl/switch_core.v tb/tb_switch_core.sv --top-module tb_switch_core -o sim > build/build_core.log
> ./build/obj_core/sim | grep -v finish

smoke:
> @mkdir -p build
> verilator $(VFLAGS) -Wno-PINCONNECTEMPTY --Mdir build/obj_smoke $(CDC) $(MAC) $(SW) tb/tb_switch_smoke.sv --top-module tb_switch_smoke -o sim > build/build_smoke.log
> ./build/obj_smoke/sim | grep -v finish

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

# Every bug through the WHOLE-switch test, at 20% and 100% load. Prints a
# caught / missed line per bug; a miss is reported, not an error, because some
# bugs are only visible to a unit test (see the README's bug table).
SYSBUGS := BUG_NO_REWIND BUG_NO_MOVE BUG_NO_LEARN BUG_RX_NO_CRC BUG_PER_EGRESS_PRIORITY \
           BUG_FORK_ANY_READY BUG_FORK_GATED_VALID BUG_NO_FILTER
sysbugs:
> @mkdir -p build
> @for b in $(SYSBUGS); do \
>   verilator $(VFLAGS) -Wno-PINCONNECTEMPTY +define+$$b --Mdir build/sys_$$b $(CDC) $(MAC) $(SW) tb/tb_switch.sv --top-module tb_switch -o sim > build/build_sys_$$b.log || { echo "$$b: BUILD FAILED"; exit 1; }; \
>   r=""; for L in 20 100; do \
>     if ./build/sys_$$b/sim +N=300 +LOAD=$$L | grep -q "RESULT: PASS"; then r="$$r  load $$L%: missed"; else r="$$r  load $$L%: caught"; fi; \
>   done; echo "$$b:$$r"; \
> done

test: crc tx rx loop ingress table core smoke sim bugs

all: test congest sysbugs

clean:
> rm -rf build
