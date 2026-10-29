###############################################################################
## AD9361 FMC card on PYNQ-ZU (ADI fmcomms2 design)
##
## Run from this directory with the ADI HDL tree in ADI_HDL_DIR and its
## libraries built (hw/scripts/build_adi_libs.sh):
##   vivado -mode batch -source system_project.tcl
###############################################################################

set glidelink_hw_dir [file normalize [file join [file dirname [info script]] ../..]]

source $::env(ADI_HDL_DIR)/scripts/adi_env.tcl
source $ad_hdl_dir/projects/scripts/adi_project_xilinx.tcl
source $ad_hdl_dir/projects/scripts/adi_board.tcl
set ADI_POST_ROUTE_SCRIPT [file normalize $ad_hdl_dir/projects/scripts/auto_timing_fix_xilinx.tcl]

# PYNQ-ZU: xczu5eg, no Vivado board part
adi_project_create fmcomms2_pynqzu 0 {} "xczu5eg-sfvc784-2-e"
adi_project_files fmcomms2_pynqzu [list \
  "system_top.v" \
  "system_constr.xdc" \
  "$ad_hdl_dir/library/common/ad_iobuf.v" ]

## as in ADI's fmcomms2/zcu102: spread logic to help hold-time fixes
set_property strategy Congestion_SpreadLogic_high [get_runs impl_1]

adi_project_run fmcomms2_pynqzu
source $ad_hdl_dir/library/axi_ad9361/axi_ad9361_delay.tcl
