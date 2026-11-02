# 教程：QPSK 收发，从纯软件到全部卸载到 PL

两块板之间跑一条 QPSK 链路：发射板（192.168.4.1）发、接收板（192.168.3.1）收，符号率 5 Msymbol/s，射频采样率 20 MSPS（每符号 4 个样点）。
先用 GNU Radio 在电脑上完成全部信号处理，再一步一步把处理搬进 PL，每一步只改流程图，最后电脑只需送符号、收符号。

| 步骤 | 流程图 | 发射：电脑做什么 / PL 做什么 | 接收：PL 做什么 / 电脑做什么 | 电脑收 / 发（实测） | 符号 EVM（实测） |
|---|---|---|---|---|---|
| 0 | `ota_qpsk.grc` | 调制、成形滤波 / — | — / AGC、FLL、时钟同步、Costas | 收不动：先 12 MSPS，十几秒后卡死；发 14～18 MSPS | 不锁定 |
| 1 | `ota_qpsk_pltx.grc` | 送符号 / 插值成形 | — / 同上 | 收 7～16 MSPS（应为 20，持续溢出，每次运行不同，偶尔崩溃）；发 5 MSPS | 约 −19 dB |
| 2 | `ota_qpsk_pl.grc` | 同上 | 低通抽取 / AGC、FLL、时钟同步、Costas | 收 10 MSPS；发 5 MSPS | 约 −19.5 dB |
| 3 | `ota_qpsk_plrx.grc` | 同上 | 抽取、AGC、FLL、匹配滤波、符号同步、Costas / 只看星座 | 收 5 MSPS；发 5 MSPS | 约 −19.6 dB |

实测环境：i5-14600KF 的 Windows 电脑，radioconda 中的 GNU Radio 3.10，两块板天线相距约 1 m，915 MHz。流程图都在
`sw/gr-glidelink/examples/`。表中的速率和 EVM 可以用 `sw/tests/flowgraph_probe.py` 自己测（第 6 节）。

## 1. 准备

1. 两块板各用一根 USB 线接电脑，电脑端环境按 [`pc_setup.md`](pc_setup.md) 装好（radioconda、GlideLink 的 Soapy 模块、gr-glidelink）。
   GNU Radio Companion（GRC）从开始菜单的 radioconda 文件夹启动。
2. 第 1 步起要用 PL 中的模块，两块板都换成 `qpsk` 镜像（第 0 步任何镜像都可以）。在仓库根目录：

   ```bash
   python glidelink.py deploy 192.168.4.1 qpsk
   ```

   ```bash
   python glidelink.py deploy 192.168.3.1 qpsk
   ```

   `hw/build/qpsk/` 下没有构建好的镜像时，先 `python glidelink.py build qpsk`（Vivado，约半小时）。镜像里的模块（`hw/images/qpsk.yaml`）：

   | 槽位 | 模块 | 用在 |
   |---|---|---|
   | 1 | `rrc_interp`：RRC 成形滤波，插值 4 倍 | 发射板 |
   | 2 | `lp_decim`：低通滤波，抽取 2 倍 | 接收板 |
   | 3～7 | `agc`、`fll`、`rrc_mf`（RRC 匹配滤波）、`symsync`（符号同步）、`costas` | 接收板 |

   两块板用同一个镜像，各自只用到其中一部分。`python glidelink.py status <板子地址>` 显示板上各槽位的模块。流程图里的模块块按模块 ID 自己找槽位，
   不用关心槽位号。

3. GRC 中的块分两类，后面要用到：
   - 普通块（白色端口）：在电脑上运行，数据经 USB 网口在电脑与板子之间传送。GlideLink Source / Sink 是电脑与板子交接数据的地方。
   - PL 块（名字带 "(PL)"，橙色端口）：模块在板子的 PL 里运行，橙色连线就是 PL 内部的连接，数据不经过电脑。
     GlideLink Source / Sink 也有一个橙色端口（`pl_in` / `pl_out`），用来接 PL 块。

## 2. 第 0 步：纯软件（`ota_qpsk.grc`）

在 GRC 中打开 `ota_qpsk.grc`：

- 发射：Random Source（随机字节）→ Constellation Modulator（QPSK、每符号 4 个样点、RRC 成形，滚降 0.35）→ Multiply Const（0.5，留出余量）→
  GlideLink Sink（发射板，`samp_rate` 20 MSPS）。
- 接收：GlideLink Source（接收板，20 MSPS）→ AGC → FLL Band-Edge（粗频偏）→ Polyphase Clock Sync（RRC 匹配滤波与符号定时，每符号输出一个点）
  → Costas Loop（相位与残余频偏）→ 星座图。频谱、瀑布图和同步前的星座接在 Source 与 AGC 后面。

点运行（F6）。20 MSPS 下电脑跟不上：

- 控制台一直打印 `sO`：`O` 是接收溢出，板上的 DMA 因为电脑读得慢而丢了样点。
- 实测电脑起初每秒只收到约 12 MSPS，十几秒后接收完全停住，频谱、星座图不再刷新；发射也只送出 14～18 MSPS，空中信号时有时无。
  原因见 [`known_issues.md`](known_issues.md) 中 `ota_qpsk.grc` 一条：FLL 单核只能处理约 16 MSPS，信号断续又让时钟同步卡住。

把 `samp_rate` 改成 `5e6`（符号率随之降到 1.25 Msymbol/s）再运行，同一个流程图就能稳定工作：电脑收发各 5 MSPS，同步后的星座清晰，
实测 EVM 约 −26 dB（带宽窄，噪声小，所以比后面 20 MSPS 的结果好）。流程图本身没有问题，问题是电脑要在 20 MSPS 上做全部处理。
改回 `20e6`，接下来把处理搬到 PL。

## 3. 第 1 步：发射成形滤波卸载到 PL（`ota_qpsk_pltx.grc`）

发射端最费算力的是成形滤波：电脑要按 20 MSPS 算出每个样点。PL 中的 `rrc_interp` 做同样的事：每个符号插值成 4 个样点、RRC 滚降 0.35，
和 Constellation Modulator 的设置一致。电脑只送符号，每秒 5 M 个。

在 `ota_qpsk.grc` 的基础上修改（另存为新文件），或直接打开 `ota_qpsk_pltx.grc` 对照：

1. 删掉 Constellation Modulator，换成三个块，把字节变成 QPSK 符号，每个符号一个样点：
   - Packed to Unpacked：`Bits per Chunk` 2，`Endianness` MSB；
   - Chunks to Symbols：`Symbol Table` 填 `qpsk.points()`（变量 `qpsk` 已在流程图中）；
   - Multiply Const 改成 0.4（插值滤波的峰值比符号高，留出余量）。
2. GlideLink Sink 保留，它的白色输入仍接电脑送来的符号。在它的橙色输出 `pl_out` 后面依次接：
   - GlideLink RRC interpolator (Xilinx FIR Compiler) (PL)（`[GlideLink]/FPGA modules` 分类下）：`Device arguments` 填
     `"driver=glidelink,uri=ip:192.168.4.1"`，`Slot` 保持 -1（自动找）。这个块没有系数参数，系数在镜像里已经固定；
   - GlideLink Radio (PL)（`[GlideLink]` 分类下）：`Board` 填发射板 `"192.168.4.1"`，`Sample rate` 填 `samp_rate`，`TX frequency` 填 `freq`，
     `RX frequency` 填 `freq - 10e6`（让本板的发射本振离开自己的接收频段），`TX attenuation (dB)` 填 `tx_atten`，`RX gain (dB)` 填 0，
     其余保持默认。PL 链路的射频参数由它设置：橙色连线一直通到射频，射频的采样率、频率、衰减都在这个块上。
3. 接收端不动。

运行。实测：

- 电脑稳定发出 5 MSPS，发射端的处理不再受电脑限制。
- 接收端仍然是 20 MSPS 的纯软件处理，控制台持续打印 `O`。三次运行中电脑每秒收到的样点分别约为 16.4、7.3、7.5 M（GNU Radio 每个块一个线程，
  落在能效核上的块更慢，所以每次不同）；第一次运行 35 秒左右进程崩溃，是丢样严重时 GNU Radio 时钟同步块的问题
  （[`known_issues.md`](known_issues.md) 中 `ota_qpsk.grc` 一条）。没崩溃时星座能锁上，EVM 约 −19 dB，但一直在丢样点。瓶颈在接收端。

## 4. 第 2 步：接收抽取卸载到 PL（`ota_qpsk_pl.grc`）

QPSK 信号只占射频采样带宽的一部分（滚降 0.35 时约 ±3.4 MHz），接收端先低通滤波、抽取到每符号 2 个样点（10 MSPS），后面的同步处理就足够了。
PL 中的 `lp_decim` 做这一步，电脑只收一半的样点。

1. 在 GlideLink Source 的橙色输入 `pl_in` 前面依次接：
   - GlideLink Radio (PL)：`Board` 填接收板 `"192.168.3.1"`，`Sample rate` 填 `samp_rate`，`RX frequency` 填 `freq`，`Gain mode` 填 `"slow_attack"`，
     `RX gain (dB)` 填 `rx_gain`，`TX frequency` 保持 0，`TX attenuation (dB)` 填 89（接收板不发射）；
   - GlideLink Low-pass decimator by 2 (Xilinx FIR Compiler) (PL)：`Device arguments` 填 `"driver=glidelink,uri=ip:192.168.3.1"`。
   
   连线顺序：Radio 的 `pl_out` → 抽取块 → Source 的 `pl_in`。Source 的白色输出就是抽取后的样点。
2. 电脑上的接收处理改成每符号 2 个样点：
   - 新建变量 `decim` = 2、`rx_sps` = `sps // decim`；
   - FLL Band-Edge 的 `Samples Per Symbol` 填 `rx_sps`；
   - Polyphase Clock Sync 的 `Samples/Symbol` 填 `rx_sps`，滤波器系数变量 `rrc_taps` 改为
     `firdes.root_raised_cosine(32, 32 * rx_sps, 1.0, 0.35, 11 * rx_sps * 32)`，`Maximum Rate Deviation` 改成 0.05
     （两板时钟偏差远小于这个值；保留 1.5 在每符号 2 个样点时会停在边界上假锁）。
   - 频谱、瀑布图的带宽改为 `samp_rate / decim`。

运行。实测：电脑收 10 MSPS、发 5 MSPS，不再溢出，EVM 约 −19.5 dB。电脑端的 FLL、时钟同步、Costas 仍在运行，处理 10 MSPS 已经够用。

## 5. 第 3 步：整个接收链卸载到 PL（`ota_qpsk_plrx.grc`）

把电脑上剩下的接收处理也换成 PL 块，电脑每个符号只收一个点。电脑上的块与 PL 块的对应：

| 电脑上的块 | PL 块（都在 `[GlideLink]/FPGA modules` 下） | 参数 |
|---|---|---|
| AGC | GlideLink AGC (PL) | `rate` 1e-3、`reference` 0.5、`gain` 1.0、`max_gain` 1000 |
| FLL Band-Edge | GlideLink FLL band-edge (PL) | `sps` 填 `rx_sps`、`rolloff` 0.35、`filter_size` 44、`w` 填 `6.28 / 400`（与 GNU Radio 的块同义） |
| Polyphase Clock Sync | GlideLink RRC matched filter (Xilinx FIR Compiler) (PL)，接 GlideLink Symbol sync (Gardner) (PL) | 匹配滤波无参数（每符号 2 个样点、滚降 0.35，固定在镜像里）；符号同步 `loop_bw` 0.01、`damping` 0.707、`max_dev` 0.01、`ted_gain` 0.3 |
| Costas Loop | GlideLink Costas loop (PL) | `w` 填 `6.28 / 200` |

GNU Radio 的 Polyphase Clock Sync 把匹配滤波和符号定时合在一个块里，PL 中是两个模块：先匹配滤波，再用 Gardner 定时误差检测和
Farrow 插值找符号时刻，每个符号输出一个点。

1. 删掉电脑上的 AGC、FLL Band-Edge、Polyphase Clock Sync、Costas Loop，以及接在它们后面的星座图。
2. 在抽取块与 GlideLink Source 之间，用橙色连线依次接 AGC → FLL → 匹配滤波 → 符号同步 → Costas，每个块的 `Device arguments` 都填接收板
   `"driver=glidelink,uri=ip:192.168.3.1"`。整条链为：Radio → 抽取 → AGC → FLL → 匹配滤波 → 符号同步 → Costas → Source。
3. Source 的白色输出现在就是符号，接一个 QT GUI Constellation Sink 看星座。
4. （可选）看各环路的状态：PL 块可以读模块的寄存器。加一个 Function Probe，`Block ID` 填 `fll`（FLL 块的 ID），`Function Name` 填 `read`，
   `Function Args` 填 `'FREQ'`，再用 QT GUI Label 显示换算后的值；`ota_qpsk_plrx.grc` 中有 FLL 频率、符号时钟偏差、Costas 频率三个读数。
   FLL 与 Costas 的频率读数大小相近、方向相抵（各约 55 kHz），原因见 [`known_issues.md`](known_issues.md) 中带边 FLL 一条，星座不受影响。

运行。实测：电脑收 5 MSPS（每符号一个点）、发 5 MSPS，EVM 约 −19.6 dB，和第 2 步电脑端处理的结果一样。

至此电脑只做两件事：产生要发的符号，显示收到的符号。镜像里的全部 PL 模块共用 42 个 DSP（`fll` 20 个，其余每个 1～6 个）。

## 6. 自己测速率和 EVM

GRC 本身不显示电脑实际收发的速率。`sw/tests/flowgraph_probe.py` 运行一个流程图（照常打开窗口），每 10 秒打印一次电脑收、发的速率和
符号的 EVM。在 "radioconda Prompt" 中：

```bash
python sw/tests/flowgraph_probe.py sw/gr-glidelink/examples/ota_qpsk_pl.grc --secs 60
```

收到的速率低于流程图要求的速率（第 0、1 步应为 20 MSPS），说明有样点丢了。块 ID 不是 `rx`、`tx`、`costas` 的流程图用
`--rx`、`--tx`、`--symbols` 指定。

## 7. 常见问题

| 现象 | 处理 |
|---|---|
| GRC 中找不到 GlideLink 的块，或块的参数和教程不一样 | 重新安装 gr-glidelink：`D:\radioconda\python.exe sw\gr-glidelink\install_conda.py`，再重启 GRC |
| 运行时报找不到某个模块的槽位 | 板上不是 `qpsk` 镜像：`python glidelink.py status <板子地址>` 查看，按第 1 节部署 |
| 控制台一直打印 `O` | 电脑来不及处理：降低 `samp_rate`，或把更多处理搬到 PL |
| 运行时进程偶尔直接退出（第 0～2 步） | 第 0、1 步丢样严重时，GNU Radio 的时钟同步块会崩溃（[`known_issues.md`](known_issues.md)）；第 2 步实测 7 次中有 1 次刚启动就退出（当时没有丢样，原因未查明），重新运行即可。第 3 步电脑上不再运行这些接收块 |
| 想确认某个 PL 模块和电脑上的算法一致 | 每个模块都有一个同名的软件块（名字带 "(software)"），可以替换 PL 块对照；或用 `sw/tests/gr_module_swap.py <模块 ID>` 在板上逐样点比较（[`module_guide.md`](module_guide.md) 第 4 节） |
