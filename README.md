# GlideLink SDR

基于 PYNQ-ZU + AD9361 FMC 子卡的通信算法原型验证平台：算法先在 MATLAB 或 GNU Radio 中用真实射频验证，再把模块逐个卸载到
PL（参考 RFNoC 的思路，用户可加入自己的 FPGA 模块），最终脱离 PC 运行。

本项目在竞赛作品 [GlideLink](https://github.com/Vimcovan/glidelink-fpga) 的基础上发展而来。

## 现在能做什么

| 用法 | 入口 | 说明 |
|---|---|---|
| MATLAB | [`sw/matlab`](sw/matlab/README.md) | `glidelink.Radio` 经板上的桥接服务收发；QPSK、2-FSK、CSS、802.11a/g OFDM、定时突发等示例；MathWorks USRP / Pluto / WLAN 官方例程移植版 |
| GNU Radio | [`sw/gr-glidelink`](sw/gr-glidelink/README.md) | GlideLink Source / Sink 块（板子地址、频率、采样率、增益模式），PL 路由与模块控制块，示例流程图 |
| SoapySDR 工具 | [`sw/soapy-glidelink`](sw/soapy-glidelink/README.md) | `driver=glidelink,uri=ip:<板子>`：GQRX、SoapySDRUtil、自己的 Python / C++ 程序 |
| 自己的 FPGA 模块 | [`docs/design.md`](docs/design.md) 第 5 节、[`hw/modules`](hw/modules) | AXI4-Stream 模块放进外壳的槽位，软件模型与 PL 实现可互换 |
| 脱离 PC 运行 | [`sw/offline`](sw/offline) | 守护程序加载镜像、配置射频与模块；DeepJSCC-Q 图像传输（竞赛系统）已迁移到平台上 |

采样率 0.52～50 MSPS（板上）；经 USB 网口到 PC 的连续流收发同时各 50 MSPS（Windows 原生程序，板上 UDP 流服务 `sw/streamd`；WSL 中发射约 48 MSPS），桥接服务先在板上采集再发给 PC，不受此限。

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/user_guide.md`](docs/user_guide.md) | 使用指南：连接板子、板上服务、各种用法、常用操作 |
| [`docs/qpsk_tutorial.md`](docs/qpsk_tutorial.md) | 教程：QPSK 收发，从纯软件流程图一步步把信号处理卸载到 PL |
| [`docs/pc_setup.md`](docs/pc_setup.md) | 电脑端环境：WSL（GNU Radio、Soapy、图形桌面）、MATLAB 及支持包 |
| [`docs/known_issues.md`](docs/known_issues.md) | 已知问题与注意事项 |
| [`docs/design.md`](docs/design.md) | 设计文档：架构、外壳、模块接口、主机软件 |
| `docs/phase*.md`、[`docs/matlab_plan.md`](docs/matlab_plan.md) | 各阶段的决定、实施与实测结果 |
| [`hw/README.md`](hw/README.md)、[`os/kernel/README.md`](os/kernel/README.md) | PL 工程与内核的构建 |

## 目录

| 路径 | 内容 |
|---|---|
| `hw/` | PL 工程：外壳（`library/glidelink_shell`）、用户模块（`modules/`）、镜像配置（`images/`）、设备树叠加（`dts/`） |
| `os/kernel/` | ADI 内核的配置、补丁与平台驱动 |
| `sw/bridge/` | 板上的桥接服务（MATLAB 用，TCP 7030） |
| `sw/soapy-glidelink/` | SoapySDR 模块 |
| `sw/gr-glidelink/` | GNU Radio OOT 模块 |
| `sw/gnuradio/` | 不经 GRC 的 GNU Radio 脚本（板间 QPSK、频谱） |
| `sw/matlab/` | MATLAB 包与示例 |
| `sw/offline/` | 脱机系统（守护程序、收发应用、测量工具） |
| `sw/pc/` | 电脑端辅助脚本（WSL 图形桌面） |
| `sw/tests/` | 板上与两板之间的测试 |
| `data/` | 测量数据 |
