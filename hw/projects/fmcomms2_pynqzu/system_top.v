// ***************************************************************************
// AD9361 FMC card on PYNQ-ZU: top level of the ADI fmcomms2 design
//
// Adapted from ADI hdl projects/fmcomms2/zcu102/system_top.v (ADIBSD).
// Differences: no board GPIO (LEDs/buttons); the FMC SPI is an AXI Quad SPI;
// SW0 selects the TX LVDS polarity of data pair D5 (1: P/N swapped on the card,
// as on the third-party AD9361 FMC card; 0: AD-FMCOMMS3) and reads back on
// EMIO GPIO 0.
// ***************************************************************************

`timescale 1ns/100ps

module system_top (

  input           rx_clk_in_p,
  input           rx_clk_in_n,
  input           rx_frame_in_p,
  input           rx_frame_in_n,
  input   [ 5:0]  rx_data_in_p,
  input   [ 5:0]  rx_data_in_n,
  output          tx_clk_out_p,
  output          tx_clk_out_n,
  output          tx_frame_out_p,
  output          tx_frame_out_n,
  output  [ 5:0]  tx_data_out_p,
  output  [ 5:0]  tx_data_out_n,

  output          enable,
  output          txnrx,

  output          gpio_resetb,
  output          gpio_sync,
  output          gpio_en_agc,
  output  [ 3:0]  gpio_ctl,
  input   [ 7:0]  gpio_status,

  output          spi_csn,
  output          spi_clk,
  output          spi_mosi,
  input           spi_miso,

  input           sw_tx_swap
);

  // TX LVDS data pairs whose polarity SW0 inverts (D5)

  localparam [5:0] TX_SWAP_PAIRS = 6'b100000;

  // internal signals

  wire    [94:0]  gpio_i;
  wire    [94:0]  gpio_o;
  wire    [ 0:0]  spi_csn_o;
  wire            spi_clk_o;
  wire            spi_sdo_o;

  // defaults

  assign gpio_resetb = gpio_o[46:46];
  assign gpio_sync = gpio_o[45:45];
  assign gpio_en_agc = gpio_o[44:44];
  assign gpio_ctl = gpio_o[43:40];

  assign gpio_i[94:40] = gpio_o[94:40];
  assign gpio_i[39:32] = gpio_status;
  assign gpio_i[31: 1] = gpio_o[31: 1];
  assign gpio_i[ 0: 0] = sw_tx_swap;

  assign spi_csn = spi_csn_o[0];
  assign spi_clk = spi_clk_o;
  assign spi_mosi = spi_sdo_o;

  // instantiations

  system_wrapper i_system_wrapper (
    .ctrl_out (gpio_status),
    .enable (enable),
    .gpio_i (gpio_i),
    .gpio_o (gpio_o),
    .gpio_t (),
    .rx_clk_in_n (rx_clk_in_n),
    .rx_clk_in_p (rx_clk_in_p),
    .rx_data_in_n (rx_data_in_n),
    .rx_data_in_p (rx_data_in_p),
    .rx_frame_in_n (rx_frame_in_n),
    .rx_frame_in_p (rx_frame_in_p),
    .spi_csn_i (spi_csn_o),
    .spi_csn_o (spi_csn_o),
    .spi_clk_i (spi_clk_o),
    .spi_clk_o (spi_clk_o),
    .spi_sdo_i (spi_sdo_o),
    .spi_sdo_o (spi_sdo_o),
    .spi_sdi_i (spi_miso),
    .tdd_sync_i (1'b0),
    .tdd_sync_o (),
    .tdd_sync_t (),
    .tx_clk_out_n (tx_clk_out_n),
    .tx_clk_out_p (tx_clk_out_p),
    .tx_data_out_n (tx_data_out_n),
    .tx_data_out_p (tx_data_out_p),
    .tx_data_invert (sw_tx_swap ? TX_SWAP_PAIRS : 6'd0),
    .tx_frame_out_n (tx_frame_out_n),
    .tx_frame_out_p (tx_frame_out_p),
    .txnrx (txnrx),
    .up_enable (gpio_o[47]),
    .up_txnrx (gpio_o[48]));

endmodule
