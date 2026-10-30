###############################################################################
## AD9361 FMC card on PYNQ-ZU (ADI fmcomms2 design)
##
## Run from this directory with the ADI HDL tree in ADI_HDL_DIR and its
## libraries built (hw/scripts/build_adi_libs.sh):
##   vivado -mode batch -source system_project.tcl
## GLIDELINK_IMAGE names the image (hw/images/<name>.yaml, default demo): the
## modules in the shell's slots. The project is fmcomms2_pynqzu for demo and
## fmcomms2_pynqzu_<name> otherwise, so images build side by side.
###############################################################################

set glidelink_hw_dir [file normalize [file join [file dirname [info script]] ../..]]
set glidelink_image [expr {[info exists ::env(GLIDELINK_IMAGE)] ? $::env(GLIDELINK_IMAGE) : "demo"}]
set glidelink_project [expr {$glidelink_image eq "demo" ? "fmcomms2_pynqzu" : "fmcomms2_pynqzu_$glidelink_image"}]

source $::env(ADI_HDL_DIR)/scripts/adi_env.tcl
source $ad_hdl_dir/projects/scripts/adi_project_xilinx.tcl
source $ad_hdl_dir/projects/scripts/adi_board.tcl
set ADI_POST_ROUTE_SCRIPT [file normalize $ad_hdl_dir/projects/scripts/auto_timing_fix_xilinx.tcl]

# PYNQ-ZU: xczu5eg, no Vivado board part
adi_project_create $glidelink_project 0 {} "xczu5eg-sfvc784-2-e"
adi_project_files $glidelink_project [list \
  "system_top.v" \
  "system_constr.xdc" \
  "$ad_hdl_dir/library/common/ad_iobuf.v" ]

## as in ADI's fmcomms2/zcu102: spread logic to help hold-time fixes
set_property strategy Congestion_SpreadLogic_high [get_runs impl_1]

adi_project_run $glidelink_project
source $ad_hdl_dir/library/axi_ad9361/axi_ad9361_delay.tcl
