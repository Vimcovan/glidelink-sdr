# phy_common

Source library shared by the OFDM modules (`ofdm_tx`, `ofdm_rx`): AXI4-Stream FIFOs and
registers, FFT shift, PN sign scrambler, URAM frame FIFO. Copied unchanged from the competition
design (Vimcovan/glidelink-fpga @ 8367bee, `src/hw/{tx,rx}/rtl/phy/{ofdm_tx,jscc}`; the TX and RX
copies there are identical). Modules list it under `uses:` in their `module.yaml`.
