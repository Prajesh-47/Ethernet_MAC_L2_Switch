// -----------------------------------------------------------------------------
// tb_mac_loop.sv -- full-MAC loopback (milestone 4)
//
//   AXIS in (sys clock) -> TX FIFO -> TX MAC -> GMII --wire--> RX MAC -> RX FIFO -> AXIS out
//
// Both async FIFOs (from the Asynchronous_FIFO project) are in the path, so
// every frame crosses clock domains twice. The clocks are set at run time:
//   +SYS_MHZ=<f>   system clock, default 156.25
//   +GMII_MHZ=<f>  GMII clock (tx and rx are wired together), default 125
//
// Every frame that comes back is classified:
//   GOOD      bytes identical (padded to 60) and tuser = 0
//   FLAGGED   tuser = 1: the MAC reported a problem (allowed only in slow mode)
//   CORRUPT   tuser = 0 but the bytes differ: a SILENT error -- always a failure
//
// Normal mode (sys >= GMII): every frame must be GOOD, no underruns.
// Slow mode (+SLOW, sys < GMII): the TX FIFO drains faster than it fills, so
// the TX MAC underruns mid-frame. That is EXPECTED; the test then requires
// that every damaged frame is FLAGGED and none is CORRUPT.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_mac_loop;
    real sys_mhz = 156.25, gmii_mhz = 125.0;
    real sys_half, gmii_half;
    bit  slow_mode = 0;

    logic sys_clk = 0, gclk = 0, rst_n = 0;
    initial begin
        void'($value$plusargs("SYS_MHZ=%f", sys_mhz));
        void'($value$plusargs("GMII_MHZ=%f", gmii_mhz));
        slow_mode = $test$plusargs("SLOW");
        sys_half  = 500.0 / sys_mhz;      // ns
        gmii_half = 500.0 / gmii_mhz;
    end
    initial begin #0.1; forever #(sys_half)  sys_clk = ~sys_clk; end
    initial begin #1.3; forever #(gmii_half) gclk    = ~gclk;    end   // unrelated phase

    wire [7:0] txd; wire tx_en, tx_er;
    wire [7:0] rx_d; wire rx_v, rx_l, rx_u; logic rx_r = 1;
    logic [7:0] tx_d = 0; logic tx_v = 0, tx_l = 0; wire tx_r, tx_empty;
    wire s_good, s_bad, s_und, s_frm;

    eth_mac dut (.sys_clk(sys_clk), .sys_rst_n(rst_n),
        .gmii_rx_clk(gclk), .gmii_rxd(txd), .gmii_rx_dv(tx_en), .gmii_rx_er(tx_er),
        .gmii_tx_clk(gclk), .gmii_txd(txd), .gmii_tx_en(tx_en), .gmii_tx_er(tx_er),
        .rx_tdata(rx_d), .rx_tvalid(rx_v), .rx_tlast(rx_l), .rx_tuser(rx_u), .rx_tready(rx_r),
        .tx_tdata(tx_d), .tx_tvalid(tx_v), .tx_tlast(tx_l), .tx_tready(tx_r), .tx_fifo_empty(tx_empty),
        .stat_rx_good(s_good), .stat_rx_bad(s_bad), .stat_tx_underrun(s_und), .stat_tx_frame(s_frm));

    class frm; byte unsigned d[$]; endclass   // (queue-of-queues is unreliable in Verilator 5.020)
    frm sent[$];
    byte unsigned cur[$];
    int nframes = 0, ngot = 0, errors = 0, n_good = 0, n_flagged = 0, n_corrupt = 0, n_underrun = 0;

    // ---------------- receiver / checker ----------------
    always @(posedge sys_clk) if (rx_v && rx_r) begin
        cur.push_back(rx_d);
        if (rx_l) begin
            byte unsigned e[$]; bit same; frm x;
            if (sent.size() == 0) begin errors++; $display("ERROR: frame received that was never sent"); end
            else begin
                x = sent.pop_front(); e = x.d;
                while (e.size() < 60) e.push_back(8'h00);
                same = (e.size() == cur.size());
                if (same) foreach (e[i]) if (e[i] != cur[i]) same = 0;
                if (rx_u)       n_flagged++;
                else if (same)  n_good++;
                else begin
                    n_corrupt++; errors++;
                    if (n_corrupt < 5) $display("ERROR: SILENT corruption on frame %0d (len %0d vs %0d, tuser 0)", ngot, cur.size(), e.size());
                end
            end
            ngot++; cur = {};
        end
    end
    always @(posedge gclk) if (s_und) n_underrun++;

    // ---------------- driver ----------------
    task automatic send(int len);
        byte unsigned f[$]; frm x = new();
        f = {};                                   // explicit: Verilator 5.020 can keep automatic queues between calls
        for (int i = 0; i < len; i++) f.push_back(8'($urandom()));
        x.d = f; sent.push_back(x); nframes++;
        foreach (f[i]) begin
            @(negedge sys_clk); tx_v = 1; tx_d = f[i]; tx_l = (i == len - 1);
            @(posedge sys_clk); while (!tx_r) @(posedge sys_clk);
        end
        @(negedge sys_clk); tx_v = 0; tx_l = 0;
    endtask

    initial begin
        int lens[$] = {14, 20, 59, 60, 61, 100, 500, 1500, 1514, 1, 33};
        #1;
        if (slow_mode) $display("clocks: system %0.3f MHz, GMII %0.3f MHz  (SLOW mode: damage allowed, must be flagged)", sys_mhz, gmii_mhz);
        else           $display("clocks: system %0.3f MHz, GMII %0.3f MHz", sys_mhz, gmii_mhz);
        repeat (10) @(posedge sys_clk); rst_n = 1; repeat (20) @(posedge sys_clk);
        foreach (lens[i]) send(lens[i]);
        for (int i = 0; i < 200; i++) send($urandom_range(1, 1514));
        repeat (40000) @(posedge sys_clk);

        if (ngot != nframes) begin errors++; $display("ERROR: sent %0d frames, %0d came back", nframes, ngot); end
        if (!slow_mode && (n_flagged != 0 || n_underrun != 0)) begin
            errors++; $display("ERROR: %0d frames flagged bad and %0d underrun cycles in normal mode", n_flagged, n_underrun);
        end
        if (slow_mode && n_flagged == 0) begin
            errors++; $display("ERROR: slow mode produced no flagged frames -- the test did not exercise underrun");
        end
        $display("loopback: sent %0d, received %0d: good %0d, flagged bad %0d, silently corrupt %0d (TX underrun cycles %0d)",
                 nframes, ngot, n_good, n_flagged, n_corrupt, n_underrun);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
