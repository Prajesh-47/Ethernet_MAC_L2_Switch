// -----------------------------------------------------------------------------
// eth_mac_rx.v -- GMII receive path (runs on the PHY's rx clock, 125 MHz)
//
//   GMII  : rxd[7:0], rx_dv (frame present), rx_er (PHY-signalled error)
//   output: AXI4-Stream bytes of the frame WITHOUT preamble, SFD or FCS;
//           m_tuser on the m_tlast beat = 1 means "bad frame, drop it"
//
// Frame on the wire:  0x55 x7 | 0xD5 (SFD) | dst(6) src(6) type(2) payload | FCS(4)
//
// The FCS is only known to be the FCS when rx_dv falls, so bytes are delayed
// through a 5-byte shift register: when the frame ends it holds
// [last data byte, FCS0..FCS3]; the last data byte goes out with tlast and the
// FCS bytes are discarded.
//
// Bad frame (tuser = 1) when any of:
//   * CRC residue != 0xDEBB20E3        (bit error, or bad FCS)
//   * length < 64 bytes incl. FCS      (runt)
//   * length > 1518 bytes incl. FCS    (oversized, no VLAN support)
//   * rx_er seen during the frame
//   * the output FIFO overflowed       (GMII cannot be back-pressured)
// -----------------------------------------------------------------------------
`default_nettype none
module eth_mac_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] gmii_rxd,
    input  wire       gmii_rx_dv,
    input  wire       gmii_rx_er,
    output reg  [7:0] m_tdata,
    output reg        m_tvalid,
    output reg        m_tlast,
    output reg        m_tuser,
    input  wire       m_tready,
    output reg        stat_good,      // one-cycle pulses for counters
    output reg        stat_bad
);
`include "crc32.vh"
    localparam MIN_LEN = 64, MAX_LEN = 1518;
    localparam S_IDLE = 2'd0, S_PRE = 2'd1, S_DATA = 2'd2, S_DRAIN = 2'd3;

    // register the GMII inputs once (they come from pins / a PHY)
    reg [7:0] rxd;  reg dv, er;
    always @(posedge clk) begin rxd <= gmii_rxd; dv <= gmii_rx_dv; er <= gmii_rx_er; end

    reg [1:0]  st;
    reg [31:0] crc;
    reg [10:0] len;                 // bytes after SFD, incl. FCS (saturates)
    reg [39:0] dly;                 // 5-byte delay line, newest in [7:0]
    reg        saw_er, ovf;

    // a beat is "lost" if we present it while the FIFO is full
    wire lost = m_tvalid && !m_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; m_tvalid <= 0; m_tlast <= 0; m_tuser <= 0; m_tdata <= 0;
            crc <= 32'hFFFFFFFF; len <= 0; dly <= 0; saw_er <= 0; ovf <= 0;
            stat_good <= 0; stat_bad <= 0;
        end else begin
            stat_good <= 0; stat_bad <= 0;
            // default: a data beat lasts one cycle (no back-pressure on GMII)
            if (!(m_tvalid && m_tlast)) m_tvalid <= 1'b0;
            if (lost && !m_tlast) ovf <= 1'b1;

            case (st)
                S_IDLE: if (dv && rxd == 8'h55) st <= S_PRE;
                S_PRE: begin
                    if (!dv)               st <= S_IDLE;
                    else if (rxd == 8'hD5) begin
                        st <= S_DATA; crc <= 32'hFFFFFFFF; len <= 0;
                        saw_er <= er; ovf <= 0;
                    end else if (rxd != 8'h55) st <= S_IDLE;   // not a preamble
                end
                S_DATA: begin
                    if (dv) begin
                        crc <= crc32_byte(crc, rxd);
                        if (len != 11'h7FF) len <= len + 1'b1;
                        dly <= {dly[31:0], rxd};
                        if (er) saw_er <= 1'b1;
                        if (len >= 5) begin                   // oldest byte leaves the delay line
                            m_tdata <= dly[39:32]; m_tvalid <= 1'b1; m_tlast <= 1'b0; m_tuser <= 1'b0;
                        end
                    end else begin
                        // end of frame: emit the held last data byte with tlast + verdict
                        m_tdata  <= (len >= 5) ? dly[39:32] : 8'h00;
                        m_tvalid <= 1'b1;
                        m_tlast  <= 1'b1;
                        m_tuser  <= (crc != 32'hDEBB20E3) || (len < MIN_LEN) || (len > MAX_LEN)
                                    || saw_er || ovf || lost;
                        if ((crc == 32'hDEBB20E3) && (len >= MIN_LEN) && (len <= MAX_LEN)
                            && !saw_er && !ovf && !lost) stat_good <= 1'b1;
                        else stat_bad <= 1'b1;
                        st <= S_DRAIN;
                    end
                end
                // hold the tlast beat until the FIFO takes it (inter-frame gap +
                // preamble give >= 20 cycles before the next frame's data)
                S_DRAIN: if (m_tready) begin m_tvalid <= 1'b0; m_tlast <= 1'b0; st <= S_IDLE; end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
