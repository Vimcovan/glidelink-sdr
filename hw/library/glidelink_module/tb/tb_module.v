// Generic testbench for GlideLink user modules (docs/phase3_modules.md):
// bit-exact comparison against vectors from the module's reference model.
//
//   tb_cfg.vh (written by run_module_sim.ps1) defines DUT (the module) and VEC (vector dir)
//   <dir>/regs.hex  register writes, "addr data" per line, done before streaming
//   <dir>/in.hex    input beats, "word last" per line
//   <dir>/out.hex   expected output beats, same format
//   <dir>/reads.hex optional: "addr value" per line, registers read back and compared after
//                   the output (both modes)
// The input is sent with random gaps, the output taken with random back-pressure.
// Each input packet carries tuser = {8'hC3 ^ p[7:0], 64'(p)} on its first beat
// (p = packet number); the output must keep it on the first beat of the same packet,
// (IN_FLAGS, if defined, replaces the flags 8'hC3 ^ p, e.g. 0 for modules that act on
// flag bit 1 = end of burst), unless NO_TUSER_CHECK is defined (modules whose output packets do not map one to
// one onto input packets, e.g. jscc_enc: an image in, a symbol frame out).
// Capture mode (CAPTURE defined, for modules checked by a script instead of a
// vector file, e.g. ofdm_tx): every output beat goes to <dir>/captured.hex as
// "word last flags" (flags = tuser[71:64] of the packet's first beat), and the
// run ends when the output has been quiet for CAPTURE_QUIET cycles after the input,
// or after CAPTURE_PACKETS packets if that is defined (modules with their own source).

`timescale 1ns/100ps
`include "tb_cfg.vh"

module tb_module;

  localparam MAXN = 1 << 17;
`ifndef CAPTURE_QUIET
  `define CAPTURE_QUIET 200000
`endif

  reg         clk = 1'b0, rstn = 1'b0;
  always #2.5 clk = !clk;                   // 200 MHz

  reg         awvalid = 1'b0, wvalid = 1'b0, bready = 1'b1, arvalid = 1'b0, rready = 1'b1;
  reg  [11:0] awaddr = 12'd0, araddr = 12'd0;
  reg  [31:0] wdata = 32'd0;
  wire        awready, wready, bvalid, arready, rvalid;
  wire [31:0] rdata;

  reg         s_valid = 1'b0, s_last = 1'b0, m_ready = 1'b0;
  reg  [31:0] s_data = 32'd0;
  reg  [71:0] s_user = 72'd0;
  wire        s_ready, m_valid, m_last;
  wire [31:0] m_data;
  wire [71:0] m_user;

  `DUT dut (
    .clk(clk), .rstn(rstn), .flush(1'b0),
    .s_axil_awvalid(awvalid), .s_axil_awready(awready), .s_axil_awaddr(awaddr),
    .s_axil_wvalid(wvalid), .s_axil_wready(wready), .s_axil_wdata(wdata),
    .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_arvalid(arvalid), .s_axil_arready(arready), .s_axil_araddr(araddr),
    .s_axil_rvalid(rvalid), .s_axil_rready(rready), .s_axil_rdata(rdata),
    .s_axis_tvalid(s_valid), .s_axis_tready(s_ready), .s_axis_tdata(s_data),
    .s_axis_tuser(s_user), .s_axis_tlast(s_last),
    .m_axis_tvalid(m_valid), .m_axis_tready(m_ready), .m_axis_tdata(m_data),
    .m_axis_tuser(m_user), .m_axis_tlast(m_last));

  task axil_write(input [11:0] a, input [31:0] d);
    begin
      @(posedge clk);
      awaddr <= a; wdata <= d; awvalid <= 1'b1; wvalid <= 1'b1;
      fork
        begin @(posedge clk); while (!awready) @(posedge clk); awvalid <= 1'b0; end
        begin @(posedge clk); while (!wready) @(posedge clk); wvalid <= 1'b0; end
      join
      @(posedge clk); while (!bvalid) @(posedge clk);
    end
  endtask

  task axil_read(input [11:0] a, output [31:0] d);
    begin
      @(posedge clk);
      araddr <= a; arvalid <= 1'b1;
      @(posedge clk); while (!arready) @(posedge clk); arvalid <= 1'b0;
      while (!rvalid) @(posedge clk);
      d = rdata;
    end
  endtask

  reg  [31:0] in_w [0:MAXN-1], out_w [0:MAXN-1];
  reg         in_l [0:MAXN-1], out_l [0:MAXN-1];
  integer     n_in = 0, n_out = 0, fd, r, a, d, l;
  integer     errors = 0, got = 0, sent = 0, pkt_in = 0, pkt_out = 0;
  reg         first_in = 1'b1, first_out = 1'b1;
  reg  [31:0] id;

  initial begin
    fd = $fopen({`VEC, "/in.hex"}, "r");
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %d\n", d, l);
      if (r == 2) begin in_w[n_in] = d; in_l[n_in] = l; n_in = n_in + 1; end
    end
    $fclose(fd);
`ifndef CAPTURE
    fd = $fopen({`VEC, "/out.hex"}, "r");
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %d\n", d, l);
      if (r == 2) begin out_w[n_out] = d; out_l[n_out] = l; n_out = n_out + 1; end
    end
    $fclose(fd);
`endif

    repeat (10) @(posedge clk);
    rstn <= 1'b1;
    repeat (5) @(posedge clk);
    axil_read(12'h000, id);
    $display("module ID %h, %0d beats in, %0d expected", id, n_in, n_out);
    fd = $fopen({`VEC, "/regs.hex"}, "r");
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %h\n", a, d);
      if (r == 2) axil_write(a, d);
    end
    $fclose(fd);

    // input: random gaps
    while (sent < n_in) begin
      @(posedge clk);
      if (s_valid && s_ready) begin
        sent = sent + 1;
        if (s_last) pkt_in = pkt_in + 1;
      end
      if (sent < n_in && (!s_valid || s_ready)) begin
        if ($random % 4 != 0) begin
          s_valid <= 1'b1;
          s_data <= in_w[sent];
          s_last <= in_l[sent];
`ifdef IN_FLAGS
          s_user <= (sent == 0 || in_l[sent - 1]) ? {`IN_FLAGS, 32'd0, pkt_in} : 72'd0;
`else
          s_user <= (sent == 0 || in_l[sent - 1]) ? {8'hC3 ^ pkt_in[7:0], 32'd0, pkt_in} : 72'd0;
`endif
        end else begin
          s_valid <= 1'b0;
        end
      end else if (sent >= n_in) begin
        s_valid <= 1'b0;
      end
    end
  end

  // registers read back after the output and compared (reads.hex, optional)
  integer rfd, ra, rv, nreads = 0;
  reg [31:0] rd;
  task check_reads;
    begin
      rfd = $fopen({`VEC, "/reads.hex"}, "r");
      if (rfd != 0) begin
        while (!$feof(rfd)) begin
          r = $fscanf(rfd, "%h %h\n", ra, rv);
          if (r == 2) begin
            axil_read(ra[11:0], rd);
            nreads = nreads + 1;
            if (rd !== rv[31:0]) begin
              $display("ERROR: register 0x%03h read %h, want %h", ra[11:0], rd, rv[31:0]);
              errors = errors + 1;
            end
          end
        end
        $fclose(rfd);
        $display("%0d registers read back", nreads);
      end
    end
  endtask

`ifdef CAPTURE
  // output: random back-pressure, record
  integer cap_fd, quiet = 0;
  reg [7:0] cap_flags = 8'd0;
  initial cap_fd = $fopen({`VEC, "/captured.hex"}, "w");
  always @(posedge clk) begin
    m_ready <= ($random % 3) != 0;
    quiet = quiet + 1;
    if (m_valid && m_ready) begin
      if (first_out) cap_flags = m_user[71:64];
      $fwrite(cap_fd, "%h %0d %h\n", m_data, m_last, cap_flags);
      got = got + 1;
      first_out = m_last;
      if (m_last) pkt_out = pkt_out + 1;
      quiet = 0;
    end
`ifdef CAPTURE_PACKETS
    if (pkt_out >= `CAPTURE_PACKETS) quiet = `CAPTURE_QUIET;
    if (rstn && quiet >= `CAPTURE_QUIET) begin
`else
    if (rstn && sent >= n_in && n_in > 0 && quiet >= `CAPTURE_QUIET) begin
`endif
      $fclose(cap_fd);
      $display("%0d beats in %0d packets captured", got, pkt_out);
      check_reads;
      if (errors == 0) $display("PASS (captured; check with the module's script)"); else $display("FAIL");
      $finish;
    end
  end
`else
  // output: random back-pressure, compare
  always @(posedge clk) begin
    m_ready <= ($random % 3) != 0;
    if (m_valid && m_ready) begin
      if (got >= n_out) begin
        if (errors < 10) $display("ERROR: extra output %h", m_data);
        errors = errors + 1;
      end else begin
        if (m_data !== out_w[got] || m_last !== out_l[got]) begin
          if (errors < 10)
            $display("ERROR: beat %0d: got %h last %b, want %h last %b", got, m_data, m_last, out_w[got], out_l[got]);
          errors = errors + 1;
        end
`ifndef NO_TUSER_CHECK
        if (first_out && m_user !== {8'hC3 ^ pkt_out[7:0], 32'd0, pkt_out}) begin
          if (errors < 10) $display("ERROR: packet %0d tuser %h", pkt_out, m_user);
          errors = errors + 1;
        end
`endif
      end
      got = got + 1;
      first_out = m_last;
      if (m_last) pkt_out = pkt_out + 1;
    end
  end

`endif

`ifndef TIMEOUT_NS
  `define TIMEOUT_NS (5.0 * 20 * MAXN)
`endif
  initial begin
    #(`TIMEOUT_NS);
    $display("FAIL: timeout, %0d of %0d beats out", got, n_out);
    $finish;
  end

`ifndef CAPTURE
  always @(posedge clk)
    if (rstn && got == n_out && n_out > 0) begin
      repeat (50) @(posedge clk);
      if (got != n_out) errors = errors + 1;
      $display("%0d beats in %0d packets compared, %0d errors", got, pkt_out, errors);
      check_reads;
      if (errors == 0) $display("PASS"); else $display("FAIL");
      $finish;
    end

`endif

endmodule
