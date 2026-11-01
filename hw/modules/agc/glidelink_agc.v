// ***************************************************************************
// GlideLink user module: AGC, as GNU Radio's agc_cc in fixed point.
// Description and registers: module.yaml; reference model: model.py.
//
// One sample at a time, 4 cycles each (take, multiply, saturate / magnitude,
// gain update and output), so the gain used for a sample is the one updated by
// the sample before it, as in the software recursion (50 MSPS at 200 MHz):
//   y = sat16((x * g + 2^15) >> 16), m = max(|yI|, |yQ|) + (3 min >> 3),
//   g += (2 (REFERENCE - m)) >>> RATE_SHIFT, g within 0 .. MAX_GAIN.
// Disabled: samples pass unchanged, the gain holds. Soft reset and flush set
// the gain to GAIN as written.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_agc (
  input             clk,
  input             rstn,
  input             flush,                  // stream state only (PORT_RESET): registers kept

  // registers (module.yaml; the register file is generated)
  input             enable,                 // CONTROL[0]: 1 = AGC, 0 = pass unchanged
  input             soft_reset,             // CONTROL[1], one cycle per write of 1
  input     [15:0]  reference,              // REFERENCE: output magnitude, 1.0 = 32768
  input      [4:0]  rate_shift,             // RATE_SHIFT: gain update rate 2^-RATE_SHIFT
  input     [25:0]  max_gain,               // MAX_GAIN: 1.0 = 65536
  input     [25:0]  gain,                   // GAIN as written
  input             gain_wr,                // one cycle per write of GAIN
  output    [25:0]  gain_rd,                // GAIN as read: the gain now

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

  localparam [1:0] S_TAKE = 2'd0, S_MUL = 2'd1, S_MAG = 2'd2, S_UPD = 2'd3;

  wire        rst = !rstn || soft_reset || flush;
  reg   [1:0] st = S_TAKE;
  reg  [25:0] g = 26'd65536;
  reg  signed [15:0] xi = 0, xq = 0;
  reg  [71:0] user = 72'd0;
  reg         last = 1'b0, byp = 1'b0;
  reg  signed [42:0] pi = 0, pq = 0;        // x * g
  reg  signed [15:0] yi = 0, yq = 0;
  reg  [16:0] mag = 17'd0;

  reg         o_valid = 1'b0;
  reg  [31:0] o_data = 32'd0;
  reg  [71:0] o_user = 72'd0;
  reg         o_last = 1'b0;

  assign s_axis_tready = st == S_TAKE && !rst;
  assign m_axis_tvalid = o_valid;
  assign m_axis_tdata = o_data;
  assign m_axis_tuser = o_user;
  assign m_axis_tlast = o_last;
  assign gain_rd = g;

  // (p + 2^15) >>> 16 saturated to 16 bits
  function signed [15:0] sat;
    input signed [42:0] p;
    reg signed [42:0] r;
    begin
      r = (p + 43'sd32768) >>> 16;
      if (r > 43'sd32767)
        sat = 16'sh7FFF;
      else if (r < -43'sd32768)
        sat = -16'sd32768;
      else
        sat = r[15:0];
    end
  endfunction

  wire [16:0] ai = yi[15] ? -{yi[15], yi} : {1'b0, yi};
  wire [16:0] aq = yq[15] ? -{yq[15], yq} : {1'b0, yq};
  wire [16:0] amax = ai > aq ? ai : aq;
  wire [16:0] amin = ai > aq ? aq : ai;
  wire [18:0] amin3 = {2'd0, amin} + {1'b0, amin, 1'b0};
  wire signed [19:0] err = $signed({4'd0, reference}) - $signed({3'd0, mag});
  wire signed [27:0] delta = $signed({{7{err[19]}}, err, 1'b0}) >>> rate_shift;
  wire signed [28:0] gsum = $signed({3'd0, g}) + delta;
  wire        out_free = !o_valid || m_axis_tready;

  always @(posedge clk) begin
    if (o_valid && m_axis_tready)
      o_valid <= 1'b0;
    if (rst) begin
      st <= S_TAKE;
      o_valid <= 1'b0;
      g <= gain;
    end else begin
      if (gain_wr)
        g <= gain;
      case (st)
        S_TAKE:
          if (s_axis_tvalid) begin
            xi <= s_axis_tdata[15:0];
            xq <= s_axis_tdata[31:16];
            user <= s_axis_tuser;
            last <= s_axis_tlast;
            byp <= !enable;
            st <= S_MUL;
          end
        S_MUL: begin
          pi <= xi * $signed({1'b0, g});
          pq <= xq * $signed({1'b0, g});
          st <= S_MAG;
        end
        S_MAG: begin
          yi <= byp ? xi : sat(pi);
          yq <= byp ? xq : sat(pq);
          st <= S_UPD;
        end
        default: begin                      // S_UPD: magnitude, gain update, output
          if (out_free) begin
            o_valid <= 1'b1;
            o_data <= {yq, yi};
            o_user <= user;
            o_last <= last;
            if (!byp && !gain_wr)
              g <= gsum < 0 ? 26'd0 : gsum > $signed({3'd0, max_gain}) ? max_gain : gsum[25:0];
            st <= S_TAKE;
          end
        end
      endcase
    end
  end

  always @(*) mag = amax + {2'd0, amin3[18:3]};

endmodule
