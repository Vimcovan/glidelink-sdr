# UHD RFNoC 源文件（第三方）

本目录是 Ettus Research UHD 仓库中 RFNoC FFT 块的处理核心及其用到的通用库文件，供 `hw/modules/fft` 使用（`module.yaml` 中 `uses: [uhd_rfnoc]`）。

| 项目 | 内容 |
|---|---|
| 来源 | https://github.com/EttusResearch/uhd ，提交 d1be634（2026-10-13） |
| 原路径 | `fpga/usrp3/lib/rfnoc/blocks/rfnoc_block_fft`、`fpga/usrp3/lib/{axi,fifo,control,rfnoc,rfnoc/core}` |
| 许可 | 各文件头 `SPDX-License-Identifier: LGPL-3.0-or-later`；许可证全文见本目录 `COPYING.LESSER`（LGPL-3.0）与 `COPYING`（LGPL-3.0 所依据的 GPL-3.0） |
| 改动 | 无：文件按原样复制，文件名不变。适配 GlideLink 槽位的部分全部在 `hw/modules/fft/glidelink_fft.sv` 中 |

只保留了 FFT 核心实际例化到的文件（按 xsim 展开结果筛选），没有复制 RFNoC 的 noc_shell、CHDR 与 UHD 主机软件。
FFT 运算本身由 Xilinx FFT IP（`hw/modules/fft/ip/xfft_4k_16b.xci`，按 UHD 的设置重新指定到 xczu5eg）完成，该 IP 随 Vivado 提供，不属于上述许可。

更新到新版 UHD 时，按原路径重新复制同名文件，再跑 `hw/modules/fft` 的仿真（见该目录 `model.py` 与 `hw/library/glidelink_module/tb/run_module_sim.ps1`）。
