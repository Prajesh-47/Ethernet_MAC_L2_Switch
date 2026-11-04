// -----------------------------------------------------------------------------
// eth_mac_tx.v -- GMII transmit path (runs on the 125 MHz GTX clock)
//
//   input : AXI4-Stream frame bytes (dst, src, type, payload), no FCS
//   GMII  : txd[7:0], tx_en, tx_er
//
// Sequence per frame:
//   PRE  : 7 x 0x55          SFD : 0xD5
//   DATA : frame bytes from the stream (tready = 1 only here)
//   PAD  : 0x00 until 60 bytes have been sent (64 with FCS = minimum frame)
//   FCS  : ~CRC, least significant byte first
//   IFG  : 12 idle byte times before the next preamble
// CRC covers DATA + PAD (not preamble/SFD).
//
// Underrun: if the stream runs dry in the middle of a frame (tvalid = 0 before
// tlast), the frame is corrupt. GMII marks that with tx_er; stat_underrun
// pulses and the FSM keeps going so the frame ends cleanly. The switch is
// designed so this cannot happen (see guide, "egress admission").
// -----------------------------------------------------------------------------
`default_nettype none
module eth_mac_tx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] s_tdata,
    input  wire       s_tvalid,
    input  wire       s_tlast,
    output wire       s_tready,
    output reg  [7:0] gmii_txd,
    output reg        gmii_tx_en,
    output reg        gmii_tx_er,
    output reg        stat_underrun,
    output reg        stat_frame          // pulses once per frame sent
);
`include "crc32.vh"
    localparam S_IDLE = 3'd0, S_PRE = 3'd1, S_DATA = 3'd2, S_PAD = 3'd3,
               S_FCS = 3'd4, S_IFG = 3'd5;
    reg [2:0]  st;
    reg [3:0]  cnt;          // preamble / FCS / IFG counter
    reg [10:0] nbytes;       // DATA + PAD bytes sent
    reg [31:0] crc;

    assign s_tready = (st == S_DATA);

    wire [31:0] fcs = ~crc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; cnt <= 0; nbytes <= 0; crc <= 32'hFFFFFFFF;
            gmii_txd <= 8'h00; gmii_tx_en <= 1'b0; gmii_tx_er <= 1'b0;
            stat_underrun <= 1'b0; stat_frame <= 1'b0;
        end else begin
            stat_underrun <= 1'b0; stat_frame <= 1'b0; gmii_tx_er <= 1'b0;
            case (st)
                S_IDLE: begin
                    gmii_tx_en <= 1'b0; gmii_txd <= 8'h00;
                    if (s_tvalid) begin st <= S_PRE; cnt <= 0; end
                end
                S_PRE: begin
                    gmii_tx_en <= 1'b1;
                    if (cnt < 7) begin gmii_txd <= 8'h55; cnt <= cnt + 1'b1; end
                    else begin
                        gmii_txd <= 8'hD5;                       // SFD
                        st <= S_DATA; nbytes <= 0; crc <= 32'hFFFFFFFF;
                    end
                end
                S_DATA: begin
                    gmii_tx_en <= 1'b1;
                    if (s_tvalid) begin
                        gmii_txd <= s_tdata;
                        crc      <= crc32_byte(crc, s_tdata);
                        nbytes   <= nbytes + 1'b1;
                        if (s_tlast) st <= (nbytes + 1 < 60) ? S_PAD : S_FCS;
                        cnt <= 0;
                    end else begin
                        // underrun mid-frame: send an error byte, flag it
                        gmii_txd <= 8'h00; gmii_tx_er <= 1'b1;
                        stat_underrun <= 1'b1;
                    end
                end
                S_PAD: begin
                    gmii_tx_en <= 1'b1;
                    gmii_txd   <= 8'h00;
                    crc        <= crc32_byte(crc, 8'h00);
                    nbytes     <= nbytes + 1'b1;
                    if (nbytes + 1 >= 60) begin st <= S_FCS; cnt <= 0; end
                end
                S_FCS: begin
                    gmii_tx_en <= 1'b1;
                    case (cnt[1:0])
                        2'd0: gmii_txd <= fcs[7:0];
                        2'd1: gmii_txd <= fcs[15:8];
                        2'd2: gmii_txd <= fcs[23:16];
                        2'd3: gmii_txd <= fcs[31:24];
                    endcase
                    if (cnt == 3) begin st <= S_IFG; cnt <= 0; stat_frame <= 1'b1; end
                    else cnt <= cnt + 1'b1;
                end
                S_IFG: begin
                    gmii_tx_en <= 1'b0; gmii_txd <= 8'h00;
                    if (cnt == 11) st <= S_IDLE; else cnt <= cnt + 1'b1;
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
