`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// axis_pack8: decoder image stream (one byte per beat, s_tlast on the last byte of a frame) ->
//   32-bit words, byte k of the frame in bits [8*(k%4) +: 8] (little endian, the order of a numpy
//   uint8 array), m_tlast on the last word of the frame. The counterpart of jscc_enc's axis_unpack8.
//////////////////////////////////////////////////////////////////////////////////
module axis_pack8 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [7:0]  s_tdata,
    input  logic        s_tvalid,
    output logic        s_tready,
    input  logic        s_tlast,
    output logic [31:0] m_tdata,
    output logic        m_tvalid,
    input  logic        m_tready,
    output logic        m_tlast
);
    logic [23:0] acc;
    logic [1:0]  idx;
    assign s_tready = ~m_tvalid | m_tready;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin acc <= '0; idx <= '0; m_tdata <= '0; m_tvalid <= 1'b0; m_tlast <= 1'b0; end
        else begin
            if (m_tvalid & m_tready) m_tvalid <= 1'b0;
            if (s_tvalid & s_tready) begin
                if (idx == 2'd3 || s_tlast) begin
                    m_tdata  <= {s_tdata, acc};
                    m_tlast  <= s_tlast;
                    m_tvalid <= 1'b1;
                    idx      <= '0;
                end else begin
                    acc[8*idx +: 8] <= s_tdata;
                    idx <= idx + 1'b1;
                end
            end
        end
    end
endmodule
