# phy_common

OFDM 模块（`ofdm_tx`、`ofdm_rx`）共用的源文件库：AXI4-Stream FIFO 和寄存器级、FFT 移位、PN 符号加扰、
URAM 帧 FIFO。原样复制自竞赛设计（Vimcovan/glidelink-fpga @ 8367bee，`src/hw/{tx,rx}/rtl/phy/{ofdm_tx,jscc}`；
其中 TX 与 RX 两份完全相同）。各模块在 `module.yaml` 的 `uses:` 中引用它。
