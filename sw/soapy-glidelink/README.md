# SoapyGlideLink

SoapySDR 模块，经 libiio 访问 ADI 的 ad9361 / cf_axi_adc / cf_axi_dds 驱动。在板上默认用本地上下文（`uri=local:`），
在 PC 上经板上的 iiod 用网络上下文（`uri=ip:192.168.3.1`）。

当前实现（第 2 阶段），控制分三层（设计文档 7.2 节）：

- 标准参数：频点（RX / TX 各一个本振，两通道共用）、采样率（RX / TX 共用）、模拟带宽、天线端口、增益。
  RX 增益即 `hardwaregain`（−3 ~ 71 dB）；TX 增益 = 89.75 dB + `hardwaregain`（衰减取负）。
  `setGainMode(true)` 从手动切到 `slow_attack`，已经处在某种自动增益模式（如经设置项选的 `fast_attack`）时保持不变；
  自动增益下写 RX 增益被忽略（由芯片控制；gr-soapy 总会写一次增益）。
- 驱动配置参数（设置项，`writeSetting` / `readSetting`，`SoapySDRUtil --probe` 列出）：
  - AD9361 驱动在 debugfs 中给出的全部参数，名字与设备树属性相同（如 `adi,agc-inner-thresh-high` 为快速 AGC 的锁定电平），
    另有 `loopback` 等调试属性。经 libiio 的调试属性访问，板上与经网络都可用。设备树参数写入后在重新初始化时生效。
  - `initialize`：写 `true` 按当前参数重新初始化 AD9361（约 1 s）。初始化会把频点、采样率、带宽、端口、增益模式和增益
    恢复成设备树的值，模块事先记下这些标准参数并在初始化后写回；自上次初始化以来写过对应设备树参数
    （`adi,rf-rx-bandwidth-hz`、`adi,rf-tx-bandwidth-hz`、`adi,rx-rf-port-input-select`、`adi,tx-rf-port-input-select`、
    `adi,gc-rx1-mode` / `adi,gc-rx2-mode`、`adi,tx-attenuation-mdB`）的项以设备树参数为准。
  - `gain_control_mode`：RX 增益控制模式（`manual`、`fast_attack`、`slow_attack`、`hybrid`）。
  - 按通道的设置调用（gr-soapy 的 “Other settings”）落到同一组设置。
- 原始寄存器：接口名 `AD9361`，读写 AD9361 任意 SPI 寄存器；有外壳时另有 `FPGA`（外壳寄存器窗口，字节偏移，含槽位窗口）。
  驱动在改采样率、切换增益模式、重新初始化时会重写相关寄存器，直接写入的值可能被覆盖；长期使用的设置放在驱动参数一层。
- 流：
  - 射频（主机端口 0）：有外壳时 RX / TX 各一个通道（外壳 CAPS 中的射频通道数，第一版 1R1T），否则按 IIO 设备的通道数；
    格式 CS16（12 位样点，满量程 2048，TX 写入时左移 4 位对齐 DAC）与 CF32。
  - 主机端口 1（流参数 `port=1`，外壳 1.2 起）：槽位中模块的数据，32 位字原样作为 CS16（CF32 满量程 32768），一个通道。
    路由由用户经 `FPGA` 寄存器或 gr-glidelink 的控制块设定。
  - `transport`：经网络时采样走 `auto`（板上有 glidelink-streamd 时用它，默认）、`iiod`（libiio 缓冲区）或 `streamd`（`sw/streamd`，UDP 流，
    客户端在 `streamd_udp.hpp`）。设置与寄存器始终经 libiio。`frameSize` 为 UDP 包的字节数（含 16 字节包头）；0（默认）按平台取：
    Windows 8000（板子的 USB 网口用巨型帧），Linux 取连接的路径 MTU 减 28、至多 8000（WSL 中为 1472）。UDP 流中丢了包时，
    原始模式下 `readStream` 先返回一次 `SOAPY_SDR_OVERFLOW`，包头模式下丢掉当前的包、在下一个包头处接上。
  - `bufferLength` 为每个 IIO 缓冲区的样点数（默认 65536），TX 在缓冲区写满或带 `END_BURST` 时提交。RX 的 DMA 按整块交付，
    原始模式下不满一块的尾巴要等后续数据。
  - 外壳 1.1 起默认走包头（流参数 `headers=false` 关闭）：`readStream` 给出 `timeNs`，包头中的丢包标志变为 `SOAPY_SDR_OVERFLOW`，
    读完带“突发结束”标志的包时给出 `SOAPY_SDR_END_BURST`（外壳 1.3 起）；`writeStream` 每次调用为一个包，带 `SOAPY_SDR_HAS_TIME`
    定时发送，`SOAPY_SDR_END_BURST` 结束突发。包头模式下主机 RX 端口在 DMA 来不及收时整包丢弃，不反压上游。
  - 启动流时先清理端口（`PORT_RESET`），连同沿路由串在该端口上的槽位（RX 往上游、TX 往下游；槽位清理只清数据通路，寄存器保留），接收流在 DMA 缓冲建好后才打开 RX 流化；停止时恢复原始模式。
    用户设好的路由保留，主机端口 0 的路由为空时接回射频。
- 时间：`getHardwareTime` / `setHardwareTime` 为外壳的采样计数器，按当前采样率换算为纳秒。
- 采样率上限 50 MSPS（第三方子卡的 TX 接口余量，见 `hw/README.md`）。
- 网络：PC 上用 `uri=ip:<板子>`，经板上的 iiod。iiod 只在启动时扫描设备，`hw/scripts/load_overlay.sh` 加载叠加后会重启它。
  libiio 超时 1 s，可能更慢的操作（改采样率换 FIR 最长约 1.4 s、写驱动参数、重新初始化）临时放宽到 10 s，
  否则经网络时超时会断开与 iiod 的连接。经板子的 USB 网口实测：经 iiod 收、发各 20 MSPS 无丢失；经 glidelink-streamd，
  Windows 原生程序收发同时各 50 MSPS，WSL 中接收 50、发射约 48 MSPS（`docs/known_issues.md` 1.3）。

## 构建

### Linux（板上、WSL）

依赖 libiio（0.23 起）与 SoapySDR（0.8），在板上直接编译：

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j4
sudo cmake --install build
SoapySDRUtil --probe="driver=glidelink"
```

### Windows

模块要和 SoapySDR 用同一种编译器：radioconda / conda-forge 的 SoapySDR 用 MSVC 编译，所以模块也用 MSVC。依赖：

- [radioconda](https://github.com/radioconda/radioconda-installer/releases)（含 Windows 版 GNU Radio、SoapySDR 0.8、libiio）；
- Visual Studio 2022 生成工具，只需 C++ 的 MSVC x64 与一个 Windows SDK（只有编译模块时需要，使用者不需要）。

```bat
sw\soapy-glidelink\build_win.bat install D:\radioconda
```

生成 `build-win\glidelinkSupport.dll`，`install` 把它复制到 `<radioconda>\Library\lib\SoapySDR\modules0.8`。
不复制时可设环境变量 `SOAPY_SDR_PLUGIN_PATH` 指向 `build-win`。radioconda 中没有 CMake，脚本直接调用 `cl`；
装了 CMake 时 `CMakeLists.txt` 同样可用（libiio 经 pkg-config 或直接找 `iio.h` / `libiio.lib`）。

## 测试

| 脚本（`sw/tests/`） | 作用 |
|---|---|
| `tone_loopback.py` | TX 发单音，RX 接收并给出频谱峰值；打开 AD9361 内部数字环回时可不经射频验证数据通路 |
| `ramp_loopback.py` | 经 AD9361 数字环回逐样点核对收发数据（I 为连续计数，Q 为 TX 缓冲区序号），走 Soapy 模块 |
| `ramp_loopback_iio.c` | 同上，C 语言直接用 libiio，用于 Python 跟不上的高采样率 |
| `known_waveform.py` | 两板之间：一块循环发 Zadoff-Chu 序列，另一块相关检测，给出定时、频偏与信噪比 |
| `settings_init.py` | 三层控制：改快速 AGC 参数并重新初始化，核对寄存器与恢复的标准参数；设备树参数优先；AD9361 寄存器读写（板上或 `--args ...,uri=ip:...`） |
| `host1_soapy.py` | 主机端口 1 经槽位 0 自环，原始模式与包头模式逐字核对，包头时间戳原样返回 |
| `gr_agc_init.py` | GNU Radio 中（PC 经网络）运行时改锁定电平并重新初始化，数据流不断 |

板上实测（内核打上 `os/kernel/patches/0001` 之后）：Soapy 模块 RX、TX 各自 61.44 MSPS 满速；
`ramp_loopback_iio` 在 61.44 MSPS 全双工下连续 20 s 逐样点核对无丢失、无旧数据。
Python 收发同时进行时约 5 MSPS 以内无丢失，再高受 Python 本身速度限制。
