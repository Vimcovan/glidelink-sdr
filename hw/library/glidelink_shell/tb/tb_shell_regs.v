// Testbench for glidelink_shell_regs: fixed registers, scratch, sample counter
// (counts only valid samples), consistent 64-bit snapshot, counter load, status.

`timescale 1ns/100ps

module tb_shell_regs;

  reg         aclk = 0, aresetn = 0;
  reg         l_clk = 0;
  always #5    aclk = ~aclk;      // 100 MHz CPU clock
  always #2.03 l_clk = ~l_clk;    // ~246 MHz data clock

  // valid on 1 of every 4 l_clk cycles (61.44 MSPS at 245.76 MHz, 1R1T)
  reg  [1:0]  vcnt = 0;
  reg         adc_valid = 0;
  always @(posedge l_clk) begin
    vcnt <= vcnt + 1;
    adc_valid <= vcnt == 0;
  end

  reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  reg  [15:0] awaddr = 0, araddr = 0;
  reg  [31:0] wdata = 0;
  wire        awready, wready, bvalid, arready, rvalid;
  wire [31:0] rdata;
  wire [1:0]  bresp, rresp;
  wire [63:0] time_now;

  glidelink_shell_regs #(.HOST_RX(8'd2), .HOST_TX(8'd2), .SLOTS(8'd1)) dut (
    .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
    .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0),
    .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_wdata(wdata), .s_axi_wstrb(4'hf),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_bresp(bresp),
    .s_axi_arvalid(arvalid), .s_axi_arready(arready), .s_axi_araddr(araddr), .s_axi_arprot(3'd0),
    .s_axi_rvalid(rvalid), .s_axi_rready(rready), .s_axi_rresp(rresp), .s_axi_rdata(rdata),
    .l_clk(l_clk), .adc_valid(adc_valid), .time_now(time_now),
    .ctrl_out(8'h5A), .rx_overflow_gray(32'd14), .tx_underflow_gray(32'd29), .tx_late_gray(32'd49),
    .rx_pkt_len(), .rx_enable(), .tx_late_drop());   // Gray codes of 11, 22, 33

  integer errors = 0;

  task axi_write(input [15:0] a, input [31:0] d);
    begin
      @(posedge aclk);
      awaddr <= a; awvalid <= 1; wdata <= d; wvalid <= 1;
      fork
        begin @(posedge aclk); while (!awready) @(posedge aclk); awvalid <= 0; end
        begin @(posedge aclk); while (!wready) @(posedge aclk); wvalid <= 0; end
      join
      repeat (2) @(posedge aclk);          // response held back for a while
      bready <= 1;
      @(posedge aclk); while (!bvalid) @(posedge aclk);
      bready <= 0;
    end
  endtask

  task axi_read(input [15:0] a, output [31:0] d);
    begin
      @(posedge aclk);
      araddr <= a; arvalid <= 1;
      @(posedge aclk); while (!arready) @(posedge aclk);
      arvalid <= 0;
      repeat (3) @(posedge aclk);          // read data held back for a while
      rready <= 1;
      @(posedge aclk); while (!rvalid) @(posedge aclk);
      d = rdata;
      rready <= 0;
    end
  endtask

  task expect(input [15:0] a, input [31:0] v);
    reg [31:0] d;
    begin
      axi_read(a, d);
      if (d !== v) begin
        $display("ERROR: reg 0x%03h = 0x%08h, expected 0x%08h", a, d, v);
        errors = errors + 1;
      end
    end
  endtask

  reg [31:0] lo, hi, lo2, hi2;
  reg [63:0] t1, t2;
  real       dt_ns;
  integer    i;

  initial begin
    repeat (10) @(posedge aclk);
    aresetn = 1;
    repeat (10) @(posedge aclk);

    expect(16'h000, 32'h474C4B53);
    expect(16'h004, 32'h00010300);
    expect(16'h008, 32'h01020201);
    axi_write(16'h00C, 32'hDEADBEEF);
    expect(16'h00C, 32'hDEADBEEF);
    expect(16'h030, 32'h0000005A);
    expect(16'h040, 32'd11);
    expect(16'h044, 32'd22);
    expect(16'h048, 32'd33);
    expect(16'h0FC, 32'd0);

    // counter rate: 10 us plus two register reads between the snapshots is
    // ~10.2 us, ~628 samples at one per 16.24 ns
    axi_read(16'h010, lo); axi_read(16'h014, hi); t1 = {hi, lo};
    #10000;
    axi_read(16'h010, lo); axi_read(16'h014, hi); t2 = {hi, lo};
    if (t2 - t1 < 610 || t2 - t1 > 650) begin
      $display("ERROR: counter advanced %0d samples in 10 us", t2 - t1);
      errors = errors + 1;
    end

    // load near a 32-bit carry, then check the halves stay consistent across it
    axi_write(16'h018, 32'hFFFFFF00);
    axi_write(16'h01C, 32'h00000007);
    axi_write(16'h020, 32'd1);
    for (i = 0; i < 50; i = i + 1) begin
      axi_read(16'h020, lo);
      if (lo == 0) i = 100;
    end
    if (i < 100) begin
      $display("ERROR: counter load still pending");
      errors = errors + 1;
    end
    for (i = 0; i < 80; i = i + 1) begin
      axi_read(16'h010, lo); axi_read(16'h014, hi);
      t2 = {hi, lo};
      if (t2 < 64'h7FFFFFF00 || t2 > 64'h800001000) begin
        $display("ERROR: snapshot 0x%016h out of range after load", t2);
        errors = errors + 1;
      end
      if (i > 0 && t2 < t1) begin
        $display("ERROR: snapshot went backwards: 0x%016h -> 0x%016h", t1, t2);
        errors = errors + 1;
      end
      t1 = t2;
    end
    if (t1 < 64'h800000000) begin
      $display("ERROR: did not cross the 32-bit carry (0x%016h)", t1);
      errors = errors + 1;
    end

    // upset the l_clk side of both handshakes (as an l_clk glitch can) and
    // check that the snapshot keeps updating and a load still goes through
    @(posedge l_clk);
    force dut.snap_ack = ~dut.snap_ack;
    force dut.load_ack = ~dut.load_ack;
    repeat (3) @(posedge l_clk);
    release dut.snap_ack;
    release dut.load_ack;
    #2000;
    axi_read(16'h010, lo); axi_read(16'h014, hi); t1 = {hi, lo};
    #2000;
    axi_read(16'h010, lo); axi_read(16'h014, hi); t2 = {hi, lo};
    if (t2 <= t1) begin
      $display("ERROR: snapshot stuck after upset: 0x%016h -> 0x%016h", t1, t2);
      errors = errors + 1;
    end
    axi_write(16'h018, 32'h00000100);
    axi_write(16'h01C, 32'h00000000);
    axi_write(16'h020, 32'd1);
    #1000;
    expect(16'h020, 32'd0);
    #1000;
    axi_read(16'h010, lo); axi_read(16'h014, hi); t2 = {hi, lo};
    if (t2 < 64'h100 || t2 > 64'h200) begin
      $display("ERROR: load after upset gave 0x%016h", t2);
      errors = errors + 1;
    end

    if (errors == 0) $display("PASS tb_shell_regs");
    else $display("FAIL tb_shell_regs: %0d errors", errors);
    $finish;
  end

endmodule
