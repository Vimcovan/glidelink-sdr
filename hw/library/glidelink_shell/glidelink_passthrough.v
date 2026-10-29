// ***************************************************************************
// GlideLink user module: passthrough (slot 0; also the template for modules,
// docs/design.md section 5)
//
// Registers (4 KB window):
//   0x000  ID       RO  0x50535448 ("PSTH")
//   0x004  VERSION  RO  {major[15:0], minor[7:0], patch[7:0]}
//   0x008  CONTROL  RW  bit 0: enable (default 1; disabled = input dropped),
//                       bit 1: soft reset (self-clearing; clears the counters)
//   0x00C  STATUS   RO  bit 0: enabled
//   0x010  PACKETS  RO  packets passed (tlast beats)
//   0x014  BEATS    RO  beats passed
// Stream: two-entry skid buffer, so the module adds one cycle of latency and
// both sides may be back-pressured, as a real module would.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_passthrough (
  input             clk,
  input             rstn,

  input             s_axil_awvalid,
  output            s_axil_awready,
  input     [11:0]  s_axil_awaddr,
  input             s_axil_wvalid,
  output            s_axil_wready,
  input     [31:0]  s_axil_wdata,
  output            s_axil_bvalid,
  input             s_axil_bready,
  input             s_axil_arvalid,
  output            s_axil_arready,
  input     [11:0]  s_axil_araddr,
  output            s_axil_rvalid,
  input             s_axil_rready,
  output    [31:0]  s_axil_rdata,

  input             s_axis_tvalid,
  output            s_axis_tready,
  input     [31:0]  s_axis_tdata,
  input     [71:0]  s_axis_tuser,
  input             s_axis_tlast,

  output            m_axis_tvalid,
  input             m_axis_tready,
  output    [31:0]  m_axis_tdata,
  output    [71:0]  m_axis_tuser,
  output            m_axis_tlast
);

  localparam [31:0] ID = 32'h50535448;
  localparam [31:0] VERSION = 32'h00010000;

  // ---------------------------------------------------------------------------
  // registers

  reg         enable = 1'b1, soft_rst = 1'b0;
  reg  [31:0] packets = 32'd0, beats = 32'd0;
  reg         awready = 1'b0, wready = 1'b0, bvalid = 1'b0, arready = 1'b0, rvalid = 1'b0;
  reg  [11:0] waddr = 12'd0;
  reg         waddr_ok = 1'b0, wdata_ok = 1'b0;
  reg  [31:0] wdata = 32'd0, rdata = 32'd0;
  wire        wr_fire = waddr_ok && wdata_ok && !bvalid;

  assign s_axil_awready = awready;
  assign s_axil_wready = wready;
  assign s_axil_bvalid = bvalid;
  assign s_axil_arready = arready;
  assign s_axil_rvalid = rvalid;
  assign s_axil_rdata = rdata;

  always @(posedge clk) begin
    if (!rstn) begin
      awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; waddr_ok <= 1'b0; wdata_ok <= 1'b0;
      arready <= 1'b0; rvalid <= 1'b0;
      enable <= 1'b1; soft_rst <= 1'b0;
    end else begin
      awready <= !waddr_ok && !awready && s_axil_awvalid;
      wready <= !wdata_ok && !wready && s_axil_wvalid;
      if (awready && s_axil_awvalid) begin waddr <= s_axil_awaddr; waddr_ok <= 1'b1; end
      if (wready && s_axil_wvalid) begin wdata <= s_axil_wdata; wdata_ok <= 1'b1; end
      soft_rst <= 1'b0;
      if (wr_fire) begin
        bvalid <= 1'b1; waddr_ok <= 1'b0; wdata_ok <= 1'b0;
        if (waddr[11:2] == 10'h002) begin
          enable <= wdata[0];
          soft_rst <= wdata[1];
        end
      end else if (bvalid && s_axil_bready) begin
        bvalid <= 1'b0;
      end

      arready <= !rvalid && !arready && s_axil_arvalid;
      if (arready && s_axil_arvalid) begin
        rvalid <= 1'b1;
        case (s_axil_araddr[11:2])
          10'h000: rdata <= ID;
          10'h001: rdata <= VERSION;
          10'h002: rdata <= {31'd0, enable};
          10'h003: rdata <= {31'd0, enable};
          10'h004: rdata <= packets;
          10'h005: rdata <= beats;
          default: rdata <= 32'd0;
        endcase
      end else if (rvalid && s_axil_rready) begin
        rvalid <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // stream: skid buffer (main register + one spare)

  wire        rst = !rstn || soft_rst;
  reg  [104:0] main = 105'd0, spare = 105'd0;     // {last, user, data}
  reg         main_v = 1'b0, spare_v = 1'b0;

  assign s_axis_tready = !enable || !spare_v;
  assign m_axis_tvalid = main_v;
  assign {m_axis_tlast, m_axis_tuser, m_axis_tdata} = main;

  wire        in_beat = s_axis_tvalid && s_axis_tready && enable;
  wire        out_beat = main_v && m_axis_tready;

  always @(posedge clk) begin
    if (rst) begin
      main_v <= 1'b0;
      spare_v <= 1'b0;
    end else begin
      if (out_beat || !main_v) begin
        if (spare_v) begin
          main <= spare;
          main_v <= 1'b1;
          spare_v <= in_beat;
          spare <= {s_axis_tlast, s_axis_tuser, s_axis_tdata};
        end else begin
          main <= {s_axis_tlast, s_axis_tuser, s_axis_tdata};
          main_v <= in_beat;
        end
      end else if (in_beat) begin
        spare <= {s_axis_tlast, s_axis_tuser, s_axis_tdata};
        spare_v <= 1'b1;
      end
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      packets <= 32'd0;
      beats <= 32'd0;
    end else if (out_beat) begin
      beats <= beats + 32'd1;
      if (m_axis_tlast)
        packets <= packets + 32'd1;
    end
  end

endmodule
