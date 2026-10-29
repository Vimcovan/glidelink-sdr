// Testbench for glidelink_switch (3 sources x 3 sinks). Sources send packets
// with data {src[3:0], seq[11:0], idx[15:0]} and lengths 8..12; sinks apply
// random back-pressure. Routes change in three phases:
//   1  sink k <- source k
//   2  sink 0 <- 2, sink 1 <- none, sink 2 <- 0
//   3  sink 0 <- 1, sink 1 <- none, sink 2 <- 1 (conflict: sink 0 wins)
// Checks: sinks only see whole packets (idx 0.. with tlast at the end), a
// source's packets reach a sink in order without repeats, each sink gets
// data only from its route once a phase has settled, unrouted sinks stay
// silent, and the losing sink of a conflict gets nothing.

`timescale 1ns/100ps

module tb_switch;

  reg         clk = 0;
  always #2.5 clk = ~clk;
  reg         rst = 1;
  reg  [11:0] route = {4'd2, 4'd1, 4'd0};

  reg  [2:0]  s_valid = 0;
  wire [2:0]  s_ready;
  reg  [95:0] s_data = 0;
  reg  [2:0]  s_last = 0;
  wire [2:0]  m_valid;
  reg  [2:0]  m_ready = 0;
  wire [95:0] m_data;
  wire [2:0]  m_last;

  glidelink_switch #(.N_SRC(3), .N_SNK(3)) dut (
    .clk(clk), .rst(rst), .route(route), .abort_snk(3'd0), .abort_src(3'd0),
    .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data), .s_user(216'd0), .s_last(s_last),
    .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data), .m_user(), .m_last(m_last));

  // sources
  integer     k;
  reg  [11:0] seq [0:2];
  reg  [15:0] idx [0:2];
  initial for (k = 0; k < 3; k = k + 1) begin seq[k] = 0; idx[k] = 0; end

  function [15:0] plen(input [11:0] s);
    plen = 8 + (s % 5);
  endfunction

  always @(posedge clk) if (!rst) begin
    for (k = 0; k < 3; k = k + 1) begin
      if (s_valid[k] && s_ready[k]) begin
        if (s_last[k]) begin seq[k] = seq[k] + 1; idx[k] = 0; end
        else idx[k] = idx[k] + 1;
      end
      if (!s_valid[k] || s_ready[k]) begin
        s_valid[k] <= ($random & 3) != 0;
        s_data[k*32 +: 32] <= {k[3:0], seq[k], idx[k]};
        s_last[k] <= idx[k] == plen(seq[k]) - 1;
      end
    end
    m_ready <= $random;
  end

  // sinks
  integer     errors = 0, phase = 1;
  integer     got [0:2][0:2];               // [sink][src] beats in the settled part of a phase
  reg  [15:0] exp_idx [0:2];
  reg  [11:0] last_seq [0:2][0:2];
  reg         seen [0:2][0:2];
  reg         settled = 0;
  integer     a, b;
  initial for (a = 0; a < 3; a = a + 1) begin
    exp_idx[a] = 0;
    for (b = 0; b < 3; b = b + 1) begin got[a][b] = 0; seen[a][b] = 0; end
  end

  reg  [3:0]  src;
  reg  [11:0] sq;
  reg  [15:0] ix;
  always @(posedge clk) if (!rst) begin
    for (a = 0; a < 3; a = a + 1) if (m_valid[a] && m_ready[a]) begin
      {src, sq, ix} = m_data[a*32 +: 32];
      if (ix != exp_idx[a]) begin
        $display("ERROR: sink %0d got idx %0d of src %0d seq %0d, expected idx %0d", a, ix, src, sq, exp_idx[a]);
        errors = errors + 1;
      end
      if (ix == 0) begin
        if (seen[a][src] && sq <= last_seq[a][src]) begin
          $display("ERROR: sink %0d got src %0d seq %0d after seq %0d", a, src, sq, last_seq[a][src]);
          errors = errors + 1;
        end
        seen[a][src] = 1;
        last_seq[a][src] = sq;
      end
      if (m_last[a] != (ix == plen(sq) - 1)) begin
        $display("ERROR: sink %0d tlast %b at idx %0d of a %0d-beat packet", a, m_last[a], ix, plen(sq));
        errors = errors + 1;
      end
      exp_idx[a] = m_last[a] ? 0 : ix + 1;
      if (settled) got[a][src] = got[a][src] + 1;
    end
  end

  task expect_only(input integer snk, input integer s);   // s = -1: nothing
    integer x;
    begin
      for (x = 0; x < 3; x = x + 1)
        if ((x == s) ? got[snk][x] < 100 : got[snk][x] != 0) begin
          $display("ERROR: phase %0d sink %0d got %0d beats from src %0d", phase, snk, got[snk][x], x);
          errors = errors + 1;
        end
    end
  endtask

  task run_phase(input [11:0] r);
    begin
      route = r;
      settled = 0;
      #500;                                  // route sync + packets in flight finish
      for (a = 0; a < 3; a = a + 1) for (b = 0; b < 3; b = b + 1) got[a][b] = 0;
      settled = 1;
      #20000;
      settled = 0;
    end
  endtask

  initial begin
    #50 rst = 0;
    run_phase({4'd2, 4'd1, 4'd0});
    expect_only(0, 0); expect_only(1, 1); expect_only(2, 2);
    phase = 2;
    run_phase({4'd0, 4'hF, 4'd2});
    expect_only(0, 2); expect_only(1, -1); expect_only(2, 0);
    phase = 3;
    run_phase({4'd1, 4'hF, 4'd1});
    expect_only(0, 1); expect_only(1, -1); expect_only(2, -1);
    $display("packets: sink0 got %0d/%0d/%0d beats from src 0/1/2 in phase 3", got[0][0], got[0][1], got[0][2]);
    if (errors == 0) $display("PASS tb_switch");
    else $display("FAIL tb_switch: %0d errors", errors);
    $finish;
  end

endmodule
