// Testbench for glidelink_tx_stream. Samples are I = {packet id, index},
// Q = ~I (never zero), so the output monitor can attribute every DAC sample.
// Scenarios:
//   A  three untimed packets back to back, the last ends the burst: contiguous output
//   B  timed packet (end of burst): starts a fixed latency after its time
//   C+D timed packet followed by an untimed one in the same burst: same latency, no gap
//   E  late timed packet with late_drop = 1: never sent, late = 1
//   F  two packets of one burst with a gap between them: underflow = 1

`timescale 1ns/100ps

module tb_tx_stream;

  reg         l_clk = 0, s_clk = 0;
  always #2.03 l_clk = ~l_clk;
  always #2.5  s_clk = ~s_clk;
  reg         l_rst = 1, s_rst = 1;

  reg  [1:0]  vcnt = 0;
  reg         dac_valid = 0;
  reg  [63:0] time_now = 0;
  always @(posedge l_clk) begin
    vcnt <= vcnt + 1;
    dac_valid <= vcnt == 2;
    if (vcnt == 0) time_now <= time_now + 1;      // the counter runs off the ADC samples
  end

  reg  [31:0] tdata = 0;
  reg  [71:0] tuser = 0;
  reg         tlast = 0, tvalid = 0;
  wire        tready;
  wire [15:0] di, dq;
  wire [31:0] unf_gray, late_gray;

  glidelink_tx_stream #(.FIFO_ADDR_WIDTH(9)) dut (
    .s_clk(s_clk), .s_rst(s_rst), .s_axis_tdata(tdata), .s_axis_tuser(tuser), .s_axis_tlast(tlast),
    .s_axis_tvalid(tvalid), .s_axis_tready(tready),
    .l_clk(l_clk), .l_rst(l_rst), .dac_valid(dac_valid), .dac_data_i(di), .dac_data_q(dq),
    .time_now(time_now), .late_drop(1'b1), .underflow_gray(unf_gray), .late_gray(late_gray), .dac_dunf());

  task send_pkt(input [7:0] id, input integer len, input timed, input eob, input [63:0] t);
    integer k;
    begin
      for (k = 0; k < len; k = k + 1) begin
        @(posedge s_clk);
        tdata <= {~{id, k[7:0]}, id, k[7:0]};
        tuser <= {5'd0, timed, eob, 1'b0, t};
        tlast <= k == len - 1;
        tvalid <= 1;
        @(posedge s_clk); while (!tready) @(posedge s_clk);
        tvalid <= 0;
      end
    end
  endtask

  // output monitor: the DAC register updates on dac_valid
  reg         dv_d = 0;
  integer     slot = 0;
  reg  [63:0] slot_time [0:4095];
  reg  [15:0] slot_i [0:4095];
  always @(posedge l_clk) begin
    dv_d <= dac_valid;
    if (dv_d && slot < 4096) begin
      slot_time[slot] = time_now;
      slot_i[slot] = di;
      if (di != 16'd0 && dq !== ~di) $display("ERROR: Q %h does not match I %h", dq, di);
      slot = slot + 1;
    end
  end

  function integer find(input [7:0] id, input [7:0] idx);
    integer s;
    begin
      find = -1;
      for (s = 0; s < slot; s = s + 1)
        if (slot_i[s] == {id, idx} && find < 0) find = s;
    end
  endfunction

  function [31:0] gray2bin(input [31:0] g);
    integer i;
    begin
      gray2bin[31] = g[31];
      for (i = 30; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i + 1] ^ g[i];
    end
  endfunction

  integer errors = 0;
  task check(input ok, input [8*64-1:0] what);
    if (!ok) begin
      $display("ERROR: %0s", what);
      errors = errors + 1;
    end
  endtask

  // the samples of a packet occupy consecutive slots starting at its first
  task check_contiguous(input [7:0] id, input integer len);
    integer s0, k;
    begin
      s0 = find(id, 0);
      check(s0 >= 0, "packet missing");
      for (k = 1; k < len; k = k + 1)
        if (slot_i[s0 + k] != {id, k[7:0]}) begin
          $display("ERROR: packet %0d sample %0d not contiguous", id, k);
          errors = errors + 1;
          k = len;
        end
    end
  endtask

  reg  [63:0] tB, tC, tE;
  integer     latB, latC;

  initial begin
    #100 l_rst = 0; s_rst = 0;
    #500;

    // A
    send_pkt(1, 50, 0, 0, 0);
    send_pkt(2, 50, 0, 0, 0);
    send_pkt(3, 50, 0, 1, 0);
    #3000;
    // B
    tB = time_now + 300;
    send_pkt(4, 20, 1, 1, tB);
    #8000;
    // C + D
    tC = time_now + 300;
    send_pkt(5, 30, 1, 0, tC);
    send_pkt(6, 30, 0, 1, 0);
    #8000;
    // E
    tE = time_now - 50;
    send_pkt(7, 20, 1, 1, tE);
    #3000;
    // F
    send_pkt(8, 40, 0, 0, 0);
    #2000;                              // the first packet runs dry before the second
    send_pkt(9, 40, 0, 1, 0);
    #3000;

    check_contiguous(1, 50); check_contiguous(2, 50); check_contiguous(3, 50);
    check(find(2, 0) == find(1, 49) + 1 && find(3, 0) == find(2, 49) + 1, "burst A has gaps");
    check_contiguous(4, 20);
    latB = slot_time[find(4, 0)] - tB;
    check_contiguous(5, 30); check_contiguous(6, 30);
    latC = slot_time[find(5, 0)] - tC;
    check(find(6, 0) == find(5, 29) + 1, "D does not follow C without a gap");
    check(latB == latC && latB >= 0 && latB < 4, "timed start latency differs or is out of range");
    check(find(7, 0) < 0, "late packet E was sent");
    check(gray2bin(late_gray) == 1, "late count is not 1");
    check_contiguous(8, 40); check_contiguous(9, 40);
    check(gray2bin(unf_gray) == 1, "underflow count is not 1");
    $display("timed start latency %0d / %0d samples, underflow %0d, late %0d",
             latB, latC, gray2bin(unf_gray), gray2bin(late_gray));

    if (errors == 0) $display("PASS tb_tx_stream");
    else $display("FAIL tb_tx_stream: %0d errors", errors);
    $finish;
  end

endmodule
