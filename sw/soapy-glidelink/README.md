# SoapyGlideLink

SoapySDR 模块，经 libiio 访问 ADI 的 ad9361 / cf_axi_adc / cf_axi_dds 驱动。在板上默认用本地上下文（`uri=local:`），
在 PC 上经板上的 iiod 用网络上下文（`uri=ip:192.168.3.1`）。

当前实现（第 1 阶段）：

- 标准参数：频点（RX / TX 各一个本振，两通道共用）、采样率（RX / TX 共用）、模拟带宽、天线端口、增益。
  RX 增益即 `hardwaregain`（−3 ~ 71 dB），自动增益为 `slow_attack`；TX 增益 = 89.75 dB + `hardwaregain`（衰减取负）。
- 流：有外壳时 RX / TX 各一个通道（外壳 CAPS 中的射频通道数，第一版 1R1T），否则按 IIO 设备的通道数；格式 CS16（12 位样点，满量程 2048，TX 写入时左移 4 位对齐 DAC）与 CF32；
  `bufferLength` 为每个 IIO 缓冲区的样点数（默认 65536），TX 在缓冲区写满或带 `END_BURST` 时提交。
- 寄存器：接口名 `AD9361`，读写 AD9361 任意 SPI 寄存器；有外壳时另有 `FPGA`（外壳寄存器窗口，字节偏移，含槽位窗口）。
- 时间：`getHardwareTime` / `setHardwareTime` 为外壳的采样计数器，按当前采样率换算为纳秒。
- 外壳 1.1 起，射频流默认走主机端口 0 的包头（流参数 `headers=false` 关闭）：`readStream` 给出 `timeNs`，
  包头中的丢包标志变为 `SOAPY_SDR_OVERFLOW`；`writeStream` 每次调用为一个包，带 `SOAPY_SDR_HAS_TIME` 定时发送，
  `SOAPY_SDR_END_BURST` 结束突发。启动流时先清理端口（`PORT_RESET`），接收流在 DMA 缓冲建好后才打开 RX 流化；
  停止时恢复原始模式。
- 采样率上限 50 MSPS（第三方子卡的 TX 接口余量，见 `hw/README.md`）。

尚未实现：驱动配置参数（`writeSetting`）、主机端口 1 的流。

## 构建

依赖 libiio（0.23）与 SoapySDR（0.8），在板上直接编译：

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j4
sudo cmake --install build
SoapySDRUtil --probe="driver=glidelink"
```

## 测试

| 脚本（`sw/tests/`） | 作用 |
|---|---|
| `tone_loopback.py` | TX 发单音，RX 接收并给出频谱峰值；打开 AD9361 内部数字环回时可不经射频验证数据通路 |
| `ramp_loopback.py` | 经 AD9361 数字环回逐样点核对收发数据（I 为连续计数，Q 为 TX 缓冲区序号），走 Soapy 模块 |
| `ramp_loopback_iio.c` | 同上，C 语言直接用 libiio，用于 Python 跟不上的高采样率 |
| `known_waveform.py` | 两板之间：一块循环发 Zadoff-Chu 序列，另一块相关检测，给出定时、频偏与信噪比 |

板上实测（内核打上 `os/kernel/patches/0001` 之后）：Soapy 模块 RX、TX 各自 61.44 MSPS 满速；
`ramp_loopback_iio` 在 61.44 MSPS 全双工下连续 20 s 逐样点核对无丢失、无旧数据。
Python 收发同时进行时约 5 MSPS 以内无丢失，再高受 Python 本身速度限制。
