# Simulation of a user module with the generic testbench (tb_module.v):
#   .\run_module_sim.ps1 <module dir> <top module> [-Vectors <dir>] [-Capture] [-Bin <vivado bin dir>]
#   e.g. .\run_module_sim.ps1 ..\..\..\modules\nco glidelink_nco
# Sources are the module's as the image generator sees them (hw/scripts/gen_image.py: its .v /
# .sv / .mem files and those of the libraries it uses), the module register interface library,
# and the simulation files of its Xilinx IP (exported once into the work directory by
# ip_sim_export.tcl). Without -Capture the output is compared with <vectors>/out.hex; with it,
# the output is written to <vectors>/captured.hex for the module's own checker.
param(
  [Parameter(Mandatory = $true)][string]$ModuleDir,
  [string]$Top = "",
  [string]$Vectors = "",
  [switch]$Capture,
  [int]$Packets = 0,                        # capture mode: stop after this many output packets
  [double]$TimeoutMs = 0,                   # simulated time limit (default 13 ms)
  [switch]$NoTuser,                         # output packets not one to one with input packets
  [int]$InFlags = -1,                       # input packets' tuser flags (default 0xC3 ^ packet number)
  [int]$MidFlush = 0,                       # flush mid-stream: the first MidFlush beats (MidFlushPkts
  [int]$MidFlushPkts = 0,                   # packets) go in with the output stalled, then a flush
  [string]$Bin = "D:\AMDDesignTools\2025.2\Vivado\bin"
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mod = (Resolve-Path $ModuleDir).Path
$name = Split-Path -Leaf $mod
if ($Vectors -eq "") { $Vectors = Join-Path $mod "tb\vectors" }
$vec = (Resolve-Path $Vectors).Path.Replace([char]92, [char]47)
$work = Join-Path $here "work\$name"
New-Item -ItemType Directory -Force $work | Out-Null
Push-Location $work
try {

  # the module's sources and IP, as the image generator lists them
  $py = @"
import json, sys
sys.path.insert(0, r'$here\..\..\..\scripts')
import gen_image
i = gen_image.module_info('$name', r'$work\gen')
print(json.dumps({'top': i['top'], 'rtl': i['rtl'], 'sv': gen_image.sv_compile_order(i['rtl']), 'ip': gen_image.patch_ips(i, r'$work\ip_xci')}))
"@
  $info = (& python -c $py) | ConvertFrom-Json
  if ($Top -eq "") { $Top = $info.top }
  $cfg = "``define DUT $Top`n``define VEC `"$vec`"`n"
  if ($Capture) { $cfg += "``define CAPTURE`n" }
  if ($Packets -gt 0) { $cfg += "``define CAPTURE_PACKETS $Packets`n" }
  if ($NoTuser) { $cfg += "``define NO_TUSER_CHECK`n" }
  if ($InFlags -ge 0) { $cfg += "``define IN_FLAGS 8'd$InFlags`n" }
  if ($MidFlush -gt 0) { $cfg += "``define MID_FLUSH $MidFlush`n``define MID_FLUSH_PKTS $MidFlushPkts`n" }
  if ($TimeoutMs -gt 0) { $cfg += "``define TIMEOUT_NS ($($TimeoutMs * 1e6))`n" }
  $cfg | Set-Content -Encoding ascii tb_cfg.vh
  $v = @(Get-ChildItem (Join-Path $here "..\*.v") | ForEach-Object { $_.FullName })
  $v += @($info.rtl | Where-Object { $_ -like "*.v" })
  # SystemVerilog packages first, in dependency order: xvlog compiles in the order given
  $sv = @($info.sv)
  # include path: the work directory (tb_cfg.vh) and every directory holding a library header
  $inc = @("-i", $work)
  foreach ($d in @($info.rtl | Where-Object { $_ -like "*.vh" -or $_ -like "*.svh" } | ForEach-Object { Split-Path $_ } | Sort-Object -Unique)) { $inc += @("-i", $d) }
  foreach ($m in @($info.rtl | Where-Object { $_ -like "*.mem" })) { Copy-Item -Force $m . }

  $libs = @("-L", "xpm", "-L", "unisims_ver")    # unisims: primitives in library RTL (e.g. SRLC32E)
  if ($info.ip.Count -gt 0) {
    $ipdir = Join-Path $work "ip_sim"
    if (-not (Test-Path (Join-Path $ipdir "export"))) {
      & "$Bin\vivado.bat" -mode batch -nojournal -nolog -source (Join-Path $here "ip_sim_export.tcl") -tclargs $ipdir @($info.ip) | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "IP export failed" }
    }
    # coefficient / init files the IP models read at elaboration, from the run directory
    foreach ($f in Get-ChildItem -Recurse (Join-Path $ipdir "ip") -Include *.mif, *.coe) { Copy-Item -Force $f.FullName . }
    foreach ($prj in Get-ChildItem -Recurse (Join-Path $ipdir "export") -Include vhdl.prj, vlog.prj) {
      $tool = if ($prj.Name -eq "vhdl.prj") { "xvhdl.bat" } else { "xvlog.bat" }
      & "$Bin\$tool" --nolog -prj $prj.FullName | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "$tool $($prj.FullName) failed" }
      $opt = Get-Content (Join-Path $prj.DirectoryName "elab.opt") -Raw
      foreach ($m in [regex]::Matches($opt, "-L (\S+)")) { $libs += @("-L", $m.Groups[1].Value) }
    }
  }

  & "$Bin\xvlog.bat" --nolog $inc $v (Join-Path $here "tb_module.v") | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
  if ($sv.Count -gt 0) {
    & "$Bin\xvlog.bat" --nolog -sv $inc $sv | Select-String "ERROR"
    if ($LASTEXITCODE -ne 0) { throw "xvlog -sv failed" }
  }
  & "$Bin\xvlog.bat" --nolog (Join-Path (Split-Path $Bin) "data\verilog\src\glbl.v") | Out-Null
  # --debug typical: with --debug off the xfft model (FFT IP) of ofdm_rx stops on a spurious
  # internal assertion ("add_1 must be in range") right after reset
  & "$Bin\xelab.bat" --nolog --debug typical --relax $libs tb_module glbl -s tb_module | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "xelab failed" }
  & "$Bin\xsim.bat" --nolog tb_module -R | Select-String -Pattern "PASS|FAIL|ERROR|Fatal|module ID|compared|captured|read back"
} finally {
  Pop-Location
}
