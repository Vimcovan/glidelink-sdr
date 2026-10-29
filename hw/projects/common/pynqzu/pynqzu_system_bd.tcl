###############################################################################
## PYNQ-ZU carrier: PS + system clocks/resets, EMIO GPIO and SPI, system ID and
## interrupt concatenation. Same interface (nets and pointer variables) as ADI's
## projects/common/zcu102/zcu102_system_bd.tcl, so ADI project block designs
## (e.g. fmcomms2_bd.tcl) can be sourced on top of it.
##
## Differences from zcu102:
## - the PS starts from the PYNQ-ZU configuration (ps_config_list.txt, exported
##   from the board's PYNQ image) instead of a board preset;
## - the FMC SPI is an AXI Quad SPI in the PL: SPI0 is on MIO 38..43 in the
##   PYNQ-ZU boot configuration and SPI1 is not in its PM configuration (the
##   PMU firmware refuses it, -EACCES), and an overlay can change neither.
###############################################################################

set CACHE_COHERENCY true

# default ports

create_bd_port -dir O -from 0 -to 0 spi_csn_o
create_bd_port -dir I -from 0 -to 0 spi_csn_i
create_bd_port -dir I spi_clk_i
create_bd_port -dir O spi_clk_o
create_bd_port -dir I spi_sdo_i
create_bd_port -dir O spi_sdo_o
create_bd_port -dir I spi_sdi_i

create_bd_port -dir I -from 94 -to 0 gpio_i
create_bd_port -dir O -from 94 -to 0 gpio_o
create_bd_port -dir O -from 94 -to 0 gpio_t

# instance: sys_ps8

ad_ip_instance zynq_ultra_ps_e sys_ps8

set ps_cfg_file [file join [file dirname [info script]] ps_config_list.txt]
set fh [open $ps_cfg_file r]
set ps_cfg {}
foreach l [split [read $fh] "\n"] {
  if {$l ne ""} {lappend ps_cfg [lindex $l 0] [lindex $l 1]}
}
close $fh
set_property -dict $ps_cfg [get_bd_cells sys_ps8]

# PL-side interfaces: start from none, the project adds what it uses
# (ad_cpu_interconnect -> HPM0_LPD, ad_mem_hpc*_interconnect -> HPC0/HPC1)

ad_ip_parameter sys_ps8 CONFIG.PSU__USE__M_AXI_GP0 0
ad_ip_parameter sys_ps8 CONFIG.PSU__USE__M_AXI_GP1 0
ad_ip_parameter sys_ps8 CONFIG.PSU__USE__M_AXI_GP2 1
ad_ip_parameter sys_ps8 CONFIG.PSU__MAXIGP2__DATA_WIDTH 32
ad_ip_parameter sys_ps8 CONFIG.PSU__USE__S_AXI_GP2 0
ad_ip_parameter sys_ps8 CONFIG.PSU__USE__S_AXI_GP4 0
ad_ip_parameter sys_ps8 CONFIG.PSU__USE__S_AXI_GP6 0

ad_ip_parameter sys_ps8 CONFIG.PSU__FPGA_PL0_ENABLE 1
ad_ip_parameter sys_ps8 CONFIG.PSU__CRL_APB__PL0_REF_CTRL__SRCSEL {IOPLL}
ad_ip_parameter sys_ps8 CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ 100
ad_ip_parameter sys_ps8 CONFIG.PSU__FPGA_PL1_ENABLE 1
ad_ip_parameter sys_ps8 CONFIG.PSU__FPGA_PL2_ENABLE 1
ad_ip_parameter sys_ps8 CONFIG.PSU__FPGA_PL3_ENABLE 0
ad_ip_parameter sys_ps8 CONFIG.PSU__CRL_APB__PL1_REF_CTRL__SRCSEL {IOPLL}
ad_ip_parameter sys_ps8 CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ 250
ad_ip_parameter sys_ps8 CONFIG.PSU__CRL_APB__PL2_REF_CTRL__SRCSEL {IOPLL}
ad_ip_parameter sys_ps8 CONFIG.PSU__CRL_APB__PL2_REF_CTRL__FREQMHZ 500
ad_ip_parameter sys_ps8 CONFIG.PSU__USE__IRQ0 1
ad_ip_parameter sys_ps8 CONFIG.PSU__USE__IRQ1 1
ad_ip_parameter sys_ps8 CONFIG.PSU__GPIO_EMIO__PERIPHERAL__ENABLE 1
ad_ip_parameter sys_ps8 CONFIG.PSU__GPIO_EMIO__PERIPHERAL__IO 95

# processor system reset instances for all the three system clocks

ad_ip_instance proc_sys_reset sys_rstgen
ad_ip_parameter sys_rstgen CONFIG.C_EXT_RST_WIDTH 1
ad_ip_instance proc_sys_reset sys_250m_rstgen
ad_ip_parameter sys_250m_rstgen CONFIG.C_EXT_RST_WIDTH 1
ad_ip_instance proc_sys_reset sys_500m_rstgen
ad_ip_parameter sys_500m_rstgen CONFIG.C_EXT_RST_WIDTH 1

# system reset/clock definitions

ad_connect  sys_cpu_clk sys_ps8/pl_clk0
ad_connect  sys_250m_clk sys_ps8/pl_clk1
ad_connect  sys_500m_clk sys_ps8/pl_clk2

ad_connect  sys_ps8/pl_resetn0 sys_rstgen/ext_reset_in
ad_connect  sys_cpu_clk sys_rstgen/slowest_sync_clk
ad_connect  sys_ps8/pl_resetn0 sys_250m_rstgen/ext_reset_in
ad_connect  sys_250m_clk sys_250m_rstgen/slowest_sync_clk
ad_connect  sys_ps8/pl_resetn0 sys_500m_rstgen/ext_reset_in
ad_connect  sys_500m_clk sys_500m_rstgen/slowest_sync_clk

ad_connect  sys_cpu_reset sys_rstgen/peripheral_reset
ad_connect  sys_cpu_resetn sys_rstgen/peripheral_aresetn
ad_connect  sys_250m_reset sys_250m_rstgen/peripheral_reset
ad_connect  sys_250m_resetn sys_250m_rstgen/peripheral_aresetn
ad_connect  sys_500m_reset sys_500m_rstgen/peripheral_reset
ad_connect  sys_500m_resetn sys_500m_rstgen/peripheral_aresetn

# generic system clocks&resets pointers

set sys_cpu_clk            [get_bd_nets sys_cpu_clk]
set sys_dma_clk            [get_bd_nets sys_250m_clk]
set sys_iodelay_clk        [get_bd_nets sys_500m_clk]

set  sys_cpu_reset         [get_bd_nets sys_cpu_reset]
set  sys_cpu_resetn        [get_bd_nets sys_cpu_resetn]
set  sys_dma_reset         [get_bd_nets sys_250m_reset]
set  sys_dma_resetn        [get_bd_nets sys_250m_resetn]
set  sys_iodelay_reset     [get_bd_nets sys_500m_reset]
set  sys_iodelay_resetn    [get_bd_nets sys_500m_resetn]

# gpio

ad_connect  gpio_i sys_ps8/emio_gpio_i
ad_connect  gpio_o sys_ps8/emio_gpio_o
ad_connect  gpio_t sys_ps8/emio_gpio_t

# spi (sck = 100 MHz / 16)

ad_ip_instance axi_quad_spi axi_spi
ad_ip_parameter axi_spi CONFIG.C_USE_STARTUP 0
ad_ip_parameter axi_spi CONFIG.C_NUM_SS_BITS 1
ad_ip_parameter axi_spi CONFIG.C_SCK_RATIO 16

ad_connect  sys_cpu_clk axi_spi/ext_spi_clk
ad_connect  spi_csn_i axi_spi/ss_i
ad_connect  spi_csn_o axi_spi/ss_o
ad_connect  spi_clk_i axi_spi/sck_i
ad_connect  spi_clk_o axi_spi/sck_o
ad_connect  spi_sdo_i axi_spi/io0_i
ad_connect  spi_sdo_o axi_spi/io0_o
ad_connect  spi_sdi_i axi_spi/io1_i

# system id

ad_ip_instance axi_sysid axi_sysid_0
ad_ip_instance sysid_rom rom_sys_0

ad_connect  axi_sysid_0/rom_addr   	rom_sys_0/rom_addr
ad_connect  axi_sysid_0/sys_rom_data   	rom_sys_0/rom_data
ad_connect  sys_cpu_clk                 rom_sys_0/clk

ad_cpu_interconnect 0x45000000 axi_sysid_0
ad_cpu_interconnect 0x44A70000 axi_spi

# interrupts

ad_ip_instance ilconcat sys_concat_intc_0
ad_ip_parameter sys_concat_intc_0 CONFIG.NUM_PORTS 8

ad_ip_instance ilconcat sys_concat_intc_1
ad_ip_parameter sys_concat_intc_1 CONFIG.NUM_PORTS 8

ad_connect  sys_concat_intc_0/dout sys_ps8/pl_ps_irq0
ad_connect  sys_concat_intc_1/dout sys_ps8/pl_ps_irq1

for {set i 0} {$i < 8} {incr i} {
  ad_connect  sys_concat_intc_0/In$i GND
  ad_connect  sys_concat_intc_1/In$i GND
}

ad_cpu_interrupt ps-11 mb-11 axi_spi/ip2intc_irpt
