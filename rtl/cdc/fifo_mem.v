// -----------------------------------------------------------------------------
// fifo_mem.v
// Dual-port storage: write port in the write clock domain, asynchronous
// (combinational) read port addressed from the read domain.
//
// The read is combinational so the FIFO behaves "first-word-fall-through":
// as soon as the FIFO is non-empty, m_axis_tdata already shows the oldest word.
// On an FPGA this maps to distributed (LUT) RAM. In an ASIC with an SRAM
// macro (synchronous read) you add a one-entry prefetch register on the read
// side -- see docs, section "Hardening with an SRAM macro".
//
// No reset on the array: storage is never read before it is written,
// because the empty flag blocks it.
// -----------------------------------------------------------------------------
`default_nettype none
module fifo_mem #(
    parameter DW = 32,
    parameter AW = 5
) (
    input  wire          wclk,
    input  wire          wen,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire [AW-1:0] raddr,
    output wire [DW-1:0] rdata
);
    reg [DW-1:0] mem [0:(1<<AW)-1];

    always @(posedge wclk) begin
        if (wen)
            mem[waddr] <= wdata;
    end

    assign rdata = mem[raddr];
endmodule
`default_nettype wire
