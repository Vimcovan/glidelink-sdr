###############################################################################
## AD9361 + GlideLink shell block design (docs/phase1_shell.md, step 1.2)
##
## Based on ADI projects/fmcomms2/common/fmcomms2_bd.tcl (ADIBSD): axi_ad9361,
## the TDD sync and the two axi_dmac are kept; the ADC/DAC FIFOs, cpack/upack
## and the divided clock are replaced by the shell, which takes AD9361 channel
## 0 and feeds the DMAs as AXI4-Stream in the 200 MHz processing clock.
###############################################################################

# ad9361

create_bd_port -dir I rx_clk_in_p
create_bd_port -dir I rx_clk_in_n
create_bd_port -dir I rx_frame_in_p
create_bd_port -dir I rx_frame_in_n
create_bd_port -dir I -from 5 -to 0 rx_data_in_p
create_bd_port -dir I -from 5 -to 0 rx_data_in_n

create_bd_port -dir O tx_clk_out_p
create_bd_port -dir O tx_clk_out_n
create_bd_port -dir O tx_frame_out_p
create_bd_port -dir O tx_frame_out_n
create_bd_port -dir O -from 5 -to 0 tx_data_out_p
create_bd_port -dir O -from 5 -to 0 tx_data_out_n

create_bd_port -dir O enable
create_bd_port -dir O txnrx
create_bd_port -dir I up_enable
create_bd_port -dir I up_txnrx

create_bd_port -dir O tdd_sync_o
create_bd_port -dir I tdd_sync_i
create_bd_port -dir O tdd_sync_t

ad_ip_instance axi_ad9361 axi_ad9361
ad_ip_parameter axi_ad9361 CONFIG.ID 0
ad_ip_parameter axi_ad9361 CONFIG.DAC_DDS_TYPE 1
ad_ip_parameter axi_ad9361 CONFIG.DAC_DDS_CORDIC_DW 14

ad_connect $sys_iodelay_clk axi_ad9361/delay_clk
ad_connect axi_ad9361/l_clk axi_ad9361/clk
ad_connect rx_clk_in_p axi_ad9361/rx_clk_in_p
ad_connect rx_clk_in_n axi_ad9361/rx_clk_in_n
ad_connect rx_frame_in_p axi_ad9361/rx_frame_in_p
ad_connect rx_frame_in_n axi_ad9361/rx_frame_in_n
ad_connect rx_data_in_p axi_ad9361/rx_data_in_p
ad_connect rx_data_in_n axi_ad9361/rx_data_in_n
ad_connect tx_clk_out_p axi_ad9361/tx_clk_out_p
ad_connect tx_clk_out_n axi_ad9361/tx_clk_out_n
ad_connect tx_frame_out_p axi_ad9361/tx_frame_out_p
ad_connect tx_frame_out_n axi_ad9361/tx_frame_out_n
ad_connect tx_data_out_p axi_ad9361/tx_data_out_p
ad_connect tx_data_out_n axi_ad9361/tx_data_out_n
ad_connect enable axi_ad9361/enable
ad_connect txnrx axi_ad9361/txnrx
ad_connect up_enable axi_ad9361/up_enable
ad_connect up_txnrx axi_ad9361/up_txnrx

ad_ip_instance util_tdd_sync util_ad9361_tdd_sync
ad_ip_parameter util_ad9361_tdd_sync CONFIG.TDD_SYNC_PERIOD 10000000
ad_connect $sys_cpu_clk util_ad9361_tdd_sync/clk
ad_connect $sys_cpu_resetn util_ad9361_tdd_sync/rstn
ad_connect util_ad9361_tdd_sync/sync_out axi_ad9361/tdd_sync
ad_connect util_ad9361_tdd_sync/sync_mode axi_ad9361/tdd_sync_cntr
ad_connect tdd_sync_t axi_ad9361/tdd_sync_cntr
ad_connect tdd_sync_o util_ad9361_tdd_sync/sync_out
ad_connect tdd_sync_i util_ad9361_tdd_sync/sync_in

# GlideLink shell

add_files -norecurse [glob $::glidelink_hw_dir/library/glidelink_shell/*.v]
add_files -norecurse [glob $::glidelink_hw_dir/library/glidelink_module/*.v]
# the image's slots (docs/phase4_plan.md G7): generated slot wiring, module RTL and IP
set glidelink_gen [file normalize [file join [pwd] gen_$::glidelink_image]]
# Vivado puts its own Python (without PyYAML) first on PATH: GLIDELINK_PYTHON, else the
# Windows launcher "py -3", else python3
if {[info exists ::env(GLIDELINK_PYTHON)]} {
  set glidelink_python [list $::env(GLIDELINK_PYTHON)]
} elseif {[auto_execok py] ne ""} {
  set glidelink_python [list py -3]
} else {
  set glidelink_python [list python3]
}
exec {*}$glidelink_python $::glidelink_hw_dir/scripts/gen_image.py $::glidelink_hw_dir/images/$::glidelink_image.yaml $glidelink_gen
add_files -norecurse [list $glidelink_gen/glidelink_slots.v $glidelink_gen/glidelink_image.vh]
set_property file_type {Verilog Header} [get_files $glidelink_gen/glidelink_image.vh]
set_property include_dirs [list $glidelink_gen] [current_fileset]
source $glidelink_gen/image_sources.tcl
update_compile_order -fileset sources_1

create_bd_cell -type module -reference glidelink_shell shell
create_bd_port -dir I -from 7 -to 0 ctrl_out
ad_connect ctrl_out shell/ctrl_out

ad_connect axi_ad9361/l_clk shell/l_clk
ad_connect axi_ad9361/rst shell/l_rst
ad_connect axi_ad9361/adc_valid_i0 shell/adc_valid_i0
ad_connect axi_ad9361/adc_data_i0 shell/adc_data_i0
ad_connect axi_ad9361/adc_data_q0 shell/adc_data_q0
ad_connect shell/adc_dovf axi_ad9361/adc_dovf
ad_connect axi_ad9361/dac_valid_i0 shell/dac_valid_i0
ad_connect shell/dac_data_i0 axi_ad9361/dac_data_i0
ad_connect shell/dac_data_q0 axi_ad9361/dac_data_q0
ad_connect GND axi_ad9361/dac_data_i1
ad_connect GND axi_ad9361/dac_data_q1
ad_connect shell/dac_dunf axi_ad9361/dac_dunf

ad_connect sys_200m_clk shell/clk
ad_connect sys_200m_resetn shell/rstn
ad_connect sys_250m_clk shell/clk_250

# host port 0: RX DMA (FIFO write interface -> memory). Not the AXI4-Stream
# source: with it the Linux axi-dmac driver never enabled the channel (RX
# refills timed out with CTRL = 0), while the FIFO source is the one ADI uses.

ad_ip_instance axi_dmac axi_ad9361_adc_dma
ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_TYPE_SRC 2
ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.CYCLIC 0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.SYNC_TRANSFER_START 0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_SG_TRANSFER 1
ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_DATA_WIDTH_SRC 32
ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_DATA_WIDTH_SG 64
ad_ip_parameter axi_ad9361_adc_dma CONFIG.CACHE_COHERENT $CACHE_COHERENCY

ad_connect sys_200m_clk axi_ad9361_adc_dma/fifo_wr_clk
ad_connect shell/host0_rx_valid axi_ad9361_adc_dma/fifo_wr_en
ad_connect shell/host0_rx_data axi_ad9361_adc_dma/fifo_wr_din
ad_connect axi_ad9361_adc_dma/fifo_wr_xfer_req shell/host0_rx_xfer_req
ad_connect axi_ad9361_adc_dma/fifo_wr_overflow shell/host0_rx_overflow
ad_connect $sys_cpu_resetn axi_ad9361_adc_dma/m_dest_axi_aresetn
ad_connect $sys_cpu_resetn axi_ad9361_adc_dma/m_sg_axi_aresetn

# host port 0: TX DMA (memory -> stream)

ad_ip_instance axi_dmac axi_ad9361_dac_dma
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_TYPE_SRC 0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_TYPE_DEST 1
ad_ip_parameter axi_ad9361_dac_dma CONFIG.CYCLIC 1
ad_ip_parameter axi_ad9361_dac_dma CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_SG_TRANSFER 1
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_DATA_WIDTH_DEST 32
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_DATA_WIDTH_SG 64
ad_ip_parameter axi_ad9361_dac_dma CONFIG.CACHE_COHERENT $CACHE_COHERENCY

ad_connect sys_200m_clk axi_ad9361_dac_dma/m_axis_aclk
ad_connect axi_ad9361_dac_dma/m_axis_valid shell/host0_tx_valid
ad_connect axi_ad9361_dac_dma/m_axis_ready shell/host0_tx_ready
ad_connect axi_ad9361_dac_dma/m_axis_data shell/host0_tx_data
ad_connect axi_ad9361_dac_dma/m_axis_last shell/host0_tx_last
ad_connect $sys_cpu_resetn axi_ad9361_dac_dma/m_src_axi_aresetn
ad_connect $sys_cpu_resetn axi_ad9361_dac_dma/m_sg_axi_aresetn

# host port 1 (step 1.5): a second DMA pair, like host port 0 but not tied to
# the RF; IIO devices glidelink-host1-rx / -tx (os/kernel/glidelink)

ad_ip_instance axi_dmac host1_rx_dma
ad_ip_parameter host1_rx_dma CONFIG.DMA_TYPE_SRC 2
ad_ip_parameter host1_rx_dma CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter host1_rx_dma CONFIG.CYCLIC 0
ad_ip_parameter host1_rx_dma CONFIG.SYNC_TRANSFER_START 0
ad_ip_parameter host1_rx_dma CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter host1_rx_dma CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter host1_rx_dma CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter host1_rx_dma CONFIG.DMA_SG_TRANSFER 1
ad_ip_parameter host1_rx_dma CONFIG.DMA_DATA_WIDTH_SRC 32
ad_ip_parameter host1_rx_dma CONFIG.DMA_DATA_WIDTH_SG 64
ad_ip_parameter host1_rx_dma CONFIG.CACHE_COHERENT $CACHE_COHERENCY

ad_connect sys_200m_clk host1_rx_dma/fifo_wr_clk
ad_connect shell/host1_rx_valid host1_rx_dma/fifo_wr_en
ad_connect shell/host1_rx_data host1_rx_dma/fifo_wr_din
ad_connect host1_rx_dma/fifo_wr_xfer_req shell/host1_rx_xfer_req
ad_connect host1_rx_dma/fifo_wr_overflow shell/host1_rx_overflow
ad_connect $sys_cpu_resetn host1_rx_dma/m_dest_axi_aresetn
ad_connect $sys_cpu_resetn host1_rx_dma/m_sg_axi_aresetn

ad_ip_instance axi_dmac host1_tx_dma
ad_ip_parameter host1_tx_dma CONFIG.DMA_TYPE_SRC 0
ad_ip_parameter host1_tx_dma CONFIG.DMA_TYPE_DEST 1
ad_ip_parameter host1_tx_dma CONFIG.CYCLIC 1
ad_ip_parameter host1_tx_dma CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter host1_tx_dma CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter host1_tx_dma CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter host1_tx_dma CONFIG.DMA_SG_TRANSFER 1
ad_ip_parameter host1_tx_dma CONFIG.DMA_DATA_WIDTH_DEST 32
ad_ip_parameter host1_tx_dma CONFIG.DMA_DATA_WIDTH_SG 64
ad_ip_parameter host1_tx_dma CONFIG.CACHE_COHERENT $CACHE_COHERENCY

ad_connect sys_200m_clk host1_tx_dma/m_axis_aclk
ad_connect host1_tx_dma/m_axis_valid shell/host1_tx_valid
ad_connect host1_tx_dma/m_axis_ready shell/host1_tx_ready
ad_connect host1_tx_dma/m_axis_data shell/host1_tx_data
ad_connect host1_tx_dma/m_axis_last shell/host1_tx_last
ad_connect $sys_cpu_resetn host1_tx_dma/m_src_axi_aresetn
ad_connect $sys_cpu_resetn host1_tx_dma/m_sg_axi_aresetn

# cpu interconnect, memory, interrupts (as ADI fmcomms2, plus host port 1)

ad_cpu_interconnect 0x79020000 axi_ad9361
ad_cpu_interconnect 0x7C400000 axi_ad9361_adc_dma
ad_cpu_interconnect 0x7C420000 axi_ad9361_dac_dma
ad_cpu_interconnect 0x44B00000 shell
ad_cpu_interconnect 0x7C440000 host1_rx_dma
ad_cpu_interconnect 0x7C460000 host1_tx_dma

ad_mem_hpc0_interconnect $sys_cpu_clk sys_ps8/S_AXI_HPC0
ad_mem_hpc0_interconnect $sys_cpu_clk axi_ad9361_adc_dma/m_dest_axi
ad_mem_hpc0_interconnect $sys_cpu_clk axi_ad9361_adc_dma/m_sg_axi
ad_mem_hpc1_interconnect $sys_cpu_clk sys_ps8/S_AXI_HPC1
ad_mem_hpc1_interconnect $sys_cpu_clk axi_ad9361_dac_dma/m_src_axi
ad_mem_hpc1_interconnect $sys_cpu_clk axi_ad9361_dac_dma/m_sg_axi
ad_mem_hpc0_interconnect $sys_cpu_clk host1_rx_dma/m_dest_axi
ad_mem_hpc0_interconnect $sys_cpu_clk host1_rx_dma/m_sg_axi
ad_mem_hpc1_interconnect $sys_cpu_clk host1_tx_dma/m_src_axi
ad_mem_hpc1_interconnect $sys_cpu_clk host1_tx_dma/m_sg_axi

ad_cpu_interrupt ps-13 mb-12 axi_ad9361_adc_dma/irq
ad_cpu_interrupt ps-12 mb-13 axi_ad9361_dac_dma/irq
ad_cpu_interrupt ps-10 mb-10 host1_rx_dma/irq
ad_cpu_interrupt ps-9 mb-9 host1_tx_dma/irq
