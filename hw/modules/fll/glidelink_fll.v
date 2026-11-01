// ***************************************************************************
// GlideLink user module: FLL band-edge, as GNU Radio's fll_band_edge_cc in
// fixed point. Description and registers: module.yaml; bit-exact reference:
// model.py.
//
// One sample at a time, 13 cycles each, so each sample is turned by the phase
// the previous one left (as the software recursion; 15 MSPS at 200 MHz):
//   T0  take x; table address = phase[31:20]
//   T1  x * (cos, sin)                 T2  sums with the rounding constant
//   T3  y saturated, into the history (bypass: y = x, straight to the output)
//   T4  c_k y_k, s_k y_k for all taps  T5..T7  adder trees (groups of 4)
//   T8  P, Q >>> (TAP_SHIFT - 1), saturated to 18 bits
//   T9  e = Pq Qi - Pi Qq              T10, T11  e ALPHA, e BETA
//   T12 f' = f - (e BETA >>> 24), phase += f' - (e ALPHA >>> 24),
//       f = f' within +-FREQ_MAX; y out
// Coefficients: shadow set written through COEF_ADDR / COEF_DATA (2k = c_k,
// 2k + 1 = s_k), active on CONTROL.load. Soft reset and flush clear the
// history, set the phase to 0 and the frequency to FREQ as written.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_fll #(
  parameter TAPS = 48
) (
  input             clk,
  input             rstn,
  input             flush,                  // stream state only (PORT_RESET): registers kept

  // registers (module.yaml; the register file is generated)
  input             enable,                 // CONTROL[0]: 1 = FLL, 0 = pass unchanged
  input             soft_reset,             // CONTROL[1], one cycle per write of 1
  input             load,                   // CONTROL[2], one cycle per write of 1
  output            enabled,                // STATUS[0]
  input      [4:0]  tap_shift,              // TAP_SHIFT: coefficients x 2^TAP_SHIFT
  input     [23:0]  alpha,                  // ALPHA: 2 alpha / pi 2^24
  input     [23:0]  beta,                   // BETA: 2 beta / pi 2^24
  input     [31:0]  freq_max,               // FREQ_MAX
  input     [31:0]  freq,                   // FREQ as written
  input             freq_wr,
  output    [31:0]  freq_rd,
  output    [31:0]  phase,                  // PHASE
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

  localparam NP = 64;                       // taps padded to 4^3 for the adder trees

  // ---------------------------------------------------------------------------
  // coefficients

  reg   [7:0] caddr = 8'd0;
  reg  signed [15:0] shadow [0:2*TAPS-1];
  reg  signed [15:0] c [0:NP-1];
  reg  signed [15:0] s [0:NP-1];

  integer k;
  initial begin
    for (k = 0; k < 2 * TAPS; k = k + 1)
      shadow[k] = 16'sd0;
    for (k = 0; k < NP; k = k + 1) begin
      c[k] = 16'sd0;
      s[k] = 16'sd0;
    end
  end

  always @(posedge clk) begin
    if (!rstn)
      caddr <= 8'd0;
    else if (coef_addr_wr)
      caddr <= coef_addr;
    else if (coef_data_wr) begin
      if (caddr < 2 * TAPS)
        shadow[caddr] <= coef_data;
      caddr <= caddr + 8'd1;
    end
    if (load)
      for (k = 0; k < TAPS; k = k + 1) begin
        c[k] <= shadow[2 * k];
        s[k] <= shadow[2 * k + 1];
      end
  end

  assign enabled = enable;
  assign coef_addr_rd = caddr;
  assign coef_data_rd = caddr < 2 * TAPS ? shadow[caddr] : 16'd0;

  // ---------------------------------------------------------------------------
  // per-sample sequence

  wire        rst = !rstn || soft_reset || flush;
  reg   [3:0] t = 4'd0;                     // step T0 .. T12
  reg         busy = 1'b0;
  reg  signed [15:0] xi = 0, xq = 0;
  reg  [71:0] user = 72'd0;
  reg         last = 1'b0, byp = 1'b0;
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
  assign freq_rd = f;
  assign phase = ph;

  wire [31:0] cs;
  glidelink_fll_rom i_rom (.clk(clk), .addr(ph[31:20]), .data(cs));
  wire signed [15:0] tc = cs[15:0], ts = cs[31:16];

  reg  signed [31:0] p_ic = 0, p_qs = 0, p_is = 0, p_qc = 0;
  reg  signed [33:0] re = 0, im = 0;
  reg  signed [15:0] yi = 0, yq = 0;
  reg  signed [15:0] hi [0:NP-1];
  reg  signed [15:0] hq [0:NP-1];
  reg  signed [31:0] mci [0:NP-1];
  reg  signed [31:0] mcq [0:NP-1];
  reg  signed [31:0] msi [0:NP-1];
  reg  signed [31:0] msq [0:NP-1];
  reg  signed [33:0] aci [0:15], acq [0:15], asi [0:15], asq [0:15];
  reg  signed [35:0] bci [0:3], bcq [0:3], bsi [0:3], bsq [0:3];
  reg  signed [37:0] pi_ = 0, pq_ = 0, qi_ = 0, qq_ = 0;
  reg  signed [17:0] pi18 = 0, pq18 = 0, qi18 = 0, qq18 = 0;
  reg  signed [36:0] e = 0;
  reg  signed [61:0] ma1 = 0, mb1 = 0, ma2 = 0, mb2 = 0;

  initial
    for (k = 0; k < NP; k = k + 1) begin
      hi[k] = 16'sd0;
      hq[k] = 16'sd0;
    end

  // x >>> 15 saturated to 16 bits (rounding constant already added)
  function signed [15:0] sat16;
    input signed [33:0] x;
    reg signed [33:0] y;
    begin
      y = x >>> 15;
      sat16 = y > 34'sd32767 ? 16'sh7FFF : y < -34'sd32768 ? -16'sd32768 : y[15:0];
    end
  endfunction

  // x >>> sh saturated to 18 bits
  function signed [17:0] sat18;
    input signed [37:0] x;
    input [4:0] sh;
    reg signed [37:0] y;
    begin
      y = x >>> sh;
      sat18 = y > 38'sd131071 ? 18'sh1FFFF : y < -38'sd131072 ? -18'sd131072 : y[17:0];
    end
  endfunction

  wire signed [37:0] dfb = mb2 >>> 24;                     // e BETA >>> 24 (full width:
  wire signed [37:0] dfa = ma2 >>> 24;                     // the limit applies to f' as is)
  wire signed [38:0] f2 = $signed({{7{f[31]}}, f}) - dfb;
  wire signed [38:0] fmax = $signed({7'd0, freq_max});

  integer j;
  always @(posedge clk) begin
    if (o_valid && m_axis_tready)
      o_valid <= 1'b0;
    if (rst) begin
      busy <= 1'b0;
      t <= 4'd0;
      o_valid <= 1'b0;
      ph <= 32'd0;
      f <= freq;
      for (j = 0; j < NP; j = j + 1) begin
        hi[j] <= 16'sd0;
        hq[j] <= 16'sd0;
      end
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
          t <= 4'd1;
        end
      end else begin
        t <= t + 4'd1;
        case (t)
          4'd1: begin
            p_ic <= xi * tc;
            p_qs <= xq * ts;
            p_is <= xi * ts;
            p_qc <= xq * tc;
          end
          4'd2: begin
            re <= p_ic - p_qs + 34'sd16384;
            im <= p_is + p_qc + 34'sd16384;
          end
          4'd3: begin
            if (byp) begin
              yi <= xi;
              yq <= xq;
              t <= 4'd12;                     // straight to the output
            end else begin
              yi <= sat16(re);
              yq <= sat16(im);
              hi[0] <= sat16(re);
              hq[0] <= sat16(im);
              for (j = 1; j < TAPS; j = j + 1) begin
                hi[j] <= hi[j - 1];
                hq[j] <= hq[j - 1];
              end
            end
          end
          4'd4:
            for (j = 0; j < NP; j = j + 1) begin
              mci[j] <= c[j] * hi[j];
              mcq[j] <= c[j] * hq[j];
              msi[j] <= s[j] * hi[j];
              msq[j] <= s[j] * hq[j];
            end
          4'd5:
            for (j = 0; j < 16; j = j + 1) begin
              aci[j] <= mci[4*j] + mci[4*j+1] + mci[4*j+2] + mci[4*j+3];
              acq[j] <= mcq[4*j] + mcq[4*j+1] + mcq[4*j+2] + mcq[4*j+3];
              asi[j] <= msi[4*j] + msi[4*j+1] + msi[4*j+2] + msi[4*j+3];
              asq[j] <= msq[4*j] + msq[4*j+1] + msq[4*j+2] + msq[4*j+3];
            end
          4'd6:
            for (j = 0; j < 4; j = j + 1) begin
              bci[j] <= aci[4*j] + aci[4*j+1] + aci[4*j+2] + aci[4*j+3];
              bcq[j] <= acq[4*j] + acq[4*j+1] + acq[4*j+2] + acq[4*j+3];
              bsi[j] <= asi[4*j] + asi[4*j+1] + asi[4*j+2] + asi[4*j+3];
              bsq[j] <= asq[4*j] + asq[4*j+1] + asq[4*j+2] + asq[4*j+3];
            end
          4'd7: begin
            pi_ <= bci[0] + bci[1] + bci[2] + bci[3];
            pq_ <= bcq[0] + bcq[1] + bcq[2] + bcq[3];
            qi_ <= bsi[0] + bsi[1] + bsi[2] + bsi[3];
            qq_ <= bsq[0] + bsq[1] + bsq[2] + bsq[3];
          end
          4'd8: begin
            pi18 <= sat18(pi_, tap_shift - 5'd1);
            pq18 <= sat18(pq_, tap_shift - 5'd1);
            qi18 <= sat18(qi_, tap_shift - 5'd1);
            qq18 <= sat18(qq_, tap_shift - 5'd1);
          end
          4'd9:
            e <= pq18 * qi18 - pi18 * qq18;
          4'd10: begin
            ma1 <= e * $signed({1'b0, alpha});
            mb1 <= e * $signed({1'b0, beta});
          end
          4'd11: begin
            ma2 <= ma1;
            mb2 <= mb1;
          end
          default: begin                      // T12: loop update, output
            t <= 4'd12;
            if (out_free) begin
              o_valid <= 1'b1;
              o_data <= {yq, yi};
              o_user <= user;
              o_last <= last;
              if (!byp) begin
                ph <= ph + f2[31:0] - dfa[31:0];
                if (!freq_wr)
                  f <= f2 < -fmax ? -freq_max : f2 > fmax ? freq_max : f2[31:0];
              end
              busy <= 1'b0;
              t <= 4'd0;
            end
          end
        endcase
      end
    end
  end

endmodule
