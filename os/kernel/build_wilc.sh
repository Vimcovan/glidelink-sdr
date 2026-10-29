#!/bin/bash
# Build wilc-sdio.ko (WILC3000 WiFi on PYNQ-ZU) for the ADI kernel.
# Source: linux4microchip/linux, branch linux-6.6-mchp, commit
# c5ee3b5209256990ae272d97b69103e3289f2190, drivers/net/wireless/microchip/wilc1000/
# Usage: build_wilc.sh <wilc1000 source dir>
set -e
SRC=${1:?wilc1000 source dir}
KDIR=/root/sdr/linux
OUT=/root/sdr/wilc/src16
HERE=$(cd "$(dirname "$0")" && pwd)

rm -rf "$OUT" && mkdir -p "$OUT"
cp "$SRC"/* "$OUT"/
cp "$HERE"/wilc/compat.h "$OUT"/
for p in "$HERE"/wilc/*.patch; do patch -d "$OUT" -p1 < "$p"; done
make -C "$KDIR" M="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
	CONFIG_WILC=m CONFIG_WILC_SDIO=m \
	KCFLAGS="-include $OUT/compat.h" -j8 modules
modinfo "$OUT"/wilc-sdio.ko | grep -E "vermagic|firmware"
