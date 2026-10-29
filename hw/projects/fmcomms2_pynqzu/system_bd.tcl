###############################################################################
## AD9361 FMC card on PYNQ-ZU: GlideLink block design on the PYNQ-ZU carrier
###############################################################################

source $::glidelink_hw_dir/projects/common/pynqzu/pynqzu_system_bd.tcl
source $::glidelink_hw_dir/projects/fmcomms2_pynqzu/glidelink_bd.tcl
source $ad_hdl_dir/projects/scripts/adi_pd.tcl

# TX LVDS data-pair polarity (adi-patches/0001), driven from system_top

create_bd_port -dir I -from 5 -to 0 tx_data_invert
ad_connect tx_data_invert axi_ad9361/tx_data_invert

#system ID
ad_ip_parameter axi_sysid_0 CONFIG.ROM_ADDR_BITS 9
ad_ip_parameter rom_sys_0 CONFIG.PATH_TO_FILE "$mem_init_sys_file_path/mem_init_sys.txt"
ad_ip_parameter rom_sys_0 CONFIG.ROM_ADDR_BITS 9

sysid_gen_sys_init_file

ad_ip_parameter axi_ad9361 CONFIG.ADC_INIT_DELAY 11
ad_ip_parameter axi_ad9361 CONFIG.DELAY_REFCLK_FREQUENCY 500
