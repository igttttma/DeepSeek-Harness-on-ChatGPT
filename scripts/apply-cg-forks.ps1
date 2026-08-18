# apply-cg-forks.ps1
# Apply ChatGPT npm junctions + asset forks into a DSH tree.
# Thin wrapper around the generated stage controller.
param(
    [string]$DshRoot = ''
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
$stageRoot = Join-Path $repo 'dist\stage'
$dshPs1 = Join-Path $stageRoot 'parasite-runtime\dsh.ps1'
if (-not (Test-Path -LiteralPath $dshPs1)) { throw "missing $dshPs1" }
if (-not $DshRoot) {
    $DshRoot = Join-Path $stageRoot 'dsh-runtime'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator permission is required. Run this development helper from an elevated terminal.'
}

Write-Host ('[DSH] elevated apply-forks dsh=' + $DshRoot)
& $dshPs1 'apply-forks' -DshRoot $DshRoot
exit $LASTEXITCODE
