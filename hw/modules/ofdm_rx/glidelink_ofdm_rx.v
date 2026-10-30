// ***************************************************************************
// GlideLink user module: OFDM receiver of the DeepJSCC-Q link (from the
// competition design, docs/phase4_plan.md; description: module.yaml).
//
// Input: 20 MSPS baseband samples from the RF RX streamer, {Q[31:16], I[15:0]}
// at 16-bit full scale (the 12-bit ADC value shifted left by 4); packets and
// timestamps are ignored, the samples are taken as one continuous stream.
// Output: equalised soft symbols, {Q[31:16], I[15:0]} with each half the
// 12-bit Q10 value sign-extended, 32768 per frame, tlast on the last one.
//
// Chain (competition RTL, unchanged): frame detection + CFO (STF), LTF timing,
// CP removal, FFT (Xilinx IP), channel estimate (two LTFs), equalisation, SFO
// and CPE tracking, PN sign descrambling + deframing -> URAM frame buffer
// (complete frames, 2.25 frames; it never holds the PHY off: a frame finding
// it full is dropped and counted).
//
// Registers (4 KB window):
//   0x000  ID          RO  0x4F465258 ("OFRX")
//   0x004  VERSION     RO  {major[15:0], minor[7:0], patch[7:0]}
//   0x008  CONTROL     RW  bit 0: enable (default 1; 0 drops the input),
//                          bit 1: soft reset (self-clearing)
//   0x00C  STATUS      RO  bit 0: enabled
//   0x010  FRAMES_IN   RO  frames the PHY delivered into the frame buffer (the
//                          receive rate for an AGC watchdog)
//   0x014  DROPPED     RO  frames dropped because the frame buffer was full
//   0x018  FRAMES_OUT  RO  frames sent on
//   0x01C  SAMPLES     RO  input samples taken
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_ofdm_rx #(
  parameter NSYM = 683,
  parameter FRAME_SYMS = 32768
) (
  input             clk,                    // 100 MHz slot
  input             rstn,
  input             flush,

  input             s_axil_awvalid,
  output            s_axil_awready,
  input     [11:0]  s_axil_awaddr,
  input             s_axil_wvalid,
  output            s_axil_wready,
  input     [31:0]  s_axil_wdata,
  output            s_axil_bvalid,
  input             s_axil_bready,
  input             s_axil_arvalid,
  output            s_axil_arready,
  input     [11:0]  s_axil_araddr,
  output            s_axil_rvalid,
  input             s_axil_rready,
  output    [31:0]  s_axil_rdata,

  input             s_axis_tvalid,
  output            s_axis_tready,
  input     [31:0]  s_axis_tdata,
  input     [71:0]  s_axis_tuser,
  input             s_axis_tlast,

  output            m_axis_tvalid,
  input             m_axis_tready,
  output    [31:0]  m_axis_tdata,
  output    [71:0]  m_axis_tuser,
  output            m_axis_tlast
);

  localparam [31:0] ID = 32'h4F465258;
  localparam [31:0] VERSION = 32'h00010000;

  // ---------------------------------------------------------------------------
  // registers

  wire        wr_en;
  wire [11:0] wr_addr, rd_addr;
  wire [31:0] wr_data;
  reg  [31:0] rd_data;
  reg         enable = 1'b1, soft_rst = 1'b0;
  reg  [31:0] frames_out = 32'd0, samples = 32'd0;
  wire [31:0] frames_in, dropped;

  glidelink_module_axil i_axil (
    .clk(clk), .rstn(rstn),
    .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready), .s_axil_awaddr(s_axil_awaddr),
    .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready), .s_axil_wdata(s_axil_wdata),
    .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
    .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready), .s_axil_araddr(s_axil_araddr),
    .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready), .s_axil_rdata(s_axil_rdata),
    .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .rd_addr(rd_addr), .rd_data(rd_data));

  always @(posedge clk) begin
    soft_rst <= 1'b0;
    if (!rstn) begin
      enable <= 1'b1;
    end else if (wr_en && wr_addr[11:2] == 10'h002) begin
      enable <= wr_data[0];
      soft_rst <= wr_data[1];
    end
  end

  always @(*) begin
    case (rd_addr[11:2])
      10'h000: rd_data = ID;
      10'h001: rd_data = VERSION;
      10'h002: rd_data = {31'd0, enable};
      10'h003: rd_data = {31'd0, enable};
      10'h004: rd_data = frames_in;
      10'h005: rd_data = dropped;
      10'h006: rd_data = frames_out;
      10'h007: rd_data = samples;
      default: rd_data = 32'd0;
    endcase
  end

  reg  [2:0]  rst_pipe = 3'b000;            // the competition RTL resets asynchronously, active low
  always @(posedge clk) rst_pipe <= {rst_pipe[1:0], rstn && !flush && !soft_rst};
  wire        rst_n = rst_pipe[2];

  // ---------------------------------------------------------------------------
  // baseband (competition RTL); disabled, the input is taken and dropped

  wire [23:0] phy_tdata;
  wire        phy_tvalid, phy_tready, phy_tlast, phy_tuser, in_tready;

  assign s_axis_tready = !enable || in_tready;

  rx_baseband_top #(.NSYM(NSYM), .FRAME_SYMS(FRAME_SYMS)) u_rx_baseband (
    .clk(clk), .rst_n(rst_n),
    .s_in_tdata({s_axis_tdata[31:20], s_axis_tdata[15:4]}),
    .s_in_tvalid(s_axis_tvalid && enable), .s_in_tready(in_tready),
    .m_out_tdata(phy_tdata), .m_out_tlast(phy_tlast), .m_out_tuser(phy_tuser),
    .m_out_tvalid(phy_tvalid), .m_out_tready(phy_tready),
    .dbg_pre_data(), .dbg_pre_fire(), .dbg_ce_data(), .dbg_ce_fire(),
    .dbg_cpe_data(), .dbg_cpe_fire(), .dbg_sfo_data(), .dbg_sfo_fire());

  // ---------------------------------------------------------------------------
  // frame buffer: complete frames only, 6 URAM = 2.25 frames, never holds the PHY off

  wire [23:0] fb_tdata;
  wire        fb_tlast;

  uram_frame_fifo #(.FRAME_LEN(FRAME_SYMS), .DEPTH_WORDS(24576), .PACKET_MODE(0)) u_frame_buf (
    .clk(clk), .rst_n(rst_n),
    .s_tdata(phy_tdata), .s_tvalid(phy_tvalid), .s_tready(phy_tready),
    .m_tdata(fb_tdata), .m_tlast(fb_tlast), .m_tuser(), .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready),
    .frames_in(frames_in), .dropped_frames(dropped));

  assign m_axis_tdata = {{4{fb_tdata[23]}}, fb_tdata[23:12], {4{fb_tdata[11]}}, fb_tdata[11:0]};
  assign m_axis_tlast = fb_tlast;
  assign m_axis_tuser = 72'd0;

  always @(posedge clk) begin
    if (!rst_n) begin
      frames_out <= 32'd0;
      samples <= 32'd0;
    end else begin
      if (m_axis_tvalid && m_axis_tready && m_axis_tlast)
        frames_out <= frames_out + 32'd1;
      if (s_axis_tvalid && s_axis_tready && enable)
        samples <= samples + 32'd1;
    end
  end

endmodule
