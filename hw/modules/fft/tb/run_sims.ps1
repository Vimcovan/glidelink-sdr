# All simulations of the FFT module: writes the vectors (model.py), runs the generic
# testbench on each case (capture mode, then model.py check; vectors_bypass in compare mode).
#   .\run_sims.ps1 [case ...]
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mod = Split-Path -Parent $here
$runner = Join-Path $mod "..\..\library\glidelink_module\tb\run_module_sim.ps1"
$cases = [ordered]@{}
foreach ($line in (& python (Join-Path $mod "model.py") vectors @args)) {
  $name, $packets = $line -split " "
  $cases[$name] = [int]$packets
}
foreach ($name in $cases.Keys) {
  & $runner $mod glidelink_fft -Vectors (Join-Path $here $name) -Capture -Packets $cases[$name] -NoTuser -InFlags 0 |
    Select-String "captured|ERROR|FAIL" | Select-Object -First 1
}
if ($args.Count -eq 0) { & $runner $mod glidelink_fft -Vectors (Join-Path $here "vectors_bypass") }
& python (Join-Path $mod "model.py") check @($cases.Keys)
