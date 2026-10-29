cd /root/sdr/xrt/src/runtime_src/core/edge/drm/zocl
make -C /root/sdr/linux M=/root/sdr/xrt/src/runtime_src/core/edge/drm/zocl ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j20 \
  cflags_zocl='-DXRT_BRANCH=\"2024.1\" -DXRT_HASH=\"202410.2.17.319\" -DXRT_HASH_DATE=\"\" -DXRT_DATE=\"\" -DXRT_MODIFIED_FILES=\"\"' modules > /root/sdr/zocl.log 2>&1
grep -E "error|Error" /root/sdr/zocl.log | head -20
ls -la zocl.ko && modinfo zocl.ko | grep -E "vermagic|^version:"
