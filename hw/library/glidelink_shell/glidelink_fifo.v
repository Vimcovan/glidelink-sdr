// ***************************************************************************
// GlideLink shell: synchronous FIFO, first-word fall-through
// RAM_STYLE: "block" (BRAM), "ultra" (URAM: one clock, read latency 1, no
// initial contents needed), or "distributed" (LUTRAM)
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_fifo #(
  parameter WIDTH = 32,
  parameter ADDR_WIDTH = 10,
  parameter RAM_STYLE = "block"
) (
  input                       clk,
  input                       rst,
  input                       wr_en,       // ignored when full
  input       [WIDTH-1:0]     wr_data,
  output                      full,
  input                       rd_en,       // pop rd_data; ignored when empty
  output      [WIDTH-1:0]     rd_data,
  output                      empty,
  output reg  [ADDR_WIDTH:0]  level = 0    // words in the FIFO, output register included
);

  localparam DEPTH = 1 << ADDR_WIDTH;

  (* ram_style = RAM_STYLE *) reg [WIDTH-1:0] mem [0:DEPTH-1];
  reg  [ADDR_WIDTH:0] wr_ptr = 0, rd_ptr = 0;
  reg  [WIDTH-1:0]    out_data = 0;
  reg                 out_valid = 1'b0;

  wire                ram_empty = wr_ptr == rd_ptr;
  wire                do_wr = wr_en && !full;
  wire                do_rd = rd_en && out_valid;
  wire                fetch = !ram_empty && (!out_valid || do_rd);

  assign full = level[ADDR_WIDTH];
  assign rd_data = out_data;
  assign empty = !out_valid;

  always @(posedge clk) begin
    if (rst) begin
      wr_ptr <= 0;
      rd_ptr <= 0;
      out_valid <= 1'b0;
      level <= 0;
    end else begin
      if (do_wr) wr_ptr <= wr_ptr + 1'b1;
      if (fetch) begin
        rd_ptr <= rd_ptr + 1'b1;
        out_valid <= 1'b1;
      end else if (do_rd) begin
        out_valid <= 1'b0;
      end
      level <= level + do_wr - do_rd;
    end
  end

  always @(posedge clk) begin
    if (do_wr) mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
    if (fetch) out_data <= mem[rd_ptr[ADDR_WIDTH-1:0]];
  end

endmodule
