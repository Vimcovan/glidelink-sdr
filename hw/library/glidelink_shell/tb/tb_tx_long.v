// TX streamer with packets longer than its buffer (OFDM frames: 55,960 samples),
// each ending a burst, sent back to back, at the AD9361 1R1T rate (one dac_valid
// per 4 l_clk). Every packet must reach the DAC, in order and complete.
`timescale 1ns/100ps
module tb_tx_long;
  localparam LEN = 20000, PKTS = 4;
  reg s_clk = 0, l_clk = 0;
  always #2.5  s_clk = ~s_clk;     // 200 MHz
  always #6.25 l_clk = ~l_clk;     // 80 MHz
  reg s_rst = 1, l_rst = 1;
  reg [1:0] vc = 0; reg dac_valid = 0; reg [63:0] t = 0;
  always @(posedge l_clk) begin vc <= vc + 1; dac_valid <= vc == 0; if (dac_valid) t <= t + 1; end
  reg  s_valid = 0; reg [31:0] s_data = 0; reg s_last = 0; wire s_ready;
  integer n = 0;
  reg [15:0] pk, ix;
  always @(posedge s_clk) if (!s_rst) begin
    if (s_valid && s_ready) n = n + 1;
    pk = 16'hA000 + n / LEN;
    ix = n % LEN;
    s_valid <= n < LEN * PKTS;
    s_data <= {pk, ix};
    s_last <= (n % LEN) == LEN - 1;
  end
  wire [15:0] di, dq;
  glidelink_tx_stream dut (.s_clk(s_clk), .s_rst(s_rst), .s_axis_tdata(s_data), .s_axis_tuser({8'h02, 64'd0}),
    .s_axis_tlast(s_last), .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
    .l_clk(l_clk), .l_rst(l_rst), .dac_valid(dac_valid), .dac_data_i(di), .dac_data_q(dq),
    .time_now(t), .late_drop(1'b1), .underflow_gray(), .late_gray(), .dac_dunf());
  integer got = 0, err = 0;
  always @(posedge l_clk) if (dac_valid && dq[15:12] == 4'hA) begin
    if (dq != 16'hA000 + got / LEN || di != (got % LEN) % 65536) begin if (err < 5) $display("ERROR at %0d: %h %h", got, dq, di); err = err + 1; end
    got = got + 1;
  end
  initial begin
    #100 s_rst = 0; l_rst = 0;
    #(12.5 * 4 * (LEN * PKTS + 20000));
    $display("%0d of %0d samples out, %0d errors", got, LEN * PKTS, err);
    if (got == LEN * PKTS && err == 0) $display("PASS tb_tx_long"); else $display("FAIL tb_tx_long");
    $finish;
  end
endmodule
