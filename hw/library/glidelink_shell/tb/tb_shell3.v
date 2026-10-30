// Integration testbench for host port 1 (step 1.5). Both host ports run at
// once, raw: host port 0 loops through the RF (DAC looped back to ADC, default
// routes) and host port 1 loops through slot 0 (host 1 TX -> slot 0 -> host 1
// RX). Each carries its own ramp and must come back contiguous; the host 1
// TX side then stops in the middle of a transfer, PORT_RESET flushes host
// port 1 and slot 0, and the loop must come back.

`timescale 1ns/100ps

module tb_shell3;

  reg         aclk = 0, l_clk = 0, clk = 0;
  always #5    aclk = ~aclk;
  always #2.03 l_clk = ~l_clk;
  always #2.5  clk = ~clk;
  reg         aresetn = 0, rstn = 0, l_rst = 1;

  reg  [1:0]  vcnt = 0;
  reg         adc_valid = 0, dac_valid = 0;
  always @(posedge l_clk) begin
    vcnt <= vcnt + 1;
    adc_valid <= vcnt == 0;
    dac_valid <= vcnt == 1;
  end
  wire [15:0] dac_i, dac_q;
  reg  [15:0] adc_i = 0, adc_q = 0;
  // AD9361 digital loopback: the DAC's 12 MSBs come back as the 12-bit ADC sample
  // (the RX streamer shifts it back up), so test patterns use bits 15..4 only
  always @(posedge l_clk) if (dac_valid) begin
    adc_i <= {{4{dac_i[15]}}, dac_i[15:4]};
    adc_q <= {{4{dac_q[15]}}, dac_q[15:4]};
  end

  reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  reg  [15:0] awaddr = 0, araddr = 0;
  reg  [31:0] wdata = 0;
  wire        awready, wready, bvalid, arready, rvalid;
  wire [31:0] rdata;

  // host port n: TX source (ramp) and RX sink (checker)
  wire [1:0]  rx_valid, tx_ready;
  wire [63:0] rx_data;
  reg  [1:0]  rx_req = 0, tx_valid = 0, tx_last = 0;
  reg  [63:0] tx_data = 0;

  glidelink_shell dut (
    .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
    .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0),
    .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_wdata(wdata), .s_axi_wstrb(4'hf),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_bresp(),
    .s_axi_arvalid(arvalid), .s_axi_arready(arready), .s_axi_araddr(araddr), .s_axi_arprot(3'd0),
    .s_axi_rvalid(rvalid), .s_axi_rready(rready), .s_axi_rresp(), .s_axi_rdata(rdata),
    .l_clk(l_clk), .l_rst(l_rst), .adc_valid_i0(adc_valid), .adc_data_i0(adc_i), .adc_data_q0(adc_q),
    .adc_dovf(), .dac_valid_i0(dac_valid), .dac_data_i0(dac_i), .dac_data_q0(dac_q), .dac_dunf(),
    .ctrl_out(8'd0), .clk(clk), .rstn(rstn),
    .host0_rx_valid(rx_valid[0]), .host0_rx_xfer_req(rx_req[0]), .host0_rx_overflow(1'b0),
    .host0_rx_data(rx_data[31:0]), .host0_tx_valid(tx_valid[0]), .host0_tx_ready(tx_ready[0]),
    .host0_tx_data(tx_data[31:0]), .host0_tx_last(tx_last[0]),
    .host1_rx_valid(rx_valid[1]), .host1_rx_xfer_req(rx_req[1]), .host1_rx_overflow(1'b0),
    .host1_rx_data(rx_data[63:32]), .host1_tx_valid(tx_valid[1]), .host1_tx_ready(tx_ready[1]),
    .host1_tx_data(tx_data[63:32]), .host1_tx_last(tx_last[1]));

  task axi_write(input [15:0] a, input [31:0] d);
    begin
      @(posedge aclk); awaddr <= a; awvalid <= 1; wdata <= d; wvalid <= 1; bready <= 1;
      fork
        begin @(posedge aclk); while (!awready) @(posedge aclk); awvalid <= 0; end
        begin @(posedge aclk); while (!wready) @(posedge aclk); wvalid <= 0; end
      join
      while (!bvalid) @(posedge aclk);
      @(posedge aclk); bready <= 0;
    end
  endtask

  task axi_read(input [15:0] a, output [31:0] d);
    begin
      @(posedge aclk); araddr <= a; arvalid <= 1;
      @(posedge aclk); while (!arready) @(posedge aclk);
      arvalid <= 0; rready <= 1;
      @(posedge aclk); while (!rvalid) @(posedge aclk);
      d = rdata; rready <= 0;
    end
  endtask

  integer errors = 0;

  // sources: ramps tagged by port in the top bit of Q (port 1: Q = ~I ^ 16'h8000)
  integer     n_tx [0:1];
  reg  [1:0]  run = 0;
  integer     p;
  initial begin n_tx[0] = 0; n_tx[1] = 0; end
  always @(posedge clk) if (rstn) begin
    for (p = 0; p < 2; p = p + 1)
      if (!tx_valid[p] || tx_ready[p]) begin
        if (run[p] && ($random & 3) != 0) begin
          tx_valid[p] <= 1;
          tx_data[p*32 +: 32] <= {~n_tx[p][11:0] ^ (p ? 12'h800 : 12'h0), 4'd0, n_tx[p][11:0], 4'd0};
          tx_last[p] <= (n_tx[p] % 1000) == 999;
          n_tx[p] = n_tx[p] + 1;
        end else begin
          tx_valid[p] <= 0;
        end
      end
  end

  // sinks
  integer     n_rx [0:1], rx_err [0:1];
  reg  [1:0]  locked = 0, pause = 0;
  reg  [15:0] expect_i [0:1];
  reg  [31:0] w;
  initial begin n_rx[0] = 0; n_rx[1] = 0; rx_err[0] = 0; rx_err[1] = 0; end
  always @(posedge clk) begin
    rx_req <= {($random & 7) != 0, ($random & 7) != 0};
    for (p = 0; p < 2; p = p + 1)
      if (rx_valid[p] && !pause[p]) begin
        w = rx_data[p*32 +: 32];
        if (!locked[p] && w[15:4] != 0 && w == {~w[15:4] ^ (p ? 12'h800 : 12'h0), 4'd0, w[15:4], 4'd0}) begin
          locked[p] = 1;
          expect_i[p] = w[15:4];
        end
        if (locked[p]) begin
          if (w !== {~expect_i[p][11:0] ^ (p ? 12'h800 : 12'h0), 4'd0, expect_i[p][11:0], 4'd0}) begin
            if (rx_err[p] < 5) $display("ERROR: host %0d RX %h, expected I %h", p, w, expect_i[p]);
            rx_err[p] = rx_err[p] + 1;
          end
          expect_i[p] = expect_i[p] + 1;
          n_rx[p] = n_rx[p] + 1;
        end
      end
  end

  reg [31:0] v, ovf, unf;
  initial begin
    #100 aresetn = 1; rstn = 1; l_rst = 0;
    axi_read(16'h008, v);
    if (v != 32'h03020201) begin $display("ERROR: CAPS %h", v); errors = errors + 1; end
    axi_write(16'h1008, 32'd3);                    // slot 0 in  <- host 1 TX
    axi_write(16'h100C, 32'd2);                    // host 1 RX  <- slot 0 out
    run = 2'b11;
    #600000;
    axi_read(16'h040, ovf); axi_read(16'h044, unf);
    $display("phase A: host 0 %0d samples / %0d errors, host 1 %0d samples / %0d errors, overflow %0d, underflow %0d",
             n_rx[0], rx_err[0], n_rx[1], rx_err[1], ovf, unf);
    if (n_rx[0] < 30000 || n_rx[1] < 30000 || rx_err[0] || rx_err[1] || ovf || unf) errors = errors + 1;

    // host 1 TX stops mid-transfer; flush host port 1 and slot 0; restart
    run[1] = 0;
    pause[1] = 1;
    #20000;
    axi_write(16'h05C, 32'b11100);                 // host 1 TX, host 1 RX, slot 0
    #2000;
    locked[1] = 0; pause[1] = 0; n_rx[1] = 0;
    run[1] = 1;
    #300000;
    $display("phase B: host 1 after PORT_RESET %0d samples / %0d errors; host 0 %0d errors",
             n_rx[1], rx_err[1], rx_err[0]);
    if (n_rx[1] < 20000 || rx_err[1] || rx_err[0]) errors = errors + 1;

    if (errors == 0) $display("PASS tb_shell3");
    else $display("FAIL tb_shell3: %0d errors", errors);
    $finish;
  end

endmodule
