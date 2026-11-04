// -----------------------------------------------------------------------------
// async_fifo.v  -- Dual-clock FIFO with AXI4-Stream on both sides
//
//   s_axis_*  : slave (input) side, clocked by s_aclk  (the WRITE domain)
//   m_axis_*  : master (output) side, clocked by m_aclk (the READ domain)
//
// Block diagram (see docs for the picture):
//
//   s_aclk domain                         m_aclk domain
//   +------------+   wptr (Gray)   +-----------+
//   | wptr_full  |---------------->| sync_2ff  |--> rq2_wptr --+
//   |            |                 +-----------+               |
//   |            |<-- wq2_rptr --+                       +-----v------+
//   +-----+------+               |   +-----------+       | rptr_empty |
//         | waddr                +---| sync_2ff  |<------|            |
//         v                          +-----------+ rptr  +-----+------+
//   +-----------------------------------------------+          | raddr
//   |                fifo_mem (32 x 32)             |<---------+
//   +-----------------------------------------------+
//
// Handshake rules (AXI4-Stream):
//   * a word moves on a clock edge where VALID && READY are both high
//   * s_axis_tready = !full     (we accept when there is room)
//   * m_axis_tvalid = !empty    (we offer the oldest word when we have one)
//   * once m_axis_tvalid is high it stays high, with stable data, until the
//     sink takes the word -- required by AXI and proven formally below.
// -----------------------------------------------------------------------------
`default_nettype none
module async_fifo #(
    parameter DW    = 32,
    parameter AW    = 5,           // depth = 2**AW = 32
    parameter AF_TH = (1<<AW) - 4, // almost_full  at fill >= 28
    parameter AE_TH = 4            // almost_empty at fill <= 4
) (
    // write side (AXI4-Stream slave)
    input  wire          s_aclk,
    input  wire          s_aresetn,
    input  wire [DW-1:0] s_axis_tdata,
    input  wire          s_axis_tvalid,
    output wire          s_axis_tready,
    output wire          s_almost_full,
    output wire [AW:0]   s_fill,        // writer's (pessimistic) view of occupancy
    // read side (AXI4-Stream master)
    input  wire          m_aclk,
    input  wire          m_aresetn,
    output wire [DW-1:0] m_axis_tdata,
    output wire          m_axis_tvalid,
    input  wire          m_axis_tready,
    output wire          m_almost_empty
);
    // ---------------- per-domain synchronized resets ----------------
    wire wrst_n, rrst_n;
    reset_sync u_wrst (.clk(s_aclk), .rst_n_in(s_aresetn), .rst_n_out(wrst_n));
    reset_sync u_rrst (.clk(m_aclk), .rst_n_in(m_aresetn), .rst_n_out(rrst_n));

    // ---------------- pointers ----------------
    wire [AW:0]   wptr, rptr, wq2_rptr, rq2_wptr, wbin, rbin, wfill, rfill;
    wire [AW-1:0] waddr, raddr;
    wire          wfull, rempty;

    wire wr_fire = s_axis_tvalid & s_axis_tready;
    wire rd_fire = m_axis_tvalid & m_axis_tready;

    // read pointer -> write domain
    sync_2ff #(.WIDTH(AW+1)) u_sync_r2w (
        .clk(s_aclk), .rst_n(wrst_n), .d_in(rptr), .d_out(wq2_rptr));

    // write pointer -> read domain
`ifdef BUG_BINARY_SYNC
    // INJECTED BUG: binary pointer sent across instead of Gray.
    sync_2ff #(.WIDTH(AW+1)) u_sync_w2r (
        .clk(m_aclk), .rst_n(rrst_n), .d_in(wbin), .d_out(rq2_wptr));
`else
    sync_2ff #(.WIDTH(AW+1)) u_sync_w2r (
        .clk(m_aclk), .rst_n(rrst_n), .d_in(wptr), .d_out(rq2_wptr));
`endif

    wptr_full #(.AW(AW), .AF_TH(AF_TH)) u_wptr (
        .wclk(s_aclk), .wrst_n(wrst_n), .winc(wr_fire), .wq2_rptr(wq2_rptr),
        .wfull(wfull), .walmost_full(s_almost_full), .waddr(waddr),
        .wptr(wptr), .wbin(wbin), .wfill(wfill));

    rptr_empty #(.AW(AW), .AE_TH(AE_TH)) u_rptr (
        .rclk(m_aclk), .rrst_n(rrst_n), .rinc(rd_fire), .rq2_wptr(rq2_wptr),
        .rempty(rempty), .ralmost_empty(m_almost_empty), .raddr(raddr),
        .rptr(rptr), .rbin(rbin), .rfill(rfill));

    fifo_mem #(.DW(DW), .AW(AW)) u_mem (
        .wclk(s_aclk), .wen(wr_fire), .waddr(waddr), .wdata(s_axis_tdata),
        .raddr(raddr), .rdata(m_axis_tdata));

    // While in reset, refuse writes (tready low) and offer nothing.
`ifdef BUG_NO_TREADY_RESET_GATE
    // INJECTED BUG: tready not gated by reset. While the write domain is still
    // in (synchronized) reset, the pointer is held at 0 but the master sees a
    // completed handshake -> the word is silently dropped.
    assign s_axis_tready = ~wfull;
`else
    assign s_axis_tready = wrst_n & ~wfull;
`endif
    // Occupancy as the writer sees it. It uses the synchronized (old) read
    // pointer, so it can only OVER-estimate: s_fill == 0 means truly empty.
    assign s_fill = wfill;
    assign m_axis_tvalid = rrst_n & ~rempty;

`ifdef FORMAL
    // =========================================================================
    // Formal properties (SymbiYosys, multiclock mode).
    // Both clocks are FREE inputs: the solver may toggle either one at any
    // global step, so a proof covers EVERY possible clock ratio and phase.
    // =========================================================================
    localparam DEPTH = (1<<AW);

    reg f_past_valid = 1'b0;
    always @($global_clock) f_past_valid <= 1'b1;

    // Both resets asserted at time 0, released afterwards and never again.
    always @(*) if (!f_past_valid) assume(!s_aresetn && !m_aresetn);
    // Once released, stay released. Written COMBINATIONALLY on purpose:
    // a clocked "always @($global_clock) assume(...)" is evaluated on the
    // previous step's values, so in the LAST step of a trace the solver could
    // still drop reset -- which produced a bogus counterexample to P13.
    reg f_s_rel = 1'b0, f_m_rel = 1'b0;
    always @($global_clock) begin
        if (s_aresetn) f_s_rel <= 1'b1;
        if (m_aresetn) f_m_rel <= 1'b1;
    end
    always @(*) if (f_s_rel) assume(s_aresetn);
    always @(*) if (f_m_rel) assume(m_aresetn);

    // ---- true occupancy (only visible to the formal tool) ----
    wire [AW:0] f_fill = wbin - rbin;

    // P1: never overflow -- occupancy never exceeds DEPTH
    always @(*) if (wrst_n && rrst_n) assert(f_fill <= DEPTH);

    // P2: no write is accepted while full (tready must be low)
    always @(*) if (wfull) assert(!s_axis_tready);

    // P3: no read happens while empty
    always @(*) if (rempty) assert(!m_axis_tvalid);

    // P4: write pointer (Gray) changes by at most one bit per step
    always @($global_clock) if (f_past_valid)
        assert($countones(wptr ^ $past(wptr)) <= 1);

    // P5: read pointer (Gray) changes by at most one bit per step
    always @($global_clock) if (f_past_valid)
        assert($countones(rptr ^ $past(rptr)) <= 1);

    // P6: Gray and binary pointers stay consistent
    always @(*) assert(wptr == ((wbin >> 1) ^ wbin));
    always @(*) assert(rptr == ((rbin >> 1) ^ rbin));

    // P7: the writer's view of occupancy is sane, and 'not full' is never a lie.
    //     Note it is NOT "wfull == (wfill == DEPTH)": wfull is registered
    //     against the PREVIOUS synchronized read pointer, so it can stay high
    //     one cycle after room appeared. Pessimistic is fine; optimistic is not.
    always @(*) if (wrst_n) assert(wfill <= DEPTH);
    always @(*) if (wrst_n && !wfull) assert(wfill < DEPTH);

    // P8: same for the reader: 'not empty' is never a lie
    always @(*) if (rrst_n) assert(rfill <= DEPTH);
    always @(*) if (rrst_n && !rempty) assert(rfill != 0);

    // P9: underflow -- reader never runs ahead of the writer
    //     (rbin <= wbin modulo wrap is the same as f_fill <= DEPTH, plus:)
    always @(*) if (wrst_n && rrst_n && rempty == 1'b0) assert(f_fill != 0);

    // P10: AXI4-Stream stability on the output -- once valid, stay valid and
    //      keep the same data until the sink accepts
    always @($global_clock) if (f_past_valid && $past(rrst_n) && rrst_n
                                && $past(m_axis_tvalid) && !$past(m_axis_tready))
        assert(m_axis_tvalid && m_axis_tdata == $past(m_axis_tdata));

    // P11: flag consistency
    always @(*) if (wfull  && wrst_n) assert(s_almost_full  || AF_TH > DEPTH);
    always @(*) if (rempty && rrst_n) assert(m_almost_empty);

    // P12: DATA INTEGRITY. Pick an arbitrary pointer value f_ptr (the solver
    //      chooses it). Remember the word written at that pointer; when the
    //      reader reaches that pointer, the word it presents must match.
    //      Because f_ptr is arbitrary, this covers every slot and every lap.
    (* anyconst *) reg [AW:0] f_ptr;
    reg [DW-1:0] f_data;
    reg          f_written = 1'b0;
    always @(posedge s_aclk)
        if (wr_fire && wbin == f_ptr) begin
            f_data    <= s_axis_tdata;
            f_written <= 1'b1;
        end
    always @(*) if (rrst_n && wrst_n && m_axis_tvalid && rbin == f_ptr) begin
        assert(f_written);
        assert(m_axis_tdata == f_data);
    end

    // P13: HANDSHAKE ACCOUNTING. Count every accepted AXI handshake on each
    //      side (these counters are NOT reset by the internal synchronized
    //      resets). Each accepted word must advance the pointer exactly once.
    //      P12 alone cannot see a handshake that never moved the pointer --
    //      this property was added after the formal run MISSED the injected
    //      BUG_NO_TREADY_RESET_GATE, which the simulation caught.
    reg [AW:0] f_wcount = 0, f_rcount = 0;
    always @(posedge s_aclk) if (wr_fire) f_wcount <= f_wcount + 1'b1;
    always @(posedge m_aclk) if (rd_fire) f_rcount <= f_rcount + 1'b1;
    always @(*) assert(f_wcount == wbin);
    always @(*) assert(f_rcount == rbin);

    // ---- covers: show the interesting states are reachable ----
    always @(*) cover(wfull);
    always @(*) cover(f_written && rbin == f_ptr + 1'b1);  // word read back
`endif
endmodule
`default_nettype wire
