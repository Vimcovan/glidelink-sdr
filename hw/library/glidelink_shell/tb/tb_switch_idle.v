// Stream switch: a route to a source that never sends is changed to another
// source; that source's packets must come through (a sink must not hold on to
// an idle source and wait for a packet boundary that never comes).
`timescale 1ns/100ps
module tb_switch_idle;
  reg clk = 0; always #2.5 clk = ~clk;
  reg rst = 1;
  reg [11:0] route = {4'hF, 4'hF, 4'd1};          // sink 0 <- source 1 (idle)
  reg [2:0] s_valid = 0, s_last = 0; reg [95:0] s_data = 0;
  wire [2:0] s_ready, m_valid, m_last; wire [95:0] m_data;
  glidelink_switch #(.N_SRC(3), .N_SNK(3)) dut (.clk(clk), .rst(rst), .route(route), .abort_snk(3'd0), .abort_src(3'd0),
    .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data), .s_user(216'd0), .s_last(s_last),
    .m_valid(m_valid), .m_ready(3'b111), .m_data(m_data), .m_user(), .m_last(m_last));
  integer got = 0, k = 0;
  always @(posedge clk) if (m_valid[0] && m_data[31:16] == 16'hB2) got = got + 1;
  reg go = 0;                                    // the switch takes a route a few cycles after it changes
  always @(posedge clk) if (!rst && go) begin
    if (!s_valid[2] || s_ready[2]) begin
      s_valid[2] <= k < 300; s_data[95:64] <= {16'hB2, k[15:0]}; s_last[2] <= (k % 100) == 99; k = k + 1;
    end
  end
  initial begin
    #50 rst = 0;
    #500 route[3:0] = 4'd2;                       // source 1 never sent anything
    #250 go = 1;
    #5000;
    $display("%0d of 300 beats from source 2 at sink 0", got);
    if (got == 300) $display("PASS tb_switch_idle"); else $display("FAIL tb_switch_idle");
    $finish;
  end
endmodule
