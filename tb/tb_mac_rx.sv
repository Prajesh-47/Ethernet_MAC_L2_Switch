// -----------------------------------------------------------------------------
// tb_mac_rx.sv -- unit test for rtl/eth_mac_rx.v (milestone 3)
//
// DRIVER   : plays frames onto GMII exactly as a PHY would:
//            preamble (1..7 x 0x55) + SFD + bytes + FCS, then >= 12 idle cycles.
// MONITOR  : collects the AXI4-Stream output and, at each tlast, checks the
//            bytes (FCS must be stripped) and the good/bad verdict in tuser.
// CASES    : every frame has a KIND; the expected verdict follows from it:
//   GOOD      64..1518 bytes incl. FCS, correct CRC          -> tuser = 0
//   BAD_CRC   one data bit flipped after the FCS was computed -> tuser = 1
//   RUNT      < 64 bytes incl. FCS                            -> tuser = 1
//   OVERSIZE  > 1518 bytes incl. FCS                          -> tuser = 1
//   RX_ER     PHY raises rx_er for one byte mid-frame         -> tuser = 1
//   BACKPRES  m_tready dropped mid-frame (data was lost)      -> tuser = 1
//   NOISE     rx_dv burst with no SFD                         -> no output at all
// The MAC's stat_good / stat_bad pulse counts must match too.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_mac_rx;
    logic clk = 0, rst_n = 0;
    always #4 clk = ~clk;                         // 125 MHz, the PHY's rx clock

    logic [7:0] rxd = 0; logic rx_dv = 0, rx_er = 0;
    wire  [7:0] m_tdata; wire m_tvalid, m_tlast, m_tuser; logic m_tready = 1;
    wire  stat_good, stat_bad;

    eth_mac_rx dut (.clk(clk), .rst_n(rst_n),
        .gmii_rxd(rxd), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tlast(m_tlast), .m_tuser(m_tuser), .m_tready(m_tready),
        .stat_good(stat_good), .stat_bad(stat_bad));

    // ---------------- independent reference CRC (bit-serial) ----------------
    function automatic logic [31:0] crc_ref(input byte unsigned d[$]);
        logic [31:0] c = 32'hFFFFFFFF;
        foreach (d[i]) for (int b = 0; b < 8; b++) begin
            logic fb = c[0] ^ d[i][b];
            c = c >> 1;
            if (fb) c = c ^ 32'hEDB88320;
        end
        return ~c;
    endfunction

    typedef enum {GOOD, BAD_CRC, RUNT, OVERSIZE, RX_ER, BACKPRES, NOISE} kind_t;
    class frame_t;
        byte unsigned d[$];     // frame bytes WITHOUT the FCS (what the MAC must output)
        kind_t kind;
    endclass
    frame_t expq[$];

    int errors = 0, n_sent = 0, n_checked = 0, exp_good = 0, exp_bad = 0;
    int got_good = 0, got_bad = 0;
    int kind_count [kind_t];

    // ---------------- driver ----------------
    task automatic play(kind_t kind, int len);   // len = bytes before the FCS
        frame_t f = new();
        byte unsigned w[$];
        logic [31:0] fcs;
        int pre = $urandom_range(1, 7);           // some PHYs shorten the preamble
        int er_at = -1, bp_at = -1;
        f.d = {}; w = {};
        f.kind = kind;
        for (int i = 0; i < len; i++) f.d.push_back(8'($urandom()));
        fcs = crc_ref(f.d);
        w = f.d;
        w.push_back(fcs[7:0]); w.push_back(fcs[15:8]); w.push_back(fcs[23:16]); w.push_back(fcs[31:24]);
        if (kind == BAD_CRC) begin                // corrupt one data bit AFTER computing the FCS
            int k = $urandom_range(0, len - 1);
            w[k] ^= 8'(1 << $urandom_range(0, 7));
            f.d[k] = w[k];                         // the MAC still outputs the (corrupted) bytes
        end
        if (kind == RX_ER)    er_at = $urandom_range(0, w.size() - 1);
        if (kind == BACKPRES) bp_at = $urandom_range(10, len - 1);
        kind_count[kind]++;
        if (kind != NOISE) begin
            expq.push_back(f); n_sent++;
            if (kind == GOOD) exp_good++; else exp_bad++;
        end

        // preamble + SFD (NOISE: preamble only, never an SFD)
        @(negedge clk);
        for (int i = 0; i < pre; i++) begin rx_dv = 1; rxd = 8'h55; @(negedge clk); end
        if (kind == NOISE) begin
            repeat ($urandom_range(5, 40)) begin rxd = 8'h55; @(negedge clk); end
        end else begin
            rxd = 8'hD5; @(negedge clk);
            foreach (w[i]) begin
                rxd = w[i];
                rx_er = (i == er_at);
                if (i == bp_at) m_tready = 0;      // the sink stalls for 3 cycles: data is lost
                if (i == bp_at + 3) m_tready = 1;
                @(negedge clk);
            end
        end
        rx_dv = 0; rx_er = 0; rxd = 0; m_tready = 1;
        repeat (12 + $urandom_range(0, 20)) @(negedge clk);    // inter-frame gap
    endtask

    // ---------------- monitor ----------------
    byte unsigned got[$];
    always @(posedge clk) if (m_tvalid && m_tready) begin
        got.push_back(m_tdata);
        if (m_tlast) begin
            check(got, m_tuser);
            got = {};
        end
    end
    always @(posedge clk) begin
        if (stat_good) got_good++;
        if (stat_bad)  got_bad++;
    end

    function automatic void check(byte unsigned g[$], bit tuser);
        frame_t f;
        bit exp_bad_v;
        if (expq.size() == 0) begin errors++; $display("ERROR: output frame that was never sent (noise accepted?)"); return; end
        f = expq.pop_front();
        n_checked++;
        exp_bad_v = (f.kind != GOOD);
        if (tuser != exp_bad_v) begin
            errors++; $display("ERROR: %s frame (%0d B) got tuser=%0b, expected %0b", f.kind.name(), f.d.size() + 4, tuser, exp_bad_v);
            return;
        end
        if (f.kind == GOOD) begin                  // bytes only matter for good frames
            if (g.size() != f.d.size()) begin
                errors++; $display("ERROR: good frame length %0d, expected %0d (FCS stripped?)", g.size(), f.d.size()); return;
            end
            foreach (g[i]) if (g[i] != f.d[i]) begin
                errors++; $display("ERROR: good frame byte %0d = %h, expected %h", i, g[i], f.d[i]); return;
            end
        end
    endfunction

    // ---------------- test sequence ----------------
    initial begin
        repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
        // edge cases around the size limits (sizes here are WITHOUT the 4 FCS bytes)
        play(GOOD, 60);   play(GOOD, 1514);   // exactly 64 and 1518 incl. FCS: the limits
        play(RUNT, 59);   play(OVERSIZE, 1515); // one byte past each limit
        play(NOISE, 0);   play(GOOD, 100);
        // random mix
        for (int i = 0; i < 400; i++) begin
            int r = $urandom_range(0, 99);
            if      (r < 60) play(GOOD,     $urandom_range(60, 1514));
            else if (r < 70) play(BAD_CRC,  $urandom_range(60, 1514));
            else if (r < 77) play(RUNT,     $urandom_range(14, 59));
            else if (r < 82) play(OVERSIZE, $urandom_range(1515, 1600));
            else if (r < 89) play(RX_ER,    $urandom_range(60, 1514));
            else if (r < 95) play(BACKPRES, $urandom_range(60, 1514));
            else             play(NOISE,    0);
        end
        repeat (100) @(posedge clk);

        if (expq.size() != 0) begin errors++; $display("ERROR: %0d frames produced no output", expq.size()); end
        if (got_good != exp_good || got_bad != exp_bad) begin
            errors++; $display("ERROR: stat_good %0d (exp %0d), stat_bad %0d (exp %0d)", got_good, exp_good, got_bad, exp_bad);
        end
        $display("frames played %0d, checked %0d   (stat_good %0d, stat_bad %0d)", n_sent, n_checked, got_good, got_bad);
        foreach (kind_count[k]) $display("  %-9s %4d", k.name(), kind_count[k]);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
