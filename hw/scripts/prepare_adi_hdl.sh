#!/bin/bash
# Apply hw/adi-patches to an ADI HDL checkout (branch hdl_2026_r1).
# Usage: prepare_adi_hdl.sh <adi hdl dir>
set -e
ADI=${1:?adi hdl dir}
HERE=$(cd "$(dirname "$0")/.." && pwd)
for p in "$HERE"/adi-patches/*.patch; do
	if git -C "$ADI" apply --reverse --check "$p" 2>/dev/null; then
		echo "already applied: $(basename "$p")"
	else
		git -C "$ADI" apply "$p"
		echo "applied: $(basename "$p")"
	fi
done
