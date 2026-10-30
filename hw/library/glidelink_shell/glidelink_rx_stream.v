// ***************************************************************************
// GlideLink shell: RX streamer
//
// Takes the AD9361 channel 0 samples (l_clk, valid-qualified, cannot be held
// off), cuts them into packets of pkt_len samples and passes them to the
// processing clock as AXI4-Stream:
//   tdata = {Q, I}, each the 12-bit ADC sample shifted left by 4 (16-bit
//           full scale, as the DAC side), tlast on the last sample,
//   tuser = {flags[7:0], timestamp[63:0]} (sample counter value of the first
//           sample; held for the whole packet),
//   flags bit 0 = packets were dropped before this one.
// Every sample crosses to the processing clock with its timestamp through a
// small LUTRAM FIFO, which the processing side empties every cycle (it runs
// much faster than the sample rate). There the samples are cut into packets
// and buffered in URAM: a packet is only started when the buffer has room for
// all of it; otherwise it is dropped as a whole and counted in overflow
// (Gray-coded, processing clock). Should the crossing FIFO ever fill (it
// cannot at the sample rates the AD9361 supports), the lost samples leave a
// gap that is counted in overflow and flagged on the next packet.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_rx_stream #(
  parameter FIFO_ADDR_WIDTH = 13,          // 8192 samples (URAM)
  parameter HDR_ADDR_WIDTH = 4,
  parameter CDC_ADDR_WIDTH = 5             // crossing FIFO, 32 samples (LUTRAM)
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
  output            adc_dovf,             // to axi_ad9361 (l_clk): a packet was dropped

  // processing side
  input             m_clk,
  input             m_rst,
  output    [31:0]  m_axis_tdata,
  output    [71:0]  m_axis_tuser,
  output            m_axis_tlast,
  output            m_axis_tvalid,
  input             m_axis_tready
);

  wire        l_reset, m_reset;           // either side's reset resets both

  // ---------------------------------------------------------------------------
  // l_clk: every sample with its timestamp into the crossing FIFO

  wire        cdc_full;
  reg         cdc_lost = 1'b0;            // a sample found the crossing FIFO full

  always @(posedge l_clk)
    cdc_lost <= adc_valid && cdc_full;

  wire [95:0] cdc_out;                    // {time, Q, I}
  wire        cdc_empty;

  glidelink_async_fifo #(.WIDTH(96), .ADDR_WIDTH(CDC_ADDR_WIDTH), .RAM_STYLE("distributed")) i_cdc_fifo (
    .wr_clk(l_clk), .wr_rst(l_rst), .wr_en(adc_valid),
    .wr_data({time_now, adc_data_q[11:0], 4'd0, adc_data_i[11:0], 4'd0}),
    .wr_full(cdc_full), .wr_level(), .wr_in_reset(l_reset),
    .rd_clk(m_clk), .rd_rst(m_rst), .rd_en(!cdc_empty),
    .rd_data(cdc_out), .rd_empty(cdc_empty), .rd_level(), .rd_in_reset(m_reset));

  // a lost sample breaks the packet in progress: toggle across, drop it
  reg         lost_t = 1'b0;
  always @(posedge l_clk) if (cdc_lost) lost_t <= !lost_t;
  (* ASYNC_REG = "TRUE" *) reg [1:0] lost_m = 2'b00;
  reg         lost_d = 1'b0;
  always @(posedge m_clk) begin
    lost_m <= {lost_m[0], lost_t};
    lost_d <= lost_m[1];
  end
  wire        lost = lost_m[1] != lost_d;

  // ---------------------------------------------------------------------------
  // m_clk: packetiser into the URAM buffer

  wire        smp = !cdc_empty;           // a sample this cycle
  wire [FIFO_ADDR_WIDTH:0] wr_level;
  wire [HDR_ADDR_WIDTH:0]  hdr_level;
  wire [32:0] data_out;
  wire        data_empty;
  wire [71:0] hdr_out;
  wire        hdr_empty;
  wire        beat, hdr_rd;                // output side (below)

  reg  [15:0] remaining = 16'd0;          // samples left in the current packet after this one (0 = between packets)
  reg         dropping = 1'b0;            // the current packet is being dropped
  reg         dropped = 1'b0;             // a packet was dropped since the last written one
  reg  [31:0] overflow = 32'd0;
  reg  [31:0] overflow_g = 32'd0;
  reg         dovf_t = 1'b0;

  wire        room = ({1'b0, wr_level} + pkt_len <= (1 << FIFO_ADDR_WIDTH)) &&
                     (hdr_level < (1 << HDR_ADDR_WIDTH));
  wire        start = smp && remaining == 16'd0 && enable;
  wire        keep = start ? room : (remaining != 16'd0 && !dropping);
  wire        data_wr = smp && keep;
  wire        data_last = start ? (pkt_len == 16'd1) : (remaining == 16'd1);
  wire        hdr_wr = start && room;

  always @(posedge m_clk) begin
    if (m_reset) begin
      remaining <= 16'd0;
      dropping <= 1'b0;
      dropped <= 1'b0;
    end else begin
      if (start) begin
        remaining <= pkt_len - 16'd1;
        dropping <= !room;
        if (room) begin
          dropped <= 1'b0;
        end else begin
          dropped <= 1'b1;
          overflow <= overflow + 32'd1;
          dovf_t <= !dovf_t;
        end
      end else if (smp && remaining != 16'd0) begin
        remaining <= remaining - 16'd1;
      end
      if (lost) begin                     // samples lost in the crossing
        dropped <= 1'b1;
        overflow <= overflow + 32'd1;
        dovf_t <= !dovf_t;
      end
    end
    overflow_g <= overflow ^ (overflow >> 1);
  end

  assign overflow_gray = overflow_g;

  // the drop pulse for axi_ad9361, in l_clk
  (* ASYNC_REG = "TRUE" *) reg [1:0] dovf_l = 2'b00;
  reg         dovf_ld = 1'b0;
  always @(posedge l_clk) begin
    dovf_l <= {dovf_l[0], dovf_t};
    dovf_ld <= dovf_l[1];
  end
  assign adc_dovf = dovf_l[1] != dovf_ld;

  glidelink_fifo #(.WIDTH(33), .ADDR_WIDTH(FIFO_ADDR_WIDTH), .RAM_STYLE("ultra")) i_data_fifo (
    .clk(m_clk), .rst(m_reset), .wr_en(data_wr),
    .wr_data({data_last, cdc_out[31:0]}), .full(),
    .rd_en(beat), .rd_data(data_out), .empty(data_empty), .level(wr_level));

  glidelink_fifo #(.WIDTH(72), .ADDR_WIDTH(HDR_ADDR_WIDTH), .RAM_STYLE("distributed")) i_hdr_fifo (
    .clk(m_clk), .rst(m_reset), .wr_en(hdr_wr),
    .wr_data({7'd0, dropped, cdc_out[95:32]}), .full(),
    .rd_en(hdr_rd), .rd_data(hdr_out), .empty(hdr_empty), .level(hdr_level));

  // ---------------------------------------------------------------------------
  // m_clk: one header per packet, data beats until tlast

  reg         in_pkt = 1'b0;              // header taken, packet data flowing
  reg  [71:0] user = 72'd0;

  assign beat = m_axis_tvalid && m_axis_tready;
  assign hdr_rd = !in_pkt && !hdr_empty;

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

endmodule
