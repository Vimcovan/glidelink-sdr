// RX streamer with nobody reading (tready = 0): overflow must count dropped packets,
// one per pkt_len samples, not samples.
`timescale 1ns/100ps
module tb_rx_idle;
  reg l_clk = 0, m_clk = 0;
  always #12.5 l_clk = ~l_clk;     // 40 MHz
  always #2.5  m_clk = ~m_clk;     // 200 MHz
  reg l_rst = 1, m_rst = 1;
  reg [1:0] vcnt = 0; reg adc_valid = 0; reg [63:0] t = 0;
  always @(posedge l_clk) begin vcnt <= vcnt + 1; adc_valid <= vcnt == 0; if (adc_valid) t <= t + 1; end
  wire [31:0] ovf_g;
  glidelink_rx_stream dut (.l_clk(l_clk), .l_rst(l_rst), .adc_valid(adc_valid), .adc_data_i(t[15:0]), .adc_data_q(~t[15:0]),
    .time_now(t), .pkt_len(16'd256), .enable(1'b1), .overflow_gray(ovf_g), .adc_dovf(),
    .m_clk(m_clk), .m_rst(m_rst), .m_axis_tdata(), .m_axis_tuser(), .m_axis_tlast(), .m_axis_tvalid(), .m_axis_tready(1'b0));
  function [31:0] g2b(input [31:0] g); integer i; begin g2b[31] = g[31]; for (i = 30; i >= 0; i = i - 1) g2b[i] = g2b[i+1] ^ g[i]; end endfunction
  initial begin
    #200 l_rst = 0; m_rst = 0;
    #4000000;
    $display("samples %0d, overflow %0d (whole packets of 256 after the 8192-sample buffer fills: about %0d)",
             t, g2b(ovf_g), (t - 8192) / 256);
    if (g2b(ovf_g) > t / 256 + 2) $display("FAIL"); else $display("PASS");
    $finish;
  end
endmodule
