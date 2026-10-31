// ***************************************************************************
// GlideLink user module: FFT / IFFT, the core of the Ettus RFNoC FFT block
// (UHD fpga/usrp3/lib/rfnoc/blocks/rfnoc_block_fft, fft_core, LGPL-3.0-or-later,
// sources unchanged in hw/modules/uhd_rfnoc) in a GlideLink slot: cyclic
// prefix removal / insertion, FFT order, magnitude and magnitude squared, all
// as in RFNoC. This wrapper replaces the RFNoC noc_shell: AXI4-Lite in place
// of CtrlPort, the slot's sc16 stream in place of the RFNoC item stream.
//
// Registers (4 KB window):
//   0x000  ID         RO  0x46465431 ("FFT1")
//   0x004  VERSION    RO  {major[15:0], minor[7:0], patch[7:0]}
//   0x008  CONTROL    RW  bit 0: enable (default 0 = samples pass unchanged),
//                         bit 1: soft reset (self-clearing)
//   0x00C  STATUS     RO  bit 0: enabled, bit 1: busy (switching, resetting)
//   0x010  KEEP       RW  output one FFT packet in every KEEP (default 1 = all;
//                         0 counts as 1), as RFNoC's Keep One in N block in
//                         packet mode: a full-rate spectrum at a host rate
//                         divided by KEEP. Not part of the RFNoC FFT block.
//   0x100..0x17F          the RFNoC FFT block's registers at their RFNoC
//                         offsets + 0x100 (fft_core_regs_pkg.sv): COMPAT 0x100,
//                         CAPABILITIES 0x108, LENGTH_LOG2 0x114, SCALING 0x118,
//                         DIRECTION 0x11C, CP_INS/REM_* 0x120..0x13C,
//                         OVERFLOW 0x140, BYPASS 0x144, ORDER 0x148,
//                         MAGNITUDE 0x14C
//
// Data: the slot's sc16 {Q[31:16], I[15:0]} is RFNoC's {I, Q} with the halves
// swapped; magnitude outputs land in I. Output packets are 2^LENGTH_LOG2
// samples plus the first entry of the cyclic prefix insertion list: one FFT
// per packet while all the list's entries are equal (RFNoC repacketizes the
// output to the input packet size; here that size is set so), with tuser on
// its first beat: the timestamp (of the burst's first input sample, counted
// on as if contiguous, as RFNoC does) and flag bit 1 = end of burst. An input
// packet whose first beat has flag bit 1 ends a burst; the input packet size
// does not matter otherwise.
//
// The core's registers and its two cyclic prefix lists (up to 32 entries
// each) are kept in copies and written back after anything that resets the
// core: shell flush, soft reset, a change of CONTROL.enable or of LENGTH_LOG2.
// The last two wait for the packets in progress to finish (input and output,
// at most DRAIN_MAX cycles) and switch between packets. A write to the core's
// own RESET register (0x110) is passed on and not followed by a write-back.
// The write-back ends by writing ORDER away and back, so that the reorder
// buffer takes its address mask (see S_REPLAY).
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_fft #(
  parameter MAX_FFT_SIZE_LOG2 = 12          // 12 = 4096 (the Xilinx FFT IP is xfft_4k_16b)
) (
  input             clk,
  input             rstn,
  input             flush,                  // stream state only (PORT_RESET): registers kept

  input             s_axil_awvalid,
  output            s_axil_awready,
  input     [11:0]  s_axil_awaddr,
  input             s_axil_wvalid,
  output            s_axil_wready,
  input     [31:0]  s_axil_wdata,
  output            s_axil_bvalid,
  input             s_axil_bready,
  input             s_axil_arvalid,
  output            s_axil_arready,
  input     [11:0]  s_axil_araddr,
  output            s_axil_rvalid,
  input             s_axil_rready,
  output    [31:0]  s_axil_rdata,

  input             s_axis_tvalid,
  output            s_axis_tready,
  input     [31:0]  s_axis_tdata,
  input     [71:0]  s_axis_tuser,
  input             s_axis_tlast,

  output            m_axis_tvalid,
  input             m_axis_tready,
  output    [31:0]  m_axis_tdata,
  output    [71:0]  m_axis_tuser,
  output            m_axis_tlast
);

  localparam [31:0] ID = 32'h46465431;
  localparam [31:0] VERSION = 32'h00010000;
  localparam integer RESET_CYCLES = 16;     // ce_rst, then the core's own 8-cycle user reset
  localparam integer SETTLE_CYCLES = 32;
  localparam integer DRAIN_MAX = 1 << 18;
  localparam integer NSHADOW = 8;

  // core registers written back after a reset (RFNoC offsets)
  function [6:0] shadow_addr(input [2:0] k);
    case (k)
      3'd0: shadow_addr = 7'h14;            // LENGTH_LOG2
      3'd1: shadow_addr = 7'h18;            // SCALING
      3'd2: shadow_addr = 7'h1C;            // DIRECTION
      3'd3: shadow_addr = 7'h20;            // CP_INS_LEN
      3'd4: shadow_addr = 7'h30;            // CP_REM_LEN
      3'd5: shadow_addr = 7'h44;            // BYPASS
      3'd6: shadow_addr = 7'h48;            // ORDER
      default: shadow_addr = 7'h4C;         // MAGNITUDE
    endcase
  endfunction

  function [3:0] shadow_index(input [6:0] a);   // 8 = not a shadowed register
    case (a)
      7'h14: shadow_index = 4'd0;
      7'h18: shadow_index = 4'd1;
      7'h1C: shadow_index = 4'd2;
      7'h20: shadow_index = 4'd3;
      7'h30: shadow_index = 4'd4;
      7'h44: shadow_index = 4'd5;
      7'h48: shadow_index = 4'd6;
      7'h4C: shadow_index = 4'd7;
      default: shadow_index = 4'd8;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // State: RUN, DRAIN (finish the packets in progress), RESET (core in reset),
  // SETTLE (core's own reset sequence), REPLAY (write the shadows back)
  // ---------------------------------------------------------------------------

  localparam [2:0] S_RUN = 3'd0, S_DRAIN = 3'd1, S_RESET = 3'd2, S_SETTLE = 3'd3, S_REPLAY = 3'd4;
  reg  [2:0]  st = S_RESET;
  reg  [18:0] cnt = 19'd0;
  reg  [1:0]  rph = 2'd0;                   // write-back phase: shadows, lists, last writes
  reg  [6:0]  rj = 7'd0;

  reg         enable = 1'b0;                // CONTROL.enable as written
  reg         path = 1'b0;                  // data path in use: 1 = FFT core
  reg  [31:0] shadow [0:NSHADOW-1];
  reg  [NSHADOW-1:0] written = {NSHADOW{1'b0}};
  reg  [4:0]  len_log2 = MAX_FFT_SIZE_LOG2; // LENGTH_LOG2 as written (shadow 0)
  reg  [4:0]  len_active = MAX_FFT_SIZE_LOG2;
  reg  [11:0] cp_active = 12'd0;            // first insertion list entry, in the packet size
  reg         pend_switch = 1'b0;           // enable or LENGTH_LOG2 changed: drain, reset
  reg         pend_reset = 1'b0;            // soft reset: reset now

  // copies of the cyclic prefix lists (the core's are emptied by a reset)
  localparam integer LIST_MAX = 32;         // 2^MAX_CP_LIST_LEN_*_LOG2
  reg  [11:0] ins_list [0:LIST_MAX-1];
  reg  [11:0] rem_list [0:LIST_MAX-1];
  reg  [5:0]  ins_n = 6'd0, rem_n = 6'd0;

  wire        ce_rst = !rstn || st == S_RESET;
  wire [1:0]  order_now = written[6] ? shadow[6][1:0] : 2'd0;    // ORDER (default normal)
  wire [11:0] ins_len_now = written[3] ? shadow[3][11:0] : 12'd0;
  wire [11:0] rem_len_now = written[4] ? shadow[4][11:0] : 12'd0;

  // ---------------------------------------------------------------------------
  // Stream: bypass or the core, switched between packets
  // ---------------------------------------------------------------------------

  reg         in_mid = 1'b0, out_mid = 1'b0;    // inside an input / output packet
  reg  [7:0]  in_flags = 8'd0;
  wire        accept = st == S_RUN || (st == S_DRAIN && in_mid);
  wire        in_first = !in_mid;

  wire        c_in_tready, c_out_tvalid, c_out_tlast, c_out_teob, c_out_thas_time;
  wire [31:0] c_out_tdata;
  wire [63:0] c_out_ttimestamp;

  wire        in_valid = s_axis_tvalid && accept;
  wire        in_ready = path ? c_in_tready : m_axis_tready;
  assign s_axis_tready = accept && in_ready;

  // KEEP: core output packets other than one in every KEEP are taken and dropped
  reg  [15:0] keep = 16'd1;
  reg  [15:0] keep_cnt = 16'd0;
  wire        pass = keep_cnt == 16'd0;

  wire        c_in_tvalid = in_valid && path;
  wire        c_out_tready = path && (m_axis_tready || !pass) && st != S_RESET;

  assign m_axis_tvalid = path ? (c_out_tvalid && pass && st != S_RESET) : in_valid;
  assign m_axis_tdata = path ? {c_out_tdata[15:0], c_out_tdata[31:16]} : s_axis_tdata;
  assign m_axis_tlast = path ? c_out_tlast : s_axis_tlast;
  assign m_axis_tuser = path ? {6'd0, c_out_teob, 1'b0, c_out_thas_time ? c_out_ttimestamp : 64'd0}
                             : s_axis_tuser;

  wire        in_fire = s_axis_tvalid && s_axis_tready;
  wire        out_fire = m_axis_tvalid && m_axis_tready;

  always @(posedge clk) begin
    if (!rstn || flush || st == S_RESET) begin
      in_mid <= 1'b0;
      out_mid <= 1'b0;
      in_flags <= 8'd0;
      keep_cnt <= 16'd0;
    end else begin
      if (c_out_tvalid && c_out_tready && c_out_tlast)
        keep_cnt <= (keep_cnt + 16'd1 >= keep) ? 16'd0 : keep_cnt + 16'd1;
      if (in_fire) begin
        in_mid <= !s_axis_tlast;
        if (in_first)
          in_flags <= s_axis_tuser[71:64];
      end
      if (out_fire)
        out_mid <= !m_axis_tlast;
    end
  end

  // ---------------------------------------------------------------------------
  // CtrlPort to the core: register writes / reads from AXI4-Lite, write-back
  // ---------------------------------------------------------------------------

  reg         cp_wr = 1'b0, cp_rd = 1'b0;
  reg  [19:0] cp_addr = 20'd0;
  reg  [31:0] cp_data = 32'd0;
  wire        cp_ack;
  wire [31:0] cp_resp;

  // AXI4-Lite: one access at a time; core registers through CtrlPort
  reg         awready = 1'b0, wready = 1'b0, bvalid = 1'b0, arready = 1'b0, rvalid = 1'b0;
  reg  [31:0] rdata = 32'd0;
  reg         rd_wait = 1'b0;
  reg  [5:0]  rd_cnt = 6'd0;
  wire        core_ok = st == S_RUN || st == S_DRAIN;   // core out of reset, no write-back
  wire        aw_go = s_axil_awvalid && s_axil_wvalid && !bvalid && !awready && core_ok;
  wire        ar_go = s_axil_arvalid && !rvalid && !arready && !rd_wait && core_ok && !aw_go;
  wire        a_core_w = s_axil_awaddr[11:7] == 5'b00010;   // 0x100..0x17F
  wire        a_core_r = s_axil_araddr[11:7] == 5'b00010;
  wire [3:0]  w_shadow = shadow_index(s_axil_awaddr[6:0]);

  assign s_axil_awready = awready;
  assign s_axil_wready = wready;
  assign s_axil_bvalid = bvalid;
  assign s_axil_arready = arready;
  assign s_axil_rvalid = rvalid;
  assign s_axil_rdata = rdata;

  integer k;
  always @(posedge clk) begin
    cp_wr <= 1'b0;
    cp_rd <= 1'b0;
    awready <= 1'b0;
    wready <= 1'b0;
    arready <= 1'b0;
    pend_reset <= 1'b0;
    if (bvalid && s_axil_bready)
      bvalid <= 1'b0;
    if (rvalid && s_axil_rready)
      rvalid <= 1'b0;

    // writes
    if (awready)                             // response the cycle after the handshake
      bvalid <= 1'b1;
    if (aw_go) begin
      awready <= 1'b1;
      wready <= 1'b1;
      if (a_core_w) begin
        if (w_shadow != 4'd8) begin
          shadow[w_shadow[2:0]] <= s_axil_wdata;
          written[w_shadow[2:0]] <= 1'b1;
        end
        case (s_axil_awaddr[6:0])            // list copies follow the core's lists
          // the insertion list sets the output packet size: change it between packets
          7'h24: if (ins_n < LIST_MAX) begin
                   ins_list[ins_n[4:0]] <= ins_len_now; ins_n <= ins_n + 6'd1; pend_switch <= 1'b1;
                 end
          7'h28: begin ins_n <= 6'd0; pend_switch <= 1'b1; end
          7'h34: if (rem_n < LIST_MAX) begin rem_list[rem_n[4:0]] <= rem_len_now; rem_n <= rem_n + 6'd1; end
          7'h38: rem_n <= 6'd0;
          default: ;
        endcase
        if (w_shadow == 4'd0) begin          // LENGTH_LOG2: through the write-back
          len_log2 <= s_axil_wdata[4:0];
          pend_switch <= 1'b1;
        end else begin
          cp_wr <= 1'b1;
          cp_addr <= {13'd0, s_axil_awaddr[6:0]};
          cp_data <= s_axil_wdata;
        end
      end else if (s_axil_awaddr[11:2] == 10'h004) begin
        keep <= s_axil_wdata[15:0];
      end else if (s_axil_awaddr[11:2] == 10'h002) begin
        if (s_axil_wdata[0] != enable)
          pend_switch <= 1'b1;
        enable <= s_axil_wdata[0];
        pend_reset <= s_axil_wdata[1];
      end
    end

    // reads
    if (ar_go) begin
      arready <= 1'b1;
      if (a_core_r) begin
        cp_rd <= 1'b1;
        cp_addr <= {13'd0, s_axil_araddr[6:0]};
        rd_wait <= 1'b1;
        rd_cnt <= 6'd0;
      end else begin
        rvalid <= 1'b1;
        case (s_axil_araddr[11:2])
          10'h000: rdata <= ID;
          10'h001: rdata <= VERSION;
          10'h002: rdata <= {31'd0, enable};
          10'h003: rdata <= {30'd0, st != S_RUN, path};
          10'h004: rdata <= {16'd0, keep};
          default: rdata <= 32'd0;
        endcase
      end
    end
    if (rd_wait) begin
      rd_cnt <= rd_cnt + 6'd1;
      if (cp_ack || &rd_cnt) begin           // no answer (core in reset): 0
        rd_wait <= 1'b0;
        rvalid <= 1'b1;
        rdata <= cp_ack ? cp_resp : 32'd0;
      end
    end

    // reset / switch sequence
    case (st)
      S_RUN: begin
        cnt <= 19'd0;
        if (pend_switch)
          st <= S_DRAIN;
      end
      S_DRAIN: begin                         // stop taking input between packets, let output finish
        cnt <= cnt + 19'd1;
        if ((!in_mid && !out_mid) || cnt == DRAIN_MAX - 1) begin
          st <= S_RESET;
          cnt <= 19'd0;
        end
      end
      S_RESET: begin
        cnt <= cnt + 19'd1;
        pend_switch <= 1'b0;
        path <= enable;
        len_active <= len_log2;
        cp_active <= ins_n != 6'd0 ? ins_list[0] : 12'd0;
        if (cnt == RESET_CYCLES - 1) begin
          st <= S_SETTLE;
          cnt <= 19'd0;
        end
      end
      S_SETTLE: begin
        cnt <= cnt + 19'd1;
        rph <= 2'd0;
        rj <= 7'd0;
        if (cnt == SETTLE_CYCLES - 1)
          st <= S_REPLAY;
      end
      default: begin                         // S_REPLAY: one CtrlPort write per cycle
        rj <= rj + 7'd1;
        case (rph)
          2'd0: begin                        // the shadowed registers
            if (written[rj[2:0]]) begin
              cp_wr <= 1'b1;
              cp_addr <= {13'd0, shadow_addr(rj[2:0])};
              cp_data <= shadow[rj[2:0]];
            end
            if (rj == NSHADOW - 1) begin rph <= 2'd1; rj <= 7'd0; end
          end
          2'd1: begin                        // the insertion list: LEN, LOAD per entry
            if (rj < {ins_n, 1'b0}) begin
              cp_wr <= 1'b1;
              cp_addr <= rj[0] ? 20'h24 : 20'h20;
              cp_data <= {20'd0, ins_list[rj[5:1]]};
            end else begin
              rph <= 2'd2; rj <= 7'd0;
            end
          end
          2'd2: begin                        // the removal list
            if (rj < {rem_n, 1'b0}) begin
              cp_wr <= 1'b1;
              cp_addr <= rj[0] ? 20'h34 : 20'h30;
              cp_data <= {20'd0, rem_list[rj[5:1]]};
            end else begin
              rph <= 2'd3; rj <= 7'd0;
            end
          end
          default: begin
            // CP_*_LEN as written (the lists went through them), then ORDER away and back:
            // fft_reorder loads its write address mask when the order or the size changes (or
            // after an FFT), and its change detector has no reset, so after a reset that leaves
            // both at their defaults the first FFT would use whatever mask was there
            cp_wr <= rj < 7'd4;
            case (rj[1:0])
              2'd0: begin cp_addr <= 20'h20; cp_data <= {20'd0, ins_len_now}; end
              2'd1: begin cp_addr <= 20'h30; cp_data <= {20'd0, rem_len_now}; end
              2'd2: begin cp_addr <= 20'h48; cp_data <= {30'd0, order_now ^ 2'd1}; end
              default: begin cp_addr <= 20'h48; cp_data <= {30'd0, order_now}; end
            endcase
            if (rj == 7'd6)
              st <= S_RUN;
          end
        endcase
      end
    endcase

    if (flush || pend_reset) begin
      st <= S_RESET;
      cnt <= 19'd0;
    end

    if (!rstn) begin
      st <= S_RESET;
      cnt <= 19'd0;
      enable <= 1'b0;
      path <= 1'b0;
      keep <= 16'd1;
      written <= {NSHADOW{1'b0}};
      ins_n <= 6'd0;
      rem_n <= 6'd0;
      len_log2 <= MAX_FFT_SIZE_LOG2;
      len_active <= MAX_FFT_SIZE_LOG2;
      cp_active <= 12'd0;
      pend_switch <= 1'b0;
      awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0;
      arready <= 1'b0; rvalid <= 1'b0; rd_wait <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // The RFNoC FFT core
  // ---------------------------------------------------------------------------

  // output packet size in bytes: one FFT and the first insertion list entry
  wire [15:0] c_in_tlength = (16'd4 << len_active) + {2'd0, cp_active, 2'd0};

  fft_core #(
    .NIPC                    (1),
    .NUM_CHAN                (1),
    .NUM_CORES               (1),
    .MAX_PKT_SIZE_LOG2       (MAX_FFT_SIZE_LOG2),
    .MAX_FFT_SIZE_LOG2       (MAX_FFT_SIZE_LOG2),
    .MAX_CP_LIST_LEN_INS_LOG2(5),
    .MAX_CP_LIST_LEN_REM_LOG2(5),
    .EN_CP_REMOVAL           (1),
    .EN_CP_INSERTION         (1),
    .CP_INSERTION_REPEAT     (1),
    .CP_REMOVAL_REPEAT       (1),
    .EN_FFT_BYPASS           (1),
    .EN_FFT_ORDER            (1),
    .EN_MAGNITUDE            (1),
    .EN_MAGNITUDE_SQ         (1),
    .USE_APPROX_MAG          (1)
  ) i_core (
    .ce_clk               (clk),
    .ce_rst               (ce_rst),
    .s_ctrlport_req_wr    (cp_wr),
    .s_ctrlport_req_rd    (cp_rd),
    .s_ctrlport_req_addr  (cp_addr),
    .s_ctrlport_req_data  (cp_data),
    .s_ctrlport_resp_ack  (cp_ack),
    .s_ctrlport_resp_data (cp_resp),
    .s_in_axis_tdata      ({s_axis_tdata[15:0], s_axis_tdata[31:16]}),
    .s_in_axis_tkeep      (1'b1),
    .s_in_axis_tlast      (s_axis_tlast),
    .s_in_axis_tvalid     (c_in_tvalid),
    .s_in_axis_tready     (c_in_tready),
    .s_in_axis_ttimestamp (s_axis_tuser[63:0]),
    .s_in_axis_thas_time  (1'b1),
    .s_in_axis_tlength    (c_in_tlength),
    .s_in_axis_teov       (1'b0),
    .s_in_axis_teob       (in_first ? s_axis_tuser[65] : in_flags[1]),
    .m_out_axis_tdata     (c_out_tdata),
    .m_out_axis_tkeep     (),
    .m_out_axis_tlast     (c_out_tlast),
    .m_out_axis_tvalid    (c_out_tvalid),
    .m_out_axis_tready    (c_out_tready),
    .m_out_axis_ttimestamp(c_out_ttimestamp),
    .m_out_axis_thas_time (c_out_thas_time),
    .m_out_axis_tlength   (),
    .m_out_axis_teov      (),
    .m_out_axis_teob      (c_out_teob)
  );

endmodule
