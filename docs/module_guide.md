# 自定义 FPGA 模块

一个模块放在 `hw/modules/<id>/`，开发者写三样东西：

| 文件 | 内容 |
|---|---|
| RTL | 模块本身：时钟复位、`flush`、AXI4-Stream 输入输出，寄存器以普通端口的形式出现 |
| `module.yaml` | 名字、RTL 文件、寄存器表、GNU Radio 块的参数（及其到寄存器的换算） |
| `model.py`（可选） | 参考模型：寄存器级的 Python 类 `Model` |

其余由脚本生成：

| 生成的东西 | 来源 | 由谁生成 |
|---|---|---|
| 寄存器文件 `<top>_slot.v`：AXI4-Lite、地址译码、ID / VERSION、读回多路选择，把模块接进槽位 | 寄存器表 | `hw/scripts/gen_module.py`，构建镜像（`gen_image.py`）与仿真（`run_module_sim.ps1`）时自动调用，不进源码树 |
| GNU Radio 的 PL 块 `glidelink_<id>`（只写寄存器，橙色端口在 PL 内连线）与软件块 `glidelink_<id>_model`（跑参考模型） | `block` 段 + `model.py` | 安装 gr-glidelink 时（`install_conda.py` 或 CMake） |
| Python 中按名字读写寄存器 | 寄存器表 | `gnuradio.glidelink.modules.slot_registers`，PL 块的 `read(名字)` / `write(名字, 值)` |

PL 块按模块 ID 自己找槽位（槽位参数填 -1，默认值），换镜像、调整槽位顺序都不用改流程图。

从写好 RTL 到在 GRC 里使用，是仓库根目录 `glidelink.py` 的四条命令（第 5 节是完整的例子）：

```bash
python glidelink.py new <id>              # 骨架：直通模块，能直接测试、构建
python glidelink.py test <id>             # 仿真，与参考模型逐拍比较，并检查寄存器读回
python glidelink.py build <id> [<id> ...] --name <镜像>
python glidelink.py deploy <板子地址> <镜像>
```

再重新安装 gr-glidelink，模块的两个块就出现在 GRC 中。`python glidelink.py status <板子地址>` 显示板子的开机镜像和各槽位的模块。

## 1. 模块的端口

```verilog
module my_gain (
  input             clk,
  input             rstn,
  input             flush,                  // 流开始时外壳清空槽位：只清数据通路，寄存器保留

  // 寄存器（module.yaml 中声明，寄存器文件由脚本生成）
  input             enable,                 // CONTROL[0]
  input             soft_reset,             // CONTROL[1]，写 1 时一个周期的脉冲
  input     [15:0]  gain,                   // GAIN

  input             s_axis_tvalid,
  output            s_axis_tready,
  input     [31:0]  s_axis_tdata,           // sc16：{Q[31:16], I[15:0]}
  input     [71:0]  s_axis_tuser,           // 包的第一拍：{标志[7:0], 时间戳[63:0]}
  input             s_axis_tlast,

  output            m_axis_tvalid,
  input             m_axis_tready,
  output    [31:0]  m_axis_tdata,
  output    [71:0]  m_axis_tuser,
  output            m_axis_tlast
);
```

`python hw/scripts/gen_module.py ports <id>` 按 `module.yaml` 打印模块应有的端口表，可以直接复制进 RTL。

寄存器与端口的对应：

| 寄存器表中的写法 | 模块端口 |
|---|---|
| 读写寄存器 `NAME`（默认） | `input [W-1:0] name`：写入的值，复位后为 `default` |
| 读写位域 | `input [W-1:0] <位域名>` |
| 位域 `access: pulse` | `input <位域名>`：每次写 1 时一个周期的脉冲，读回 0 |
| `strobe: true` | 另加 `input name_wr`：每次写一个周期，`name` 同时给出数据 |
| `access: wo` | `input [W-1:0] name` 与 `input name_wr`，读回 0 |
| `readback: true` | 另加 `output [W-1:0] name_rd`：读这个寄存器时返回它，不返回写入的值 |
| `access: ro` | `output [W-1:0] name`：模块给出的值；写了常量 `value`（可以用模块参数，如 `TAPS`）时没有端口 |

端口名是寄存器名的小写，位域用位域名。地址从 0x008 起按顺序每个占 4 字节，0x000 / 0x004 固定为 ID 与 VERSION（取自 `id_value`、`version`）；
个别寄存器要固定地址时写 `offset`。读写都是单周期，模块不用处理总线握手。

## 2. module.yaml

以 NCO 为例（`hw/modules/nco/module.yaml`）：

```yaml
id: nco
name: NCO mixer
rtl: glidelink_nco.v
top: glidelink_nco
model: model.py
id_value: 0x4E434F31          # "NCO1"，ID 寄存器的值，PL 块靠它找槽位
version: 1.0.0
registers:
  - name: CONTROL
    fields:
      - {name: enable, bits: 0, doc: "1 = mix, 0 = pass unchanged"}
      - {name: soft_reset, bits: 1, access: pulse}
  - {name: STATUS, access: ro, fields: [{name: enabled, bits: 0}]}
  - {name: FREQ, doc: "phase increment per sample = f / fs * 2^32"}
  - {name: PHASE, strobe: true, readback: true}
block:
  doc: Frequency shift by freq.
  params:
    - {name: samp_rate, label: Sample rate, type: real, default: 1.0e+6, grc_default: samp_rate}
    - {name: freq, label: Frequency shift (Hz), type: real, default: 0.0,
       write: {FREQ: "freq / samp_rate * 2**32"}}
    - {name: phase, label: Start phase (turns), type: real, default: 0.0, write: {PHASE: "phase * 2**32"}}
  start: {CONTROL: 1}
```

| 键 | 含义 |
|---|---|
| `parameters` | RTL 参数及默认值；镜像文件中可按槽位覆盖 |
| `uses` | 用到的源码库目录（`hw/modules` 下，如 `phy_common`、`uhd_rfnoc`） |
| `ip` | Xilinx IP（`.xci`） |
| `bus: module` | 模块自己实现 AXI4-Lite（例如寄存器访问要多个周期的第三方核：`fft` 的包装要经 RFNoC 的 CtrlPort 读写核内寄存器）；这时不生成寄存器文件，寄存器表只给软件用，每项写 `offset` |
| `block` | GNU Radio 块，见下 |
| `exact: false` | 参考模型不是逐比特的（如 FFT 用浮点），软件块说明中不写"逐比特一致" |

`block.params` 每一项是 GRC 中的一个参数，PL 块与软件块相同：

| 键 | 含义 |
|---|---|
| `name`、`label`、`type`、`default` | `type`：`real`、`int`、`bool`、`string`、`enum`、`int_vector`、`real_vector`；`grc_default` 是 GRC 中的默认表达式（如变量名 `samp_rate`） |
| `options` | `enum` 的选项：`[[值, 显示名, 寄存器值], ...]` |
| `check` | 必须成立的条件，如 `"8 <= size <= 4096"` |
| `write` | 参数设定时写的寄存器：`{寄存器: 表达式}` 或 `[[寄存器, 表达式], ...]`；表达式给出列表时逐个写同一寄存器；`[[A, B], 表达式]` 对列表中每个二元组依次写 A、B |
| `doc` | 一句说明，进入 GRC 的块说明 |

表达式是 Python，可用各参数（`enum` 取寄存器值）、`read('寄存器')`、`log2(n)`（必须是 2 的幂）、`pad(列表, n)`、`round`、`min`、`max`、
`math` 与模块自己的 `model`（如 FFT 的 `model.default_scaling(...)`）；结果取整并截成 32 位。块启动时按顺序写所有参数，再写 `start`；运行中改一个参数，
重写所有用到它的项（例如 NCO 的 `samp_rate` 变了，FREQ 随之重写）。

## 3. 参考模型

`model.py` 中的 `Model` 类继承 `module_desc.RegisterModel`，在寄存器层面模仿模块：寄存器按名字存放，`on_write` / `on_read` 处理写入的副作用和
由模块给出的读数，`process(words)` 处理一段样点（`uint32` 的 sc16 字），状态留在对象里，输出个数可以和输入不同。

```python
class Model(module_desc.RegisterModel):
    def __init__(self, params=None):
        super().__init__(module_desc.load("nco", os.path.dirname(HERE)), params)
        self.phase = 0

    def on_write(self, name, value):
        if name == "PHASE" or (name == "CONTROL" and value & 2):
            self.phase = self.regs["PHASE"]

    def on_read(self, name):
        return self.phase if name == "PHASE" else None

    def process(self, words):
        out, self.phase = process(words, self.regs["FREQ"], self.phase, bool(self.field("CONTROL", "enable")))
        return out
```

软件块与 PL 块用同一段"参数 → 寄存器"的换算：软件块把寄存器写给 `Model`，PL 块写给板上的槽位。所以软件块就是 PL 模块在电脑上的替身，
流程图里把一个换成另一个（PL 块前后接主机端口源 / 汇或射频块），输出应当相同（`sw/tests/gr_proxy_swap.py`）。

## 4. 命令

| 命令 | 做什么 |
|---|---|
| `new <id> [--name 名字]` | 建 `hw/modules/<id>/`：`module.yaml`（寄存器 CONTROL.enable / soft_reset，ID 值自动选一个不重复的）、`glidelink_<id>.v`（一级流水的直通，端口表按 yaml 生成）、`model.py`（直通的 `Model`）。不改任何东西就能通过 `test`、能构建 |
| `test <id> [--case K]` | 对 `module.yaml` 中 `tests` 的每一项（块参数，或寄存器名加原始值）：按与 GNU Radio 块相同的"参数 → 寄存器"换算写寄存器，送 6000 个随机 sc16 样点（满幅噪声、单音、小信号、极值，随机长度的包），测试平台随机插入间隙与反压，输出与 `Model` 逐拍比较（`tlast`、`tuser` 随样点），最后读回全部可读寄存器与 `Model.read` 比较。输出个数与输入不同的模块（如 FFT）在输入后补一段把模块里留着的数据推出来，比较全部应出的输出，模型不逐比特时允许 `tolerance` LSB；`test_input_scale` 缩小激励幅度。没有参考模型时只检查能仿真、有输出。向量在 `hw/modules/<id>/build/test<K>/`。需要 Windows 上的 Vivado（xsim） |
| `build <镜像>` 或 `build <id> ... --name <镜像>` | 镜像文件 `hw/images/<镜像>.yaml`，或直接列模块（放在槽位 1、2……，槽位 0 是外壳的直通，写成 `hw/images/<镜像>.yaml` 留着下次用）；跑 Vivado（约一小时，打印各阶段），产物与时序余量：`hw/build/<镜像>/glidelink_<镜像>.bit`、`.hwh`、`image.json` |
| `deploy <板子> [<镜像>]` | 不写镜像时用最近构建的。拷到板子开机镜像所在目录（设备树叠加与外壳无关，沿用板上现有的），改 `/etc/default/glidelink-bridge`，重启，等桥接服务把镜像加载好，逐个槽位读 ID 与 `image.json` 核对。`--no-reboot` 只设开机镜像 |
| `status <板子>` | 开机镜像与各槽位的模块（按 ID 认出 `hw/modules` 中的模块） |

本机的工具与板子的登录在环境变量或仓库根目录的 `glidelink.local.yaml`（不进 git）中：`VIVADO`（vivado 可执行文件）、`ADI_HDL_DIR`（编好库的 ADI HDL，见 `hw/README.md`）、
`GLIDELINK_SSH_KEY`、`GLIDELINK_SSH_USER`（默认 root）。

上板核对软件块与 PL 块：`python sw/tests/gr_module_swap.py <id> --args driver=glidelink,uri=ip:<板子地址>`（在装了 gr-glidelink 的 Python 中运行，
Windows 为 `D:\radioconda\python.exe`）。它用 `tests` 的每一项参数，把同一段信号分别送进软件块和经主机端口 1 送进 PL 块，逐样点比较。

底层的单项操作仍可单独用：`hw/library/glidelink_module/tb/run_module_sim.ps1 hw/modules/<id> -Vectors <目录>`（按自己的 `regs.hex`、`in.hex`、`out.hex`、
`reads.hex` 仿真），`GLIDELINK_IMAGE=<镜像>` 直接跑 Vivado（`hw/README.md`），手动换镜像见用户指南第 4 节。

## 5. 例子：增益加直流偏置

目标：I、Q 各乘一个增益再加一个偏置，饱和到 16 位；GRC 里三个参数（增益、I 偏置、Q 偏置）运行中可调。完整的结果在 `hw/modules/gain_offset/`。

1. 建骨架，先确认它本身能通过：

   ```bash
   python glidelink.py new gain_offset --name "Gain and offset"
   python glidelink.py test gain_offset
   ```

2. `module.yaml`：加三个寄存器，块参数与换算，测试用例。

   ```yaml
   registers:
     - name: CONTROL
       fields:
         - {name: enable, bits: 0}
         - {name: soft_reset, bits: 1, access: pulse}
     - {name: GAIN, width: 16, signed: true, default: 16384, doc: "gain, 1.0 = 16384"}
     - {name: OFFSET_I, width: 16, signed: true}
     - {name: OFFSET_Q, width: 16, signed: true}
   block:
     params:
       - {name: gain, label: Gain, type: real, default: 1.0, check: "-2 <= gain < 2", write: {GAIN: "gain * 16384"}}
       - {name: offset_i, label: Offset I, type: real, default: 0.0, write: {OFFSET_I: "offset_i * 32768"}}
       - {name: offset_q, label: Offset Q, type: real, default: 0.0, write: {OFFSET_Q: "offset_q * 32768"}}
     start: {CONTROL: 1}
   tests:
     - {}
     - {gain: 1.7, offset_i: 0.25, offset_q: -0.5}
     - {gain: -2.0, offset_i: -1.0, offset_q: 0.999}
   ```

   `python hw/scripts/gen_module.py ports gain_offset` 打印新的端口表（多了 `gain`、`offset_i`、`offset_q` 三个输入），复制进 RTL。

3. RTL（`glidelink_gain_offset.v`）：第一级算乘积，第二级舍入、加偏置、饱和，两级一起受反压控制，`tuser` / `tlast` 随样点走。没有一行总线代码。

4. 参考模型（`model.py`）中的 `process`：

   ```python
   s16 = lambda v: (v & 0xFFFF) - ((v & 0x8000) << 1)
   g = s16(self.regs["GAIN"])
   i, q = unpack(words)
   return pack(sat16(((i * g + (1 << 13)) >> 14) + s16(self.regs["OFFSET_I"])),
               sat16(((q * g + (1 << 13)) >> 14) + s16(self.regs["OFFSET_Q"])))
   ```

5. 仿真、构建、部署：

   ```bash
   python glidelink.py test gain_offset                         # 4 组，各 6000 个样点逐拍一致，寄存器读回一致
   python glidelink.py build gain_offset nco --name tutorial    # 槽位 1 增益偏置，槽位 2 NCO
   python glidelink.py deploy 192.168.3.1 tutorial              # 重启后核对槽位
   ```

6. 重新安装 gr-glidelink，GRC 的 GlideLink / FPGA modules 中出现 GlideLink Gain and offset (PL) 与 (software)。
   上板核对：`python sw/tests/gr_module_swap.py gain_offset`。示例 `sw/gr-glidelink/examples/pl_gain_offset.grc`：射频 → NCO → 增益偏置 → 主机端口 1，
   拖动滑块时 I / Q 的直流台阶和 0 Hz 处的谱线随之变化。

   ![示例运行中：I、Q 分别停在偏置 0.3、-0.2，0 Hz 处是偏置的谱线](img/pl_gain_offset.png)

   2026-11-01 在接收板上：`test` 4 组仿真逐拍一致；`build` 13 分钟，时序满足；`deploy` 核对槽位通过；`gr_module_swap.py gain_offset` 4 组各 131072 个样点与软件块完全相同。

## 6. 安装 GNU Radio 块

新模块或改了 `module.yaml` 之后重新运行 gr-glidelink 的安装（Windows：`D:\radioconda\python.exe sw\gr-glidelink\install_conda.py`；
Linux：CMake 安装），模块的两个块出现在 GRC 的 GlideLink / FPGA modules 分类中。
