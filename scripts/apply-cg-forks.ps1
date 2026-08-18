# apply-cg-forks.ps1
# Apply ChatGPT npm junctions + asset forks into a DSH tree.
# Thin wrapper around the generated stage controller.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
$stageRoot = Join-Path $repo 'dist\stage'
$launcher = Join-Path $stageRoot 'DeepSeek Harness (on ChatGPT).exe'
if (-not (Test-Path -LiteralPath $launcher)) { throw "missing $launcher" }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator permission is required. Run this development helper from an elevated terminal.'
}

Write-Host '[DSH] elevated apply-forks'
$process = Start-Process -FilePath $launcher -ArgumentList 'prepare-elevated' -Wait -PassThru
exit $process.ExitCode
