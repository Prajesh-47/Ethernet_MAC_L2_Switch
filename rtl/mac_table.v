// -----------------------------------------------------------------------------
// mac_table.v -- MAC learning table, 16 entries, fully associative
//
//   4 lookup ports (one per ingress, combinational): dst MAC -> hit, port
//   1 learn port shared by the 4 ingress buffers, arbitrated round-robin:
//     address already present -> update its port (a station moved)
//     not present              -> write it into the next victim slot
//                                 (round-robin replacement)
// Test-only bug switch: +define+BUG_NO_MOVE (a station that moves keeps its
// old port).
// No aging timer: entries live until replaced. (A real switch ages entries
// out after ~300 s so a silent station's slot can be reused -- see guide.)
// -----------------------------------------------------------------------------
`default_nettype none
module mac_table #(
    parameter N = 16
) (
    input  wire         clk,
    input  wire         rst_n,
    // lookups: 4 x 48-bit address in, hit + port out
    input  wire [191:0] lk_mac,
    output reg  [3:0]   lk_hit,
    output reg  [7:0]   lk_port,
    // learn requests: one per ingress port
    input  wire [3:0]   ln_valid,
    input  wire [191:0] ln_mac,
    output wire [3:0]   ln_ack           // same-cycle acknowledge (requester clears on this edge)
);
    reg        v    [0:N-1];
    reg [47:0] mac  [0:N-1];
    reg [1:0]  prt  [0:N-1];
    reg [$clog2(N)-1:0] victim;
    reg [1:0]  rr;                     // learn arbitration pointer

    // ---------------- lookups ----------------
    integer p, k;
    always @(*) begin
        lk_hit = 4'b0; lk_port = 8'b0;
        for (p = 0; p < 4; p = p + 1)
            for (k = 0; k < N; k = k + 1)
                if (v[k] && mac[k] == lk_mac[48*p +: 48]) begin
                    lk_hit[p] = 1'b1;
                    lk_port[2*p +: 2] = prt[k];
                end
    end

    // ---------------- learn arbitration (round robin) ----------------
    reg [1:0] sel, cand; reg any;
    integer i;
    always @(*) begin
        any = 1'b0; sel = 2'd0;
        for (i = 3; i >= 0; i = i - 1) begin  // lowest offset from rr wins
            cand = rr + i[1:0];                 // 2-bit add wraps mod 4
            if (ln_valid[cand]) begin any = 1'b1; sel = cand; end
        end
    end
    wire [47:0] lmac = ln_mac[48*sel +: 48];
    assign ln_ack = any ? (4'b0001 << sel) : 4'b0000;

    // is the address already in the table?
    reg found; reg [$clog2(N)-1:0] fidx;
    integer m;
    always @(*) begin
        found = 1'b0; fidx = 0;
        for (m = 0; m < N; m = m + 1)
            if (v[m] && mac[m] == lmac) begin found = 1'b1; fidx = m[$clog2(N)-1:0]; end
    end

    integer z;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (z = 0; z < N; z = z + 1) begin v[z] <= 1'b0; mac[z] <= 48'b0; prt[z] <= 2'b0; end
            victim <= 0; rr <= 0;
        end else begin
            if (any) begin
                rr <= sel + 1'b1;
`ifndef BUG_NO_MOVE
                if (found) prt[fidx] <= sel;          // station moved: update its port
`else
                if (found) ;                           // BUG: a moved station keeps its old port
`endif
                else begin
                    v[victim] <= 1'b1; mac[victim] <= lmac; prt[victim] <= sel;
                    victim <= victim + 1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
