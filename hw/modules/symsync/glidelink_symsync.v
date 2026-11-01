// ***************************************************************************
// GlideLink user module: symbol sync (Gardner) for 2 samples per symbol.
// Description and registers: module.yaml; bit-exact reference: model.py.
//
// One input sample at a time (25 MSPS at 200 MHz):
//   T0  take x into the history h0..h4
//   (when the NCO underflowed two samples ago, with its mu:)
//   T1  Farrow v2, v1 for the symbol (h0..h3) and the midpoint (h1..h4)
//   T2  t = ((v2 mu) >>> 15) + v1      T3  y = sat16(c + (((t mu) >>> 15) >>> 1))
//   T4  e = ymI (ysI - yprevI) + ymQ (ysQ - yprevQ)
//   T5  e KP, e KI                      T6  v, integrator (within +-MAX_DEV)
//   T7  W = W0 + v within W0 +- MAX_DEV; ys out
//   last step of every sample: eta -= W, underflow -> mu = min(eta >> 8, 32767)
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
  input     [23:0]  kp,                     // KP (signed)
  input     [23:0]  ki,                     // KI (signed)
  output    [24:0]  w,                      // W: NCO step now

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
  reg   [3:0] t = 4'd0;
  reg         busy = 1'b0, byp = 1'b0;
  reg  signed [15:0] hi [0:4];
  reg  signed [15:0] hq [0:4];
  reg  [71:0] user = 72'd0;
  reg         last = 1'b0;

  // NCO and loop
  reg  [23:0] eta = 24'd0;
  reg  signed [25:0] wr = 26'sd8388608;     // W (positive, 25 bits used)
  reg  signed [24:0] integ = 25'sd0;
  reg         f1 = 1'b0, f2 = 1'b0;         // underflow one / two samples ago
  reg  [14:0] mu1 = 15'd0, mu2 = 15'd0;
  reg  signed [15:0] ypi = 0, ypq = 0;      // previous symbol

  // packet marks carried to the next output
  reg         p_first = 1'b0, p_last = 1'b0, at_start = 1'b1;
  reg  [71:0] p_user = 72'd0;

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
  reg  signed [33:0] e = 0;
  reg  signed [57:0] ekp = 0, eki = 0;
  reg  signed [28:0] v = 0;

  wire signed [15:0] mus = {1'b0, mu2};

  function signed [17:0] fv2(input signed [15:0] a, b, c, d);
    fv2 = a - b - c + d;
  endfunction
  function signed [18:0] fv1(input signed [15:0] a, b, c, d);
    fv1 = -a + 3 * b - c - d;
  endfunction
  function signed [19:0] ft(input signed [17:0] v2_, input signed [18:0] v1_, input signed [15:0] m);
    reg signed [33:0] p;
    begin
      p = v2_ * m;
      ft = (p >>> 15) + v1_;
    end
  endfunction
  function signed [15:0] fy(input signed [19:0] t_, input signed [15:0] c, input signed [15:0] m);
    reg signed [35:0] p;
    reg signed [21:0] r;
    begin
      p = t_ * m;
      r = c + ((p >>> 15) >>> 1);
      fy = r > 22'sd32767 ? 16'sh7FFF : r < -22'sd32768 ? -16'sd32768 : r[15:0];
    end
  endfunction

  wire signed [25:0] dev = {2'b00, max_dev};
  wire signed [57:0] ekpd = ekp >>> 30, ekid = eki >>> 30;
  wire signed [28:0] vsum = integ + $signed(ekpd[28:0]);  // a part-select is unsigned
  wire signed [29:0] isum = integ + $signed(ekid[29:0]);
  wire signed [29:0] wsum = $signed({4'd0, w0}) + v;
  wire signed [29:0] wlo = $signed({4'd0, w0}) - dev, whi = $signed({4'd0, w0}) + dev;
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
      p_first <= 1'b0;
      p_last <= 1'b0;
      at_start <= 1'b1;
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
        user <= s_axis_tuser;
        last <= s_axis_tlast;
        byp <= !enable;
        busy <= 1'b1;
        t <= 4'd1;
        // packet marks since the previous output
        at_start <= s_axis_tlast;
        if (at_start && !p_first) begin
          p_first <= 1'b1;
          p_user <= s_axis_tuser;
        end
        p_last <= p_last || s_axis_tlast;
      end
    end else begin
      t <= t + 4'd1;
      if (byp) begin                          // pass unchanged
        if (out_free) begin
          o_valid <= 1'b1;
          o_data <= {hq[0], hi[0]};
          o_user <= user;
          o_last <= last;
          p_first <= 1'b0;
          p_last <= 1'b0;
          busy <= 1'b0;
          t <= 4'd0;
        end
      end else if (!f2 && t == 4'd1) begin   // no symbol here: NCO only
        t <= 4'd8;
      end else begin
        case (t)
          4'd1: begin
            v2si <= fv2(hi[0], hi[1], hi[2], hi[3]);  v1si <= fv1(hi[0], hi[1], hi[2], hi[3]);
            v2sq <= fv2(hq[0], hq[1], hq[2], hq[3]);  v1sq <= fv1(hq[0], hq[1], hq[2], hq[3]);
            v2mi <= fv2(hi[1], hi[2], hi[3], hi[4]);  v1mi <= fv1(hi[1], hi[2], hi[3], hi[4]);
            v2mq <= fv2(hq[1], hq[2], hq[3], hq[4]);  v1mq <= fv1(hq[1], hq[2], hq[3], hq[4]);
          end
          4'd2: begin
            tsi <= ft(v2si, v1si, mus);  tsq <= ft(v2sq, v1sq, mus);
            tmi <= ft(v2mi, v1mi, mus);  tmq <= ft(v2mq, v1mq, mus);
          end
          4'd3: begin
            ysi <= fy(tsi, hi[2], mus);  ysq <= fy(tsq, hq[2], mus);
            ymi <= fy(tmi, hi[3], mus);  ymq <= fy(tmq, hq[3], mus);
          end
          4'd4:
            e <= ymi * (ysi - ypi) + ymq * (ysq - ypq);
          4'd5: begin
            ekp <= e * $signed(kp);
            eki <= e * $signed(ki);
          end
          4'd6: begin
            v <= vsum;
            integ <= isum < -dev ? -dev[24:0] : isum > dev ? dev[24:0] : isum[24:0];
          end
          4'd7: begin
            if (out_free) begin
              wr <= wsum < wlo ? wlo[25:0] : wsum > whi ? whi[25:0] : wsum[25:0];
              ypi <= ysi;
              ypq <= ysq;
              o_valid <= 1'b1;
              o_data <= {ysq, ysi};
              o_user <= p_first ? p_user : 72'd0;
              o_last <= p_last;
              p_first <= 1'b0;
              p_last <= 1'b0;
            end else begin
              t <= 4'd7;                      // wait for room at the output
            end
          end
          default: begin                      // T8: NCO
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
        endcase
      end
    end
  end

endmodule
