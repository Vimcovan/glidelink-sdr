// ***************************************************************************
// GlideLink user modules: AXI4-Lite slave for a module's 4 KB register window
// (docs/design.md 5.2), so that a module only decodes addresses.
//
// Writes: wr_en pulses for one cycle with wr_addr (byte address) / wr_data.
// Reads: the module drives rd_data combinationally from rd_addr; it is
// sampled one cycle after the address is taken. The standard registers
// (0x000 ID, 0x004 VERSION, 0x008 CONTROL, 0x00C STATUS) are the module's
// own to decode like any other.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_module_axil (
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

  output            wr_en,
  output    [11:0]  wr_addr,
  output    [31:0]  wr_data,
  output    [11:0]  rd_addr,
  input     [31:0]  rd_data
);

  reg         awready = 1'b0, wready = 1'b0, bvalid = 1'b0, arready = 1'b0, rvalid = 1'b0;
  reg         waddr_ok = 1'b0, wdata_ok = 1'b0, rpend = 1'b0;
  reg  [11:0] waddr = 12'd0, raddr = 12'd0;
  reg  [31:0] wdata = 32'd0, rdata = 32'd0;
  wire        wr_fire = waddr_ok && wdata_ok && !bvalid;

  assign s_axil_awready = awready;
  assign s_axil_wready = wready;
  assign s_axil_bvalid = bvalid;
  assign s_axil_arready = arready;
  assign s_axil_rvalid = rvalid;
  assign s_axil_rdata = rdata;
  assign wr_en = wr_fire;
  assign wr_addr = waddr;
  assign wr_data = wdata;
  assign rd_addr = raddr;

  always @(posedge clk) begin
    if (!rstn) begin
      awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; waddr_ok <= 1'b0; wdata_ok <= 1'b0;
      arready <= 1'b0; rvalid <= 1'b0; rpend <= 1'b0;
    end else begin
      awready <= !waddr_ok && !awready && s_axil_awvalid;
      wready <= !wdata_ok && !wready && s_axil_wvalid;
      if (awready && s_axil_awvalid) begin waddr <= s_axil_awaddr; waddr_ok <= 1'b1; end
      if (wready && s_axil_wvalid) begin wdata <= s_axil_wdata; wdata_ok <= 1'b1; end
      if (wr_fire) begin
        bvalid <= 1'b1; waddr_ok <= 1'b0; wdata_ok <= 1'b0;
      end else if (bvalid && s_axil_bready) begin
        bvalid <= 1'b0;
      end

      arready <= !rvalid && !rpend && !arready && s_axil_arvalid;
      if (arready && s_axil_arvalid) begin
        raddr <= s_axil_araddr;
        rpend <= 1'b1;
      end
      if (rpend) begin
        rdata <= rd_data;
        rvalid <= 1'b1;
        rpend <= 1'b0;
      end else if (rvalid && s_axil_rready) begin
        rvalid <= 1'b0;
      end
    end
  end

endmodule
