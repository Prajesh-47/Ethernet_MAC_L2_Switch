// -----------------------------------------------------------------------------
// eth_mac.v -- 1G Ethernet MAC: GMII on one side, AXI4-Stream in the SYSTEM
// clock domain on the other. The clock-domain crossing is done by the async
// FIFO from the async_fifo project (reused unchanged, plus its s_fill port).
//
//   GMII rx clock --> eth_mac_rx --> async_fifo (10b: user,last,data) --> sys
//   sys --> async_fifo (9b: last,data) --> eth_mac_tx --> GMII tx clock
//
// Each clock domain gets its own reset synchronizer.
// -----------------------------------------------------------------------------
`default_nettype none
module eth_mac (
    input  wire       sys_clk,
    input  wire       sys_rst_n,       // raw async reset, all domains
    // GMII
    input  wire       gmii_rx_clk,
    input  wire [7:0] gmii_rxd,
    input  wire       gmii_rx_dv,
    input  wire       gmii_rx_er,
    input  wire       gmii_tx_clk,
    output wire [7:0] gmii_txd,
    output wire       gmii_tx_en,
    output wire       gmii_tx_er,
    // received frames, sys clock (tuser on tlast = bad frame)
    output wire [7:0] rx_tdata,
    output wire       rx_tvalid,
    output wire       rx_tlast,
    output wire       rx_tuser,
    input  wire       rx_tready,
    // frames to send, sys clock
    input  wire [7:0] tx_tdata,
    input  wire       tx_tvalid,
    input  wire       tx_tlast,
    output wire       tx_tready,
    output reg        tx_fifo_empty,   // sys-side view: egress FIFO holds nothing (see below)
    // status (in their own clock domains)
    output wire       stat_rx_good,
    output wire       stat_rx_bad,
    output wire       stat_tx_underrun,
    output wire       stat_tx_frame
);
    wire rx_rst_n, tx_rst_n;
    reset_sync u_rxr (.clk(gmii_rx_clk), .rst_n_in(sys_rst_n), .rst_n_out(rx_rst_n));
    reset_sync u_txr (.clk(gmii_tx_clk), .rst_n_in(sys_rst_n), .rst_n_out(tx_rst_n));

    // ---------------- receive ----------------
    wire [7:0] r_data; wire r_valid, r_last, r_user, r_ready;
    eth_mac_rx u_rx (
        .clk(gmii_rx_clk), .rst_n(rx_rst_n),
        .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
        .m_tdata(r_data), .m_tvalid(r_valid), .m_tlast(r_last), .m_tuser(r_user), .m_tready(r_ready),
        .stat_good(stat_rx_good), .stat_bad(stat_rx_bad));

    async_fifo #(.DW(10), .AW(5)) u_rx_fifo (
        .s_aclk(gmii_rx_clk), .s_aresetn(sys_rst_n),
        .s_axis_tdata({r_user, r_last, r_data}), .s_axis_tvalid(r_valid), .s_axis_tready(r_ready),
        .s_almost_full(), .s_fill(),
        .m_aclk(sys_clk), .m_aresetn(sys_rst_n),
        .m_axis_tdata({rx_tuser, rx_tlast, rx_tdata}), .m_axis_tvalid(rx_tvalid),
        .m_axis_tready(rx_tready), .m_almost_empty());

    // ---------------- transmit ----------------
    wire [7:0] t_data; wire t_valid, t_last, t_ready;
    wire [5:0] tx_fill;

    // Register slice before the FIFO, so the switch's crossbar does not run into
    // the FIFO's write pointer logic in one cycle.
    wire sys_rst_sync_n;
    reset_sync u_sysr (.clk(sys_clk), .rst_n_in(sys_rst_n), .rst_n_out(sys_rst_sync_n));
    wire [8:0] f_data; wire f_valid, f_ready, skid_empty;
    axis_skid #(.DW(9)) u_tx_skid (
        .clk(sys_clk), .rst_n(sys_rst_sync_n),
        .s_tdata({tx_tlast, tx_tdata}), .s_tvalid(tx_tvalid), .s_tready(tx_tready),
        .m_tdata(f_data), .m_tvalid(f_valid), .m_tready(f_ready), .empty(skid_empty));

    async_fifo #(.DW(9), .AW(5)) u_tx_fifo (
        .s_aclk(sys_clk), .s_aresetn(sys_rst_n),
        .s_axis_tdata(f_data), .s_axis_tvalid(f_valid), .s_axis_tready(f_ready),
        .s_almost_full(), .s_fill(tx_fill),
        .m_aclk(gmii_tx_clk), .m_aresetn(sys_rst_n),
        .m_axis_tdata({t_last, t_data}), .m_axis_tvalid(t_valid),
        .m_axis_tready(t_ready), .m_almost_empty());

    // Registered, because tx_fill is a Gray decode plus a subtraction and this
    // flag feeds the switch's arbiter. A word entering the slice clears it straight
    // away: it may say "not empty" a cycle too long, which is safe, but it never
    // says "empty" while the slice or the FIFO holds data (the switch relies on
    // that to grant a port).
    always @(posedge sys_clk or negedge sys_rst_sync_n) begin
        if (!sys_rst_sync_n) tx_fifo_empty <= 1'b0;
        else                 tx_fifo_empty <= (tx_fill == 6'd0) && skid_empty && !(tx_tvalid && tx_tready);
    end

    eth_mac_tx u_tx (
        .clk(gmii_tx_clk), .rst_n(tx_rst_n),
        .s_tdata(t_data), .s_tvalid(t_valid), .s_tlast(t_last), .s_tready(t_ready),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .stat_underrun(stat_tx_underrun), .stat_frame(stat_tx_frame));
endmodule
`default_nettype wire
