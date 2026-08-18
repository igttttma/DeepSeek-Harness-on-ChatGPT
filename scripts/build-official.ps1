param(
    [string]$Source = '',
    [string]$Proxy = '',
    [switch]$SkipZip
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$source = if ($Source) { [IO.Path]::GetFullPath($Source) } else { Join-Path $repoRoot '.work\deepseek-harness' }
$sourceNodeModules = Join-Path $source 'node_modules'
$helperRoot = Join-Path $env:TEMP ('dsh-release-unrun-' + [guid]::NewGuid().ToString('N'))
$targets = @()

if (-not (Test-Path -LiteralPath (Join-Path $source 'package.json'))) {
    throw ('official source missing: ' + $source)
}

if ($Proxy) {
    $env:HTTP_PROXY = $Proxy
    $env:HTTPS_PROXY = $Proxy
    $env:ALL_PROXY = $Proxy
}
$env:CI = 'true'

function Invoke-Pnpm([string[]]$arguments) {
    & pnpm @arguments
    if ($LASTEXITCODE -ne 0) { throw ('pnpm failed: ' + ($arguments -join ' ')) }
}

function Remove-LinkOrTree([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        cmd /c ('rmdir "' + $path + '"') | Out-Null
    } else {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

Push-Location $source
try {
    Write-Host '[official] install dependencies'
    Invoke-Pnpm @('install', '--fetch-timeout=600000', '--network-concurrency=8')

    Remove-LinkOrTree $helperRoot
    New-Item -ItemType Directory -Force -Path $helperRoot | Out-Null
    Push-Location $helperRoot
    try {
        & npm install unrun@0.3.1 --no-fund --no-audit
        if ($LASTEXITCODE -ne 0) { throw 'temporary unrun install failed' }
    } finally {
        Pop-Location
    }
    $unrun = Join-Path $helperRoot 'node_modules\unrun'
    $targets = @(
        (Join-Path $sourceNodeModules 'unrun'),
        (Join-Path $sourceNodeModules '.pnpm\node_modules\unrun')
    )
    Get-ChildItem (Join-Path $sourceNodeModules '.pnpm') -Directory -Filter 'tsdown@*' |
        ForEach-Object { $targets += (Join-Path $_.FullName 'node_modules\unrun') }
    foreach ($target in $targets) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Remove-LinkOrTree $target
        New-Item -ItemType Junction -Path $target -Target $unrun | Out-Null
    }

    Write-Host '[official] build'
    Invoke-Pnpm @('run', 'build')

    Write-Host '[official] materialize production harvest layout'
    Invoke-Pnpm @('install', '--prod', '--shamefully-hoist', '--ignore-scripts', '--fetch-timeout=600000', '--network-concurrency=8')

    Write-Host '[official] harvest minimal closure'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'build-release.ps1'), '-Source', $source)
    if ($SkipZip) { $arguments += '-SkipZip' }
    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
    foreach ($target in $targets) { Remove-LinkOrTree $target }
    Remove-LinkOrTree $helperRoot
}
