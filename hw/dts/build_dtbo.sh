#!/bin/bash
# Build fmcomms2_pynqzu.dtbo with the ADI kernel tree's dtc and dt-bindings.
# ADI's adi-fmcomms2.dtsi is used with two changes: its root node "/ {" becomes
# "&{/} {" (in an overlay, a plain root node is not merged), and its /clocks
# node gets compatible "simple-pm-bus" so that the 40 MHz fixed-clock under it
# gets a device. The compatible has to go into that same fragment: an overlay
# with two fragments that both add /clocks is rejected.
# Usage: build_dtbo.sh [kernel dir] [output dir]
set -e
KDIR=${1:-/root/sdr/linux}
OUT=${2:-$(pwd)}
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sed -e 's|^/ {$|\&{/} {|' \
	-e 's|^\tclocks {$|\tclocks {\n\t\tcompatible = "simple-pm-bus";|' \
	"$KDIR/arch/arm64/boot/dts/xilinx/adi-fmcomms2.dtsi" > "$TMP/adi-fmcomms2.dtsi"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$TMP" -I "$KDIR/include" \
	"$HERE/fmcomms2_pynqzu.dtso" -o "$TMP/fmcomms2_pynqzu.pp.dts"
"$KDIR/scripts/dtc/dtc" -@ -I dts -O dtb -o "$OUT/fmcomms2_pynqzu.dtbo" "$TMP/fmcomms2_pynqzu.pp.dts"
echo "$OUT/fmcomms2_pynqzu.dtbo"
