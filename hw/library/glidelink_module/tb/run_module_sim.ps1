# Bit-exact simulation of a user module against its reference model's vectors:
#   .\run_module_sim.ps1 <module dir> <top module> [vector dir] [vivado bin dir]
#   e.g. .\run_module_sim.ps1 ..\..\..\modules\nco glidelink_nco
# Compiles the module library (glidelink_module), every .v in the module dir and tb_module.v.
param(
  [Parameter(Mandatory = $true)][string]$ModuleDir,
  [Parameter(Mandatory = $true)][string]$Top,
  [string]$Vectors = "",
  [string]$Bin = "D:\AMDDesignTools\2025.2\Vivado\bin"
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mod = (Resolve-Path $ModuleDir).Path
if ($Vectors -eq "") { $Vectors = Join-Path $mod "tb\vectors" }
$vec = (Resolve-Path $Vectors).Path.Replace([char]92, [char]47)
$work = Join-Path $here "work\$Top"
New-Item -ItemType Directory -Force $work | Out-Null
Push-Location $work
try {
  "``define DUT $Top`n``define VEC `"$vec`"`n" | Set-Content -Encoding ascii tb_cfg.vh
  $src = @(Get-ChildItem (Join-Path $here "..\*.v") | ForEach-Object { $_.FullName })
  $src += @(Get-ChildItem (Join-Path $mod "*.v") | ForEach-Object { $_.FullName })
  & "$Bin\xvlog.bat" --nolog -i $work $src (Join-Path $here "tb_module.v") | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
  & "$Bin\xelab.bat" --nolog --debug off tb_module -s tb_module | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "xelab failed" }
  & "$Bin\xsim.bat" --nolog tb_module -R | Select-String -Pattern "PASS|FAIL|ERROR|Fatal|module ID|compared"
} finally {
  Pop-Location
}
