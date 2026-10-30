// Asynchronous FIFO recovery from an upset pointer: mid-run the writer's binary
// pointer jumps by 40 (a clock glitch, as the AD9361 data clock has while the
// driver re-initialises the chip). The FIFO may pass some stale words once, but
// must not stay stuck full: writes and reads have to carry on.
`timescale 1ns/100ps
module tb_async_heal;
  reg wclk = 0, rclk = 0;
  always #12.5 wclk = ~wclk;       // 40 MHz
  always #2.5  rclk = ~rclk;       // 200 MHz
  reg rst = 1;
  wire full, empty;
  reg  [15:0] n = 0;
  integer writes = 0, reads = 0, w_after = 0, r_after = 0;
  reg upset = 0;
  glidelink_async_fifo #(.WIDTH(16), .ADDR_WIDTH(5), .RAM_STYLE("distributed")) dut (
    .wr_clk(wclk), .wr_rst(rst), .wr_en(1'b1), .wr_data(n), .wr_full(full), .wr_level(), .wr_in_reset(),
    .rd_clk(rclk), .rd_rst(rst), .rd_en(!empty), .rd_data(), .rd_empty(empty), .rd_level(), .rd_in_reset());
  always @(posedge wclk) if (!rst && !full) begin n <= n + 1; writes = writes + 1; if (upset) w_after = w_after + 1; end
  always @(posedge rclk) if (!empty) begin reads = reads + 1; if (upset) r_after = r_after + 1; end
  initial begin
    #500 rst = 0;
    #20000;
    @(posedge wclk); #1 force dut.wr_ptr = dut.wr_ptr + 40;
    @(posedge wclk); #1 release dut.wr_ptr;
    upset = 1;
    #50000;
    $display("before the upset: %0d writes; after: %0d writes, %0d reads", writes - w_after, w_after, r_after);
    if (w_after > 1500 && r_after > 1500) $display("PASS tb_async_heal"); else $display("FAIL tb_async_heal: stuck");
    $finish;
  end
endmodule
