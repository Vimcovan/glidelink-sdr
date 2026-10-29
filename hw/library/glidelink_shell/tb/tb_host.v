// Testbench for the host port adapters.
// host_rx (MAX_LEN 32): packets of 5..80 samples, data = {pkt, idx}, tuser =
//   {flags = pkt[3:0], ts = 1000 * pkt}; random back-pressure on both sides.
//   The output is parsed: magic, length (parts of at most 32), flags (+ bit 7
//   on all but the last part), sequence numbers counting up, timestamps
//   continuing across parts, and every sample in order.
// host_tx: a word stream of headers and samples with junk words in front of
//   some headers; the output packets must carry the header's flags and time,
//   the right length with tlast, the samples in order; errors = junk words.

`timescale 1ns/100ps

module tb_host;

  reg clk = 0;
  always #2.5 clk = ~clk;
  reg rst = 1;
  integer errors = 0;

  // ---------------------------------------------------------------------------
  // host_rx

  reg         rs_valid = 0, rs_last = 0;
  reg  [31:0] rs_data = 0;
  reg  [71:0] rs_user = 0;
  wire        rs_ready, rm_valid;
  wire [31:0] rm_data;
  reg         rm_ready = 0;

  glidelink_host_rx #(.MAX_LEN_LOG2(5)) i_rx (
    .clk(clk), .rst(rst), .hdr_en(1'b1),
    .s_valid(rs_valid), .s_ready(rs_ready), .s_data(rs_data), .s_user(rs_user), .s_last(rs_last),
    .m_valid(rm_valid), .m_ready(rm_ready), .m_data(rm_data));

  function integer rx_len(input integer p);
    rx_len = 5 + (p * 37) % 76;
  endfunction

  integer rp = 0, ri = 0;                    // source packet / index
  always @(posedge clk) if (!rst) begin
    if (rs_valid && rs_ready) begin
      if (rs_last) begin rp = rp + 1; ri = 0; end else ri = ri + 1;
    end
    if (!rs_valid || rs_ready) begin
      rs_valid <= ($random & 3) != 0 && rp < 200;
      rs_data <= {rp[15:0], ri[15:0]};
      rs_user <= {4'd0, rp[3:0], 64'd1000 * rp};
      rs_last <= ri == rx_len(rp) - 1;
    end
    rm_ready <= ($random & 3) != 0;
  end

  // parser
  integer     st = 0, plen = 0, pleft = 0, op = 0, oi = 0, nseq = 0, parts_rx = 0;
  reg  [7:0]  pflags;
  reg  [63:0] pts;
  always @(posedge clk) if (!rst && rm_valid && rm_ready) begin
    case (st)
      0: begin
        if (rm_data[31:24] != 8'hA5) begin $display("ERROR: rx magic %h", rm_data); errors = errors + 1; end
        pflags = rm_data[23:16]; plen = rm_data[15:0]; pleft = plen;
        st = 1;
      end
      1: begin
        if (rm_data != nseq) begin $display("ERROR: rx seq %0d, expected %0d", rm_data, nseq); errors = errors + 1; end
        nseq = nseq + 1; st = 2;
      end
      2: begin pts[31:0] = rm_data; st = 3; end
      3: begin
        pts[63:32] = rm_data; st = 4;
        if (pts != 1000 * op + oi) begin $display("ERROR: rx ts %0d for pkt %0d idx %0d", pts, op, oi); errors = errors + 1; end
        if (pflags[3:0] != op[3:0]) begin $display("ERROR: rx flags %h for pkt %0d", pflags, op); errors = errors + 1; end
        if (plen > 32 || plen != ((rx_len(op) - oi > 32) ? 32 : rx_len(op) - oi)) begin
          $display("ERROR: rx part length %0d for pkt %0d at idx %0d", plen, op, oi); errors = errors + 1;
        end
        if (pflags[7] != (rx_len(op) - oi > 32)) begin $display("ERROR: rx cut flag %b", pflags[7]); errors = errors + 1; end
        parts_rx = parts_rx + 1;
      end
      default: begin
        if (rm_data != {op[15:0], oi[15:0]}) begin $display("ERROR: rx data %h, expected pkt %0d idx %0d", rm_data, op, oi); errors = errors + 1; end
        oi = oi + 1;
        if (oi == rx_len(op)) begin op = op + 1; oi = 0; end
        pleft = pleft - 1;
        if (pleft == 0) st = 0;
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // host_tx

  reg         ts_valid = 0;
  reg  [31:0] ts_data = 0;
  wire        ts_ready, tm_valid, tm_last;
  wire [31:0] tm_data;
  wire [71:0] tm_user;
  reg         tm_ready = 0;
  wire [31:0] tx_err_gray;

  glidelink_host_tx i_tx (
    .clk(clk), .rst(rst), .hdr_en(1'b1),
    .s_valid(ts_valid), .s_ready(ts_ready), .s_data(ts_data), .s_last(1'b0),
    .m_valid(tm_valid), .m_ready(tm_ready), .m_data(tm_data), .m_user(tm_user), .m_last(tm_last),
    .errors_gray(tx_err_gray));

  function integer tx_len(input integer p);
    tx_len = 1 + (p * 13) % 40;
  endfunction

  // word stream: [junk (every 5th packet)] header x4, samples
  integer tp = 0, tw = 0;
  integer hdr_base;
  reg [15:0] tlen16, tidx16;
  always @(posedge clk) if (!rst) begin
    if (ts_valid && ts_ready) begin
      tw = tw + 1;
      hdr_base = (tp % 5 == 0) ? 1 : 0;
      if (tw == hdr_base + 4 + tx_len(tp)) begin tp = tp + 1; tw = 0; end
    end
    if (!ts_valid || ts_ready) begin
      hdr_base = (tp % 5 == 0) ? 1 : 0;
      tlen16 = tx_len(tp);
      tidx16 = tw - hdr_base - 4;
      ts_valid <= ($random & 3) != 0 && tp < 200;
      if (tw < hdr_base) begin ts_data <= 32'h12345678; end
      else case (tw - hdr_base)
        0: ts_data <= {8'hA5, 6'd0, tp[1:0], tlen16};
        1: ts_data <= tp;
        2: ts_data <= 32'd5000 + tp;
        3: ts_data <= 32'd0;
        default: ts_data <= {tp[15:0], tidx16};
      endcase
    end
    tm_ready <= ($random & 3) != 0;
  end

  integer xp = 0, xi = 0;
  always @(posedge clk) if (!rst && tm_valid && tm_ready) begin
    if (tm_data != {xp[15:0], xi[15:0]}) begin $display("ERROR: tx data %h, expected pkt %0d idx %0d", tm_data, xp, xi); errors = errors + 1; if (errors > 10) $finish; end
    if (xi == 0 && (tm_user[63:0] != 5000 + xp || tm_user[65:64] != xp[1:0])) begin
      $display("ERROR: tx user %h for pkt %0d", tm_user, xp); errors = errors + 1;
    end
    if (tm_last != (xi == tx_len(xp) - 1)) begin $display("ERROR: tx tlast %b at %0d/%0d", tm_last, xi, tx_len(xp)); errors = errors + 1; end
    xi = xi + 1;
    if (xi == tx_len(xp)) begin xp = xp + 1; xi = 0; end
  end

  function [31:0] gray2bin(input [31:0] g);
    integer i;
    begin
      gray2bin[31] = g[31];
      for (i = 30; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i + 1] ^ g[i];
    end
  endfunction

  initial begin
    #50 rst = 0;
    #400000;
    if (op != 200) begin $display("ERROR: rx parsed %0d of 200 packets", op); errors = errors + 1; end
    if (xp != 200) begin $display("ERROR: tx produced %0d of 200 packets", xp); errors = errors + 1; end
    if (gray2bin(tx_err_gray) != 40) begin $display("ERROR: tx errors %0d, expected 40", gray2bin(tx_err_gray)); errors = errors + 1; end
    $display("packets: rx %0d packets in %0d parts, tx %0d packets, tx errors %0d", op, parts_rx, xp, gray2bin(tx_err_gray));
    if (errors == 0) $display("PASS tb_host");
    else $display("FAIL tb_host: %0d errors", errors);
    $finish;
  end

endmodule
