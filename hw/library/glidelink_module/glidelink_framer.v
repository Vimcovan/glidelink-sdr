// ***************************************************************************
// GlideLink: the packets around a user module (as RFNoC's axi_rate_change does
// for its blocks), so that the module itself sees samples only (tdata, tvalid,
// tready) and its output still reaches a host port or the RF in packets with
// their headers (tuser on the first beat: flags[71:64], timestamp[63:0]).
//
// Each input packet's header is kept; the module's outputs are counted and
// grouped into output packets, one per input packet, each with that packet's
// header on its first beat:
//   - fixed rate L / M (VARIABLE = 0; 1 / 1 for a module that keeps the rate):
//     the output packet of an input packet ends at output floor(N L / M), N
//     the inputs up to that packet's end since the reset. A packet with no
//     output there (shorter than the decimation) is dropped with its header;
//     an output beyond the counted ones waits for the next packet's header.
//   - VARIABLE = 1 (output count not a fixed ratio, e.g. a symbol sync): an
//     output packet ends with the first output after its input packet ended;
//     input packets that ended before that without an output of their own
//     are dropped with their headers.
// The module's output is never held back for a header (a module may stop
// taking input while its output waits, as AXI4-Stream allows): it goes into
// a 16-sample FIFO, where an output with no packet yet (e.g. a decimator one
// sample ahead) waits for the next packet's header; with the FIFO full and no
// header in sight it goes out without one. L and M may change only while the
// stream is idle (flush, soft reset).
//
// After a reset (flush, soft reset), what the module still had in it is not
// part of the new stream: as RFNoC's NoC Shell flushes a block, the module's
// output is taken and dropped, with no input going in, until it has been
// quiet for QUIET cycles (a module need not empty itself on a flush; e.g. the
// Xilinx FIR Compiler keeps what it had computed through its aresetn).
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_framer #(
  parameter VARIABLE = 0,
  parameter DEPTH_LOG2 = 6,                 // input packets in flight inside the module
  parameter QUIET = 256                     // after a reset: cycles with no output that end it
) (
  input             clk,
  input             rst,
  input      [7:0]  interp,                 // L (0 counts as 1)
  input      [7:0]  decim,                  // M (0 counts as 1)

  // slot side
  input             s_axis_tvalid,
  output            s_axis_tready,
  input     [31:0]  s_axis_tdata,
  input     [71:0]  s_axis_tuser,
  input             s_axis_tlast,
  output            m_axis_tvalid,
  input             m_axis_tready,
  output    [31:0]  m_axis_tdata,
  output    [71:0]  m_axis_tuser,
  output            m_axis_tlast,

  // module side
  output            u_s_tvalid,
  input             u_s_tready,
  output    [31:0]  u_s_tdata,
  input             u_m_tvalid,
  output            u_m_tready,
  input     [31:0]  u_m_tdata
);

  localparam D = 1 << DEPTH_LOG2;

  // ---------------------------------------------------------------------------
  // after a reset: the module's output dropped until quiet

  reg         drain = 1'b1;
  reg  [15:0] quiet = 16'd0;
  always @(posedge clk) begin
    if (rst) begin
      drain <= 1'b1;
      quiet <= 16'd0;
    end else if (drain) begin
      quiet <= u_m_tvalid ? 16'd0 : quiet + 16'd1;
      if (!u_m_tvalid && quiet == QUIET - 1)
        drain <= 1'b0;
    end
  end

  wire [7:0] L = interp == 8'd0 ? 8'd1 : interp;
  wire [7:0] M = decim == 8'd0 ? 8'd1 : decim;

  // ---------------------------------------------------------------------------
  // input side: a header per packet start, an end count per packet end

  reg  [71:0] hdr [0:D-1];
  reg  [31:0] ends [0:D-1];                 // fixed rate: output count at the packet's end
  reg  [DEPTH_LOG2:0] hwp = 0, hrp = 0, ewp = 0, erp = 0;
  wire [DEPTH_LOG2:0] hused = hwp - hrp, eused = ewp - erp;
  wire        hfull = hused == D, efull = eused == D;
  wire        hempty = hused == 0, eempty = eused == 0;

  reg         in_first = 1'b1;              // the next input starts a packet
  reg  [31:0] tgt = 32'd0;                  // floor(inputs L / M) so far
  reg   [7:0] acc = 8'd0;                   // (inputs L) mod M
  wire  [8:0] sum = {1'b0, acc} + {1'b0, L};
  wire  [8:0] q = sum / {1'b0, M};
  wire  [8:0] rem = sum % {1'b0, M};

  assign s_axis_tready = !drain && u_s_tready && !hfull && !efull;
  assign u_s_tvalid = !drain && s_axis_tvalid && !hfull && !efull;
  assign u_s_tdata = s_axis_tdata;
  wire        in_beat = s_axis_tvalid && s_axis_tready;

  always @(posedge clk) begin
    if (rst) begin
      hwp <= 0;
      ewp <= 0;
      in_first <= 1'b1;
      tgt <= 32'd0;
      acc <= 8'd0;
    end else if (in_beat) begin
      in_first <= s_axis_tlast;
      tgt <= tgt + {23'd0, q};
      acc <= rem[7:0];
      if (in_first) begin
        hdr[hwp[DEPTH_LOG2-1:0]] <= s_axis_tuser;
        hwp <= hwp + 1'b1;
      end
      if (s_axis_tlast) begin
        ends[ewp[DEPTH_LOG2-1:0]] <= tgt + {23'd0, q};
        ewp <= ewp + 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // the module's outputs: always taken (a module may hold its input while its
  // output waits, as AXI4-Stream allows), into a small FIFO where they wait
  // for their packet's header

  reg  [31:0] obuf [0:15];
  reg   [4:0] owp = 5'd0, orp = 5'd0;
  wire  [4:0] oused = owp - orp;
  wire        ofull = oused == 5'd16, oempty = oused == 5'd0;
  assign u_m_tready = drain || !ofull;
  always @(posedge clk) begin
    if (rst || drain) begin
      owp <= 5'd0;
    end else if (u_m_tvalid && !ofull) begin
      obuf[owp[3:0]] <= u_m_tdata;
      owp <= owp + 5'd1;
    end
  end

  // ---------------------------------------------------------------------------
  // output side

  reg         o_first = 1'b1;               // the next output starts a packet
  reg  [31:0] ocnt = 32'd0;                 // outputs so far
  wire [31:0] efront = ends[erp[DEPTH_LOG2-1:0]];
  wire signed [31:0] eleft = efront - ocnt; // outputs still due to the front packet
  // fixed rate: the front packet ended with no output of its own
  wire        skip = !VARIABLE && o_first && !eempty && eleft <= 0;
  // an output waits for its packet's header; with none in sight and the FIFO full (a module
  // that makes output with no input) it goes out without one
  wire        nohdr = hempty && ofull;
  wire        go = (!hempty || nohdr) && !skip;
  wire        last = !hempty && (VARIABLE ? !eempty : (!eempty && eleft <= 1));

  assign m_axis_tvalid = !oempty && go;
  assign m_axis_tdata = obuf[orp[3:0]];
  assign m_axis_tuser = o_first && !hempty ? hdr[hrp[DEPTH_LOG2-1:0]] : 72'd0;
  assign m_axis_tlast = last;
  wire        out_beat = m_axis_tvalid && m_axis_tready;

  always @(posedge clk) begin
    if (rst)
      orp <= 5'd0;
    else if (out_beat)
      orp <= orp + 5'd1;
  end

  always @(posedge clk) begin
    if (rst) begin
      hrp <= 0;
      erp <= 0;
      o_first <= 1'b1;
      ocnt <= 32'd0;
    end else if (skip) begin
      hrp <= hrp + 1'b1;
      erp <= erp + 1'b1;
    end else if (out_beat && hempty) begin  // no packet: not counted
    end else if (out_beat) begin
      ocnt <= ocnt + 32'd1;
      o_first <= last;
      if (last) begin
        if (VARIABLE) begin                 // every packet ended so far closes here
          hrp <= hrp + eused;
          erp <= ewp;
        end else begin
          hrp <= hrp + 1'b1;
          erp <= erp + 1'b1;
        end
      end
    end
  end

endmodule
