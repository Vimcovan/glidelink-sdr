// ***************************************************************************
// GlideLink shell: one module slot, between the shell (CPU clock registers,
// processing-clock stream switch) and the module in it (docs/phase4_plan.md
// G2). The module runs on the processing clock (ASYNC = 0) or on its own
// clock slot_clk (ASYNC = 1):
//   registers   the AXI4-Lite bridge from the CPU clock into the module's clock
//   stream in   ASYNC = 0: a skid buffer (its ready is a register, so a module
//               whose s_axis_tready follows its m_axis_tready combinationally,
//               as AXI4-Stream allows, closes no loop through the switch);
//               ASYNC = 1: a small asynchronous FIFO (its ready is a register too)
//   stream out  ASYNC = 0: straight to the switch; ASYNC = 1: asynchronous FIFO
//   resets      the module's rstn and flush, synchronised into its clock; a
//               flush also empties the slot's own buffers
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_slot #(
  parameter ASYNC = 0,
  parameter CDC_ADDR_WIDTH = 5              // asynchronous stream FIFOs, 32 beats (LUTRAM)
) (
  // shell side, CPU clock
  input             s_axi_aclk,
  input             s_axi_aresetn,
  input             s_awvalid,
  output            s_awready,
  input     [11:0]  s_awaddr,
  input             s_wvalid,
  output            s_wready,
  input     [31:0]  s_wdata,
  output            s_bvalid,
  input             s_bready,
  input             s_arvalid,
  output            s_arready,
  input     [11:0]  s_araddr,
  output            s_rvalid,
  input             s_rready,
  output    [31:0]  s_rdata,

  // shell side, processing clock: from the switch (sink) and to it (source)
  input             clk,
  input             rstn,
  input             flush,                  // PORT_RESET for this slot
  input             snk_valid,
  output            snk_ready,
  input    [104:0]  snk_data,               // {last, user[71:0], data[31:0]}
  output            src_valid,
  input             src_ready,
  output   [104:0]  src_data,

  // module side, in the module's clock
  input             slot_clk,               // used when ASYNC = 1
  output            m_clk,
  output            m_rstn,
  output            m_flush,
  output            m_awvalid,
  input             m_awready,
  output    [11:0]  m_awaddr,
  output            m_wvalid,
  input             m_wready,
  output    [31:0]  m_wdata,
  input             m_bvalid,
  output            m_bready,
  output            m_arvalid,
  input             m_arready,
  output    [11:0]  m_araddr,
  input             m_rvalid,
  output            m_rready,
  input     [31:0]  m_rdata,
  output            mod_in_valid,
  input             mod_in_ready,
  output   [104:0]  mod_in_data,
  input             mod_out_valid,
  output            mod_out_ready,
  input    [104:0]  mod_out_data
);

  assign m_clk = ASYNC ? slot_clk : clk;

  // resets into the module's clock
  (* ASYNC_REG = "TRUE" *) reg [1:0] rstn_s = 2'b00, flush_s = 2'b00;
  always @(posedge m_clk) begin
    rstn_s <= {rstn_s[0], rstn};
    flush_s <= {flush_s[0], flush};
  end
  assign m_rstn = ASYNC ? rstn_s[1] : rstn;
  assign m_flush = ASYNC ? flush_s[1] : flush;

  glidelink_axil_cdc i_cdc (
    .s_clk(s_axi_aclk), .s_rstn(s_axi_aresetn),
    .s_awvalid(s_awvalid), .s_awready(s_awready), .s_awaddr(s_awaddr),
    .s_wvalid(s_wvalid), .s_wready(s_wready), .s_wdata(s_wdata),
    .s_bvalid(s_bvalid), .s_bready(s_bready),
    .s_arvalid(s_arvalid), .s_arready(s_arready), .s_araddr(s_araddr),
    .s_rvalid(s_rvalid), .s_rready(s_rready), .s_rdata(s_rdata),
    .m_clk(m_clk), .m_rstn(m_rstn),
    .m_awvalid(m_awvalid), .m_awready(m_awready), .m_awaddr(m_awaddr),
    .m_wvalid(m_wvalid), .m_wready(m_wready), .m_wdata(m_wdata),
    .m_bvalid(m_bvalid), .m_bready(m_bready),
    .m_arvalid(m_arvalid), .m_arready(m_arready), .m_araddr(m_araddr),
    .m_rvalid(m_rvalid), .m_rready(m_rready), .m_rdata(m_rdata));

  generate
    if (ASYNC) begin : g_async
      wire in_full, in_empty, out_full, out_empty;

      glidelink_async_fifo #(.WIDTH(105), .ADDR_WIDTH(CDC_ADDR_WIDTH), .RAM_STYLE("distributed")) i_cdc_fifo_in (
        .wr_clk(clk), .wr_rst(!rstn || flush), .wr_en(snk_valid), .wr_data(snk_data),
        .wr_full(in_full), .wr_level(), .wr_in_reset(),
        .rd_clk(slot_clk), .rd_rst(!m_rstn), .rd_en(mod_in_valid && mod_in_ready),
        .rd_data(mod_in_data), .rd_empty(in_empty), .rd_level(), .rd_in_reset());
      assign snk_ready = !in_full;
      assign mod_in_valid = !in_empty;

      glidelink_async_fifo #(.WIDTH(105), .ADDR_WIDTH(CDC_ADDR_WIDTH), .RAM_STYLE("distributed")) i_cdc_fifo_out (
        .wr_clk(slot_clk), .wr_rst(!m_rstn), .wr_en(mod_out_valid), .wr_data(mod_out_data),
        .wr_full(out_full), .wr_level(), .wr_in_reset(),
        .rd_clk(clk), .rd_rst(!rstn || flush), .rd_en(src_valid && src_ready),
        .rd_data(src_data), .rd_empty(out_empty), .rd_level(), .rd_in_reset());
      assign mod_out_ready = !out_full;
      assign src_valid = !out_empty;
    end else begin : g_sync
      glidelink_skid #(.W(105)) i_skid (
        .clk(clk), .rst(!rstn || flush),
        .s_valid(snk_valid), .s_ready(snk_ready), .s_data(snk_data),
        .m_valid(mod_in_valid), .m_ready(mod_in_ready), .m_data(mod_in_data));
      assign src_valid = mod_out_valid;
      assign mod_out_ready = src_ready;
      assign src_data = mod_out_data;
    end
  endgenerate

endmodule
