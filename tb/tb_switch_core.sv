// -----------------------------------------------------------------------------
// tb_switch_core.sv -- unit test for rtl/switch_core.v (milestone 6)
//
// The core is tested alone: the 4 ingress buffers, the MAC table and the 4
// TX FIFOs are replaced by testbench stand-ins, so every corner can be forced.
//
// INGRESS STUBS : each holds a queue of frames. The head frame's descriptor
//                 (dst) and the table's answer for it (hit, port) are shown
//                 together, like the real buffer + table. When the core
//                 raises xfer, the stub streams bytes (with random gaps that
//                 obey AXI-Stream). On drop it discards the head.
// EGRESS STUBS  : model a TX FIFO: occupancy goes up on each accepted byte
//                 and drains at a random ~125 MHz-ish rate; eg_empty = 0 bytes.
//                 tready is random (backpressure).
// SPEC MODEL    : per frame, from the forwarding rules alone:
//                   dst multicast/broadcast, or table miss -> all ports but its own
//                   table hit on another port              -> that port
//                   table hit on its own port              -> nothing (filtered)
//                 Every copy is queued per (ingress, egress) pair.
// CHECKS        : every egress frame is the next expected one for its pair,
//                 byte for byte; AXI-Stream on every egress (valid held, data
//                 stable until ready); a frame starts only into an EMPTY FIFO;
//                 every ingress is served within 20000 cycles (liveness); the
//                 stat_flood / stat_filter pulse counts; all queues drain.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_switch_core;
    logic clk = 0, rst_n = 0;
    always #3.2 clk = ~clk;

    // core ports
    logic [3:0]   head_valid = 0, lk_valid = 0, lk_hit = 0, in_tvalid = 0, in_tlast = 0, eg_empty = 4'hF, eg_tready = 0;
    logic [191:0] head_dst = 0;
    logic [7:0]   lk_port = 0;
    logic [31:0]  in_tdata = 0;
    wire  [3:0]   xfer, drop, in_tready, eg_tvalid, eg_tlast, stat_flood, stat_filter;
    wire  [31:0]  eg_tdata;

    switch_core dut (.clk(clk), .rst_n(rst_n),
        .head_valid(head_valid), .head_dst(head_dst), .lk_valid(lk_valid), .lk_hit(lk_hit), .lk_port(lk_port),
        .xfer(xfer), .drop(drop), .in_tdata(in_tdata), .in_tvalid(in_tvalid), .in_tlast(in_tlast), .in_tready(in_tready),
        .eg_empty(eg_empty), .eg_tdata(eg_tdata), .eg_tvalid(eg_tvalid), .eg_tlast(eg_tlast), .eg_tready(eg_tready),
        .stat_flood(stat_flood), .stat_filter(stat_filter));

    // ---------------- frames ----------------
    class sfrm;
        byte unsigned d[$];       // d[0..5] dst, d[6] ingress port, d[7..8] sequence number
        logic [47:0]  dst;
        bit           hit; bit [1:0] port;
        bit [3:0]     mask;       // expected destination set
    endclass
    class efrm; byte unsigned d[$]; endclass

    sfrm srcq [4][$];             // frames waiting in each ingress stub
    efrm expq [4][4][$];          // [ingress][egress] expected copies, in order
    int  errors = 0, seq = 0, n_frames = 0, n_copies = 0, n_got = 0;
    int  exp_flood = 0, exp_filter = 0, got_flood = 0, got_filter = 0;
    int  gap_pct = 20, ready_pct = 80, drain_pct = 80;

    function automatic void make(int i, int kind, int len);
        sfrm f = new();
        int  r;
        // destination + what the table says about it
        case (kind)
            0: begin f.port = 2'($urandom_range(0, 3)); if (f.port == i) f.port = f.port + 1; f.hit = 1; end   // unicast, known, other port
            1: begin f.port = i[1:0]; f.hit = 1; end                                                         // known, SAME port -> filter
            2: begin f.port = 2'($urandom_range(0, 3)); f.hit = 0; end                                       // unknown -> flood
            3: begin f.port = 2'($urandom_range(0, 3)); f.hit = 0; end                                       // broadcast
            default: begin f.port = 2'($urandom_range(0, 3)); f.hit = 1; end                                 // multicast (flood even on a hit)
        endcase
        if      (kind == 3) f.dst = 48'hFFFF_FFFF_FFFF;
        else if (kind == 4) f.dst = {8'h01, 8'h00, 8'h5E, 24'($urandom())};                                  // multicast bit set
        else                f.dst = {8'h02, 8'h00, 8'h00, 8'h00, 6'h00, f.port, 8'($urandom())};
        f.d = {};
        for (int b = 5; b >= 0; b--) f.d.push_back(f.dst[8*b +: 8]);
        f.d.push_back(8'(i)); f.d.push_back(8'(seq >> 8)); f.d.push_back(8'(seq)); seq++;
        while (f.d.size() < len) f.d.push_back(8'($urandom()));
        // spec model
        if (f.dst[40] || !f.hit)  f.mask = 4'hF & ~(4'b1 << i);
        else if (f.port == i)     f.mask = 4'b0000;
        else                      f.mask = 4'b1 << f.port;
        if (f.mask == 0) exp_filter++;
        else if (f.dst[40] || !f.hit) exp_flood++;
        for (int e = 0; e < 4; e++) if (f.mask[e]) begin
            efrm x = new(); x.d = f.d; expq[i][e].push_back(x); n_copies++;
        end
        srcq[i].push_back(f); n_frames++;
    endfunction

    // ---------------- ingress stubs ----------------
    sfrm cur [4];
    bit  have [4] = '{0, 0, 0, 0};
    int  idx [4]  = '{0, 0, 0, 0};
    int  lk_delay [4] = '{0, 0, 0, 0};
    bit  took [4] = '{0, 0, 0, 0}, gone [4] = '{0, 0, 0, 0};
    int  waitc [4] = '{0, 0, 0, 0};
    int  max_wait = 0;

    always @(posedge clk) if (rst_n) begin          // what happened at this edge
        for (int i = 0; i < 4; i++) begin
            if (in_tvalid[i] && in_tready[i]) begin
                took[i] = 1;
                if (in_tlast[i]) gone[i] = 1;
            end
            if (drop[i]) begin
                gone[i] = 1;
                if (cur[i].mask != 0) begin errors++; $display("ERROR: ingress %0d dropped a frame that should go to %b", i, cur[i].mask); end
            end
            // liveness: a head frame must be started (or dropped) in bounded time
            if (have[i] && !xfer[i] && !gone[i]) begin
                waitc[i]++;
                if (waitc[i] > max_wait) max_wait = waitc[i];
                if (waitc[i] == 20000) begin errors++; $display("ERROR: ingress %0d starved for 20000 cycles", i); end
            end else waitc[i] = 0;
        end
        got_flood  += $countones(stat_flood);
        got_filter += $countones(stat_filter);
    end

    always @(negedge clk) begin
        for (int i = 0; i < 4; i++) begin
            if (gone[i]) begin
                have[i] = 0; head_valid[i] = 0; lk_valid[i] = 0; in_tvalid[i] = 0; in_tlast[i] = 0; gone[i] = 0; took[i] = 0;
            end
            if (took[i]) begin idx[i]++; in_tvalid[i] = 0; took[i] = 0; end
            if (!have[i] && srcq[i].size() != 0 && rst_n && $urandom_range(0, 99) < 70) begin
                cur[i] = srcq[i].pop_front(); have[i] = 1; idx[i] = 0;
                head_valid[i] = 1; head_dst[48*i +: 48] = cur[i].dst;
                // the table answers a few cycles later; until then its outputs are
                // garbage, which the core must not act on
                lk_hit[i] = 1'($urandom()); lk_port[2*i +: 2] = 2'($urandom());
                lk_delay[i] = $urandom_range(0, 9);
            end
            if (have[i] && !lk_valid[i]) begin
                if (lk_delay[i] == 0) begin
                    lk_valid[i] = 1; lk_hit[i] = cur[i].hit; lk_port[2*i +: 2] = cur[i].port;
                end else lk_delay[i]--;
            end
            // stream: once tvalid is up it stays up until taken (AXI-Stream rule)
            if (have[i] && xfer[i] && !in_tvalid[i] && $urandom_range(0, 99) >= gap_pct) begin
                in_tvalid[i] = 1; in_tdata[8*i +: 8] = cur[i].d[idx[i]]; in_tlast[i] = (idx[i] == cur[i].d.size() - 1);
            end
        end
    end

    // ---------------- egress stubs + scoreboard ----------------
    int  occ [4] = '{0, 0, 0, 0};
    byte unsigned rx [4][$];
    bit  pv [4] = '{0, 0, 0, 0}, pr [4] = '{0, 0, 0, 0}, plast [4] = '{0, 0, 0, 0};
    byte unsigned pd [4];
    int  n_axi = 0, n_fork = 0, n_par = 0, n_contend = 0;

    always @(posedge clk) if (rst_n) begin
        int owners;
        for (int e = 0; e < 4; e++) begin
            // AXI-Stream: if valid was high without ready, it must still be high with the same data
            if (pv[e] && !pr[e] && (!eg_tvalid[e] || eg_tdata[8*e +: 8] != pd[e] || eg_tlast[e] != plast[e])) begin
                n_axi++; errors++;
                if (n_axi <= 3) $display("ERROR: egress %0d dropped or changed tvalid/tdata before tready (AXI-Stream violation) at %0t", e, $time);
            end
            pv[e] = eg_tvalid[e]; pr[e] = eg_tready[e]; pd[e] = eg_tdata[8*e +: 8]; plast[e] = eg_tlast[e];

            if (eg_tvalid[e] && eg_tready[e]) begin
                if (rx[e].size() == 0 && occ[e] != 0) begin errors++; $display("ERROR: egress %0d: frame started into a non-empty FIFO (%0d bytes)", e, occ[e]); end
                rx[e].push_back(eg_tdata[8*e +: 8]); occ[e]++;
                if (eg_tlast[e]) begin check(e); rx[e] = {}; end
            end
            if (occ[e] > 0 && $urandom_range(0, 99) < drain_pct) occ[e]--;
        end
        // coverage: forks, parallel transfers, contention
        for (int i = 0; i < 4; i++) if (xfer[i] && $countones(dut.xmask[i]) > 1) n_fork++;
        owners = 0; for (int i = 0; i < 4; i++) if (xfer[i]) owners++;
        if (owners >= 2) n_par++;
        for (int e = 0; e < 4; e++) begin
            int c = 0;
            for (int i = 0; i < 4; i++) if (dut.req[i] && dut.mask[i][e]) c++;
            if (c >= 2) n_contend++;
        end
    end

    always @(negedge clk) for (int e = 0; e < 4; e++) begin
        eg_empty[e]  = (occ[e] == 0);
        eg_tready[e] = rst_n && occ[e] < 32 && ($urandom_range(0, 99) < ready_pct);
    end

    function automatic void check(int e);
        int  i = rx[e][6];
        efrm x;
        if (i > 3 || expq[i][e].size() == 0) begin
            errors++; if (errors < 10) $display("ERROR: egress %0d got an unexpected frame (claims ingress %0d)", e, i); return;
        end
        x = expq[i][e].pop_front(); n_got++;
        if (x.d.size() != rx[e].size()) begin
            errors++; if (errors < 10) $display("ERROR: %0d->%0d frame length %0d, expected %0d", i, e, rx[e].size(), x.d.size()); return;
        end
        foreach (x.d[b]) if (x.d[b] != rx[e][b]) begin
            errors++; if (errors < 10) $display("ERROR: %0d->%0d byte %0d = %h, expected %h", i, e, b, rx[e][b], x.d[b]); return;
        end
    endfunction

    // ---------------- test sequence ----------------
    function automatic int pending();
        int n = 0;
        for (int i = 0; i < 4; i++) begin n += srcq[i].size() + have[i]; for (int e = 0; e < 4; e++) n += expq[i][e].size(); end
        return n;
    endfunction
    task automatic run_until_empty(string phase);
        int t = 0, left = pending();     // (a function call in the while condition is not re-evaluated by Verilator 5.020)
        while (left != 0 && t < 3000000 && errors == 0) begin @(posedge clk); t++; left = pending(); end   // stop at the first error
        if (pending() != 0) begin errors++; $display("ERROR: %s: %0d frames/copies still pending after %0d cycles (deadlock?)", phase, pending(), t); end
        repeat (20) @(posedge clk);
    endtask

    initial begin
        repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);

        // 1. one of each kind from every port, minimum and maximum sizes
        for (int i = 0; i < 4; i++) for (int k = 0; k < 5; k++) begin make(i, k, 14); make(i, k, 1514); end
        run_until_empty("directed");

        // 2. random mix, light backpressure
        for (int n = 0; n < 400; n++) for (int i = 0; i < 4; i++) begin
            int r = $urandom_range(0, 99), len = ($urandom_range(0, 9) == 0) ? $urandom_range(500, 1514) : $urandom_range(14, 200);
            make(i, r < 45 ? 0 : r < 60 ? 1 : r < 75 ? 2 : r < 90 ? 3 : 4, len);
        end
        run_until_empty("random");

        // 3. overload: flood-heavy, no gaps, slow and stalling egress ports
        gap_pct = 0; ready_pct = 50; drain_pct = 60;
        for (int n = 0; n < 300; n++) for (int i = 0; i < 4; i++) begin
            int r = $urandom_range(0, 99);
            make(i, r < 30 ? 0 : r < 40 ? 1 : r < 70 ? 2 : 3, $urandom_range(14, 120));
        end
        run_until_empty("overload");

        if (got_flood != exp_flood || got_filter != exp_filter) begin
            errors++; $display("ERROR: stat_flood %0d (exp %0d), stat_filter %0d (exp %0d)", got_flood, exp_flood, got_filter, exp_filter);
        end
        if (n_fork == 0 || n_par == 0 || n_contend == 0) begin errors++; $display("ERROR: coverage hole (fork %0d, parallel %0d, contention %0d)", n_fork, n_par, n_contend); end
        $display("frames %0d -> %0d copies expected, %0d delivered  (flooded %0d, filtered %0d)", n_frames, n_copies, n_got, got_flood, got_filter);
        $display("coverage: fork cycles %0d, parallel-transfer cycles %0d, contended cycles %0d", n_fork, n_par, n_contend);
        $display("longest wait for an ingress to start: %0d cycles (limit 20000); AXI violations %0d", max_wait, n_axi);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
