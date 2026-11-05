# Open-source ASIC flow: assessment

Could this design go through an open-source ASIC flow, given that no FPGA board is available?

**Verdict: yes, as a physical design exercise, and the main work is memory.** It would produce a chip layout
with area, timing and power estimates. It would not produce a chip. None of this has been run yet, so
everything below is a desk assessment, and the size and speed figures are estimates to be measured.

## What it would give

| You get | You don't get |
| --- | --- |
| A layout file (GDSII) and an image of the design as a chip | A manufactured chip |
| Post-layout area, timing and power estimates | Proof it works in silicon |
| Design rule (DRC) and layout-versus-schematic (LVS) checks | Anything that replaces real hardware testing |
| Evidence that doesn't depend on a particular FPGA | |

Fabrication options weren't assessed, because the goal here is the design flow.

## Tools

| Tool | Role |
| --- | --- |
| **LibreLane** | The whole flow, RTL to layout. It was called OpenLane 2 until it was renamed in early 2026 |
| Yosys | Synthesis, already used in this project |
| OpenROAD | Placement, clock tree and routing |
| Magic, KLayout, Netgen | Layout and verification checks |
| ciel | Downloads the process design kit (PDK) |

| Process (PDK) | Notes |
| --- | --- |
| **sky130** | Best starting point, with an SRAM macro available and characterized below |
| gf180mcu | Also supported. Its listed SRAM macros are at most 512 x 8, so a 4 KB buffer needs 8 of them |
| IHP SG13G2 | Has 64-bit wide SRAM variants, but a 2025 IHP talk described the PDK as "preview" maturity |

## Can this machine run it?

| Item | Status |
| --- | --- |
| CPU, disk | 16 cores and 947 GB free, which should be plenty |
| Memory | 15 GB total. It may limit a full-design run, and only measuring will tell |
| Windows | LibreLane's guide says to use WSL on Windows, which this is |
| Docker or Nix | **Neither is installed, and installing either needs your sudo.** `docker.io` and `nix-bin` are both in `apt`. LibreLane's docs recommend Nix and also support Docker. A pip-only install is unsupported |

Nothing was installed for this assessment.

## The main problem: 16 KB of memory

The four ingress buffers hold 4 KB each. An ASIC has no block RAM, so there are two options.

**Flip-flops: not practical.** 16 KB is 131,072 bits. At about 20 µm² per flip-flop (a rough figure for
sky130's smallest), that is about 2.6 mm² before the read and write logic, which would be very large and hard to route.

**SRAM macros: the realistic route.** The sky130 macro `sky130_sram_2kbyte_1rw1r_32x512_8` from OpenRAM has these
figures in its timing library (typical corner, 1.8 V, 25 °C):

| Property | Value |
| --- | --- |
| Size | 32 bits x 512 words, 2 KB |
| Ports | One read/write, one read-only |
| Byte write mask | 4 bits |
| Area | 284,538, with no unit stated, presumably µm² (0.285 mm²) |
| Minimum clock period | 1.956 ns |
| Clock-to-output | 0.383-0.529 ns, on the **falling** clock edge |

- **Count:** 2 per port, so 8 in total. By the area above, that's about 2.3 mm² for memory alone.
- **It fits the current design.** One write port and one read port match the ingress buffer, and its registered
  read and prefetch FIFO already handle a memory that answers a cycle later.
- **It needs a small wrapper,** because the buffer is byte-wide and the macro is 32 bits wide: the write mask
  selects a byte, and the read side selects one of four bytes.
- **Don't trust the speed figure yet.** 1.956 ns implies about 511 MHz, but one OpenRAM test chip lists a
  50 MHz maximum. That may be a limit of the system rather than the macro, but it's a wide gap. The falling-edge
  output also leaves only half a cycle for its timing path, which is 4 ns at 125 MHz.

## Other changes it needs

- **Everything else:** the FIFOs and descriptor queues would become flip-flops, adding about 4,300 bits to the
  3,296 flip-flops in the FPGA build (2,432 bits of FIFO and 1,888 of descriptors).
- **Timing constraints:** an SDC file for 9 clocks, marking paths between clock domains as asynchronous. Today's
  flow has no such constraints, and a mistake here would hide real problems or report false ones.
- **Simulation:** tests would need a Verilog model of the macro, so the RTL needs a way to select it.
- **Reset:** the design uses asynchronous resets, which sky130 has flip-flops for, but reset tree timing needs checking.
- **rtl/cdc/:** the FIFOs stay as they are, but their synchronizers need checking in the flow. Any change goes
  to the Asynchronous_FIFO repo first.

## Rough size

These are rough estimates, to be replaced by measurements:

- **Memory:** about 2.3 mm².
- **Logic and flip-flops:** probably under 1 mm².
- **Total:** a die of several mm².

Whether it reaches 125 MHz in sky130 isn't known. Recent pipelining should help, but it can only be measured.

## Suggested plan

Each stage stops if it fails, and earlier stages still leave something useful:

| Stage | Work | Result |
| --- | --- | --- |
| 0 | Install Docker or Nix, and run LibreLane's smoke test | Confirms the flow runs on this machine |
| 1 | Harden one block with no memory, such as `switch_core` or `mac_table` | First real sky130 timing and area |
| 2 | Add the SRAM wrapper and macro model, and pass the existing tests | Memory ready for ASIC, verified in simulation |
| 3 | Harden one complete port with its macros | Tests the macro's timing and the 9-clock constraints |
| 4 | Harden the whole switch | Complete layout, if memory and run time allow |

The riskiest stages are 3 and 4, so only stage 0 and 1 results should be used to decide whether to go further.

## Sources

- [LibreLane repository](https://github.com/librelane/librelane) and [tutorial](https://vlsida.github.io/chip-tutorials/librelane.html)
- [OpenLane 2 installation overview](https://openlane2.readthedocs.io/en/latest/getting_started/installation_overview.html)
- [sky130 SRAM macro timing library](https://foss-eda-tools.googlesource.com/third_party/shuttle/sky130/mpw-005/slot-012/+/dc9a1cf4ada65e61ead505fabf3689c1b0ff91eb/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib)
- [OpenRAM test chip project page](https://platform.efabless.com/projects/187)
- [GF180MCU SRAM documentation](https://gf180mcu-pdk.readthedocs.io/en/latest/IPs/SRAM/sram.html)
- [IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK) and [IHP MOS-AK 2025 talk](https://www.mos-ak.org/LA_2025/presentations/1_Herman_MOS-AK_LA2025.pdf)
