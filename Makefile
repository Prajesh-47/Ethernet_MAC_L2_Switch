# Ethernet_MAC_L2_Switch -- grows one milestone at a time
#   make crc     milestone 1: CRC-32 unit test
#   make tx      milestone 2: transmit MAC unit test
#   make rx      milestone 3: receive MAC unit test
#   make loop    milestone 4: full MAC (TX + RX + async FIFOs) in loopback
#   make test    every test so far
# Recipe lines start with '>' instead of a TAB (easier to copy-paste).
.RECIPEPREFIX := >
CDC    := rtl/cdc/reset_sync.v rtl/cdc/sync_2ff.v rtl/cdc/fifo_mem.v rtl/cdc/wptr_full.v rtl/cdc/rptr_empty.v rtl/cdc/async_fifo.v
MAC    := rtl/eth_mac_tx.v rtl/eth_mac_rx.v rtl/eth_mac.v
VFLAGS := --binary --timing -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Irtl -j 4

.PHONY: crc tx rx loop test clean
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

test: crc tx rx loop

clean:
> rm -rf build
