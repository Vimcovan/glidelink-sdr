// ***************************************************************************
// GlideLink shell: register block (CPU window 0x0000-0x1FFF of the shell)
//
//   0x000  ID           RO  0x474C4B53 ("GLKS")
//   0x004  VERSION      RO  {major[15:0], minor[7:0], patch[7:0]}
//   0x008  CAPS         RO  {slots[7:0], host_tx[7:0], host_rx[7:0], rf_channels[7:0]}
//   0x00C  SCRATCH      RW
//   0x010  TIME_LO      RO  sample counter [31:0]; reading it latches [63:32] for TIME_HI
//   0x014  TIME_HI      RO  sample counter [63:32] latched by the last TIME_LO read
//   0x018  TIME_SET_LO  RW  value loaded by TIME_CTRL.load
//   0x01C  TIME_SET_HI  RW
//   0x020  TIME_CTRL    W   bit 0: load TIME_SET into the counter (at the next sample)
//                       R   bit 0: load pending
//   0x030  CTRL_OUT     RO  AD9361 CTRL_OUT[7:0] (synchronised)
//   0x040  RX_OVERFLOW  RO  packets dropped by the RX streamer
//   0x044  TX_UNDERFLOW RO  TX FIFO empty inside a burst
//   0x048  TX_LATE      RO  timed TX packets that arrived after their time
//   0x04C  HOST0_TX_ERR RO  host port 0 TX: words dropped looking for a packet header
//   0x058  HOST0_RX_OVF RO  host port 0 RX: words the DMA could not take (FIFO interface)
//   0x05C  PORT_RESET   W   bit 0: flush host port 0 RX, bit 1: flush host port 0 TX (and the
//                           RF TX streamer), bit 2: reset slot 0, bit 3 / 4: flush host port 1
//                           RX / TX, bit 5 / 6: reset slot 1 / 2; held 16 cycles, self-clearing
//   0x060  HOST1_TX_ERR RO  host port 1 TX: words dropped looking for a packet header
//   0x064  HOST1_RX_OVF RO  host port 1 RX: words the DMA could not take
//   0x050  RX_PKT_LEN   RW  samples per RX packet (default 4096)
//   0x054  CONFIG       RW  bit 0: RX enable (default 1), bit 1: drop late TX packets (default 1),
//                           bit 2: host port 0 RX adds packet headers, bit 3: host port 0 TX
//                           takes packet headers, bit 4 / 5: the same for host port 1
//                           (all default 0: raw)
//   0x1000 + 4j  ROUTE[j]  RW  source of sink j (4'hF = none):
//                           sinks 0 RF TX, 1 host port 0 RX, 2 slot 0 in, 3 host port 1 RX;
//                           sources 0 RF RX, 1 host port 0 TX, 2 slot 0 out, 3 host port 1 TX
//
// The counters arrive Gray-coded from the l_clk domain.
//
// The sample counter runs in the AD9361 data clock domain (l_clk) and counts
// valid samples of RF channel 0. The CPU side reads a snapshot that a
// toggle handshake keeps refreshing, a few clock cycles old.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_shell_regs #(
  parameter [7:0] RF_CHANNELS = 8'd1,
  parameter [7:0] HOST_RX = 8'd1,
  parameter [7:0] HOST_TX = 8'd1,
  parameter [7:0] SLOTS = 8'd0,
  parameter N_SNK = 4,
  parameter [N_SNK*4-1:0] ROUTE_RESET = {4'hF, 4'hF, 4'd0, 4'd1}
) (
  // AXI4-Lite slave (CPU clock)
  input             s_axi_aclk,
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

  // sample clock domain
  input             l_clk,
  input             adc_valid,
  output    [63:0]  time_now,

  // status (synchronised here)
  input      [7:0]  ctrl_out,
  input     [31:0]  rx_overflow_gray,
  input     [31:0]  tx_underflow_gray,
  input     [31:0]  tx_late_gray,
  input     [31:0]  host0_tx_err_gray,
  input     [31:0]  host0_rx_ovf_gray,
  input     [31:0]  host1_tx_err_gray,
  input     [31:0]  host1_rx_ovf_gray,

  // configuration (CPU clock, quasi-static)
  output    [15:0]  rx_pkt_len,
  output            rx_enable,
  output            tx_late_drop,
  output            host0_rx_hdr,
  output            host0_tx_hdr,
  output            host1_rx_hdr,
  output            host1_tx_hdr,
  output     [6:0]  port_reset,             // CPU clock, 16-cycle pulses
  output [N_SNK*4-1:0] route
);

  localparam [31:0] ID = 32'h474C4B53;
  localparam [31:0] VERSION = 32'h00010400;    // 1.4.0: three slots (passthrough, NCO, FIR)

  // ---------------------------------------------------------------------------
  // AXI4-Lite: one outstanding write and one outstanding read

  reg         awready = 1'b0, wready = 1'b0, bvalid = 1'b0;
  reg         arready = 1'b0, rvalid = 1'b0;
  reg  [31:0] rdata = 32'd0;
  reg  [12:0] waddr = 13'd0;
  reg         waddr_ok = 1'b0, wdata_ok = 1'b0;
  reg  [31:0] wdata = 32'd0;

  assign s_axi_awready = awready;
  assign s_axi_wready = wready;
  assign s_axi_bvalid = bvalid;
  assign s_axi_bresp = 2'b00;
  assign s_axi_arready = arready;
  assign s_axi_rvalid = rvalid;
  assign s_axi_rresp = 2'b00;
  assign s_axi_rdata = rdata;

  reg  [31:0] scratch = 32'd0;
  reg  [15:0] pkt_len = 16'd4096;
  reg  [5:0]  cfg = 6'b000011;
  reg  [N_SNK*4-1:0] routes = ROUTE_RESET;
  reg  [6:0]  prst = 7'd0;
  reg  [3:0]  prst_cnt = 4'd0;
  reg  [31:0] time_set_lo = 32'd0, time_set_hi = 32'd0;

  assign rx_pkt_len = pkt_len;
  assign rx_enable = cfg[0];
  assign tx_late_drop = cfg[1];
  assign host0_rx_hdr = cfg[2];
  assign host0_tx_hdr = cfg[3];
  assign host1_rx_hdr = cfg[4];
  assign host1_tx_hdr = cfg[5];
  assign route = routes;
  assign port_reset = prst;
  reg         load_req = 1'b0;            // toggles to request a counter load
  reg         load_ack = 1'b0;            // l_clk: follows load_req once the load is done
  (* ASYNC_REG = "TRUE" *) reg [2:0] load_ack_s = 3'd0;
  wire        load_pending = load_req != load_ack_s[2];
  reg  [31:0] time_hi_latched = 32'd0;

  wire        wr_fire = waddr_ok && wdata_ok && !bvalid;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      awready <= 1'b0;
      wready <= 1'b0;
      bvalid <= 1'b0;
      waddr_ok <= 1'b0;
      wdata_ok <= 1'b0;
    end else begin
      awready <= !waddr_ok && !awready && s_axi_awvalid;
      wready <= !wdata_ok && !wready && s_axi_wvalid;
      if (awready && s_axi_awvalid) begin
        waddr <= s_axi_awaddr[12:0];
        waddr_ok <= 1'b1;
      end
      if (wready && s_axi_wvalid) begin
        wdata <= s_axi_wdata;
        wdata_ok <= 1'b1;
      end
      if (wr_fire) begin
        bvalid <= 1'b1;
        waddr_ok <= 1'b0;
        wdata_ok <= 1'b0;
      end else if (bvalid && s_axi_bready) begin
        bvalid <= 1'b0;
      end
    end
  end

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      scratch <= 32'd0;
      pkt_len <= 16'd4096;
      cfg <= 6'b000011;
      routes <= ROUTE_RESET;
      time_set_lo <= 32'd0;
      time_set_hi <= 32'd0;
      load_req <= 1'b0;
      prst <= 7'd0;
      prst_cnt <= 4'd0;
    end else begin
      if (prst_cnt != 4'd0)
        prst_cnt <= prst_cnt - 4'd1;
      else
        prst <= 7'd0;
      if (wr_fire) begin
      case (waddr[12:2])
        11'h003: scratch <= wdata;
        11'h014: if (wdata[15:0] != 16'd0) pkt_len <= wdata[15:0];
        11'h015: cfg <= wdata[5:0];
        11'h017: if (wdata[6:0] != 7'd0) begin prst <= wdata[6:0]; prst_cnt <= 4'hF; end
        11'h006: time_set_lo <= wdata;
        11'h007: time_set_hi <= wdata;
        11'h008: if (wdata[0] && !load_pending) load_req <= ~load_req;
        default: ;
      endcase
      if (waddr[12] && waddr[11:2] < N_SNK)
        routes[waddr[11:2]*4 +: 4] <= wdata[3:0];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // sample counter (l_clk)

  // Both handshakes compare the synchronised request with their own ack
  // rather than detecting request edges, so they recover by themselves if
  // the state is upset (l_clk glitches while the driver tunes the AD9361
  // data interface): an edge-detecting version deadlocked on the board.

  reg  [63:0] count = 64'd0;
  (* ASYNC_REG = "TRUE" *) reg [1:0] load_req_s = 2'd0;

  assign time_now = count;

  always @(posedge l_clk) begin
    load_req_s <= {load_req_s[0], load_req};
    if (adc_valid) begin
      if (load_req_s[1] != load_ack) begin
        count <= {time_set_hi, time_set_lo};   // quasi-static while the load is pending
        load_ack <= load_req_s[1];
      end else begin
        count <= count + 64'd1;
      end
    end
  end

  always @(posedge s_axi_aclk)
    load_ack_s <= {load_ack_s[1:0], load_ack};

  // snapshot handshake: the CPU side toggles snap_req, l_clk captures the
  // counter and toggles snap_ack, the CPU side then takes the snapshot

  reg         snap_req = 1'b0;
  (* ASYNC_REG = "TRUE" *) reg [1:0] snap_req_s = 2'd0;
  reg         snap_ack = 1'b0;
  reg  [63:0] snap = 64'd0;
  (* ASYNC_REG = "TRUE" *) reg [2:0] snap_ack_s = 3'd0;
  reg  [63:0] time_cpu = 64'd0;

  always @(posedge l_clk) begin
    snap_req_s <= {snap_req_s[0], snap_req};
    if (snap_req_s[1] != snap_ack) begin
      snap <= count;
      snap_ack <= snap_req_s[1];
    end
  end

  always @(posedge s_axi_aclk) begin
    snap_ack_s <= {snap_ack_s[1:0], snap_ack};
    if (snap_ack_s[2] == snap_req) begin
      time_cpu <= snap;                        // stable: l_clk updated it before toggling ack
      snap_req <= ~snap_req;
    end
  end

  // ---------------------------------------------------------------------------
  // status synchronisers

  (* ASYNC_REG = "TRUE" *) reg [7:0] ctrl_out_m1 = 8'd0, ctrl_out_s = 8'd0;
  always @(posedge s_axi_aclk) begin
    ctrl_out_m1 <= ctrl_out;
    ctrl_out_s <= ctrl_out_m1;
  end

  function [31:0] gray2bin(input [31:0] g);
    integer i;
    begin
      gray2bin[31] = g[31];
      for (i = 30; i >= 0; i = i - 1)
        gray2bin[i] = gray2bin[i + 1] ^ g[i];
    end
  endfunction

  (* ASYNC_REG = "TRUE" *) reg [31:0] ovf_g_m1 = 0, ovf_g_s = 0, unf_g_m1 = 0, unf_g_s = 0, late_g_m1 = 0, late_g_s = 0;
  (* ASYNC_REG = "TRUE" *) reg [31:0] herr_g_m1 = 0, herr_g_s = 0, rovf_g_m1 = 0, rovf_g_s = 0;
  (* ASYNC_REG = "TRUE" *) reg [31:0] herr1_g_m1 = 0, herr1_g_s = 0, rovf1_g_m1 = 0, rovf1_g_s = 0;
  reg  [31:0] rx_overflow = 0, tx_underflow = 0, tx_late = 0, host0_tx_err = 0, host0_rx_ovf = 0;
  reg  [31:0] host1_tx_err = 0, host1_rx_ovf = 0;
  always @(posedge s_axi_aclk) begin
    ovf_g_m1 <= rx_overflow_gray;
    ovf_g_s <= ovf_g_m1;
    unf_g_m1 <= tx_underflow_gray;
    unf_g_s <= unf_g_m1;
    late_g_m1 <= tx_late_gray;
    late_g_s <= late_g_m1;
    rx_overflow <= gray2bin(ovf_g_s);
    tx_underflow <= gray2bin(unf_g_s);
    tx_late <= gray2bin(late_g_s);
    herr_g_m1 <= host0_tx_err_gray;
    herr_g_s <= herr_g_m1;
    host0_tx_err <= gray2bin(herr_g_s);
    rovf_g_m1 <= host0_rx_ovf_gray;
    rovf_g_s <= rovf_g_m1;
    host0_rx_ovf <= gray2bin(rovf_g_s);
    herr1_g_m1 <= host1_tx_err_gray;
    herr1_g_s <= herr1_g_m1;
    host1_tx_err <= gray2bin(herr1_g_s);
    rovf1_g_m1 <= host1_rx_ovf_gray;
    rovf1_g_s <= rovf1_g_m1;
    host1_rx_ovf <= gray2bin(rovf1_g_s);
  end

  // ---------------------------------------------------------------------------
  // reads

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      arready <= 1'b0;
      rvalid <= 1'b0;
    end else begin
      arready <= !rvalid && !arready && s_axi_arvalid;
      if (arready && s_axi_arvalid) begin
        rvalid <= 1'b1;
        case (s_axi_araddr[12:2])
          11'h000: rdata <= ID;
          11'h001: rdata <= VERSION;
          11'h002: rdata <= {SLOTS, HOST_TX, HOST_RX, RF_CHANNELS};
          11'h003: rdata <= scratch;
          11'h004: begin
            rdata <= time_cpu[31:0];
            time_hi_latched <= time_cpu[63:32];
          end
          11'h005: rdata <= time_hi_latched;
          11'h006: rdata <= time_set_lo;
          11'h007: rdata <= time_set_hi;
          11'h008: rdata <= {31'd0, load_pending};
          11'h00C: rdata <= {24'd0, ctrl_out_s};
          11'h010: rdata <= rx_overflow;
          11'h011: rdata <= tx_underflow;
          11'h012: rdata <= tx_late;
          11'h014: rdata <= {16'd0, pkt_len};
          11'h013: rdata <= host0_tx_err;
          11'h016: rdata <= host0_rx_ovf;
          11'h015: rdata <= {26'd0, cfg};
          11'h018: rdata <= host1_tx_err;
          11'h019: rdata <= host1_rx_ovf;
          default: rdata <= (s_axi_araddr[12] && s_axi_araddr[11:2] < N_SNK) ?
                            {28'd0, routes[s_axi_araddr[11:2]*4 +: 4]} : 32'd0;
        endcase
      end else if (rvalid && s_axi_rready) begin
        rvalid <= 1'b0;
      end
    end
  end

endmodule
