// -----------------------------------------------------------------------------
// rptr_empty.v  -- read-domain pointer and empty / almost-empty logic
//
// EMPTY is "my next read pointer equals the (synchronized) write pointer".
// rq2_wptr is old, so the reader may think the FIFO is empty for a couple of
// cycles after a word actually landed (pessimistic) -- but it can never think
// a word is there when it is not. That is why the design is safe.
// -----------------------------------------------------------------------------
`default_nettype none
module rptr_empty #(
    parameter AW    = 5,
    parameter AE_TH = 4        // almost_empty when fill level <= AE_TH
) (
    input  wire          rclk,
    input  wire          rrst_n,
    input  wire          rinc,          // read request (ready & valid)
    input  wire [AW:0]   rq2_wptr,      // synchronized write pointer (Gray)
    output reg           rempty,
    output reg           ralmost_empty,
    output wire [AW-1:0] raddr,
    output reg  [AW:0]   rptr,          // read pointer (Gray), goes to write domain
    output reg  [AW:0]   rbin,
    output wire [AW:0]   rfill          // conservative fill level seen by reader
);
    wire [AW:0] rbin_next;
    wire [AW:0] rgray_next;
    wire        rempty_next;
    wire [AW:0] rq2_wbin;
    wire [AW:0] rfill_next;

    genvar i;
    generate
        for (i = 0; i <= AW; i = i + 1) begin : g2b
            assign rq2_wbin[i] = ^(rq2_wptr >> i);
        end
    endgenerate

    assign rbin_next   = rbin + {{AW{1'b0}}, (rinc & ~rempty)};
    assign rgray_next  = (rbin_next >> 1) ^ rbin_next;
    assign rempty_next = (rgray_next == rq2_wptr);
    assign rfill_next  = rq2_wbin - rbin_next;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin          <= {(AW+1){1'b0}};
            rptr          <= {(AW+1){1'b0}};
            rempty        <= 1'b1;            // empty out of reset
            ralmost_empty <= 1'b1;
        end else begin
            rbin          <= rbin_next;
            rptr          <= rgray_next;
            rempty        <= rempty_next;
            ralmost_empty <= (rfill_next <= AE_TH);
        end
    end

    assign raddr = rbin[AW-1:0];
    assign rfill = rq2_wbin - rbin;
endmodule
`default_nettype wire
