// -----------------------------------------------------------------------------
// tb_switch.sv -- full-switch randomized test for eth_switch_4port (milestone 7)
//
// UVM-style structure without the UVM library (runs on Verilator 5):
//   eth_frame   : transaction -- dst, src, type, payload, error kind
//   drivers     : one per port, drive GMII rx (preamble, SFD, bytes, FCS, IFG)
//   monitors    : one per port, parse GMII tx, check FCS / length / IFG / tx_er
//   ref model   : learning table + forwarding rules -> expected frames per
//                 (ingress, egress) queue
//   scoreboard  : every frame seen on egress e must be the next expected frame
//                 from its ingress to e; at the end every queue must be empty
//   coverage    : explicit bins (Verilator 5.020 has no covergroups)
//   protocol    : AXI-Stream check on the internal core -> TX FIFO links
//   liveness    : every requesting ingress starts within 20000 cycles
//
// Phases
//   1 learning : every station sends one broadcast -> table learns 12 stations
//   2 random   : all 4 ports transmit concurrently: unicast, filtered, unknown,
//                broadcast, and bad frames (CRC error, runt, oversized)
//   3 check    : frames to the address that only ever sent BAD frames must
//                flood -- proving bad frames were not learned; then one
//                maximum-size frame from every port
// Every coverage bin must be hit, or the test fails.
//
// Plusargs: +N=<frames per port> (default 300)  +LOAD=<% of line rate> (default 30)
//           +SYS_MHZ=<system clock> (default 156.25)
//   LOAD <= 30 : no-drop mode -- every expected copy must arrive
//   LOAD  > 30 : congestion mode (milestone 8) -- drops allowed, but what does
//                arrive must be intact and in order, nobody may starve, and at
//                least 25% of copies must get through (sanity floor)
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_switch;
    // ---------------- clocks ----------------
    // system clock: +SYS_MHZ=<f>, default 156.25
    logic sys_clk = 0;
    initial begin
        real sys_mhz = 156.25;
        void'($value$plusargs("SYS_MHZ=%f", sys_mhz));
        forever #(500.0 / sys_mhz) sys_clk = ~sys_clk;
    end
    logic gtx_clk = 0; always #4.0 gtx_clk = ~gtx_clk;          // 125 MHz
    // independent rx clocks: same nominal 125 MHz, different phases.
    // Four separate signals, packed with an assign: driving bits of ONE vector
    // from four processes made Verilator 5.020 miss edges inside the DUT.
    logic rc0 = 0, rc1 = 0, rc2 = 0, rc3 = 0;
    initial begin #0.0; forever #4.0 rc0 = ~rc0; end
    initial begin #1.3; forever #4.0 rc1 = ~rc1; end
    initial begin #2.1; forever #4.0 rc2 = ~rc2; end
    initial begin #3.4; forever #4.0 rc3 = ~rc3; end
    wire [3:0] rx_clk = {rc3, rc2, rc1, rc0};
    logic rst_n = 0;

    logic [31:0] rxd = 0; logic [3:0] rx_dv = 0, rx_er = 0;
    wire  [31:0] txd;     wire  [3:0] tx_en, tx_er;
    wire  [3:0] s_rx_good, s_rx_bad, s_underrun, s_tx_frame, s_drop, s_flood, s_filter;

    eth_switch_4port dut (
        .sys_clk(sys_clk), .rst_n(rst_n),
        .gmii_rx_clk(rx_clk), .gmii_rxd(rxd), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .gmii_tx_clk({4{gtx_clk}}), .gmii_txd(txd), .gmii_tx_en(tx_en), .gmii_tx_er(tx_er),
        .stat_rx_good(s_rx_good), .stat_rx_bad(s_rx_bad), .stat_tx_underrun(s_underrun),
        .stat_tx_frame(s_tx_frame), .stat_ingress_drop(s_drop), .stat_flood(s_flood),
        .stat_filter(s_filter));

    // ---------------- independent CRC-32 (bit-serial, not the RTL's form) ----------------
    function automatic logic [31:0] crc_bits(input byte unsigned d[$]);
        logic [31:0] c = 32'hFFFFFFFF;
        foreach (d[i]) for (int b = 0; b < 8; b++) begin
            logic fb = c[0] ^ d[i][b];
            c = c >> 1;
            if (fb) c = c ^ 32'hEDB88320;
        end
        return ~c;
    endfunction

    // ---------------- transaction ----------------
    typedef enum {GOOD, BAD_CRC, RUNT, OVERSIZE} kind_t;
    class eth_frame;
        logic [47:0] dst, src;
        logic [15:0] etype;
        byte unsigned payload[$];
        kind_t kind;
        byte unsigned wire_b[$];                 // frame bytes without FCS
        function void build();
            wire_b = {};
            for (int i = 5; i >= 0; i--) wire_b.push_back(dst[8*i +: 8]);
            for (int i = 5; i >= 0; i--) wire_b.push_back(src[8*i +: 8]);
            wire_b.push_back(etype[15:8]); wire_b.push_back(etype[7:0]);
            foreach (payload[i]) wire_b.push_back(payload[i]);
        endfunction
    endclass
    class exp_frame;                             // an expected frame on one egress port
        byte unsigned d[$];
    endclass

    // ---------------- stations ----------------
    function automatic logic [47:0] station(int port, int s); return {32'h0200_0000, 8'(port), 8'(s)}; endfunction
    localparam logic [47:0] BCAST   = 48'hFFFF_FFFF_FFFF;
    function automatic logic [47:0] unknown_mac(int n);  return {32'h0200_0000, 8'h99, 8'(n)}; endfunction
    function automatic logic [47:0] badonly(int port);    return {32'h0200_0000, 8'(port), 8'h0E}; endfunction

    // ---------------- reference model ----------------
    int model_port [logic [47:0]];          // learned MAC -> port
    exp_frame expq [4][4][$];               // [ingress][egress] queue of expected frames (padded, no FCS)
    int n_expected = 0, n_received = 0, n_dropped = 0, errors = 0;
    int LOAD = 30;                          // offered load per port, % of line rate (+LOAD=)

    function automatic void model_frame(int ing, eth_frame f);
        logic [3:0] mask;
        if (f.kind != GOOD) return;                               // bad frames: dropped, not learned
        f.build();
        if (f.dst[40] || !model_port.exists(f.dst)) mask = 4'hF & ~(4'b1 << ing);
        else if (model_port[f.dst] == ing)          mask = 4'b0;  // filtered
        else                                         mask = 4'b1 << model_port[f.dst];
        for (int e = 0; e < 4; e++) if (mask[e]) begin
            exp_frame x = new();
            x.d = f.wire_b;
            while (x.d.size() < 60) x.d.push_back(8'h00);         // egress pads short frames
            expq[ing][e].push_back(x); n_expected++;
        end
        if (!f.src[40]) model_port[f.src] = ing;                  // learn (after the decision)
    endfunction

    // ---------------- coverage bins ----------------
    int cov_hit[string];
    function automatic void hit(string n); if (!cov_hit.exists(n)) cov_hit[n] = 0; cov_hit[n]++; endfunction

    // ---------------- driver ----------------
    // explicit per-port wait: an event control on rx_clk[p] with a variable p
    // is not re-evaluated correctly by Verilator 5.020
    task automatic wait_rx(int p);
        case (p)
            0: @(negedge rx_clk[0]);
            1: @(negedge rx_clk[1]);
            2: @(negedge rx_clk[2]);
            default: @(negedge rx_clk[3]);
        endcase
    endtask
    task automatic drive(int p, eth_frame f);
        byte unsigned q[$]; logic [31:0] fcs;
        f.build(); q = f.wire_b;
        fcs = crc_bits(q);
        if (f.kind == BAD_CRC) fcs = fcs ^ 32'h0000_0100;
        q.push_back(fcs[7:0]); q.push_back(fcs[15:8]); q.push_back(fcs[23:16]); q.push_back(fcs[31:24]);
        wait_rx(p);
        for (int i = 0; i < 7; i++) begin rx_dv[p] = 1; rxd[8*p +: 8] = 8'h55; wait_rx(p); end
        rxd[8*p +: 8] = 8'hD5; wait_rx(p);
        foreach (q[i]) begin rxd[8*p +: 8] = q[i]; wait_rx(p); end
        rx_dv[p] = 0; rxd[8*p +: 8] = 0;
        // inter-frame gap: 12 minimum, stretched so this port offers LOAD% of line rate
        repeat (12 + $urandom_range(0, 4) + (q.size() + 20) * (100 - LOAD) / LOAD) wait_rx(p);
    endtask

    // ---------------- monitors (one per egress port) ----------------
    int last_end [4];
    task automatic monitor(int e);
        byte unsigned q[$]; int cyc = 0, gap;
        last_end[e] = -100;
        forever begin
            @(posedge gtx_clk); cyc++;
            if (tx_er[e]) begin errors++; $display("ERROR: port %0d: tx_er asserted", e); end
            if (tx_en[e]) begin
                gap = cyc - last_end[e] - 1;
                if (gap < 12) begin errors++; $display("ERROR: port %0d: IFG %0d < 12", e, gap); end
                q = {};
                while (tx_en[e]) begin q.push_back(txd[8*e +: 8]); @(posedge gtx_clk); cyc++; end
                last_end[e] = cyc - 1;
                check_frame(e, q);
            end
        end
    endtask

    function automatic void check_frame(int e, byte unsigned w[$]);
        byte unsigned body[$]; logic [31:0] fcs, calc; logic [47:0] src; int ing;
        // preamble + SFD
        for (int i = 0; i < 7; i++) if (w[i] != 8'h55) begin errors++; $display("ERROR: port %0d: bad preamble", e); return; end
        if (w[7] != 8'hD5) begin errors++; $display("ERROR: port %0d: bad SFD", e); return; end
        body = {};
        for (int i = 8; i < w.size() - 4; i++) body.push_back(w[i]);
        fcs = {w[w.size()-1], w[w.size()-2], w[w.size()-3], w[w.size()-4]};
        calc = crc_bits(body);
        if (fcs != calc) begin errors++; $display("ERROR: port %0d: FCS %h expected %h", e, fcs, calc); return; end
        if (body.size() < 60) begin errors++; $display("ERROR: port %0d: frame shorter than 64", e); return; end
        src = {body[6], body[7], body[8], body[9], body[10], body[11]};
        ing = src[15:8];                                    // stations encode their port
        if (ing > 3) begin errors++; $display("ERROR: port %0d: unexpected source %h", e, src); return; end
        // Received frames must be an ORDERED SUBSEQUENCE of the expected frames
        // for this (ingress, egress) pair: frames may be missing (dropped under
        // congestion) but never corrupted, duplicated or reordered.
        begin
            exp_frame x; bit same = 0;
            while (!same && expq[ing][e].size() != 0) begin
                x = expq[ing][e].pop_front();
                same = (x.d.size() == body.size());
                if (same) foreach (body[i]) if (body[i] != x.d[i]) same = 0;
                if (!same) n_dropped++;
            end
            if (!same) begin
                errors++;
                if (errors < 8) $display("ERROR: port %0d: frame from port %0d (len %0d) matches no expected frame -- corrupt, duplicated or reordered",
                                       e, ing, body.size());
                return;
            end
        end
        n_received++;
        if (body.size() == 60) hit("egress min-size frame (60 B + FCS)");
        if (body.size() >= 1500) hit("egress max-size frame");
    endfunction

    // ---------------- traffic generator ----------------
    function automatic eth_frame make(int p, int mode);
        eth_frame f = new();
        int plen, r = $urandom_range(0, 99);
        f.etype = 16'h0800;
        f.src = station(p, $urandom_range(0, 2));
        f.kind = GOOD;
        // destination
        if      (mode == 1)            f.dst = BCAST;
        else if (r < 60) begin int q = $urandom_range(0, 3); f.dst = station(q, $urandom_range(0, 2)); end
        else if (r < 75)               f.dst = station(p, $urandom_range(0, 2));   // same port -> filtered
        else if (r < 85)               f.dst = unknown_mac($urandom_range(0, 255));
        else                           f.dst = BCAST;
        // length / error kind
        r = $urandom_range(0, 99);
        if      (mode == 1)  plen = 46;
        else if (r < 30)     plen = $urandom_range(0, 45);       // sender pads to 46
        else if (r < 85)     plen = $urandom_range(46, 300);
        else                 plen = $urandom_range(1000, 1500);
        if (mode == 0) begin
            int e = $urandom_range(0, 99);
            if      (e < 6)  f.kind = BAD_CRC;
            else if (e < 9)  begin f.kind = RUNT;     plen = $urandom_range(0, 30); end  // < 64B incl FCS (no padding on rx)
            else if (e < 11) begin f.kind = OVERSIZE; plen = $urandom_range(1501, 1600); end
            if (f.kind != GOOD) f.src = badonly(p);
        end
        for (int i = 0; i < plen; i++) f.payload.push_back(8'($urandom()));
        // A sending MAC pads to the 64-byte minimum; only deliberate runts stay short.
        if (f.kind != RUNT) while (f.payload.size() < 46) f.payload.push_back(8'h00);
        return f;
    endfunction

    task automatic port_traffic(int p, int n);
        for (int i = 0; i < n; i++) begin
            eth_frame f = make(p, 0);
            if (f.kind == GOOD) model_frame(p, f);
            case (f.kind)
                GOOD: begin
                    if (f.dst == BCAST) hit("broadcast");
                    else if (f.dst[15:8] == 8'h99) hit("unknown unicast (flood)");
                    else if (f.dst[15:8] == p) hit("filtered (dst on ingress port)");
                    else hit($sformatf("unicast %0d->%0d", p, f.dst[15:8]));
                    if (f.payload.size() == 46) hit("minimum-size frame (64 B on the wire)");
                end
                BAD_CRC:  hit("bad CRC dropped");
                RUNT:     hit("runt dropped");
                OVERSIZE: hit("oversized dropped");
            endcase
            drive(p, f);
        end
    endtask

    // contention: two or more ingress ports want the same egress in the same cycle
    always @(posedge sys_clk) if (rst_n) begin
        for (int e = 0; e < 4; e++) begin
            int c = 0;
            for (int i = 0; i < 4; i++) if (dut.u_core.req[i] && dut.u_core.mask[i][e]) c++;
            if (c >= 2) hit("egress contention (>=2 requesters)");
        end
        if (|dut.u_core.start && $countones(dut.u_core.start) >= 2) hit("parallel starts (disjoint ports)");
    end
    always @(posedge gtx_clk) if (|s_underrun) begin errors++; $display("ERROR: TX underrun"); end

    // INTERNAL PROTOCOL CHECK: AXI-Stream on the 4 core -> TX FIFO links.
    // End-to-end checks cannot see a valid that drops before ready (the FIFO
    // happens to tolerate it), so watch the interface itself. Note: in THIS
    // system every copy of a frame starts from an empty FIFO and drains on the
    // same clock, so all destinations' tready fall on the same edge and
    // BUG_FORK_GATED_VALID never fires here -- it is latent. Only
    // tb_switch_core.sv, with independent random tready per port, exposes it.
    logic [3:0] axi_pv = 0, axi_pr = 0, axi_pl = 0; logic [31:0] axi_pd = 0;
    int n_axi = 0;
    always @(posedge sys_clk) if (rst_n) begin
        for (int e = 0; e < 4; e++) begin
            if (axi_pv[e] && !axi_pr[e] &&
                (!dut.tx_v[e] || dut.tx_d[8*e +: 8] != axi_pd[8*e +: 8] || dut.tx_l[e] != axi_pl[e])) begin
                n_axi++; errors++;
                if (n_axi <= 3) $display("ERROR: core -> TX FIFO %0d: tvalid/tdata changed before tready (AXI-Stream)", e);
            end
        end
        axi_pv = dut.tx_v; axi_pr = dut.tx_r; axi_pl = dut.tx_l; axi_pd = dut.tx_d;
    end

    // LIVENESS: an ingress port that keeps requesting must start within a
    // bounded time. Worst legitimate wait: its destinations finish a max-size
    // frame (~1538 byte times at 125 MHz ~ 2,000 sys cycles) and drain their
    // 32-entry FIFOs, a few times over -> 20,000 sys cycles is generous.
    // This catches STARVATION, which drop-tolerant data checks cannot.
    int waitc [4] = '{0, 0, 0, 0};
    int max_wait = 0;
    always @(posedge sys_clk) if (rst_n) begin
        for (int i = 0; i < 4; i++) begin
            if (dut.u_core.req[i] && !dut.u_core.start[i]) waitc[i]++; else waitc[i] = 0;
            if (waitc[i] > max_wait) max_wait = waitc[i];
            if (waitc[i] == 20000) begin errors++; $display("ERROR: ingress %0d starved: requesting for 20000 cycles", i); end
        end
    end

    // progress counters + global watchdog
    int c_rx_good = 0, c_rx_bad = 0, c_txf = 0, c_drop = 0, c_filt = 0;
    always @(posedge rx_clk[0]) begin c_rx_good += s_rx_good[0]; c_rx_bad += s_rx_bad[0]; end
    always @(posedge rx_clk[1]) begin c_rx_good += s_rx_good[1]; c_rx_bad += s_rx_bad[1]; end
    always @(posedge rx_clk[2]) begin c_rx_good += s_rx_good[2]; c_rx_bad += s_rx_bad[2]; end
    always @(posedge rx_clk[3]) begin c_rx_good += s_rx_good[3]; c_rx_bad += s_rx_bad[3]; end
    always @(posedge gtx_clk) c_txf += $countones(s_tx_frame);
    always @(posedge sys_clk) begin c_drop += $countones(s_drop); c_filt += $countones(s_filter); end
    task automatic report(string tag);
        $display("[%0t] %s: rx good %0d bad %0d | ingress drops %0d filtered %0d | tx frames %0d | expected %0d received %0d",
                 $time, tag, c_rx_good, c_rx_bad, c_drop, c_filt, c_txf, n_expected, n_received);
    endtask
    initial begin
        #(64'd50_000_000);   // 50 ms
        report("WATCHDOG"); $display("RESULT: FAIL (watchdog)"); $finish;
    end

    int NPER = 300;
    initial begin
        int timeout;
        if ($value$plusargs("N=%d", NPER)) ;
        if ($value$plusargs("LOAD=%d", LOAD)) ;
        $display("offered load per port: %0d%% of line rate (%s)", LOAD,
                 LOAD <= 30 ? "no-drop mode: every expected frame must arrive" : "congestion mode: drops allowed, integrity checked");
        // self-check of the TB's CRC against the standard check value
        begin byte unsigned t[$] = {8'h31,8'h32,8'h33,8'h34,8'h35,8'h36,8'h37,8'h38,8'h39};
              if (crc_bits(t) != 32'hCBF43926) begin $display("ERROR: TB CRC broken"); $finish; end end
        fork monitor(0); monitor(1); monitor(2); monitor(3); join_none   // (a fork-in-loop trips Verilator 5.020)
        repeat (10) @(posedge sys_clk); rst_n = 1; repeat (20) @(posedge sys_clk);

        // phase 1: learning
        for (int p = 0; p < 4; p++)
            for (int s = 0; s < 3; s++) begin
                eth_frame f = make(p, 1); f.src = station(p, s); f.dst = BCAST;
                model_frame(p, f); drive(p, f);
            end
        timeout = 0;
        while (n_received < n_expected && timeout < 100000) begin @(posedge sys_clk); timeout++; end
        report("phase 1");
        if (n_received != n_expected) begin $display("RESULT: FAIL (phase 1 stuck)"); $finish; end

        // phase 2: concurrent random traffic on all ports
        fork
            port_traffic(0, NPER); port_traffic(1, NPER);
            port_traffic(2, NPER); port_traffic(3, NPER);
        join

        // phase 3: the bad-only addresses must still be unknown -> flood
        for (int p = 0; p < 4; p++) begin
            eth_frame f = make(p, 0); f.kind = GOOD; f.src = station(p, 0);
            f.dst = badonly((p + 1) % 4); f.payload = {}; repeat (50) f.payload.push_back(8'hA5);
            model_frame(p, f); drive(p, f); hit("dst = bad-only source (must flood)");
        end
        // directed: one maximum-size frame (1514 B + FCS) from every port.
        // Random lengths hit this only rarely, and some seeds missed it.
        for (int p = 0; p < 4; p++) begin
            eth_frame f = make(p, 0); f.kind = GOOD; f.src = station(p, 0);
            f.dst = station((p + 1) % 4, 0); f.payload = {};
            repeat (1500) f.payload.push_back(8'($urandom()));
            model_frame(p, f); drive(p, f);
        end

        timeout = 0;
        while (n_received < n_expected && timeout < 200000) begin @(posedge sys_clk); timeout++; end
        repeat (2000) @(posedge sys_clk);

        $display("---- functional coverage bins ----");
        begin
            string must[$] = {"broadcast", "unknown unicast (flood)", "filtered (dst on ingress port)",
                              "minimum-size frame (64 B on the wire)", "bad CRC dropped", "runt dropped", "oversized dropped",
                              "egress min-size frame (60 B + FCS)", "egress max-size frame",
                              "egress contention (>=2 requesters)", "parallel starts (disjoint ports)",
                              "dst = bad-only source (must flood)"};
            int got = 0, total = 0;
            for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) if (i != j) must.push_back($sformatf("unicast %0d->%0d", i, j));
            foreach (must[k]) begin
                total++;
                if (cov_hit.exists(must[k])) begin got++; $display("  %-40s %6d", must[k], cov_hit[must[k]]); end
                else $display("  %-40s      0  <-- MISSED", must[k]);
            end
            $display("coverage: %0d / %0d bins (%0d%%)", got, total, got * 100 / total);
            if (got != total) begin errors++; $display("ERROR: coverage hole -- a scenario the test claims to check never happened"); end
        end
        for (int i = 0; i < 4; i++) for (int e = 0; e < 4; e++) begin
            n_dropped += expq[i][e].size();
            if (LOAD <= 30 && expq[i][e].size() != 0) begin
                errors++; $display("ERROR: %0d frames from %0d never reached %0d (no-drop mode)", expq[i][e].size(), i, e);
            end
        end
        $display("delivered %0d of %0d expected frame copies, dropped %0d (%0d%%)", n_received, n_expected,
                 n_dropped, n_expected ? n_dropped * 100 / n_expected : 0);
        report("end");
        $display("longest wait for grants: %0d sys cycles (liveness limit 20000)", max_wait);
        $display("frames expected %0d, received %0d, errors %0d", n_expected, n_received, errors);
        // Congestion mode allows drops, so a switch that dropped nearly
        // everything would otherwise pass. Measured delivery is 41-46%;
        // the floor is a sanity check, not a performance spec.
        if (LOAD > 30 && n_received * 100 < n_expected * 25) begin
            errors++; $display("ERROR: only %0d%% of copies delivered under congestion (sanity floor 25%%)", n_received * 100 / n_expected);
        end
        $display("AXI-Stream violations on core -> TX FIFO links: %0d", n_axi);
        if (errors == 0 && (LOAD > 30 || n_received == n_expected)) $display("RESULT: PASS"); else $display("RESULT: FAIL");
        $finish;
    end
endmodule
