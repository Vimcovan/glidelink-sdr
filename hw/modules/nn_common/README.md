# nn_common

DeepJSCC-Q 网络模块（`jscc_enc`、`jscc_dec`）共用的源文件库：卷积引擎、行 / 像素缓存、GDN、sigmoid、
分段线性函数支持、ROM 和 FIFO。原样复制自竞赛设计（Vimcovan/glidelink-fpga @ 8367bee，
`src/hw/{tx,rx}/rtl/network/rtl`；其中 TX 与 RX 两份完全相同）。各模块在 `module.yaml` 的 `uses:` 中引用它。
