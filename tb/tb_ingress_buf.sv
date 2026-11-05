// -----------------------------------------------------------------------------
// tb_ingress_buf.sv -- unit test for rtl/ingress_buf.v (milestone 5)
//
// The buffer must keep a frame only if ALL of these hold when its tlast arrives:
//   tuser = 0 (the MAC said good), length >= 14 (a full header),
//   every byte fitted in the 4096-byte buffer, and the 8-entry descriptor
//   queue had room. Otherwise the frame must vanish without a trace.
//
// WRITER   : plays frames like the RX FIFO would, with random idle cycles
//            inside a frame (tvalid gaps).
// MODEL    : before each byte, the writer predicts whether it fits, using
//            what the reader has removed so far. At tlast it predicts
//            commit or drop. Committed frames go into expq / learnq.
// CROSSBAR : plays the switch core: looks at the head descriptor, then
//            either streams the frame out (xfer) under random tready, or
//            throws it away (drop). Reader stalls force the buffer to fill.
// CHECKS   : every output frame matches the oldest committed frame byte
//            for byte; head_len / head_dst match before it starts; learn
//            requests carry the right source MAC, and none for multicast
//            sources; stat_drop pulses once per dropped frame.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_ingress_buf;
    localparam DEPTH = 4096, QD = 8;
    logic clk = 0, rst_n = 0;
    always #3.2 clk = ~clk;                       // 156.25 MHz system clock

    logic [7:0] s_tdata = 0; logic s_tvalid = 0, s_tlast = 0, s_tuser = 0; wire s_tready;
    wire head_valid; wire [10:0] head_len; wire [47:0] head_dst;
    logic xfer = 0, drop = 0, out_tready = 0;
    wire [7:0] out_tdata; wire out_tvalid, out_tlast;
    wire learn_valid; wire [47:0] learn_mac; logic learn_ack = 0;
    wire stat_drop;

    ingress_buf #(.AW(12)) dut (.clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tlast(s_tlast), .s_tuser(s_tuser), .s_tready(s_tready),
        .head_valid(head_valid), .head_len(head_len), .head_dst(head_dst),
        .xfer(xfer), .drop(drop), .out_tdata(out_tdata), .out_tvalid(out_tvalid), .out_tlast(out_tlast), .out_tready(out_tready),
        .learn_valid(learn_valid), .learn_mac(learn_mac), .learn_ack(learn_ack), .stat_drop(stat_drop));

    class frm; byte unsigned d[$]; endclass
    frm          expq[$];                         // committed frames, oldest first
    logic [47:0] learnq[$];                       // expected learn requests, in order

    // model state: bytes / frames that went in and came out
    int committed_bytes = 0, read_bytes = 0, committed_frames = 0, popped_frames = 0;
    int errors = 0, n_sent = 0, n_fwd = 0, n_learn = 0, n_mcast = 0;
    int n_drop_bad = 0, n_drop_short = 0, n_drop_full = 0, n_drop_q = 0, n_drop_switch = 0;
    int exp_stat_drop = 0, got_stat_drop = 0;
    bit stall = 0, busy = 0;
    int ready_pct = 100, drop_pct = 0, drop_len = 0;

    function automatic logic [47:0] mac_at(frm f, int o);
        return {f.d[o], f.d[o+1], f.d[o+2], f.d[o+3], f.d[o+4], f.d[o+5]};
    endfunction

    // ---------------- writer + model ----------------
    task automatic send(int len, bit bad = 0, bit mcast_src = 0, int gap_pct = 0);
        frm f = new(); bit fits = 1, commit;
        f.d = {};
        for (int i = 0; i < len; i++) f.d.push_back(8'($urandom()));
        // bit 0 of the first source byte is the multicast bit
        if (len > 6) f.d[6] = mcast_src ? (f.d[6] | 8'h01) : (f.d[6] & 8'hFE);
        n_sent++;
        for (int i = 0; i < len; i++) begin
            @(negedge clk);
            while ($urandom_range(0, 99) < gap_pct) begin s_tvalid = 0; @(negedge clk); end
            // byte i lands at (unread committed bytes + i); it fits only below DEPTH
            if ((committed_bytes - read_bytes) + i >= DEPTH) fits = 0;
            s_tvalid = 1; s_tdata = f.d[i]; s_tlast = (i == len - 1); s_tuser = bad && (i == len - 1);
        end
        commit = !bad && len >= 14 && fits && (committed_frames - popped_frames < QD);
        if (commit) begin
            expq.push_back(f); committed_bytes += len; committed_frames++;
            if (!mcast_src) learnq.push_back(mac_at(f, 6)); else n_mcast++;
        end else begin
            exp_stat_drop++;
            if (bad)           n_drop_bad++;
            else if (len < 14) n_drop_short++;
            else if (!fits)    n_drop_full++;
            else               n_drop_q++;
        end
        @(negedge clk); s_tvalid = 0; s_tlast = 0; s_tuser = 0;
    endtask

    // ---------------- crossbar stand-in ----------------
    initial forever begin
        @(negedge clk);
        drop = 0;
        if (!busy) xfer = 0;
        if (!busy && head_valid && !stall) begin
            frm e;
            if (expq.size() == 0) begin errors++; $display("ERROR: head_valid with no committed frame"); end
            else begin
                e = expq[0];
                if (head_len != e.d.size() || head_dst != mac_at(e, 0)) begin
                    errors++; $display("ERROR: head descriptor len %0d dst %h, expected %0d %h", head_len, head_dst, e.d.size(), mac_at(e, 0));
                end
                if ($urandom_range(0, 99) < drop_pct) begin
                    drop = 1; drop_len = e.d.size(); e = expq.pop_front(); n_drop_switch++;
                end else begin
                    xfer = 1; busy = 1;
                end
            end
        end
        out_tready = ($urandom_range(0, 99) < ready_pct);
    end

    // ---------------- learn acknowledge: 0..3 cycles late ----------------
    int lwait = 0;
    always @(negedge clk) begin
        if (learn_valid && !learn_ack) begin
            if (lwait == 0) learn_ack = 1; else lwait--;
        end else begin
            learn_ack = 0; lwait = $urandom_range(0, 3);
        end
    end

    // ---------------- monitor ----------------
    byte unsigned got[$];
    // out_t* rules: a stalled beat holds its value, a started frame has no gaps
    // (the TX path relies on this to never underrun), and a frame starts promptly.
    localparam MAX_START_WAIT = 3;
    logic pv = 0, pl = 0; logic [7:0] pd = 0;
    bit   in_frame = 0;
    int   start_wait = 0, max_start_wait = 0;
    always @(posedge clk) if (rst_n) begin
        if (pv && !(out_tvalid && out_tdata == pd && out_tlast == pl)) begin
            errors++; $display("ERROR: stalled out beat changed or dropped at %0t", $time);
        end
        if (in_frame && !out_tvalid) begin
            errors++; $display("ERROR: gap inside an outgoing frame at %0t", $time);
        end
        if (xfer && !out_tvalid && !in_frame) begin
            start_wait++;
            if (start_wait > max_start_wait) max_start_wait = start_wait;
            if (start_wait > MAX_START_WAIT) begin errors++; $display("ERROR: xfer waited %0d clocks for its first byte", start_wait); end
        end else start_wait = 0;
        pv = out_tvalid && !out_tready; pd = out_tdata; pl = out_tlast;
        if (out_tvalid) in_frame = !(out_tready && out_tlast);
    end

    always @(posedge clk) begin
        if (drop && head_valid) begin read_bytes += drop_len; popped_frames++; end
        if (out_tvalid && out_tready) begin
            got.push_back(out_tdata); read_bytes++;
            if (out_tlast) begin
                frm e;
                popped_frames++; busy = 0; n_fwd++;
                if (expq.size() == 0) begin errors++; $display("ERROR: frame out that was never committed"); end
                else begin
                    e = expq.pop_front();
                    if (got.size() != e.d.size()) begin
                        errors++; $display("ERROR: frame %0d length %0d, expected %0d", n_fwd, got.size(), e.d.size());
                    end else foreach (got[i]) if (got[i] != e.d[i]) begin
                        errors++; $display("ERROR: frame %0d byte %0d = %h, expected %h", n_fwd, i, got[i], e.d[i]); break;
                    end
                end
                got = {};
            end
        end
        if (learn_valid && learn_ack) begin
            n_learn++;
            if (learnq.size() == 0) begin errors++; $display("ERROR: unexpected learn request %h", learn_mac); end
            else if (learn_mac != learnq[0]) begin errors++; $display("ERROR: learn %h, expected %h", learn_mac, learnq[0]); void'(learnq.pop_front()); end
            else void'(learnq.pop_front());
        end
        if (stat_drop) got_stat_drop++;
    end

    task automatic drain();
        int t = 0;
        while ((expq.size() != 0 || busy) && t < 100000) begin @(negedge clk); t++; end
        repeat (10) @(negedge clk);
    endtask

    // ---------------- test sequence ----------------
    initial begin
        int full0;
        repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);

        // 1. directed: header-length limit, a bad frame, a multicast source
        send(14); send(13); send(100, 1); send(60, 0, 1); send(1514);
        drain();

        // 2. reader stalled: 8 descriptors fit, the 9th frame must be dropped
        stall = 1; repeat (9) send(60); stall = 0;
        drain();

        // 3. reader stalled: fill the 4096-byte buffer to the last byte
        full0 = n_drop_full;
        stall = 1;
        send(1514); send(1514);                  // 3028 bytes
        send(1514);                              // would need 4542 -> dropped
        send(1068);                              // exactly 4096 -> kept
        send(14);                                // buffer is full -> dropped
        stall = 0;
        drain();
        if (n_drop_full - full0 != 2) begin errors++; $display("ERROR: buffer-full phase dropped %0d frames, expected 2", n_drop_full - full0); end

        // 4. random traffic with backpressure, switch drops and reader stalls
        ready_pct = 70; drop_pct = 10;
        for (int i = 0; i < 2000; i++) begin
            int r = $urandom_range(0, 99);
            stall = (i % 200) >= 170;            // 30 frames in every 200 with a frozen reader
            if      (r < 55) send($urandom_range(14, 1514), 0, 0, 10);
            else if (r < 65) send($urandom_range(14, 64));
            else if (r < 73) send($urandom_range(14, 1514), 1);
            else if (r < 80) send($urandom_range(1, 13));
            else if (r < 90) send($urandom_range(14, 1514), 0, 1);
            else             send(1514);
            repeat ($urandom_range(0, 20)) @(negedge clk);
        end
        stall = 0;
        drain();

        if (expq.size() != 0)   begin errors++; $display("ERROR: %0d committed frames never came out", expq.size()); end
        if (learnq.size() != 0) begin errors++; $display("ERROR: %0d learn requests never raised", learnq.size()); end
        if (got_stat_drop != exp_stat_drop) begin errors++; $display("ERROR: stat_drop pulsed %0d times, expected %0d", got_stat_drop, exp_stat_drop); end
        if (n_drop_bad == 0 || n_drop_short == 0 || n_drop_full == 0 || n_drop_q == 0 || n_drop_switch == 0) begin
            errors++; $display("ERROR: coverage hole: some drop reason never happened");
        end
        $display("frames written %0d: forwarded %0d, dropped by switch %0d", n_sent, n_fwd, n_drop_switch);
        $display("  rejected: bad %0d, short %0d, buffer full %0d, queue full %0d  (stat_drop %0d)",
                 n_drop_bad, n_drop_short, n_drop_full, n_drop_q, got_stat_drop);
        $display("  learn requests %0d (%0d multicast sources correctly not learned)", n_learn, n_mcast);
        $display("  longest wait from xfer to first byte: %0d clocks (limit %0d)", max_start_wait, MAX_START_WAIT);
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
