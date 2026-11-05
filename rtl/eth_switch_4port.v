// -----------------------------------------------------------------------------
// eth_switch_4port.v -- 4-port Layer-2 learning switch
//
//   port p: GMII <-> eth_mac (CDC via async FIFOs) <-> ingress_buf (sys clock)
//   shared: mac_table (learning + lookup), switch_core (decision, arbitration,
//           crossbar)
//
//   GMII signals are packed 4 ports wide: port p uses bits [8p +: 8] / [p].
// -----------------------------------------------------------------------------
`default_nettype none
module eth_switch_4port (
    input  wire        sys_clk,
    input  wire        rst_n,
    input  wire [3:0]  gmii_rx_clk,
    input  wire [31:0] gmii_rxd,
    input  wire [3:0]  gmii_rx_dv,
    input  wire [3:0]  gmii_rx_er,
    input  wire [3:0]  gmii_tx_clk,
    output wire [31:0] gmii_txd,
    output wire [3:0]  gmii_tx_en,
    output wire [3:0]  gmii_tx_er,
    // statistics (pulses)
    output wire [3:0]  stat_rx_good,      // gmii rx clock domains
    output wire [3:0]  stat_rx_bad,
    output wire [3:0]  stat_tx_underrun,  // gmii tx clock domains
    output wire [3:0]  stat_tx_frame,
    output wire [3:0]  stat_ingress_drop, // sys clock
    output wire [3:0]  stat_flood,
    output wire [3:0]  stat_filter
);
    wire srst_n;
    reset_sync u_sr (.clk(sys_clk), .rst_n_in(rst_n), .rst_n_out(srst_n));

    wire [31:0]  rx_d;  wire [3:0] rx_v, rx_l, rx_u, rx_r;
    wire [31:0]  tx_d;  wire [3:0] tx_v, tx_l, tx_r, tx_empty;
    wire [3:0]   hv;    wire [191:0] hdst;  wire [43:0] hlen;
    wire [3:0]   xfer, drop;
    wire [31:0]  o_d;   wire [3:0] o_v, o_l, o_r;
    wire [3:0]   ln_v, ln_ack;  wire [191:0] ln_mac;
    wire [3:0]   lk_valid, lk_hit; wire [7:0] lk_port;

    genvar p;
    generate
        for (p = 0; p < 4; p = p + 1) begin : g_port
            eth_mac u_mac (
                .sys_clk(sys_clk), .sys_rst_n(rst_n),
                .gmii_rx_clk(gmii_rx_clk[p]), .gmii_rxd(gmii_rxd[8*p +: 8]),
                .gmii_rx_dv(gmii_rx_dv[p]), .gmii_rx_er(gmii_rx_er[p]),
                .gmii_tx_clk(gmii_tx_clk[p]), .gmii_txd(gmii_txd[8*p +: 8]),
                .gmii_tx_en(gmii_tx_en[p]), .gmii_tx_er(gmii_tx_er[p]),
                .rx_tdata(rx_d[8*p +: 8]), .rx_tvalid(rx_v[p]), .rx_tlast(rx_l[p]),
                .rx_tuser(rx_u[p]), .rx_tready(rx_r[p]),
                .tx_tdata(tx_d[8*p +: 8]), .tx_tvalid(tx_v[p]), .tx_tlast(tx_l[p]),
                .tx_tready(tx_r[p]), .tx_fifo_empty(tx_empty[p]),
                .stat_rx_good(stat_rx_good[p]), .stat_rx_bad(stat_rx_bad[p]),
                .stat_tx_underrun(stat_tx_underrun[p]), .stat_tx_frame(stat_tx_frame[p]));

            ingress_buf #(.PORT(p)) u_ib (
                .clk(sys_clk), .rst_n(srst_n),
                .s_tdata(rx_d[8*p +: 8]), .s_tvalid(rx_v[p]), .s_tlast(rx_l[p]),
                .s_tuser(rx_u[p]), .s_tready(rx_r[p]),
                .head_valid(hv[p]), .head_len(hlen[11*p +: 11]), .head_dst(hdst[48*p +: 48]),
                .xfer(xfer[p]), .drop(drop[p]),
                .out_tdata(o_d[8*p +: 8]), .out_tvalid(o_v[p]), .out_tlast(o_l[p]), .out_tready(o_r[p]),
                .learn_valid(ln_v[p]), .learn_mac(ln_mac[48*p +: 48]), .learn_ack(ln_ack[p]),
                .stat_drop(stat_ingress_drop[p]));
        end
    endgenerate

    mac_table u_tbl (
        .clk(sys_clk), .rst_n(srst_n),
        .lk_en(hv), .lk_mac(hdst), .lk_valid(lk_valid), .lk_hit(lk_hit), .lk_port(lk_port),
        .ln_valid(ln_v), .ln_mac(ln_mac), .ln_ack(ln_ack));

    switch_core u_core (
        .clk(sys_clk), .rst_n(srst_n),
        .head_valid(hv), .head_dst(hdst), .lk_valid(lk_valid), .lk_hit(lk_hit), .lk_port(lk_port),
        .xfer(xfer), .drop(drop),
        .in_tdata(o_d), .in_tvalid(o_v), .in_tlast(o_l), .in_tready(o_r),
        .eg_empty(tx_empty), .eg_tdata(tx_d), .eg_tvalid(tx_v), .eg_tlast(tx_l), .eg_tready(tx_r),
        .stat_flood(stat_flood), .stat_filter(stat_filter));
endmodule
`default_nettype wire
