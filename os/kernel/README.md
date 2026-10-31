# 内核（路线 K2）

PYNQ-ZU 镜像的内核换成 ADI Linux `adi-6.6.0`，以 PYNQ 的内核配置（`config-6.6.10-pynq`）为基础，另外打开
AD9361、AXI ADC / DDS、AXI DMAC 与 IIO DMA 缓冲（均编进内核），以及 lima（模块）。结果配置为 `config-6.6.0-adi-glidelink`，
内核版本名 `6.6.0-adi-glidelink`。

在 WSL（Ubuntu 24.04，aarch64-linux-gnu-gcc 13.3）中交叉编译：

| 脚本 | 作用 |
|---|---|
| `build_kernel.sh` | 在 `/root/sdr/linux`（ADI `adi-6.6.0` 源码）中配置并编译 Image 与模块，安装到 `/root/sdr/modroot` |
| `make_image_ub.sh` | 用 Image 与 PYNQ 原 `image.ub` 中的设备树打包新的 `image.ub`（FIT：kernel + fdt，加载地址 0x80000，与 PYNQ 相同）；设备树中给 USB 控制器（dwc3）加 `snps,dis-u1-entry-quirk`、`snps,dis-u2-entry-quirk`，关闭 USB 3 链路的 U1/U2（开着时电脑会不时复位 USB 链路，见 `docs/known_issues.md` 1.1），并留 8 KB 余量给 U-Boot 修改设备树 |
| `build_zocl.sh` | 针对新内核编译 XRT `202410.2.17.319` 的 zocl（PYNQ 的 DMA 缓冲分配依赖它） |
| `build_wilc.sh` | 编译板载 WiFi（WILC3000）驱动 `wilc-sdio.ko` |
| `build_glidelink.sh` | 编译 `glidelink/` 中的平台驱动：`glidelink_shell.ko`（外壳寄存器窗口作为 IIO 设备 `glidelink-shell`，libiio 经 `iio_device_reg_read/write` 访问，属性 `timestamp` 为采样计数器）；`glidelink_host.ko`（主机端口 1 的两个 DMA 作为 IIO 缓冲设备 `glidelink-host1-rx` / `-tx`，各一个 32 位通道）。装到 `updates/` 并 `depmod`，设备树叠加加入节点时自动加载 |

`build_kernel.sh` 编译前打上 `patches/` 中的补丁：

- `0001-iio-buffer-dma-cached-mmap-blocks.patch`：IIO DMA 缓冲（libiio 0.2x 使用的 mmap 块接口）在 DMA 设备不是缓存一致时
  改用可缓存的页，并在交给 DMA 前、交回 CPU 时做缓存维护。原实现用 `dma_alloc_coherent`，在非一致设备上 CPU 以不可缓存方式
  映射，读取接收块只有约 150 MB/s，RX 在约 19 MSPS 封顶。PYNQ-ZU 的启动程序没有为 HPC 端口打开 CCI 侦听，
  设备树不能标 `dma-coherent`（标了以后 axi_dmac 读到缓存中的旧描述符而停住），所以走这条路。
  内核参数 `industrialio_buffer_dma.cached_blocks=0` 恢复原行为。
- `0002-dma-axi-dmac-sg-queue-full.patch`：AXI DMAC 分散聚集模式下限制同时交给硬件的传输数。两块 AXI DMAC（版本 0x40565）
  支持硬件分散聚集，`dma-axi-dmac` 因此走该模式，而该模式下驱动提交传输时不检查硬件队列，完成中断又不看传输编号，
  按列表顺序逐个结束描述符。同时交给硬件的传输超过约 5 个时，多出的传输不执行却被报告完成：IIO 内核缓冲块数为 N（N > 5）时，
  开始传输后客户端收到 N − 5 个从未写过的块（开头为全 0，块被重复使用后为旧数据），TX 有 N − 5 个缓冲没有发出去。
  libiio 本地默认 4 块，不受影响；网络客户端经 iiod 设置块数时会碰到，例如 MathWorks ADALM-Pluto 支持包
  （`sdrrx('Pluto', RadioID='ip:…')`）开头有 3 帧全 0，随后 AGC 等处理出错，GQRX、GNU Radio 的 `ip:` 地址也一样。
  补丁做三件事：分散聚集模式下同时交给硬件的传输最多 4 个（`AXI_DMAC_SG_MAX_QUEUED`），其余描述符留在驱动队列中，
  每完成一个传输补交一个；提交前同样检查 START_TRANSFER（队列满时临时打开"队列有空位"中断等待）；完成中断按
  TRANSFER_DONE 中的传输编号结束描述符，一次中断可结束多个，已被前一次中断结束的传输不会再次结束别的描述符。
  只查 START_TRANSFER 不够：实测硬件接受了请求，排得更深的传输仍会丢失，所以以 4 个为上限。
  这样客户端可以请求任意块数，多出的块作为软件侧余量，不再丢数据。
  验证（两块板）：板上本地与经 iiod 网络读取，内核块数 4～64、块长 512～262144 个样点，无全 0 块，
  也无重复的旧数据（按 256 个样点分段比对整段数据）；`iio_readdev -u ip:… -b 11226 -s 800000` 无全 0 块；
  Pluto 支持包 `sdrrx` 读 1 MSPS、240 帧无全 0 帧；`sw/tests/ramp_loopback_iio.c` 全双工数字回环
  30.72 / 50 MSPS、内核块数 4～32，逐样点无误，TX 无欠载、无缺失缓冲。

- `0003-usb-gadget-ncm-64k-ntb.patch`：USB 设备端 NCM 网卡（`f_ncm`，板子经 USB 线连电脑的网口，`os/board/install_net.sh`）
  每次 USB 传输（NTB）的上限由 16 KB 加到约 64 KB：发送 65024 字节（NTB16 的块长字段只有 16 位），接收 65536 字节，
  每块最多 64 个以太网帧（原 32）。16 KB 时收发合计约 230 MB/s 封顶（每秒上万次传输），板上 CPU 与电脑端都不是瓶颈；
  电脑端的 NCM 驱动按板子声明的上限选择块长，不需要改动。

安装到 SD 卡：`image.ub` 放到启动分区（原文件另存为 `image.ub.pynq-6.6.10`；两块板上
`image.ub.cached-mmap-20261029` 为加入补丁 0002 之前的内核），模块放到根文件系统的
`/lib/modules/6.6.0-adi-glidelink/`，zocl 与 wilc-sdio 放到其中的 `updates/` 并运行 `depmod`。

## WiFi 驱动

主线 6.6 的 wilc1000 驱动不支持 WILC3000，使用 Microchip 维护的版本：`linux4microchip/linux` 的 `linux-6.6-mchp` 分支，
提交 `c5ee3b5209256990ae272d97b69103e3289f2190`，目录 `drivers/net/wireless/microchip/wilc1000/`
（下载后可用 `git hash-object` 对照该提交的 `git ls-tree` 校验）。`build_wilc.sh` 把该目录复制出来，加两处适配后编译：

- `wilc/compat.h`：定义 `struct ieee80211_radiotap_header_fixed`。该结构是 6.6 稳定版后期才加入的，`adi-6.6.0` 没有；
- `wilc/0001-sdio-allow-host-without-runtime-pm.patch`：`adi-6.6.0` 的 SD 主机驱动没有启用运行时电源管理，
  `pm_runtime_get_sync()` 返回 `-EACCES`，驱动把它当作错误导致探测失败（`-EIO`）。此时主机一直上电，忽略该返回值即可；
- `wilc/0002-recovery-no-hang-no-spin.patch`：修正固件恢复流程的自锁。SDIO 偶发 CRC 错误（`err(-84)`）后固件不再应答，
  连续 5 个配置包超时，`debug_thread` 置 `wait_for_recovery` 并关闭网口重启芯片。若此时正在扫描，关闭网口时
  `handle_scan_done()` 要发"中止扫描"配置包，而 `wilc_send_config_pkt()` 要等 `wait_for_recovery` 清零，
  清零又在关闭之后的重新打开里，于是恢复永远停住，WiFi 断到重启为止。`wl->close` 已置位，`wlan0-tx` 被下一个发送包唤醒后
  在 `while (!kthread_should_stop()) schedule();` 里空转占满一核；芯片若还活着，它的中断也不再被应答，
  变成 SDIO 中断风暴由 kworker 占满一核。补丁让恢复期间跳过中止扫描命令（芯片随后被重启），
  并把两处等待 `kthread_stop()` 的循环改为睡眠等待。

固件沿用板上的 `/lib/firmware/mchp/wilc3000_wifi_firmware.bin`；`/etc/modules` 中已有 `wilc-sdio`，开机自动加载。
没有该驱动时 wlan0 不出现，`network.target` 要等约 90 s 超时，开机明显变慢。
