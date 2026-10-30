// ***************************************************************************
// GlideLink shell, steps 1.3 / 1.4 (docs/phase1_shell.md)
//
//   sources: 0 RF RX (RX streamer), 1 host port 0 TX, 2 slot 0 out, 3 host port 1 TX
//   sinks:   0 RF TX (TX streamer), 1 host port 0 RX, 2 slot 0 in, 3 host port 1 RX
//
// The stream switch connects them (routes from the registers; reset routes
// RF RX -> host 0 RX and host 0 TX -> RF TX). Host port 0 carries 16-byte
// packet headers or raw samples (CONFIG bits 2 / 3). Register window:
// 0x0000-0x1FFF shell registers and routes (CPU clock), 0x2000 slot 0
// (processing clock, through an AXI4-Lite clock-domain bridge).
// PORT_RESET flushes a host port before a stream starts: RX drops the switch
// connection into host port 0 RX and resets its adapter; TX resets the host
// TX adapter, the switch's packet state for it and the RF TX streamer, and drops
// whatever the RF TX sink was connected to; slot 0 resets the slot and its
// switch connections (a slot left holding half a packet).
// Switch packets carry tuser = {flags[7:0], timestamp[63:0]} on the first
// beat, one set of flags for every port (host port headers carry them as
// they are): bit 0 = packets were dropped before this one, bit 1 = end of
// burst, bit 2 = timed (the RF TX streamer sends it at the timestamp); host
// port RX headers add bit 7 = part of a longer packet.
// The DMA side pins are deliberately not named *_tdata/_tvalid so that they
// can be wired pin by pin to axi_dmac in the block design.
// ***************************************************************************

`timescale 1ns/100ps

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

  // processing clock
  input             clk,
  input             rstn,

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

  localparam N_SRC = 4, N_SNK = 4;

  wire        rst = !rstn;
  wire [63:0] time_now;
  wire [15:0] rx_pkt_len;
  wire        rx_enable, tx_late_drop, host0_rx_hdr, host0_tx_hdr, host1_rx_hdr, host1_tx_hdr;
  wire [31:0] ovf_gray, unf_gray, late_gray, herr_gray, herr1_gray;
  reg  [31:0] dma_ovf = 32'd0, dma_ovf_gray = 32'd0, dma1_ovf = 32'd0, dma1_ovf_gray = 32'd0;
  wire [N_SNK*4-1:0] route;
  wire  [4:0] port_reset;                 // CPU clock: host 0 RX, host 0 TX, slot 0, host 1 RX, host 1 TX
  (* ASYNC_REG = "TRUE" *) reg [4:0] prst_m1 = 5'd0, prst_s = 5'd0;
  wire        rx_flush = prst_s[0];
  wire        tx_flush = prst_s[1];
  wire        slot_flush = prst_s[2];
  wire        rx1_flush = prst_s[3];
  wire        tx1_flush = prst_s[4];
  always @(posedge clk) begin
    prst_m1 <= port_reset;
    prst_s <= prst_m1;
  end

  // ---------------------------------------------------------------------------
  // register window: demux, shell registers, slot 0 through the CDC bridge

  wire [15:0] r_awaddr, r_araddr;
  wire [31:0] r_wdata;
  wire  [3:0] r_wstrb;
  wire  [1:0] r_awvalid, r_awready, r_wvalid, r_wready, r_bvalid, r_bready;
  wire  [1:0] r_arvalid, r_arready, r_rvalid, r_rready;
  wire [63:0] r_rdata;

  glidelink_axil_demux #(.N_PORTS(2)) i_demux (
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

  glidelink_shell_regs #(.HOST_RX(8'd2), .HOST_TX(8'd2), .SLOTS(8'd1), .N_SNK(N_SNK)) i_regs (
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
    .tx_late_gray(late_gray), .host0_tx_err_gray(herr_gray), .host0_rx_ovf_gray(dma_ovf_gray),
    .host1_tx_err_gray(herr1_gray), .host1_rx_ovf_gray(dma1_ovf_gray),
    .rx_pkt_len(rx_pkt_len), .rx_enable(rx_enable), .tx_late_drop(tx_late_drop),
    .host0_rx_hdr(host0_rx_hdr), .host0_tx_hdr(host0_tx_hdr), .host1_rx_hdr(host1_rx_hdr),
    .host1_tx_hdr(host1_tx_hdr), .route(route),
    .port_reset(port_reset));

  wire        sl_awvalid, sl_awready, sl_wvalid, sl_wready, sl_bvalid, sl_bready;
  wire        sl_arvalid, sl_arready, sl_rvalid, sl_rready;
  wire [11:0] sl_awaddr, sl_araddr;
  wire [31:0] sl_wdata, sl_rdata;

  glidelink_axil_cdc i_slot0_cdc (
    .s_clk(s_axi_aclk), .s_rstn(s_axi_aresetn),
    .s_awvalid(r_awvalid[1]), .s_awready(r_awready[1]), .s_awaddr(r_awaddr[11:0]),
    .s_wvalid(r_wvalid[1]), .s_wready(r_wready[1]), .s_wdata(r_wdata),
    .s_bvalid(r_bvalid[1]), .s_bready(r_bready[1]),
    .s_arvalid(r_arvalid[1]), .s_arready(r_arready[1]), .s_araddr(r_araddr[11:0]),
    .s_rvalid(r_rvalid[1]), .s_rready(r_rready[1]), .s_rdata(r_rdata[63:32]),
    .m_clk(clk), .m_rstn(rstn),
    .m_awvalid(sl_awvalid), .m_awready(sl_awready), .m_awaddr(sl_awaddr),
    .m_wvalid(sl_wvalid), .m_wready(sl_wready), .m_wdata(sl_wdata),
    .m_bvalid(sl_bvalid), .m_bready(sl_bready),
    .m_arvalid(sl_arvalid), .m_arready(sl_arready), .m_araddr(sl_araddr),
    .m_rvalid(sl_rvalid), .m_rready(sl_rready), .m_rdata(sl_rdata));

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
    .overflow_gray(ovf_gray), .adc_dovf(adc_dovf),
    .m_clk(clk), .m_rst(rst), .m_axis_tdata(src_data[0 +: 32]), .m_axis_tuser(src_user[0 +: 72]),
    .m_axis_tlast(src_last[0]), .m_axis_tvalid(src_valid[0]), .m_axis_tready(src_ready[0]));

  glidelink_host_tx i_host0_tx (
    .clk(clk), .rst(rst || tx_flush), .hdr_en(host0_tx_hdr),
    .s_valid(host0_tx_valid), .s_ready(host0_tx_ready), .s_data(host0_tx_data), .s_last(host0_tx_last),
    .m_valid(src_valid[1]), .m_ready(src_ready[1]), .m_data(src_data[32 +: 32]),
    .m_user(src_user[72 +: 72]), .m_last(src_last[1]), .errors_gray(herr_gray));

  glidelink_passthrough i_slot0 (
    .clk(clk), .rstn(rstn && !slot_flush),
    .s_axil_awvalid(sl_awvalid), .s_axil_awready(sl_awready), .s_axil_awaddr(sl_awaddr),
    .s_axil_wvalid(sl_wvalid), .s_axil_wready(sl_wready), .s_axil_wdata(sl_wdata),
    .s_axil_bvalid(sl_bvalid), .s_axil_bready(sl_bready),
    .s_axil_arvalid(sl_arvalid), .s_axil_arready(sl_arready), .s_axil_araddr(sl_araddr),
    .s_axil_rvalid(sl_rvalid), .s_axil_rready(sl_rready), .s_axil_rdata(sl_rdata),
    .s_axis_tvalid(snk_valid[2]), .s_axis_tready(snk_ready[2]), .s_axis_tdata(snk_data[64 +: 32]),
    .s_axis_tuser(snk_user[144 +: 72]), .s_axis_tlast(snk_last[2]),
    .m_axis_tvalid(src_valid[2]), .m_axis_tready(src_ready[2]), .m_axis_tdata(src_data[64 +: 32]),
    .m_axis_tuser(src_user[144 +: 72]), .m_axis_tlast(src_last[2]));

  glidelink_switch #(.N_SRC(N_SRC), .N_SNK(N_SNK)) i_switch (
    .clk(clk), .rst(rst), .route(route),
    .abort_snk({rx1_flush, slot_flush, rx_flush, tx_flush}), .abort_src({tx1_flush, slot_flush, tx_flush, 1'b0}),
    .s_valid(src_valid), .s_ready(src_ready), .s_data(src_data), .s_user(src_user), .s_last(src_last),
    .m_valid(snk_valid), .m_ready(snk_ready), .m_data(snk_data), .m_user(snk_user), .m_last(snk_last));

  glidelink_tx_stream i_tx (
    .s_clk(clk), .s_rst(rst || tx_flush), .s_axis_tdata(snk_data[0 +: 32]), .s_axis_tuser(snk_user[0 +: 72]),
    .s_axis_tlast(snk_last[0]), .s_axis_tvalid(snk_valid[0]), .s_axis_tready(snk_ready[0]),
    .l_clk(l_clk), .l_rst(l_rst), .dac_valid(dac_valid_i0), .dac_data_i(dac_data_i0),
    .dac_data_q(dac_data_q0), .time_now(time_now), .late_drop(tx_late_drop),
    .underflow_gray(unf_gray), .late_gray(late_gray), .dac_dunf(dac_dunf));

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
