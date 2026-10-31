# glidelink-streamd

板上的采样流服务：在板子的 IIO DMA 缓冲与电脑之间经 UDP 连续传送采样，供经 USB 网口的高采样率使用。
Soapy 模块（`sw/soapy-glidelink`，客户端 `streamd_udp.hpp`）经网络时默认使用它（流参数 `transport=auto`）。

做法参照 UHD 对网口 USRP 的传输（`host/docs/driver_usage/transport.dox`、RFNoC 规范 2.2.4）：

- 建流经 TCP 端口 7040（一行请求、一行应答），TCP 连接也是流的生命周期：连接断开，流结束；对端 5 s 不应答也结束（`TCP_USER_TIMEOUT`）。
- 数据走 UDP，每个包 16 字节包头：魔数、包类型（数据 / 状态）、标志（数据包"本块缓冲结束"）、32 位序号；UDP 校验和为 0
  （网口 USRP 的 FPGA 也不算）。一根 USB 线点对点，包按发出的顺序到达，序号跳了就是丢包。
- 两个方向都有流量控制，状态包反向传：接收方向电脑每消耗自己接收缓冲的 1/32 报一次，板子在途字节不超过电脑的容量，
  电脑来不及时由板子的 DMA 溢出（外壳计数），不在套接字里悄悄丢包；发射方向板子每消耗自己容量的 1/8 报一次。
- 电脑先向板子发第一个包（状态包），防火墙（Windows、WSL）才放行板子发来的 UDP。
- 板子发包用 UDP 分段卸载（`UDP_SEGMENT`，一次交给内核约 64 KB，内核切成包），比逐包发送省约 40 % 的 CPU；
  这要求网卡声明校验和卸载，板上 NCM 网卡由内核补丁 0005 提供（IPv4 UDP 的校验和写 0）。不支持时自动改为逐包发送。
- 只搬运原始的 DMA 字，不解释内容：原始采样与外壳的包头（时间戳、突发结束、丢包标志）都原样通过。
  采样率、路由、包头模式等设置仍经 libiio / iiod。协议细节见 `glidelink_streamd.c` 开头的说明。

## 安装（板上，root）

```bash
cd sw/streamd && bash install.sh
```

编译、安装 systemd 服务 `glidelink-streamd`（开机启动，运行在 CPU 1～3，USB 中断在 CPU 0，见 `os/board/install_net.sh`）。

## 实测

见 `docs/known_issues.md` 1.3：Windows 原生程序（8000 字节的包）收发同时各 50 MSPS，WSL 中的程序（1472 字节的包）接收 50、发射约 48 MSPS。
