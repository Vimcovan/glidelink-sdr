// ***************************************************************************
// GlideLink user module: FLL band-edge, as GNU Radio's fll_band_edge_cc in
// fixed point. Description and registers: module.yaml; bit-exact reference:
// model.py.
//
// One sample at a time, each turned by the phase the previous one left (as the
// software recursion), 16 cycles per sample (12.5 MSPS at 200 MHz), 16 DSP
// slices. The band-edge sums P = c_0 y_n + sum_{k>=1} c_k y_{n-k} (and Q with
// s) are split: the older part only needs the history, so a multiply-
// accumulate engine (3 lanes x 4 products: c y_i, c y_q, s y_i, s y_q) works
// it out for the next sample while this one is processed, newest tap last;
// the newest sample's part goes through the recursion:
//   t0  take x; table address = phase[31:20]; the engine starts on the next
//       sample's older taps (16 cycles, 3 taps each)
//   t1, t2  x * (cos, sin) on 2 shared multipliers, t2, t3 sums with rounding
//   t3, t4  y saturated, into the history (bypass: y = x, straight to t14)
//   t5, t6  c_0 y, s_0 y on the same 2 multipliers, t6, t7 + the engine's sums
//   t7, t8  P, Q >>> (TAP_SHIFT - 1), saturated to 18 bits
//   t9, t10 Pq Qi, Pi Qq on 1 multiplier, t11 eq = (Pq Qi - Pi Qq) >>> 12
//   t12, t13 eq BETA, eq ALPHA on 1 multiplier (eq 25 bits, gains 17)
//   t14 f' = f - (eq BETA >>> BETA_SHIFT), phase += f' - (eq ALPHA >>>
//       ALPHA_SHIFT), f = f' within +-FREQ_MAX; y out
// History: a 64-entry ring with the number of entries since the last reset
// (older ones count as 0), so a reset clears it at once.
// Coefficients: shadow set written through COEF_ADDR / COEF_DATA (2k = c_k,
// 2k + 1 = s_k), active on CONTROL.load (the engine then works the older part
// out again before the next sample). Soft reset and flush clear the history,
// set the phase to 0 and the frequency to FREQ as written.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_fll #(
  parameter TAPS = 48                       // at most 64
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
  input     [16:0]  alpha,                  // ALPHA, ALPHA_SHIFT: 2 alpha / pi = ALPHA / 2^(ALPHA_SHIFT + 12)
  input      [4:0]  alpha_shift,
  input     [16:0]  beta,                   // BETA, BETA_SHIFT: the same for beta
  input      [4:0]  beta_shift,
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

  output            m_axis_tvalid,
  input             m_axis_tready,
  output    [31:0]  m_axis_tdata
);

  localparam LANES = 3;
  localparam NI = (TAPS + 1) / LANES;       // engine cycles: taps TAPS-1 .. 1, 3 at a time

  // ---------------------------------------------------------------------------
  // coefficients

  reg   [7:0] caddr = 8'd0;
  reg  signed [15:0] shadow [0:2*TAPS-1];
  reg  signed [15:0] c [0:TAPS-1];
  reg  signed [15:0] s [0:TAPS-1];

  integer k;
  initial begin
    for (k = 0; k < 2 * TAPS; k = k + 1)
      shadow[k] = 16'sd0;
    for (k = 0; k < TAPS; k = k + 1) begin
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
  // history ring: {y_q, y_i}

  reg  [31:0] hmem [0:63];
  reg   [5:0] wp = 6'd0;                    // slot of the next output
  reg   [6:0] cnt = 7'd0;                   // entries since the reset, at most TAPS
  reg   [5:0] wslot = 6'd0;                 // slot of the sample being processed

  initial
    for (k = 0; k < 64; k = k + 1)
      hmem[k] = 32'd0;

  // ---------------------------------------------------------------------------
  // per-sample control

  wire        rst = !rstn || soft_reset || flush;
  reg   [3:0] t = 4'd0;                     // step t0 .. t14
  reg         busy = 1'b0;
  reg  signed [15:0] xi = 0, xq = 0;
  reg         byp = 1'b0;
  reg  [31:0] ph = 32'd0;
  reg  signed [31:0] f = 32'sd0;

  reg         run = 1'b0;                   // the engine issuing
  reg   [4:0] ri = 5'd0;                    // its cycle
  reg   [5:0] rb = 6'd0;                    // slot of the newest output it uses (age 0)
  reg   [6:0] rcnt = 7'd0;                  // valid entries for it
  reg         redo = 1'b0;                  // coefficients loaded: older part again

  reg         o_valid = 1'b0;
  reg  [31:0] o_data = 32'd0;
  wire        out_free = !o_valid || m_axis_tready;

  wire        run_free = !run || ri == NI - 1;
  wire        take = !rst && !busy && run_free && !redo && s_axis_tvalid;
  assign s_axis_tready = !rst && !busy && run_free && !redo;
  assign m_axis_tvalid = o_valid;
  assign m_axis_tdata = o_data;
  assign freq_rd = f;
  assign phase = ph;

  // ---------------------------------------------------------------------------
  // the engine: next sample's sum over taps k = TAPS-1 .. 1 of c_k y, s_k y;
  // lane j, cycle i: tap TAPS-1 - 3i - j, the output of age k - 1

  reg         p1v = 1'b0, p1first = 1'b0, p1last = 1'b0;
  reg         p2v = 1'b0, p2first = 1'b0, p2last = 1'b0;
  reg  signed [37:0] aci = 0, acq = 0, asi = 0, asq = 0;     // running sums
  reg  signed [37:0] rci = 0, rcq = 0, rsi = 0, rsq = 0;     // results for the next sample

  wire signed [31:0] lci [0:LANES-1], lcq [0:LANES-1], lsi [0:LANES-1], lsq [0:LANES-1];

  genvar j;
  generate
    for (j = 0; j < LANES; j = j + 1) begin : lane
      wire signed [8:0] tk = TAPS - 1 - LANES * $signed({4'd0, ri}) - j;
      wire              kv = tk >= 1;
      wire        [8:0] age = tk - 9'd1;
      wire              hv = kv && age < {2'd0, rcnt};
      wire        [5:0] addr = rb - age[5:0];
      reg  signed [15:0] hi = 0, hq = 0, cc = 0, ss = 0;
      reg  signed [31:0] mci = 0, mcq = 0, msi = 0, msq = 0;
      always @(posedge clk) begin
        hi <= hv ? hmem[addr][15:0] : 16'sd0;
        hq <= hv ? hmem[addr][31:16] : 16'sd0;
        cc <= kv ? c[tk[5:0]] : 16'sd0;
        ss <= kv ? s[tk[5:0]] : 16'sd0;
        mci <= cc * hi;
        mcq <= cc * hq;
        msi <= ss * hi;
        msq <= ss * hq;
      end
      assign lci[j] = mci;
      assign lcq[j] = mcq;
      assign lsi[j] = msi;
      assign lsq[j] = msq;
    end
  endgenerate

  wire signed [37:0] nci = (p2first ? 38'sd0 : aci) + lci[0] + lci[1] + lci[2];
  wire signed [37:0] ncq = (p2first ? 38'sd0 : acq) + lcq[0] + lcq[1] + lcq[2];
  wire signed [37:0] nsi = (p2first ? 38'sd0 : asi) + lsi[0] + lsi[1] + lsi[2];
  wire signed [37:0] nsq = (p2first ? 38'sd0 : asq) + lsq[0] + lsq[1] + lsq[2];

  // ---------------------------------------------------------------------------
  // the recursion: shared multipliers

  wire [31:0] cs;
  glidelink_fll_rom i_rom (.clk(clk), .addr(ph[31:20]), .data(cs));
  wire signed [15:0] tc = cs[15:0], ts = cs[31:16];

  reg  signed [15:0] yi = 0, yq = 0;
  reg  signed [33:0] re = 0, im = 0;
  reg  signed [37:0] pi_ = 0, pq_ = 0, qi_ = 0, qq_ = 0;
  reg  signed [17:0] pi18 = 0, pq18 = 0, qi18 = 0, qq18 = 0;
  reg  signed [35:0] e0 = 0;
  reg  signed [24:0] eq = 0;
  reg  signed [41:0] dfb = 0;

  // 2 multipliers: x (cos, sin) at t1, t2; (c_0, s_0) y at t5, t6
  wire        m_rot = t == 4'd1 || t == 4'd2;
  wire signed [15:0] a0 = m_rot ? xi : t == 4'd5 ? c[0] : s[0];
  wire signed [15:0] b0 = m_rot ? (t == 4'd1 ? tc : ts) : yi;
  wire signed [15:0] a1 = m_rot ? xq : t == 4'd5 ? c[0] : s[0];
  wire signed [15:0] b1 = m_rot ? (t == 4'd1 ? ts : tc) : yq;
  (* keep = "true" *) reg signed [31:0] m0 = 0, m1 = 0;   // kept: synthesis would copy the multiplier into each adder after it
  // 1 multiplier: Pq Qi at t9, Pi Qq at t10
  wire signed [17:0] ea = t == 4'd9 ? pq18 : pi18;
  wire signed [17:0] eb = t == 4'd9 ? qi18 : qq18;
  (* keep = "true" *) reg signed [35:0] em = 0;
  // 1 multiplier: eq BETA at t12, eq ALPHA at t13
  wire signed [17:0] lg = $signed({1'b0, t == 4'd12 ? beta : alpha});
  reg  signed [41:0] lm = 0;

  always @(posedge clk) begin
    m0 <= a0 * b0;
    m1 <= a1 * b1;
    if (t == 4'd9 || t == 4'd10)
      em <= ea * eb;
    if (t == 4'd12 || t == 4'd13)
      lm <= eq * lg;
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

  wire signed [41:0] dfa = lm >>> alpha_shift;              // full width: the limit applies
  wire signed [42:0] f2 = $signed({{11{f[31]}}, f}) - dfb;  // to f' as is
  wire signed [42:0] fmax = $signed({11'd0, freq_max});

  always @(posedge clk) begin
    if (o_valid && m_axis_tready)
      o_valid <= 1'b0;
    if (rst) begin
      busy <= 1'b0;
      t <= 4'd0;
      o_valid <= 1'b0;
      ph <= 32'd0;
      f <= freq;
      wp <= 6'd0;
      cnt <= 7'd0;
      run <= 1'b0;
      redo <= 1'b0;
      p1v <= 1'b0;
      p2v <= 1'b0;
      rci <= 38'sd0;                          // empty history: the older part is 0
      rcq <= 38'sd0;
      rsi <= 38'sd0;
      rsq <= 38'sd0;
    end else begin
      if (freq_wr)
        f <= freq;
      if (load)
        redo <= 1'b1;

      // the engine
      p1v <= run;
      p1first <= run && ri == 5'd0;
      p1last <= run && ri == NI - 1;
      p2v <= p1v;
      p2first <= p1first;
      p2last <= p1last;
      if (p2v) begin
        aci <= nci;
        acq <= ncq;
        asi <= nsi;
        asq <= nsq;
        if (p2last) begin
          rci <= nci;
          rcq <= ncq;
          rsi <= nsi;
          rsq <= nsq;
        end
      end
      if (run)
        ri <= ri + 5'd1;
      if (run && ri == NI - 1)
        run <= 1'b0;
      if (take && enable) begin               // next sample: this one's output is age 0
        run <= 1'b1;
        ri <= 5'd0;
        rb <= wp;
        rcnt <= cnt == TAPS ? cnt : cnt + 7'd1;
      end else if (!busy && !run && redo && !load) begin   // coefficients changed: again
        run <= 1'b1;
        ri <= 5'd0;
        rb <= wp - 6'd1;
        rcnt <= cnt;
        redo <= 1'b0;
      end

      // the sample
      if (take) begin                         // t0
        xi <= s_axis_tdata[15:0];
        xq <= s_axis_tdata[31:16];
        byp <= !enable;
        busy <= 1'b1;
        t <= 4'd1;
        if (enable) begin
          wslot <= wp;
          wp <= wp + 6'd1;
          if (cnt != TAPS)
            cnt <= cnt + 7'd1;
        end
      end else if (busy) begin
        t <= t + 4'd1;
        case (t)
          4'd2:
            re <= m0 - m1 + 34'sd16384;
          4'd3: begin
            im <= m0 + m1 + 34'sd16384;
            yi <= sat16(re);
            if (byp) begin
              yi <= xi;
              yq <= xq;
              t <= 4'd14;                     // straight to the output
            end
          end
          4'd4: begin
            yq <= sat16(im);
            hmem[wslot] <= {sat16(im), yi};
          end
          4'd6: begin
            pi_ <= rci + m0;
            pq_ <= rcq + m1;
          end
          4'd7: begin
            qi_ <= rsi + m0;
            qq_ <= rsq + m1;
            pi18 <= sat18(pi_, tap_shift - 5'd1);
            pq18 <= sat18(pq_, tap_shift - 5'd1);
          end
          4'd8: begin
            qi18 <= sat18(qi_, tap_shift - 5'd1);
            qq18 <= sat18(qq_, tap_shift - 5'd1);
          end
          4'd10:
            e0 <= em;
          4'd11:
            eq <= ($signed({e0[35], e0}) - $signed({em[35], em})) >>> 12;
          4'd13:
            dfb <= lm >>> beta_shift;
          4'd14: begin                        // loop update, output
            t <= 4'd14;
            if (out_free) begin
              o_valid <= 1'b1;
              o_data <= {yq, yi};
              if (!byp) begin
                ph <= ph + f2[31:0] - dfa[31:0];
                if (!freq_wr)
                  f <= f2 < -fmax ? -freq_max : f2 > fmax ? freq_max : f2[31:0];
              end
              busy <= 1'b0;
              t <= 4'd0;
            end
          end
          default: ;
        endcase
      end
    end
  end

endmodule
