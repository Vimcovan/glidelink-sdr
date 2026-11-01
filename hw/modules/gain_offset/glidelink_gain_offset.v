// ***************************************************************************
// GlideLink user module: Gain and offset. Description and registers:
// module.yaml; reference model: model.py (docs/module_guide.md).
//
// I and Q each: sat16(((x * GAIN + 2^13) >>> 14) + OFFSET). Two stages
// (products; rounding, offset, saturation), stalled together by back-pressure;
// tuser / tlast travel with the samples. Disabled: samples pass unchanged.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_gain_offset (
  input             clk,
  input             rstn,
  input             flush,                  // stream state only (PORT_RESET): registers kept

  // registers (module.yaml; the register file is generated)
  input             enable,                 // CONTROL[0]: 1 = process, 0 = pass unchanged
  input             soft_reset,             // CONTROL[1], one cycle per write of 1: pipeline emptied
  input     [15:0]  gain,                   // GAIN: gain, 1.0 = 16384
  input     [15:0]  offset_i,               // OFFSET_I: added to I after the gain
  input     [15:0]  offset_q,               // OFFSET_Q: added to Q after the gain

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

  reg   [1:0] v = 2'd0;
  wire        ce = !v[1] || m_axis_tready;

  assign s_axis_tready = ce;

  reg  [104:0] side [0:1];                  // {last, user, data}
  reg   [1:0] byp = 2'd0;

  always @(posedge clk) begin
    if (!rstn || flush || soft_reset)
      v <= 2'd0;
    else if (ce)
      v <= {v[0], s_axis_tvalid};
    if (ce) begin
      side[0] <= {s_axis_tlast, s_axis_tuser, s_axis_tdata};
      side[1] <= side[0];
      byp <= {byp[0], !enable};
    end
  end

  // stage 1: products
  reg  signed [31:0] p_i = 0, p_q = 0;
  // stage 2: rounding, offset, saturation
  reg  [31:0] out = 32'd0;

  // ((p + 2^13) >>> 14) + offset saturated to 16 bits (the sum fits in 19 bits)
  function [15:0] sat;
    input signed [31:0] p;
    input signed [15:0] off;
    reg signed [18:0] y;
    begin
      y = ((p + 32'sd8192) >>> 14) + off;
      if (y > 19'sd32767)
        sat = 16'h7FFF;
      else if (y < -19'sd32768)
        sat = 16'h8000;
      else
        sat = y[15:0];
    end
  endfunction

  always @(posedge clk) begin
    if (ce) begin
      p_i <= $signed(s_axis_tdata[15:0]) * $signed(gain);
      p_q <= $signed(s_axis_tdata[31:16]) * $signed(gain);
      out <= byp[0] ? side[0][31:0] : {sat(p_q, offset_q), sat(p_i, offset_i)};
    end
  end

  assign m_axis_tvalid = v[1];
  assign m_axis_tdata = out;
  assign m_axis_tuser = side[1][103:32];
  assign m_axis_tlast = side[1][104];

endmodule
