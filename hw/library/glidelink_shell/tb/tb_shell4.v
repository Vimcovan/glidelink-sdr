// Integration testbench for the module slots (docs/phase3_modules.md): host
// port 1 TX -> slot 1 (NCO) -> slot 2 (FIR) -> host port 1 RX, raw, set up
// through the shell's register window (vectors_chain/regs.hex, from
// hw/modules/chain_vectors.py) and compared word for word with the reference
// models (vectors_chain/out.hex). Then the sender stops in the middle of a
// transfer, PORT_RESET flushes host port 1 and both slots (their registers
// are kept), and the same input must give the same output again from the start.
// Run with -Image demo (slots on the processing clock) and -Image test_clocks
// (NCO at 250 MHz, FIR at 100 MHz: clock-crossing slots).

`timescale 1ns/100ps

module tb_shell4;

  localparam N = 8000;

  reg         aclk = 0, l_clk = 0, clk = 0, clk250 = 0;
  always #5    aclk = ~aclk;
  always #2    clk250 = ~clk250;
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

  reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  reg  [15:0] awaddr = 0, araddr = 0;
  reg  [31:0] wdata = 0;
  wire        awready, wready, bvalid, arready, rvalid;
  wire [31:0] rdata;

  wire        rx_valid, tx_ready;
  wire [31:0] rx_data;
  reg         rx_req = 0, tx_valid = 0, tx_last = 0;
  reg  [31:0] tx_data = 0;

  glidelink_shell dut (
    .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
    .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0),
    .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_wdata(wdata), .s_axi_wstrb(4'hf),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_bresp(),
    .s_axi_arvalid(arvalid), .s_axi_arready(arready), .s_axi_araddr(araddr), .s_axi_arprot(3'd0),
    .s_axi_rvalid(rvalid), .s_axi_rready(rready), .s_axi_rresp(), .s_axi_rdata(rdata),
    .l_clk(l_clk), .l_rst(l_rst), .adc_valid_i0(adc_valid), .adc_data_i0(16'd0), .adc_data_q0(16'd0),
    .adc_dovf(), .dac_valid_i0(dac_valid), .dac_data_i0(), .dac_data_q0(), .dac_dunf(),
    .ctrl_out(8'd0), .clk(clk), .rstn(rstn), .clk_250(clk250),
    .host0_rx_valid(), .host0_rx_xfer_req(1'b1), .host0_rx_overflow(1'b0), .host0_rx_data(),
    .host0_tx_valid(1'b0), .host0_tx_ready(), .host0_tx_data(32'd0), .host0_tx_last(1'b0),
    .host1_rx_valid(rx_valid), .host1_rx_xfer_req(rx_req), .host1_rx_overflow(1'b0),
    .host1_rx_data(rx_data), .host1_tx_valid(tx_valid), .host1_tx_ready(tx_ready),
    .host1_tx_data(tx_data), .host1_tx_last(tx_last));

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

  reg  [31:0] in_w [0:N-1], out_w [0:N-1];
  integer     errors = 0, n_tx = 0, n_rx = 0, rx_err = 0, stop_at = N, fd, r, a, d;
  reg         run = 0, pause = 0;

  // sender: random gaps, a DMA transfer (tlast) every 500 words
  always @(posedge clk) if (rstn) begin
    if (!tx_valid || tx_ready) begin
      if (run && n_tx < stop_at && ($random & 3) != 0) begin
        tx_valid <= 1;
        tx_data <= in_w[n_tx];
        tx_last <= (n_tx % 500) == 499;
        n_tx = n_tx + 1;
      end else begin
        tx_valid <= 0;
      end
    end
  end

  // receiver: random DMA availability, compare in order
  always @(posedge clk) begin
    rx_req <= ($random & 7) != 0;
    if (rx_valid && !pause) begin
      if (n_rx < N && rx_data !== out_w[n_rx]) begin
        if (rx_err < 5) $display("ERROR: word %0d: %h, expected %h", n_rx, rx_data, out_w[n_rx]);
        rx_err = rx_err + 1;
      end
      n_rx = n_rx + 1;
    end
  end

  reg [31:0] v;
  initial begin
    $readmemh("../../vectors_chain/in.hex", in_w);
    $readmemh("../../vectors_chain/out.hex", out_w);
    #100 aresetn = 1; rstn = 1; l_rst = 0;
    axi_read(16'h3000, v);
    if (v != 32'h4E434F31) begin $display("ERROR: slot 1 ID %h", v); errors = errors + 1; end
    axi_read(16'h4000, v);
    if (v != 32'h46495231) begin $display("ERROR: slot 2 ID %h", v); errors = errors + 1; end
    fd = $fopen("../../vectors_chain/regs.hex", "r");
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %h\n", a, d);
      if (r == 2) axi_write(a, d);
    end
    $fclose(fd);

    run = 1;
    wait (n_rx >= N);
    #1000;
    $display("phase A: %0d words through NCO and FIR, %0d errors", n_rx, rx_err);
    if (n_rx != N || rx_err) errors = errors + 1;

    // stop in the middle of a transfer (the slots carry on from phase A, so this
    // part is not compared), flush host port 1 and the slots, start over
    pause = 1;
    run = 0; n_tx = 0; stop_at = 1234;
    run = 1;
    wait (n_tx >= stop_at);
    run = 0;
    #20000;
    axi_write(16'h05C, 32'b1111000);               // slot 2, slot 1, host 1 TX, host 1 RX
    #2000;
    tx_valid = 0;
    n_tx = 0; n_rx = 0; rx_err = 0; stop_at = N; pause = 0;
    axi_read(16'h3010, v);
    if (v != 32'h0CCCCCCD) begin $display("ERROR: NCO FREQ lost after the flush: %h", v); errors = errors + 1; end
    run = 1;
    wait (n_rx >= N - 500);                        // the last transfer may wait for more input
    #20000;
    $display("phase B: after PORT_RESET %0d words, %0d errors", n_rx, rx_err);
    if (n_rx < N - 500 || rx_err) errors = errors + 1;

    if (errors == 0) $display("PASS tb_shell4");
    else $display("FAIL tb_shell4: %0d errors", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("FAIL tb_shell4: timeout (%0d words out)", n_rx);
    $finish;
  end

endmodule
