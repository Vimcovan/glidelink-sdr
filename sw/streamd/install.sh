#!/bin/bash
# Build and install glidelink-streamd on the board (as root, in this directory)
set -e
gcc -O2 -Wall -o /usr/local/bin/glidelink_streamd glidelink_streamd.c -liio -lpthread
cp glidelink-streamd.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now glidelink-streamd
systemctl restart glidelink-streamd
systemctl is-active glidelink-streamd
