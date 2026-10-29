#!/bin/bash
# Package the ADI HDL IP cores used by the fmcomms2_pynqzu project, in
# dependency order (what ADI's library Makefiles do, without make).
# Usage: build_adi_libs.sh <adi hdl dir>    (VIVADO: vivado executable)
set -e
ADI=${1:?adi hdl dir}
VIVADO=${VIVADO:-vivado}
# hdl_2026_r1 asks for Vivado 2025.1; we build with 2025.2
export ADI_IGNORE_VERSION_CHECK=1

LIBS="interfaces axi_dmac/interfaces util_cdc util_axis_fifo axi_dmac axi_ad9361
	axi_sysid sysid_rom util_pack/util_cpack2 util_pack/util_upack2 util_rfifo
	util_wfifo util_tdd_sync xilinx/util_clkdiv"

for l in $LIBS; do
	d="$ADI/library/$l"
	n=$(basename "$l")
	if [ -f "$d/.glidelink_built" ]; then echo "skip $l"; continue; fi
	echo "== $l"
	(cd "$d" && "$VIVADO" -mode batch -nojournal -log "${n}_ip.log" -source "${n}_ip.tcl" > /dev/null)
	touch "$d/.glidelink_built"
done
