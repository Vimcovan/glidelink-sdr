# MATLAB 接入（方案）

目标：通信算法在 MATLAB 中验证时，直接用 GlideLink 板收发与调用 PL 模块，不需要在 PC 上另装驱动或支持包。

第一个验收场景用 QPSK：MATLAB 生成波形，经 TX 板发出、RX 板收下，回到 MATLAB 完成同步与解调，统计误码率与 EVM。

## 1. 决定

| 编号 | 内容 | 决定 | 理由 |
|---|---|---|---|
| M1 | 接入方式 | 板上运行桥接服务 `glidelink_bridge.py`，MATLAB 用自带的 `tcpclient` 连接；MATLAB 侧提供 `+glidelink` 包 | PC 上只需 MATLAB 本体（本机 R2025b），不装 libiio、Soapy 或 ADI 支持包；桥接服务在板上调用 Soapy，平台的全部功能（定时突发、主机端口 1、路由、寄存器、驱动参数）都能用，语义与 GNU Radio 一侧相同 |
| M2 | 协议 | TCP，端口 7030；每个请求与应答是一行 JSON（MATLAB 的 `jsonencode` / `jsondecode` 与 Python 的 `json` 都是内置的）；样点块紧跟在 JSON 行之后，长度在 JSON 中给出 | 控制命令可读、易扩展；样点按二进制传输，不经文本转换 |
| M3 | 样点格式 | 射频端口：CS16（`int16` 交织 I/Q，12 位满量程，与 Soapy 的约定相同），MATLAB 侧换成 `±1` 归一化的复数 `double`；主机端口 1：32 位字原样（`uint32`），也可按 `{Q, I}` 取复数 | 射频样点与 GNU Radio、Soapy 一侧一致；模块数据不一定是射频样点，原样传递 |
| M4 | TX 方式 | 三种：循环发送（波形一次传到板上，由桥接服务在板上反复写入 DMA，等同 ADI 工具箱的 `EnableCyclicBuffers`）；连续流式发送；定时突发（给定硬件时间，结尾标突发结束） | 算法验证大多是“一段波形反复发”，循环发送不占网络带宽，速率不受 USB 网口约 7 MSPS 的限制 |
| M5 | RX 方式 | 两种：一次取 N 个连续样点（桥接服务先在板上读满，再整块传回，保证中间无丢失，长度受板上内存限制）；连续流式接收（尽力而为，报告溢出） | 板上先缓存再传，取回的数据一定连续，与网络速率无关 |
| M6 | 与脱机服务的关系 | 桥接服务与 `glidelinkd@*` 及其应用互斥（systemd `Conflicts=`）；打开射频时按请求设置路由（默认 RF ↔ 主机端口 0），清理链路上的槽位 | 脱机服务占用射频与路由；桥接服务适用于任何镜像（demo、phy_test、tx、rx） |
| M7 | MATLAB 包 | `sw/matlab/+glidelink`：`Radio`（射频收发、频点、采样率、带宽、增益与增益模式、驱动参数、硬件时间、定时突发）、`HostPort`（主机端口 1 收发）、`Shell`（路由、寄存器、端口清理）；普通 handle 类，每块板一个连接 | 与 gr-glidelink 的划分一致（控制、主机端口、射频）；先用普通类，Simulink 块与 System object 之后再加 |
| M8 | 示例的位置 | `sw/matlab/examples/`：每个示例一个脚本，开头写明需要的镜像与板子连接方式 | 用户照着示例改，就能接入自己的算法 |

## 2. QPSK 验收场景

参数：915 MHz，1 MSPS，根升余弦成形，每符号 4 个样点（250 k 符号/s），滚降 0.35。

帧结构：一段已知前导，后接 PRBS 数据，用 QPSK 调制，每帧约 2000 个符号。TX 波形中帧与帧之间留少量空白，整段循环发送。

MATLAB 接收端使用 Communications Toolbox 的标准模块：自动增益 → 粗频偏补偿（`comm.CoarseFrequencyCompensator`）→ 符号定时同步（`comm.SymbolSynchronizer`）→ 载波同步（`comm.CarrierSynchronizer`）→ 前导检测与相位模糊消除（`comm.PreambleDetector`）→ 解调、误码统计。最后画出频谱、同步前后的星座图和误码率。

| 编号 | 内容 | 验收 |
|---|---|---|
| Q1 | 单板数字环回：一块板上 TX → AD9361 数字环回 → RX，全部由 MATLAB 控制 | 10⁵ 比特以上误码为 0；样点幅度与发送一致（验证 12 位满量程的换算） |
| Q2 | 两板空中收发：TX 板循环发送，RX 板一次取回 1 s 样点 | 默认发射电平下，10⁵ 比特以上误码为 0；打印 EVM 与频偏估计；画出星座图 |
| Q3 | 主机端口 1 环回：MATLAB → 主机端口 1 → 槽位 0（直通）→ 主机端口 1 → MATLAB | 逐字一致；说明与 PL 模块交换数据的方式 |

## 3. 步骤

| 步骤 | 内容 | 验证 |
|---|---|---|
| MA1 | 桥接服务：协议、射频收发（循环 / 流式 / 定时突发、一次取 N 点）、主机端口 1、路由与寄存器、驱动参数；systemd 服务 `glidelink-bridge` | PC 上的 Python 测试脚本覆盖每条命令；数字环回与主机端口 1 环回逐样点一致 |
| MA2 | MATLAB 包 `+glidelink` 与基本测试 | 在 MATLAB 中完成 Q3 与一次数字环回取样 |
| MA3 | QPSK 示例：`qpsk_loopback.m`（Q1）、`qpsk_ota.m`（Q2） | Q1、Q2 的验收 |
| MA4 | 文档：使用说明、命令表、示例说明 | — |

之后可选：模块代理（同一段 MATLAB 处理链中，把某个 MATLAB 函数换成 PL 模块，比对输出，同 GNU Radio 的 `gr_proxy_swap`）；Simulink 块；HDL Coder 生成 AXI4-Stream 模块放入槽位（MATLAB 验证 → 生成 HDL → 上板）。

## 4. 限制与风险

- PC 与板之间经 USB 网口，持续样点速率约 7 MSPS（2.5 MSPS 以下最稳）。循环发送与“一次取 N 点”不受此限。
- MATLAB `tcpclient` 的读写吞吐需要实测；若成为瓶颈，大块数据改为分段读取。
- 空中收发时，AD9361 的本振泄漏落在零频。示例中 QPSK 放在零频，靠 RX 直流校正与同步处理；必要时在数字域把信号移到 +200 kHz。
- 桥接服务与脱机系统互斥，切换时需要停掉另一方（`systemctl stop glidelinkd@*` / `glidelink-bridge`）。

## 5. 进展

| 项目 | 结果 |
|---|---|
| 桥接服务 | `sw/bridge/glidelink_bridge.py`，systemd 服务 `glidelink-bridge`（开机加载本板镜像后启动，与脱机系统互斥）；协议版本 1，命令覆盖射频设置（任意采样率 0.52–61.44 MSPS，由 libad9361 为该速率设计 FIR）、任意驱动属性、循环 / 定时突发发送、连续取样、硬件时间、主机端口 1、路由、寄存器；多个客户端可同时连接，命令依次执行 |
| MATLAB 包 | `sw/matlab/+glidelink/Radio.m`，只用 MATLAB 自带的 `tcpclient`；连接时检查协议版本；说明见 `sw/matlab/README.md` |
| Q2 QPSK 空中收发 | `sw/matlab/examples/qpsk_ota.m`：1 MSPS、250 k 符号/s，110 帧 44 万比特误码 0，EVM −23.8 dB；2.5 MSPS 时 292 帧 116.8 万比特误码 0，EVM −27.7 dB；图窗显示频谱、同步前后星座、统计 |
| 多种通信体制 | 同一个桥接服务、板上不做任何改动，`examples/run_all.m` 依次运行：QPSK（1 MSPS）、2-FSK（窄带恒包络，0.6 MSPS）、线性调频扩频 SF7（1 MSPS）、802.11a/g OFDM 16-QAM（宽带、高 PAPR、按包突发，20 MSPS，WLAN Toolbox）、按硬件时间定时发出的突发（2 MSPS），全部零误码；突发间隔误差标准差 2 ns |
| 期间修正的桥接服务问题 | 定时发送与带时间戳的接收需要包头模式（原先用的原始模式会忽略时间）；DMA 以 64 位为单位，包头 4 个字加奇数个样点的包发不出去，奇数长度的突发补一个零样点；一个定时突发在发出前一直占着一个 DMA 缓冲区（共 4 个），提前排很多突发会阻塞请求，改为桥接服务内部排队、后台按序送入 |
| 增益模式 | 手动增益、慢速 AGC、快速 AGC、混合模式由 `RxGainMode` 选择，AGC 的全部驱动参数由 `attr` 读写；`attr("initialize", 1)` 按新参数重新初始化 AD9361，桥接服务在初始化前后保持采样率、本振、带宽、增益模式 / 增益与 TX 衰减（客户端改过对应设备树参数的项除外）。`examples/agc_modes.m` 用同一串功率相差 14 dB 的突发对比四种设置，只描述现象，驱动参数保持原样（快速 AGC 的可调参数列在脚本说明里）。驱动参数改动后一直有效，直到再改或板子重启 |
| 待查 | 慢速 AGC 曾有一次停在最低增益、RSSI 不再更新（TX 关闭后也不恢复），当时反复改过快速 AGC 参数并多次初始化；重启后按同样步骤（初始化、窗口上沿改为 20）均未复现，触发条件未知 |

