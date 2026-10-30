// ***************************************************************************
// GlideLink shell: TX streamer
//
// Takes AXI4-Stream packets from the processing clock and feeds the AD9361
// channel 0 DAC, one sample per dac_valid (l_clk):
//   tdata = {Q, I}, tlast on the last sample,
//   tuser = {flags[7:0], time[63:0]} on the first beat,
//   flags bit 1 = end of burst: idle (zeros) after this packet is not an underflow,
//   flags bit 2 = timed: start the packet when the sample counter reaches time
//   (bit 0, drops before this packet, is ignored).
// A timed packet found already late is dropped (late_drop = 1) or sent at
// once; either way it is counted in late. Running out of data inside a burst
// sends zeros and counts one underflow per dry spell. Counters are Gray-coded
// in l_clk.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_tx_stream #(
  parameter FIFO_ADDR_WIDTH = 13,
  parameter HDR_ADDR_WIDTH = 4
) (
  // processing side
  input             s_clk,
  input             s_rst,
  input     [31:0]  s_axis_tdata,
  input     [71:0]  s_axis_tuser,
  input             s_axis_tlast,
  input             s_axis_tvalid,
  output            s_axis_tready,

  // sample side
  input             l_clk,
  input             l_rst,
  input             dac_valid,
  output    [15:0]  dac_data_i,
  output    [15:0]  dac_data_q,
  input     [63:0]  time_now,             // sample counter, l_clk
  input             late_drop,            // quasi-static
  output    [31:0]  underflow_gray,
  output    [31:0]  late_gray,
  output            dac_dunf              // to axi_ad9361: underflow
);

  localparam FLAG_EOB = 1, FLAG_TIMED = 2;

  wire        data_full, hdr_full;
  wire [32:0] data_out;
  wire        data_empty;
  wire [71:0] hdr_out;
  wire        hdr_empty;
  wire        s_reset, l_reset;           // either side reset resets both

  // ---------------------------------------------------------------------------
  // s_clk: data and one header per packet

  reg         s_in_pkt = 1'b0;
  wire        s_beat = s_axis_tvalid && s_axis_tready;

  assign s_axis_tready = !data_full && (s_in_pkt || !hdr_full);

  always @(posedge s_clk) begin
    if (s_reset)
      s_in_pkt <= 1'b0;
    else if (s_beat)
      s_in_pkt <= !s_axis_tlast;
  end

  // ---------------------------------------------------------------------------
  // l_clk: scheduler

  localparam IDLE = 2'd0, WAIT = 2'd1, SEND = 2'd2, DROP = 2'd3;

  reg  [1:0]  state = IDLE;
  reg  [63:0] start_time = 64'd0;
  reg         eob = 1'b1;                 // the packet being sent ends a burst
  reg         first_wait = 1'b0;
  reg         dry = 1'b0;                 // currently underflowing (count once)
  reg  [31:0] underflow = 32'd0, late = 32'd0;
  reg  [31:0] underflow_g = 32'd0, late_g = 32'd0;
  reg  [31:0] dac_data = 32'd0;
  reg         dunf = 1'b0;

  wire        hdr_timed = hdr_out[64 + FLAG_TIMED];
  wire        hdr_eob = hdr_out[64 + FLAG_EOB];
  wire        sample_last = data_out[32];

  // header fetch: between packets (once the packet's first sample is
  // visible too: the two FIFOs' pointers cross independently), or right at
  // the last sample of a packet that does not end a burst, so that
  // back-to-back packets have no gap
  wire        send_now = state == SEND && dac_valid && !data_empty;
  wire        at_end = send_now && sample_last;
  wire        take_hdr = !hdr_empty && ((state == IDLE && !data_empty) || (at_end && !eob));
  wire        drop_rd = state == DROP && !data_empty;
  wire        data_rd = send_now || drop_rd;

  always @(posedge l_clk) begin
    if (l_reset) begin
      state <= IDLE;
      eob <= 1'b1;
      dry <= 1'b0;
      dac_data <= 32'd0;
      dunf <= 1'b0;
    end else begin
      dunf <= 1'b0;

      if (dac_valid)
        dac_data <= send_now ? data_out[31:0] : 32'd0;

      // underflow: no sample to send inside a burst
      if (dac_valid && ((state == SEND && data_empty) || (state == IDLE && !eob && hdr_empty))) begin
        if (!dry) begin
          underflow <= underflow + 32'd1;
          dunf <= 1'b1;
        end
        dry <= 1'b1;
      end else if (send_now) begin
        dry <= 1'b0;
      end

      if (take_hdr) begin
        start_time <= hdr_out[63:0];
        eob <= hdr_eob;
        first_wait <= 1'b1;
        state <= hdr_timed ? WAIT : SEND;
      end else begin
        case (state)
          WAIT: begin
            first_wait <= 1'b0;
            if (first_wait && time_now > start_time) begin
              late <= late + 32'd1;
              state <= late_drop ? DROP : SEND;
            end else if (time_now >= start_time) begin
              state <= SEND;
            end
          end
          SEND: if (at_end) state <= IDLE;
          DROP: if (drop_rd && sample_last) state <= IDLE;
          default: ;
        endcase
      end
    end
    underflow_g <= underflow ^ (underflow >> 1);
    late_g <= late ^ (late >> 1);
  end

  assign dac_data_i = dac_data[15:0];
  assign dac_data_q = dac_data[31:16];
  assign underflow_gray = underflow_g;
  assign late_gray = late_g;
  assign dac_dunf = dunf;

  // ---------------------------------------------------------------------------

  glidelink_async_fifo #(.WIDTH(33), .ADDR_WIDTH(FIFO_ADDR_WIDTH)) i_data_fifo (
    .wr_clk(s_clk), .wr_rst(s_rst), .wr_en(s_beat),
    .wr_data({s_axis_tlast, s_axis_tdata}),
    .wr_full(data_full), .wr_level(), .wr_in_reset(s_reset),
    .rd_clk(l_clk), .rd_rst(l_rst), .rd_en(data_rd),
    .rd_data(data_out), .rd_empty(data_empty), .rd_level(), .rd_in_reset(l_reset));

  glidelink_async_fifo #(.WIDTH(72), .ADDR_WIDTH(HDR_ADDR_WIDTH)) i_hdr_fifo (
    .wr_clk(s_clk), .wr_rst(s_rst), .wr_en(s_beat && !s_in_pkt),
    .wr_data(s_axis_tuser),
    .wr_full(hdr_full), .wr_level(), .wr_in_reset(),
    .rd_clk(l_clk), .rd_rst(l_rst), .rd_en(take_hdr),
    .rd_data(hdr_out), .rd_empty(hdr_empty), .rd_level(), .rd_in_reset());

endmodule
