#!/bin/bash
# Load a PL design and its device tree overlay on the board (run as root).
# Usage: load_overlay.sh <design.bit> <design.dtbo>
#
# The bitstream is programmed through PYNQ from a copy with no .dtbo next to
# it, and the overlay is then written into configfs directly: letting PYNQ
# insert the dtbo (Overlay(bit, dtbo=...)) fails with "multiple fragments add
# node /clocks" for fmcomms2_pynqzu.dtbo, while the same file applies when
# written by hand.
#
# An applied overlay cannot be removed cleanly (the kernel warns that removing
# it leaks memory), so loading again needs a reboot.
set -e
BIT=$(readlink -f "$1")
DTBO=$(readlink -f "$2")
[ -f "$BIT" ] && [ -f "$DTBO" ] || { echo "usage: $0 <design.bit> <design.dtbo>" >&2; exit 1; }
HWH=${BIT%.bit}.hwh
NAME=$(basename "$DTBO" .dtbo)
OVL=/sys/kernel/config/device-tree/overlays

if [ -n "$(ls -A $OVL)" ]; then
	echo "overlays already applied ($(ls $OVL | tr '\n' ' ')); reboot first" >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp "$BIT" "$TMP/pl.bit"
[ -f "$HWH" ] && cp "$HWH" "$TMP/pl.hwh"
bash -lc "source /etc/profile.d/pynq_venv.sh && python3 -c 'from pynq import Overlay; Overlay(\"$TMP/pl.bit\")'"

mkdir "$OVL/$NAME"
cat "$DTBO" > "$OVL/$NAME/dtbo"
STATUS=$(cat "$OVL/$NAME/status")
echo "$NAME: $STATUS"
[ "$STATUS" = applied ]

# iiod builds its device list when it starts (at boot, before the overlay):
# restart it so that network clients see the new devices, once the AD9361
# drivers have probed (a few seconds after the overlay is applied)
if systemctl is-active -q iiod; then
	for i in $(seq 1 30); do
		names=$(cat /sys/bus/iio/devices/iio:device*/name 2>/dev/null)
		echo "$names" | grep -qx ad9361-phy && echo "$names" | grep -qx cf-ad9361-lpc &&
			echo "$names" | grep -qx cf-ad9361-dds-core-lpc && break
		sleep 1
	done
	systemctl restart iiod
	echo "iiod restarted"
fi

# The RF TX data always comes from the shell (through axi_ad9361's DMA data
# input), never from its DDS: select it on the TX channels (DAC channel register
# 0x18, value 2). The driver selects it only while a host TX buffer is open, so a
# module streaming to the RF on its own would otherwise send the DDS tone.
for ch in 0x418 0x458; do
	iio_reg cf-ad9361-dds-core-lpc $ch 2 >/dev/null
done
