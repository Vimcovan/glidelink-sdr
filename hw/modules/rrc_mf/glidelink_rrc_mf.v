// ***************************************************************************
// GlideLink user module: RRC matched filter (Xilinx FIR Compiler).
// RX: before the symbol sync. Description: module.yaml; reference model: model.py.
// The filter is the IP ip/rrc_mf.xci (FIR Compiler, fixed coefficients from
// ip/rrc_mf.coe); hw/modules/fir_fixed/glidelink_fir_fixed.v around it.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_rrc_mf (
  input             clk,
  input             rstn,
  input             flush,                  // stream state only (PORT_RESET): registers kept

  // registers (module.yaml; the register file is generated)
  input             enable,                 // CONTROL[0]
  input             soft_reset,             // CONTROL[1], one cycle per write of 1
  output            enabled,                // STATUS[0]

  input             s_axis_tvalid,
  output            s_axis_tready,
  input     [31:0]  s_axis_tdata,

  output            m_axis_tvalid,
  input             m_axis_tready,
  output    [31:0]  m_axis_tdata
);

  localparam OW = 32;                       // the IP's output width (make_fir_ip.tcl prints it)
  localparam OWP = (OW + 7) / 8 * 8;        // each path byte-aligned in tdata

  wire             ip_aresetn, ip_s_tvalid, ip_s_tready, ip_m_tvalid, ip_m_tready;
  wire [31:0]      ip_s_tdata;
  wire [2*OWP-1:0] ip_m_tdata;

  assign enabled = enable;

  rrc_mf i_ip (
    .aclk(clk),
    .aresetn(ip_aresetn),
    .s_axis_data_tvalid(ip_s_tvalid),
    .s_axis_data_tready(ip_s_tready),
    .s_axis_data_tdata(ip_s_tdata),
    .m_axis_data_tvalid(ip_m_tvalid),
    .m_axis_data_tready(ip_m_tready),
    .m_axis_data_tdata(ip_m_tdata)
  );

  glidelink_fir_fixed #(.SHIFT(15), .OWP(OWP), .OW(OW)) i_wrap (
    .clk(clk), .rstn(rstn), .flush(flush), .enable(enable), .soft_reset(soft_reset),
    .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .s_axis_tdata(s_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tdata(m_axis_tdata),
    .ip_aresetn(ip_aresetn), .ip_s_tvalid(ip_s_tvalid), .ip_s_tready(ip_s_tready), .ip_s_tdata(ip_s_tdata),
    .ip_m_tvalid(ip_m_tvalid), .ip_m_tready(ip_m_tready), .ip_m_tdata(ip_m_tdata));

endmodule
