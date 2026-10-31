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

## 实测（2026-11-01，发射板，内核补丁 0003 之后：NCM 每次 USB 传输至多约 64 KB）

接收在接收板与发射板上都测过；发射只能在发射板上测（接收板的 `rx` 镜像中主机端口 0 没有接到 DAC，`docs/known_issues.md` 2.2）。
丢失看外壳计数器：接收 `HOST0_RX_OVF`（0x058），发射 `TX_UNDERFLOW`（0x044）。

| 测法 | 结果 |
|---|---|
| 接收 50 MSPS，C 客户端，1～4 条连接 | 200 MB/s，跟满（`HOST0_RX_OVF` 每次 +13～30，多半在开始 / 结束时） |
| 接收 50 MSPS，`SoapySDRUtil`（默认 3 条连接） | 49.5～49.7 MSPS，溢出只在开始的几秒 |
| 发射 50 MSPS，C 客户端，1 / 2 / 3 / 4 条连接 | 48.0 / 50.05 / 51.1 / 51.4 MSPS，10 s 内欠载 +154 / +79 / +4 / +7 |
| 发射 50 MSPS，Soapy（Python，262144 个采样的缓冲，3 条连接） | 40～52 MSPS，每次结果不同，10 s 内欠载 +3～+99 |
| 发射 50 MSPS，`SoapySDRUtil`（65536 个采样的缓冲） | 26～33 MSPS |
| 收发同时各 50 MSPS，C 客户端，各 3 条连接 | 收 41、发 22.7 MSPS，合计约 255 MB/s |

接收已能跟满 50 MSPS；电脑→板子方向还不稳定（板上一个软中断线程 `ksoftirqd/N` 占满一核），收发同时合计约 255 MB/s 封顶。
