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
//
// The frame memory has a registered read so it maps to block RAM. A small
// prefetch FIFO sits between it and out_t*, so out_tready never reaches the
// RAM address. Fetching starts when xfer rises: the first byte appears 3 clocks
// later, then the frame streams with no gaps. A byte's space is released when
// it is delivered on out_t*, not when it is fetched.
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
    reg [AW:0] wr_ptr, rd_ptr, frm_start;      // rd_ptr: next byte to DELIVER
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

    wire mem_we = beat && room && !ovf;
    wire commit = beat && s_tlast && !s_tuser && !ovf && room && !q_full && (wcnt + 1 >= 14);

    // ---------------- storage ----------------
    // Written in their own block with no reset: an array assigned inside an
    // async-reset process cannot be inferred as RAM (it becomes one flip-flop
    // per bit). Nothing reads these before writing them: the pointers do reset.
    always @(posedge clk) begin
        if (mem_we) mem[wr_ptr[AW-1:0]] <= s_tdata;
        if (commit) begin
            q_len[q_wr[2:0]] <= wcnt + 1'b1;
            q_dst[q_wr[2:0]] <= cap_dst;
        end
    end

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
                if (mem_we) begin
                    if (wcnt < 6)       cap_dst <= {cap_dst[39:0], s_tdata};
                    else if (wcnt < 12) cap_src <= {cap_src[39:0], s_tdata};
                end
                if (!room) ovf <= 1'b1;
                if (!s_tlast) begin
                    if (room && !ovf) wr_ptr <= wr_ptr + 1'b1;
                    if (wcnt != 11'h7FF) wcnt <= wcnt + 1'b1;
                end else begin
                    // end of frame: commit or rewind
                    if (commit) begin
                        wr_ptr        <= wr_ptr + 1'b1;
                        frm_start     <= wr_ptr + 1'b1;
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
    localparam [1:0] F_IDLE = 2'd0, F_FETCH = 2'd1, F_DRAIN = 2'd2;
    reg [1:0]  f_state;
    reg [AW:0] fetch_ptr;                      // next byte to read from mem
    reg [10:0] f_cnt;                          // bytes of the head frame fetched so far
    reg [7:0]  rd_data;                        // block RAM output register
    reg        rd_valid, rd_last;
    reg [8:0]  pf_mem [0:3];                   // prefetch FIFO: {last, data}
    reg [1:0]  pf_wp, pf_rp;
    reg [2:0]  pf_cnt;

    assign head_valid = !q_empty;
    assign head_len   = q_len[q_rd[2:0]];
    assign head_dst   = q_dst[q_rd[2:0]];
    assign out_tvalid = (pf_cnt != 3'd0);
    assign {out_tlast, out_tdata} = pf_mem[pf_rp];

    // Fetch only if the FIFO has room for this byte and the one still in the RAM.
    wire [2:0] pf_used = pf_cnt + {2'b0, rd_valid};
    wire       rd_en   = (f_state == F_FETCH) && (pf_used != 3'd4);
    wire       f_last  = (f_cnt == head_len - 1'b1);
    wire       pf_pop  = out_tvalid && out_tready;

    always @(posedge clk) begin
        if (rd_en)    rd_data       <= mem[fetch_ptr[AW-1:0]];
        if (rd_valid) pf_mem[pf_wp] <= {rd_last, rd_data};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_state <= F_IDLE; fetch_ptr <= 0; f_cnt <= 0; rd_ptr <= 0; q_rd <= 0;
            rd_valid <= 0; rd_last <= 0; pf_wp <= 0; pf_rp <= 0; pf_cnt <= 0;
        end else begin
            rd_valid <= rd_en;
            if (rd_en)    rd_last <= f_last;
            if (rd_valid) pf_wp   <= pf_wp + 1'b1;
            if (pf_pop)   pf_rp   <= pf_rp + 1'b1;
            pf_cnt <= pf_cnt + {2'b0, rd_valid} - {2'b0, pf_pop};

            if (drop && head_valid) begin
                rd_ptr    <= rd_ptr    + {{(AW-10){1'b0}}, head_len};
                fetch_ptr <= fetch_ptr + {{(AW-10){1'b0}}, head_len};
                q_rd      <= q_rd + 1'b1;
            end else begin
                if (f_state == F_IDLE && xfer && head_valid) begin
                    f_state <= F_FETCH;
                    f_cnt   <= 0;
                end
                if (rd_en) begin
                    fetch_ptr <= fetch_ptr + 1'b1;
                    f_cnt     <= f_cnt + 1'b1;
                    if (f_last) f_state <= F_DRAIN;
                end
                if (pf_pop) begin
                    rd_ptr <= rd_ptr + 1'b1;
                    if (out_tlast) begin
                        q_rd    <= q_rd + 1'b1;
                        f_state <= F_IDLE;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
