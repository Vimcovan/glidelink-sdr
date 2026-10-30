# 在 MATLAB 中使用 GlideLink

MATLAB 通过板上的桥接服务（`glidelink-bridge`，TCP 端口 7030，开机自动启动）控制每块板子。电脑上除
MATLAB 外不需要安装任何东西（已在 R2025b 上测试，`tcpclient` 是 MATLAB 自带的）；示例用到通信工具箱。

```matlab
addpath('D:/ClaudePrj/glidelink-sdr/sw/matlab')
run('D:/ClaudePrj/glidelink-sdr/sw/matlab/examples/qpsk_ota.m')     % 两块板之间的 QPSK
```

## 示例（`sw/matlab/examples`，都在两块板之间空口收发，用同一个桥接服务）

| 脚本 | 通信体制 | 展示内容 |
|---|---|---|
| `qpsk_ota.m` | QPSK，根升余弦成形，1 MSPS | 单载波、连续发送；通信工具箱的同步链路 |
| `fsk_narrowband.m` | 2-FSK，10 kBd，0.6 MSPS | 窄带、恒包络（峰均比 0 dB），非相干检测 |
| `css_chirp.m` | 线性调频扩频 SF7，125 kHz，1 MSPS | 恒包络、扩频；调频信号的时频图 |
| `wlan_ofdm.m` | 802.11a/g 16-QAM 3/4，20 MSPS（WLAN 工具箱） | 宽带、高峰均比（10 dB）、带空闲间隔的包；信道估计 |
| `timed_bursts.m` | 20 个 Zadoff-Chu 突发，按硬件时间精确发送，2 MSPS | 提前排定的突发；间隔精度（ns）、时钟偏差（ppm） |
| `agc_modes.m` | 同一串突发（功率相差 14 dB），分别用固定增益、慢速 AGC、快速 AGC、换一个锁定电平的快速 AGC | 各增益模式的反应（驱动参数保持原样，快速 AGC 的可调参数列在脚本里） |
| `run_all.m` | 依次运行以上全部 | 汇总表 |
| `run_agc.m` | 每个体制跑两次：固定增益，以及针对其波形配置的 AGC | 汇总表，含 AD9361 最终的增益 |

2026-10-30 `run_all` 各体制均 0 误码（QPSK 440 kbit，2-FSK 27 kbit，CSS 768 个符号，OFDM 60 包 / 480 kbit、
信噪比 27.6 dB，突发 20 个全收到、间隔离散 2 ns）。

## MathWorks 官方例程（`sw/matlab/examples/official`）

USRP、ADALM-Pluto 支持包和 WLAN 工具箱的官方例程，保留例程的参数和信号处理流程，只把射频收发换成
`glidelink.Radio`。官方文件不放进仓库：脚本运行时由 `glidelink.officialExample` 从本机已安装的支持包取出，
放在 `sw/matlab/official/`（不入库）并加入路径。需要先安装 Communications Toolbox Support Package for
USRP Radio 和 for Analog Devices ADALM-Pluto Radio。

| 脚本 | 官方例程 | 用到的官方部分 | 与原例程的差别 | 2026-10-31 结果 |
|---|---|---|---|---|
| `official_qpsk.m` | QPSK Transmitter / Receiver with USRP Hardware、with ADALM-PLUTO Radio | 参数脚本、`QPSKTransmitter`、`QPSKReceiver`（AGC、根升余弦、粗/细频偏、Gardner 定时、帧同步、解扰、误码统计） | `variant` 选 USRP 或 Pluto 的参数；Pluto 版符号率 0.2→0.5 MBd（我们的采样率下限 0.52 MSPS）；发射端在板上循环发送 3 帧（扰码周期） | 两版各 178 帧、136 万比特，0 误码 |
| `official_freq_correction.m` | Frequency Correction for ADALM-PLUTO Radio | 三个单音、80 kHz 单音估计 ppm、校正值的叠加公式 | Pluto 的 `FrequencyCorrection` 换成 AD9361 驱动的 `xo_correction`；1 MSPS（原 200 kSPS） | 板间 −0.85 ppm，校正后残差约 10 Hz；发射端 +1 ppm 后重新估计，残差约 10 Hz |
| `official_fm.m` | FM Demodulation and Spectrum Analysis with USRP Radio | 宽带频谱与峰值、`comm.FMBroadcastDemodulator`（立体声） | 宽带中心 90 MHz（日本波段）；窄带 960 kSPS；`source = "boards"` 时由发射板在 915 MHz 发调频立体声广播 | 板间：导频 36 dB，左声道信噪比约 25 dB（无射频回环 41.6 dB），左右隔离 43 dB；空中只收到弱台 |
| `official_wlan_image.m` | Image Transmission and Reception Using 802.11 Waveform and SDR | 同样的步骤和 WLAN 工具箱函数（MAC 分片、802.11a MCS 6、检测、同步、信道估计、L-SIG、解调、FCS），`helperInterpretLSIG` | 用整段采集里每个分片 FCS 正确的那一份（原例程遇到第一个重复序号即停）；跳过其他 WLAN 的帧 | 2432 MHz：3 次中 2 次 11 包全收、BER 0、EVM 约 6 %；另一次 7 包（WiFi 干扰） |
| `official_wlan_beacons.m` | WLAN Beacon Receiver Using Software-Defined Radio | `recoverDSSSBits` / `recoverOFDMBits`、`wlanMPDUDecode`、按主信道去重 | 每信道采 3 个信标间隔（原 1 个）；不查厂商 | 例程自带的录制数据：5 包、4 个信标；空中 OFDM 2.4 GHz 13 个信道解出 1323 个包，信标只解出 1 个接入点（信噪比 18 dB）；DSSS 解出 0 包。915 MHz 天线在 2.4 GHz 收不到较远的接入点 |

| `official_fmcw.m` | FMCW Radar Waveform Based Range Calculation Using Time Trigger | `phased.FMCWWaveform`、`dechirp`、按拍频算距离（`beat2range`） | 同一块板（发射板）上 `txBurst` 定时发射，接收数据的时间戳定位触发时刻；20 MSPS、对称扫频（原 30 MSPS、0～15 MHz，带宽相同） | 拍频 42.1 kHz → 421 m，与互相关测得的 56 个采样（2.80 µs）一致：即板上发→收的固定延迟 56 个采样 |

未移植：USRP 的两个"突发模式缓冲"例程是主机端缓冲选项，我们的接收在板上连续采集、发射在板上循环或定时，
没有对应功能；Alamouti 2×1 需要一块板两路发射，平台目前每块板一路收、一路发。

移植时发现的平台问题与处理：

- 桥接服务的突发发射流按打开时的采样率把突发时间换算成采样数。同一连接里改采样率后，突发在错误时刻反复发出。
  已改为改采样率时关闭突发流，下一个突发按新采样率重新打开（两块板已更新）。
- 采样率高于 20 MSPS 时采样会丢失：30 MSPS 循环发射的波形中间有空隙，定时突发的间隔按约 0.65 的比例缩短。
  原因在桥接服务：接收用 Python 逐包读取（每 4096 个采样调用一次），约 20 MSPS 封顶，丢失也不报告；
  循环发送由 Python 线程反复写入。现在接收在 C 库 `sw/bridge/libglidelink_fast.so`（`glidelink_fast.c`，
  `install.sh` 在板上编译）中完成，并按包头时间报告丢失；循环发送用 libiio 的循环缓冲区，由 DMA 硬件重复，
  不占 CPU。`sw/tests/bridge_rate.py` 在 20、30、30.72、40、50 MSPS 下验证（发射板 → 接收板，以及发射板
  自发自收）：1 ms 线性调频 + 1 ms 静默的循环波形，周期误差不超过 ±1 个采样（两板时钟差与取整）；三个相隔
  50 ms 的定时突发，测得间隔 50.000 ms；接收均无丢失。两块板已更新。
- libad9361（板上 0.2 版）在 40 MSPS 以上加载固定的 96 阶 FIR，此时射频接收不可用（46～50 MSPS 实测约四分之一的
  采样接近满幅，与发射无关）。桥接服务在 40 MSPS 以上关闭 FIR，直接写驱动的采样率（与 Soapy 模块相同），
  接收正常；40 MSPS 及以下仍由 libad9361 设计 FIR。
- 接收板的镜像（`glidelink_rx`）没有主机到 DAC 的发射数据通路，只有发射板的镜像能收发。

- 接收板的发射本振与接收本振同频时会漏进接收通道，在 −0.6 kHz 处形成一根约 −53 dBFS 的谱线（与载频无关）。
  只接收的脚本把接收板的发射本振移开（`TxFreq` 设为接收频率 +10 MHz 以上）。
- 参考时钟原先在设备树里是固定时钟，写 `xo_correction` 不起作用；已改为与 Pluto 相同的可调时钟（±200 ppm，
  `hw/dts/build_dtbo.sh`），两块板已更新。
- Pluto 支持包可以直接按 `ip:` 地址连接我们的板子（只提示固件版本未知）。原先经 iiod 网络读数据时，
  开始后的第 5～7 个缓冲块全为零，会把例程的 AGC 推到最大；原因是 AXI DMAC 驱动在内核块数多于 5 时丢传输，
  已由内核补丁修正（`os/kernel/README.md` 补丁 0002），两块板已更新。另外 Pluto 支持包按 12 位
  数据换算，我们的数据是 16 位高位对齐，读数大 16 倍。桥接服务不经过 iiod，不受影响。

## 各波形的 AGC 配置

每个体制脚本都带有针对其波形的 AGC 配置（`agcMode`、`agcParams`，每个取值的理由写在注释里）。运行脚本前
设 `gainMode = "agc"` 即启用（`run_agc.m` 就是这样做的），否则使用脚本里的固定增益。
`glidelink.agcSetup(r, mode, params)` 写入驱动参数、按新参数重新初始化 AD9361 并选择增益模式；
`glidelink.agcRestore(r, saved)` 在脚本结束时恢复参数、增益模式和增益。
功率测量时长按 ClkRF 的采样计数（这里是采样率的 4 倍）；慢速 AGC 的测量时长若不能在增益更新间隔内放下
两次，驱动会自动缩短。

| 脚本 | AGC | 配置 |
|---|---|---|
| `qpsk_ota.m` | 慢速 | 平均功率 −11～−14 dBFS（峰均比约 3.5 dB），平均 256 µs，每 5 ms 更新一次 |
| `fsk_narrowband.m` | 慢速 | −6～−8 dBFS（恒包络），每 5 ms 更新一次 |
| `css_chirp.m` | 慢速 | −6～−8 dBFS，平均时长等于 4.1 ms 的帧间空隙，每 50 ms 更新一次 |
| `wlan_ofdm.m` | 快速 | 同竞赛 OFDM 接收机：锁定电平 −14 dBFS（峰均比 10 dB），第一包锁定后保持，关闭强信号解锁（OFDM 峰值可达锁定电平 +10 dB）；包开始发送后再启动 AGC，采样削顶时重启 |
| `timed_bursts.m` | 快速 | 锁定电平 −8 dBFS（恒包络），10 ms 间隔内解锁，每个突发从最大增益重新攻击 |

2026-10-30 `run_agc` 十组全部 0 误码（OFDM 用 AGC 时 60 包全对，增益 29 dB，信噪比 26.9 dB）。
OFDM 重复运行时，快速 AGC 约每 6 次有 1 次锁得偏高约 13 dB（60 包错 2 包）；每包解锁（能量消失后回到
最大或优化增益）在这两块板上每次结果差别很大（60 包错 0～59 包），因此不采用。

## `glidelink.Radio`

| 调用 | 作用 |
|---|---|
| `r = glidelink.Radio("192.168.4.1")` | 连接（检查桥接协议版本） |
| `s = r.config(Rate=1e6, Freq=915e6, Bandwidth=2e6, RxGain=40, TxAtten=20)` | 射频设置并读回；另有 `RxFreq`、`TxFreq`、`RxGainMode`（`"slow_attack"`、`"fast_attack"`、`"hybrid"`、`"manual"`）、`Loopback`（AD9361 数字环回）。采样率 0.52～61.44 MSPS（40 MSPS 及以下由 libad9361 按采样率设计 FIR，以上只用驱动自身的滤波器；发射数据接口在 50 MSPS 以内逐位正确） |
| `r.txCyclic(x)` / `r.txStop()` | 在板上循环发送一段波形（复数，abs(x) ≤ 1），不占网络。波形不超过 2^23 个采样时放进 DMA 循环缓冲区，由硬件重复（任意采样率，不占 CPU；奇数长度时放两个周期）；更长时由板上线程写入（约 20 MSPS 以内） |
| `t = r.txBurst(x, 0.1)` / `r.txBurst(x, [], t)` | 在硬件时间"现在 + 0.1 s"（或 t，单位 ns）发送一个突发，按突发结束；排队后即返回，可以提前排定多个突发（桥接服务按顺序发送） |
| `[y, t, d] = r.rx(n)` | 在板上连续采集 n 个采样（复数，满幅为 1）后发回；t 为第一个采样的硬件时间（ns）。采集由板上的 C 库完成，50 MSPS 以内无丢失。d 为丢失报告：`Overflows` 缺口数，`Dropped` 丢失的采样总数，`Drops` 每行 [位置, 丢失数]（第“位置 + 1”个采样之前丢了这么多）；有丢失时给出警告 `glidelink:rxDrops`，此时数据不连续 |
| `t = r.time()` | 硬件时间（采样时钟），ns |
| `v = r.attr(name)` / `r.attr(name, value)` | AD9361 驱动的任意属性：sysfs（`"in_voltage0_rssi"` 等）或驱动参数（`"adi,agc-inner-thresh-high"` 等；`r.attr("initialize", 1)` 按这些参数重新初始化，桥接服务在初始化前后保持采样率、本振、带宽、增益模式 / 增益和发射衰减，客户端改过对应设备树参数的项除外）。驱动参数改动后一直有效，直到再改或板子重启 |
| `r.route(struct("slot0_in", "host1_tx", "host1_rx", "slot0_out"))` | 流交换路由，接收端 <- 来源 |
| `w = r.host1(words, m)` | 向主机端口 1（进入已连接的模块）发送 uint32 字，并取回 m 个字 |
| `v = r.reg("FPGA", addr)` / `r.reg("FPGA", addr, value)` | 外壳和模块寄存器（`"AD9361"`：芯片寄存器） |

MATLAB 中每个请求约 15 ms（tcpclient）；排定突发的脚本在第一个突发之前为每个突发留出这么多时间。
一块板可以同时连接多个 MATLAB 会话（或脚本），它们的命令轮流执行。
循环发送在启动它的连接关闭时（`clear r`）停止。

## 板子一侧

桥接服务在开机时加载板子的镜像并管理路由，因此不能与离线 DeepJSCC-Q 系统同时运行：在板上用
`systemctl start glidelinkd@tx`（或 `rx`）切换到离线系统，用 `systemctl start glidelink-bridge` 切回
（启动一个会停止另一个）。安装：`sw/bridge/install.sh <image.bit> --enable`。
