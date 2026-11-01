# gr-glidelink

GlideLink 平台的 GNU Radio 3.10 OOT 模块（纯 Python 块）：板子的射频源 / 汇，以及 PL 侧的连接与控制。

| 块 | 作用 |
|---|---|
| GlideLink Source / Sink | 板子 AD9361 的接收 / 发射（主机端口 0），复数采样、满幅 1。参数直接填板子地址（`192.168.3.1`、`ip:...`，空为本机板子，也可填完整的 Soapy 设备串）、采样率、中心频率、射频带宽（0 = 采样率）；源另有增益模式（手动、慢速 / 快速 / 混合 AGC）与接收增益，汇有发射衰减（0～89.75 dB）。频率、增益、增益模式、衰减可在运行中改（变量、滑块）。内部是 gr-soapy 加 `glidelink` Soapy 驱动，也可以直接用 GNU Radio 自带的 Soapy 源 / 汇（设备参数 `driver=glidelink,uri=ip:<板子地址>`） |
| Video File Source | 电脑上的视频文件（OpenCV 能打开的格式）、图片、图片文件夹或摄像头编号；取中间正方形缩成 256×256 RGB，一帧为一个数据项（196,608 字节），按片子本身的帧率输出 |
| JSCC TX Sink | 把画面送到发射板的离线图传系统：把发射程序切到"网络"片源并发送画面（端口 7023），发射板按每秒 30 帧取最新一帧编码发出；发射衰减可在运行中改 |
| JSCC RX Source | 接收板解码出的画面（接收程序的画面流，端口 7021），来一帧输出一帧 |
| Video Sink | 显示画面；两路输入时左边是发出的画面（输入 0），右边是解码画面（输入 1），每帧解码画面配上最匹配的发出画面（近 30 帧中与最佳差在 0.5 dB 以内的最新一帧），显示逐帧 PSNR、平均 PSNR、两路帧率与延迟帧数；两路输入各自取用，链路中断时发送不受影响 |
| GlideLink Control | 设流交换路由；按顺序写设置（AD9361 驱动参数、`gain_control_mode`、`initialize`）；写寄存器；按间隔回读一组寄存器 / 设置，从 `status` 消息口发出。运行中改设置字典里用到的变量时，只写变化的项，字典含 `'initialize': True` 时随后重新初始化 AD9361。`cmd` 消息口收同样键的字典 |
| GlideLink Host Source / Sink | 主机端口 1：槽位中模块的数据。复数（sc16 / 32768）或整数（原样 32 位字）；带包头时源打 `rx_time` / `rx_eob` 标签，汇按 `tx_time` / `tx_eob` 标签定时发送、结束突发 |
| GlideLink NCO / FIR / FFT (software) | 调用模块的参考模型（`hw/modules/<id>/model.py` 的 `Model`）：软件原型阶段使用。NCO、FIR 与 PL 中的模块逐比特一致；FFT 用浮点计算，与 PL 输出相差约 1 LSB |
| GlideLink NCO / FIR / FFT (PL) | 模块在 PL 槽位中：按参数写寄存器，不传数据；数据经 PL 端口的连线（或控制块设的路由）进出槽位。槽位 -1（默认）按模块 ID 自己找 |

模块的这两种块不是手写的：`modules.py` 按每个带 `block` 段的 `hw/modules/<id>/module.yaml` 生成 Python 类，GRC 的块文件在安装时由
`hw/scripts/gen_module.py` 生成（GRC 分类 GlideLink / FPGA modules）。两种块参数相同、"参数 → 寄存器"的换算相同，软件块把寄存器写给参考模型，
PL 块写给板上的槽位（[`docs/module_guide.md`](../../docs/module_guide.md)）。
| GlideLink Radio (PL) | 射频在 PL 一侧的两端：输出 `rf_rx`（AD9361 接收采样）、输入 `rf_tx`（送往 AD9361 发射），以及采样率、收发本振、带宽、增益模式与增益、发射衰减。相当于 RFNoC 的 Radio 块 |

## 在 GRC 中连接 PL 模块

GlideLink 的 PL 块有橙色端口（GRC 端口域 `glidelink_pl`，`grc/glidelink_pl.domain.yml`），用法与 RFNoC 块相同：在 GRC 里把它们连起来，
数据就在 PL 内部按连线流动，不经过 GNU Radio。生成的代码把每条橙色连线变成一次 `glidelink.pl_connect(源块, 端口, 汇块, 端口)`，
它在流程图构造时设置外壳流交换的路由（汇 ← 源，改变时清理该汇）。

| 块 | 橙色输入（交换汇） | 橙色输出（交换源） |
|---|---|---|
| GlideLink Radio (PL) | `rf_tx` | `rf_rx` |
| 模块的 PL 块（NCO / FIR / FFT (PL)，在槽位 k） | `slot<k>_in` | `slot<k>_out` |
| GlideLink Host Source / Sink（主机端口 1） | `host1_rx`（Host Source） | `host1_tx`（Host Sink） |
| GlideLink Source / Sink（主机端口 0） | `host0_rx`（Source） | `host0_tx`（Sink） |

- 主机端口块一端是橙色端口，另一端是普通数据流端口：PL 与 GNU Radio 之间的数据在这里交接。
- 交换一个源同一时刻只接一个汇，所以每个橙色端口只能连一条线（GRC 会提示）；同一流程图里的 PL 块要在同一块板上。
- 没有连线的橙色输入保持原来的路由。旧流程图里用 GlideLink Control 写路由的方式照常可用。
- 连线属于建立它的进程，和 RFNoC 图的连接一样：进程结束时（关掉流程图窗口、脚本结束）还保持原样的连线都放开成 none，
  也可以随时调用 `glidelink.pl.release()`。被强行结束的进程（如 GRC 的停止按钮）来不及放开；之后 Soapy 模块为主机端口 0
  接射频接收或发射时，按同一条规则（一个源只接一个汇）把仍占着 `rf_rx` / `host0_tx` 的旧连线断开，并打出一条警告。
- 一个模块的软件块与 PL 块可以互换：软件原型阶段用 (software) 块和普通数据流，换到 PL 时用 (PL) 块和橙色连线。

控制块自己开一个 Soapy 设备实例，只做控制，不碰射频流；Soapy 模块的构造不改硬件状态，几个实例可以同时存在。

路由名：汇 `rf_tx`、`host0_rx`、`host1_rx`、`slot<k>_in`；源 `rf_rx`、`host0_tx`、`host1_tx`、`slot<k>_out`、`none`（k = 0～10，按镜像的槽位数；
`demo` 镜像：槽位 0 直通、1 NCO、2 FIR；`dsp` 镜像：0 直通、1 FFT、2 FIR、3 NCO）。
例：`{'slot0_in': 'rf_rx', 'host0_rx': 'slot0_out'}` 把槽位 0 接在射频接收与 Soapy 源之间。

## 安装（WSL / Ubuntu，GNU Radio 3.10）

```bash
sudo apt install gnuradio-dev python3-soapysdr
cmake -S . -B build && cmake --build build && sudo cmake --install build
```

块装到 `/usr/local/share/gnuradio/grc/blocks`，GRC 默认能找到。Soapy 模块（`sw/soapy-glidelink`）需在同一台机器上装好。

## 安装（Windows，radioconda）

radioconda 中没有 CMake；这些块是纯 Python，用 radioconda 自己的 Python 运行安装脚本，把文件复制到它的 GNU Radio 中：

```bat
D:\radioconda\python.exe sw\gr-glidelink\install_conda.py
```

Soapy 模块的 Windows 版见 `sw/soapy-glidelink/README.md`。radioconda 没有 OpenCV，视频块（Video File Source 等）用不了，其余块都可用。

## 示例

`examples/ota_qpsk.grc`：发射板（GlideLink Sink）发 QPSK，接收板（GlideLink Source）收，经 AGC、FLL 频偏校正、多相时钟同步、
Costas 环后显示星座；频谱、瀑布图；滑块改发射衰减和接收增益。915 MHz、2.5 MSPS。

`examples/rate_50msps.grc`：发射板发两个单音加噪声、接收板收，都是 50 MSPS 经 USB 网口（板上 UDP 流服务），
显示接收板的整个 50 MHz 频谱，每秒打印两路实际速率。要在 Windows 原生的 GNU Radio（radioconda）中运行；WSL 中发射约 48 MSPS。
2026-11-01 实测两路都稳定在 50.0 MSPS（`docs/img/win_rate_50msps.png`）。

`examples/pl_fft_spectrum.grc`：全部在 PL 内的一条链，在 GRC 中用橙色连线画出：射频接收 → NCO（PL）→ FFT（PL，RFNoC FFT 块的核心）
→ 主机端口 1，电脑上只显示频谱。PL 按 20 MSPS 全速率计算 1024 点 FFT，每 KEEP 帧送一帧到电脑（KEEP = 40 时电脑只收 0.5 MSPS）；
滑块改 KEEP、NCO 频移、接收频率与增益。板子要运行 `dsp` 镜像。

`examples/jscc_video.grc`：电脑上的视频经离线 DeepJSCC-Q 链路（发射板 → 空口 → 接收板）传回，发出与解码的画面并排对比，
另有接收机星座图与发射衰减滑块。两块板要切到离线系统（`systemctl start glidelinkd@tx` / `glidelinkd@rx`）；运行
`python3 glidelink_jscc_video.py -v <视频文件>`（GRC 生成）或在 GRC 中填参数 Video。

`examples/agc_fast_attack.grc`：快速 AGC，用滑块改锁定电平（`adi,agc-inner-thresh-high`），每次改动写入驱动参数并重新初始化
AD9361，界面上显示寄存器 0x101 的回读、频谱和接收幅度。参数 `uri` 选板子（默认 `ip:192.168.3.1`）。

自动化的验收见 `sw/tests/gr_agc_init.py`（第 2 阶段）与 `sw/tests/gr_proxy_swap.py`（软件块换成 PL 块后输出不变）。

Python 块在流程图运行期间要保持引用（存到变量里）；在 `connect()` 里直接构造会被回收，流程图启动时崩溃。
