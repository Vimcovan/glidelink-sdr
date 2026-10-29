// ***************************************************************************
// GlideLink shell: stream switch (processing clock)
//
// N_SRC source ports, N_SNK sink ports; AXI4-Stream with tdata[31:0],
// tuser[71:0] and tlast, flattened into vectors (port k at [k*W +: W]).
// Each sink has a route (source index, 4'hF = none) from the registers.
// - A sink takes a new route only between packets, and starts forwarding a
//   source only at the start of one of its packets.
// - A source goes to one sink only: if several sinks route the same source,
//   the lowest-numbered one gets it.
// - A source that no sink routes is drained (its data is dropped), so an
//   unrouted RF RX does not show up as RX overflow; the rest of a packet a
//   source was in the middle of when its route appeared is drained as well.
// The routes come from the CPU clock: each is synchronised and only used once
// it has been stable for four cycles.
// abort_snk[j] drops sink j's connection at once (its downstream is being
// reset); abort_src[i] forgets that source i is inside a packet (it is being
// reset) and drops the sink forwarding it. A sink stalled inside a packet
// would otherwise never reach the packet boundary where routes change.
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_switch #(
  parameter N_SRC = 3,
  parameter N_SNK = 3
) (
  input                       clk,
  input                       rst,
  input   [N_SNK*4-1:0]       route,          // CPU clock, quasi-static
  input   [N_SNK-1:0]         abort_snk,
  input   [N_SRC-1:0]         abort_src,

  input   [N_SRC-1:0]         s_valid,
  output  [N_SRC-1:0]         s_ready,
  input   [N_SRC*32-1:0]      s_data,
  input   [N_SRC*72-1:0]      s_user,
  input   [N_SRC-1:0]         s_last,

  output  [N_SNK-1:0]         m_valid,
  input   [N_SNK-1:0]         m_ready,
  output  [N_SNK*32-1:0]      m_data,
  output  [N_SNK*72-1:0]      m_user,
  output  [N_SNK-1:0]         m_last
);

  localparam [3:0] NONE = 4'hF;

  // route synchronisers: two flops, then four equal samples

  (* ASYNC_REG = "TRUE" *) reg [N_SNK*4-1:0] route_m1 = {N_SNK{NONE}}, route_m2 = {N_SNK{NONE}};
  reg  [N_SNK*4-1:0]  route_d = {N_SNK{NONE}};
  reg  [N_SNK*4-1:0]  route_s = {N_SNK{NONE}};
  reg  [1:0]          stable = 2'd0;

  always @(posedge clk) begin
    route_m1 <= route;
    route_m2 <= route_m1;
    route_d <= route_m2;
    if (route_m2 != route_d) begin
      stable <= 2'd0;
    end else if (stable != 2'd3) begin
      stable <= stable + 2'd1;
    end else begin
      route_s <= route_d;
    end
  end

  // per source: packet state, which sink wants it, which sink has it

  reg  [N_SRC-1:0]    src_in_pkt = {N_SRC{1'b0}};
  reg  [N_SNK-1:0]    active = {N_SNK{1'b0}};
  reg  [N_SNK*4-1:0]  cur = {N_SNK{NONE}};

  // sink j may take source r if no lower sink routes r
  function claim_ok(input integer j, input [3:0] r, input [N_SNK*4-1:0] rt);
    integer k;
    begin
      claim_ok = 1'b1;
      for (k = 0; k < N_SNK; k = k + 1)
        if (k < j && rt[k*4 +: 4] == r)
          claim_ok = 1'b0;
    end
  endfunction

  reg  [N_SRC-1:0]    routed;         // some sink routes this source
  reg  [N_SRC-1:0]    connected;      // an active sink forwards it
  reg  [N_SRC-1:0]    src_ready;
  reg  [N_SNK-1:0]    snk_valid;
  integer i, j;

  always @(*) begin
    routed = {N_SRC{1'b0}};
    connected = {N_SRC{1'b0}};
    src_ready = {N_SRC{1'b0}};
    snk_valid = {N_SNK{1'b0}};
    for (j = 0; j < N_SNK; j = j + 1) begin
      if (route_s[j*4 +: 4] < N_SRC)
        routed[route_s[j*4 +: 4]] = 1'b1;
      if (active[j]) begin
        connected[cur[j*4 +: 4]] = 1'b1;
        src_ready[cur[j*4 +: 4]] = m_ready[j];
        snk_valid[j] = s_valid[cur[j*4 +: 4]];
      end
    end
    for (i = 0; i < N_SRC; i = i + 1)
      if (!connected[i] && (src_in_pkt[i] || !routed[i]))
        src_ready[i] = 1'b1;          // drained
  end

  assign s_ready = src_ready;
  assign m_valid = snk_valid;

  genvar g;
  generate
    for (g = 0; g < N_SNK; g = g + 1) begin : g_snk
      wire [3:0] c = cur[g*4 +: 4] < N_SRC ? cur[g*4 +: 4] : 4'd0;   // NONE only while inactive
      assign m_data[g*32 +: 32] = s_data[c*32 +: 32];
      assign m_user[g*72 +: 72] = s_user[c*72 +: 72];
      assign m_last[g] = s_last[c];
    end
  endgenerate

  reg  [3:0] r;
  integer si, sj;
  always @(posedge clk) begin
    if (rst) begin
      src_in_pkt <= {N_SRC{1'b0}};
      active <= {N_SNK{1'b0}};
      cur <= {N_SNK{NONE}};
    end else begin
      for (si = 0; si < N_SRC; si = si + 1)
        if (abort_src[si])
          src_in_pkt[si] <= 1'b0;
        else if (s_valid[si] && src_ready[si])
          src_in_pkt[si] <= !s_last[si];
      for (sj = 0; sj < N_SNK; sj = sj + 1) begin
        r = route_s[sj*4 +: 4];
        if (active[sj]) begin
          if (abort_snk[sj] || abort_src[cur[sj*4 +: 4]] ||
              (snk_valid[sj] && m_ready[sj] && s_last[cur[sj*4 +: 4]]))
            active[sj] <= 1'b0;
        end else if (r < N_SRC && claim_ok(sj, r, route_s) && !src_in_pkt[r] && !connected[r] &&
                     !abort_snk[sj] && !abort_src[r]) begin
          cur[sj*4 +: 4] <= r;
          active[sj] <= 1'b1;
        end
      end
    end
  end

endmodule
