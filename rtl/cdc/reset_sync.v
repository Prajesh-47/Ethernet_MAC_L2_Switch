// -----------------------------------------------------------------------------
// reset_sync.v
// Asynchronous-assert, synchronous-deassert reset synchronizer.
//
//  * rst_n_in goes low  -> rst_n_out goes low IMMEDIATELY (no clock needed).
//  * rst_n_in goes high -> rst_n_out goes high only after STAGES rising edges
//                          of clk, so every flop in this domain leaves reset on
//                          the same edge and never sees a reset-recovery
//                          violation.
// One instance is needed per clock domain.
// -----------------------------------------------------------------------------
`default_nettype none
module reset_sync #(
    parameter STAGES = 2
) (
    input  wire clk,
    input  wire rst_n_in,    // raw asynchronous reset, active low
    output wire rst_n_out    // synchronized reset, active low
);
    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] sync_q;

    always @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in)
            sync_q <= {STAGES{1'b0}};
        else
            sync_q <= {sync_q[STAGES-2:0], 1'b1};
    end

    assign rst_n_out = sync_q[STAGES-1];
endmodule
`default_nettype wire
