param(
    [string]$Source = '',
    [string]$ReleaseDir = '',
    [string]$OutputDir = '',
    [string]$PortableOutputDir = '',
    [string]$Proxy = '',
    [switch]$BuildOfficialSource,
    [switch]$SkipReleaseBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ReleaseDir) { $ReleaseDir = Join-Path $repoRoot 'dist\stage' }
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'dist\installer' }
if (-not $PortableOutputDir) { $PortableOutputDir = Join-Path $repoRoot 'dist\portable' }
$ReleaseDir = [IO.Path]::GetFullPath($ReleaseDir)
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$PortableOutputDir = [IO.Path]::GetFullPath($PortableOutputDir)

function Write-Step([string]$message) { Write-Host ('[installer] ' + $message) }

function Ensure-InnoCompiler {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'Inno Setup 6 is missing and winget is unavailable' }
    Write-Step 'install Inno Setup 6'
    $oldHttpProxy = $env:HTTP_PROXY
    $oldHttpsProxy = $env:HTTPS_PROXY
    try {
        if ($Proxy) {
            $env:HTTP_PROXY = $Proxy
            $env:HTTPS_PROXY = $Proxy
        }
        & $winget.Source install --id JRSoftware.InnoSetup --exact --source winget --silent `
            --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw ('winget failed with exit code ' + $LASTEXITCODE) }
    } finally {
        $env:HTTP_PROXY = $oldHttpProxy
        $env:HTTPS_PROXY = $oldHttpsProxy
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    throw 'Inno Setup installed but ISCC.exe was not found'
}

function Convert-ToInnoLiteral([string]$value) {
    return $value.Replace('"', '""')
}

if (-not $SkipReleaseBuild) {
    if ($BuildOfficialSource) {
        Write-Step 'build official source and minimal release payload'
        $officialArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'build-official.ps1'), '-SkipZip')
        if ($Source) { $officialArgs += @('-Source', $Source) }
        if ($Proxy) { $officialArgs += @('-Proxy', $Proxy) }
        & powershell.exe @officialArgs
    } else {
        Write-Step 'build minimal release payload from existing official build'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-release.ps1') -SkipZip
    }
    if ($LASTEXITCODE -ne 0) { throw ('release build failed with exit code ' + $LASTEXITCODE) }
}

$manifestPath = Join-Path $ReleaseDir 'dsh-runtime\meta\release-manifest.json'
$controllerPath = Join-Path $ReleaseDir 'parasite-runtime\dsh.ps1'
$requirementsPath = Join-Path $ReleaseDir 'parasite-runtime\codex-requirements.ps1'
foreach ($requiredPath in @($manifestPath, $controllerPath, $requirementsPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('release payload missing: ' + $requiredPath) }
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$version = [string]$manifest.version
if (-not $version) { throw 'release manifest has no version' }

Write-Step 'validate local ChatGPT dependency surface'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'src\installer\install-preflight.ps1') `
    -ManifestPath $manifestPath -RequirementsScript $requirementsPath
if ($LASTEXITCODE -ne 0) { throw ('ChatGPT preflight failed with exit code ' + $LASTEXITCODE) }

$tempRoot = Join-Path $env:TEMP ('dsh-installer-' + [guid]::NewGuid().ToString('N'))
$payloadDir = Join-Path $tempRoot 'payload'
$generatedIss = Join-Path $tempRoot 'dsh-desktop.generated.iss'
New-Item -ItemType Directory -Force -Path $payloadDir, $OutputDir, $PortableOutputDir | Out-Null
try {
    Get-ChildItem -LiteralPath $OutputDir -Filter 'DSH-Desktop-Setup-*.exe' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $OutputDir -Filter 'DeepSeek-Harness-Setup-*.exe' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $PortableOutputDir -Filter 'DeepSeek-Harness-Portable-*.zip' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Step 'copy static payload without junction targets'
    $reparseFiles = @(Get-ChildItem -LiteralPath $ReleaseDir -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    $robocopyArgs = @(
        $ReleaseDir, $payloadDir, '/E', '/XJ', '/R:1', '/W:1',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP'
    )
    if ($reparseFiles.Count -gt 0) {
        $robocopyArgs += '/XF'
        $robocopyArgs += @($reparseFiles | ForEach-Object { $_.FullName })
    }
    & robocopy @robocopyArgs | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ('payload robocopy failed with exit code ' + $LASTEXITCODE) }
    $copiedReparse = @(Get-ChildItem -LiteralPath $payloadDir -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($copiedReparse.Count -gt 0) { throw ('installer payload contains reparse points: ' + $copiedReparse.Count) }

    Write-Step 'compile x64 GUI launcher'
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw ('C# compiler missing: ' + $csc) }
    $launcherPath = Join-Path $payloadDir 'DeepSeek Harness (on ChatGPT).exe'
    $iconPath = Join-Path $payloadDir 'parasite-runtime\owl-host\resources\app\icon.ico'
    & $csc /nologo /target:winexe /platform:x64 /optimize+ `
        /reference:System.Windows.Forms.dll `
        ('/win32icon:' + $iconPath) `
        ('/out:' + $launcherPath) `
        (Join-Path $repoRoot 'src\installer\DSHDesktopLauncher.cs')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $launcherPath)) {
        throw ('launcher compilation failed with exit code ' + $LASTEXITCODE)
    }

    $portableReadme = @'
# DeepSeek Harness (on ChatGPT) Portable

Extract the entire archive to a normal writable directory, then run `DeepSeek Harness (on ChatGPT).exe`.

Requirements:
- Windows x64
- Microsoft Store ChatGPT/Codex installed for the current user
- Approve UAC when link repair is required

Every start validates the local ChatGPT runtime and recreates stale junctions, symlinks, and copied host files. Existing ChatGPT.exe processes are never modified or terminated.
'@
    [IO.File]::WriteAllText(
        (Join-Path $payloadDir 'README.portable.md'),
        ($portableReadme.Trim() + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false))

    $portablePath = Join-Path $PortableOutputDir ('DeepSeek-Harness-on-ChatGPT-Portable-' + $version + '-win-x64.zip')
    if (Test-Path -LiteralPath $portablePath) { Remove-Item -LiteralPath $portablePath -Force }
    Write-Step 'compress portable package'
    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if ($tar) {
        Push-Location $payloadDir
        try {
            & $tar.Source -a -c -f $portablePath *
            if ($LASTEXITCODE -ne 0) { throw ('portable archive failed with exit code ' + $LASTEXITCODE) }
        } finally {
            Pop-Location
        }
    } else {
        Compress-Archive -Path (Join-Path $payloadDir '*') -DestinationPath $portablePath -Force
    }

    $template = Get-Content -LiteralPath (Join-Path $repoRoot 'src\installer\dsh-desktop.iss') -Raw -Encoding UTF8
    $replacements = @{
        '@@PAYLOAD_DIR@@'     = Convert-ToInnoLiteral $payloadDir
        '@@OUTPUT_DIR@@'      = Convert-ToInnoLiteral $OutputDir
        '@@PRODUCT_VERSION@@' = Convert-ToInnoLiteral $version
        '@@PRODUCT_ICON@@'    = Convert-ToInnoLiteral $iconPath
        '@@PREFLIGHT_SCRIPT@@'= Convert-ToInnoLiteral (Join-Path $repoRoot 'src\installer\install-preflight.ps1')
    }
    foreach ($replacement in $replacements.GetEnumerator()) {
        $template = $template.Replace($replacement.Key, $replacement.Value)
    }
    [IO.File]::WriteAllText($generatedIss, $template, [Text.UTF8Encoding]::new($false))

    $iscc = Ensure-InnoCompiler
    Write-Step 'compile Inno Setup package'
    & $iscc /Qp $generatedIss
    if ($LASTEXITCODE -ne 0) { throw ('ISCC failed with exit code ' + $LASTEXITCODE) }

    $installerPath = Join-Path $OutputDir ('DeepSeek-Harness-on-ChatGPT-Setup-' + $version + '-win-x64.exe')
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw ('installer output missing: ' + $installerPath)
    }
    Write-Step ('DONE ' + $installerPath)
    Write-Step ('installer size {0:N1} MB' -f ((Get-Item -LiteralPath $installerPath).Length / 1MB))
    Write-Step ('portable  ' + $portablePath)
    Write-Step ('portable size {0:N1} MB' -f ((Get-Item -LiteralPath $portablePath).Length / 1MB))
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
