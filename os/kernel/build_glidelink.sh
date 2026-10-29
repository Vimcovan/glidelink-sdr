#!/bin/bash
# Build the GlideLink kernel modules (os/kernel/glidelink) against the ADI kernel tree.
# Usage: build_glidelink.sh [kernel dir] [output dir]
set -e
KDIR=${1:-/root/sdr/linux}
OUT=${2:-/root/sdr/glidelink}
HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$HERE"/glidelink/*.c "$HERE"/glidelink/Makefile "$OUT"/
make -C "$KDIR" M="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules
ls -l "$OUT"/*.ko
