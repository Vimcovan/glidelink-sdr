#!/bin/bash
# Installs the GlideLink bridge service on a board (run there, from sw/bridge copied to
# /home/xilinx/claude/sdr/bridge, with sw/offline next to it for the images and load_overlay.sh):
#   bash install.sh <image.bit> [--enable]
# The image is the one loaded at boot (e.g. ../offline/ovl/glidelink_tx.bit on the TX board).
# --enable: the bridge starts at boot; the offline services (glidelinkd@*) are disabled (the two
# cannot run together; switch with systemctl start glidelinkd@tx|rx or glidelink-bridge).
set -e
image=$(readlink -f "$1")
[ -f "$image" ] || { echo "usage: install.sh <image.bit> [--enable]"; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
install -m 644 "$here/glidelink-bridge.service" /etc/systemd/system/
echo "GLIDELINK_IMAGE=$image" > /etc/default/glidelink-bridge
systemctl daemon-reload
if [ "$2" = "--enable" ]; then
	systemctl disable glidelinkd@tx.service glidelinkd@rx.service 2>/dev/null || true
	systemctl enable glidelink-bridge.service
fi
echo "installed: glidelink-bridge.service, image $image"
