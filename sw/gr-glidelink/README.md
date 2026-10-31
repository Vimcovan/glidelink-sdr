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
| GlideLink NCO / FIR (software) | 调用模块的参考模型（`hw/modules/<id>/model.py`），与 PL 中的模块逐比特一致：软件原型阶段使用 |
| GlideLink NCO / FIR (PL) | 代理块：按 `module.yaml` 中的寄存器名写槽位寄存器（NCO 在槽位 1，FIR 在槽位 2），不传数据；数据经控制块设的路由进出槽位 |

控制块自己开一个 Soapy 设备实例，只做控制，不碰射频流；Soapy 模块的构造不改硬件状态，几个实例可以同时存在。

路由名：汇 `rf_tx`、`host0_rx`、`host1_rx`、`slot0_in`、`slot1_in`、`slot2_in`；源 `rf_rx`、`host0_tx`、`host1_tx`、`slot0_out`、`slot1_out`、`slot2_out`、`none`（外壳 1.4.0：槽位 0 直通、1 NCO、2 FIR）。
例：`{'slot0_in': 'rf_rx', 'host0_rx': 'slot0_out'}` 把槽位 0 接在射频接收与 Soapy 源之间。

## 安装（WSL / Ubuntu，GNU Radio 3.10）

```bash
sudo apt install gnuradio-dev python3-soapysdr
cmake -S . -B build && cmake --build build && sudo cmake --install build
```

块装到 `/usr/local/share/gnuradio/grc/blocks`，GRC 默认能找到。Soapy 模块（`sw/soapy-glidelink`）需在同一台机器上装好。

## 示例

`examples/ota_qpsk.grc`：发射板（GlideLink Sink）发 QPSK，接收板（GlideLink Source）收，经 AGC、FLL 频偏校正、多相时钟同步、
Costas 环后显示星座；频谱、瀑布图；滑块改发射衰减和接收增益。915 MHz、2.5 MSPS。

`examples/jscc_video.grc`：电脑上的视频经离线 DeepJSCC-Q 链路（发射板 → 空口 → 接收板）传回，发出与解码的画面并排对比，
另有接收机星座图与发射衰减滑块。两块板要切到离线系统（`systemctl start glidelinkd@tx` / `glidelinkd@rx`）；运行
`python3 glidelink_jscc_video.py -v <视频文件>`（GRC 生成）或在 GRC 中填参数 Video。

`examples/agc_fast_attack.grc`：快速 AGC，用滑块改锁定电平（`adi,agc-inner-thresh-high`），每次改动写入驱动参数并重新初始化
AD9361，界面上显示寄存器 0x101 的回读、频谱和接收幅度。参数 `uri` 选板子（默认 `ip:192.168.3.1`）。

自动化的验收见 `sw/tests/gr_agc_init.py`（第 2 阶段）与 `sw/tests/gr_proxy_swap.py`（软件块换成代理块后输出不变）。

Python 块在流程图运行期间要保持引用（存到变量里）；在 `connect()` 里直接构造会被回收，流程图启动时崩溃。
