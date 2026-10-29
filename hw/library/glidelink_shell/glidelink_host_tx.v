// ***************************************************************************
// GlideLink shell: host TX port adapter (axi_dmac -> switch, processing clock)
//
// Header mode (hdr_en = 1): the stream from memory is a sequence of packets,
// each four header words (as glidelink_host_rx) followed by length samples:
//   word 0  {8'hA5, flags[7:0], length[15:0]}   flags bit 0 timed, bit 1 end of burst
//   word 1  sequence number (not checked)
//   word 2 / 3  send time [31:0] / [63:32]
// They become switch packets with tuser = {flags, time} and tlast on the last
// sample. A word where a header should start that is not one (wrong magic or
// length 0) is dropped and counted in errors (Gray-coded), and parsing tries
// again with the next word.
// Raw mode (hdr_en = 0): words pass through, each DMA transfer (tlast from
// axi_dmac) one untimed packet that does not end a burst.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_host_tx (
  input             clk,
  input             rst,
  input             hdr_en,                 // quasi-static; change only while idle

  input             s_valid,
  output            s_ready,
  input     [31:0]  s_data,
  input             s_last,

  output            m_valid,
  input             m_ready,
  output    [31:0]  m_data,
  output    [71:0]  m_user,
  output            m_last,

  output    [31:0]  errors_gray
);

  reg  [2:0]  hw = 3'd0;                    // 0..3 header word, 4 samples
  reg  [7:0]  flags = 8'd0;
  reg  [15:0] left = 16'd0;
  reg  [63:0] t = 64'd0;
  reg  [31:0] errors = 32'd0, errors_g = 32'd0;

  wire        sending = hw == 3'd4;
  wire        in_beat = s_valid && s_ready;
  wire        hdr_ok = s_data[31:24] == 8'hA5 && s_data[15:0] != 16'd0;

  assign s_ready = hdr_en && !sending ? 1'b1 : m_ready;      // header words are always taken
  assign m_valid = hdr_en ? (sending && s_valid) : s_valid;
  assign m_data = s_data;
  assign m_user = hdr_en ? {flags, t} : 72'd0;
  assign m_last = hdr_en ? left == 16'd1 : s_last;
  assign errors_gray = errors_g;

  always @(posedge clk) begin
    if (rst) begin
      hw <= 3'd0;
    end else if (hdr_en && in_beat) begin
      case (hw)
        3'd0: if (hdr_ok) begin
                flags <= s_data[23:16];
                left <= s_data[15:0];
                hw <= 3'd1;
              end else begin
                errors <= errors + 32'd1;
              end
        3'd1: hw <= 3'd2;
        3'd2: begin t[31:0] <= s_data; hw <= 3'd3; end
        3'd3: begin t[63:32] <= s_data; hw <= 3'd4; end
        default: begin
          left <= left - 16'd1;
          if (left == 16'd1) hw <= 3'd0;
        end
      endcase
    end
    errors_g <= errors ^ (errors >> 1);
  end

endmodule
