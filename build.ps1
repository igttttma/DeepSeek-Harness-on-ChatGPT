[CmdletBinding()]
param(
    [string]$Ref = 'dsh-v0.1.1-rc.2',
    [string]$Source = '',
    [string]$Proxy = '',
    [switch]$Offline,
    [switch]$SkipOfficialBuild,
    [switch]$StageOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$officialRepository = 'https://github.com/deepseek-ai/deepseek-harness.git'
$managedSource = -not $Source
if ($managedSource) { $Source = Join-Path $repoRoot '.work\deepseek-harness' }
$Source = [IO.Path]::GetFullPath($Source)

function Write-Step([string]$message) {
    Write-Host ('[builder] ' + $message)
}

function Invoke-Native([string]$file, [string[]]$arguments) {
    & $file @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ($file + ' failed with exit code ' + $LASTEXITCODE + ': ' + ($arguments -join ' '))
    }
}

foreach ($command in @('git', 'pnpm')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw ('required build command is unavailable: ' + $command)
    }
}

if ($Proxy) {
    $env:HTTP_PROXY = $Proxy
    $env:HTTPS_PROXY = $Proxy
    $env:ALL_PROXY = $Proxy
}

if ($managedSource) {
    if (-not (Test-Path -LiteralPath (Join-Path $Source '.git') -PathType Container)) {
        if ($Offline) { throw ('official source is unavailable in offline mode: ' + $Source) }
        Write-Step ('clone official DeepSeek Harness into ' + $Source)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Source) | Out-Null
        Invoke-Native 'git' @('clone', '--filter=blob:none', $officialRepository, $Source)
    }

    $origin = (& git -C $Source remote get-url origin).Trim()
    if ($LASTEXITCODE -ne 0 -or $origin -ne $officialRepository) {
        throw ('unexpected DeepSeek Harness origin: ' + $origin)
    }
    $dirty = @(& git -C $Source status --porcelain --untracked-files=no)
    if ($LASTEXITCODE -ne 0) { throw 'unable to inspect official source status' }
    if ($dirty.Count -gt 0) {
        throw 'official source has tracked changes; commit or discard them before building'
    }

    if (-not $Offline) {
        Write-Step 'fetch official refs'
        Invoke-Native 'git' @('-C', $Source, 'fetch', '--tags', '--prune', 'origin')
    }

    $commit = (& git -C $Source rev-parse --verify ($Ref + '^{commit}') 2>$null | Select-Object -First 1)
    if (-not $commit) {
        $commit = (& git -C $Source rev-parse --verify ('origin/' + $Ref + '^{commit}') 2>$null | Select-Object -First 1)
    }
    if (-not $commit) { throw ('official ref was not found: ' + $Ref) }
    $commit = $commit.Trim()
    Write-Step ('checkout ' + $Ref + ' @ ' + $commit.Substring(0, 12))
    Invoke-Native 'git' @('-C', $Source, 'switch', '--detach', $commit)
}

$packageJsonPath = Join-Path $Source 'package.json'
if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
    throw ('official DeepSeek Harness source is invalid: ' + $Source)
}
$packageJson = Get-Content -LiteralPath $packageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Step ('source version ' + $packageJson.version)

if (-not $SkipOfficialBuild) {
    $officialArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repoRoot 'scripts\build-official.ps1'), '-Source', $Source, '-SkipZip')
    if ($Proxy) { $officialArgs += @('-Proxy', $Proxy) }
    Invoke-Native 'powershell.exe' $officialArgs
} else {
    $releaseArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repoRoot 'scripts\build-release.ps1'), '-Source', $Source, '-SkipZip')
    Invoke-Native 'powershell.exe' $releaseArgs
}

if ($StageOnly) {
    Write-Step ('stage ready: ' + (Join-Path $repoRoot 'dist\stage'))
    exit 0
}

$installerArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $repoRoot 'scripts\build-installer.ps1'),
    '-Source', $Source,
    '-SkipReleaseBuild'
)
if ($Proxy) { $installerArgs += @('-Proxy', $Proxy) }
Invoke-Native 'powershell.exe' $installerArgs

$artifacts = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'dist\installer'), (Join-Path $repoRoot 'dist\portable') -File)
Write-Step 'artifacts'
$artifacts | ForEach-Object {
    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    Write-Host ('  ' + $_.FullName)
    Write-Host ('  SHA256 ' + $hash)
}
