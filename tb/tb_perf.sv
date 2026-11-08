// -----------------------------------------------------------------------------
// tb_perf.sv -- throughput and latency of the whole switch
//
// Offers one traffic pattern at one frame size and one load, then prints a
// single "PERF," line. docs/perf_sweep.py runs this across a grid.
//
// Plusargs:
//   +PATTERN=pair|uniform|incast   (default uniform)
//       pair     0<->1 and 2<->3: no two ports want the same output
//       uniform  every port sends to a random other port
//       incast   ports 1, 2, 3 all send to port 0, port 0 stays silent
//   +SIZE=<bytes>      frame size including FCS, 64..1518 (default 64)
//   +LOAD=<percent>    offered load per sending port, % of line rate (default 50)
//   +N=<frames>        frames per sending port (default 500)
//   +SYS_MHZ=<f>       system clock (default 156.25)
//   +verilator+seed+<n>
//
// Line rate counts the whole time a frame occupies the wire: preamble and SFD
// (8 bytes), the frame, and the minimum gap (12 bytes). So 100% is 1000 Mb/s.
//
// MEASURED over a window with every sender active, skipping the first 10% of
// frames as warm-up:
//   offered / delivered rate, Mb/s, over all sending ports
//   latency (store-and-forward, RFC 2544 "last bit in, first bit out"): from the
//     end of the frame on GMII rx to the start of its preamble on GMII tx
// Dropped frames have no latency, so latency only describes delivered frames.
//
// CHECKED on all frames, whatever the load: every byte correct, FCS correct, the
// right output port, order kept per sender, nothing duplicated, gap >= 12, no
// tx_er. Any failure prints RESULT: FAIL.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_perf;
    // ---------------- clocks ----------------
    logic sys_clk = 0;
    initial begin
        real sys_mhz = 156.25;
        void'($value$plusargs("SYS_MHZ=%f", sys_mhz));
        forever #(500.0 / sys_mhz) sys_clk = ~sys_clk;
    end
    logic gtx_clk = 0; always #4.0 gtx_clk = ~gtx_clk;
    // Four separate signals, as in tb_switch: driving bits of one vector from four
    // processes makes Verilator 5.020 miss edges inside the DUT.
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

    // ---------------- settings ----------------
    string PATTERN = "uniform";
    int SIZE = 64, LOAD = 50, N = 500;
    int errors = 0;

    function automatic logic [31:0] crc_bits(input byte unsigned d[$]);
        logic [31:0] c = 32'hFFFFFFFF;
        foreach (d[i]) for (int b = 0; b < 8; b++) begin
            logic fb = c[0] ^ d[i][b];
            c = c >> 1;
            if (fb) c = c ^ 32'hEDB88320;
        end
        return ~c;
    endfunction

    function automatic logic [47:0] station(int p); return {32'h0200_0000, 8'(p), 8'h01}; endfunction
    function automatic bit sends(int p);            return !(PATTERN == "incast" && p == 0); endfunction

    function automatic int pick_dst(int p);
        if (PATTERN == "pair")   return p ^ 1;
        if (PATTERN == "incast") return 0;
        begin
            int d = $urandom_range(0, 2);
            return (d >= p) ? d + 1 : d;
        end
    endfunction

    // payload: {sender, seq[31:0], then a pattern that depends on both}
    function automatic byte unsigned pat(int p, int seq, int i);
        return 8'((i * 7) ^ (seq * 13) ^ (p * 53));
    endfunction

    function automatic void build(ref byte unsigned q[$], input logic [47:0] dst, input int p, input int seq);
        logic [47:0] src = station(p);
        logic [31:0] fcs;
        q = {};
        for (int i = 5; i >= 0; i--) q.push_back(dst[8*i +: 8]);
        for (int i = 5; i >= 0; i--) q.push_back(src[8*i +: 8]);
        q.push_back(8'h08); q.push_back(8'h00);
        q.push_back(8'(p));
        for (int i = 3; i >= 0; i--) q.push_back(8'(seq >> (8 * i)));
        for (int i = q.size(); i < SIZE - 4; i++) q.push_back(pat(p, seq, i));
        fcs = crc_bits(q);
        q.push_back(fcs[7:0]); q.push_back(fcs[15:8]); q.push_back(fcs[23:16]); q.push_back(fcs[31:24]);
    endfunction

    // ---------------- driver ----------------
    real    t_in  [longint];                     // {sender, seq} -> end of frame on rx
    int     dst_of[longint];                     // {sender, seq} -> expected output port
    real    t_warm[4] = '{0.0, 0.0, 0.0, 0.0};   // when each sender finished warm-up
    real    t_done[4] = '{0.0, 0.0, 0.0, 0.0};   // when each sender finished
    int     n_sent = 0;

    function automatic longint key(int p, int seq); return (longint'(p) << 32) | longint'(seq); endfunction

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

    task automatic drive(int p, ref byte unsigned q[$]);
        wait_rx(p);
        for (int i = 0; i < 7; i++) begin rx_dv[p] = 1; rxd[8*p +: 8] = 8'h55; wait_rx(p); end
        rxd[8*p +: 8] = 8'hD5; wait_rx(p);
        foreach (q[i]) begin rxd[8*p +: 8] = q[i]; wait_rx(p); end
        rx_dv[p] = 0; rxd[8*p +: 8] = 0;
    endtask

    // mean gap for LOAD%: the frame occupies SIZE + 20 byte times at 100%, so the
    // period is that / load, and the gap is the period minus SIZE + 8. Gaps vary
    // evenly around the mean so that ports don't fall into lock-step.
    function automatic int next_gap();
        int mean = (SIZE + 20) * 100 / LOAD - (SIZE + 8);
        if (mean <= 12) return 12;
        return $urandom_range(12, 2 * mean - 12);
    endfunction

    task automatic traffic(int p);
        byte unsigned q[$];
        if (!sends(p)) return;
        for (int s = 0; s < N; s++) begin
            int d = pick_dst(p);
            q = {};                                  // explicit: Verilator 5.020 can keep automatic queues between calls
            build(q, station(d), p, s);
            dst_of[key(p, s)] = d;
            n_sent++;
            drive(p, q);
            t_in[key(p, s)] = $realtime;
            if (s == N / 10) t_warm[p] = $realtime;
            begin
                int g = next_gap();
                for (int w = 1; w < g; w++) wait_rx(p);      // drive() starts with one more wait, so idle is exactly g
            end
        end
        t_done[p] = $realtime;
    endtask

    // Independent check of the traffic generator, on the wires themselves: a gap under
    // 12 bytes is illegal Ethernet and would silently overdrive the switch. This caught
    // a real problem: `repeat` around wait_rx ran about a quarter of its count with
    // all four ports active (seen on Verilator 5.020), so generators use `for` loops.
    int rx_gap_min[4] = '{1000000, 1000000, 1000000, 1000000};
    task automatic rx_gap_monitor(int p);
        int idle = 0; bit started = 0;
        forever begin
            wait_rx(p);
            if (rx_dv[p]) begin
                if (started && idle != 0 && idle < rx_gap_min[p]) rx_gap_min[p] = idle;
                started = 1; idle = 0;
            end else idle++;
        end
    endtask

    // ---------------- monitors ----------------
    typedef struct { real t_out; int lat; longint k; } got_t;
    got_t got[$];
    int   last_seq[4][4];
    int   n_learn_copies = 0;

    function automatic void err(string m);
        errors++;
        if (errors < 8) $display("ERROR: %s", m);
    endfunction

    function automatic void check_frame(int e, real t0, ref byte unsigned w[$]);
        byte unsigned body[$];
        logic [31:0] fcs, calc; logic [47:0] dst;
        int ing, seq;
        if (w.size() < 72) begin err($sformatf("port %0d: frame too short (%0d)", e, w.size())); return; end
        for (int i = 0; i < 7; i++) if (w[i] != 8'h55) begin err($sformatf("port %0d: bad preamble", e)); return; end
        if (w[7] != 8'hD5) begin err($sformatf("port %0d: bad SFD", e)); return; end
        body = {};
        for (int i = 8; i < w.size() - 4; i++) body.push_back(w[i]);
        fcs = {w[w.size()-1], w[w.size()-2], w[w.size()-3], w[w.size()-4]};
        calc = crc_bits(body);
        if (fcs != calc) begin err($sformatf("port %0d: FCS %h, expected %h", e, fcs, calc)); return; end
        dst = {body[0], body[1], body[2], body[3], body[4], body[5]};
        if (dst == 48'hFFFF_FFFF_FFFF) begin n_learn_copies++; return; end   // learning phase
        ing = body[14];
        seq = {body[15], body[16], body[17], body[18]};
        if (ing > 3 || !t_in.exists(key(ing, seq))) begin err($sformatf("port %0d: unknown frame, sender %0d seq %0d", e, ing, seq)); return; end
        if (dst_of[key(ing, seq)] != e) begin err($sformatf("port %0d: frame %0d/%0d belongs on port %0d", e, ing, seq, dst_of[key(ing, seq)])); return; end
        if (body.size() != SIZE - 4) begin err($sformatf("port %0d: length %0d, expected %0d", e, body.size(), SIZE - 4)); return; end
        for (int i = 19; i < body.size(); i++) if (body[i] != pat(ing, seq, i)) begin err($sformatf("port %0d: frame %0d/%0d byte %0d is corrupt", e, ing, seq, i)); return; end
        if (seq <= last_seq[ing][e]) begin err($sformatf("port %0d: frame %0d/%0d duplicated or reordered", e, ing, seq)); return; end
        last_seq[ing][e] = seq;
        begin
            got_t g;
            g.t_out = t0; g.k = key(ing, seq);
            g.lat   = int'(t0 - t_in[key(ing, seq)]);
            got.push_back(g);
        end
    endfunction

    task automatic monitor(int e);
        byte unsigned q[$]; int cyc = 0, last_end = -100, gap; real t0;
        forever begin
            @(posedge gtx_clk); cyc++;
            if (tx_er[e]) err($sformatf("port %0d: tx_er asserted", e));
            if (tx_en[e]) begin
                t0 = $realtime;
                gap = cyc - last_end - 1;
                if (gap < 12) err($sformatf("port %0d: gap %0d < 12", e, gap));
                q = {};
                while (tx_en[e]) begin
                    if (tx_er[e]) err($sformatf("port %0d: tx_er asserted", e));
                    q.push_back(txd[8*e +: 8]); @(posedge gtx_clk); cyc++;
                end
                last_end = cyc - 1;
                check_frame(e, t0, q);
            end
        end
    endtask

    int c_ingress_drop = 0, c_flood = 0, c_underrun = 0;
    always @(posedge sys_clk) if (rst_n) begin
        c_ingress_drop += $countones(s_drop);
        c_flood        += $countones(s_flood);
    end
    always @(posedge gtx_clk) if (rst_n) c_underrun += $countones(s_underrun);

    // ---------------- watchdog: simulated time, far beyond any run in the sweep ----------------
    initial begin
        #(64'd2_000_000_000);
        $display("RESULT: FAIL (watchdog)"); $finish;
    end

    // ---------------- results ----------------
    task automatic finish_up();
        real t0 = 0.0, t1 = 1.0e30, window;
        int  n_off = 0, n_del = 0, nlat = 0, senders = 0;
        longint sum = 0;
        int  lats[$];
        int  n_got = got.size();
        real wire_bits = real'((SIZE + 20) * 8);

        for (int p = 0; p < 4; p++) if (sends(p)) begin
            senders++;
            if (t_warm[p] > t0) t0 = t_warm[p];
            if (t_done[p] < t1) t1 = t_done[p];
        end
        window = t1 - t0;
        if (window <= 0.0) begin $display("RESULT: FAIL (no measurement window)"); $finish; end

        foreach (t_in[k]) if (t_in[k] > t0 && t_in[k] <= t1) n_off++;
        foreach (got[i]) begin
            if (got[i].t_out > t0 && got[i].t_out <= t1) n_del++;
            if (t_in[got[i].k] > t0 && t_in[got[i].k] <= t1) begin lats.push_back(got[i].lat); sum += got[i].lat; nlat++; end
        end
        lats.sort();

        if (n_got == 0 || nlat == 0) err("no frames delivered in the window");
        if (n_got > n_sent) err("more frames delivered than sent");
        if (c_underrun != 0) err($sformatf("%0d TX underrun cycles", c_underrun));
        // once learned, nothing in these patterns should ever flood
        if (c_flood != 0) err($sformatf("%0d frames flooded after learning", c_flood));

        for (int p = 0; p < 4; p++) if (rx_gap_min[p] < 12) err($sformatf("rx port %0d: generator gap %0d < 12", p, rx_gap_min[p]));
        // the generator must really offer what was asked (random gaps allow some error)
        begin
            real want = real'(senders) * real'(LOAD) * 10.0;
            real off  = real'(n_off) * wire_bits / window * 1000.0;
            if (off > want * 1.12 || off < want * 0.88) err($sformatf("offered %0.1f Mb/s, asked for %0.1f", off, want));
        end

        // PERF,pattern,size,load,senders,offered_mbps,delivered_mbps,sent,delivered,drop_pct,lat_min,lat_avg,lat_p50,lat_p99,lat_max
        if (nlat != 0)
            $display("PERF,%s,%0d,%0d,%0d,%0.1f,%0.1f,%0d,%0d,%0.2f,%0d,%0.0f,%0d,%0d,%0d",
                     PATTERN, SIZE, LOAD, senders,
                     real'(n_off) * wire_bits / window * 1000.0,
                     real'(n_del) * wire_bits / window * 1000.0,
                     n_sent, n_got, 100.0 * real'(n_sent - n_got) / real'(n_sent),
                     lats[0], real'(sum) / real'(nlat), lats[nlat / 2], lats[(nlat * 99) / 100], lats[nlat - 1]);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    endtask

    initial begin
        int quiet = 0, seen = 0;
        byte unsigned q[$];
        void'($value$plusargs("PATTERN=%s", PATTERN));
        void'($value$plusargs("SIZE=%d", SIZE));
        void'($value$plusargs("LOAD=%d", LOAD));
        void'($value$plusargs("N=%d", N));
        if (SIZE < 64 || SIZE > 1518 || LOAD < 1 || LOAD > 100 || N < 20 ||
            !(PATTERN == "pair" || PATTERN == "uniform" || PATTERN == "incast")) begin
            $display("RESULT: FAIL (bad settings)"); $finish;
        end
        for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) last_seq[i][j] = -1;

        fork monitor(0); monitor(1); monitor(2); monitor(3); join_none   // (a fork-in-loop trips Verilator 5.020)
        fork rx_gap_monitor(0); rx_gap_monitor(1); rx_gap_monitor(2); rx_gap_monitor(3); join_none
        repeat (10) @(posedge sys_clk); rst_n = 1; repeat (20) @(posedge sys_clk);

        // learning: each station broadcasts once, and every other port must hear it
        for (int p = 0; p < 4; p++) begin
            q = {};
            build(q, 48'hFFFF_FFFF_FFFF, p, 0);
            drive(p, q);
            repeat (4000) @(posedge gtx_clk);
        end
        if (n_learn_copies != 12) begin $display("RESULT: FAIL (learning: %0d of 12 copies)", n_learn_copies); $finish; end
        c_flood = 0;

        fork
            traffic(0); traffic(1); traffic(2); traffic(3);
        join

        // drain: stop when no output has been active for a while
        while (quiet < 20000) begin
            @(posedge gtx_clk);
            if (tx_en != 0 || got.size() != seen) quiet = 0; else quiet++;
            seen = got.size();
        end
        finish_up();
    end
endmodule
