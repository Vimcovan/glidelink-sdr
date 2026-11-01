// ***************************************************************************
// GlideLink user module: Costas loop for QPSK, as GNU Radio's costas_loop_cc
// of order 4 in fixed point. Description and registers: module.yaml;
// bit-exact reference: model.py.
//
// One sample at a time, 7 cycles each (28 MSPS at 200 MHz), two multipliers
// (2 DSP slices) taking the products in turn:
//   T0  take x; table address = phase[31:20]
//   T1, T2  x * (cos, sin)            T2, T3  sums with the rounding constant
//   T3, T4  y saturated               T4  e = sign(yI) yQ - sign(yQ) yI within +-32768
//   T5  e ALPHA, e BETA (gains 17 bits)  T6  loop update, y out
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
  input     [16:0]  alpha,                  // ALPHA, ALPHA_SHIFT: alpha 2^17 / (2 pi) = ALPHA / 2^ALPHA_SHIFT
  input      [4:0]  alpha_shift,
  input     [16:0]  beta,                   // BETA, BETA_SHIFT: the same for beta
  input      [4:0]  beta_shift,
  input     [31:0]  freq_max,               // FREQ_MAX
  input     [31:0]  freq,                   // FREQ as written
  input             freq_wr,
  output    [31:0]  freq_rd,
  output    [31:0]  phase,                  // PHASE

  input             s_axis_tvalid,
  output            s_axis_tready,
  input     [31:0]  s_axis_tdata,

  output            m_axis_tvalid,
  input             m_axis_tready,
  output    [31:0]  m_axis_tdata
);

  wire        rst = !rstn || soft_reset || flush;
  reg   [2:0] t = 3'd0;
  reg         busy = 1'b0, byp = 1'b0;
  reg  signed [15:0] xi = 0, xq = 0;
  reg  [31:0] ph = 32'd0;
  reg  signed [31:0] f = 32'sd0;

  reg         o_valid = 1'b0;
  reg  [31:0] o_data = 32'd0;
  wire        out_free = !o_valid || m_axis_tready;

  assign s_axis_tready = !busy && !rst;
  assign m_axis_tvalid = o_valid;
  assign m_axis_tdata = o_data;
  assign enabled = enable;
  assign freq_rd = f;
  assign phase = ph;

  wire [31:0] cs;
  glidelink_costas_rom i_rom (.clk(clk), .addr(ph[31:20]), .data(cs));
  wire signed [15:0] tc = cs[15:0], ts = cs[31:16];

  reg  signed [33:0] re = 0, im = 0;
  reg  signed [15:0] yi = 0, yq = 0;
  reg  signed [17:0] e = 0;

  function signed [15:0] sat16(input signed [33:0] x);
    reg signed [33:0] y;
    begin
      y = x >>> 15;
      sat16 = y > 34'sd32767 ? 16'sh7FFF : y < -34'sd32768 ? -16'sd32768 : y[15:0];
    end
  endfunction

  // the two multipliers: xI C, xQ S at T1; xQ C, xI S at T2; e ALPHA, e BETA at T5
  reg  signed [17:0] a0, b0, a1, b1;
  always @(*)
    case (t)
      3'd1:    begin a0 = xi; b0 = tc; a1 = xq; b1 = ts; end
      3'd2:    begin a0 = xq; b0 = tc; a1 = xi; b1 = ts; end
      default: begin a0 = e; b0 = $signed({1'b0, alpha}); a1 = e; b1 = $signed({1'b0, beta}); end
    endcase
  (* keep = "true" *) reg signed [35:0] m0 = 0, m1 = 0;   // kept: synthesis would copy the multiplier into each adder after it
  always @(posedge clk) begin
    m0 <= a0 * b0;
    m1 <= a1 * b1;
  end

  wire signed [15:0] ryq = sat16(im);
  wire signed [17:0] ed = (yi > 0 ? $signed({{2{ryq[15]}}, ryq}) : -$signed({{2{ryq[15]}}, ryq}))
                        - (ryq > 0 ? $signed({{2{yi[15]}}, yi}) : -$signed({{2{yi[15]}}, yi}));
  wire signed [35:0] dfb = m1 >>> beta_shift, dfa = m0 >>> alpha_shift;
  wire signed [36:0] f2 = $signed({{5{f[31]}}, f}) + dfb;
  wire signed [36:0] fmax = $signed({5'b00, freq_max});

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
          byp <= !enable;
          busy <= 1'b1;
          t <= 3'd1;
        end
      end else begin
        t <= t + 3'd1;
        case (t)
          3'd1: ;
          3'd2:
            re <= m0 + m1 + 34'sd16384;
          3'd3: begin
            im <= m0 - m1 + 34'sd16384;
            yi <= byp ? xi : sat16(re);
          end
          3'd4: begin
            yq <= byp ? xq : ryq;
            e <= ed < -18'sd32768 ? -18'sd32768 : ed > 18'sd32768 ? 18'sd32768 : ed;
          end
          3'd5: ;
          default: begin                      // T6
            t <= 3'd6;
            if (out_free) begin
              o_valid <= 1'b1;
              o_data <= {yq, yi};
              if (!byp) begin
                ph <= ph + f2[31:0] + dfa[31:0];
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
