# Ethernet_MAC_L2_Switch -- grows one milestone at a time
#   make crc     milestone 1: CRC-32 unit test
VFLAGS := --binary --timing -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Irtl -j 4

.PHONY: crc clean
crc:
	@mkdir -p build
	verilator $(VFLAGS) --Mdir build/obj_crc tb/tb_crc32.sv --top-module tb_crc32 -o sim > build/build_crc.log
	./build/obj_crc/sim | grep -v finish

clean:
	rm -rf build
