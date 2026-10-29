// ***************************************************************************
// GlideLink shell: RX streamer
//
// Takes the AD9361 channel 0 samples (l_clk, valid-qualified, cannot be held
// off), cuts them into packets of pkt_len samples and passes them to the
// processing clock as AXI4-Stream:
//   tdata = {Q, I}, tlast on the last sample,
//   tuser = {flags[7:0], timestamp[63:0]} (sample counter value of the first
//           sample; held for the whole packet),
//   flags bit 0 = packets were dropped before this one.
// A packet is only started when the FIFO has room for all of it; otherwise
// it is dropped as a whole and counted in overflow (Gray-coded, l_clk).
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_rx_stream #(
  parameter FIFO_ADDR_WIDTH = 13,          // 8192 samples
  parameter HDR_ADDR_WIDTH = 4
) (
  // sample side
  input             l_clk,
  input             l_rst,
  input             adc_valid,
  input     [15:0]  adc_data_i,
  input     [15:0]  adc_data_q,
  input     [63:0]  time_now,             // sample counter, l_clk
  input     [15:0]  pkt_len,              // samples per packet, 1..2^FIFO_ADDR_WIDTH; quasi-static
  input             enable,               // quasi-static; packets start only while set
  output    [31:0]  overflow_gray,
  output            adc_dovf,             // to axi_ad9361: a packet was dropped

  // processing side
  input             m_clk,
  input             m_rst,
  output    [31:0]  m_axis_tdata,
  output    [71:0]  m_axis_tuser,
  output            m_axis_tlast,
  output            m_axis_tvalid,
  input             m_axis_tready
);

  wire [FIFO_ADDR_WIDTH:0] wr_level;
  wire [HDR_ADDR_WIDTH:0]  hdr_level;
  wire [32:0] data_out;
  wire        data_empty;
  wire [71:0] hdr_out;
  wire        hdr_empty;
  wire        l_reset, m_reset;           // either side reset resets both

  // ---------------------------------------------------------------------------
  // l_clk: packetiser

  reg  [15:0] remaining = 16'd0;          // samples left in the current packet after this one (0 = between packets)
  reg         dropping = 1'b0;            // the current packet is being dropped
  reg         dropped = 1'b0;             // a packet was dropped since the last written one
  reg  [31:0] overflow = 32'd0;
  reg  [31:0] overflow_g = 32'd0;
  reg         dovf = 1'b0;

  wire        room = ({1'b0, wr_level} + pkt_len <= (1 << FIFO_ADDR_WIDTH)) &&
                     (hdr_level < (1 << HDR_ADDR_WIDTH));
  wire        start = adc_valid && remaining == 16'd0 && enable;
  wire        data_wr = adc_valid && (start ? room : (remaining != 16'd0 && !dropping));
  wire        data_last = start ? (pkt_len == 16'd1) : (remaining == 16'd1);
  wire        hdr_wr = start && room;

  always @(posedge l_clk) begin
    if (l_reset) begin
      remaining <= 16'd0;
      dropping <= 1'b0;
      dropped <= 1'b0;
      dovf <= 1'b0;
    end else begin
      dovf <= 1'b0;
      if (start) begin
        remaining <= pkt_len - 16'd1;
        dropping <= !room;
        if (room) begin
          dropped <= 1'b0;
        end else begin
          dropped <= 1'b1;
          overflow <= overflow + 32'd1;
          dovf <= 1'b1;
        end
      end else if (adc_valid && remaining != 16'd0) begin
        remaining <= remaining - 16'd1;
      end
    end
    overflow_g <= overflow ^ (overflow >> 1);
  end

  assign overflow_gray = overflow_g;
  assign adc_dovf = dovf;

  // ---------------------------------------------------------------------------
  // m_clk: one header per packet, data beats until tlast

  reg         in_pkt = 1'b0;              // header taken, packet data flowing
  reg  [71:0] user = 72'd0;

  wire        beat = m_axis_tvalid && m_axis_tready;
  wire        hdr_rd = !in_pkt && !hdr_empty;

  always @(posedge m_clk) begin
    if (m_reset) begin
      in_pkt <= 1'b0;
    end else if (hdr_rd) begin
      in_pkt <= 1'b1;
      user <= hdr_out;
    end else if (beat && data_out[32]) begin
      in_pkt <= 1'b0;
    end
  end

  assign m_axis_tdata = data_out[31:0];
  assign m_axis_tlast = data_out[32];
  assign m_axis_tuser = user;
  assign m_axis_tvalid = in_pkt && !data_empty;

  // ---------------------------------------------------------------------------

  glidelink_async_fifo #(.WIDTH(33), .ADDR_WIDTH(FIFO_ADDR_WIDTH)) i_data_fifo (
    .wr_clk(l_clk), .wr_rst(l_rst), .wr_en(data_wr),
    .wr_data({data_last, adc_data_q, adc_data_i}),
    .wr_full(), .wr_level(wr_level), .wr_in_reset(l_reset),
    .rd_clk(m_clk), .rd_rst(m_rst), .rd_en(beat),
    .rd_data(data_out), .rd_empty(data_empty), .rd_level(), .rd_in_reset(m_reset));

  glidelink_async_fifo #(.WIDTH(72), .ADDR_WIDTH(HDR_ADDR_WIDTH)) i_hdr_fifo (
    .wr_clk(l_clk), .wr_rst(l_rst), .wr_en(hdr_wr),
    .wr_data({7'd0, dropped, time_now}),
    .wr_full(), .wr_level(hdr_level), .wr_in_reset(),
    .rd_clk(m_clk), .rd_rst(m_rst), .rd_en(hdr_rd),
    .rd_data(hdr_out), .rd_empty(hdr_empty), .rd_level(), .rd_in_reset());

endmodule
