# build-release.ps1
# Harvest a Windows x64 release stage from a built official deepseek-harness tree.
# Product-closure collection: copy built artifacts + private deps (not a recompile).
# Workspace/npm features are filtered by config/release-blacklist.json (blacklist).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 -SkipZip
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 -Source .\.work\deepseek-harness
param(
    [string]$Source = '',
    [string]$OutDir = '',
    [string]$BlacklistFile = '',
    [switch]$SkipZip,
    [switch]$SkipCgLink
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $BlacklistFile) { $BlacklistFile = Join-Path $repoRoot 'config\release-blacklist.json' }

function Write-Step([string]$msg) { Write-Host ('[release] ' + $msg) }

function Resolve-DefaultSource {
    $official = Join-Path $repoRoot '.work\deepseek-harness'
    return $official
}

if (-not $Source) { $Source = Resolve-DefaultSource }
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'dist\stage' }
$Source = [IO.Path]::GetFullPath($Source)
$OutDir = [IO.Path]::GetFullPath($OutDir)
$BlacklistFile = [IO.Path]::GetFullPath($BlacklistFile)

function Get-CodexDesktopPackage {
    $candidates = @(Get-AppxPackage -Name 'OpenAI.Codex*' -ErrorAction SilentlyContinue)
    if (-not $candidates) {
        $candidates = @(Get-AppxPackage -Name 'OpenAI.*' -ErrorAction SilentlyContinue)
    }
    $candidates |
        Where-Object {
            $app = Join-Path $_.InstallLocation 'app'
            (Test-Path -LiteralPath (Join-Path $app 'resources\cua_node\bin\node.exe')) -and
            (Test-Path -LiteralPath (Join-Path $app 'chrome.dll'))
        } |
        Sort-Object {
            try { [version]$_.Version } catch { [version]'0.0.0.0' }
        } -Descending |
        Select-Object -First 1
}

function Get-NodeExecutable {
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCommand) { return $nodeCommand.Source }

    try {
        $package = Get-CodexDesktopPackage
        if ($package) {
            $candidate = Join-Path $package.InstallLocation 'app\resources\cua_node\bin\node.exe'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    } catch {}
    return $null
}

function Get-DefaultCgPackageNames {
    return @(
        '@img/colour','@img/sharp-win32-x64','@napi-rs/canvas','@napi-rs/canvas-win32-x64-msvc',
        'sharp','playwright','playwright-core','pdfjs-dist','tesseract.js','tesseract.js-core',
        'bmp-js','jpeg-js','pngjs','pixelmatch','semver','detect-libc','node-fetch','idb-keyval',
        'is-url','opencollective-postinstall','node-readable-to-web-readable-stream','regenerator-runtime',
        'tr46','webidl-conversions','whatwg-url','zlibjs','wasm-feature-detect'
    )
}

function Test-ProviderImportClosure($package, [string]$runtimeRoot) {
    if (-not $package) { throw 'OpenAI.Codex package missing; cannot verify runtime closure' }
    $nodePath = Join-Path $package.InstallLocation 'app\resources\cua_node\bin\node.exe'
    if (-not (Test-Path -LiteralPath $nodePath)) { throw ('Codex node missing: ' + $nodePath) }

    $token = [guid]::NewGuid().ToString('N')
    $smokeRoot = Join-Path $runtimeRoot 'meta'
    Ensure-Dir $smokeRoot
    $scriptPath = Join-Path $smokeRoot ('dsh-provider-smoke-' + $token + '.mjs')
    $markerPath = Join-Path $smokeRoot ('dsh-provider-smoke-' + $token + '.txt')
    $stdoutPath = Join-Path $smokeRoot ('dsh-provider-smoke-' + $token + '.out.txt')
    $stderrPath = Join-Path $smokeRoot ('dsh-provider-smoke-' + $token + '.err.txt')
    $piRoot = Join-Path $runtimeRoot 'node_modules\@earendil-works\pi-ai\dist\api'
    $modules = @(
        'anthropic-messages.js',
        'bedrock-converse-stream.js',
        'google-generative-ai.js',
        'mistral-conversations.js',
        'openai-completions.js'
    ) | ForEach-Object { ([uri](Join-Path $piRoot $_)).AbsoluteUri }
    $modules += ([uri](Join-Path $runtimeRoot 'packages\bundle\web-app\lib\index.js')).AbsoluteUri
    $moduleJson = $modules | ConvertTo-Json -Compress
    $markerJson = $markerPath | ConvertTo-Json -Compress
    $ptyJson = (Join-Path $runtimeRoot 'node_modules\node-pty\lib\index.js') | ConvertTo-Json -Compress
    $script = @"
import fs from 'node:fs';
import { createRequire } from 'node:module';
const modules = $moduleJson;
const require = createRequire(import.meta.url);

async function testPty() {
  const nodePty = require($ptyJson);
  await new Promise((resolve, reject) => {
    const terminal = nodePty.spawn(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', 'echo DSH_PTY_SMOKE'], {
      name: 'dumb', cols: 80, rows: 24, cwd: process.cwd(), env: process.env,
    });
    let output = '';
    const timer = setTimeout(() => {
      try { terminal.kill(); } catch {}
      reject(new Error('node-pty smoke timed out'));
    }, 10000);
    terminal.onData((data) => { output += data; });
    terminal.onExit(({ exitCode }) => {
      clearTimeout(timer);
      if (exitCode === 0 && output.includes('DSH_PTY_SMOKE')) resolve();
      else reject(new Error('node-pty smoke failed: exit=' + exitCode + ' output=' + JSON.stringify(output)));
    });
  });
}

try {
  await Promise.all(modules.map((module) => import(module)));
  await testPty();
  fs.writeFileSync($markerJson, 'OK');
} catch (error) {
  fs.writeFileSync($markerJson, 'ERROR: ' + (error?.stack || error));
  process.exitCode = 1;
}
"@
    [IO.File]::WriteAllText($scriptPath, $script, [Text.UTF8Encoding]::new($false))
    try {
        $escapedNode = $nodePath.Replace("'", "''")
        $escapedScript = $scriptPath.Replace("'", "''")
        $escapedRuntime = $runtimeRoot.Replace("'", "''")
        $escapedMarker = $markerPath.Replace("'", "''")
        $escapedStdout = $stdoutPath.Replace("'", "''")
        $escapedStderr = $stderrPath.Replace("'", "''")
        $command = @"
`$ErrorActionPreference = 'Stop'
try {
    `$process = Start-Process -FilePath '$escapedNode' -ArgumentList @('$escapedScript') -WorkingDirectory '$escapedRuntime' -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput '$escapedStdout' -RedirectStandardError '$escapedStderr'
    if (`$process.ExitCode -ne 0 -and -not (Test-Path -LiteralPath '$escapedMarker')) {
        `$details = Get-Content -Raw -LiteralPath '$escapedStderr' -ErrorAction SilentlyContinue
        Set-Content -LiteralPath '$escapedMarker' -Value ('ERROR: provider smoke node exit ' + `$process.ExitCode + "`n" + `$details) -NoNewline
    }
} catch {
    Set-Content -LiteralPath '$escapedMarker' -Value ('ERROR: ' + `$_) -NoNewline
}
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Invoke-CommandInDesktopPackage -PackageFamilyName $package.PackageFamilyName -AppId 'App' `
            -Command $powershell -Args ('-NoProfile -EncodedCommand ' + $encoded) -PreventBreakaway | Out-Null
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $markerPath)) {
            Start-Sleep -Milliseconds 200
        }
        if (-not (Test-Path -LiteralPath $markerPath)) { throw 'provider import smoke timed out' }
        $result = Get-Content -Raw -LiteralPath $markerPath
        if ($result -ne 'OK') { throw $result }
    } finally {
        Remove-Item -LiteralPath $scriptPath, $markerPath, $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-ReparseTarget([string]$path) {
    try {
        $item = Get-Item -LiteralPath $path -Force
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
        $t = $item.Target
        if ($t -is [array]) { return [string]$t[0] }
        return [string]$t
    } catch {
        return $null
    }
}

function Remove-Tree([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            try {
                if ($_.PSIsContainer) { cmd /c ('rmdir "' + $_.FullName + '"') | Out-Null }
                else { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            } catch {}
        }
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
}

function Ensure-Dir([string]$path) { New-Item -ItemType Directory -Force -Path $path | Out-Null }

function Copy-FileTo([string]$src, [string]$dst) {
    Ensure-Dir (Split-Path -Parent $dst)
    Copy-Item -LiteralPath $src -Destination $dst -Force
}

function Invoke-Robocopy([string]$src, [string]$dst, [string[]]$extraArgs) {
    Ensure-Dir $dst
    $rcArgs = @($src, $dst, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP', '/XJ') + $extraArgs
    & robocopy @rcArgs | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) { throw ("robocopy failed ($code): $src -> $dst") }
    return $code
}

function Copy-WorkspacePackageTree([string]$srcRoot, [string]$dstRoot) {
    if (-not (Test-Path -LiteralPath $srcRoot)) { return }
    $xd = @('node_modules','tests','test','__tests__','src','fixtures','coverage','.turbo','.git','docs','examples','example')
    $xf = @('*.map','*.ts','*.tsx','*.tsbuildinfo','tsconfig.json','tsconfig*.json','vitest*.ts','tsdown.config.*','*.spec.js','*.test.js','*.e2e.ts','*.snapshot.ts','README.md','README.zh.md','README.i18n.yaml','AGENTS.md','composition.md','package.json.bak')
    $extra = @()
    foreach ($d in $xd) { $extra += @('/XD', $d) }
    foreach ($f in $xf) { $extra += @('/XF', $f) }
    Invoke-Robocopy $srcRoot $dstRoot $extra | Out-Null
}

function Copy-PrivatePackage([string]$src, [string]$dst) {
    $xd = @('test','tests','__tests__','.yarn','.github','docs','example','examples','coverage','benchmark','benchmarks','fixtures','darwin-arm64','darwin-x64','linux-arm64','linux-x64','linux-arm','linux-arm64-gnu','linux-x64-gnu','win32-arm64','win32-ia32','android-arm','android-arm64','prebuilds\darwin-arm64','prebuilds\darwin-x64','prebuilds\linux-x64','prebuilds\linux-arm64','prebuilds\win32-arm64','win10-arm64')
    $xf = @('*.md','*.markdown','*.map','*.ts','*.tsx','*.d.mts','*.d.cts','*.tsbuildinfo','*.development.js','*.development.min.js','html5lib-tests.json','.DS_Store','LICENSE-MIT','CHANGELOG*','CONTRIBUTING*')
    $extra = @()
    foreach ($d in $xd) { $extra += @('/XD', $d) }
    foreach ($f in $xf) { $extra += @('/XF', $f) }
    Invoke-Robocopy $src $dst $extra | Out-Null
}

function Remove-PrivateRuntimeResidue([string]$nmRoot, [string[]]$packageNames) {
    $stats = [pscustomobject]@{ files = 0; bytes = [int64]0 }

    function Remove-RuntimeFile([string]$path) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $stats.bytes += (Get-Item -LiteralPath $path -Force).Length
        Remove-Item -LiteralPath $path -Force
        $stats.files++
    }

    function Remove-RuntimeTree([string]$path) {
        if (-not (Test-Path -LiteralPath $path)) { return }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        $sum = (Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
        if ($sum) { $stats.bytes += $sum }
        Remove-Item -LiteralPath $path -Recurse -Force
    }

    foreach ($packageName in $packageNames) {
        $packageRoot = Join-Path $nmRoot ($packageName -replace '/', '\')
        if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) { continue }
        $packageItem = Get-Item -LiteralPath $packageRoot -Force
        if ($packageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }

        $queue = [Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($packageRoot)
        while ($queue.Count -gt 0) {
            $directory = $queue.Dequeue()
            foreach ($entry in Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue) {
                if ($entry.PSIsContainer) {
                    if ($entry.Name -eq '.bin' -and (Split-Path -Leaf $entry.Parent.FullName) -eq 'node_modules') {
                        Remove-RuntimeTree $entry.FullName
                    } elseif (-not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        $queue.Enqueue($entry.FullName)
                    }
                    continue
                }
                $lowerName = $entry.Name.ToLowerInvariant()
                if ($lowerName -match '\.d\.(ts|mts|cts)$' -or
                    $lowerName.EndsWith('.tsbuildinfo') -or
                    $lowerName.EndsWith('.map') -or
                    $lowerName -match '(^|\.)(test|spec|e2e|fixture)\.js$') {
                    Remove-RuntimeFile $entry.FullName
                }
            }
        }
    }

    $koffi = Join-Path $nmRoot 'koffi'
    foreach ($relativePath in @('cnoke.cjs', 'doc', 'lib', 'vendor', 'src\koffi\CMakeLists.txt')) {
        Remove-RuntimeTree (Join-Path $koffi $relativePath)
    }
    Remove-RuntimeTree (Join-Path $nmRoot 'node-addon-api')
    Remove-RuntimeTree (Join-Path $nmRoot 'bignumber.js\doc')

    $googleGenAiDist = Join-Path $nmRoot '@google\genai\dist'
    foreach ($relativePath in @(
        'index.cjs', 'index.mjs', 'web', 'node\index.cjs', 'tokenizer', 'vertex_internal'
    )) {
        Remove-RuntimeTree (Join-Path $googleGenAiDist $relativePath)
    }
    Get-ChildItem -LiteralPath (Join-Path $nmRoot 'openai') -Recurse -Force -File -Filter '*.js' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-RuntimeFile $_.FullName }

    return [pscustomobject]@{
        files = $stats.files
        bytes = $stats.bytes
        mb = [math]::Round($stats.bytes / 1MB, 2)
    }
}

function New-JunctionSafe([string]$linkPath, [string]$targetPath) {
    if (-not (Test-Path -LiteralPath $targetPath)) { throw ("junction target missing: $targetPath") }
    Ensure-Dir (Split-Path -Parent $linkPath)
    if (Test-Path -LiteralPath $linkPath) {
        $item = Get-Item -LiteralPath $linkPath -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            cmd /c ('rmdir "' + $linkPath + '"') | Out-Null
        } else {
            Remove-Item -LiteralPath $linkPath -Recurse -Force
        }
    }
    New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
}


function Get-LineIndent([string]$line) {
    if ($line -match '^(?<ind>[ \t]*)') { return $Matches['ind'].Length }
    return 0
}

function Import-ReleaseBlacklist([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw ("blacklist file missing: " + $path) }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    $json = $raw | ConvertFrom-Json
    $wsNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $wsPrefixes = New-Object 'System.Collections.Generic.List[string]'
    $npmNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $npmScopes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $scrubNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $keepNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in @($json.workspacePackageNames)) { if ($x) { [void]$wsNames.Add([string]$x) } }
    foreach ($x in @($json.workspacePathPrefixes)) {
        if (-not $x) { continue }
        $p = ([string]$x) -replace '\\', '/'
        if (-not $p.EndsWith('/')) { $p += '/' }
        $wsPrefixes.Add($p) | Out-Null
    }
    foreach ($x in @($json.npmPackages)) { if ($x) { [void]$npmNames.Add([string]$x) } }
    foreach ($x in @($json.npmScopes)) { if ($x) { [void]$npmScopes.Add([string]$x) } }
    foreach ($x in @($json.scrubCordisPluginNames)) { if ($x) { [void]$scrubNames.Add([string]$x) } }
    foreach ($x in @($json.keepWorkspacePackages)) { if ($x) { [void]$keepNames.Add([string]$x) } }
    foreach ($x in $wsNames) { [void]$scrubNames.Add($x) }
    return [pscustomobject]@{
        workspacePackageNames  = $wsNames
        workspacePathPrefixes  = $wsPrefixes
        npmPackages            = $npmNames
        npmScopes              = $npmScopes
        scrubCordisPluginNames = $scrubNames
        keepWorkspacePackages  = $keepNames
        description            = [string]$json.description
    }
}

function Test-WorkspacePathBlacklisted([string]$relPosix, $blacklist) {
    $rel = ($relPosix -replace '\\', '/').TrimStart('/')
    $relTest = if ($rel.EndsWith('/')) { $rel } else { $rel + '/' }
    foreach ($prefix in $blacklist.workspacePathPrefixes) {
        if ($relTest.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($rel.Equals($prefix.TrimEnd('/'), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-NpmNameBlacklisted([string]$name, $blacklist) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    $n = $name -replace '\\', '/'
    if ($blacklist.npmPackages.Contains($n)) { return $true }
    if ($n.StartsWith('@')) {
        $scope = $n.Split('/')[0]
        if ($blacklist.npmScopes.Contains($scope)) { return $true }
    }
    return $false
}

function Find-WorkspacePackages([string]$root) {
    $map = New-Object 'System.Collections.Generic.List[object]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    foreach ($top in @('packages', 'vendor', 'native', 'apps')) {
        $p = Join-Path $root $top
        if (Test-Path -LiteralPath $p) { $stack.Push($p) }
    }
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $pj = Join-Path $dir 'package.json'
        if (Test-Path -LiteralPath $pj) {
            try {
                $j = Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($j.name) {
                    $rel = [IO.Path]::GetFullPath($dir).Substring([IO.Path]::GetFullPath($root).Length).TrimStart([char]'\', [char]'/')
                    $map.Add([pscustomobject]@{ name = [string]$j.name; rel = ($rel -replace '\\', '/'); full = $dir }) | Out-Null
                }
            } catch {}
        }
        Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -in @('node_modules', '.git', 'dist', 'build', 'coverage', 'src', 'tests', 'test', 'fixtures')) { return }
            $stack.Push($_.FullName)
        }
    }
    return $map
}

function Remove-BlacklistedWorkspaceFromStage([string]$stageRoot, [string]$sourceRoot, $blacklist) {
    $removed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pkg in (Find-WorkspacePackages $sourceRoot)) {
        $byName = $blacklist.workspacePackageNames.Contains($pkg.name)
        $byPath = Test-WorkspacePathBlacklisted $pkg.rel $blacklist
        if (-not ($byName -or $byPath)) { continue }
        if ($blacklist.keepWorkspacePackages.Contains($pkg.name)) { continue }
        $dst = Join-Path $stageRoot (($pkg.rel -replace '/', '\'))
        if (Test-Path -LiteralPath $dst) {
            Remove-Tree $dst
            $removed.Add($pkg.name + ' <= ' + $pkg.rel) | Out-Null
        }
    }
    foreach ($prefix in $blacklist.workspacePathPrefixes) {
        $dst = Join-Path $stageRoot (($prefix.TrimEnd('/') -replace '/', '\'))
        if (Test-Path -LiteralPath $dst) {
            Remove-Tree $dst
            $mark = 'path:' + $prefix.TrimEnd('/')
            if (-not ($removed -contains $mark)) { $removed.Add($mark) | Out-Null }
        }
    }
    return @($removed)
}

function Remove-BlacklistedCordisPlugins([string]$file, $scrubNames) {
    if (-not (Test-Path -LiteralPath $file)) { return 0 }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($ln in Get-Content -LiteralPath $file -Encoding UTF8) { $lines.Add($ln) | Out-Null }
    $removed = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^[ \t]*name:\s*[''\"]?([^''\"\s]+)[''\"]?\s*$') { continue }
        $pkg = $Matches[1]
        if (-not $scrubNames.Contains($pkg)) { continue }
        $nameIndent = Get-LineIndent $lines[$i]
        $start = $i
        for ($j = $i - 1; $j -ge 0; $j--) {
            $l = $lines[$j]
            if ($l -match '^[ \t]*$') { continue }
            if ($l -match '^[ \t]*- ') {
                $ind = Get-LineIndent $l
                if ($ind -lt $nameIndent) { $start = $j; break }
            }
            if ((Get-LineIndent $l) -lt $nameIndent) { break }
        }
        # Keep surrounding comments. Walking backwards through blank/comment
        # lines can reach an unindented section comment, making itemIndent=0 and
        # accidentally deleting every following list item.
        $itemIndent = Get-LineIndent $lines[$start]
        $end = $start
        for ($k = $start + 1; $k -lt $lines.Count; $k++) {
            $l = $lines[$k]
            if ($l -match '^[ \t]*$') { $end = $k; continue }
            $ind = Get-LineIndent $l
            if ($ind -le $itemIndent -and $l -match '^[ \t]*- ') { break }
            if ($ind -le $itemIndent -and $l -notmatch '^[ \t]*#') { break }
            $end = $k
        }
        $lines.RemoveRange($start, $end - $start + 1)
        $removed++
        $i = $start - 1
    }
    if ($removed -gt 0) {
        $full = (Resolve-Path -LiteralPath $file).Path
        [IO.File]::WriteAllText($full, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    }
    return $removed
}

function Scrub-StageCompositions([string]$stageRoot, $scrubNames) {
    $total = 0
    $files = Get-ChildItem -LiteralPath $stageRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.yml', '.yaml') -and $_.FullName -notmatch '[\\/]node_modules[\\/]' }
    foreach ($f in @($files)) {
        $n = Remove-BlacklistedCordisPlugins $f.FullName $scrubNames
        if ($n -gt 0) {
            Write-Step ('scrubbed ' + $n + ' cordis plugin row(s) from ' + $f.FullName.Substring($stageRoot.Length).TrimStart('\'))
            $total += $n
        }
    }
    return $total
}

function Remove-BlacklistedManifestDependencies([string]$stageRoot, $blacklist) {
    $removed = New-Object 'System.Collections.Generic.List[string]'
    $dependencySections = @('dependencies', 'optionalDependencies', 'peerDependencies', 'devDependencies')
    $manifestFiles = Get-ChildItem -LiteralPath $stageRoot -Recurse -File -Filter 'package.json' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' }

    foreach ($manifestFile in @($manifestFiles)) {
        try {
            $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw ('invalid staged package manifest: ' + $manifestFile.FullName + ' :: ' + $_)
        }

        $changed = $false
        foreach ($sectionName in $dependencySections) {
            $section = $manifest.$sectionName
            if (-not $section) { continue }
            foreach ($packageName in $blacklist.workspacePackageNames) {
                if ($blacklist.keepWorkspacePackages.Contains($packageName)) { continue }
                if ($section.PSObject.Properties.Name -notcontains $packageName) { continue }
                $section.PSObject.Properties.Remove($packageName)
                $relativeManifest = $manifestFile.FullName.Substring($stageRoot.Length).TrimStart('\') -replace '\\', '/'
                $removed.Add($relativeManifest + ' :: ' + $sectionName + ' :: ' + $packageName) | Out-Null
                $changed = $true
            }
        }

        if ($changed) {
            $json = $manifest | ConvertTo-Json -Depth 100
            [IO.File]::WriteAllText($manifestFile.FullName, ($json + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        }
    }
    return @($removed)
}

function Remove-EmptyNpmScopes([string]$nodeModulesRoot, [string[]]$scopeNames) {
    foreach ($scopeName in $scopeNames) {
        $scopePath = Join-Path $nodeModulesRoot $scopeName
        if (-not (Test-Path -LiteralPath $scopePath)) { continue }
        $children = @(Get-ChildItem -LiteralPath $scopePath -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) {
            Remove-Item -LiteralPath $scopePath -Force -ErrorAction SilentlyContinue
        }
    }
}


$blacklist = Import-ReleaseBlacklist $BlacklistFile
Write-Step ('blacklist = ' + $BlacklistFile)
if ($blacklist.description) { Write-Step $blacklist.description }

if (-not (Test-Path -LiteralPath (Join-Path $Source 'apps\cli\lib\bin.js'))) {
    throw @"
Source does not look like a built DSH runtime tree (missing apps\cli\lib\bin.js):
  $Source

Run .\build.ps1 for the complete clone, build, harvest, and package flow.
For a manually prepared clone, build upstream and pass it with -Source.
"@
}
if (-not (Test-Path -LiteralPath (Join-Path $Source 'node_modules'))) {
    throw ("Source missing node_modules: $Source")
}

$version = '0.0.0'
$cliPkg = Join-Path $Source 'apps\cli\package.json'
$rootPkg = Join-Path $Source 'package.json'
if (Test-Path -LiteralPath $cliPkg) {
    try { $version = (Get-Content -LiteralPath $cliPkg -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
}
if (($version -eq '0.0.0') -and (Test-Path -LiteralPath $rootPkg)) {
    try { $version = (Get-Content -LiteralPath $rootPkg -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
}

$sourceLabel = Split-Path -Leaf ([IO.Path]::GetFullPath($Source))
$sourceCommit = ''
try {
    $sourceCommit = (& git -C $Source rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
} catch {}
Write-Step ("source = " + $Source + ' (' + $sourceLabel + ')')
Write-Step ("out    = " + $OutDir)
Write-Step ("version= " + $version)

Remove-Tree $OutDir
Ensure-Dir $OutDir

$dshRuntime = Join-Path $OutDir 'dsh-runtime'
$metaDir = Join-Path $dshRuntime 'meta'
Ensure-Dir $metaDir

Write-Step 'harvest workspace apps/packages/vendor'
Ensure-Dir (Join-Path $dshRuntime 'apps\cli')
Invoke-Robocopy (Join-Path $Source 'apps\cli\lib') (Join-Path $dshRuntime 'apps\cli\lib') @() | Out-Null
if (Test-Path (Join-Path $Source 'apps\cli\config')) {
    Invoke-Robocopy (Join-Path $Source 'apps\cli\config') (Join-Path $dshRuntime 'apps\cli\config') @() | Out-Null
}
Copy-FileTo (Join-Path $Source 'apps\cli\package.json') (Join-Path $dshRuntime 'apps\cli\package.json')

Ensure-Dir (Join-Path $dshRuntime 'apps\web')
if (Test-Path (Join-Path $Source 'apps\web\dist')) {
    Invoke-Robocopy (Join-Path $Source 'apps\web\dist') (Join-Path $dshRuntime 'apps\web\dist') @('/XF', '*.map') | Out-Null
} else {
    throw 'apps\web\dist missing - build upstream web frontend first'
}
if (Test-Path (Join-Path $Source 'apps\web\package.json')) {
    Copy-FileTo (Join-Path $Source 'apps\web\package.json') (Join-Path $dshRuntime 'apps\web\package.json')
}

if (Test-Path (Join-Path $Source 'packages')) { Copy-WorkspacePackageTree (Join-Path $Source 'packages') (Join-Path $dshRuntime 'packages') }
if (Test-Path (Join-Path $Source 'vendor')) { Copy-WorkspacePackageTree (Join-Path $Source 'vendor') (Join-Path $dshRuntime 'vendor') }
if (Test-Path (Join-Path $Source 'native')) { Copy-WorkspacePackageTree (Join-Path $Source 'native') (Join-Path $dshRuntime 'native') }

Write-Step 'apply workspace blacklist'
$excludedWorkspace = @(Remove-BlacklistedWorkspaceFromStage $dshRuntime $Source $blacklist)
Write-Step ('excluded workspace packages/paths: ' + $excludedWorkspace.Count)
foreach ($x in $excludedWorkspace) { Write-Step ('  - ' + $x) }

foreach ($name in @('package.json', 'pnpm-workspace.yaml', '.npmrc')) {
    $p = Join-Path $Source $name
    if (Test-Path -LiteralPath $p) { Copy-FileTo $p (Join-Path $dshRuntime $name) }
}

$patchesSource = Join-Path $Source 'patches'
if (Test-Path -LiteralPath $patchesSource -PathType Container) {
    Write-Step 'stage pnpm patches'
    Invoke-Robocopy $patchesSource (Join-Path $dshRuntime 'patches') @() | Out-Null
}
else {
    throw ('Source is missing required pnpm patches directory: ' + $patchesSource)
}
$workspaceManifest = Join-Path $dshRuntime 'pnpm-workspace.yaml'
$patchReferences = @(Select-String -Path $workspaceManifest -Pattern 'patches/[^\s]+' -AllMatches -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Matches | ForEach-Object { $_.Value } } | Sort-Object -Unique)
foreach ($patchReference in $patchReferences) {
    $patchPath = Join-Path $dshRuntime ($patchReference -replace '/', '\')
    if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
        throw ('pnpm patch reference is missing from release runtime: ' + $patchReference)
    }
}

# Profile workspaces are out-of-tree plugin projects. They must not inherit the
# root workspace's build-only node-pty patch when installing unrelated plugins.
$profileBootLib = Join-Path $dshRuntime 'packages\boot\app-boot\lib\index.js'
if (Test-Path -LiteralPath $profileBootLib -PathType Leaf) {
    $profileText = Get-Content -LiteralPath $profileBootLib -Raw -Encoding UTF8
    $profileText = $profileText.Replace("nodeLinker: hoisted`nautoInstallPeers: false`n", "nodeLinker: hoisted`nautoInstallPeers: false`npatchedDependencies: {}`n")
    [IO.File]::WriteAllText($profileBootLib, $profileText, [Text.UTF8Encoding]::new($false))
}

Write-Step 'stage DSH CLI wrappers + Corepack downloader'
$toolsRoot = Join-Path $dshRuntime 'tools'
$toolsBin = Join-Path $toolsRoot 'bin'
Ensure-Dir $toolsBin
Copy-FileTo (Join-Path $repoRoot 'src\cli\dsh.cmd') (Join-Path $toolsBin 'dsh.cmd')
Copy-FileTo (Join-Path $repoRoot 'src\cli\pnpm.cmd') (Join-Path $toolsBin 'pnpm.cmd')
$corepackPackage = Get-CodexDesktopPackage
if (-not $corepackPackage) { throw 'OpenAI.Codex package missing; cannot stage Corepack downloader' }
$corepackSource = Join-Path $corepackPackage.InstallLocation 'app\resources\cua_node\bin\node_modules\corepack'
if (-not (Test-Path -LiteralPath (Join-Path $corepackSource 'dist\corepack.js') -PathType Leaf)) {
    throw ('ChatGPT Corepack downloader is missing: ' + $corepackSource)
}
Invoke-Robocopy $corepackSource (Join-Path $toolsRoot 'corepack') @() | Out-Null

Write-Step 'scrub blacklisted workspace dependencies from package manifests'
$manifestDepsScrubbed = @(Remove-BlacklistedManifestDependencies $dshRuntime $blacklist)
Write-Step ('package manifest dependencies removed: ' + $manifestDepsScrubbed.Count)

Write-Step 'scrub cordis compositions for blacklisted plugins'
$scrubbed = Scrub-StageCompositions $dshRuntime $blacklist.scrubCordisPluginNames
Write-Step ('cordis plugin rows removed: ' + $scrubbed)

Write-Step 'seed .dshhome'
$homeSrc = Join-Path $Source '.dshhome'
$homeDst = Join-Path $dshRuntime '.dshhome'
Ensure-Dir $homeDst
Ensure-Dir (Join-Path $homeDst 'sessions')
Ensure-Dir (Join-Path $homeDst 'storages')
Ensure-Dir (Join-Path $homeDst 'profiles\web')
foreach ($f in @('settings.yaml')) {
    $p = Join-Path $homeSrc $f
    if (Test-Path -LiteralPath $p) { Copy-FileTo $p (Join-Path $homeDst $f) }
}
$webProf = Join-Path $homeSrc 'profiles\web'
if (Test-Path -LiteralPath $webProf) {
    Get-ChildItem -LiteralPath $webProf -File -Force | ForEach-Object {
        Copy-FileTo $_.FullName (Join-Path $homeDst ('profiles\web\' + $_.Name))
    }
}
if (-not (Test-Path (Join-Path $homeDst 'settings.yaml'))) {
    Set-Content -LiteralPath (Join-Path $homeDst 'settings.yaml') -Value '{}' -Encoding UTF8
}
$webPkg = Join-Path $homeDst 'profiles\web\package.json'
if (-not (Test-Path -LiteralPath $webPkg)) {
    $seedObj = [ordered]@{
        name = 'dsh-profile-web'
        private = $true
        dependencies = @{}
        dsh = @{ profile = @{ bundles = @('@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app') } }
    }
    $seed = ($seedObj | ConvertTo-Json -Depth 6)
    [IO.File]::WriteAllText($webPkg, $seed + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
$webCordis = Join-Path $homeDst 'profiles\web\cordis.yml'
if (-not (Test-Path -LiteralPath $webCordis)) {
    [IO.File]::WriteAllText($webCordis, ('[]' + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}
$webPatch = Join-Path $homeDst 'profiles\web\cordis.patch.yml'
if (-not (Test-Path -LiteralPath $webPatch)) {
    [IO.File]::WriteAllText($webPatch, ('[]' + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}
$webWorkspace = Join-Path $homeDst 'profiles\web\pnpm-workspace.yaml'
if (-not (Test-Path -LiteralPath $webWorkspace)) {
    [IO.File]::WriteAllText($webWorkspace, "packages:`n  - .`n`nnodeLinker: hoisted`nautoInstallPeers: false`npatchedDependencies: {}`n", [Text.UTF8Encoding]::new($false))
}


Write-Step 'classify node_modules (private vs CG vs workspace)'
$srcNm = Join-Path $Source 'node_modules'
$dstNm = Join-Path $dshRuntime 'node_modules'
Ensure-Dir $dstNm

$sourceFull = [IO.Path]::GetFullPath($Source)
$cgJunctions = New-Object System.Collections.Generic.List[object]
$workspaceLinks = New-Object System.Collections.Generic.List[object]
$privatePackages = New-Object System.Collections.Generic.List[string]
$skippedEmptyScopes = New-Object System.Collections.Generic.List[string]
$excludedNpm = New-Object System.Collections.Generic.List[string]
$excludedWorkspaceLinks = New-Object System.Collections.Generic.List[string]

function Add-CgJunction([string]$relPath, [string]$fromCg, [string]$version) {
    $cgJunctions.Add([ordered]@{
            path    = ($relPath -replace '\\', '/')
            fromCg  = ($fromCg -replace '\\', '/')
            version = $version
        }) | Out-Null
}

function Read-PkgVersion([string]$dir) {
    $pj = Join-Path $dir 'package.json'
    if (-not (Test-Path -LiteralPath $pj)) { return $null }
    try { return (Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { return $null }
}

function Convert-CgRelative([string]$target) {
    if ($target -match 'cua_node\\bin\\node_modules\\(.+)$') { return $Matches[1] }
    if ($target -match 'cua_node/bin/node_modules/(.+)$') { return $Matches[1] }
    return $null
}

function Convert-WorkspaceRelative([string]$target, [string]$linkPath = '') {
    $full = $null
    try {
        if ([IO.Path]::IsPathRooted($target)) { $full = [IO.Path]::GetFullPath($target) }
        elseif ($linkPath) { $full = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $linkPath) $target)) }
        else { $full = [IO.Path]::GetFullPath($target) }
    } catch { return $null }
    if ($full.StartsWith($sourceFull, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($sourceFull.Length).TrimStart([char]'\', [char]'/')
        $norm = ($rel -replace '\\', '/')
        if ($norm -match '^(packages|vendor|apps|native)(/|$)') { return $rel }
        return $null
    }
    return $null
}

function Process-NmEntry([string]$srcPath, [string]$relFromNm) {
    $pkgName = ($relFromNm -replace '\\', '/')

    if (Test-NpmNameBlacklisted $pkgName $blacklist) {
        $excludedNpm.Add($pkgName) | Out-Null
        return
    }

    $target = Get-ReparseTarget $srcPath
    if ($target) {
        $cgRel = Convert-CgRelative $target
        if ($cgRel) {
            $ver = Read-PkgVersion $srcPath
            Add-CgJunction ('node_modules\' + $relFromNm) $cgRel $ver
            return
        }
        $wsRel = Convert-WorkspaceRelative $target $srcPath
        if ($wsRel) {
            $wsPosix = ($wsRel -replace '\\', '/')
            $pj = Join-Path $srcPath 'package.json'
            $wsName = $null
            if (Test-Path -LiteralPath $pj) {
                try { $wsName = (Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json).name } catch {}
            }
            $drop = $false
            if ($wsName -and $blacklist.workspacePackageNames.Contains([string]$wsName) -and -not $blacklist.keepWorkspacePackages.Contains([string]$wsName)) { $drop = $true }
            if (Test-WorkspacePathBlacklisted $wsPosix $blacklist) { $drop = $true }
            if ($drop) {
                $excludedWorkspaceLinks.Add($pkgName + ' -> ' + $wsPosix) | Out-Null
                return
            }
            $workspaceLinks.Add([ordered]@{
                    path   = (('node_modules\' + $relFromNm) -replace '\\', '/')
                    target = $wsPosix
                }) | Out-Null
            return
        }
        # pnpm shamefully-hoist / isolated layout: symlink into .pnpm store
        $fullTarget = $null
        try {
            if ([IO.Path]::IsPathRooted($target)) { $fullTarget = [IO.Path]::GetFullPath($target) }
            else { $fullTarget = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $srcPath) $target)) }
        } catch { $fullTarget = $target }
        if ($fullTarget -match '[\\/]\.pnpm[\\/]') {
            if (-not (Test-Path -LiteralPath $fullTarget)) {
                Write-Step ('WARN broken pnpm link: ' + $relFromNm + ' -> ' + $target)
                return
            }
            $item = Get-Item -LiteralPath $fullTarget -Force
            if (-not $item.PSIsContainer) {
                Copy-FileTo $fullTarget (Join-Path $dstNm $relFromNm)
                return
            }
            $privatePackages.Add(($relFromNm -replace '\\', '/')) | Out-Null
            Copy-PrivatePackage $fullTarget (Join-Path $dstNm $relFromNm)
            return
        }
        Write-Step ('WARN skip unknown link: ' + $relFromNm + ' -> ' + $target)
        return
    }

    if (-not (Get-Item -LiteralPath $srcPath -Force).PSIsContainer) {
        Copy-FileTo $srcPath (Join-Path $dstNm $relFromNm)
        return
    }

    $kids = @(Get-ChildItem -LiteralPath $srcPath -Force -ErrorAction SilentlyContinue)
    if ($kids.Count -eq 0 -and $relFromNm.StartsWith('@')) {
        $skippedEmptyScopes.Add($relFromNm) | Out-Null
        return
    }

    $privatePackages.Add(($relFromNm -replace '\\', '/')) | Out-Null
    Copy-PrivatePackage $srcPath (Join-Path $dstNm $relFromNm)
}

foreach ($item in @(Get-ChildItem -LiteralPath $srcNm -Force)) {
    if ($item.Name -in @('.bin', '.package-lock.json', '.pnpm', '.modules.yaml') -or $item.Name.StartsWith('.')) { continue }

    if ($item.Name.StartsWith('@') -and $item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        if ($blacklist.npmScopes.Contains($item.Name)) {
            $excludedNpm.Add($item.Name + '/*') | Out-Null
            continue
        }
        $scopeKids = @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue)
        if ($scopeKids.Count -eq 0) {
            $skippedEmptyScopes.Add($item.Name) | Out-Null
            continue
        }
        foreach ($child in $scopeKids) {
            Process-NmEntry $child.FullName (Join-Path $item.Name $child.Name)
        }
        continue
    }

    Process-NmEntry $item.FullName $item.Name
}

Write-Step ('CG junctions recorded: ' + $cgJunctions.Count)
Write-Step ('workspace links:       ' + $workspaceLinks.Count)
Write-Step ('private packages:      ' + $privatePackages.Count)
Write-Step ('empty scopes skipped:  ' + $skippedEmptyScopes.Count)
Write-Step ('npm blacklist drops:   ' + $excludedNpm.Count)
Write-Step ('workspace link drops:  ' + $excludedWorkspaceLinks.Count)



function Ensure-DefaultCgJunctions([string]$cgNmPath) {
    if (-not $cgNmPath -or -not (Test-Path -LiteralPath $cgNmPath)) { return }
    $defaults = Get-DefaultCgPackageNames
    $existing = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($j in $cgJunctions) { [void]$existing.Add([string]$j.fromCg) }
    $added = 0
    foreach ($name in $defaults) {
        if ($existing.Contains($name)) { continue }
        $cgPath = Join-Path $cgNmPath (($name -replace '/', '\'))
        if (-not (Test-Path -LiteralPath $cgPath)) { continue }
        $ver = Read-PkgVersion $cgPath
        Add-CgJunction ('node_modules\' + ($name -replace '/', '\')) $name $ver
        # drop private copy if present
        $priv = Join-Path $dstNm (($name -replace '/', '\'))
        if (Test-Path -LiteralPath $priv) {
            $it = Get-Item -LiteralPath $priv -Force
            if (-not ($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Tree $priv }
        }
        $added++
    }
    Write-Step ('default CG junctions added: ' + $added)
}

function Promote-CgPackagesFromLocal([string]$stageNm, [string]$cgNmPath) {
    if (-not $cgNmPath -or -not (Test-Path -LiteralPath $cgNmPath)) {
        Write-Step 'CG promote skipped (no local Codex node_modules)'
        return
    }
    Write-Step ('promote private packages present in CG: ' + $cgNmPath)
    $promoted = 0
    function Consider([string]$rel) {
        $srcPrivate = Join-Path $stageNm (($rel -replace '/', '\'))
        $srcCg = Join-Path $cgNmPath (($rel -replace '/', '\'))
        if (-not (Test-Path -LiteralPath $srcPrivate)) { return }
        if (-not (Test-Path -LiteralPath $srcCg)) { return }
        $it = Get-Item -LiteralPath $srcPrivate -Force
        if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        Remove-Tree $srcPrivate
        $ver = Read-PkgVersion $srcCg
        Add-CgJunction ('node_modules\' + ($rel -replace '/', '\')) $rel $ver
        $promoted++
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $stageNm -Force -ErrorAction SilentlyContinue)) {
        if ($item.Name.StartsWith('.')) { continue }
        if ($item.Name.StartsWith('@') -and $item.PSIsContainer) {
            # whole-scope promote if CG has whole scope dir and we have only dirs? prefer per-package
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue)) {
                Consider ($item.Name + '/' + $child.Name)
            }
            # cleanup empty scope
            $kids = @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue)
            if ($kids.Count -eq 0) { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue }
            continue
        }
        Consider $item.Name
    }
    Write-Step ('CG promoted: ' + $promoted)
}

$pkgForPromote = Get-CodexDesktopPackage
$cgNmForPromote = $null
if ($pkgForPromote) { $cgNmForPromote = Join-Path $pkgForPromote.InstallLocation 'app\resources\cua_node\bin\node_modules' }
Promote-CgPackagesFromLocal $dstNm $cgNmForPromote
Ensure-DefaultCgJunctions $cgNmForPromote

Write-Step 'slim private packages for CG asset forks'
# Keep tiny package shells; heavy natives are forked from ChatGPT package at start.
$rgWin = Join-Path $dstNm '@vscode\ripgrep-win32-x64'
if (Test-Path -LiteralPath $rgWin) {
    $binDir = Join-Path $rgWin 'bin'
    Ensure-Dir $binDir
    $exe = Join-Path $binDir 'rg.exe'
    if (Test-Path -LiteralPath $exe) {
        $it = Get-Item -LiteralPath $exe -Force
        if (-not ($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
        }
    }
}
$ptyDir = Join-Path $dstNm 'node-pty'
if (Test-Path -LiteralPath $ptyDir) {
    foreach ($drop in @('third_party', 'src', 'deps', 'build')) {
        $dropPath = Join-Path $ptyDir $drop
        if (Test-Path -LiteralPath $dropPath) {
            $it = Get-Item -LiteralPath $dropPath -Force
            if (-not ($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                Remove-Item -LiteralPath $dropPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $prebuilds = Join-Path $ptyDir 'prebuilds'
    $win32X64 = Join-Path $prebuilds 'win32-x64'
    $nativeKeep = @('conpty.node', 'conpty_console_list.node')
    if (-not (Test-Path -LiteralPath $win32X64 -PathType Container)) {
        throw 'node-pty win32-x64 prebuilds are missing'
    }
    Get-ChildItem -LiteralPath $prebuilds -Force | Where-Object { $_.Name -ne 'win32-x64' } |
        Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $win32X64 -Force | Where-Object { $_.PSIsContainer -or $_.Name -notin $nativeKeep } |
        Remove-Item -Recurse -Force
    foreach ($nativeName in $nativeKeep) {
        if (-not (Test-Path -LiteralPath (Join-Path $win32X64 $nativeName) -PathType Leaf)) {
            throw ('node-pty native prebuild is missing: ' + $nativeName)
        }
    }
}


$browserDrop = @(
    'shiki','katex','react','react-dom','scheduler','loose-envify','csstype','use-sync-external-store',
    '@shikijs\langs','@shikijs\themes','@shikijs\core','@shikijs\engine-oniguruma','@shikijs\engine-javascript',
    '@shikijs\types','@shikijs\primitive','@shikijs\vscode-textmate',
    '@types\react','@types\react-dom','@types\prop-types','@types\katex',
    '@tanstack\react-virtual','@tanstack\virtual-core'
)
$emptyNpmScopes = @(
    '@shikijs','@types','@tanstack','@opentelemetry','@anthropic-ai','@esbuild','@vitest',
    '@asamuzakjp','@csstools','@testing-library','@oxc-project'
)

Write-Step 'ensure missing runtime deps from source .pnpm / unhoisted packages'
$ensureScript = Join-Path $PSScriptRoot 'lib\ensure-missing-nm.js'
$runtimeNode = Get-NodeExecutable
$browserDropCsv = (($browserDrop | ForEach-Object { ($_ -replace '\\','/') }) -join ',')
$ensuredMissing = @()
if ((Test-Path -LiteralPath $ensureScript) -and $runtimeNode) {
    $cgPkgCsv = ((Get-DefaultCgPackageNames) -join ',')
    $ensureOut = & $runtimeNode $ensureScript $Source $dshRuntime $BlacklistFile ('--browser-drop=' + $browserDropCsv) ('--cg-packages=' + $cgPkgCsv) 2>&1 | Out-String
    try {
        $ensureObj = $ensureOut | ConvertFrom-Json
        $ensuredMissing = @($ensureObj.added)
        Write-Step ('ensured missing deps: ' + $ensureObj.addedCount + '; unresolved: ' + $ensureObj.missingUnresolvedCount)
        if ($ensureObj.addedCount -gt 0) {
            Write-Step ('  + ' + (($ensureObj.added | Select-Object -First 12) -join ', '))
        }
    } catch {
        Write-Step ('WARN ensure-missing parse failed: ' + $_)
        Write-Step $ensureOut
    }
    Write-Step 're-promote CG after ensure-missing'
    Promote-CgPackagesFromLocal $dstNm $cgNmForPromote
    Ensure-DefaultCgJunctions $cgNmForPromote
} else {
    Write-Step 'WARN ensure-missing skipped (node or script missing)'
}

Write-Step 'drop browser-only npm packages (served via apps/web/dist)'
foreach ($rel in $browserDrop) {
    $bp = Join-Path $dstNm $rel
    if (-not (Test-Path -LiteralPath $bp)) { continue }
    $bit = Get-Item -LiteralPath $bp -Force
    if ($bit.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    Remove-Item -LiteralPath $bp -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-EmptyNpmScopes $dstNm $emptyNpmScopes

Write-Step 'recompute privatePackages after browser-drop / slim / blacklist'
function Get-StagePrivatePackages([string]$nmRoot) {
    $list = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $nmRoot)) { return @() }
    function Walk([string]$dir, [string]$rel) {
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $name = $item.Name
            $r = if ($rel) { "$rel/$name" } else { $name }
            if ($item.PSIsContainer) {
                if ($name.StartsWith('@') -and -not $rel) {
                    Walk $item.FullName $r
                } else {
                    $list.Add(($r -replace '\\', '/')) | Out-Null
                }
            }
        }
    }
    Walk $nmRoot ''
    return @($list | Sort-Object -Unique)
}
$privatePackages = New-Object System.Collections.Generic.List[string]
foreach ($p in (Get-StagePrivatePackages $dstNm)) { $privatePackages.Add($p) | Out-Null }
Write-Step ('private packages after slim: ' + $privatePackages.Count)

Write-Step 'prune unreachable private npm via import graph'
$pruneScript = Join-Path $PSScriptRoot 'lib\prune-unreachable-nm.js'
$unreachableDropped = @()
if ((Test-Path -LiteralPath $pruneScript) -and $runtimeNode) {
    $pruneOut = & $runtimeNode $pruneScript $dshRuntime 2>&1 | Out-String
    try {
        $pruneObj = $pruneOut | ConvertFrom-Json
        $unreachableDropped = @($pruneObj.dropped)
        Write-Step ('import-graph dropped: ' + $pruneObj.droppedCount + ' (kept ' + $pruneObj.kept + '/' + $pruneObj.privateBefore + ')')
    } catch {
        Write-Step ('WARN import-graph prune parse failed: ' + $_)
        Write-Step $pruneOut
    }
} else {
    Write-Step 'WARN import-graph prune skipped (node or script missing)'
}

Remove-EmptyNpmScopes $dstNm $emptyNpmScopes

Write-Step 'recompute privatePackages after import-graph prune'
$privatePackages = New-Object System.Collections.Generic.List[string]
foreach ($p in (Get-StagePrivatePackages $dstNm)) { $privatePackages.Add($p) | Out-Null }
Write-Step ('private packages after import-graph: ' + $privatePackages.Count)

Write-Step 'strip non-runtime files from private npm closure'
$runtimeResidue = Remove-PrivateRuntimeResidue $dstNm @($privatePackages)
$privatePackages = New-Object System.Collections.Generic.List[string]
foreach ($p in (Get-StagePrivatePackages $dstNm)) { $privatePackages.Add($p) | Out-Null }
Write-Step ('runtime residue removed: ' + $runtimeResidue.mb + ' MB; private packages now: ' + $privatePackages.Count)

Write-Step 'prune unreachable workspace lib/types runtime duplicates'
$workspacePruneScript = Join-Path $PSScriptRoot 'lib\prune-workspace-runtime.js'
$workspacePrune = [pscustomobject]@{ candidates = 0; kept = 0; dropped = 0; droppedBytes = 0; droppedMb = 0 }
if ((Test-Path -LiteralPath $workspacePruneScript) -and $runtimeNode) {
    $workspacePruneOut = & $runtimeNode $workspacePruneScript $dshRuntime 2>&1 | Out-String
    try {
        $workspacePrune = $workspacePruneOut | ConvertFrom-Json
        Write-Step ('workspace duplicate files dropped: ' + $workspacePrune.dropped +
            ' (' + $workspacePrune.droppedMb + ' MB; kept ' + $workspacePrune.kept + '/' + $workspacePrune.candidates + ')')
    } catch {
        throw ('workspace runtime prune failed: ' + $_ + "`n" + $workspacePruneOut)
    }
} else {
    throw 'workspace runtime prune unavailable'
}


function Ensure-SynthesizedWorkspaceLinks([string]$stageRoot, $blacklist) {
    Write-Step 'synthesize workspace junctions from harvested packages'
    $added = 0
    foreach ($pkg in (Find-WorkspacePackages $stageRoot)) {
        if ($blacklist.workspacePackageNames.Contains($pkg.name) -and -not $blacklist.keepWorkspacePackages.Contains($pkg.name)) { continue }
        if (Test-WorkspacePathBlacklisted $pkg.rel $blacklist) { continue }
        if (-not $pkg.name.StartsWith('@')) { continue }
        $scope, $short = $pkg.name.Split('/', 2)
        if (-not $short) { continue }
        $linkRel = ('node_modules/' + $scope + '/' + $short)
        $linkPath = Join-Path $stageRoot (($linkRel -replace '/', '\'))
        $targetPath = Join-Path $stageRoot (($pkg.rel -replace '/', '\'))
        if (-not (Test-Path -LiteralPath $targetPath)) { continue }
        $exists = $false
        foreach ($l in $workspaceLinks) {
            if (($l.path -replace '\\','/') -eq $linkRel) { $exists = $true; break }
        }
        if (-not $exists) {
            $workspaceLinks.Add([ordered]@{ path = $linkRel; target = ($pkg.rel -replace '\\', '/') }) | Out-Null
            $added++
        }
    }
    Write-Step ('synthesized workspace link entries: ' + $added)
}

Write-Step 'recreate workspace junctions in stage'
Ensure-SynthesizedWorkspaceLinks $dshRuntime $blacklist
foreach ($link in $workspaceLinks) {
    $linkPath = Join-Path $dshRuntime (($link.path -replace '/', '\'))
    $targetPath = Join-Path $dshRuntime (($link.target -replace '/', '\'))
    if (-not (Test-Path -LiteralPath $targetPath)) {
        Write-Step ('WARN workspace target missing, skip: ' + $link.path + ' -> ' + $link.target)
        continue
    }
    try { New-JunctionSafe $linkPath $targetPath } catch { Write-Step ('WARN workspace junction failed: ' + $link.path + ' :: ' + $_) }
}

$pkg = Get-CodexDesktopPackage
$cgNm = $null
if ($pkg) { $cgNm = Join-Path $pkg.InstallLocation 'app\resources\cua_node\bin\node_modules' }
if (-not $SkipCgLink -and $cgNm -and (Test-Path -LiteralPath $cgNm)) {
    Write-Step ('apply CG junctions from ' + $pkg.PackageFullName)
    foreach ($j in $cgJunctions) {
        $linkPath = Join-Path $dshRuntime (($j.path -replace '/', '\'))
        $targetPath = Join-Path $cgNm (($j.fromCg -replace '/', '\'))
        if (-not (Test-Path -LiteralPath $targetPath)) { Write-Step ('WARN CG missing: ' + $j.fromCg); continue }
        try { New-JunctionSafe $linkPath $targetPath } catch { Write-Step ('WARN CG link failed: ' + $j.path) }
    }
} else {
    Write-Step 'skip applying CG junctions (no local Codex package or -SkipCgLink)'
}

Write-Step 'verify provider and Web bundle import closure'
Test-ProviderImportClosure $pkg $dshRuntime
Write-Step 'runtime import closure OK'

Write-Step 'stage runtime controller, shell, and launchers'
$prSrc = Join-Path $repoRoot 'src\runtime'
$prDst = Join-Path $OutDir 'parasite-runtime'
Ensure-Dir $prDst
if (Test-Path (Join-Path $prSrc 'dsh-taskbar-icon.exe')) {
    Copy-FileTo (Join-Path $prSrc 'dsh-taskbar-icon.exe') (Join-Path $prDst 'dsh-taskbar-icon.exe')
}
$resSrc = Join-Path $repoRoot 'src\shell\resources'
$resDst = Join-Path $prDst 'owl-host\resources'
if (-not (Test-Path -LiteralPath $resSrc)) { throw ('missing owl-host resources: ' + $resSrc) }
Invoke-Robocopy $resSrc $resDst @() | Out-Null
$nodeForTools = Get-NodeExecutable
if (-not $nodeForTools) { throw 'Node.js is required to build the Electron app.asar' }
& $nodeForTools (Join-Path $repoRoot 'scripts\lib\pack-asar.js') (Join-Path $resSrc 'app') (Join-Path $resDst 'app.asar')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $resDst 'app.asar') -PathType Leaf)) {
    throw ('app.asar generation failed with exit code ' + $LASTEXITCODE)
}

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw ('C# compiler missing: ' + $csc) }
$sma = Get-ChildItem (Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation') `
    -Filter 'System.Management.Automation.dll' -Recurse -File -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $sma) { throw 'Windows PowerShell automation assembly is missing' }
$launcherPath = Join-Path $OutDir 'DeepSeek Harness (on ChatGPT).exe'
$launcherSources = @(Get-ChildItem (Join-Path $repoRoot 'src\installer') -Filter '*.cs' -File | Select-Object -ExpandProperty FullName)
& $csc /nologo /target:winexe /platform:x64 /optimize+ `
    /reference:System.Windows.Forms.dll /reference:System.Management.dll /reference:System.Web.Extensions.dll `
    ('/reference:' + $sma) ('/win32icon:' + (Join-Path $resDst 'app\icon.ico')) `
    ('/out:' + $launcherPath) $launcherSources
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw ('launcher compilation failed with exit code ' + $LASTEXITCODE)
}

$releaseCmds = @{
    'start-dsh-desktop.cmd' = @'
@echo off
cd /d "%~dp0"
"%~dp0DeepSeek Harness (on ChatGPT).exe" start
exit /b %ERRORLEVEL%
'@
    'stop-dsh-desktop.cmd' = @'
@echo off
cd /d "%~dp0"
"%~dp0DeepSeek Harness (on ChatGPT).exe" stop
exit /b %ERRORLEVEL%
'@
    'cleanup-admin.cmd' = @'
@echo off
cd /d "%~dp0"
"%~dp0DeepSeek Harness (on ChatGPT).exe" cleanup
exit /b %ERRORLEVEL%
'@
}
foreach ($entry in $releaseCmds.GetEnumerator()) {
    Set-Content -LiteralPath (Join-Path $OutDir $entry.Key) -Value $entry.Value.Trim() -Encoding ASCII
}
if (Test-Path (Join-Path $repoRoot 'assets\branding')) {
    Invoke-Robocopy (Join-Path $repoRoot 'assets\branding') (Join-Path $OutDir 'icon') @() | Out-Null
}

$stageReadme = @'
# DeepSeek Harness (on ChatGPT) - release stage

Windows x64 payload. Requires Microsoft Store ChatGPT/Codex (OpenAI.Codex) with cua_node.

## Start
- Double-click start-dsh-desktop.cmd
- Or: run `DeepSeek Harness (on ChatGPT).exe`

The launcher EXE requests UAC for junction/symlink creation, then starts DSH as the normal user. No PowerShell script runs on the target machine.

On first start the controller will:
1. Detect the local Codex package
2. Sync owl-host stub/links from the package (symlink/junction only; stub/elf copied)
3. Create ChatGPT node_modules junctions + asset forks from dsh-runtime\meta\release-manifest.json
4. Boot DSH web on http://127.0.0.1:3080 and open the shell

Do not recursively delete dsh-runtime\node_modules in Explorer (may contain junctions into WindowsApps).
'@
Set-Content -LiteralPath (Join-Path $OutDir 'README.release.md') -Value $stageReadme.Trim() -Encoding UTF8

$cgJunctionsArr = @($cgJunctions | ForEach-Object {
        [pscustomobject]@{ path = $_.path; fromCg = $_.fromCg; version = $_.version }
    })
$workspaceLinksArr = @($workspaceLinks | ForEach-Object {
        [pscustomobject]@{ path = $_.path; target = $_.target }
    })
$privatePackagesArr = @($privatePackages)
$skippedEmptyScopesArr = @($skippedEmptyScopes)

$browserDropManifest = @($browserDrop | ForEach-Object { ($_ -replace '\\', '/') })
$cgExample = $null
if ($pkg) {
    $cgExample = [pscustomobject]@{
        packageFullName = $pkg.PackageFullName
        version         = [string]$pkg.Version
    }
}

$manifestObj = [pscustomobject]@{
    schemaVersion         = 1
    product               = 'dsh-desktop'
    version               = $version
    platform              = 'win32-x64'
    builtAt               = (Get-Date).ToString('o')
    sourceLabel           = $sourceLabel
    sourceRepository      = 'https://github.com/deepseek-ai/deepseek-harness.git'
    sourceCommit          = $sourceCommit
    blacklistFile         = 'config/release-blacklist.json'
    dshRootName           = 'dsh-runtime'
    entry                 = 'apps/cli/lib/bin.js'
    port                  = 3080
    cgNodeModules         = 'app/resources/cua_node/bin/node_modules'
    cgJunctions           = $cgJunctionsArr
    workspaceLinks        = $workspaceLinksArr
    privatePackages       = $privatePackagesArr
    skippedEmptyScopes    = $skippedEmptyScopesArr
    browserOnlyDropped    = $browserDropManifest
    excludedWorkspace     = @($excludedWorkspace)
    excludedNpm           = @($excludedNpm | Sort-Object -Unique)
    unreachableDropped    = @($unreachableDropped)
    runtimeResidueRemoved = $runtimeResidue
    workspaceRuntimePrune = $workspacePrune
    excludedWorkspaceLinks = @($excludedWorkspaceLinks)
    packageManifestDepsScrubbed = @($manifestDepsScrubbed)
    cordisRowsScrubbed    = $scrubbed
    keepFeatures          = @($blacklist.keepWorkspacePackages)
    chatgptPackageExample = $cgExample
    cgAssetForks          = @(
        [pscustomobject]@{ path = 'node_modules/@vscode/ripgrep-win32-x64/bin/rg.exe'; fromPackage = 'app/resources/rg.exe'; type = 'symlink' }
        [pscustomobject]@{ path = 'node_modules/node-pty/build'; fromPackage = 'app/resources/app.asar.unpacked/node_modules/node-pty/build'; type = 'junction' }
    )
    notes                 = @(
        'Phase-1 closure: harvest built apps/packages + private node_modules with win32-x64 prune.',
        'Source is a local clone of the official deepseek-ai/deepseek-harness repository; build before harvest.',
        'Blacklist (config/release-blacklist.json): drop foreign model subagents, OTel, E2B, Typert generator, build tooling, DOM/test stacks; keep ACP + pi-ai.',
        'Runtime typert protocol/registry/loader remain (required by dsh-base).',
        'CG packages are not shipped; junctions/symlinks are created at start from local OpenAI.Codex.',
        'Asset forks: rg.exe + Electron node-pty/build (see cgAssetForks). File symlinks need UAC/Developer Mode.',
        'Browser-only npm listed in browserOnlyDropped are omitted; UI is apps/web/dist.',
        'privatePackages is the on-disk private set after slim/browser-drop/blacklist/import-graph (junction targets excluded).',
        'Import-graph prune: scripts/lib/prune-unreachable-nm.js seeds from harvested apps/packages/vendor/native and drops unreachable private npm.',
        'File-level prune removes declarations, source maps, build metadata, docs residue, and prebuilt-native compilation inputs.',
        'Workspace runtime graph keeps package exports and relative imports, then removes unreachable lib/types JavaScript duplicates.'
    )
}
$manifestPath = Join-Path $metaDir 'release-manifest.json'
$json = $manifestObj | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($manifestPath, ($json + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Write-Step ('wrote ' + $manifestPath)

function Get-DirBytes([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return [int64]0 }
    $o = robocopy $path NULL /L /S /XJ /BYTES /NJH /NFL /NDL /NC /NS /NP 2>&1 | Out-String
    $m = [regex]::Match($o, 'Bytes\s*:\s*(\d+)')
    if ($m.Success) { return [int64]$m.Groups[1].Value }
    return [int64]0
}
$stageBytes = Get-DirBytes $OutDir
$rtBytes = Get-DirBytes $dshRuntime
$nmBytes = Get-DirBytes $dstNm
Write-Step ('stage size   ~{0:N1} MB (no junction targets)' -f ($stageBytes / 1MB))
Write-Step ('runtime      ~{0:N1} MB' -f ($rtBytes / 1MB))
Write-Step ('node_modules ~{0:N1} MB private files' -f ($nmBytes / 1MB))

try {
    $manifestObj | Add-Member -NotePropertyName privateNodeModulesBytes -NotePropertyValue $nmBytes -Force
    $manifestObj | Add-Member -NotePropertyName privateNodeModulesMb -NotePropertyValue ([math]::Round($nmBytes / 1MB, 2)) -Force
    $manifestObj | Add-Member -NotePropertyName stageBytes -NotePropertyValue $stageBytes -Force
    $json2 = $manifestObj | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($manifestPath, ($json2 + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Step 'manifest sizes updated'
} catch {
    Write-Step ('WARN could not write sizes into manifest: ' + $_)
}

$zipPath = $null
if (-not $SkipZip) {
    $releaseDir = Split-Path -Parent $OutDir
    Ensure-Dir $releaseDir
    $zipName = ('DeepSeek-Harness-on-ChatGPT-stage-win-x64-' + $version + '.zip')
    $zipPath = Join-Path $releaseDir $zipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Write-Step ('zip ' + $zipPath)
    $tarCmd = Get-Command tar -ErrorAction SilentlyContinue
    if ($tarCmd) {
        Push-Location $OutDir
        try {
            & tar -a -c -f $zipPath *
            if ($LASTEXITCODE -ne 0) { throw ('tar zip failed: ' + $LASTEXITCODE) }
        } finally { Pop-Location }
    } else {
        Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zipPath -Force
    }
    Write-Step ('zip size ~{0:N1} MB' -f ((Get-Item $zipPath).Length / 1MB))
}

Write-Step 'DONE'
Write-Host ''
Write-Host ('Stage : ' + $OutDir)
Write-Host ('Run   : "' + (Join-Path $OutDir 'DeepSeek Harness (on ChatGPT).exe') + '"')
if ($zipPath) { Write-Host ('Zip   : ' + $zipPath) }
