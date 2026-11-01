// ***************************************************************************
// GlideLink: the part shared by the fixed-coefficient FIR modules (rrc_interp,
// lp_decim, rrc_mf) around their Xilinx FIR Compiler IP: bypass, the IP's
// reset, rounding / shift / saturation. Reference arithmetic: fir_fixed.py.
//
//   - The IP: I and Q as its two paths (input {Q, I}, 16 bits each), full
//     precision out, each path OWP bits wide in tdata (OW of them used); its
//     own interpolation or decimation (decimation: it keeps its inputs 0, M,
//     2M, ... counted from its reset).
//   - out = sat16((y + 2^(SHIFT-1)) >>> SHIFT) on each path.
//   - Soft reset and flush: the IP is reset; nothing goes in or out meanwhile.
//   - Disabled: samples pass unchanged and do not enter the IP.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_fir_fixed #(
  parameter SHIFT = 15,
  parameter OWP = 40,
  parameter OW = 37
) (
  input                clk,
  input                rstn,
  input                flush,
  input                enable,
  input                soft_reset,

  input                s_axis_tvalid,
  output               s_axis_tready,
  input       [31:0]   s_axis_tdata,

  output               m_axis_tvalid,
  input                m_axis_tready,
  output      [31:0]   m_axis_tdata,

  output reg           ip_aresetn = 1'b0,
  output               ip_s_tvalid,
  input                ip_s_tready,
  output      [31:0]   ip_s_tdata,
  input                ip_m_tvalid,
  output               ip_m_tready,
  input  [2*OWP-1:0]   ip_m_tdata
);

  wire        rst = !rstn || soft_reset || flush;

  // ---------------------------------------------------------------------------
  // the IP's reset: aresetn low for 8 cycles, then 16 for its start-up

  reg   [4:0] rcnt = 5'd0;
  reg         up = 1'b0;                    // the IP running
  always @(posedge clk) begin
    if (rst) begin
      rcnt <= 5'd0;
      up <= 1'b0;
      ip_aresetn <= 1'b0;
    end else if (!up) begin
      rcnt <= rcnt + 5'd1;
      if (rcnt == 5'd7)
        ip_aresetn <= 1'b1;
      if (rcnt == 5'd23)
        up <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // input: into the IP, or the bypass

  reg         o_valid = 1'b0;
  reg  [31:0] o_data = 32'd0;
  wire        o_free = !o_valid || m_axis_tready;
  wire        byp_take = !enable && up && s_axis_tvalid && o_free;

  assign ip_s_tvalid = enable && up && s_axis_tvalid;
  assign ip_s_tdata = s_axis_tdata;
  assign s_axis_tready = up && (enable ? ip_s_tready : o_free);

  // ---------------------------------------------------------------------------
  // output: rounding, output register

  wire signed [OWP-1:0] yi = ip_m_tdata[OWP-1:0], yq = ip_m_tdata[2*OWP-1:OWP];
  localparam signed [OWP-1:0] RND = SHIFT == 0 ? 0 : ({{(OWP-1){1'b0}}, 1'b1} << (SHIFT - 1));

  function [15:0] sat;
    input signed [OWP-1:0] x;
    reg signed [OWP-1:0] y;
    begin
      y = (x + RND) >>> SHIFT;
      sat = y > 32767 ? 16'h7FFF : y < -32768 ? 16'h8000 : y[15:0];
    end
  endfunction

  // the IP's outputs carry the sign in bit OW-1; extend it over the padding
  wire signed [OWP-1:0] yie = {{(OWP-OW){yi[OW-1]}}, yi[OW-1:0]};
  wire signed [OWP-1:0] yqe = {{(OWP-OW){yq[OW-1]}}, yq[OW-1:0]};

  assign ip_m_tready = enable && up && o_free;
  wire        out_take = ip_m_tvalid && ip_m_tready;

  assign m_axis_tvalid = o_valid;
  assign m_axis_tdata = o_data;

  always @(posedge clk) begin
    if (o_valid && m_axis_tready)
      o_valid <= 1'b0;
    if (rst) begin
      o_valid <= 1'b0;
    end else if (byp_take) begin
      o_valid <= 1'b1;
      o_data <= s_axis_tdata;
    end else if (out_take) begin
      o_valid <= 1'b1;
      o_data <= {sat(yqe), sat(yie)};
    end
  end

endmodule
