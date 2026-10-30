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
| `s = r.config(Rate=1e6, Freq=915e6, Bandwidth=2e6, RxGain=40, TxAtten=20)` | 射频设置并读回；另有 `RxFreq`、`TxFreq`、`RxGainMode`（`"slow_attack"`、`"fast_attack"`、`"hybrid"`、`"manual"`）、`Loopback`（AD9361 数字环回）。采样率 0.52～61.44 MSPS（按采样率设计 FIR） |
| `r.txCyclic(x)` / `r.txStop()` | 在板上循环发送一段波形（复数，abs(x) ≤ 1），不占网络 |
| `t = r.txBurst(x, 0.1)` / `r.txBurst(x, [], t)` | 在硬件时间"现在 + 0.1 s"（或 t，单位 ns）发送一个突发，按突发结束；排队后即返回，可以提前排定多个突发（桥接服务按顺序发送） |
| `[y, t] = r.rx(n)` | 在板上连续采集 n 个采样（复数，满幅为 1）后发回；t 为第一个采样的硬件时间（ns） |
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
