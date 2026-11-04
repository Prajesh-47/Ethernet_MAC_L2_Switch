// -----------------------------------------------------------------------------
// tb_mac_tx.sv -- unit test for rtl/eth_mac_tx.v (milestone 2)
//
// DRIVER   : feeds frames (dst..payload, no FCS) into the AXI4-Stream input.
//            Inside a frame it never drops tvalid (that is the MAC's contract);
//            between frames it waits a random 0..40 cycles, so both
//            back-to-back and idle-gap cases happen.
// MONITOR  : watches GMII. For every burst of tx_en it checks
//              - exactly 7 x 0x55 preamble + 0xD5 SFD
//              - the data bytes match what was sent
//              - frames shorter than 60 bytes are padded with 0x00 to 60
//              - the 4 FCS bytes equal an independent bit-serial CRC, LSB first
//              - the gap since the previous frame is >= 12 idle cycles
//              - tx_er never rises
// UNDERRUN : one deliberate frame with tvalid dropped for 3 cycles in the
//            middle; the MAC must raise tx_er and stat_underrun exactly then.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_mac_tx;
    logic clk = 0, rst_n = 0;
    always #4 clk = ~clk;                         // 125 MHz

    logic [7:0] s_tdata = 0; logic s_tvalid = 0, s_tlast = 0; wire s_tready;
    wire  [7:0] txd; wire tx_en, tx_er, stat_underrun, stat_frame;

    eth_mac_tx dut (.clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tlast(s_tlast), .s_tready(s_tready),
        .gmii_txd(txd), .gmii_tx_en(tx_en), .gmii_tx_er(tx_er),
        .stat_underrun(stat_underrun), .stat_frame(stat_frame));

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

    // expected frames, in order (a class wraps the byte queue: Verilator
    // 5.020 does not handle queues of queues reliably)
    class frame_t; byte unsigned d[$]; bit underrun; endclass
    frame_t expq[$];

    int errors = 0, nframes = 0, n_checked = 0, n_padded = 0, n_underrun_pulses = 0;
    int min_gap = 1 << 30, max_gap = 0, n_b2b = 0;

    // ---------------- driver ----------------
    task automatic send(int len, bit underrun = 0);
        frame_t f = new();
        f.d = {};                                 // explicit clear (Verilator 5.020 quirk)
        for (int i = 0; i < len; i++) f.d.push_back(8'($urandom()));
        f.underrun = underrun;
        expq.push_back(f); nframes++;
        for (int i = 0; i < len; i++) begin
            @(negedge clk);
            s_tvalid = 1; s_tdata = f.d[i]; s_tlast = (i == len - 1);
            @(posedge clk); while (!s_tready) @(posedge clk);   // wait for the handshake
            if (underrun && i == len / 2) begin                 // deliberately starve the MAC
                @(negedge clk); s_tvalid = 0;
                repeat (3) @(posedge clk);
            end
        end
        @(negedge clk); s_tvalid = 0; s_tlast = 0;
    endtask

    // ---------------- monitor ----------------
    int cyc = 0, last_end = -100;
    initial forever begin
        byte unsigned w[$];
        int er_cycles;
        @(posedge clk); cyc++;
        if (tx_en) begin
            int gap = cyc - last_end - 1;
            w = {}; er_cycles = 0;
            while (tx_en) begin
                w.push_back(txd);
                if (tx_er) er_cycles++;
                @(posedge clk); cyc++;
            end
            last_end = cyc - 1;
            if (nframes > 1 || expq.size() > 0) begin
                if (gap < min_gap) min_gap = gap;
                if (gap > max_gap && gap < 1000) max_gap = gap;
                if (gap <= 13) n_b2b++;
            end
            check(w, er_cycles, gap);
        end
    end

    function automatic void check(byte unsigned w[$], int er_cycles, int gap);
        frame_t f; byte unsigned body[$], exp[$]; logic [31:0] fcs;
        if (expq.size() == 0) begin errors++; $display("ERROR: frame on GMII that was never sent"); return; end
        f = expq.pop_front();
        n_checked++;
        if (f.underrun) begin
            // corrupted on purpose: only check that the error was signalled
            if (er_cycles != 3) begin errors++; $display("ERROR: underrun frame had %0d tx_er cycles, expected 3", er_cycles); end
            return;
        end
        if (er_cycles != 0) begin errors++; $display("ERROR: tx_er asserted on a good frame"); end
        if (n_checked > 1 && gap < 12) begin errors++; $display("ERROR: inter-frame gap %0d < 12", gap); end
        // preamble + SFD
        for (int i = 0; i < 7; i++)
            if (w[i] != 8'h55) begin errors++; $display("ERROR: preamble byte %0d = %h", i, w[i]); return; end
        if (w[7] != 8'hD5) begin errors++; $display("ERROR: SFD = %h", w[7]); return; end
        // body = everything between SFD and FCS
        body = {};
        for (int i = 8; i < w.size() - 4; i++) body.push_back(w[i]);
        exp = f.d;
        if (exp.size() < 60) n_padded++;
        while (exp.size() < 60) exp.push_back(8'h00);          // minimum frame padding
        if (body.size() != exp.size()) begin
            errors++; $display("ERROR: length %0d, expected %0d", body.size(), exp.size()); return;
        end
        foreach (exp[i]) if (body[i] != exp[i]) begin
            errors++; $display("ERROR: byte %0d = %h, expected %h", i, body[i], exp[i]); return;
        end
        fcs = crc_ref(exp);
        if ({w[w.size()-1], w[w.size()-2], w[w.size()-3], w[w.size()-4]} != fcs) begin
            errors++; $display("ERROR: FCS %h, expected %h", {w[w.size()-1], w[w.size()-2], w[w.size()-3], w[w.size()-4]}, fcs);
        end
    endfunction

    always @(posedge clk) if (stat_underrun) n_underrun_pulses++;

    // ---------------- test sequence ----------------
    initial begin
        int lens[$] = {1, 14, 45, 46, 59, 60, 61, 64, 100, 1500, 1514};   // edge cases first
        repeat (5) @(posedge clk); rst_n = 1;
        foreach (lens[i]) begin send(lens[i]); repeat ($urandom_range(0, 40)) @(posedge clk); end
        for (int i = 0; i < 300; i++) begin
            send($urandom_range(1, 1514));
            if ($urandom_range(0, 1)) repeat ($urandom_range(0, 40)) @(posedge clk);   // half back-to-back
        end
        send(100, 1);                                           // the deliberate underrun
        repeat (2000) @(posedge clk);

        if (expq.size() != 0) begin errors++; $display("ERROR: %0d frames never appeared on GMII", expq.size()); end
        if (n_underrun_pulses != 3) begin errors++; $display("ERROR: stat_underrun pulsed %0d times, expected 3", n_underrun_pulses); end
        $display("frames sent %0d, checked on GMII %0d (%0d needed padding)", nframes, n_checked, n_padded);
        $display("inter-frame gap: min %0d, max %0d idle cycles; %0d frames sent back-to-back", min_gap, max_gap, n_b2b);
        $display("deliberate underrun: tx_er + stat_underrun raised for %0d cycles", n_underrun_pulses);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
