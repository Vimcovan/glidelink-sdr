# Run one shell testbench with xsim: .\run_sim.ps1 tb_shell_regs [vivado bin dir]
param(
  [Parameter(Mandatory = $true)][string]$Top,
  [string]$Bin = "D:\AMDDesignTools\2025.2\Vivado\bin"
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$work = Join-Path $here "work\$Top"
New-Item -ItemType Directory -Force $work | Out-Null
Push-Location $work
try {
  # a file in wip/ replaces the library file of the same name
  $files = @{}
  Get-ChildItem (Join-Path $here "..\*.v") | ForEach-Object { $files[$_.Name] = $_.FullName }
  Get-ChildItem (Join-Path $here "..\wip\*.v") -ErrorAction SilentlyContinue | ForEach-Object { $files[$_.Name] = $_.FullName }
  # the user modules in the slots, and their shared register interface
  Get-ChildItem (Join-Path $here "..\..\glidelink_module\*.v") | ForEach-Object { $files[$_.Name] = $_.FullName }
  Get-ChildItem (Join-Path $here "..\..\..\modules\*\*.v") | ForEach-Object { $files[$_.Name] = $_.FullName }
  $src = $files.Values
  & "$Bin\xvlog.bat" --nolog $src (Join-Path $here "$Top.v") | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
  & "$Bin\xelab.bat" --nolog --debug off $Top -s $Top | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "xelab failed" }
  & "$Bin\xsim.bat" --nolog $Top -R | Select-String -Pattern "PASS|FAIL|ERROR|Fatal|latency|packets|probe|phase"
} finally {
  Pop-Location
}
