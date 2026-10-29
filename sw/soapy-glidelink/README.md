# SoapyGlideLink

SoapySDR 模块，经 libiio 访问 ADI 的 ad9361 / cf_axi_adc / cf_axi_dds 驱动。在板上默认用本地上下文（`uri=local:`），
在 PC 上经板上的 iiod 用网络上下文（`uri=ip:192.168.3.1`）。

当前实现（第 0 阶段）：

- 标准参数：频点（RX / TX 各一个本振，两通道共用）、采样率（RX / TX 共用）、模拟带宽、天线端口、增益。
  RX 增益即 `hardwaregain`（−3 ~ 71 dB），自动增益为 `slow_attack`；TX 增益 = 89.75 dB + `hardwaregain`（衰减取负）。
- 流：RX / TX 各两通道，格式 CS16（12 位样点，满量程 2048，TX 写入时左移 4 位对齐 DAC）与 CF32；
  `bufferLength` 为每个 IIO 缓冲区的样点数（默认 16384），TX 在缓冲区写满或带 `END_BURST` 时提交。
- 寄存器：接口名 `AD9361`，读写 AD9361 任意 SPI 寄存器。

尚未实现：时间戳、溢出 / 欠载报告、驱动配置参数（`writeSetting`）、外壳与模块寄存器。

## 构建

依赖 libiio（0.23）与 SoapySDR（0.8），在板上直接编译：

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j4
sudo cmake --install build
SoapySDRUtil --probe="driver=glidelink"
```

## 测试

`sw/tests/tone_loopback.py`：TX 发单音，RX 接收并给出频谱峰值。打开 AD9361 内部数字环回
（`echo 1 > /sys/kernel/debug/iio/iio:device1/loopback`）时可不经射频验证整条数据通路。

板上实测：RX 与 TX 各自在 10 MSPS 连续流化无丢失，TX 在 30.72 MSPS 可满速；RX 在约 19 MSPS 封顶。
后者的原因推测为 DMA 缓冲区对 CPU 不可缓存（设备树叠加未标 `dma-coherent`，HPC 端口未设置一致性），CPU 读未缓存内存慢。
