// ***************************************************************************
// GlideLink user module: FIR filter, real coefficients on I and Q. Bit-exact
// reference: hw/modules/fir/model.py; description: module.yaml.
//
// Registers (module.yaml; the register file around this module is generated):
// CONTROL.enable (default 0 = samples pass unchanged and do not enter the
// delay line), CONTROL.soft_reset (pipeline and delay line cleared, as flush
// from the shell does), CONTROL.load (shadow coefficients become the active
// ones), STATUS.enabled, TAPS, SHIFT (output right shift, 0..31, default 15),
// COEF_ADDR (shadow index of the next COEF_DATA access), COEF_DATA (shadow
// coefficient at COEF_ADDR; a write also moves COEF_ADDR on by one), INTERP
// and DECIM (rate change L and M, 0 or 1 = none; enabled only).
// Interpolation: each input sample enters the filter followed by L - 1 zeros
// (tuser stays on the first, tlast moves to the last). Decimation: one filter
// output in every M goes out, the phase running on across packets; it carries
// the tuser of the first packet start and any tlast among the M samples it
// stands for (packets shorter than M lose their start).
// y[n] = sum h[k] x[n-k] (transposed form, 40-bit accumulation), then
// (y + 2^(SHIFT-1)) >> SHIFT saturated to 16 bits. The delay line advances
// on valid samples only and runs on across packets. Pipeline of 5 stages,
// stalled as a whole by back-pressure; tuser / tlast travel with the samples.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_fir #(
  parameter TAPS = 32
) (
  input             clk,
  input             rstn,
  input             flush,                  // stream state only (PORT_RESET): registers kept

  input             enable,
  input             soft_reset,
  input             load,
  output            enabled,
  input      [4:0]  shift,
  input      [4:0]  interp,
  input      [4:0]  decim,
  input      [7:0]  coef_addr,              // COEF_ADDR as written
  input             coef_addr_wr,
  output     [7:0]  coef_addr_rd,
  input     [15:0]  coef_data,              // COEF_DATA as written
  input             coef_data_wr,
  output    [15:0]  coef_data_rd,

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

  localparam AW = 40;                       // accumulator width

  // ---------------------------------------------------------------------------
  // coefficients: shadow set written through COEF_ADDR / COEF_DATA, loaded at once

  reg   [7:0] caddr = 8'd0;
  reg  signed [15:0] shadow [0:TAPS-1];
  reg  signed [15:0] h [0:TAPS-1];

  integer k;
  initial
    for (k = 0; k < TAPS; k = k + 1) begin
      shadow[k] = 16'sd0;
      h[k] = 16'sd0;
    end

  always @(posedge clk) begin
    if (!rstn)
      caddr <= 8'd0;
    else if (coef_addr_wr)
      caddr <= coef_addr;
    else if (coef_data_wr) begin
      if (caddr < TAPS)
        shadow[caddr] <= coef_data;
      caddr <= caddr + 8'd1;
    end
    if (load)
      for (k = 0; k < TAPS; k = k + 1)
        h[k] <= shadow[k];
  end

  assign enabled = enable;
  assign coef_addr_rd = caddr;
  assign coef_data_rd = caddr < TAPS ? shadow[caddr] : 16'd0;

  // ---------------------------------------------------------------------------
  // stream: stages A (input), B (products), C (delay line), D (rounding),
  // E (shift, saturation); all advance together when the output can move

  wire        rst = !rstn || soft_reset || flush;
  reg   [4:0] v = 5'd0;
  wire  [4:0] L = (!enable || interp < 5'd2) ? 5'd1 : interp;
  wire  [4:0] M = (!enable || decim < 5'd2) ? 5'd1 : decim;

  // interpolation: a new input sample at up_cnt = 0, then L - 1 zeros
  reg   [4:0] up_cnt = 5'd0;
  reg         up_last = 1'b0;               // tlast of the sample being interpolated
  wire        up_new = up_cnt == 5'd0;
  wire        a_valid = up_new ? s_axis_tvalid : 1'b1;
  wire        a_last = L == 5'd1 ? s_axis_tlast : (up_cnt == L - 5'd1 && up_last);
  wire [71:0] a_user = up_new ? s_axis_tuser : 72'd0;
  wire [31:0] a_data = up_new ? s_axis_tdata : 32'd0;

  // decimation: the stage-E sample goes out when keep, else it is dropped
  reg   [4:0] dec_cnt = 5'd0;
  reg         w_first = 1'b0;               // a packet start among the dropped samples
  reg  [71:0] w_user = 72'd0;
  reg         w_last = 1'b0;                // a packet end among them
  reg         e_first = 1'b1;               // the stage-E sample starts a packet
  wire        keep = dec_cnt >= M - 5'd1;
  wire        ce = !v[4] || !keep || m_axis_tready;

  assign s_axis_tready = ce && up_new;

  reg  [104:0] side [0:4];                  // {last, user, data}
  reg   [4:0] byp = 5'd0;

  integer j;
  always @(posedge clk) begin
    if (rst)
      v <= 5'd0;
    else if (ce)
      v <= {v[3:0], a_valid};
    if (ce) begin
      side[0] <= {a_last, a_user, a_data};
      byp[0] <= !enable;
      for (j = 1; j < 5; j = j + 1) begin
        side[j] <= side[j - 1];
        byp[j] <= byp[j - 1];
      end
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      up_cnt <= 5'd0;
    end else if (ce && a_valid) begin
      if (up_new)
        up_last <= s_axis_tlast;
      up_cnt <= up_cnt >= L - 5'd1 ? 5'd0 : up_cnt + 5'd1;
    end
  end

  wire [71:0] e_user = side[4][103:32];
  wire        e_last = side[4][104];

  always @(posedge clk) begin
    if (rst) begin
      dec_cnt <= 5'd0;
      w_first <= 1'b0;
      w_last <= 1'b0;
      e_first <= 1'b1;
    end else if (v[4] && ce) begin          // the stage-E sample leaves: out or dropped
      e_first <= e_last;
      if (keep) begin
        dec_cnt <= 5'd0;
        w_first <= 1'b0;
        w_last <= 1'b0;
      end else begin
        dec_cnt <= dec_cnt + 5'd1;
        if (e_first && !w_first) begin
          w_first <= 1'b1;
          w_user <= e_user;
        end
        w_last <= w_last || e_last;
      end
    end
  end

  // B: products of the stage-A sample with every coefficient
  wire signed [15:0] xa_i = side[0][15:0], xa_q = side[0][31:16];
  reg  signed [31:0] m_i [0:TAPS-1];
  reg  signed [31:0] m_q [0:TAPS-1];
  // C: delay line z[k] = m[k] + z[k+1], taken only for a valid, filtered sample
  reg  signed [AW-1:0] z_i [0:TAPS-1];
  reg  signed [AW-1:0] z_q [0:TAPS-1];
  wire        take_c = ce && v[1] && !byp[1];
  // D, E
  reg  signed [AW-1:0] d_i = 0, d_q = 0;
  reg  [31:0] out_e = 32'd0;

  always @(posedge clk) begin
    if (ce)
      for (k = 0; k < TAPS; k = k + 1) begin
        m_i[k] <= xa_i * h[k];
        m_q[k] <= xa_q * h[k];
      end
  end

  always @(posedge clk) begin
    if (rst) begin
      for (k = 0; k < TAPS; k = k + 1) begin
        z_i[k] <= 0;
        z_q[k] <= 0;
      end
    end else if (take_c) begin
      for (k = 0; k < TAPS - 1; k = k + 1) begin
        z_i[k] <= m_i[k] + z_i[k + 1];
        z_q[k] <= m_q[k] + z_q[k + 1];
      end
      z_i[TAPS - 1] <= m_i[TAPS - 1];
      z_q[TAPS - 1] <= m_q[TAPS - 1];
    end
  end

  wire signed [AW-1:0] rnd = shift == 5'd0 ? 0 : ({{(AW-1){1'b0}}, 1'b1} << (shift - 5'd1));

  // (x >>> shift) saturated to 16 bits
  function [15:0] sat;
    input signed [AW-1:0] x;
    input [4:0] sh;
    reg signed [AW-1:0] y;
    begin
      y = x >>> sh;
      if (y > 32767)
        sat = 16'h7FFF;
      else if (y < -32768)
        sat = 16'h8000;
      else
        sat = y[15:0];
    end
  endfunction

  always @(posedge clk) begin
    if (ce) begin
      d_i <= z_i[0] + rnd;                  // z[0] holds y of the stage-C sample
      d_q <= z_q[0] + rnd;
      out_e <= byp[3] ? side[3][31:0] : {sat(d_q, shift), sat(d_i, shift)};
    end
  end

  assign m_axis_tvalid = v[4] && keep;
  assign m_axis_tdata = out_e;
  assign m_axis_tuser = M == 5'd1 ? e_user : w_first ? w_user : e_first ? e_user : 72'd0;
  assign m_axis_tlast = w_last || e_last;

endmodule
