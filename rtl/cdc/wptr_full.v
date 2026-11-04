// -----------------------------------------------------------------------------
// wptr_full.v  -- write-domain pointer and full / almost-full logic
//
// Pointers are AW+1 bits wide. The extra MSB is the "wrap bit": it flips
// every time the pointer passes the end of the array.
//
//   same address bits, same wrap bit       -> pointers equal  -> EMPTY
//   same address bits, different wrap bit  -> writer is one full lap ahead -> FULL
//
// In Gray code the FULL test becomes: the two MSBs are inverted and all the
// lower bits are equal (because Gray code reflects around the midpoint).
//
// Everything that is compared against the OTHER domain uses wq2_rptr, the
// read pointer after two-flop synchronization. It is always a few cycles old,
// so 'full' can stay asserted a little longer than necessary (pessimistic)
// but can never be de-asserted too early. That is the key safety argument.
// -----------------------------------------------------------------------------
`default_nettype none
module wptr_full #(
    parameter AW    = 5,
    parameter AF_TH = 28       // almost_full when fill level >= AF_TH
) (
    input  wire          wclk,
    input  wire          wrst_n,
    input  wire          winc,        // write request (valid)
    input  wire [AW:0]   wq2_rptr,    // synchronized read pointer (Gray)
    output reg           wfull,
    output reg           walmost_full,
    output wire [AW-1:0] waddr,
    output reg  [AW:0]   wptr,        // write pointer (Gray), goes to read domain
    output reg  [AW:0]   wbin,        // write pointer (binary), local only
    output wire [AW:0]   wfill        // conservative fill level seen by writer
);
    wire [AW:0] wbin_next;
    wire [AW:0] wgray_next;
    wire        wfull_next;
    wire [AW:0] wq2_rbin;
    wire [AW:0] wfill_next;

    // Gray -> binary: bin[i] = XOR of gray bits i..MSB
    genvar i;
    generate
        for (i = 0; i <= AW; i = i + 1) begin : g2b
            assign wq2_rbin[i] = ^(wq2_rptr >> i);
        end
    endgenerate

    // Only advance when not full: an attempted write while full is dropped by
    // design (and s_axis_tready is low, so a compliant master never does it).
    assign wbin_next  = wbin + {{AW{1'b0}}, (winc & ~wfull)};
    assign wgray_next = (wbin_next >> 1) ^ wbin_next;          // binary -> Gray

`ifdef BUG_FULL_NO_MSB_INVERT
    // INJECTED BUG: only the MSB inverted (the binary-pointer rule applied to
    // Gray pointers). Full is detected at the wrong fill level.
    assign wfull_next = (wgray_next == {~wq2_rptr[AW], wq2_rptr[AW-1:0]});
`else
    assign wfull_next = (wgray_next == {~wq2_rptr[AW:AW-1], wq2_rptr[AW-2:0]});
`endif

    assign wfill_next = wbin_next - wq2_rbin;   // modulo 2^(AW+1)

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin         <= {(AW+1){1'b0}};
            wptr         <= {(AW+1){1'b0}};
            wfull        <= 1'b0;
            walmost_full <= 1'b0;
        end else begin
            wbin         <= wbin_next;
            wptr         <= wgray_next;
            wfull        <= wfull_next;
            walmost_full <= (wfill_next >= AF_TH);
        end
    end

    assign waddr = wbin[AW-1:0];
    assign wfill = wbin - wq2_rbin;
endmodule
`default_nettype wire
