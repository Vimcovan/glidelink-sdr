// ***************************************************************************
// GlideLink user module: symbol sync (Gardner) for 2 samples per symbol.
// Description and registers: module.yaml; bit-exact reference: model.py.
//
// One input sample at a time; two multipliers (I and Q, 2 DSP slices) take
// the products in turn. A sample with a symbol takes 13 cycles, one without
// 3, so 2 samples per symbol take 16 (25 MSPS in at 200 MHz):
//   T0  take x into the history h0..h4
//   (when the NCO underflowed two samples ago, with its mu:)
//   T1  Farrow v2, v1 for the symbol (h0..h3) and the midpoint (h1..h4)
//   T2, T3  v2 mu (symbol, midpoint)   T3, T4  t = ((v2 mu) >>> 15) + v1
//   T4, T5  t mu                       T5, T6  y = sat16(c + (((t mu) >>> 15) >>> 1))
//   T7  ymI (ysI - yprevI), ymQ (ysQ - yprevQ)
//   T8  eq = (sum) >>> 9 (25 bits)
//   T9  eq KP, eq KI (gains 18 bits)  T10 v, integrator (within +-MAX_DEV)
//   T11 W = W0 + v within W0 +- MAX_DEV; ys out
//   last step of every sample (T12): eta -= W, underflow -> mu = min(eta >> 8, 32767)
// Disabled: samples pass unchanged.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_symsync (
  input             clk,
  input             rstn,
  input             flush,                  // stream state only (PORT_RESET): registers kept

  // registers (module.yaml; the register file is generated)
  input             enable,                 // CONTROL[0]
  input             soft_reset,             // CONTROL[1], one cycle per write of 1
  output            enabled,                // STATUS[0]
  input     [24:0]  w0,                     // W0: nominal NCO step, 1.0 = 2^24
  input     [23:0]  max_dev,                // MAX_DEV
  input     [17:0]  kp,                     // KP (signed): gain KP / 2^(KP_SHIFT + 3) per 2^30
  input      [4:0]  kp_shift,
  input     [17:0]  ki,                     // KI (signed), the same
  input      [4:0]  ki_shift,
  output    [24:0]  w,                      // W: NCO step now

  input             s_axis_tvalid,
  output            s_axis_tready,
  input     [31:0]  s_axis_tdata,

  output            m_axis_tvalid,
  input             m_axis_tready,
  output    [31:0]  m_axis_tdata
);

  wire        rst = !rstn || soft_reset || flush;
  reg   [3:0] t = 4'd0;
  reg         busy = 1'b0, byp = 1'b0;
  reg  signed [15:0] hi [0:4];
  reg  signed [15:0] hq [0:4];

  // NCO and loop
  reg  [23:0] eta = 24'd0;
  reg  signed [25:0] wr = 26'sd8388608;     // W (positive, 25 bits used)
  reg  signed [24:0] integ = 25'sd0;
  reg         f1 = 1'b0, f2 = 1'b0;         // underflow one / two samples ago
  reg  [14:0] mu1 = 15'd0, mu2 = 15'd0;
  reg  signed [15:0] ypi = 0, ypq = 0;      // previous symbol

  reg         o_valid = 1'b0;
  reg  [31:0] o_data = 32'd0;
  wire        out_free = !o_valid || m_axis_tready;

  assign s_axis_tready = !busy && !rst;
  assign m_axis_tvalid = o_valid;
  assign m_axis_tdata = o_data;
  assign enabled = enable;
  assign w = wr[24:0];

  integer j;
  initial
    for (j = 0; j < 5; j = j + 1) begin
      hi[j] = 16'sd0;
      hq[j] = 16'sd0;
    end

  // Farrow: v2 = a - b - c + d, v1 = -a + 3b - c - d (a newest)
  reg  signed [17:0] v2si = 0, v2sq = 0, v2mi = 0, v2mq = 0;
  reg  signed [18:0] v1si = 0, v1sq = 0, v1mi = 0, v1mq = 0;
  reg  signed [19:0] tsi = 0, tsq = 0, tmi = 0, tmq = 0;
  reg  signed [15:0] ysi = 0, ysq = 0, ymi = 0, ymq = 0;
  reg  signed [24:0] eq = 0;
  reg  signed [42:0] v = 0;

  wire signed [15:0] mus = {1'b0, mu2};

  function signed [17:0] fv2(input signed [15:0] a, b, c, d);
    fv2 = a - b - c + d;
  endfunction
  function signed [18:0] fv1(input signed [15:0] a, b, c, d);
    fv1 = -a + 3 * b - c - d;
  endfunction
  function signed [15:0] fy(input signed [42:0] p, input signed [15:0] c);
    reg signed [42:0] r;
    begin
      r = c + ((p >>> 15) >>> 1);
      fy = r > 43'sd32767 ? 16'sh7FFF : r < -43'sd32768 ? -16'sd32768 : r[15:0];
    end
  endfunction

  // the two multipliers: operands by step, product registered
  reg  signed [24:0] a0, a1;
  reg  signed [17:0] b0, b1;
  always @(*)
    case (t)
      4'd2:    begin a0 = v2si; b0 = mus; a1 = v2sq; b1 = mus; end
      4'd3:    begin a0 = v2mi; b0 = mus; a1 = v2mq; b1 = mus; end
      4'd4:    begin a0 = tsi;  b0 = mus; a1 = tsq;  b1 = mus; end
      4'd5:    begin a0 = tmi;  b0 = mus; a1 = tmq;  b1 = mus; end
      4'd7:    begin a0 = ymi;  b0 = ysi - ypi; a1 = ymq; b1 = ysq - ypq; end
      default: begin a0 = eq;   b0 = kp;  a1 = eq;   b1 = ki;  end
    endcase
  reg  signed [42:0] m0 = 0, m1 = 0;
  always @(posedge clk) begin
    m0 <= a0 * b0;
    m1 <= a1 * b1;
  end

  wire signed [42:0] dev = {19'd0, max_dev};
  wire signed [42:0] vsum = integ + (m0 >>> kp_shift);
  wire signed [42:0] isum = integ + (m1 >>> ki_shift);
  wire signed [43:0] wsum = $signed({19'd0, w0}) + v;
  wire signed [43:0] wlo = $signed({19'd0, w0}) - dev, whi = $signed({19'd0, w0}) + dev;
  wire signed [26:0] nxt = $signed({3'd0, eta}) - wr;

  always @(posedge clk) begin
    if (o_valid && m_axis_tready)
      o_valid <= 1'b0;
    if (rst) begin
      busy <= 1'b0;
      t <= 4'd0;
      o_valid <= 1'b0;
      eta <= 24'd0;
      wr <= {1'b0, w0};
      integ <= 25'sd0;
      f1 <= 1'b0;
      f2 <= 1'b0;
      ypi <= 16'sd0;
      ypq <= 16'sd0;
      for (j = 0; j < 5; j = j + 1) begin
        hi[j] <= 16'sd0;
        hq[j] <= 16'sd0;
      end
    end else if (!busy) begin
      if (s_axis_tvalid) begin                // T0
        hi[0] <= s_axis_tdata[15:0];
        hq[0] <= s_axis_tdata[31:16];
        for (j = 1; j < 5; j = j + 1) begin
          hi[j] <= hi[j - 1];
          hq[j] <= hq[j - 1];
        end
        byp <= !enable;
        busy <= 1'b1;
        t <= 4'd1;
      end
    end else begin
      t <= t + 4'd1;
      if (byp) begin                          // pass unchanged
        if (out_free) begin
          o_valid <= 1'b1;
          o_data <= {hq[0], hi[0]};
          busy <= 1'b0;
          t <= 4'd0;
        end
      end else if (!f2 && t == 4'd1) begin   // no symbol here: NCO only
        t <= 4'd12;
      end else begin
        case (t)
          4'd1: begin
            v2si <= fv2(hi[0], hi[1], hi[2], hi[3]);  v1si <= fv1(hi[0], hi[1], hi[2], hi[3]);
            v2sq <= fv2(hq[0], hq[1], hq[2], hq[3]);  v1sq <= fv1(hq[0], hq[1], hq[2], hq[3]);
            v2mi <= fv2(hi[1], hi[2], hi[3], hi[4]);  v1mi <= fv1(hi[1], hi[2], hi[3], hi[4]);
            v2mq <= fv2(hq[1], hq[2], hq[3], hq[4]);  v1mq <= fv1(hq[1], hq[2], hq[3], hq[4]);
          end
          4'd3: begin
            tsi <= (m0 >>> 15) + v1si;  tsq <= (m1 >>> 15) + v1sq;
          end
          4'd4: begin
            tmi <= (m0 >>> 15) + v1mi;  tmq <= (m1 >>> 15) + v1mq;
          end
          4'd5: begin
            ysi <= fy(m0, hi[2]);  ysq <= fy(m1, hq[2]);
          end
          4'd6: begin
            ymi <= fy(m0, hi[3]);  ymq <= fy(m1, hq[3]);
          end
          4'd8:
            eq <= (m0 + m1) >>> 9;
          4'd10: begin
            v <= vsum;
            integ <= isum < -dev ? -dev[24:0] : isum > dev ? dev[24:0] : isum[24:0];
          end
          4'd11: begin
            if (out_free) begin
              wr <= wsum < wlo ? wlo[25:0] : wsum > whi ? whi[25:0] : wsum[25:0];
              ypi <= ysi;
              ypq <= ysq;
              o_valid <= 1'b1;
              o_data <= {ysq, ysi};
            end else begin
              t <= 4'd11;                     // wait for room at the output
            end
          end
          4'd12: begin                        // T12: NCO
            if (nxt < 0) begin
              f1 <= 1'b1;
              mu1 <= eta[23:8] > 16'd32767 ? 15'd32767 : eta[22:8];
              eta <= nxt[23:0];               // + 2^24, modulo 2^24
            end else begin
              f1 <= 1'b0;
              eta <= nxt[23:0];
            end
            f2 <= f1;
            mu2 <= mu1;
            busy <= 1'b0;
            t <= 4'd0;
          end
          default: ;
        endcase
      end
    end
  end

endmodule
