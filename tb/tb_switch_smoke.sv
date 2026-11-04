// -----------------------------------------------------------------------------
// tb_switch_smoke.sv -- first test of the whole 4-port switch (milestone 6)
//
// Directed, step by step, through real GMII on all 4 ports. Each step sends
// one frame (or two at once), waits, then checks EXACTLY which ports put it
// out -- and that every copy has a correct preamble, FCS and content.
//
//   1  A (port 0) broadcasts           -> ports 1,2,3   (A learned on 0)
//   2  B (port 2) -> A                 -> port 0 only   (B learned on 2)
//   3  A -> B                          -> port 2 only
//   4  C (port 1) -> unknown address   -> ports 0,2,3   (flood)
//   5  A2 (port 0) -> A                -> nowhere       (A is on port 0: filtered)
//   6  D (port 3) broadcasts, BAD CRC  -> nowhere       (dropped, D NOT learned)
//   7  A -> D                          -> ports 1,2,3   (D unknown: proves step 6)
//   8  A moves: A broadcasts on port 3 -> ports 0,1,2
//   9  B -> A                          -> port 3 only   (table followed the move)
//  10  C -> B and A -> B at once       -> both arrive on port 2, one after the other
//
// (The big randomized test with independent clocks is milestone 7.)
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_switch_smoke;
    logic sys_clk = 0; always #3.2 sys_clk = ~sys_clk;              // 156.25 MHz
    logic gtx_clk = 0; always #4.0 gtx_clk = ~gtx_clk;              // 125 MHz transmit
    logic rclk = 0;    initial begin #1.3; forever #4.0 rclk = ~rclk; end   // 125 MHz receive, other phase
    logic rst_n = 0;

    logic [31:0] rxd = 0; logic [3:0] rx_dv = 0, rx_er = 0;
    wire  [31:0] txd;     wire  [3:0] tx_en, tx_er;
    wire  [3:0] s_rx_good, s_rx_bad, s_underrun, s_tx_frame, s_drop, s_flood, s_filter;

    eth_switch_4port dut (
        .sys_clk(sys_clk), .rst_n(rst_n),
        .gmii_rx_clk({4{rclk}}), .gmii_rxd(rxd), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .gmii_tx_clk({4{gtx_clk}}), .gmii_txd(txd), .gmii_tx_en(tx_en), .gmii_tx_er(tx_er),
        .stat_rx_good(s_rx_good), .stat_rx_bad(s_rx_bad), .stat_tx_underrun(s_underrun),
        .stat_tx_frame(s_tx_frame), .stat_ingress_drop(s_drop), .stat_flood(s_flood), .stat_filter(s_filter));

    function automatic logic [31:0] crc_ref(input byte unsigned d[$]);
        logic [31:0] c = 32'hFFFFFFFF;
        foreach (d[i]) for (int b = 0; b < 8; b++) begin
            logic fb = c[0] ^ d[i][b];
            c = c >> 1;
            if (fb) c = c ^ 32'hEDB88320;
        end
        return ~c;
    endfunction

    localparam logic [47:0] A = 48'h0200_0000_000A, A2 = 48'h0200_0000_00A2, B = 48'h0200_0000_000B,
                            C = 48'h0200_0000_000C, D = 48'h0200_0000_000D, UNK = 48'h0200_0000_0099,
                            BCAST = 48'hFFFF_FFFF_FFFF;

    class frm; byte unsigned d[$]; endclass
    frm rxq [4][$];                               // frames seen on each egress (no preamble, no FCS)
    int errors = 0, nstep = 0;

    function automatic frm make(logic [47:0] dst, logic [47:0] src, int payload);
        frm f = new();
        f.d = {};
        for (int i = 5; i >= 0; i--) f.d.push_back(dst[8*i +: 8]);
        for (int i = 5; i >= 0; i--) f.d.push_back(src[8*i +: 8]);
        f.d.push_back(8'h08); f.d.push_back(8'h00);                   // EtherType IPv4
        for (int i = 0; i < payload; i++) f.d.push_back(8'($urandom()));
        return f;
    endfunction

    // ---------------- driver: one frame onto port p's GMII receive side ----------------
    task automatic drive(int p, frm f, bit bad_crc = 0);
        byte unsigned q[$]; logic [31:0] fcs;
        q = f.d;
        fcs = crc_ref(q);
        if (bad_crc) fcs = fcs ^ 32'h1;
        q.push_back(fcs[7:0]); q.push_back(fcs[15:8]); q.push_back(fcs[23:16]); q.push_back(fcs[31:24]);
        @(negedge rclk);
        for (int i = 0; i < 7; i++) begin rx_dv[p] = 1; rxd[8*p +: 8] = 8'h55; @(negedge rclk); end
        rxd[8*p +: 8] = 8'hD5; @(negedge rclk);
        foreach (q[i]) begin rxd[8*p +: 8] = q[i]; @(negedge rclk); end
        rx_dv[p] = 0; rxd[8*p +: 8] = 0;
        repeat (12) @(negedge rclk);
    endtask

    // ---------------- monitors: parse each port's GMII transmit side ----------------
    task automatic monitor(int e);
        byte unsigned w[$];
        forever begin
            @(posedge gtx_clk);
            if (tx_er[e]) begin errors++; $display("ERROR: port %0d tx_er", e); end
            if (tx_en[e]) begin
                frm f = new();
                logic [31:0] fcs;
                w = {};
                while (tx_en[e]) begin w.push_back(txd[8*e +: 8]); @(posedge gtx_clk); end
                for (int i = 0; i < 7; i++) if (w[i] != 8'h55) begin errors++; $display("ERROR: port %0d bad preamble", e); end
                if (w[7] != 8'hD5) begin errors++; $display("ERROR: port %0d bad SFD", e); end
                f.d = {};
                for (int i = 8; i < w.size() - 4; i++) f.d.push_back(w[i]);
                fcs = {w[w.size()-1], w[w.size()-2], w[w.size()-3], w[w.size()-4]};
                if (fcs != crc_ref(f.d)) begin errors++; $display("ERROR: port %0d bad FCS", e); end
                rxq[e].push_back(f);
            end
        end
    endtask

    // ---------------- check: exactly the ports in `mask` received exactly these frames ----------------
    function automatic bit same(frm x, frm y);
        if (x.d.size() != y.d.size()) return 0;
        foreach (x.d[i]) if (x.d[i] != y.d[i]) return 0;
        return 1;
    endfunction

    // g is an optional second frame sent at the same time; the switch may
    // deliver the two in either order (that is the arbiter's choice)
    task automatic expect_out(string what, logic [3:0] mask, frm f, frm g = null);
        string got = "";
        bit ok = 1;
        repeat (3000) @(posedge sys_clk);                        // ~19 us: plenty for these frames
        nstep++;
        for (int e = 0; e < 4; e++) begin
            if (rxq[e].size() != 0) got = {got, $sformatf("%0d ", e)};
            if (!mask[e])          ok &= (rxq[e].size() == 0);
            else if (g == null)    ok &= (rxq[e].size() == 1) && same(rxq[e][0], f);
            else                   ok &= (rxq[e].size() == 2) &&
                                         ((same(rxq[e][0], f) && same(rxq[e][1], g)) ||
                                          (same(rxq[e][0], g) && same(rxq[e][1], f)));
            rxq[e] = {};
        end
        if (got == "") got = "none ";
        if (!ok) begin
            string want = "";
            for (int e = 0; e < 4; e++) if (mask[e]) want = {want, $sformatf("%0d ", e)};
            if (want == "") want = "none ";
            errors++; $display("step %2d  %-46s out on: %s <-- WRONG (expected %s)", nstep, what, got, want);
        end
        else     $display("step %2d  %-46s out on: %s OK", nstep, what, got);
    endtask

    int n_flood = 0, n_filter = 0, n_bad = 0;
    always @(posedge sys_clk) begin n_flood += $countones(s_flood); n_filter += $countones(s_filter); end
    always @(posedge rclk) n_bad += $countones(s_rx_bad);
    always @(posedge gtx_clk) if (|s_underrun) begin errors++; $display("ERROR: TX underrun"); end

    initial begin
        frm f, g;
        fork monitor(0); monitor(1); monitor(2); monitor(3); join_none   // (no fork inside a loop: Verilator 5.020)
        repeat (10) @(posedge sys_clk); rst_n = 1; repeat (50) @(posedge sys_clk);

        f = make(BCAST, A, 46);  drive(0, f);       expect_out("A (port 0) broadcast",           4'b1110, f);
        f = make(A, B, 46);      drive(2, f);       expect_out("B (port 2) -> A",                4'b0001, f);
        f = make(B, A, 100);     drive(0, f);       expect_out("A -> B",                         4'b0100, f);
        f = make(UNK, C, 46);    drive(1, f);       expect_out("C (port 1) -> unknown address",  4'b1101, f);
        f = make(A, A2, 46);     drive(0, f);       expect_out("A2 (port 0) -> A  [filtered]",   4'b0000, f);
        f = make(BCAST, D, 46);  drive(3, f, 1);    expect_out("D (port 3) broadcast, BAD CRC",  4'b0000, f);
        f = make(D, A, 46);      drive(0, f);       expect_out("A -> D  [D must still be unknown]", 4'b1110, f);
        f = make(BCAST, A, 46);  drive(3, f);       expect_out("A moves: broadcast from port 3", 4'b0111, f);
        f = make(A, B, 46);      drive(2, f);       expect_out("B -> A  [table followed the move]", 4'b1000, f);
        f = make(B, C, 200); g = make(B, A, 300);
        fork drive(1, f); drive(3, g); join
        expect_out("C -> B and A -> B at the same time", 4'b0100, f, g);

        if (n_flood != 4 || n_filter != 1 || n_bad != 1) begin
            errors++; $display("ERROR: stats flood %0d (exp 4), filter %0d (exp 1), rx bad %0d (exp 1)", n_flood, n_filter, n_bad);
        end
        $display("stats: flooded %0d, filtered %0d, rx bad %0d", n_flood, n_filter, n_bad);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
