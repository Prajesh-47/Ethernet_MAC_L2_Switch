// -----------------------------------------------------------------------------
// mac_table.v -- MAC learning table, 16 entries, fully associative
//
// One comparator bank is shared by learning and all four lookup ports through a
// 3-stage pipeline, so no path runs from an arbiter to a table write in a cycle:
//
//   S select   : a learn request if one is waiting, otherwise the next lookup
//                port in rotation. The address is registered.
//   A compare  : the address against every entry. The match vector is registered.
//   B commit   : a lookup stores its result; a learn updates the table.
//
// LOOKUPS. While lk_en[p] is high with a stable lk_mac[p], the port is looked up
// again and again: lk_valid[p] rises within about 10 cycles and lk_hit / lk_port
// keep following the table after that. lk_valid is only true for the current
// address if the requester drops lk_en for one cycle whenever the address
// changes: that discards results still in the pipeline and clears lk_valid.
//
// LEARNING. One request at a time (3 cycles each), granted round-robin:
//   address already present -> update its port (a station moved)
//   not present             -> write it into the next victim slot (oldest first)
// Only one learn is in the pipeline, so an address cannot be inserted twice.
//
// Test-only bug switches: +define+BUG_NO_MOVE (a station that moves keeps its
// old port), +define+BUG_NO_LEARN (nothing is ever learned).
// No aging timer: entries live until replaced. (A real switch ages entries
// out after ~300 s so a silent station's slot can be reused.)
// -----------------------------------------------------------------------------
`default_nettype none
module mac_table #(
    parameter N = 16
) (
    input  wire         clk,
    input  wire         rst_n,
    // lookups: 4 x 48-bit address in, valid + hit + port out
    input  wire [3:0]   lk_en,
    input  wire [191:0] lk_mac,
    output reg  [3:0]   lk_valid,
    output reg  [3:0]   lk_hit,
    output reg  [7:0]   lk_port,
    // learn requests: one per ingress port
    input  wire [3:0]   ln_valid,
    input  wire [191:0] ln_mac,
    output wire [3:0]   ln_ack           // same-cycle acknowledge (requester clears on this edge)
);
    reg [N-1:0] v;
    reg [47:0]  mac [0:N-1];             // not reset: only read when v[k] is set
    reg [1:0]   prt [0:N-1];
    reg [$clog2(N)-1:0] victim;

    // ---------------- stage S: select ----------------
    reg [1:0] rr;                        // learn arbitration pointer
    reg [1:0] scan;                      // next lookup port
    reg [1:0] sel, cand; reg any;
    integer i;
    always @(*) begin
        any = 1'b0; sel = 2'd0;
        for (i = 3; i >= 0; i = i - 1) begin  // lowest offset from rr wins
            cand = rr + i[1:0];                 // 2-bit add wraps mod 4
            if (ln_valid[cand]) begin any = 1'b1; sel = cand; end
        end
    end

    // Explicit muxes: a variable index like mac[48*sel +: 48] synthesizes to a
    // hardware multiplier on ECP5, which was the slowest element on this path.
    reg [47:0] ln_sel_mac, lk_scan_mac;
    always @(*) begin
        case (sel)
            2'd0:    ln_sel_mac = ln_mac[47:0];
            2'd1:    ln_sel_mac = ln_mac[95:48];
            2'd2:    ln_sel_mac = ln_mac[143:96];
            default: ln_sel_mac = ln_mac[191:144];
        endcase
        case (scan)
            2'd0:    lk_scan_mac = lk_mac[47:0];
            2'd1:    lk_scan_mac = lk_mac[95:48];
            2'd2:    lk_scan_mac = lk_mac[143:96];
            default: lk_scan_mac = lk_mac[191:144];
        endcase
    end

    reg        a_learn, a_look;
    reg        b_learn, b_look;
    wire       take_learn = any && !a_learn && !b_learn;
    assign     ln_ack = take_learn ? (4'b0001 << sel) : 4'b0000;

    reg [47:0] a_mac;
    reg [1:0]  a_port;

    // ---------------- stage A: compare ----------------
    reg [N-1:0] match;
    integer k;
    always @(*)
        for (k = 0; k < N; k = k + 1)
            match[k] = v[k] && (mac[k] == a_mac);

    reg [N-1:0] b_match;
    reg [47:0]  b_mac;
    reg [1:0]   b_port;

    // ---------------- stage B: commit ----------------
    wire       b_hit = |b_match;
    reg [1:0]  b_prt;
    integer m;
    always @(*) begin
        b_prt = 2'd0;
        for (m = 0; m < N; m = m + 1)
            if (b_match[m]) b_prt = b_prt | prt[m];
    end

`ifndef BUG_NO_LEARN
    wire learn_now = b_learn;
`else
    wire learn_now = 1'b0;               // BUG: nothing is ever learned
`endif
    wire insert = learn_now && !b_hit;

    integer w;
    always @(posedge clk) begin
        if (insert) begin
            mac[victim] <= b_mac;
            prt[victim] <= b_port;
        end
`ifndef BUG_NO_MOVE
        if (learn_now)
            for (w = 0; w < N; w = w + 1)
                if (b_match[w]) prt[w] <= b_port;   // station moved: update its port
`endif
    end

    integer p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v <= 0; victim <= 0; rr <= 0; scan <= 0;
            a_learn <= 0; a_look <= 0; a_mac <= 0; a_port <= 0;
            b_learn <= 0; b_look <= 0; b_mac <= 0; b_port <= 0; b_match <= 0;
            lk_valid <= 0; lk_hit <= 0; lk_port <= 0;
        end else begin
            // S -> A
            a_learn <= take_learn;
            a_look  <= !take_learn && lk_en[scan];
            if (take_learn) begin
                a_mac  <= ln_sel_mac;
                a_port <= sel;
                rr     <= sel + 1'b1;
            end else begin
                a_mac  <= lk_scan_mac;
                a_port <= scan;
                scan   <= scan + 1'b1;
            end

            // A -> B (a lookup whose requester dropped lk_en is discarded)
            b_learn <= a_learn;
            b_look  <= a_look && lk_en[a_port];
            b_mac   <= a_mac;
            b_port  <= a_port;
            b_match <= match;

            // B: results
            for (p = 0; p < 4; p = p + 1)
                if (!lk_en[p])
                    lk_valid[p] <= 1'b0;
                else if (b_look && b_port == p[1:0]) begin
                    lk_valid[p]       <= 1'b1;
                    lk_hit[p]         <= b_hit;
                    lk_port[2*p +: 2] <= b_prt;
                end

            // B: new entry
            if (insert) begin
                v[victim] <= 1'b1;
                victim    <= victim + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
