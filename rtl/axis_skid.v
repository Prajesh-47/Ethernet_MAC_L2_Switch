// -----------------------------------------------------------------------------
// axis_skid.v -- AXI4-Stream register slice with a skid buffer
//
// Cuts a long path in both directions: s_tready and every m_* output come
// straight from flip-flops, so nothing combinational passes through this block.
// It still moves one word per clock.
//
// Why two entries: s_tready is a flip-flop, so the sender only sees a stall one
// clock late. One more word can arrive after the output has stalled, and the
// skid register (skid_data) holds it.
//
// `empty` is high only when neither register holds a word.
// -----------------------------------------------------------------------------
`default_nettype none
module axis_skid #(
    parameter DW = 9
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire [DW-1:0] s_tdata,
    input  wire          s_tvalid,
    output wire          s_tready,
    output reg  [DW-1:0] m_tdata,
    output reg           m_tvalid,
    input  wire          m_tready,
    output wire          empty
);
    reg [DW-1:0] skid_data;
    reg          skid_valid;

    assign s_tready = !skid_valid;
    assign empty    = !m_tvalid && !skid_valid;

    wire s_fire  = s_tvalid && s_tready;
    wire m_stall = m_tvalid && !m_tready;

    always @(posedge clk) begin
        if (s_fire && m_stall) skid_data <= s_tdata;
        if (!m_stall)          m_tdata   <= skid_valid ? skid_data : s_tdata;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_tvalid   <= 1'b0;
            skid_valid <= 1'b0;
        end else begin
            if (!m_stall) begin
                m_tvalid   <= skid_valid || s_fire;
                skid_valid <= 1'b0;
            end else if (s_fire) begin
                skid_valid <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
