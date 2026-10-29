# 内核（路线 K2）

PYNQ-ZU 镜像的内核换成 ADI Linux `adi-6.6.0`，以 PYNQ 的内核配置（`config-6.6.10-pynq`）为基础，另外打开
AD9361、AXI ADC / DDS、AXI DMAC 与 IIO DMA 缓冲（均编进内核），以及 lima（模块）。结果配置为 `config-6.6.0-adi-glidelink`，
内核版本名 `6.6.0-adi-glidelink`。

在 WSL（Ubuntu 24.04，aarch64-linux-gnu-gcc 13.3）中交叉编译：

| 脚本 | 作用 |
|---|---|
| `build_kernel.sh` | 在 `/root/sdr/linux`（ADI `adi-6.6.0` 源码）中配置并编译 Image 与模块，安装到 `/root/sdr/modroot` |
| `make_image_ub.sh` | 用 Image 与 PYNQ 原 `image.ub` 中的设备树打包新的 `image.ub`（FIT：kernel + fdt，加载地址 0x80000，与 PYNQ 相同） |
| `build_zocl.sh` | 针对新内核编译 XRT `202410.2.17.319` 的 zocl（PYNQ 的 DMA 缓冲分配依赖它） |

安装到 SD 卡：`image.ub` 放到启动分区（原文件另存为 `image.ub.pynq-6.6.10`），模块放到根文件系统的
`/lib/modules/6.6.0-adi-glidelink/`，zocl 放到其中的 `updates/` 并运行 `depmod`。

待办：板载 WiFi（WILC3000）需要 Microchip 的独立驱动，主线内核只支持 WILC1000。
