#!/bin/bash
# Installs the offline services on a board (run there, from sw/offline copied to
# /home/xilinx/claude/sdr/offline):
#   bash install.sh tx|rx [--enable]
# glidelinkd@<board> upholds its application (jscc-<board>-app, drop-in Upholds=): the application
# starts once the daemon is ready, and when the daemon restarts (and resets the modules) the
# application is stopped (BindsTo=) and started again after it, so the encoder and decoder, which
# count their own image boundaries, never start in the middle of an image.
#   systemctl start glidelinkd@<board>     brings the board up, then the application
# Without --enable nothing starts at boot; with it, glidelinkd@<board> starts at boot and the
# competition services (which load their own overlay) are disabled.
set -e
board=$1
case "$board" in tx|rx) ;; *) echo "usage: install.sh tx|rx [--enable]"; exit 1;; esac
here=$(cd "$(dirname "$0")" && pwd)
install -m 644 "$here/systemd/glidelinkd@.service" /etc/systemd/system/
install -m 644 "$here/systemd/jscc-$board-app.service" /etc/systemd/system/
mkdir -p "/etc/systemd/system/glidelinkd@$board.service.d"
printf '[Unit]\nUpholds=jscc-%s-app.service\n' "$board" > "/etc/systemd/system/glidelinkd@$board.service.d/app.conf"
systemctl daemon-reload
if [ "$2" = "--enable" ]; then
	for s in jscc-tx jscc-rx jscc-gui jscc-web; do
		systemctl disable "$s.service" 2>/dev/null || true
	done
	systemctl enable "glidelinkd@$board.service"
fi
echo "installed: glidelinkd@$board.service (upholds jscc-$board-app.service)"
