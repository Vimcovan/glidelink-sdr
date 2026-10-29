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
| `build_wilc.sh` | 编译板载 WiFi（WILC3000）驱动 `wilc-sdio.ko` |

安装到 SD 卡：`image.ub` 放到启动分区（原文件另存为 `image.ub.pynq-6.6.10`），模块放到根文件系统的
`/lib/modules/6.6.0-adi-glidelink/`，zocl 与 wilc-sdio 放到其中的 `updates/` 并运行 `depmod`。

## WiFi 驱动

主线 6.6 的 wilc1000 驱动不支持 WILC3000，使用 Microchip 维护的版本：`linux4microchip/linux` 的 `linux-6.6-mchp` 分支，
提交 `c5ee3b5209256990ae272d97b69103e3289f2190`，目录 `drivers/net/wireless/microchip/wilc1000/`
（下载后可用 `git hash-object` 对照该提交的 `git ls-tree` 校验）。`build_wilc.sh` 把该目录复制出来，加两处适配后编译：

- `wilc/compat.h`：定义 `struct ieee80211_radiotap_header_fixed`。该结构是 6.6 稳定版后期才加入的，`adi-6.6.0` 没有；
- `wilc/0001-sdio-allow-host-without-runtime-pm.patch`：`adi-6.6.0` 的 SD 主机驱动没有启用运行时电源管理，
  `pm_runtime_get_sync()` 返回 `-EACCES`，驱动把它当作错误导致探测失败（`-EIO`）。此时主机一直上电，忽略该返回值即可。

固件沿用板上的 `/lib/firmware/mchp/wilc3000_wifi_firmware.bin`；`/etc/modules` 中已有 `wilc-sdio`，开机自动加载。
没有该驱动时 wlan0 不出现，`network.target` 要等约 90 s 超时，开机明显变慢。
