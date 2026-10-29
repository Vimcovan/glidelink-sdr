// ***************************************************************************
// GlideLink shell: AXI4-Lite address demultiplexer (one transaction at a time)
//
//   0x0000-0x1FFF  -> port 0 (shell registers and switch routes)
//   0x2000+0x1000k -> port k+1 (slot k), k < N_PORTS-1
// Other addresses read 0 and ignore writes. Store and forward: each request
// is latched, issued to the selected port, and its response returned.
// Ports share the address / data lines; addresses are passed as [15:0].
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_axil_demux #(
  parameter N_PORTS = 2
) (
  input                       clk,
  input                       rstn,

  input                       s_awvalid,
  output reg                  s_awready = 1'b0,
  input       [15:0]          s_awaddr,
  input                       s_wvalid,
  output reg                  s_wready = 1'b0,
  input       [31:0]          s_wdata,
  input        [3:0]          s_wstrb,
  output reg                  s_bvalid = 1'b0,
  input                       s_bready,
  output       [1:0]          s_bresp,
  input                       s_arvalid,
  output reg                  s_arready = 1'b0,
  input       [15:0]          s_araddr,
  output reg                  s_rvalid = 1'b0,
  input                       s_rready,
  output       [1:0]          s_rresp,
  output reg  [31:0]          s_rdata = 32'd0,

  output reg  [15:0]          m_awaddr = 16'd0,
  output      [N_PORTS-1:0]   m_awvalid,
  input       [N_PORTS-1:0]   m_awready,
  output reg  [31:0]          m_wdata = 32'd0,
  output reg   [3:0]          m_wstrb = 4'd0,
  output      [N_PORTS-1:0]   m_wvalid,
  input       [N_PORTS-1:0]   m_wready,
  input       [N_PORTS-1:0]   m_bvalid,
  output      [N_PORTS-1:0]   m_bready,
  output reg  [15:0]          m_araddr = 16'd0,
  output      [N_PORTS-1:0]   m_arvalid,
  input       [N_PORTS-1:0]   m_arready,
  input       [N_PORTS-1:0]   m_rvalid,
  output      [N_PORTS-1:0]   m_rready,
  input       [N_PORTS*32-1:0] m_rdata
);

  assign s_bresp = 2'b00;
  assign s_rresp = 2'b00;

  function [7:0] decode(input [15:0] a);     // port index, 8'hFF = none
    begin
      if (a[15:13] == 3'd0)
        decode = 8'd0;
      else if (a[15:12] - 4'd1 < N_PORTS)
        decode = a[15:12] - 4'd1;
      else
        decode = 8'hFF;
    end
  endfunction

  // write: 0 take address and data, 1 issue, 2 wait response, 3 respond
  // read:  0 take address, 1 issue, 2 wait data, 3 respond

  reg  [1:0]  ws = 2'd0, rs = 2'd0;
  reg  [7:0]  wport = 8'd0, rport = 8'd0;
  reg         aw_ok = 1'b0, w_ok = 1'b0, aw_sent = 1'b0, w_sent = 1'b0;

  genvar g;
  generate
    for (g = 0; g < N_PORTS; g = g + 1) begin : g_port
      assign m_awvalid[g] = ws == 2'd1 && wport == g && !aw_sent;
      assign m_wvalid[g] = ws == 2'd1 && wport == g && !w_sent;
      assign m_bready[g] = ws == 2'd2 && wport == g;
      assign m_arvalid[g] = rs == 2'd1 && rport == g;
      assign m_rready[g] = rs == 2'd2 && rport == g;
    end
  endgenerate

  always @(posedge clk) begin
    if (!rstn) begin
      ws <= 2'd0; aw_ok <= 1'b0; w_ok <= 1'b0;
      s_awready <= 1'b0; s_wready <= 1'b0; s_bvalid <= 1'b0;
    end else begin
      s_awready <= 1'b0;
      s_wready <= 1'b0;
      case (ws)
        2'd0: begin
          if (s_awvalid && !aw_ok && !s_awready) begin
            s_awready <= 1'b1;
            aw_ok <= 1'b1;
            m_awaddr <= s_awaddr;
            wport <= decode(s_awaddr);
          end
          if (s_wvalid && !w_ok && !s_wready) begin
            s_wready <= 1'b1;
            w_ok <= 1'b1;
            m_wdata <= s_wdata;
            m_wstrb <= s_wstrb;
          end
          if (aw_ok && w_ok) begin
            aw_ok <= 1'b0;
            w_ok <= 1'b0;
            aw_sent <= 1'b0;
            w_sent <= 1'b0;
            ws <= wport == 8'hFF ? 2'd3 : 2'd1;
          end
        end
        2'd1: begin
          if (m_awready[wport]) aw_sent <= 1'b1;
          if (m_wready[wport]) w_sent <= 1'b1;
          if ((aw_sent || m_awready[wport]) && (w_sent || m_wready[wport])) ws <= 2'd2;
        end
        2'd2: if (m_bvalid[wport]) ws <= 2'd3;
        2'd3: begin
          if (!s_bvalid) s_bvalid <= 1'b1;
          else if (s_bready) begin s_bvalid <= 1'b0; ws <= 2'd0; end
        end
      endcase
    end
  end

  always @(posedge clk) begin
    if (!rstn) begin
      rs <= 2'd0; s_arready <= 1'b0; s_rvalid <= 1'b0;
    end else begin
      s_arready <= 1'b0;
      case (rs)
        2'd0: if (s_arvalid && !s_arready) begin
          s_arready <= 1'b1;
          m_araddr <= s_araddr;
          rport <= decode(s_araddr);
          s_rdata <= 32'd0;
          rs <= decode(s_araddr) == 8'hFF ? 2'd3 : 2'd1;
        end
        2'd1: if (m_arready[rport]) rs <= 2'd2;
        2'd2: if (m_rvalid[rport]) begin s_rdata <= m_rdata[rport*32 +: 32]; rs <= 2'd3; end
        2'd3: begin
          if (!s_rvalid) s_rvalid <= 1'b1;
          else if (s_rready) begin s_rvalid <= 1'b0; rs <= 2'd0; end
        end
      endcase
    end
  end

endmodule
