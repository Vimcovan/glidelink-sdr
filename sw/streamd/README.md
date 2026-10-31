# glidelink-streamd

板上的采样流服务（TCP 端口 7040）：在板子的 IIO DMA 缓冲与电脑之间连续传送采样，供经 USB 网口的高采样率使用。

- iiod 每块缓冲一问一答，还要在用户空间多拷贝一次，经网口收约 32.7 MSPS、发约 24.5 MSPS 就到顶；
  这里一条流连续进行：接收时缓冲一满就发出，发射时收到就提交，不等应答。
- 一条流可以分在多条 TCP 连接上（第 i 块缓冲走第 i mod K 条连接），每条连接一个线程：板上一个核大约只能处理 200 MB/s 的 TCP。
- 只搬运原始的 DMA 字，不解释内容：原始采样与外壳的包头（时间戳、突发结束、丢包标志）都原样通过。
  采样率、路由、包头模式等设置仍经 libiio / iiod。

Soapy 模块（`sw/soapy-glidelink`）经网络时默认使用它（流参数 `transport=auto`），协议见 `glidelink_streamd.c` 开头的说明。

## 安装（板上，root）

```bash
cd sw/streamd && bash install.sh
```

编译、安装 systemd 服务 `glidelink-streamd`（开机启动，运行在 CPU 1～3，USB 中断在 CPU 0，见 `os/board/install_net.sh`）。

## 实测

见 `docs/known_issues.md` 1.3：板上 NCM 巨型帧（内核补丁 0003、0004）之后，Windows 中的程序收发各 50 MSPS（可同时），
WSL 中的程序接收 50、发射约 45 MSPS。连接在对端 5 s 不应答时结束（`TCP_USER_TIMEOUT`），IIO 缓冲随之释放。
