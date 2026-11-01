# 使用指南

## 1. 组成与连接

两块 PYNQ-ZU 板，各插一块 AD9361 FMC 子卡，硬件相同；按竞赛时的分工称为接收板与发射板，区别只在开机加载的 PL 镜像。
每块板用一根 USB 线直接接到电脑，枚举为复合设备：USB 网卡（RNDIS）、串口（板上登录控制台）和一个小容量存储盘。

| | 接收板 | 发射板 |
|---|---|---|
| 板子地址（USB 网口） | 192.168.3.1 | 192.168.4.1 |
| 电脑分到的地址 | 192.168.3.100～150（板上 DHCP） | 192.168.4.100～150 |
| 开机加载的镜像 | `glidelink_rx`（OFDM 接收 + 解码器） | `glidelink_tx`（编码器 + OFDM 发射） |

```bash
ssh root@192.168.3.1
```

接收板的镜像没有主机到 DAC 的发射数据通路：要在一块板上既发又收（如 FMCW 雷达示例）时用发射板，或给接收板换镜像（第 4 节）。

## 2. 板上的服务

| 服务 | 开机启动 | 作用 |
|---|---|---|
| `glidelink-bridge` | 是 | 加载 `/etc/default/glidelink-bridge` 中 `GLIDELINK_IMAGE` 指定的镜像；在 TCP 7030 上为 MATLAB 提供收发与设置（`sw/bridge`） |
| `iiod` | 是 | libiio 的网络服务：电脑上的 Soapy 模块、GNU Radio、GQRX 经它访问 AD9361 与 DMA |
| `glidelinkd@tx` / `glidelinkd@rx` | 否 | 脱机系统：守护程序按 `sw/offline/config/{tx,rx}.yaml` 加载镜像、配置射频与模块，并托住收发应用（DeepJSCC-Q 图像传输） |

桥接服务与脱机系统互斥（启动一个会停止另一个）：

```bash
systemctl start glidelinkd@rx        # 接收板切到脱机系统（发射板为 glidelinkd@tx）
systemctl start glidelink-bridge     # 切回
```

桥接服务和 iiod 可以同时使用；同一时刻同一个方向的射频流只能有一个使用者（例如 MATLAB 正在采集时，GNU Radio 的源会拿不到数据）。

## 3. 用法

### 3.1 MATLAB

电脑上只需 MATLAB（R2025b 已测，示例用到通信工具箱、WLAN 工具箱）：

```matlab
addpath('D:/ClaudePrj/glidelink-sdr/sw/matlab')
tx = glidelink.Radio("192.168.4.1");  rx = glidelink.Radio("192.168.3.1");
tx.config(Rate=1e6, Freq=915e6, TxAtten=30);  rx.config(Rate=1e6, Freq=915e6, RxGainMode="manual", RxGain=40);
tx.txCyclic(x);                       % 在板上循环发送，不占网络
[y, t, drops] = rx.rx(1e6);           % 在板上连续采集 1e6 个采样后发回；t 为第一个采样的硬件时间
```

接口、各通信体制示例、AGC 配置与 MathWorks 官方例程的移植版见 [`sw/matlab/README.md`](../sw/matlab/README.md)。
采样率 0.52～50 MSPS；采集在板上完成，再经网络发回，所以高采样率也不丢样点（单次采集受板上内存限制，数百万个采样没有问题）。

### 3.2 GNU Radio

在 GRC 的 GlideLink 分类中：

| 块 | 用途 |
|---|---|
| GlideLink Source / Sink | 板子的射频接收 / 发射：填板子地址、采样率、中心频率、带宽、增益模式与增益（或发射衰减），运行中可改 |
| GlideLink Control | 路由、驱动参数、寄存器；周期回读状态 |
| GlideLink Host Source / Sink | 主机端口 1：PL 槽位中模块的数据 |
| FPGA modules：GlideLink NCO / FIR / FFT（software / PL） | 模块的软件模型与 PL 块，由各模块的 `module.yaml` 生成；FFT 是 Ettus RFNoC FFT 块的处理核心 |
| GlideLink Radio (PL) | 射频在 PL 一侧的收发两端（`rf_rx` / `rf_tx`）与射频设置 |

PL 块的橙色端口像 RFNoC 块一样在 GRC 中直接连线：连线就是 PL 内部的路由，数据不经过 GNU Radio，主机端口块是 PL 与电脑交接数据的地方
（[`sw/gr-glidelink/README.md`](../sw/gr-glidelink/README.md)）。

示例：`sw/gr-glidelink/examples/ota_qpsk.grc`（两板之间的 QPSK，频谱、瀑布图、同步前后的星座）、`ota_qpsk_pl.grc`（同样的链路 20 MSPS，
滤波在 PL 中，需 `qpsk` 镜像）、`pl_fft_spectrum.grc`
（射频 → NCO → FFT 全在 PL 内，20 MSPS 的频谱以每 KEEP 帧一帧送到电脑，需 `dsp` 镜像）、`agc_fast_attack.grc`、`jscc_link_console.grc`。不经 GRC 的脚本在 `sw/gnuradio/`。

电脑上的 GNU Radio 经 USB 网口连续传输，单块板收发同时各 50 MSPS（Windows 原生程序，见 `pc_setup.md` 第 3 节；WSL 中发射约 48 MSPS；板上 UDP 流服务 `glidelink-streamd`，Soapy 模块默认使用）；更高的采样率在 PL 中先做处理或抽取（如 FFT 模块的 KEEP），或在板上运行流程图（`uri=local:` 或板子地址留空）。
电脑端的安装与图形桌面见 [`pc_setup.md`](pc_setup.md)。

### 3.3 视频经离线图传链路

电脑上的视频发给发射板，经空口由接收板解码传回，在电脑上并排对比（`sw/gr-glidelink/examples/jscc_video.grc`）：

```bash
systemctl start glidelinkd@tx        # 发射板；接收板为 glidelinkd@rx
python3 glidelink_jscc_video.py -v <视频文件>
```

发射板按每秒 30 帧取电脑送来的最新一帧编码发出；电脑与板子之间是两路 256×256 画面（合计约 12 MB/s）。
两块板相距约 1 m 时发射衰减宜在 8～16 dB（更小时接收端过载）。

### 3.4 SoapySDR 程序与 GQRX

设备参数 `driver=glidelink,uri=ip:192.168.3.1`（板上运行时 `driver=glidelink`）：

```bash
SoapySDRUtil --probe="driver=glidelink,uri=ip:192.168.3.1"
gqrx                                  # 设备串填 soapy=0,driver=glidelink,uri=ip:192.168.3.1
```

AD9361 驱动的全部参数、增益控制模式和寄存器经 Soapy 的设置项与寄存器接口访问，见 [`sw/soapy-glidelink/README.md`](../sw/soapy-glidelink/README.md)。

### 3.5 MathWorks Pluto 支持包直连

Communications Toolbox Support Package for ADALM-Pluto 可以按地址连接板子（`sdrrx('Pluto', RadioID="ip:192.168.3.1")`），
只提示固件版本未知。差别：采样率下限 0.52 MSPS（Pluto 的 FPGA 另有抽取，可到 65 kSPS）；支持包按 12 位换算样点，板子送出的是
16 位高位对齐，读数大 16 倍、发射小 16 倍。保留例程信号处理、射频改用 `glidelink.Radio` 的移植版在 `sw/matlab/examples/official`。

## 4. 常用操作

| 操作 | 方法 |
|---|---|
| 查看板子与射频状态 | MATLAB `rx.config()`；板上 `systemctl status glidelink-bridge`、`journalctl -u glidelink-bridge` |
| 频率校正（ppm） | 写 AD9361 驱动的 `xo_correction`（参考时钟 40 MHz，±200 ppm 可调）：本振与采样率按同一比例变化。MATLAB `r.attr("xo_correction", round(40e6 / (1 + ppm / 1e6)))`，示例 `official_freq_correction.m` |
| AGC 参数 | 驱动参数（`adi,agc-*`、`adi,fagc-*`）写入后 `initialize`；各波形的配置见 MATLAB 示例 |
| 硬件时间与定时发送 | 外壳的采样计数器：MATLAB `r.time()`、`r.txBurst(x, [], t)`；Soapy `getHardwareTime`、带时间的 `writeStream` |
| 换开机镜像 | 把 `<镜像>.bit`、`.dtbo`、`.hwh` 放到板上同一目录，改 `/etc/default/glidelink-bridge` 的 `GLIDELINK_IMAGE`，重启板子（叠加加载后不能卸载，所以换镜像要重启） |
| 重启 | `reboot`，约 70 s 后桥接服务可用 |

## 5. 加入自己的 FPGA 模块

开发者只写模块 RTL（AXI4-Stream 输入输出、`flush`，寄存器是普通端口）、`module.yaml`（寄存器表、GNU Radio 块参数及其到寄存器的换算）
和可选的参考模型 `model.py`；AXI4-Lite 寄存器文件、GRC 的 PL 块与软件块、测试向量都由脚本生成。仓库根目录的四条命令：

```bash
python glidelink.py new gain_offset                         # 骨架（直通），能直接测试、构建
python glidelink.py test gain_offset                        # xsim 仿真，与参考模型逐拍比较、核对寄存器读回
python glidelink.py build gain_offset nco --name tutorial   # 镜像：列出的模块放在槽位 1、2……（约一小时）
python glidelink.py deploy 192.168.3.1 tutorial             # 设为开机镜像、重启、核对各槽位的模块
```

然后重新安装 gr-glidelink，模块的两个块出现在 GRC 的 GlideLink / FPGA modules 中；PL 块按模块 ID 自己找槽位。
完整说明与一个从零写起的例子见 [`module_guide.md`](module_guide.md)。

第三方 RTL 放进单独的库目录、按原样保留（如 `hw/modules/uhd_rfnoc`，Ettus UHD 的 LGPL 源文件），模块在 `module.yaml` 的 `uses` 中引用，
适配写在模块自己的包装里（`hw/modules/fft/glidelink_fft.sv` 把 RFNoC 的 CtrlPort 与数据流换成槽位的 AXI4-Lite 与 AXI4-Stream，`bus: module`）。
处理时钟（100 / 200 / 250 MHz）与 RTL 参数在镜像文件 `hw/images/<镜像>.yaml` 中按槽位设定。

## 6. 性能与限制（概要）

| 项目 | 数值 |
|---|---|
| 采样率 | 0.52～50 MSPS（第三方子卡的 TX 接口在 61.44 MSPS 时余量不足，见 `hw/README.md`） |
| 射频 | AD9361：70 MHz～6 GHz（发射 47 MHz 起），带宽至 56 MHz；每块板 1 收 1 发 |
| 板上收发 | 50 MSPS 全双工逐样点无误（C 程序、桥接服务的 C 采集） |
| 经 USB 网口的连续流 | Windows 原生程序收发同时各 50 MSPS；WSL 中接收 50、发射约 48 MSPS |
| 发→收固定延迟 | 56 个采样（同一块板，数字滤波与 FIFO） |

已知问题与注意事项见 [`known_issues.md`](known_issues.md)。
