// Integration testbench for glidelink_shell (step 1.2): the DAC output is
// looped back to the ADC input as in the AD9361 digital loopback. Host port
// 0 TX sends a ramp (I = counter, Q = ~counter) in DMA-sized transfers; host
// port 0 RX must receive it contiguous once the loop is filled, and the
// overflow / underflow counters must stay 0.

`timescale 1ns/100ps

module tb_shell;

  reg         aclk = 0, l_clk = 0, clk = 0;
  always #5    aclk = ~aclk;
  always #2.03 l_clk = ~l_clk;
  always #2.5  clk = ~clk;
  reg         aresetn = 0, rstn = 0, l_rst = 1;

  // one sample per 4 l_clk in both directions, DAC one cycle after ADC
  reg  [1:0]  vcnt = 0;
  reg         adc_valid = 0, dac_valid = 0;
  always @(posedge l_clk) begin
    vcnt <= vcnt + 1;
    adc_valid <= vcnt == 0;
    dac_valid <= vcnt == 1;
  end

  wire [15:0] dac_i, dac_q;
  reg  [15:0] adc_i = 0, adc_q = 0;
  always @(posedge l_clk) if (dac_valid) begin adc_i <= dac_i; adc_q <= dac_q; end

  // AXI-Lite master (reads only)
  reg         arvalid = 0, rready = 0;
  reg  [15:0] araddr = 0;
  wire        arready, rvalid;
  wire [31:0] rdata;

  wire        rx_valid, tx_ready;
  wire [31:0] rx_data;
  reg         rx_ready = 0, tx_valid = 0, tx_last = 0;
  reg  [31:0] tx_data = 0;

  glidelink_shell dut (
    .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
    .s_axi_awvalid(1'b0), .s_axi_awready(), .s_axi_awaddr(16'd0), .s_axi_awprot(3'd0),
    .s_axi_wvalid(1'b0), .s_axi_wready(), .s_axi_wdata(32'd0), .s_axi_wstrb(4'd0),
    .s_axi_bvalid(), .s_axi_bready(1'b1), .s_axi_bresp(),
    .s_axi_arvalid(arvalid), .s_axi_arready(arready), .s_axi_araddr(araddr), .s_axi_arprot(3'd0),
    .s_axi_rvalid(rvalid), .s_axi_rready(rready), .s_axi_rresp(), .s_axi_rdata(rdata),
    .l_clk(l_clk), .l_rst(l_rst), .adc_valid_i0(adc_valid), .adc_data_i0(adc_i), .adc_data_q0(adc_q),
    .adc_dovf(), .dac_valid_i0(dac_valid), .dac_data_i0(dac_i), .dac_data_q0(dac_q), .dac_dunf(),
    .ctrl_out(8'd0), .clk(clk), .rstn(rstn),
    .host0_rx_valid(rx_valid), .host0_rx_xfer_req(rx_ready), .host0_rx_overflow(1'b0), .host0_rx_data(rx_data),
    .host0_tx_valid(tx_valid), .host0_tx_ready(tx_ready), .host0_tx_data(tx_data),
    .host0_tx_last(tx_last));

  task axi_read(input [15:0] a, output [31:0] d);
    begin
      @(posedge aclk); araddr <= a; arvalid <= 1;
      @(posedge aclk); while (!arready) @(posedge aclk);
      arvalid <= 0; rready <= 1;
      @(posedge aclk); while (!rvalid) @(posedge aclk);
      d = rdata; rready <= 0;
    end
  endtask

  // host TX: DMA-like transfers of 1000 samples, the source stalls now and then
  integer     n_tx = 0;
  always @(posedge clk) begin
    if (rstn) begin
      if (!tx_valid || tx_ready) begin
        if (($random & 3) != 0) begin
          tx_valid <= 1;
          tx_data <= {~n_tx[15:0], n_tx[15:0]};
          tx_last <= (n_tx % 1000) == 999;
          n_tx = n_tx + 1;
        end else begin
          tx_valid <= 0;
        end
      end
    end
  end

  // host RX: mostly ready; check the ramp once it has started
  integer     n_rx = 0, errors = 0;
  reg         locked = 0, pause = 0;
  reg  [15:0] expect_i;
  always @(posedge clk) begin
    rx_ready <= ($random & 7) != 0;
    if (rx_valid && !pause) begin
      if (!locked && rx_data[15:0] != 0 && rx_data[31:16] == ~rx_data[15:0]) begin
        locked = 1;
        expect_i = rx_data[15:0];
      end
      if (locked) begin
        if (rx_data !== {~expect_i, expect_i}) begin
          if (errors < 5) $display("ERROR: RX %h, expected I %h", rx_data, expect_i);
          errors = errors + 1;
        end
        expect_i = expect_i + 1;
        n_rx = n_rx + 1;
      end
    end
  end

  reg [31:0] ovf, unf;
  initial begin
    #100 aresetn = 1; rstn = 1; l_rst = 0;
    #1000000;                          // 1 ms, ~61 k samples
    axi_read(16'h040, ovf);
    axi_read(16'h044, unf);
    if (ovf != 0 || unf != 0) begin
      $display("ERROR: overflow %0d, underflow %0d", ovf, unf);
      errors = errors + 1;
    end
    if (n_rx < 50000) begin
      $display("ERROR: only %0d samples checked", n_rx);
      errors = errors + 1;
    end
    $display("%0d samples through the loop, overflow %0d, underflow %0d (packets)", n_rx, ovf, unf);

    // reset only the AD9361 side for a few cycles mid-stream (the driver
    // resets the axi_ad9361 core this way); the loop must come back by itself
    pause = 1;
    @(posedge l_clk); l_rst = 1;
    repeat (3) @(posedge l_clk);
    l_rst = 0;
    #200000;                           // let the loop settle again
    locked = 0;
    n_rx = 0;
    pause = 0;
    axi_read(16'h040, ovf);
    #500000;
    axi_read(16'h040, unf);
    if (n_rx < 25000 || unf != ovf) begin
      $display("ERROR: after an AD9361-side reset: %0d samples checked, overflow %0d -> %0d", n_rx, ovf, unf);
      errors = errors + 1;
    end
    $display("after AD9361-side reset: %0d samples contiguous, overflow steady at %0d", n_rx, unf);
    if (errors == 0) $display("PASS tb_shell");
    else $display("FAIL tb_shell: %0d errors", errors);
    $finish;
  end

endmodule
