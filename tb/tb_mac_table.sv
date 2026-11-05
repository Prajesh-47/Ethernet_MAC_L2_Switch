// -----------------------------------------------------------------------------
// tb_mac_table.sv -- unit test for rtl/mac_table.v (milestone 5)
//
// SPEC the model is written from (not from the RTL):
//   - a learned address is found by every lookup port, with the port it was
//     last learned on (a station that moves gets its new port)
//   - an address never learned (or evicted) misses
//   - the table holds 16 addresses; a 17th evicts the OLDEST one inserted
//     (updating an existing address does not make it "newer")
//   - lookups: lk_valid rises within LOOK_LIMIT cycles of lk_en, stays up while
//     lk_en stays up, falls the cycle after lk_en falls, and never reports the
//     previous address after lk_en has dropped for an address change
//   - freshness: a result may lag the table by at most FRESH cycles. Inside that
//     window after an address changed, either answer is accepted; outside it the
//     result must match the model exactly
//   - learn arbiter: at most one grant per cycle, only to a requester, and
//     a waiting requester is granted within LEARN_LIMIT cycles (no starvation)
//
// DRIVER : 4 learn requesters, each holding a request until granted, picking
//          addresses from a pool of 24 (more than 16, so evictions happen),
//          on random ports (so stations move). 4 lookup ports that hold an
//          address for a random time, then drop lk_en for a cycle and change it.
// MODEL  : an associative array  address -> port  plus a queue of addresses
//          in insertion order (the eviction order).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_mac_table;
    localparam N = 16, POOL = 24;
    localparam LOOK_LIMIT = 10, LEARN_LIMIT = 12, FRESH = 12;
    logic clk = 0, rst_n = 0;
    always #3.2 clk = ~clk;

    logic [47:0] lk [4];                          // lookup addresses, one per port
    logic [47:0] lnm[4];                          // learn addresses
    logic [3:0]  ln_valid = 0, lk_en = 0;
    wire  [191:0] lk_mac = {lk[3],  lk[2],  lk[1],  lk[0]};
    wire  [191:0] ln_mac = {lnm[3], lnm[2], lnm[1], lnm[0]};
    wire  [3:0]  lk_valid, lk_hit, ln_ack;
    wire  [7:0]  lk_port;

    mac_table #(.N(N)) dut (.clk(clk), .rst_n(rst_n),
        .lk_en(lk_en), .lk_mac(lk_mac), .lk_valid(lk_valid), .lk_hit(lk_hit), .lk_port(lk_port),
        .ln_valid(ln_valid), .ln_mac(ln_mac), .ln_ack(ln_ack));

    // ---------------- reference model ----------------
    bit [1:0]  mport [bit [47:0]];                // address -> port
    int        changed [bit [47:0]];              // address -> cycle it last changed
    bit [47:0] order[$];                          // insertion order, oldest first
    bit [47:0] pool [POOL];

    int errors = 0, cycles = 0, n_hit = 0, n_miss = 0, n_flux = 0, n_new = 0, n_move = 0, n_refresh = 0, n_evict = 0;
    int n_contend = 0, n_all4 = 0, max_wait = 0, max_look = 0, n_addr = 0;
    int waitc[4] = '{0, 0, 0, 0}, lookc[4] = '{0, 0, 0, 0}, hold[4] = '{0, 0, 0, 0};
    bit [3:0] granted = 0, p_en = 0, p_valid = 0;
    int req_pct = 0;

    function automatic void model_learn(int p, bit [47:0] m);
        if (mport.exists(m)) begin
            if (mport[m] != p) begin n_move++; changed[m] = cycles; end else n_refresh++;
            mport[m] = p;
        end else begin
            if (order.size() == N) begin
                bit [47:0] old = order.pop_front();
                mport.delete(old); changed[old] = cycles; n_evict++;
            end
            order.push_back(m); mport[m] = p; changed[m] = cycles; n_new++;
        end
    endfunction

    function automatic bit in_flux(bit [47:0] m);
        return changed.exists(m) && (cycles - changed[m] <= FRESH);
    endfunction

    // ---------------- checker (posedge: compare, then update the model) ----------------
    always @(posedge clk) if (rst_n) begin
        cycles++;
        for (int p = 0; p < 4; p++) begin
            if (!p_en[p] && lk_valid[p]) begin
                errors++; if (errors < 10) $display("ERROR: port %0d lk_valid high the cycle after lk_en was low", p);
            end
            if (p_en[p] && p_valid[p] && lk_en[p] && !lk_valid[p]) begin
                errors++; if (errors < 10) $display("ERROR: port %0d lk_valid fell while lk_en stayed high", p);
            end
            if (lk_en[p] && !lk_valid[p]) begin
                lookc[p]++;
                if (lookc[p] > max_look) max_look = lookc[p];
                if (lookc[p] == LOOK_LIMIT) begin errors++; $display("ERROR: port %0d waited %0d cycles for a lookup", p, LOOK_LIMIT); end
            end else lookc[p] = 0;

            if (lk_en[p] && lk_valid[p]) begin
                if (in_flux(lk[p])) n_flux++;
                else begin
                    bit eh = mport.exists(lk[p]);
                    bit [1:0] ep = 0;
                    if (eh) ep = mport[lk[p]];    // read ONLY after exists(): a read of a missing key creates it
                    if (lk_hit[p] != eh) begin
                        errors++; if (errors < 10) $display("ERROR: lookup port %0d addr %h: hit %0b, expected %0b", p, lk[p], lk_hit[p], eh);
                    end else if (eh && lk_port[2*p +: 2] != ep) begin
                        errors++; if (errors < 10) $display("ERROR: lookup port %0d addr %h: port %0d, expected %0d", p, lk[p], lk_port[2*p +: 2], ep);
                    end
                    if (eh) n_hit++; else n_miss++;
                end
            end
        end
        p_en = lk_en; p_valid = lk_valid;

        // arbiter rules
        if ((ln_ack & ~ln_valid) != 0 || $countones(ln_ack) > 1) begin
            errors++; if (errors < 10) $display("ERROR: requests %b got grants %b", ln_valid, ln_ack);
        end
        if ($countones(ln_valid) > 1) n_contend++;
        if (ln_valid == 4'hF) n_all4++;
        for (int p = 0; p < 4; p++) begin
            if (ln_valid[p] && !ln_ack[p]) begin
                waitc[p]++;
                if (waitc[p] > max_wait) max_wait = waitc[p];
                if (waitc[p] == LEARN_LIMIT) begin errors++; $display("ERROR: port %0d starved for %0d cycles", p, LEARN_LIMIT); end
            end else waitc[p] = 0;
        end
        for (int p = 0; p < 4; p++) if (ln_ack[p]) model_learn(p, lnm[p]);
        granted = ln_ack;
    end

    function automatic logic [47:0] pick_addr();
        int r = $urandom_range(0, 99);
        if      (r < 75) return pool[$urandom_range(0, POOL - 1)];    // a known station (maybe evicted)
        else if (r < 90) return {$urandom(), 16'($urandom())};        // a stranger
        else             return 48'hFFFF_FFFF_FFFF;                   // broadcast: never learned
    endfunction

    // ---------------- driver (negedge) ----------------
    always @(negedge clk) begin
        for (int p = 0; p < 4; p++) begin
            if (!rst_n) begin ln_valid[p] = 0; lk_en[p] = 0; end
            else begin
                if (!ln_valid[p] || granted[p]) begin      // free to issue a new request
                    if ($urandom_range(0, 99) < req_pct) begin ln_valid[p] = 1; lnm[p] = pool[$urandom_range(0, POOL - 1)]; end
                    else ln_valid[p] = 0;
                end
                if (!lk_en[p]) begin
                    if ($urandom_range(0, 99) < 80) lk_en[p] = 1;
                end else if (lk_valid[p]) begin
                    if (hold[p] == 0) begin                // same move as a new head frame
                        lk_en[p] = 0; lk[p] = pick_addr(); n_addr++;
                        // mostly short, sometimes long enough to outlast the freshness
                        // window: a frame can wait a long time, and its result must follow the table
                        hold[p] = ($urandom_range(0, 99) < 15) ? $urandom_range(20, 300) : $urandom_range(0, 7);
                    end else hold[p]--;
                end
            end
        end
    end

    initial begin
        for (int i = 0; i < POOL; i++) pool[i] = {16'h0200, 8'(i), 24'($urandom())};   // unicast, all distinct
        for (int p = 0; p < 4; p++) begin lk[p] = pick_addr(); lnm[p] = 0; end
        repeat (5) @(posedge clk); rst_n = 1;
        req_pct = 100; repeat (2000)  @(posedge clk);   // all four ports learning as fast as they can
        req_pct = 2;   repeat (30000) @(posedge clk);   // light random learning
        req_pct = 0;   repeat (200)   @(posedge clk);   // lookups only, table frozen

        if (n_hit == 0 || n_miss == 0 || n_move == 0 || n_evict == 0 || n_all4 == 0) begin
            errors++; $display("ERROR: coverage hole (hit %0d miss %0d move %0d evict %0d all4 %0d)", n_hit, n_miss, n_move, n_evict, n_all4);
        end
        if (n_hit + n_miss < 5 * n_flux) begin
            errors++; $display("ERROR: too few strict checks: %0d against %0d inside the freshness window", n_hit + n_miss, n_flux);
        end
        $display("cycles %0d, %0d addresses looked up, results checked %0d: hit %0d, miss %0d (%0d inside the %0d-cycle freshness window)",
                 cycles, n_addr, n_hit + n_miss, n_hit, n_miss, n_flux, FRESH);
        $display("learns: new %0d, moved %0d, refreshed %0d, evicted %0d", n_new, n_move, n_refresh, n_evict);
        $display("arbiter: %0d contended cycles (%0d with all 4), longest wait %0d cycles (limit %0d)", n_contend, n_all4, max_wait, LEARN_LIMIT);
        $display("lookups: longest wait for a result %0d cycles (limit %0d)", max_look, LOOK_LIMIT);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
