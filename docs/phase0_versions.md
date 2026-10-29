# 第 0 阶段：版本匹配的验证结果（2026-10-29）

对应设计文档第 10 节的风险 1、2。

## 1. HDL 与 Vivado

| ADI HDL 分支 | 要求的 Vivado 版本（`scripts/adi_env.tcl`） |
|---|---|
| `main` | 2026.1 |
| `hdl_2026_r1` | 2025.1 |
| `hdl_2023_r2` | 2023.2 |

本机为 Vivado 2025.2。选用 `hdl_2026_r1`：只差一个小版本，ADI 的脚本允许用 `REQUIRED_VIVADO_VERSION` 环境变量放宽版本检查，
需要自行确认 IP 升级后的综合结果。`projects/fmcomms2/zcu102`（ZynqMP + AD9361）是移植到 PYNQ-ZU 的起点，
其 PS 配置换成 PYNQ-ZU 的，引脚约束沿用竞赛工程。

## 2. 内核驱动

### 2.1 板上内核

`6.6.10-xilinx-v2024.1`。相关配置：`CONFIG_IIO=y`（IIO 核心编进内核，不是模块）、`CONFIG_IIO_BUFFER=y`，
没有 `IIO_BUFFER_DMA`、`IIO_BUFFER_DMAENGINE`、`AXI_DMAC`；`CONFIG_OF_OVERLAY=y`（可用设备树叠加）。
内核在 `/boot/image.ub` 中；已加载的外部模块有 `zocl`（PYNQ 使用）、`wilc_sdio`、`lima` 等。

### 2.2 ADI 内核分支

ADI Linux 有 `adi-6.6.0` 分支（内核 6.6.0），与板上内核主版本一致；`2026_R1` 为 6.12，`2023_R2` 为 6.1。

### 2.3 以外部模块方式编译的试验

在板上用私有内核构建树（竞赛工程补编 lima 时建立），把 `adi-6.6.0` 的以下驱动按外部模块编译（`-k`，看全部错误）：

| 模块 | 结果 |
|---|---|
| `ad9361_drv`（ad9361.c、ad9361_conv.c） | 编译通过 |
| `industrialio-buffer-dma`、`industrialio-buffer-dmaengine` | 失败：ADI 版本使用了 IIO 核心中的 DMABUF 接口（`iio_buffer_access_funcs` 的 `enqueue_dmabuf`、`lock_queue` 等）与 `struct dma_vec`，板上内核的 IIO 核心没有 |
| `dma-axi-dmac` | 失败：同样用到 `struct dma_vec` 与 `device_prep_peripheral_dma_vec` |
| `cf_axi_adc`、`cf_axi_dds_drv` | 失败：用到 ADI 在 IIO 核心中新增的 `IIO_CHAN_INFO_CALIBPHASE`；DDS 的发送缓冲依赖 ADI 新增的 `devm_iio_dmaengine_buffer_setup_with_ops` 与输出方向的 DMA 缓冲 |

结论：AD9361 的控制驱动可以直接用，但数据通路（DMA 缓冲）依赖 ADI 对 IIO 核心的修改，而板上内核的 IIO 核心是编进内核的，
不能只靠外部模块替换。

## 3. 三条可选路线

| 路线 | 做法 | 代价与风险 |
|---|---|---|
| K1：保留 PYNQ 内核，移植驱动 | `ad9361_drv` 直接用；DMA 缓冲改用板上内核版本（6.6 主线）的 `industrialio-buffer-dma` / `dmaengine` 与 `dma-axi-dmac` 编成模块；修改 `cf_axi_adc` / `cf_axi_dds`：去掉 `CALIBPHASE`，并为 6.6 主线的 DMA 缓冲补上输出方向（TX） | 不动启动文件；要维护一份与 ADI 上游分叉的驱动补丁，TX 输出缓冲需要自己移植并测试；以后跟随 ADI 更新较麻烦 |
| K2：用 ADI 的 `adi-6.6.0` 内核替换 PYNQ 内核 | 以 PYNQ 的内核配置为基础，在 ADI 内核树中打开 AD9361、AXI ADC / DDS、AXI DMAC 与 DMA 缓冲，重新打包 `image.ub`（内核 + PYNQ-ZU 设备树）；`zocl`、`wilc_sdio`、`lima` 针对新内核重新编译 | 驱动与 ADI 上游完全一致；要替换启动分区中的内核文件（先备份，失败时在 PC 上用 SD 卡恢复）；PYNQ 依赖的 `zocl` 能否在新内核上编译运行需要验证 |
| K3：换用 ADI Kuiper 镜像 | Kuiper（ADI 的 Linux 发行版）自带全部驱动与 libiio、GNU Radio | 需要为 PYNQ-ZU 制作启动文件与设备树；失去 PYNQ 环境（竞赛工程的上层软件、Overlay 加载方式都要改） |

建议 K2：数据通路与 ADI 上游一致，之后的驱动问题可以直接对照 ADI 的文档和社区；PYNQ 环境保留。
它的主要风险（`zocl` 重编、启动文件替换）可以先在一张备用 SD 卡上验证，不影响现在能用的系统。

板上的试验文件在 `/home/xilinx/claude/sdr/adimod/`（只编译，未加载任何模块）。
