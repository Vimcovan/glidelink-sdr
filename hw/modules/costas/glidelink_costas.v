// ***************************************************************************
// GlideLink user module: Costas loop for QPSK, as GNU Radio's costas_loop_cc
// of order 4 in fixed point. Description and registers: module.yaml;
// bit-exact reference: model.py.
//
// One sample at a time, 6 cycles each (33 MSPS at 200 MHz):
//   T0  take x; table address = phase[31:20]
//   T1  x * (cos, sin)                T2  sums with the rounding constant
//   T3  y saturated; e = sign(yI) yQ - sign(yQ) yI within +-32768
//   T4  e ALPHA, e BETA               T5  loop update, y out
// Soft reset and flush set the phase to 0 and the frequency to FREQ as written.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_costas (
  input             clk,
  input             rstn,
  input             flush,                  // stream state only (PORT_RESET): registers kept

  // registers (module.yaml; the register file is generated)
  input             enable,                 // CONTROL[0]
  input             soft_reset,             // CONTROL[1], one cycle per write of 1
  output            enabled,                // STATUS[0]
  input     [26:0]  alpha,                  // ALPHA: alpha 2^33 / (2 pi)
  input     [26:0]  beta,                   // BETA
  input     [31:0]  freq_max,               // FREQ_MAX
  input     [31:0]  freq,                   // FREQ as written
  input             freq_wr,
  output    [31:0]  freq_rd,
  output    [31:0]  phase,                  // PHASE

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

  wire        rst = !rstn || soft_reset || flush;
  reg   [2:0] t = 3'd0;
  reg         busy = 1'b0, byp = 1'b0;
  reg  signed [15:0] xi = 0, xq = 0;
  reg  [71:0] user = 72'd0;
  reg         last = 1'b0;
  reg  [31:0] ph = 32'd0;
  reg  signed [31:0] f = 32'sd0;

  reg         o_valid = 1'b0;
  reg  [31:0] o_data = 32'd0;
  reg  [71:0] o_user = 72'd0;
  reg         o_last = 1'b0;
  wire        out_free = !o_valid || m_axis_tready;

  assign s_axis_tready = !busy && !rst;
  assign m_axis_tvalid = o_valid;
  assign m_axis_tdata = o_data;
  assign m_axis_tuser = o_user;
  assign m_axis_tlast = o_last;
  assign enabled = enable;
  assign freq_rd = f;
  assign phase = ph;

  wire [31:0] cs;
  glidelink_costas_rom i_rom (.clk(clk), .addr(ph[31:20]), .data(cs));
  wire signed [15:0] tc = cs[15:0], ts = cs[31:16];

  reg  signed [31:0] p_ic = 0, p_qs = 0, p_qc = 0, p_is = 0;
  reg  signed [33:0] re = 0, im = 0;
  reg  signed [15:0] yi = 0, yq = 0;
  reg  signed [17:0] e = 0;
  reg  signed [45:0] ea = 0, eb = 0;

  function signed [15:0] sat16(input signed [33:0] x);
    reg signed [33:0] y;
    begin
      y = x >>> 15;
      sat16 = y > 34'sd32767 ? 16'sh7FFF : y < -34'sd32768 ? -16'sd32768 : y[15:0];
    end
  endfunction

  wire signed [15:0] ryi = sat16(re), ryq = sat16(im);
  wire signed [17:0] ed = (ryi > 0 ? $signed({{2{ryq[15]}}, ryq}) : -$signed({{2{ryq[15]}}, ryq}))
                        - (ryq > 0 ? $signed({{2{ryi[15]}}, ryi}) : -$signed({{2{ryi[15]}}, ryi}));
  wire signed [29:0] dfb = eb >>> 16, dfa = ea >>> 16;
  wire signed [33:0] f2 = $signed({{2{f[31]}}, f}) + dfb;
  wire signed [33:0] fmax = $signed({2'b00, freq_max});

  always @(posedge clk) begin
    if (o_valid && m_axis_tready)
      o_valid <= 1'b0;
    if (rst) begin
      busy <= 1'b0;
      t <= 3'd0;
      o_valid <= 1'b0;
      ph <= 32'd0;
      f <= freq;
    end else begin
      if (freq_wr)
        f <= freq;
      if (!busy) begin
        if (s_axis_tvalid) begin              // T0
          xi <= s_axis_tdata[15:0];
          xq <= s_axis_tdata[31:16];
          user <= s_axis_tuser;
          last <= s_axis_tlast;
          byp <= !enable;
          busy <= 1'b1;
          t <= 3'd1;
        end
      end else begin
        t <= t + 3'd1;
        case (t)
          3'd1: begin
            p_ic <= xi * tc;
            p_qs <= xq * ts;
            p_qc <= xq * tc;
            p_is <= xi * ts;
          end
          3'd2: begin
            re <= p_ic + p_qs + 34'sd16384;
            im <= p_qc - p_is + 34'sd16384;
          end
          3'd3: begin
            yi <= byp ? xi : ryi;
            yq <= byp ? xq : ryq;
            e <= ed < -18'sd32768 ? -18'sd32768 : ed > 18'sd32768 ? 18'sd32768 : ed;
          end
          3'd4: begin
            ea <= e * $signed({1'b0, alpha});
            eb <= e * $signed({1'b0, beta});
          end
          default: begin                      // T5
            t <= 3'd5;
            if (out_free) begin
              o_valid <= 1'b1;
              o_data <= {yq, yi};
              o_user <= user;
              o_last <= last;
              if (!byp) begin
                ph <= ph + f2[31:0] + {{2{dfa[29]}}, dfa};
                if (!freq_wr)
                  f <= f2 < -fmax ? -freq_max : f2 > fmax ? freq_max : f2[31:0];
              end
              busy <= 1'b0;
              t <= 3'd0;
            end
          end
        endcase
      end
    end
  end

endmodule
