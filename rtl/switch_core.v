// -----------------------------------------------------------------------------
// switch_core.v -- forwarding decision, egress arbitration and crossbar
//
// FORWARDING (per ingress i, for its head-of-line frame):
//   dst multicast/broadcast (dst[40] = 1)  -> flood: every port except i
//   dst found in the table on port p       -> p, or DROP if p == i (filtered)
//   dst unknown                            -> flood
//
// ARBITRATION (one round-robin arbiter per egress port):
//   An egress port is FREE when no ingress owns it and its tx FIFO is empty.
//   Each free egress grants the first requesting ingress starting from a
//   round-robin pointer. An ingress starts only when it holds the grant of
//   EVERY port in its destination set (so a flood goes to all ports at once).
//   All egress arbiters share ONE pointer. That is what makes flooding
//   deadlock-free: the highest-priority requester wins every free port it
//   wants, so it always eventually holds its full set. (With independent
//   pointers, ingress A could hold port 1 while B holds port 2, each waiting
//   for the other's port forever.) The pointer advances after every start.
//
// CROSSBAR: the owning ingress streams its frame to all its egress ports at
// once (a "fork"). The ingress moves to the next byte only when EVERY
// destination has taken the current one. done[e] remembers that egress e
// already took it, so e's tvalid drops only after its OWN handshake.
// AXI-Stream rules kept: tvalid never depends on tready, and once tvalid is
// high it stays high (same data) until tready. (An earlier version gated
// tvalid with the other ports' tready; that let tvalid fall without a
// handshake -- tb_switch_core.sv catches it, see BUG_FORK_GATED_VALID.)
//
// Egress admission requires an EMPTY tx FIFO, so every copy of a frame starts
// from empty and drains at the same 125 MHz rate: the mid-frame underrun a
// lock-stepped fork could otherwise cause cannot happen (checked by the TB).
//
// Test-only bug switches (tb_switch_core.sv must catch each one):
//   BUG_PER_EGRESS_PRIORITY  each egress arbiter starts from its own index
//   BUG_FORK_ANY_READY       ingress advances when ANY destination took the byte
//   BUG_FORK_GATED_VALID     the old fork: tvalid gated by the other ports' tready
//   BUG_NO_FILTER            a frame for its own port is sent back out of it
// -----------------------------------------------------------------------------
`default_nettype none
module switch_core (
    input  wire        clk,
    input  wire        rst_n,
    // per ingress (4 ports packed)
    input  wire [3:0]   head_valid,
    input  wire [191:0] head_dst,
    input  wire [3:0]   lk_hit,         // from mac_table, for head_dst
    input  wire [7:0]   lk_port,
    output reg  [3:0]   xfer,
    output reg  [3:0]   drop,
    input  wire [31:0]  in_tdata,
    input  wire [3:0]   in_tvalid,
    input  wire [3:0]   in_tlast,
    output reg  [3:0]   in_tready,
    // per egress
    input  wire [3:0]   eg_empty,       // tx FIFO empty (sys-side view)
    output reg  [31:0]  eg_tdata,
    output reg  [3:0]   eg_tvalid,
    output reg  [3:0]   eg_tlast,
    input  wire [3:0]   eg_tready,
    // stats
    output reg  [3:0]   stat_flood,     // pulse: ingress i started a flooded frame
    output reg  [3:0]   stat_filter     // pulse: ingress i dropped a frame (dst on same port)
);
    // ---------------- destination masks ----------------
    reg [3:0] mask [0:3];
    reg [3:0] isflood;
    integer i, e;
    always @(*) begin
        for (i = 0; i < 4; i = i + 1) begin
            isflood[i] = head_dst[48*i + 40] || !lk_hit[i];
            if (isflood[i])                          mask[i] = 4'hF & ~(4'b1 << i);
`ifndef BUG_NO_FILTER
            else if (lk_port[2*i +: 2] == i[1:0])    mask[i] = 4'b0000;          // filter
`endif
            else                                     mask[i] = 4'b1 << lk_port[2*i +: 2];
        end
    end

    // ---------------- state ----------------
    reg [3:0] active;              // ingress i is streaming
    reg [3:0] xmask [0:3];         // latched destination set of an active ingress
    reg [3:0] own_v;               // egress e is owned
    reg [1:0] owner [0:3];
    reg [1:0] rr;

    // ---------------- requests and grants ----------------
    reg [3:0] req, start;
    reg [1:0] cand;                // candidate ingress index (rr + k, mod 4)
    reg [1:0] gnt  [0:3];
    reg [3:0] gnt_v;
    reg [3:0] egfree;
    integer k;
    always @(*) begin
        for (i = 0; i < 4; i = i + 1)
            req[i] = head_valid[i] && !active[i] && (mask[i] != 4'b0);
        for (e = 0; e < 4; e = e + 1) begin
            egfree[e] = !own_v[e] && eg_empty[e];
            gnt_v[e] = 1'b0; gnt[e] = 2'd0;
            for (k = 3; k >= 0; k = k - 1) begin      // lowest offset from rr wins
`ifndef BUG_PER_EGRESS_PRIORITY
                cand = rr + k[1:0];                   // 2-bit add wraps mod 4
`else
                cand = e[1:0] + k[1:0];               // BUG: no shared pointer
`endif
                if (egfree[e] && req[cand] && mask[cand][e]) begin
                    gnt_v[e] = 1'b1; gnt[e] = cand;
                end
            end
        end
        for (i = 0; i < 4; i = i + 1) begin
            start[i] = req[i];
            for (e = 0; e < 4; e = e + 1)
                if (mask[i][e] && !(gnt_v[e] && gnt[e] == i[1:0])) start[i] = 1'b0;
        end
    end

    // ---------------- crossbar (fork) ----------------
    reg [3:0] done;                // egress e already took the current byte
    reg [3:0] all_rdy;             // every destination of ingress i has the byte (or takes it now)
    always @(*) begin
        for (i = 0; i < 4; i = i + 1) begin
`ifndef BUG_FORK_ANY_READY
            all_rdy[i] = 1'b1;
            for (e = 0; e < 4; e = e + 1)
`ifndef BUG_FORK_GATED_VALID
                if (xmask[i][e] && !(done[e] || eg_tready[e])) all_rdy[i] = 1'b0;
`else
                if (xmask[i][e] && !eg_tready[e]) all_rdy[i] = 1'b0;
`endif
`else
            all_rdy[i] = 1'b0;     // BUG: any one destination is enough
            for (e = 0; e < 4; e = e + 1)
                if (xmask[i][e] && (done[e] || eg_tready[e])) all_rdy[i] = 1'b1;
`endif
            xfer[i]      = active[i];
            in_tready[i] = active[i] && all_rdy[i];
            drop[i]      = head_valid[i] && !active[i] && (mask[i] == 4'b0);
        end
        for (e = 0; e < 4; e = e + 1) begin
            eg_tdata[8*e +: 8] = in_tdata[8*owner[e] +: 8];
            eg_tlast[e]        = in_tlast[owner[e]];
`ifndef BUG_FORK_GATED_VALID
            eg_tvalid[e] = own_v[e] && in_tvalid[owner[e]] && !done[e];
`else
            eg_tvalid[e] = own_v[e] && in_tvalid[owner[e]];
            for (k = 0; k < 4; k = k + 1)
                if (k != e && xmask[owner[e]][k] && !eg_tready[k]) eg_tvalid[e] = 1'b0;
`endif
        end
    end

    // ---------------- sequential ----------------
    integer z;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0; own_v <= 0; rr <= 0; stat_flood <= 0; stat_filter <= 0; done <= 0;
            for (z = 0; z < 4; z = z + 1) begin xmask[z] <= 0; owner[z] <= 0; end
        end else begin
            stat_flood <= 0; stat_filter <= drop;
            for (i = 0; i < 4; i = i + 1) begin
                if (start[i]) begin
                    active[i] <= 1'b1;
                    xmask[i]  <= mask[i];
                    stat_flood[i] <= isflood[i];
                    for (e = 0; e < 4; e = e + 1)
                        if (mask[i][e]) begin own_v[e] <= 1'b1; owner[e] <= i[1:0]; end
                end
                if (active[i] && in_tvalid[i] && in_tready[i] && in_tlast[i]) begin
                    active[i] <= 1'b0;
                    for (e = 0; e < 4; e = e + 1)
                        if (xmask[i][e]) own_v[e] <= 1'b0;
                end
            end
            if (|start) rr <= rr + 1'b1;
            // fork bookkeeping: clear when the ingress moves on, set on this egress's own handshake
            for (e = 0; e < 4; e = e + 1)
                if (!own_v[e] || (in_tvalid[owner[e]] && in_tready[owner[e]])) done[e] <= 1'b0;
                else if (eg_tvalid[e] && eg_tready[e])                          done[e] <= 1'b1;
        end
    end
endmodule
`default_nettype wire
