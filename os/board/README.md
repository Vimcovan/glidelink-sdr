# 板上系统配置

## 网口（`install_net.sh`）

在板上以 root 运行 `bash install_net.sh`，下次开机生效；`bash install_net.sh --undo` 恢复原状。

- USB 设备配置中的网卡功能由 RNDIS 改为 NCM（修改 PYNQ 的 `/usr/local/bin/usbgadget`，原文件保存为 `usbgadget.rndis`）。
  NCM 把多个以太网帧装进一次 USB 传输，板上的 USB 中断次数少一个数量级；RNDIS 每帧一次传输，单纯 TCP 在约 77 MB/s 处
  就被 USB 中断线程单核占满。Windows 10 / 11 自带 NCM 驱动（UsbNcm），不用另装；串口与存储盘保留。
- usb0 起来后（同一脚本末尾）：USB 控制器的中断固定在 CPU 0，usb0 收到的包的协议处理（确认包以及由它触发的发送）用接收包分流（RPS）放到 CPU 1～3，不再全部压在中断所在的核上。
- TCP 缓冲上限写入 `/etc/sysctl.d/90-glidelink-net.conf`（16 MB）：默认 208 KB 的接收上限经 NCM 时把电脑→板子的 TCP 限在约 63 MB/s。

2026-11-01 两块板都已安装。发射板上单纯 TCP（板上 C 程序，电脑端 Python）：

| | 板子→电脑 | 电脑→板子 |
|---|---|---|
| RNDIS | 77 MB/s | 121 MB/s |
| NCM + 缓冲上限 | 208 MB/s | 193 MB/s |
