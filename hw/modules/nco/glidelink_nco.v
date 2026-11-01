// ***************************************************************************
// GlideLink user module: NCO mixer (frequency shift). Bit-exact reference:
// hw/modules/nco/model.py; description: module.yaml.
//
// Registers (module.yaml; the register file around this module is generated):
// CONTROL.enable (default 0 = samples pass unchanged, the phase holds),
// CONTROL.soft_reset (empties the pipeline, phase back to PHASE's value; flush
// from the shell does the same), STATUS.enabled, FREQ (phase increment per
// sample, f / fs * 2^32), PHASE (write: phase of the next sample; read:
// current phase).
// x[n] * exp(j 2 pi phase / 2^32) through a 4096-point table, products
// rounded (+2^14, >> 15) and saturated to sc16. tuser / tlast travel with
// their samples. Pipeline of 5 stages, stalled as a whole by back-pressure.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_nco (
  input             clk,
  input             rstn,
  input             flush,                  // stream state only (PORT_RESET): registers kept

  input             enable,
  input             soft_reset,
  output            enabled,
  input     [31:0]  freq,
  input     [31:0]  phase,                  // PHASE as written
  input             phase_wr,
  output    [31:0]  phase_rd,

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

  reg  [31:0] ph = 32'd0;                   // the phase of the next sample

  assign enabled = enable;
  assign phase_rd = ph;

  // ---------------------------------------------------------------------------
  // stream: 5 stages, all advance together when the output can move (ce)

  wire        rst = !rstn || soft_reset || flush;
  reg   [4:0] v = 5'd0;                     // stage valid
  wire        ce = !v[4] || m_axis_tready;
  wire        take = s_axis_tvalid && ce;

  assign s_axis_tready = ce;

  // the sideband (tuser, tlast, bypass, input sample) travels in a shift register
  reg  [104:0] side [0:4];                  // {last, user, data}
  reg   [4:0] byp = 5'd0;
  reg  [11:0] k0 = 12'd0;

  always @(posedge clk) begin
    if (rst || phase_wr)
      ph <= phase;
    else if (take && enable)
      ph <= ph + freq;
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
      k0 <= ph[31:20];
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
