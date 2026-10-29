// ***************************************************************************
// GlideLink shell: asynchronous FIFO (Gray-coded pointers, first-word fall-through)
//
// wr_level / rd_level are the fill levels as seen from each side; the far
// side's pointer arrives through a two-stage synchroniser, so the write side
// may see the FIFO fuller and the read side emptier than it is, never the
// other way round.
// A reset on either side resets both: each side's reset is held for 16 of
// its cycles and passed to the other side through a synchroniser. (The
// AD9361 side is reset by itself when the driver resets the axi_ad9361
// core; resetting only one side's pointer would wedge the FIFO.)
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_async_fifo #(
  parameter WIDTH = 32,
  parameter ADDR_WIDTH = 10                // depth = 2^ADDR_WIDTH
) (
  input                       wr_clk,
  input                       wr_rst,
  input                       wr_en,       // ignored when full
  input       [WIDTH-1:0]     wr_data,
  output                      wr_full,
  output      [ADDR_WIDTH:0]  wr_level,
  output                      wr_in_reset, // this side is held in reset (own or far side's)

  input                       rd_clk,
  input                       rd_rst,
  input                       rd_en,       // pop the word on rd_data; ignored when empty
  output      [WIDTH-1:0]     rd_data,
  output                      rd_empty,
  output      [ADDR_WIDTH:0]  rd_level,
  output                      rd_in_reset
);

  localparam DEPTH = 1 << ADDR_WIDTH;

  (* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

  function [ADDR_WIDTH:0] bin2gray(input [ADDR_WIDTH:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  function [ADDR_WIDTH:0] gray2bin(input [ADDR_WIDTH:0] g);
    integer i;
    begin
      gray2bin[ADDR_WIDTH] = g[ADDR_WIDTH];
      for (i = ADDR_WIDTH - 1; i >= 0; i = i - 1)
        gray2bin[i] = gray2bin[i + 1] ^ g[i];
    end
  endfunction

  reg  [ADDR_WIDTH:0] wr_ptr = 0, wr_ptr_gray = 0;
  reg  [ADDR_WIDTH:0] rd_ptr = 0, rd_ptr_gray = 0;   // rd_ptr: next RAM word to read

  // resets: stretch locally, cross, combine

  reg  [3:0]  wr_hold = 4'hF, rd_hold = 4'hF;
  wire        wr_rst_long = wr_rst || wr_hold != 4'd0;
  wire        rd_rst_long = rd_rst || rd_hold != 4'd0;
  (* ASYNC_REG = "TRUE" *) reg [1:0] rd_rst_w = 2'b11, wr_rst_r = 2'b11;
  wire        wr_reset = wr_rst_long || rd_rst_w[1];
  wire        rd_reset = rd_rst_long || wr_rst_r[1];

  assign wr_in_reset = wr_reset;
  assign rd_in_reset = rd_reset;

  always @(posedge wr_clk) begin
    wr_hold <= wr_rst ? 4'hF : (wr_hold != 4'd0 ? wr_hold - 4'd1 : 4'd0);
    rd_rst_w <= {rd_rst_w[0], rd_rst_long};
  end

  always @(posedge rd_clk) begin
    rd_hold <= rd_rst ? 4'hF : (rd_hold != 4'd0 ? rd_hold - 4'd1 : 4'd0);
    wr_rst_r <= {wr_rst_r[0], wr_rst_long};
  end

  // write side

  (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] rd_ptr_gray_m1 = 0, rd_ptr_gray_m2 = 0;
  wire [ADDR_WIDTH:0] rd_ptr_w = gray2bin(rd_ptr_gray_m2);

  assign wr_level = wr_ptr - rd_ptr_w;
  assign wr_full = wr_level[ADDR_WIDTH];

  always @(posedge wr_clk) begin
    if (wr_reset) begin
      wr_ptr <= 0;
      wr_ptr_gray <= 0;
      rd_ptr_gray_m1 <= 0;
      rd_ptr_gray_m2 <= 0;
    end else begin
      rd_ptr_gray_m1 <= rd_ptr_gray;
      rd_ptr_gray_m2 <= rd_ptr_gray_m1;
      if (wr_en && !wr_full) begin
        wr_ptr <= wr_ptr + 1'b1;
        wr_ptr_gray <= bin2gray(wr_ptr + 1'b1);
      end
    end
  end

  always @(posedge wr_clk)
    if (wr_en && !wr_full)
      mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;

  // read side: a one-word output register in front of the RAM read port

  (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] wr_ptr_gray_m1 = 0, wr_ptr_gray_m2 = 0;
  wire [ADDR_WIDTH:0] wr_ptr_r = gray2bin(wr_ptr_gray_m2);
  wire                ram_empty = wr_ptr_r == rd_ptr;

  reg  [WIDTH-1:0]    out_data = 0;
  reg                 out_valid = 1'b0;
  wire                fetch = !ram_empty && (!out_valid || rd_en);

  assign rd_data = out_data;
  assign rd_empty = !out_valid;
  assign rd_level = wr_ptr_r - rd_ptr + out_valid;

  always @(posedge rd_clk) begin
    if (rd_reset) begin
      rd_ptr <= 0;
      rd_ptr_gray <= 0;
      wr_ptr_gray_m1 <= 0;
      wr_ptr_gray_m2 <= 0;
      out_valid <= 1'b0;
    end else begin
      wr_ptr_gray_m1 <= wr_ptr_gray;
      wr_ptr_gray_m2 <= wr_ptr_gray_m1;
      if (fetch) begin
        rd_ptr <= rd_ptr + 1'b1;
        rd_ptr_gray <= bin2gray(rd_ptr + 1'b1);
        out_valid <= 1'b1;
      end else if (rd_en) begin
        out_valid <= 1'b0;
      end
    end
  end

  always @(posedge rd_clk)
    if (fetch)
      out_data <= mem[rd_ptr[ADDR_WIDTH-1:0]];

endmodule
