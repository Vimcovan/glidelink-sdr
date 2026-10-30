// Integration testbench for glidelink_shell steps 1.3 / 1.4. DAC looped back
// to ADC as in the AD9361 digital loopback.
//   A  default routes, raw host port: TX ramp comes back contiguous, counters 0
//   B  routes host 0 TX -> slot 0 -> RF TX: still contiguous; slot ID and its
//      beat counter read through the register window (CPU -> processing clock)
//   C  header mode both ways, RX packets of 256: two timed bursts (end of
//      burst) of 100 samples; parsing the RX headers, the first burst sample's
//      RX timestamp minus its send time is the same for both bursts

`timescale 1ns/100ps

module tb_shell2;

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
  always @(posedge l_clk) if (dac_valid) begin adc_i <= dac_i; adc_q <= dac_q; end

  // AXI-Lite master
  reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  reg  [15:0] awaddr = 0, araddr = 0;
  reg  [31:0] wdata = 0;
  wire        awready, wready, bvalid, arready, rvalid;
  wire [31:0] rdata;

  wire        rx_valid, tx_ready;
  wire [31:0] rx_data;
  reg         rx_ready = 0, tx_valid = 0, tx_last = 0;
  reg  [31:0] tx_data = 0;

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
    .host0_rx_valid(rx_valid), .host0_rx_xfer_req(rx_ready), .host0_rx_overflow(1'b0), .host0_rx_data(rx_data),
    .host0_tx_valid(tx_valid), .host0_tx_ready(tx_ready), .host0_tx_data(tx_data),
    .host0_tx_last(tx_last),
    .host1_rx_valid(), .host1_rx_xfer_req(1'b0), .host1_rx_overflow(1'b0), .host1_rx_data(),
    .host1_tx_valid(1'b0), .host1_tx_ready(), .host1_tx_data(32'd0), .host1_tx_last(1'b0));

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
  task check(input ok, input [8*64-1:0] what);
    if (!ok) begin $display("ERROR: %0s", what); errors = errors + 1; end
  endtask

  // ---------------------------------------------------------------------------
  // host TX source: raw ramp (mode 0) or prepared header-framed words (mode 1)

  integer     mode = 0, n_tx = 0;
  reg         raw_run = 0;
  reg  [31:0] frame [0:1023];
  integer     frame_len = 0, frame_pos = 0;
  always @(posedge clk) if (rstn) begin
    if (!tx_valid || tx_ready) begin
      // the raw stream may stop in the middle of a DMA transfer (a stream
      // being torn down); PORT_RESET cleans up after it
      if (mode == 0 && raw_run && ($random & 3) != 0) begin
        tx_valid <= 1;
        tx_data <= {~n_tx[15:0], n_tx[15:0]};
        tx_last <= (n_tx % 1000) == 999;
        n_tx = n_tx + 1;
      end else if (mode == 1 && frame_pos < frame_len) begin
        tx_valid <= 1;
        tx_data <= frame[frame_pos];
        tx_last <= frame_pos == frame_len - 1;
        frame_pos = frame_pos + 1;
      end else begin
        tx_valid <= 0;
      end
    end
  end

  // host RX sink: raw ramp check (mode 0) or header parser (mode 1)
  integer     n_rx = 0, rx_err = 0;
  reg         locked = 0;
  reg  [15:0] expect_i;
  integer     hs = 0, hlen = 0, hleft = 0, hk = 0;
  reg  [63:0] hts;
  reg  [63:0] burst_ts [0:1];
  integer     bursts = 0;
  reg         in_burst = 0;
  always @(posedge clk) begin
    rx_ready <= ($random & 7) != 0;
    if (rx_valid) begin
      if (mode == 0) begin
        if (!locked && rx_data[15:0] != 0 && rx_data[31:16] == ~rx_data[15:0]) begin
          locked = 1; expect_i = rx_data[15:0];
        end
        if (locked) begin
          if (rx_data !== {~expect_i, expect_i}) begin
            if (rx_err < 5) $display("ERROR: RX %h, expected I %h", rx_data, expect_i);
            rx_err = rx_err + 1;
          end
          expect_i = expect_i + 1;
          n_rx = n_rx + 1;
        end
      end else begin
        case (hs)
          0: begin
            if (rx_data[31:24] != 8'hA5) begin $display("ERROR: RX header %h", rx_data); rx_err = rx_err + 1; end
            hlen = rx_data[15:0]; hleft = hlen; hs = 1;
          end
          1: hs = 2;
          2: begin hts[31:0] = rx_data; hs = 3; end
          3: begin hts[63:32] = rx_data; hs = 4; hk = 0; end
          default: begin
            // burst samples are {16'hB000 + b, idx}; the first one of each burst marks it
            if (rx_data[31:16] == 16'hB000 + bursts && rx_data[15:0] == 0 && !in_burst && bursts < 2) begin
              burst_ts[bursts] = hts + hk;
              in_burst = 1;
            end
            if (in_burst && rx_data[31:16] != 16'hB000 + bursts) begin
              in_burst = 0; bursts = bursts + 1;
            end
            hk = hk + 1; hleft = hleft - 1;
            if (hleft == 0) hs = 0;
          end
        endcase
      end
    end
  end

  // debug probes for phase C
  integer n_hdr = 0;
  reg     seen_src = 0, seen_dac = 0;
  always @(posedge clk) begin
    if (mode == 1 && rx_valid && hs == 0) n_hdr = n_hdr + 1;
    if (mode == 1 && !seen_src && dut.src_valid[1] && dut.src_ready[1] && dut.src_data[63:48] == 16'hB000) begin
      seen_src = 1; $display("probe: burst 0 left the host TX adapter, user %h", dut.src_user[143:72]);
    end
  end
  always @(posedge l_clk) if (mode == 1 && !seen_dac && dac_q == 16'hB000) begin
    seen_dac = 1; $display("probe: burst 0 at the DAC, counter %0d", dut.i_regs.count);
  end

  task make_burst(input integer b, input [63:0] t);
    integer k;
    begin
      frame[0] = {8'hA5, 8'h06, 16'd100};          // timed, end of burst, 100 samples
      frame[1] = b;
      frame[2] = t[31:0];
      frame[3] = t[63:32];
      for (k = 0; k < 100; k = k + 1) frame[4 + k] = {16'hB000 + b, k[15:0]};
      frame_len = 104;
      frame_pos = 0;
    end
  endtask

  reg  [31:0] v, ovf, unf, late, herr, beats1, beats2;
  reg  [63:0] t0, t1;
  integer     lat0, lat1;

  initial begin
    #100 aresetn = 1; rstn = 1; l_rst = 0;

    // A
    raw_run = 1;
    #400000;
    check(rx_err == 0 && n_rx > 18000, "phase A: loop not contiguous");
    axi_read(16'h040, ovf); axi_read(16'h044, unf);
    check(ovf == 0 && unf == 0, "phase A: overflow / underflow");
    $display("phase A: %0d samples, %0d errors", n_rx, rx_err);

    // B
    axi_read(16'h2000, v);
    check(v == 32'h50535448, "slot 0 ID");
    axi_read(16'h2014, beats1);
    axi_write(16'h1000, 32'd2);                     // RF TX <- slot 0 out
    axi_write(16'h1008, 32'd1);                     // slot 0 in <- host 0 TX
    axi_read(16'h1000, v);
    check(v == 2, "route readback");
    #50000;
    locked = 0;                                     // the route change may skip samples once
    n_rx = 0;
    #300000;
    axi_read(16'h2014, beats2);
    check(rx_err == 0 && n_rx > 15000, "phase B: loop through slot 0 not contiguous");
    check(beats2 > beats1 + 15000, "phase B: slot 0 beat counter");
    $display("phase B: %0d samples, slot 0 beats %0d -> %0d", n_rx, beats1, beats2);

    // C: stop the raw stream, let everything drain, switch to header mode
    // (header mode is changed only while the port is idle: host 0 RX is
    // unrouted meanwhile, and the switch reconnects it at a packet start)
    raw_run = 0;
    #100000;
    axi_write(16'h1004, 32'hF);                     // host 0 RX <- none
    axi_write(16'h05C, 32'd7);                      // flush host port 0 RX and TX, reset slot 0
    #20000;
    axi_write(16'h050, 32'd256);
    axi_write(16'h054, 32'b1111);
    mode = 1;
    axi_write(16'h1004, 32'd0);                     // host 0 RX <- RF RX
    t0 = dut.i_regs.count + 3000;
    make_burst(0, t0);
    #150000;
    t1 = dut.i_regs.count + 3000;
    make_burst(1, t1);
    #150000;
    $display("probe: t0 %0d, t1 %0d, RX headers parsed %0d, bursts found %0d", t0, t1, n_hdr, bursts);
    check(bursts == 2, "phase C: bursts not found in RX");
    lat0 = burst_ts[0] - t0;
    lat1 = burst_ts[1] - t1;
    check(lat0 == lat1 && lat0 > 0 && lat0 < 10, "phase C: burst latency differs or out of range");
    axi_read(16'h048, late); axi_read(16'h04C, herr); axi_read(16'h044, unf);
    check(late == 0 && herr == 0, "phase C: late / header errors");
    $display("phase C: burst RX-TX offset %0d / %0d samples, late %0d, header errors %0d, underflow %0d",
             lat0, lat1, late, herr, unf);

    if (errors == 0 && rx_err == 0) $display("PASS tb_shell2");
    else $display("FAIL tb_shell2: %0d errors, %0d RX errors", errors, rx_err);
    $finish;
  end

endmodule
