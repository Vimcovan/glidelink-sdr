// ***************************************************************************
// GlideLink shell (docs/phase1_shell.md; slots: docs/phase3_modules.md, docs/phase4_plan.md)
//
//   sources: 0 RF RX (RX streamer), 1 host port 0 TX, 2 slot 0 out, 3 host port 1 TX,
//            3 + k slot k out (k >= 1)
//   sinks:   0 RF TX (TX streamer), 1 host port 0 RX, 2 slot 0 in, 3 host port 1 RX,
//            3 + k slot k in (k >= 1)
//   slots:   as the image says (hw/images/*.yaml, generated glidelink_slots.v and
//            glidelink_image.vh by hw/scripts/gen_image.py)
//
// The stream switch connects them (routes from the registers; reset routes
// RF RX -> host 0 RX and host 0 TX -> RF TX). Host port 0 carries 16-byte
// packet headers or raw samples (CONFIG bits 2 / 3). Register window:
// 0x0000-0x1FFF shell registers and routes (CPU clock), 0x2000 + 0x1000 k
// slot k (processing clock, each through an AXI4-Lite clock-domain bridge).
// PORT_RESET flushes a host port before a stream starts: RX drops the switch
// connection into host port 0 RX and resets its adapter; TX resets the host
// TX adapter, the switch's packet state for it and the RF TX streamer, and drops
// whatever the RF TX sink was connected to; a slot reset flushes the slot's
// stream state (its registers are kept) and its switch connections (a slot
// left holding half a packet).
// Switch packets carry tuser = {flags[7:0], timestamp[63:0]} on the first
// beat, one set of flags for every port (host port headers carry them as
// they are): bit 0 = packets were dropped before this one, bit 1 = end of
// burst, bit 2 = timed (the RF TX streamer sends it at the timestamp); host
// port RX headers add bit 7 = part of a longer packet.
// The DMA side pins are deliberately not named *_tdata/_tvalid so that they
// can be wired pin by pin to axi_dmac in the block design.
// ***************************************************************************

`timescale 1ns/100ps
`include "glidelink_image.vh"

module glidelink_shell (
  // registers (CPU clock); the attributes tie the s_axi interface to its
  // clock and reset for the block design (the module has several clocks)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
  input             s_axi_aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input             s_axi_aresetn,
  input             s_axi_awvalid,
  output            s_axi_awready,
  input     [15:0]  s_axi_awaddr,
  input      [2:0]  s_axi_awprot,
  input             s_axi_wvalid,
  output            s_axi_wready,
  input     [31:0]  s_axi_wdata,
  input      [3:0]  s_axi_wstrb,
  output            s_axi_bvalid,
  input             s_axi_bready,
  output     [1:0]  s_axi_bresp,
  input             s_axi_arvalid,
  output            s_axi_arready,
  input     [15:0]  s_axi_araddr,
  input      [2:0]  s_axi_arprot,
  output            s_axi_rvalid,
  input             s_axi_rready,
  output     [1:0]  s_axi_rresp,
  output    [31:0]  s_axi_rdata,

  // axi_ad9361 (l_clk)
  input             l_clk,
  input             l_rst,
  input             adc_valid_i0,
  input     [15:0]  adc_data_i0,
  input     [15:0]  adc_data_q0,
  output            adc_dovf,
  input             dac_valid_i0,
  output    [15:0]  dac_data_i0,
  output    [15:0]  dac_data_q0,
  output            dac_dunf,
  input      [7:0]  ctrl_out,

  // processing clock; the other clocks a slot may run on
  input             clk,
  input             rstn,
  input             clk_250,

  // host port 0 (processing clock). RX goes to the FIFO write interface of
  // axi_dmac (it cannot hold data off): a word is written when the DMA has a
  // transfer running (xfer_req), at most every other cycle (400 MB/s, below
  // the DMA's 800 MB/s memory side); DMA overflows are counted all the same.
  output            host0_rx_valid,         // fifo_wr_en
  input             host0_rx_xfer_req,
  input             host0_rx_overflow,
  output    [31:0]  host0_rx_data,
  input             host0_tx_valid,
  output            host0_tx_ready,
  input     [31:0]  host0_tx_data,
  input             host0_tx_last,

  // host port 1 (processing clock): as host port 0, not tied to the RF
  output            host1_rx_valid,         // fifo_wr_en
  input             host1_rx_xfer_req,
  input             host1_rx_overflow,
  output    [31:0]  host1_rx_data,
  input             host1_tx_valid,
  output            host1_tx_ready,
  input     [31:0]  host1_tx_data,
  input             host1_tx_last
);

  localparam N_SLOTS = `GL_N_SLOTS;
  localparam N_SRC = N_SLOTS + 3, N_SNK = N_SLOTS + 3;
  localparam PRST_W = N_SLOTS + 4;        // PORT_RESET bits

  // switch port of slot k, PORT_RESET bit of slot k
  function integer slot_port(input integer k); slot_port = k == 0 ? 2 : 3 + k; endfunction
  function integer slot_prst(input integer k); slot_prst = k == 0 ? 2 : 4 + k; endfunction

  wire        rst = !rstn;
  wire [63:0] time_now;
  wire [15:0] rx_pkt_len, rx_pkt_len_a;
  wire        rx_enable, tx_late_drop, host0_rx_hdr, host0_tx_hdr, host1_rx_hdr, host1_tx_hdr;
  wire        rx_enable_a, tx_late_drop_a, host0_rx_hdr_a, host0_tx_hdr_a, host1_rx_hdr_a, host1_tx_hdr_a;
  wire [31:0] ovf_gray, unf_gray, late_gray, herr_gray, herr1_gray;
  wire  [7:0] tx_dbg_l, tx_dbg_s;
  wire  [1:0] rx_dbg_l;
  wire [47:0] rx_dbg_m;
  wire [31:0] sw_dbg;
  wire [63:0] tx_dbg_time;
  reg  [31:0] dma_ovf = 32'd0, dma_ovf_gray = 32'd0, dma1_ovf = 32'd0, dma1_ovf_gray = 32'd0;
  wire [N_SNK*4-1:0] route, route_a;
  wire [PRST_W-1:0] port_reset;          // CPU clock: host 0 RX, host 0 TX, slot 0, host 1 RX, host 1 TX, slot 1..
  (* ASYNC_REG = "TRUE" *) reg [PRST_W-1:0] prst_m1 = 0, prst_s = 0;
  wire        rx_flush = prst_s[0];
  wire        tx_flush = prst_s[1];
  wire        rx1_flush = prst_s[3];
  wire        tx1_flush = prst_s[4];
  wire [N_SLOTS-1:0] slot_rst;
  genvar g;
  generate
    for (g = 0; g < N_SLOTS; g = g + 1) begin : g_slot_rst
      assign slot_rst[g] = prst_s[slot_prst(g)];
    end
  endgenerate
  always @(posedge clk) begin
    prst_m1 <= port_reset;
    prst_s <= prst_m1;
  end

  // ---------------------------------------------------------------------------
  // register window: demux, shell registers, slots through CDC bridges

  localparam NP = N_SLOTS + 1;
  wire [15:0] r_awaddr, r_araddr;
  wire [31:0] r_wdata;
  wire  [3:0] r_wstrb;
  wire [NP-1:0] r_awvalid, r_awready, r_wvalid, r_wready, r_bvalid, r_bready;
  wire [NP-1:0] r_arvalid, r_arready, r_rvalid, r_rready;
  wire [NP*32-1:0] r_rdata;

  glidelink_axil_demux #(.N_PORTS(NP)) i_demux (
    .clk(s_axi_aclk), .rstn(s_axi_aresetn),
    .s_awvalid(s_axi_awvalid), .s_awready(s_axi_awready), .s_awaddr(s_axi_awaddr),
    .s_wvalid(s_axi_wvalid), .s_wready(s_axi_wready), .s_wdata(s_axi_wdata), .s_wstrb(s_axi_wstrb),
    .s_bvalid(s_axi_bvalid), .s_bready(s_axi_bready), .s_bresp(s_axi_bresp),
    .s_arvalid(s_axi_arvalid), .s_arready(s_axi_arready), .s_araddr(s_axi_araddr),
    .s_rvalid(s_axi_rvalid), .s_rready(s_axi_rready), .s_rresp(s_axi_rresp), .s_rdata(s_axi_rdata),
    .m_awaddr(r_awaddr), .m_awvalid(r_awvalid), .m_awready(r_awready),
    .m_wdata(r_wdata), .m_wstrb(r_wstrb), .m_wvalid(r_wvalid), .m_wready(r_wready),
    .m_bvalid(r_bvalid), .m_bready(r_bready),
    .m_araddr(r_araddr), .m_arvalid(r_arvalid), .m_arready(r_arready),
    .m_rvalid(r_rvalid), .m_rready(r_rready), .m_rdata(r_rdata));

  glidelink_shell_regs #(.HOST_RX(8'd2), .HOST_TX(8'd2), .SLOTS(N_SLOTS), .N_SNK(N_SNK), .PRST_W(PRST_W),
                         .ROUTE_RESET({{(N_SNK - 2){4'hF}}, 4'd0, 4'd1})) i_regs (
    .s_axi_aclk(s_axi_aclk), .s_axi_aresetn(s_axi_aresetn),
    .s_axi_awvalid(r_awvalid[0]), .s_axi_awready(r_awready[0]), .s_axi_awaddr(r_awaddr),
    .s_axi_awprot(3'd0), .s_axi_wvalid(r_wvalid[0]), .s_axi_wready(r_wready[0]),
    .s_axi_wdata(r_wdata), .s_axi_wstrb(r_wstrb), .s_axi_bvalid(r_bvalid[0]),
    .s_axi_bready(r_bready[0]), .s_axi_bresp(), .s_axi_arvalid(r_arvalid[0]),
    .s_axi_arready(r_arready[0]), .s_axi_araddr(r_araddr), .s_axi_arprot(3'd0),
    .s_axi_rvalid(r_rvalid[0]), .s_axi_rready(r_rready[0]), .s_axi_rresp(),
    .s_axi_rdata(r_rdata[31:0]),
    .l_clk(l_clk), .adc_valid(adc_valid_i0), .time_now(time_now),
    .ctrl_out(ctrl_out), .rx_overflow_gray(ovf_gray), .tx_underflow_gray(unf_gray),
    .tx_late_gray(late_gray), .tx_dbg_l(tx_dbg_l), .tx_dbg_s(tx_dbg_s), .tx_dbg_time(tx_dbg_time),
    .rx_dbg({rx_dbg_m[47:32], 14'd0, rx_dbg_l, rx_dbg_m[31:0]}), .sw_dbg(sw_dbg),
    .host0_tx_err_gray(herr_gray), .host0_rx_ovf_gray(dma_ovf_gray),
    .host1_tx_err_gray(herr1_gray), .host1_rx_ovf_gray(dma1_ovf_gray),
    .rx_pkt_len(rx_pkt_len_a), .rx_enable(rx_enable_a), .tx_late_drop(tx_late_drop_a),
    .host0_rx_hdr(host0_rx_hdr_a), .host0_tx_hdr(host0_tx_hdr_a), .host1_rx_hdr(host1_rx_hdr_a),
    .host1_tx_hdr(host1_tx_hdr_a), .route(route_a),
    .port_reset(port_reset));

  // the configuration (CPU clock) into the clocks that use it. Without this, a write landing on the cycle
  // a packet starts reaches part of the logic and not the rest (the RX buffer's level counter then drifts
  // from its contents). Level bits: two flip-flops. RX_PKT_LEN (16 bits): two flip-flops, then taken
  // only after four equal samples, so it never shows a mix of old and new bits. The routes are
  // synchronised in the switch.
  assign route = route_a;
  (* ASYNC_REG = "TRUE" *) reg [4:0] lvl_m1 = 5'b10000, lvl_s = 5'b10000;
  always @(posedge clk) begin
    lvl_m1 <= {rx_enable_a, host0_rx_hdr_a, host0_tx_hdr_a, host1_rx_hdr_a, host1_tx_hdr_a};
    lvl_s <= lvl_m1;
  end
  assign {rx_enable, host0_rx_hdr, host0_tx_hdr, host1_rx_hdr, host1_tx_hdr} = lvl_s;

  (* ASYNC_REG = "TRUE" *) reg [15:0] plen_m1 = 16'd4096, plen_m2 = 16'd4096;
  reg  [15:0] plen_d = 16'd4096, plen_s = 16'd4096;
  reg   [1:0] plen_stable = 2'd0;
  always @(posedge clk) begin
    plen_m1 <= rx_pkt_len_a;
    plen_m2 <= plen_m1;
    plen_d <= plen_m2;
    if (plen_m2 != plen_d)
      plen_stable <= 2'd0;
    else if (plen_stable != 2'd3)
      plen_stable <= plen_stable + 2'd1;
    else
      plen_s <= plen_d;
  end
  assign rx_pkt_len = plen_s;

  (* ASYNC_REG = "TRUE" *) reg [1:0] late_drop_l = 2'b11;
  always @(posedge l_clk)
    late_drop_l <= {late_drop_l[0], tx_late_drop_a};
  assign tx_late_drop = late_drop_l[1];

  // ---------------------------------------------------------------------------
  // stream ports

  wire [N_SRC-1:0]    src_valid, src_ready, src_last;
  wire [N_SRC*32-1:0] src_data;
  wire [N_SRC*72-1:0] src_user;
  wire [N_SNK-1:0]    snk_valid, snk_ready, snk_last;
  wire [N_SNK*32-1:0] snk_data;
  wire [N_SNK*72-1:0] snk_user;

  glidelink_rx_stream i_rx (
    .l_clk(l_clk), .l_rst(l_rst), .adc_valid(adc_valid_i0), .adc_data_i(adc_data_i0),
    .adc_data_q(adc_data_q0), .time_now(time_now), .pkt_len(rx_pkt_len), .enable(rx_enable),
    .overflow_gray(ovf_gray), .adc_dovf(adc_dovf), .dbg_l(rx_dbg_l), .dbg_m(rx_dbg_m),
    .m_clk(clk), .m_rst(rst), .m_axis_tdata(src_data[0 +: 32]), .m_axis_tuser(src_user[0 +: 72]),
    .m_axis_tlast(src_last[0]), .m_axis_tvalid(src_valid[0]), .m_axis_tready(src_ready[0]));

  glidelink_host_tx i_host0_tx (
    .clk(clk), .rst(rst || tx_flush), .hdr_en(host0_tx_hdr),
    .s_valid(host0_tx_valid), .s_ready(host0_tx_ready), .s_data(host0_tx_data), .s_last(host0_tx_last),
    .m_valid(src_valid[1]), .m_ready(src_ready[1]), .m_data(src_data[32 +: 32]),
    .m_user(src_user[72 +: 72]), .m_last(src_last[1]), .errors_gray(herr_gray));

  // slots (generated per image): each behind a glidelink_slot wrapper, which
  // isolates the switch from the module (skid buffer or clock-crossing FIFOs)

  wire [N_SLOTS-1:0]     sl_snk_valid, sl_snk_ready, sl_src_valid, sl_src_ready;
  wire [N_SLOTS*105-1:0] sl_snk_data, sl_src_data;      // {last, user, data}

  generate
    for (g = 0; g < N_SLOTS; g = g + 1) begin : g_slot_ports
      localparam integer J = slot_port(g);
      assign sl_snk_valid[g] = snk_valid[J];
      assign snk_ready[J] = sl_snk_ready[g];
      assign sl_snk_data[g * 105 +: 105] = {snk_last[J], snk_user[J * 72 +: 72], snk_data[J * 32 +: 32]};
      assign src_valid[J] = sl_src_valid[g];
      assign sl_src_ready[g] = src_ready[J];
      assign {src_last[J], src_user[J * 72 +: 72], src_data[J * 32 +: 32]} = sl_src_data[g * 105 +: 105];
    end
  endgenerate

  glidelink_slots i_slots (
    .s_axi_aclk(s_axi_aclk), .s_axi_aresetn(s_axi_aresetn),
    .s_awvalid(r_awvalid[NP-1:1]), .s_awready(r_awready[NP-1:1]), .s_awaddr({N_SLOTS{r_awaddr[11:0]}}),
    .s_wvalid(r_wvalid[NP-1:1]), .s_wready(r_wready[NP-1:1]), .s_wdata({N_SLOTS{r_wdata}}),
    .s_bvalid(r_bvalid[NP-1:1]), .s_bready(r_bready[NP-1:1]),
    .s_arvalid(r_arvalid[NP-1:1]), .s_arready(r_arready[NP-1:1]), .s_araddr({N_SLOTS{r_araddr[11:0]}}),
    .s_rvalid(r_rvalid[NP-1:1]), .s_rready(r_rready[NP-1:1]), .s_rdata(r_rdata[NP*32-1:32]),
    .clk(clk), .rstn(rstn), .clk_100(s_axi_aclk), .clk_250(clk_250), .flush(slot_rst),
    .snk_valid(sl_snk_valid), .snk_ready(sl_snk_ready), .snk_data(sl_snk_data),
    .src_valid(sl_src_valid), .src_ready(sl_src_ready), .src_data(sl_src_data));

  // switch aborts: a flushed port drops its connections
  wire [N_SNK-1:0] abort_snk;
  wire [N_SRC-1:0] abort_src;
  assign abort_snk[0] = tx_flush;
  assign abort_snk[1] = rx_flush;
  assign abort_snk[3] = rx1_flush;
  assign abort_src[0] = 1'b0;
  assign abort_src[1] = tx_flush;
  assign abort_src[3] = tx1_flush;
  generate
    for (g = 0; g < N_SLOTS; g = g + 1) begin : g_slot_abort
      assign abort_snk[slot_port(g)] = slot_rst[g];
      assign abort_src[slot_port(g)] = slot_rst[g];
    end
  endgenerate

  glidelink_switch #(.N_SRC(N_SRC), .N_SNK(N_SNK)) i_switch (
    .clk(clk), .rst(rst), .route(route),
    .abort_snk(abort_snk), .abort_src(abort_src),
    .s_valid(src_valid), .s_ready(src_ready), .s_data(src_data), .s_user(src_user), .s_last(src_last),
    .m_valid(snk_valid), .m_ready(snk_ready), .m_data(snk_data), .m_user(snk_user), .m_last(snk_last),
    .dbg(sw_dbg));

  glidelink_tx_stream i_tx (
    .s_clk(clk), .s_rst(rst || tx_flush), .s_axis_tdata(snk_data[0 +: 32]), .s_axis_tuser(snk_user[0 +: 72]),
    .s_axis_tlast(snk_last[0]), .s_axis_tvalid(snk_valid[0]), .s_axis_tready(snk_ready[0]),
    .l_clk(l_clk), .l_rst(l_rst), .dac_valid(dac_valid_i0), .dac_data_i(dac_data_i0),
    .dac_data_q(dac_data_q0), .time_now(time_now), .late_drop(tx_late_drop),
    .underflow_gray(unf_gray), .late_gray(late_gray), .dac_dunf(dac_dunf),
    .dbg_l(tx_dbg_l), .dbg_s(tx_dbg_s), .dbg_start_time(tx_dbg_time));

  reg         rx_phase = 1'b0;
  wire        rx_valid;
  wire        rx_take = host0_rx_xfer_req && rx_phase;

  always @(posedge clk) begin
    rx_phase <= !rx_phase;
    if (host0_rx_overflow) dma_ovf <= dma_ovf + 32'd1;
    dma_ovf_gray <= dma_ovf ^ (dma_ovf >> 1);
  end

  assign host0_rx_valid = rx_valid && rx_take;

  glidelink_host_rx i_host0_rx (
    .clk(clk), .rst(rst || rx_flush), .hdr_en(host0_rx_hdr),
    .s_valid(snk_valid[1]), .s_ready(snk_ready[1]), .s_data(snk_data[32 +: 32]),
    .s_user(snk_user[72 +: 72]), .s_last(snk_last[1]),
    .m_valid(rx_valid), .m_ready(rx_take), .m_data(host0_rx_data));

  // host port 1: TX adapter (source 3), RX adapter (sink 3)

  glidelink_host_tx i_host1_tx (
    .clk(clk), .rst(rst || tx1_flush), .hdr_en(host1_tx_hdr),
    .s_valid(host1_tx_valid), .s_ready(host1_tx_ready), .s_data(host1_tx_data), .s_last(host1_tx_last),
    .m_valid(src_valid[3]), .m_ready(src_ready[3]), .m_data(src_data[96 +: 32]),
    .m_user(src_user[216 +: 72]), .m_last(src_last[3]), .errors_gray(herr1_gray));

  wire        rx1_valid;
  wire        rx1_take = host1_rx_xfer_req && rx_phase;

  always @(posedge clk) begin
    if (host1_rx_overflow) dma1_ovf <= dma1_ovf + 32'd1;
    dma1_ovf_gray <= dma1_ovf ^ (dma1_ovf >> 1);
  end

  assign host1_rx_valid = rx1_valid && rx1_take;

  glidelink_host_rx i_host1_rx (
    .clk(clk), .rst(rst || rx1_flush), .hdr_en(host1_rx_hdr),
    .s_valid(snk_valid[3]), .s_ready(snk_ready[3]), .s_data(snk_data[96 +: 32]),
    .s_user(snk_user[216 +: 72]), .s_last(snk_last[3]),
    .m_valid(rx1_valid), .m_ready(rx1_take), .m_data(host1_rx_data));

endmodule
