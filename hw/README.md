# PL 工程

射频底座用 ADI HDL（分支 `hdl_2026_r1`）的 fmcomms2 设计，移植到 PYNQ-ZU：`axi_ad9361` + 两路 `axi_dmac` +
`util_cpack2` / `util_upack2`，Linux 端用 ADI 内核中的 ad9361、cf_axi_adc / dds 与 axi-dmac 驱动（见 `os/kernel`）。

## 目录

| 路径 | 内容 |
|---|---|
| `adi-patches/` | 对 ADI HDL 的补丁 |
| `projects/common/pynqzu/` | PYNQ-ZU 载板部分：PS 配置（`ps_config_list.txt`，取自板上 PYNQ 镜像）与 `pynqzu_system_bd.tcl` |
| `projects/fmcomms2_pynqzu/` | AD9361 FMC 子卡工程：block design、顶层、引脚约束 |
| `dts/` | 与比特流配套的设备树叠加 |
| `scripts/` | 打补丁、打包 ADI IP、板上加载比特流与叠加的脚本 |

## 与 ADI zcu102 工程的差别

- PS 从 PYNQ-ZU 的配置出发，不用板卡预设。PL 侧接口只保留 ADI 设计用到的：HPM0_LPD（寄存器）、HPC0 / HPC1（DMA）、
  PL 时钟 100 / 250 / 500 MHz、两路中断、95 位 EMIO GPIO。
- FMC 的 SPI 用 PL 中的 AXI Quad SPI（`axi_spi`，SCK 6.25 MHz），不用 PS 的 SPI：PYNQ-ZU 的启动配置把 SPI0 接到了
  MIO 38–43，SPI1 不在启动时的电源管理配置中（PMU 固件拒绝访问，驱动报 `-EACCES`），这两点加载 overlay 都改不了。
  设备树叠加中 AD9361 挂在 `axi_spi` 下。
- 引脚沿用竞赛工程。CTRL_OUT[7:0] 接 `gpio_status`，CTRL_IN[3:0] 接 `gpio_ctl`，GPIO 编号与 ADI zcu102 相同
  （EMIO GPIO n 对应 Linux gpio 78 + n）。
- SW0（AA12）选择 TX 数据线对 D5 的极性：拨上时 D5 取反，用于 D5 的 P/N 在子卡上对调的第三方 AD9361 FMC 子卡；
  拨下用于 AD-FMCOMMS3。`axi_ad9361` 没有这个功能，由补丁 `0001-axi_ad9361-tx-data-invert.patch` 加入
  `tx_data_invert[5:0]` 输入（默认 0，同步到 l_clk 后与 TX 数据异或）。开关位置可从 EMIO GPIO 0 读回。
- 设备树叠加不标 `dma-coherent`：PYNQ 的启动配置没有为 HPC 端口设置缓存一致性，由内核做缓存维护。
- 设备树叠加中外设总线的 compatible 用 `simple-pm-bus`：6.6 内核对叠加加入的纯 `simple-bus` 节点不创建子设备。
  ADI `adi-fmcomms2.dtsi` 中 40 MHz 参考时钟所在的 `/clocks` 节点也要是 `simple-pm-bus`，`build_dtbo.sh` 编译时把
  compatible 直接加进该节点：另写一个片段修改 `/clocks` 时，内核以"多个片段添加同一节点"拒绝整个叠加。
- AD9361 的 LVDS 极性寄存器（0x03D / 0x03E）用 ADI 驱动默认值 0xFF / 0x0F。第三方子卡 D5 的极性由 SW0 在 PL 中校正，
  设备树不需要改动；SW0 位置不对时 TX 数字接口调校全部失败，`cf_axi_adc` 探测报 `-EIO`。

## 构建

本机 Vivado 2025.2；`hdl_2026_r1` 要求 2025.1，脚本中设置 `ADI_IGNORE_VERSION_CHECK=1` 放宽版本检查。

```bash
bash hw/scripts/prepare_adi_hdl.sh <adi-hdl>
VIVADO=<vivado> bash hw/scripts/build_adi_libs.sh <adi-hdl>
cd hw/projects/fmcomms2_pynqzu && ADI_HDL_DIR=<adi-hdl> ADI_IGNORE_VERSION_CHECK=1 vivado -mode batch -source system_project.tcl
```

设备树叠加在 WSL 中用 ADI 内核树的 dtc 编译：`bash hw/dts/build_dtbo.sh /root/sdr/linux <输出目录>`。

## 加载

在板上以 root 运行，比特流旁需有同名 `.hwh`：

```bash
bash load_overlay.sh fmcomms2_pynqzu.bit fmcomms2_pynqzu.dtbo
```

脚本先经 PYNQ 只下载比特流，再把叠加直接写入 configfs。由 PYNQ 插入该叠加（`Overlay(bit, dtbo=...)`）时内核报
"multiple fragments add node /clocks"，同一文件手动写入则正常，原因尚未查明。叠加加载后无法干净移除，重新加载需重启。

加载成功后应有 IIO 设备 `ad9361-phy`、`cf-ad9361-lpc`、`cf-ad9361-dds-core-lpc`。
