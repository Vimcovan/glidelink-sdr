# Export the simulation files of a module's Xilinx IP for xsim (run_module_sim.ps1 calls it):
#   vivado -mode batch -source ip_sim_export.tcl -tclargs <out dir> <ip1.xci> [<ip2.xci> ...]
# (the .xci given are the image generator's copies, with the module's ip_files resolved)
# Each .xci is copied into <out dir>/ip/<name>/, its simulation target generated, and
# export_simulation writes the xsim compile lists to <out dir>/export.
set out [file normalize [lindex $argv 0]]
create_project -in_memory -part xczu5eg-sfvc784-2-e
foreach xci [lrange $argv 1 end] {
  set name [file rootname [file tail $xci]]
  file mkdir $out/ip/$name
  # point the output directory the .xci remembers from its original project at the
  # copy's own directory, so that the generated files stay next to it
  set f [open $xci r]; set text [read $f]; close $f
  regsub -all {"gen_directory": "[^"]*"} $text {"gen_directory": "."} text
  regsub -all {"OUTPUTDIR": \[ \{ "value": "[^"]*" \} \]} $text {"OUTPUTDIR": [ { "value": "." } ]} text
  set f [open $out/ip/$name/[file tail $xci] w]; puts -nonewline $f $text; close $f
  read_ip $out/ip/$name/[file tail $xci]
}
upgrade_ip [get_ips] -quiet
generate_target simulation [get_ips]
export_simulation -of_objects [get_ips] -simulator xsim -directory $out/export -force -absolute_path
