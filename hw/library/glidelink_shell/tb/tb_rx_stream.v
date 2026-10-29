// Testbench for glidelink_rx_stream: samples I = sample index, Q = ~I. The
// sink applies random back-pressure with long stalls so that packets get
// dropped. Checks: packet length, contiguous samples inside a packet,
// timestamp = index of the first sample, gaps are whole packets, the dropped
// flag marks exactly the packets after a gap, overflow = packets dropped.

`timescale 1ns/100ps

module tb_rx_stream;

  localparam PKT = 100;

  reg         l_clk = 0, m_clk = 0;
  always #2.03 l_clk = ~l_clk;     // ~246 MHz
  always #2.5  m_clk = ~m_clk;     // 200 MHz
  reg         l_rst = 1, m_rst = 1;

  reg  [1:0]  vcnt = 0;
  reg         adc_valid = 0;
  reg  [63:0] time_now = 0;
  always @(posedge l_clk) begin
    vcnt <= vcnt + 1;
    adc_valid <= vcnt == 0;          // one sample per 4 l_clk
    if (adc_valid) time_now <= time_now + 1;
  end
  wire [15:0] adc_i = time_now[15:0];
  wire [15:0] adc_q = ~time_now[15:0];

  wire [31:0] tdata;
  wire [71:0] tuser;
  wire        tlast, tvalid;
  reg         tready = 0;
  wire [31:0] ovf_gray;

  glidelink_rx_stream #(.FIFO_ADDR_WIDTH(9)) dut (
    .l_clk(l_clk), .l_rst(l_rst), .adc_valid(adc_valid), .adc_data_i(adc_i), .adc_data_q(adc_q),
    .time_now(time_now), .pkt_len(PKT[15:0]), .enable(1'b1), .overflow_gray(ovf_gray), .adc_dovf(),
    .m_clk(m_clk), .m_rst(m_rst), .m_axis_tdata(tdata), .m_axis_tuser(tuser), .m_axis_tlast(tlast),
    .m_axis_tvalid(tvalid), .m_axis_tready(tready));

  // back-pressure: mostly ready, now and then stalled for up to ~40 us
  integer stall = 0;
  always @(posedge m_clk) begin
    if (stall > 0) begin
      stall <= stall - 1;
      tready <= 0;
    end else begin
      tready <= ($random & 7) != 0;
      if (($random & 16'hFFFF) < 4) stall <= ($random & 8191);
    end
  end

  integer errors = 0, packets = 0, dropped_pkts = 0, n_in_pkt = 0;
  reg  [15:0] expect_i = 0;
  reg  [63:0] prev_end = 64'hFFFFFFFFFFFFFFFF;     // index of the last sample of the previous packet
  reg  [63:0] first_idx;

  always @(posedge m_clk) begin
    if (tvalid && tready) begin
      if (n_in_pkt == 0) begin
        first_idx = tuser[63:0];
        if (tdata[15:0] !== first_idx[15:0]) begin
          $display("ERROR: first sample %0d, timestamp %0d", tdata[15:0], first_idx);
          errors = errors + 1;
        end
        if (packets > 0) begin
          if ((first_idx - prev_end - 1) % PKT != 0) begin
            $display("ERROR: gap of %0d samples is not whole packets", first_idx - prev_end - 1);
            errors = errors + 1;
          end
          if (tuser[64] !== (first_idx != prev_end + 1)) begin
            $display("ERROR: dropped flag %b after a gap of %0d", tuser[64], first_idx - prev_end - 1);
            errors = errors + 1;
          end
          dropped_pkts = dropped_pkts + (first_idx - prev_end - 1) / PKT;
        end
        expect_i = tdata[15:0];
      end
      if (tdata[15:0] !== expect_i || tdata[31:16] !== ~expect_i) begin
        $display("ERROR: sample %0d of packet %0d is %h, expected I %h", n_in_pkt, packets, tdata, expect_i);
        errors = errors + 1;
      end
      expect_i = expect_i + 1;
      n_in_pkt = n_in_pkt + 1;
      if (tlast) begin
        if (n_in_pkt != PKT) begin
          $display("ERROR: packet %0d has %0d samples", packets, n_in_pkt);
          errors = errors + 1;
        end
        prev_end = first_idx + PKT - 1;
        packets = packets + 1;
        n_in_pkt = 0;
      end
    end
  end

  function [31:0] gray2bin(input [31:0] g);
    integer i;
    begin
      gray2bin[31] = g[31];
      for (i = 30; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i + 1] ^ g[i];
    end
  endfunction

  initial begin
    #100 l_rst = 0; m_rst = 0;
    #2000000;                         // 2 ms, ~123 k samples
    // let the FIFO drain, then compare the overflow count with the gaps seen
    force tready = 1;
    #50000;
    if (gray2bin(ovf_gray) < dropped_pkts || gray2bin(ovf_gray) > dropped_pkts + 1) begin
      $display("ERROR: overflow counter %0d, packets missing from the output %0d", gray2bin(ovf_gray), dropped_pkts);
      errors = errors + 1;
    end
    if (packets < 500 || dropped_pkts == 0) begin
      $display("ERROR: test did not exercise enough: %0d packets, %0d dropped", packets, dropped_pkts);
      errors = errors + 1;
    end
    $display("%0d packets out, %0d dropped", packets, dropped_pkts);
    if (errors == 0) $display("PASS tb_rx_stream");
    else $display("FAIL tb_rx_stream: %0d errors", errors);
    $finish;
  end

endmodule
