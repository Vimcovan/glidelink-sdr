#!/bin/bash
# Board network setup for fast sample streams over the USB cable (run on the board as root):
#  - the USB gadget's network function: NCM instead of RNDIS (PYNQ /usr/local/bin/usbgadget,
#    original kept as usbgadget.rndis). NCM puts many Ethernet frames in one USB transfer, so
#    the board takes far fewer USB interrupts (RNDIS: one transfer per frame).
#  - TCP buffer limits (/etc/sysctl.d/90-glidelink-net.conf): the default 208 KB receive limit
#    caps PC -> board TCP at about 63 MB/s over NCM.
# Takes effect at the next boot (or: systemctl restart usbgadget; sysctl --system).
#
#     bash install_net.sh            install
#     bash install_net.sh --undo     back to RNDIS and the default limits
set -e
G=/usr/local/bin/usbgadget
CONF=/etc/sysctl.d/90-glidelink-net.conf

if [ "$1" = "--undo" ]; then
    [ -e $G.rndis ] && cp $G.rndis $G
    rm -f $CONF
    echo "RNDIS and default TCP limits restored (next boot)"
    exit 0
fi

[ -e $G.rndis ] || cp $G $G.rndis
cp $G.rndis $G
sed -i \
    -e 's|^  mkdir -p functions/rndis.usb0  # network$|  mkdir -p functions/ncm.usb0  # network (NCM)|' \
    -e '/functions\/rndis.usb0\/os_desc\/interface.rndis/d' \
    -e 's|configs/c.1/rndis.usB0 -a -e functions/rndis.usb0|configs/c.1/ncm.usb0 -a -e functions/ncm.usb0|' \
    -e 's|ln -s functions/rndis.usb0 configs/c.1/|ln -s functions/ncm.usb0 configs/c.1/|' \
    $G
if grep -q rndis $G; then
    echo "usbgadget still mentions rndis: the PYNQ script differs from the expected one" >&2
    cp $G.rndis $G
    exit 1
fi

cat > $CONF <<'EOF'
# GlideLink: TCP buffers for 200 MB/s sample streams over the USB NCM link
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
EOF
echo "NCM gadget and TCP limits installed (next boot)"
