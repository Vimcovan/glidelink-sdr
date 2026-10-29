// ***************************************************************************
// GlideLink shell: AXI4-Lite clock-domain bridge (one transaction at a time)
//
// Carries register accesses from the CPU clock (s_*) to a slot's processing
// clock (m_*). The request (write address/data or read address) is latched
// in the s domain and handed over with a toggle; the m side performs it on
// its AXI4-Lite port and hands the response back with a second toggle. Both
// sides compare the synchronised toggle with their own (no edge detection),
// so a disturbed state recovers by itself. Addresses are [11:0].
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_axil_cdc (
  input             s_clk,
  input             s_rstn,
  input             s_awvalid,
  output reg        s_awready = 1'b0,
  input     [11:0]  s_awaddr,
  input             s_wvalid,
  output reg        s_wready = 1'b0,
  input     [31:0]  s_wdata,
  output reg        s_bvalid = 1'b0,
  input             s_bready,
  input             s_arvalid,
  output reg        s_arready = 1'b0,
  input     [11:0]  s_araddr,
  output reg        s_rvalid = 1'b0,
  input             s_rready,
  output reg [31:0] s_rdata = 32'd0,

  input             m_clk,
  input             m_rstn,
  output reg        m_awvalid = 1'b0,
  input             m_awready,
  output    [11:0]  m_awaddr,
  output reg        m_wvalid = 1'b0,
  input             m_wready,
  output    [31:0]  m_wdata,
  input             m_bvalid,
  output reg        m_bready = 1'b0,
  output reg        m_arvalid = 1'b0,
  input             m_arready,
  output    [11:0]  m_araddr,
  input             m_rvalid,
  output reg        m_rready = 1'b0,
  input     [31:0]  m_rdata
);

  // ---------------------------------------------------------------------------
  // s side: latch one request, toggle req, wait for ack == req

  reg  [11:0] addr = 12'd0;
  reg  [31:0] wdata = 32'd0;
  reg         is_write = 1'b0;
  reg         req = 1'b0;
  reg         busy = 1'b0;
  reg         have_aw = 1'b0, have_w = 1'b0;
  wire        ack_s;
  reg  [31:0] resp_data = 32'd0;   // m side: read data, written before ack toggles

  assign m_awaddr = addr;          // stable while the request is pending
  assign m_araddr = addr;
  assign m_wdata = wdata;

  always @(posedge s_clk) begin
    if (!s_rstn) begin
      s_awready <= 1'b0; s_wready <= 1'b0; s_bvalid <= 1'b0;
      s_arready <= 1'b0; s_rvalid <= 1'b0;
      busy <= 1'b0; have_aw <= 1'b0; have_w <= 1'b0;
    end else begin
      s_awready <= 1'b0;
      s_wready <= 1'b0;
      s_arready <= 1'b0;
      if (!busy && !s_bvalid && !s_rvalid) begin
        if (s_awvalid && !have_aw && !s_awready && !s_arready) begin
          s_awready <= 1'b1; have_aw <= 1'b1; addr <= s_awaddr;
        end
        if (s_wvalid && !have_w && !s_wready) begin
          s_wready <= 1'b1; have_w <= 1'b1; wdata <= s_wdata;
        end
        if (have_aw && have_w) begin
          have_aw <= 1'b0; have_w <= 1'b0;
          is_write <= 1'b1; busy <= 1'b1; req <= ~req;
        end else if (!have_aw && !have_w && s_arvalid && !s_arready && !s_awvalid) begin
          s_arready <= 1'b1; addr <= s_araddr;
          is_write <= 1'b0; busy <= 1'b1; req <= ~req;
        end
      end else if (busy && ack_s == req) begin
        busy <= 1'b0;
        if (is_write) s_bvalid <= 1'b1;
        else begin s_rvalid <= 1'b1; s_rdata <= resp_data; end   // written before ack toggled
      end
      if (s_bvalid && s_bready) s_bvalid <= 1'b0;
      if (s_rvalid && s_rready) s_rvalid <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // m side: when the synchronised req differs from ack, run the transaction

  (* ASYNC_REG = "TRUE" *) reg [1:0] req_m = 2'b00;
  reg         ack = 1'b0;
  reg         running = 1'b0;
  reg         aw_done = 1'b0, w_done = 1'b0;

  always @(posedge m_clk) begin
    req_m <= {req_m[0], req};
    if (!m_rstn) begin
      m_awvalid <= 1'b0; m_wvalid <= 1'b0; m_bready <= 1'b0;
      m_arvalid <= 1'b0; m_rready <= 1'b0;
      running <= 1'b0;
      ack <= req_m[1];               // nothing pending after reset
    end else if (!running) begin
      if (req_m[1] != ack) begin
        running <= 1'b1;
        aw_done <= 1'b0; w_done <= 1'b0;
        if (is_write) begin           // is_write is stable while req is pending
          m_awvalid <= 1'b1; m_wvalid <= 1'b1; m_bready <= 1'b1;
        end else begin
          m_arvalid <= 1'b1; m_rready <= 1'b1;
        end
      end
    end else begin
      if (m_awvalid && m_awready) m_awvalid <= 1'b0;
      if (m_wvalid && m_wready) m_wvalid <= 1'b0;
      if (m_arvalid && m_arready) m_arvalid <= 1'b0;
      if (m_bready && m_bvalid) begin
        m_bready <= 1'b0; running <= 1'b0; ack <= req_m[1];
      end
      if (m_rready && m_rvalid) begin
        m_rready <= 1'b0; running <= 1'b0; ack <= req_m[1]; resp_data <= m_rdata;
      end
    end
  end

  (* ASYNC_REG = "TRUE" *) reg [1:0] ack_m = 2'b00;
  always @(posedge s_clk)
    ack_m <= {ack_m[0], ack};
  assign ack_s = ack_m[1];

endmodule
