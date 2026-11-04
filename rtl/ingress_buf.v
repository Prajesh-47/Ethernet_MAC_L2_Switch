// -----------------------------------------------------------------------------
// ingress_buf.v -- per-port store-and-forward frame buffer (system clock)
//
// WRITE side (from the MAC's rx stream; never back-pressures):
//   bytes are written at wr_ptr. When the frame's tlast arrives:
//     good -> the frame is COMMITTED: a descriptor {len, dst, src} is queued
//             and a learn request (src MAC -> this port) is raised
//     bad  -> wr_ptr REWINDS to the frame start; the frame vanishes
//   "bad" = MAC said bad (tuser), or the buffer / descriptor queue was full,
//   or the frame was shorter than a 14-byte header.
//   Store-and-forward is what lets the switch drop CRC-bad frames: the
//   verdict only exists once the whole frame is in.
//
// READ side (to the crossbar):
//   head_* describes the oldest committed frame. While `xfer` is high the
//   buffer streams that frame on out_t*; the descriptor pops on the tlast
//   beat. `drop` (one cycle) discards the head frame without sending it.
//
// Test-only bug switch: +define+BUG_NO_REWIND (a dropped frame's bytes are
// left in the buffer).
// Memory read is combinational (LUT RAM). With block RAM's registered read
// you would add a 2-entry skid buffer on out_t* -- see the guide.
// -----------------------------------------------------------------------------
`default_nettype none
module ingress_buf #(
    parameter AW   = 12,               // 4096-byte buffer
    parameter PORT = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    // from MAC rx (sys clock)
    input  wire [7:0]  s_tdata,
    input  wire        s_tvalid,
    input  wire        s_tlast,
    input  wire        s_tuser,
    output wire        s_tready,
    // head-of-line descriptor
    output wire        head_valid,
    output wire [10:0] head_len,
    output wire [47:0] head_dst,
    // stream out
    input  wire        xfer,
    input  wire        drop,
    output wire [7:0]  out_tdata,
    output wire        out_tvalid,
    output wire        out_tlast,
    input  wire        out_tready,
    // learning
    output reg         learn_valid,
    output reg  [47:0] learn_mac,
    input  wire        learn_ack,
    // stats
    output reg         stat_drop
);
    localparam DEPTH = (1 << AW);
    localparam QD = 8;                         // descriptor queue depth

    reg [7:0]  mem [0:DEPTH-1];
    reg [AW:0] wr_ptr, rd_ptr, frm_start;
    reg [10:0] wcnt;                           // bytes of the frame being written
    reg [47:0] cap_dst, cap_src;
    reg        ovf;

    // descriptor queue
    reg [10:0] q_len [0:QD-1];
    reg [47:0] q_dst [0:QD-1];
    reg [3:0]  q_wr, q_rd;                     // 3 bits + wrap
    wire       q_full  = (q_wr[2:0] == q_rd[2:0]) && (q_wr[3] != q_rd[3]);
    wire       q_empty = (q_wr == q_rd);

    wire [AW:0] used = wr_ptr - rd_ptr;
    wire        room = (used < DEPTH);
    wire        beat = s_tvalid;               // s_tready is always 1
    assign s_tready = 1'b1;

    // ---------------- write side ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0; frm_start <= 0; wcnt <= 0; ovf <= 0;
            cap_dst <= 0; cap_src <= 0; q_wr <= 0;
            learn_valid <= 0; learn_mac <= 0; stat_drop <= 0;
        end else begin
            stat_drop <= 1'b0;
            if (learn_ack) learn_valid <= 1'b0;
            if (beat) begin
                if (room && !ovf) begin
                    mem[wr_ptr[AW-1:0]] <= s_tdata;
                    if (wcnt < 6)       cap_dst <= {cap_dst[39:0], s_tdata};
                    else if (wcnt < 12) cap_src <= {cap_src[39:0], s_tdata};
                end
                if (!room) ovf <= 1'b1;
                if (!s_tlast) begin
                    if (room && !ovf) wr_ptr <= wr_ptr + 1'b1;
                    if (wcnt != 11'h7FF) wcnt <= wcnt + 1'b1;
                end else begin
                    // end of frame: commit or rewind
                    if (!s_tuser && !ovf && room && !q_full && (wcnt + 1 >= 14)) begin
                        wr_ptr        <= wr_ptr + 1'b1;
                        frm_start     <= wr_ptr + 1'b1;
                        q_len[q_wr[2:0]] <= wcnt + 1'b1;
                        q_dst[q_wr[2:0]] <= cap_dst;
                        q_wr          <= q_wr + 1'b1;
                        // learn the source, unless it is a multicast address (invalid as a source)
                        if (!cap_src[40]) begin learn_valid <= 1'b1; learn_mac <= cap_src; end
                    end else begin
`ifndef BUG_NO_REWIND
                        wr_ptr    <= frm_start;               // rewind: the frame never happened
`endif
                        stat_drop <= 1'b1;
                    end
                    wcnt <= 0; ovf <= 1'b0;
                end
            end
        end
    end

    // ---------------- read side ----------------
    reg [10:0] rcnt;
    assign head_valid = !q_empty;
    assign head_len   = q_len[q_rd[2:0]];
    assign head_dst   = q_dst[q_rd[2:0]];
    assign out_tvalid = xfer && head_valid;
    assign out_tdata  = mem[rd_ptr[AW-1:0]];
    assign out_tlast  = (rcnt == head_len - 1'b1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0; rcnt <= 0; q_rd <= 0;
        end else if (drop && head_valid) begin
            rd_ptr <= rd_ptr + {{(AW-10){1'b0}}, head_len};
            rcnt   <= 0;
            q_rd   <= q_rd + 1'b1;
        end else if (out_tvalid && out_tready) begin
            rd_ptr <= rd_ptr + 1'b1;
            if (out_tlast) begin rcnt <= 0; q_rd <= q_rd + 1'b1; end
            else           rcnt <= rcnt + 1'b1;
        end
    end
endmodule
`default_nettype wire
