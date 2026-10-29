# GlideLink SDR

基于 PYNQ-ZU + AD9361 FMC 子卡的通信算法原型验证平台：板子作为 SoapySDR 设备接入 GNU Radio，先用软件验证算法，
再把算法模块逐个卸载到 PL（参考 RFNoC 的思路，用户可加入自己的 FPGA 模块），最终脱离 PC 运行。

当前状态：设计阶段，见 [`docs/design.md`](docs/design.md)。

本项目在竞赛作品 [GlideLink](https://github.com/Vimcovan/glidelink-fpga) 的基础上发展而来。
