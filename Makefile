# Ethernet_MAC_L2_Switch -- grows one milestone at a time
#   make crc     milestone 1: CRC-32 unit test
#   make tx      milestone 2: transmit MAC unit test
#   make rx      milestone 3: receive MAC unit test
#   make test    every test so far
# Recipe lines start with '>' instead of a TAB (easier to copy-paste).
.RECIPEPREFIX := >
VFLAGS := --binary --timing -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Irtl -j 4

.PHONY: crc tx rx test clean
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

test: crc tx rx

clean:
> rm -rf build
