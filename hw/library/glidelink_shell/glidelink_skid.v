// ***************************************************************************
// GlideLink shell: two-entry buffer (skid buffer) in front of each slot's
// input. Its s_ready is a register, so whatever a module does between its
// m_axis_tready and s_axis_tready (AXI4-Stream allows a combinational path)
// cannot close a loop through the stream switch, where a slot's output and
// input meet in the same multiplexers. Adds one cycle of latency.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_skid #(
  parameter W = 105                         // {last, user, data}
) (
  input             clk,
  input             rst,

  input             s_valid,
  output            s_ready,
  input   [W-1:0]   s_data,

  output            m_valid,
  input             m_ready,
  output  [W-1:0]   m_data
);

  reg  [W-1:0] main = {W{1'b0}}, spare = {W{1'b0}};
  reg          main_v = 1'b0, spare_v = 1'b0;

  assign s_ready = !spare_v;
  assign m_valid = main_v;
  assign m_data = main;

  wire         in_beat = s_valid && !spare_v;

  always @(posedge clk) begin
    if (rst) begin
      main_v <= 1'b0;
      spare_v <= 1'b0;
    end else if (m_ready || !main_v) begin
      if (spare_v) begin
        main <= spare;
        main_v <= 1'b1;
        spare_v <= in_beat;
        spare <= s_data;
      end else begin
        main <= s_data;
        main_v <= in_beat;
      end
    end else if (in_beat) begin
      spare <= s_data;
      spare_v <= 1'b1;
    end
  end

endmodule
