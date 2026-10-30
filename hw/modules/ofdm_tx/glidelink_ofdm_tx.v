// ***************************************************************************
// GlideLink user module: OFDM transmitter of the DeepJSCC-Q link (from the
// competition design, docs/phase4_plan.md; description: module.yaml).
//
// Input: DeepJSCC-Q 64-QAM symbols, one per beat, {Q[31:16], I[15:0]} with
// each half the 12-bit Q10 value sign-extended; tlast on the 32768th symbol
// of a frame. Output: 20 MSPS baseband samples for the RF TX streamer,
// {Q[31:16], I[15:0]} at 16-bit full scale (the 12-bit DAC value shifted left
// by 4): one packet per frame, the frame's 54,960 samples followed by GAP
// zero samples, tuser flags = end of burst (the idle time until the next
// frame is no underflow). The RF TX streamer takes the samples at the DAC
// rate; the module's frame buffer only releases complete frames.
//
// Chain (competition RTL, unchanged): framer + PN sign scrambling -> pilots
// -> IFFT shift -> IFFT (Xilinx FFT IP) + CP -> truncation -> preamble ->
// URAM frame buffer (1.34 frames).
//
// Registers (4 KB window):
//   0x000  ID          RO  0x4F465458 ("OFTX")
//   0x004  VERSION     RO  {major[15:0], minor[7:0], patch[7:0]}
//   0x008  CONTROL     RW  bit 0: enable (default 1; 0 holds the input off),
//                          bit 1: soft reset (self-clearing), bit 2: PRBS
//                          source (default 0: internal random 64-QAM frames
//                          instead of the input; change it between frames or
//                          with a soft reset)
//   0x00C  STATUS      RO  bit 0: enabled, bit 1: PRBS source
//   0x010  GAP         RW  zero samples after each frame (default 1000 = 50 us at 20 MSPS)
//   0x014  FRAMES_OUT  RO  frames sent
//   0x018  TLAST_ERR   RO  input symbols whose tlast did not match their place (symbol 32767)
//   0x01C  FRAMES_IN   RO  frames taken into the frame buffer
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_ofdm_tx #(
  parameter NSYM = 683,                     // OFDM data symbols per frame
  parameter FRAME_SYMS = 32768              // DeepJSCC symbols per frame
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

  localparam [31:0] ID = 32'h4F465458;
  localparam [31:0] VERSION = 32'h00010000;
  localparam [7:0]  FLAG_EOB = 8'h02;

  // ---------------------------------------------------------------------------
  // registers

  wire        wr_en;
  wire [11:0] wr_addr, rd_addr;
  wire [31:0] wr_data;
  reg  [31:0] rd_data;
  reg         enable = 1'b1, soft_rst = 1'b0, prbs = 1'b0;
  reg  [15:0] gap = 16'd1000;
  reg  [31:0] frames_out = 32'd0, tlast_errs = 32'd0;
  wire [31:0] frames_in;

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
      prbs <= 1'b0;
      gap <= 16'd1000;
    end else if (wr_en) begin
      case (wr_addr[11:2])
        10'h002: begin enable <= wr_data[0]; soft_rst <= wr_data[1]; prbs <= wr_data[2]; end
        10'h004: gap <= wr_data[15:0];
        default: ;
      endcase
    end
  end

  always @(*) begin
    case (rd_addr[11:2])
      10'h000: rd_data = ID;
      10'h001: rd_data = VERSION;
      10'h002: rd_data = {29'd0, prbs, 1'b0, enable};
      10'h003: rd_data = {30'd0, prbs, enable};
      10'h004: rd_data = {16'd0, gap};
      10'h005: rd_data = frames_out;
      10'h006: rd_data = tlast_errs;
      10'h007: rd_data = frames_in;
      default: rd_data = 32'd0;
    endcase
  end

  // ---------------------------------------------------------------------------
  // source: the input or the PRBS test frames

  reg  [2:0]  rst_pipe = 3'b000;            // the competition RTL resets asynchronously, active low
  always @(posedge clk) rst_pipe <= {rst_pipe[1:0], rstn && !flush && !soft_rst};
  wire        rst_n = rst_pipe[2];

  wire [23:0] p_tdata;
  wire        p_tvalid, p_tready, p_tlast, p_tuser;
  iq_prbs_source #(.FRAME_SYMS(FRAME_SYMS)) u_prbs (
    .clk(clk), .rst_n(rst_n),
    .m_tdata(p_tdata), .m_tlast(p_tlast), .m_tuser(p_tuser), .m_tvalid(p_tvalid), .m_tready(p_tready));

  wire [23:0] in_tdata = prbs ? p_tdata : {s_axis_tdata[27:16], s_axis_tdata[11:0]};
  wire        in_tlast = prbs ? p_tlast : s_axis_tlast;
  wire        in_tvalid = enable && (prbs ? p_tvalid : s_axis_tvalid);
  wire        in_tready;
  assign s_axis_tready = enable && !prbs && in_tready;
  assign p_tready = enable && prbs && in_tready;

  // ---------------------------------------------------------------------------
  // baseband (competition RTL)

  wire [23:0] bb_tdata;
  wire        bb_tvalid, bb_tlast, bb_tready, tlast_err;

  tx_baseband_jscc #(.NSYM(NSYM), .FRAME_SYMS(FRAME_SYMS)) u_baseband (
    .clk(clk), .rst_n(rst_n),
    .s_in_tdata(in_tdata), .s_in_tlast(in_tlast), .s_in_tvalid(in_tvalid), .s_in_tready(in_tready),
    .m_out_tdata(bb_tdata), .m_out_tvalid(bb_tvalid), .m_out_tlast(bb_tlast), .m_out_tready(bb_tready),
    .tlast_err(tlast_err), .frames_buffered(frames_in));

  // ---------------------------------------------------------------------------
  // output: a frame, then GAP zeros, as one end-of-burst packet

  reg         in_gap = 1'b0;
  reg  [15:0] gap_left = 16'd0;

  wire        frame_end = bb_tvalid && bb_tready && bb_tlast;
  assign bb_tready = !in_gap && m_axis_tready;
  assign m_axis_tvalid = in_gap || bb_tvalid;
  assign m_axis_tdata = in_gap ? 32'd0 : {bb_tdata[23:12], 4'd0, bb_tdata[11:0], 4'd0};
  assign m_axis_tlast = in_gap ? gap_left == 16'd1 : (bb_tlast && gap == 16'd0);
  assign m_axis_tuser = {FLAG_EOB, 64'd0};

  always @(posedge clk) begin
    if (!rst_n) begin
      in_gap <= 1'b0;
    end else if (frame_end && gap != 16'd0) begin
      in_gap <= 1'b1;
      gap_left <= gap;
    end else if (in_gap && m_axis_tready) begin
      gap_left <= gap_left - 16'd1;
      if (gap_left == 16'd1)
        in_gap <= 1'b0;
    end
  end

  always @(posedge clk) begin
    if (!rstn || soft_rst) begin
      frames_out <= 32'd0;
      tlast_errs <= 32'd0;
    end else begin
      if (m_axis_tvalid && m_axis_tready && m_axis_tlast)
        frames_out <= frames_out + 32'd1;
      if (tlast_err)
        tlast_errs <= tlast_errs + 32'd1;
    end
  end

endmodule
