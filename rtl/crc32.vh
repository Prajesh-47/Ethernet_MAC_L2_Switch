// -----------------------------------------------------------------------------
// crc32.vh -- IEEE 802.3 CRC-32, one byte per call (module-scoped function).
//
// Ethernet uses the REFLECTED form of polynomial 0x04C11DB7, i.e. 0xEDB88320,
// processing each byte LSB first (the same order bits go on the wire).
//
//   transmitter : crc = 0xFFFFFFFF; crc = crc32_byte(crc, b) for every byte;
//                 FCS = ~crc, sent LEAST significant byte first
//   receiver    : run the same update over data AND the 4 FCS bytes; for a
//                 good frame the register then always equals the constant
//                 residue 0xDEBB20E3 -- no need to locate or invert the FCS.
//
// The 8-iteration loop unrolls into an XOR network (~ 8 levels) in synthesis.
// -----------------------------------------------------------------------------
/* verilator lint_off BLKSEQ */   // blocking '=' inside a function is correct here
function [31:0] crc32_byte(input [31:0] crc, input [7:0] data);
    integer b;
    reg [31:0] c;
    begin
        c = crc ^ {24'b0, data};
        for (b = 0; b < 8; b = b + 1)
            c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        crc32_byte = c;
    end
endfunction
/* verilator lint_on BLKSEQ */
