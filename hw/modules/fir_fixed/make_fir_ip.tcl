# The FIR Compiler IP of a fixed-coefficient FIR module (rrc_interp, lp_decim, rrc_mf):
#   vivado -mode batch -source make_fir_ip.tcl -tclargs <module dir> <type> <rate> <input MSPS>
#     type: Single_Rate, Interpolation or Decimation; rate: L or M (1 for Single_Rate)
# writes <module dir>/ip/<module id>.xci for <module dir>/ip/<module id>.coe (python fir_fixed.py
# <module dir> writes it) and prints the output width. Fixed coefficients (no reload: a QPSK chain's
# pulse shaping, matched and decimation filters do not change at run time), the symmetry inferred
# from them, I and Q as two paths, full-precision output, a 200 MHz clock: the IP shares each
# multiplier over as many taps as the clock / sample-rate ratio allows.
set dir [file normalize [lindex $argv 0]]
set type [lindex $argv 1]
set rate [lindex $argv 2]
set fs [lindex $argv 3]
set id [file tail $dir]
set tmp [file join $dir ip _gen]
file delete -force $tmp
file mkdir $tmp
create_project -in_memory -part xczu5eg-sfvc784-2-e
create_ip -name fir_compiler -vendor xilinx.com -library ip -version 7.2 -module_name $id -dir $tmp
set cfg [list \
  CONFIG.Filter_Type $type \
  CONFIG.CoefficientSource COE_File \
  CONFIG.Coefficient_File [file join $dir ip $id.coe] \
  CONFIG.Coefficient_Structure Inferred \
  CONFIG.Coefficient_Width 16 \
  CONFIG.Coefficient_Sign Signed \
  CONFIG.Quantization Integer_Coefficients \
  CONFIG.Number_Channels 1 \
  CONFIG.Number_Paths 2 \
  CONFIG.Data_Width 16 \
  CONFIG.Data_Sign Signed \
  CONFIG.Output_Rounding_Mode Full_Precision \
  CONFIG.Clock_Frequency 200 \
  CONFIG.Sample_Frequency $fs \
  CONFIG.Has_ARESETn true \
  CONFIG.Reset_Data_Vector true \
  CONFIG.M_DATA_Has_TREADY true \
  CONFIG.S_DATA_Has_FIFO true]
if {$type eq "Interpolation"} { lappend cfg CONFIG.Interpolation_Rate $rate CONFIG.Decimation_Rate 1 }
if {$type eq "Decimation"} { lappend cfg CONFIG.Decimation_Rate $rate CONFIG.Interpolation_Rate 1 }
set_property -dict $cfg [get_ips $id]
foreach p {Output_Width Coefficient_Structure Filter_Architecture} {
  puts "IP $p = [get_property CONFIG.$p [get_ips $id]]"
}
file copy -force [file join $tmp $id $id.xci] [file join $dir ip $id.xci]
file delete -force $tmp
