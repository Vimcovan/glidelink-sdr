# 电脑端环境

Windows 11 上的两部分：WSL 2 中的 Ubuntu 24.04（GNU Radio、SoapySDR、GQRX、图形桌面）与 Windows 上的 MATLAB。
两块板各用一根 USB 线直接接电脑，地址见 [`user_guide.md`](user_guide.md) 第 1 节。

## 1. WSL

### 1.1 配置

`%UserProfile%\.wslconfig`：

```ini
[wsl2]
networkingMode=mirrored    # WSL 与 Windows 共用网口：板子的 192.168.3.1 / 4.1 在 WSL 中直接可达
dnsTunneling=true
autoProxy=true             # Windows 的代理设置同步进 WSL（http_proxy 等环境变量）
```

WSL 中 `/etc/wsl.conf` 打开 systemd：

```ini
[boot]
systemd=true
```

`autoProxy` 会把 Windows 的代理（如 127.0.0.1:7897）写进 WSL 的环境变量。代理在 WSL 中连不上时 apt 会超时，
单次安装可绕过：

```bash
sudo env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    apt-get -o Acquire::http::Proxy=false install <包>
```

板子的 USB 网卡用巨型帧（MTU 9000，`os/board/install_net.sh`），Windows 自动把这两块网卡的 MTU 设为 9000，WSL 镜像过来的网卡也显示 9000，
但 Windows 与 WSL 之间不传大于 1500 字节的帧。不改的话 WSL 中的程序连板子会卡住（iiod 连不上、采样流断开）。
每次 WSL 启动或板子重新接上后，在 WSL 中把连板子的网卡设为 1500：

```bash
sudo bash sw/pc/wsl-board-mtu
```

脚本找出地址在 192.168.3.x / 192.168.4.x 的网卡并设为 MTU 1500。也可以写进 `/etc/wsl.conf` 的 `[boot]` 段
（`command = bash /mnt/d/ClaudePrj/glidelink-sdr/sw/pc/wsl-board-mtu`），但只对 WSL 启动时已接上的板子有效。
这时 WSL 中的程序按 1500 字节的帧走：接收 50 MSPS，发射约 45 MSPS；Windows 中的程序收发各 50 MSPS（`known_issues.md` 1.3）。

WSL 的网络在高速时还会丢少量 UDP 包；收发 50 MSPS 用第 3 节的 Windows 原生环境。

### 1.2 软件包

```bash
sudo apt install gnuradio gnuradio-dev gqrx-sdr gr-osmosdr \
    python3-soapysdr soapysdr-tools libsoapysdr-dev libiio-dev libiio-utils cmake build-essential
```

已用版本：GNU Radio 3.10.9.2、SoapySDR 0.8.1、libiio 0.25、GQRX 2.17.4（Ubuntu 24.04 的包）。

### 1.3 GlideLink 的 Soapy 模块与 GNU Radio 模块

```bash
cd sw/soapy-glidelink && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j8 && sudo cmake --install build
SoapySDRUtil --probe="driver=glidelink,uri=ip:192.168.3.1"

cd sw/gr-glidelink && cmake -S . -B build && cmake --build build -j8 && sudo cmake --install build
python3 -c "from gnuradio import glidelink"
```

Soapy 模块装到 `/usr/local/lib/SoapySDR/modules0.8/`，GNU Radio 块装到 `/usr/local/share/gnuradio/grc/blocks/`（GRC 默认能找到），
Python 包为 `gnuradio.glidelink`。

### 1.4 图形界面

单个图形程序（`gnuradio-companion`、`gqrx`、Python 的 Qt 界面）直接在 WSL 中启动即可，由 WSLg 显示为 Windows 窗口。

完整的 Linux 桌面（XFCE）用 `sw/pc/xfce-desktop`：嵌套的 X 服务器（Xephyr）作为一个 Windows 窗口，里面是 XFCE 会话，不需要登录。

```bash
sudo apt install xfce4 xfce4-terminal xserver-xephyr dbus-x11 x11-utils xterm imagemagick xdotool
sudo install -m 755 sw/pc/xfce-desktop /usr/local/bin/
```

在 Windows 中启动（参数为窗口大小，默认 1600x900；关闭窗口即结束会话）：

```bash
wsl -u root xfce-desktop 1920x1080
```

几点说明（脚本中已处理）：

- GTK 程序只要运行时目录里有 WSLg 的 `wayland-0` 就会连 Wayland，即使没有设 `WAYLAND_DISPLAY`；桌面中设 `GDK_BACKEND=x11`，
  Qt 设 `QT_QPA_PLATFORM=xcb`，程序才显示在桌面里。
- `/tmp/.X11-unix` 是 WSLg 的只读挂载，Xephyr 只在抽象套接字上监听；检查显示是否就绪要用 `unix:1`，`:1` 在找不到套接字文件时
  改走 TCP，在 mirrored 网络下会挂起。
- GNU Radio Companion 运行流程图时要用终端程序（`x-terminal-emulator`），装 `xterm` 即可。

截图（例如给别人看界面）：`DISPLAY=:1 import -window root shot.png`。

## 2. MATLAB

| 组件 | 用途 |
|---|---|
| MATLAB R2025b | `sw/matlab` 的包与示例（`tcpclient` 为 MATLAB 自带） |
| Communications Toolbox | 各通信体制示例 |
| WLAN Toolbox | 802.11 示例与官方 WLAN 例程 |
| Phased Array System Toolbox | FMCW 雷达例程 |
| Communications Toolbox Support Package for USRP Radio、for Analog Devices ADALM-Pluto Radio | 官方例程的文件（`glidelink.officialExample` 从中取出）；Pluto 支持包也可直接连板子 |

支持包在 MATLAB 主页 → 附加功能 → 获取硬件支持包中安装（需要 MathWorks 账户），安装时的硬件设置步骤可以跳过。

## 3. Windows 原生环境（收发 50 MSPS）

经板子 USB 网口的 50 MSPS 采样流要在 Windows 原生程序中跑（WSL 的网络传不了巨型帧，高速时还会丢包，`known_issues.md` 1.3）。

1. 安装 [radioconda](https://github.com/radioconda/radioconda-installer/releases)（Windows 版 GNU Radio、SoapySDR、libiio）。
   例：只给当前用户装到 `D:\radioconda`，不改系统 PATH：

   ```bat
   radioconda-2025.03.14-Windows-x86_64.exe /S /InstallationType=JustMe /RegisterPython=0 /AddToPath=0 /D=D:\radioconda
   ```

2. 放入 GlideLink 的 Soapy 模块：`glidelinkSupport.dll` 复制到 `D:\radioconda\Library\lib\SoapySDR\modules0.8`
   （自己编译见 `sw/soapy-glidelink/README.md` 的 Windows 一节）。
3. 在 radioconda 的命令行（开始菜单 "radioconda Prompt"）中：

   ```bat
   SoapySDRUtil --probe="driver=glidelink,uri=ip:192.168.4.1"
   SoapySDRUtil --args="driver=glidelink,uri=ip:192.168.4.1" --rate=50e6 --direction=RX
   ```

网络不用设置：板子声明巨型帧后 Windows 自动把这两块网卡的 MTU 设为 9000，Soapy 模块在 Windows 上默认用 8000 字节的 UDP 包。

