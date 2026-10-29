// ***************************************************************************
// GlideLink shell: host RX port adapter (switch -> axi_dmac, processing clock)
//
// Header mode (hdr_en = 1): every packet is preceded by four words
//   word 0  {8'hA5, flags[7:0], length[15:0]}   length in samples
//   word 1  packet sequence number (per port, counts every packet sent)
//   word 2  timestamp[31:0]                      sample counter of the first sample
//   word 3  timestamp[63:32]
// flags = the packet's tuser flags (taken from its first beat), plus bit 7 =
// this part was cut off because the packet is longer than 2^MAX_LEN_LOG2
// samples; the rest follows as further parts with the same flags and the
// timestamps that continue the first part's. The length is only known at
// the end, so data is buffered (one maximum part) and the header goes into
// a small header FIFO that the output reads before the data.
// Raw mode (hdr_en = 0): samples pass straight through.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_host_rx #(
  parameter MAX_LEN_LOG2 = 13               // 8192 samples
) (
  input             clk,
  input             rst,
  input             hdr_en,                 // quasi-static; change only while idle

  input             s_valid,
  output            s_ready,
  input     [31:0]  s_data,
  input     [71:0]  s_user,
  input             s_last,

  output            m_valid,
  input             m_ready,
  output    [31:0]  m_data
);

  localparam [15:0] MAX_LEN = 1 << MAX_LEN_LOG2;

  wire        data_full, data_empty, hdr_full, hdr_empty;
  wire [31:0] data_out;
  wire [87:0] hdr_out;                      // {flags[7:0], length[15:0], timestamp[63:0]}

  // ---------------------------------------------------------------------------
  // input side: count each part, push its header at its end

  reg  [15:0] count = 16'd0;                // samples of the current part so far
  reg         cont = 1'b0;                  // the current part continues a cut packet
  reg  [7:0]  flags_r = 8'd0;
  reg  [63:0] ts_r = 64'd0;                 // timestamp of the current part
  reg  [63:0] next_ts = 64'd0;              // timestamp of the part after a cut

  wire        in_beat = s_valid && s_ready;
  wire        first = count == 16'd0;
  wire [7:0]  flags_now = first && !cont ? s_user[71:64] : flags_r;
  wire [63:0] ts_now = first ? (cont ? next_ts : s_user[63:0]) : ts_r;
  wire        cut = count == MAX_LEN - 16'd1 && !s_last;
  wire        part_end = in_beat && (s_last || cut);

  assign s_ready = hdr_en ? (!data_full && !hdr_full) : m_ready;

  always @(posedge clk) begin
    if (rst) begin
      count <= 16'd0;
      cont <= 1'b0;
    end else if (in_beat && hdr_en) begin
      if (first) begin
        flags_r <= flags_now;
        ts_r <= ts_now;
      end
      if (part_end) begin
        count <= 16'd0;
        cont <= cut;
        next_ts <= ts_now + count + 64'd1;
      end else begin
        count <= count + 16'd1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // output side: 4 header words, then the part's samples

  reg  [2:0]  hw = 3'd0;                    // 0..3 header word, 4 samples
  reg  [15:0] left = 16'd0;
  reg  [31:0] seq = 32'd0;

  wire        sending = hw == 3'd4;
  wire        data_beat = sending && m_ready && !data_empty;
  wire        hdr_pop = data_beat && left == 16'd1;

  reg  [31:0] hdr_word;
  always @(*) begin
    case (hw)
      3'd0: hdr_word = {8'hA5, hdr_out[87:80], hdr_out[79:64]};
      3'd1: hdr_word = seq;
      3'd2: hdr_word = hdr_out[31:0];
      default: hdr_word = hdr_out[63:32];
    endcase
  end

  always @(posedge clk) begin
    if (rst) begin
      hw <= 3'd0;
      seq <= 32'd0;
    end else if (!sending) begin
      if (!hdr_empty && m_ready) begin
        if (hw == 3'd3) left <= hdr_out[79:64];
        hw <= hw + 3'd1;
      end
    end else if (data_beat) begin
      left <= left - 16'd1;
      if (left == 16'd1) begin
        hw <= 3'd0;
        seq <= seq + 32'd1;
      end
    end
  end

  assign m_valid = hdr_en ? (sending ? !data_empty : !hdr_empty) : s_valid;
  assign m_data = hdr_en ? (sending ? data_out : hdr_word) : s_data;

  // ---------------------------------------------------------------------------

  glidelink_fifo #(.WIDTH(32), .ADDR_WIDTH(MAX_LEN_LOG2)) i_data (
    .clk(clk), .rst(rst), .wr_en(in_beat && hdr_en), .wr_data(s_data), .full(data_full),
    .rd_en(data_beat), .rd_data(data_out), .empty(data_empty), .level());

  glidelink_fifo #(.WIDTH(88), .ADDR_WIDTH(4)) i_hdr (
    .clk(clk), .rst(rst), .wr_en(part_end && hdr_en),
    .wr_data({flags_now | (cut ? 8'h80 : 8'h00), count + 16'd1, ts_now}), .full(hdr_full),
    .rd_en(hdr_pop), .rd_data(hdr_out), .empty(hdr_empty), .level());

endmodule
