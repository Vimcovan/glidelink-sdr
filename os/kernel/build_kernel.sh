set -e
cd /root/sdr/linux
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
./scripts/config -e AD9361 -e CF_AXI_ADC -e CF_AXI_DDS -e AXI_DMAC
make -s olddefconfig
grep -E "^CONFIG_(AD9361|CF_AXI_ADC|CF_AXI_DDS|AXI_DMAC)=" .config
echo "release: $(make -s kernelrelease)"
time make -j20 Image modules > /root/sdr/build.log 2>&1 || { tail -30 /root/sdr/build.log; exit 1; }
rm -rf /root/sdr/modroot && make -s INSTALL_MOD_PATH=/root/sdr/modroot modules_install
ls /root/sdr/modroot/lib/modules; ls -la arch/arm64/boot/Image
