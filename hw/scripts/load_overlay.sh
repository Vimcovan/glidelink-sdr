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
