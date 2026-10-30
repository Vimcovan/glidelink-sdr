# gr-glidelink

GlideLink 平台的 GNU Radio 3.10 OOT 模块（纯 Python 块）。射频收发仍用 GNU Radio 自带的 Soapy 源 / 汇
（`gr-soapy`，驱动 `glidelink`，PC 上设备参数加 `uri=ip:<板子地址>`），本模块补充 PL 侧的连接与控制：

| 块 | 作用 |
|---|---|
| GlideLink Control | 设流交换路由；按顺序写设置（AD9361 驱动参数、`gain_control_mode`、`initialize`）；写寄存器；按间隔回读一组寄存器 / 设置，从 `status` 消息口发出。运行中改设置字典里用到的变量时，只写变化的项，字典含 `'initialize': True` 时随后重新初始化 AD9361。`cmd` 消息口收同样键的字典 |
| GlideLink Host Source / Sink | 主机端口 1：槽位中模块的数据。复数（sc16 / 32768）或整数（原样 32 位字）；带包头时源打 `rx_time` / `rx_eob` 标签，汇按 `tx_time` / `tx_eob` 标签定时发送、结束突发 |
| GlideLink NCO / FIR (software) | 调用模块的参考模型（`hw/modules/<id>/model.py`），与 PL 中的模块逐比特一致：软件原型阶段使用 |
| GlideLink NCO / FIR (PL) | 代理块：按 `module.yaml` 中的寄存器名写槽位寄存器（NCO 在槽位 1，FIR 在槽位 2），不传数据；数据经控制块设的路由进出槽位 |

控制块自己开一个 Soapy 设备实例，只做控制，不碰射频流；Soapy 模块的构造不改硬件状态，几个实例可以同时存在。

路由名：汇 `rf_tx`、`host0_rx`、`host1_rx`、`slot0_in`、`slot1_in`、`slot2_in`；源 `rf_rx`、`host0_tx`、`host1_tx`、`slot0_out`、`slot1_out`、`slot2_out`、`none`（外壳 1.4.0：槽位 0 直通、1 NCO、2 FIR）。
例：`{'slot0_in': 'rf_rx', 'host0_rx': 'slot0_out'}` 把槽位 0 接在射频接收与 Soapy 源之间。

## 安装（WSL / Ubuntu，GNU Radio 3.10）

```bash
sudo apt install gnuradio-dev python3-soapysdr
cmake -S . -B build && cmake --build build && sudo cmake --install build
```

块装到 `/usr/local/share/gnuradio/grc/blocks`，GRC 默认能找到。Soapy 模块（`sw/soapy-glidelink`）需在同一台机器上装好。

## 示例

`examples/agc_fast_attack.grc`：快速 AGC，用滑块改锁定电平（`adi,agc-inner-thresh-high`），每次改动写入驱动参数并重新初始化
AD9361，界面上显示寄存器 0x101 的回读、频谱和接收幅度。参数 `uri` 选板子（默认 `ip:192.168.3.1`）。

自动化的验收见 `sw/tests/gr_agc_init.py`（第 2 阶段）与 `sw/tests/gr_proxy_swap.py`（软件块换成代理块后输出不变）。

Python 块在流程图运行期间要保持引用（存到变量里）；在 `connect()` 里直接构造会被回收，流程图启动时崩溃。
