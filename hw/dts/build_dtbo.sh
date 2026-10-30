#!/bin/bash
# Build fmcomms2_pynqzu.dtbo with the ADI kernel tree's dtc and dt-bindings.
# ADI's adi-fmcomms2.dtsi is used with three changes: its root node "/ {"
# becomes "&{/} {" (in an overlay, a plain root node is not merged); its
# /clocks node gets compatible "simple-pm-bus" so that the 40 MHz clock under
# it gets a device (the compatible has to go into that same fragment: an
# overlay with two fragments that both add /clocks is rejected); and that 40 MHz
# reference becomes an "adjustable-clock" of +-200 ppm, as on the ADALM-Pluto,
# so that the AD9361 driver's xo_correction moves LOs and sample rate together
# (a fixed-clock ignores the write).
# Usage: build_dtbo.sh [kernel dir] [output dir]
set -e
KDIR=${1:-/root/sdr/linux}
OUT=${2:-$(pwd)}
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sed -e 's|^/ {$|\&{/} {|' \
	-e 's|^\tclocks {$|\tclocks {\n\t\tcompatible = "simple-pm-bus";|' \
	-e 's|compatible = "fixed-clock";|compatible = "adjustable-clock";\n\t\t\tclock-accuracy = <200000>; /* ppb */|' \
	"$KDIR/arch/arm64/boot/dts/xilinx/adi-fmcomms2.dtsi" > "$TMP/adi-fmcomms2.dtsi"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$TMP" -I "$KDIR/include" \
	"$HERE/fmcomms2_pynqzu.dtso" -o "$TMP/fmcomms2_pynqzu.pp.dts"
"$KDIR/scripts/dtc/dtc" -@ -I dts -O dtb -o "$OUT/fmcomms2_pynqzu.dtbo" "$TMP/fmcomms2_pynqzu.pp.dts"
echo "$OUT/fmcomms2_pynqzu.dtbo"
