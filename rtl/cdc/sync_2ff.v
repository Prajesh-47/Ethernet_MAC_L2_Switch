// -----------------------------------------------------------------------------
// sync_2ff.v
// Multi-bit two-flop synchronizer.
//
// IMPORTANT: this is only safe for a multi-bit bus when AT MOST ONE BIT of
// d_in changes between consecutive samples. That is exactly why the FIFO
// pointers are Gray coded before they pass through here. A binary counter
// going 0111 -> 1000 changes 4 bits; if they resolve at different times the
// destination could see 1111 or 0000 for a cycle -- a wrong pointer.
// With Gray code, the worst case is the destination sees the OLD value for
// one more cycle, which is safe (pessimistic full/empty).
// -----------------------------------------------------------------------------
`default_nettype none
module sync_2ff #(
    parameter WIDTH = 6
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [WIDTH-1:0] d_in,
    output wire [WIDTH-1:0] d_out
);
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] q1;
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] q2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q1 <= {WIDTH{1'b0}};
            q2 <= {WIDTH{1'b0}};
        end else begin
            q1 <= d_in;   // may go metastable
            q2 <= q1;     // has a full cycle to resolve
        end
    end

    assign d_out = q2;
endmodule
`default_nettype wire
