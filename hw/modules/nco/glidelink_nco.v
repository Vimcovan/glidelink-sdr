// ***************************************************************************
// GlideLink user module: NCO mixer (frequency shift). Bit-exact reference:
// hw/modules/nco/model.py; description: module.yaml.
//
// Registers (4 KB window):
//   0x000  ID       RO  0x4E434F31 ("NCO1")
//   0x004  VERSION  RO  {major[15:0], minor[7:0], patch[7:0]}
//   0x008  CONTROL  RW  bit 0: enable (default 0 = samples pass unchanged,
//                       the phase holds), bit 1: soft reset (self-clearing:
//                       empties the pipeline, phase back to PHASE's value;
//                       flush from the shell does the same)
//   0x00C  STATUS   RO  bit 0: enabled
//   0x010  FREQ     RW  phase increment per sample, f / fs * 2^32
//   0x014  PHASE    RW  write: phase of the next sample; read: current phase
// x[n] * exp(j 2 pi phase / 2^32) through a 4096-point table, products
// rounded (+2^14, >> 15) and saturated to sc16. tuser / tlast travel with
// their samples. Pipeline of 5 stages, stalled as a whole by back-pressure.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_nco (
  input             clk,
  input             rstn,
  input             flush,                  // stream state only (PORT_RESET): registers kept

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

  localparam [31:0] ID = 32'h4E434F31;
  localparam [31:0] VERSION = 32'h00010000;

  // ---------------------------------------------------------------------------
  // registers

  wire        wr_en;
  wire [11:0] wr_addr, rd_addr;
  wire [31:0] wr_data;
  reg  [31:0] rd_data;
  reg         enable = 1'b0, soft_rst = 1'b0;
  reg  [31:0] freq = 32'd0, phase_set = 32'd0, phase = 32'd0;
  reg         phase_load = 1'b0;

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
    phase_load <= 1'b0;
    if (!rstn) begin
      enable <= 1'b0;
      freq <= 32'd0;
      phase_set <= 32'd0;
    end else if (wr_en) begin
      case (wr_addr[11:2])
        10'h002: begin enable <= wr_data[0]; soft_rst <= wr_data[1]; end
        10'h004: freq <= wr_data;
        10'h005: begin phase_set <= wr_data; phase_load <= 1'b1; end
        default: ;
      endcase
    end
  end

  always @(*) begin
    case (rd_addr[11:2])
      10'h000: rd_data = ID;
      10'h001: rd_data = VERSION;
      10'h002: rd_data = {31'd0, enable};
      10'h003: rd_data = {31'd0, enable};
      10'h004: rd_data = freq;
      10'h005: rd_data = phase;
      default: rd_data = 32'd0;
    endcase
  end

  // ---------------------------------------------------------------------------
  // stream: 5 stages, all advance together when the output can move (ce)

  wire        rst = !rstn || soft_rst || flush;
  reg   [4:0] v = 5'd0;                     // stage valid
  wire        ce = !v[4] || m_axis_tready;
  wire        take = s_axis_tvalid && ce;

  assign s_axis_tready = ce;

  // the sideband (tuser, tlast, bypass, input sample) travels in a shift register
  reg  [104:0] side [0:4];                  // {last, user, data}
  reg   [4:0] byp = 5'd0;
  reg  [11:0] k0 = 12'd0;

  always @(posedge clk) begin
    if (rst || phase_load)
      phase <= phase_set;
    else if (take && enable)
      phase <= phase + freq;
  end

  integer j;
  always @(posedge clk) begin
    if (rst) begin
      v <= 5'd0;
    end else if (ce) begin
      v <= {v[3:0], s_axis_tvalid};
    end
    if (ce) begin
      side[0] <= {s_axis_tlast, s_axis_tuser, s_axis_tdata};
      byp[0] <= !enable;
      k0 <= phase[31:20];
      for (j = 1; j < 5; j = j + 1) begin
        side[j] <= side[j - 1];
        byp[j] <= byp[j - 1];
      end
    end
  end

  // stage 1: table read (sample from stage 0)
  wire [31:0] cs;
  glidelink_nco_rom i_rom (.clk(clk), .ce(ce), .addr(k0), .data(cs));

  // stage 2: products of the stage-1 sample with the table output
  wire signed [15:0] i1 = side[1][15:0], q1 = side[1][31:16];
  wire signed [15:0] c1 = cs[15:0], s1 = cs[31:16];
  reg  signed [31:0] p_ic = 0, p_qs = 0, p_is = 0, p_qc = 0;
  // stage 3: sums with the rounding constant
  reg  signed [33:0] re3 = 0, im3 = 0;
  // stage 4: saturation
  reg  [31:0] out4 = 32'd0;

  // x >>> 15 saturated to 16 bits: in range when bits 33..30 are all equal
  function [15:0] sat;
    input [33:0] x;
    begin
      if (x[33:30] == 4'b0000 || x[33:30] == 4'b1111)
        sat = x[30:15];
      else
        sat = x[33] ? 16'h8000 : 16'h7FFF;
    end
  endfunction

  always @(posedge clk) begin
    if (ce) begin
      p_ic <= i1 * c1;
      p_qs <= q1 * s1;
      p_is <= i1 * s1;
      p_qc <= q1 * c1;
      re3 <= p_ic - p_qs + 34'sd16384;
      im3 <= p_is + p_qc + 34'sd16384;
      out4 <= byp[3] ? side[3][31:0] : {sat(im3), sat(re3)};
    end
  end

  assign m_axis_tvalid = v[4];
  assign m_axis_tdata = out4;
  assign m_axis_tuser = side[4][103:32];
  assign m_axis_tlast = side[4][104];

endmodule
