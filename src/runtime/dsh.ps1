# dsh.ps1 - single runtime controller for parasitic DSH desktop
# Usage:
#   dsh.ps1 start
#   dsh.ps1 stop
#   dsh.ps1 cleanup
#   dsh.ps1 apply-forks [-DshRoot <path>]
#   dsh.ps1 uninstall
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'cleanup', 'apply-forks', 'uninstall')]
    [string]$Action = 'start',

    # Optional override of DSH product root (release stage dsh-runtime).
    [string]$DshRoot = ''
)

$ErrorActionPreference = 'Continue'
$runtime = $PSScriptRoot
$root = Split-Path -Parent $runtime
# Prefer explicit -DshRoot; otherwise use the staged sibling dsh-runtime.
$dsh = $null
if ($DshRoot) {
    $dsh = $DshRoot
} else {
    $dsh = Join-Path $root 'dsh-runtime'
}

$dshLeaf = Split-Path -Leaf $dsh
$dshHome = Join-Path $dsh '.dshhome'
$bin = Join-Path $dsh 'apps\cli\lib\bin.js'
$releaseManifest = Join-Path $dsh 'meta\release-manifest.json'
$owlHost = Join-Path $runtime 'owl-host'
$stub = Join-Path $owlHost 'owl-stub.exe'
$ud = Join-Path $runtime 'owl-ud-dsh'
$iconExe = Join-Path $runtime 'dsh-taskbar-icon.exe'
$owlPkgMarker = Join-Path $owlHost '.codex-package-full-name'
$port = 3080
$url = "http://127.0.0.1:$port"

$requirementsScript = Join-Path $runtime 'codex-requirements.ps1'
if (-not (Test-Path -LiteralPath $requirementsScript -PathType Leaf)) {
    throw ('missing runtime requirements helper: ' + $requirementsScript)
}
. $requirementsScript

function Write-Info([string]$msg) {
    Write-Host ('[DSH] ' + $msg)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-OwlUserDataAvailable {
    $escaped = [regex]::Escape($ud)
    $occupied = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ne 'owl-stub.exe' -and [string]$_.CommandLine -match $escaped
    })
    if ($occupied.Count -gt 0) {
        $message = "DSH profile is already occupied by another process.`n`n$ud`n`nClose that process and try again. Existing ChatGPT.exe processes will not be touched."
        Write-Info ('ERROR: ' + ($message -replace "`n", ' '))
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($message, 'DeepSeek Harness (on ChatGPT) cannot start', 'OK', 'Error')
        } catch {}
        return $false
    }
    return $true
}

function Test-LocalPort([int]$tcpPort) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $tcpPort, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(300)
        if ($ok -and $client.Connected) { $client.Close(); return $true }
        $client.Close()
        return $false
    } catch {
        return $false
    }
}

function Get-FileLen([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return -1 }
    try { return [int64](Get-Item -LiteralPath $path -Force).Length } catch { return -1 }
}

function Stop-OwlStubUi {
    $owlUi = @(Get-Process -Name 'owl-stub' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 1 })
    if (-not $owlUi) { return 0 }
    Write-Info ('stop owl-stub: ' + (($owlUi | ForEach-Object { $_.Id }) -join ','))
    $owlUi | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    return $owlUi.Count
}

function Stop-DirectoryDialogWatcher {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $commandLine = [string]$_.CommandLine
            if ($commandLine -notmatch '(?i)-EncodedCommand\s+([^\s"]+)') { return $false }
            try {
                $source = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
                return $source -match 'DSH_DIALOG_WATCHER_'
            } catch {
                return $false
            }
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Start-DirectoryDialogWatcher([int]$shellPid) {
    Stop-DirectoryDialogWatcher
    $runtimeToken = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($dsh))
    $script = @"
`$DSH_DIALOG_WATCHER_$shellPid = `$true
`$shellPid = $shellPid
`$runtimeRoot = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$runtimeToken'))
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class DshDirectoryDialogWatcher {
  public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lparam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lparam);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
}
'@

function Find-DshMainWindow {
    try {
        `$process = Get-Process -Id `$shellPid -ErrorAction Stop
        if (`$process.MainWindowHandle -ne [IntPtr]::Zero) { return `$process.MainWindowHandle }
    } catch {}
    return [IntPtr]::Zero
}

`$seen = @{}
while (Get-Process -Id `$shellPid -ErrorAction SilentlyContinue) {
    `$owner = Find-DshMainWindow
    if (`$owner -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100; continue }
    `$dialogs = [Collections.Generic.List[object]]::new()
    `$callback = [DshDirectoryDialogWatcher+EnumWindowsProc]{
        param([IntPtr]`$hwnd, [IntPtr]`$lparam)
        if (-not [DshDirectoryDialogWatcher]::IsWindowVisible(`$hwnd)) { return `$true }
        `$title = [Text.StringBuilder]::new(128)
        `$windowClass = [Text.StringBuilder]::new(64)
        [void][DshDirectoryDialogWatcher]::GetWindowText(`$hwnd, `$title, `$title.Capacity)
        [void][DshDirectoryDialogWatcher]::GetClassName(`$hwnd, `$windowClass, `$windowClass.Capacity)
        if (`$title.ToString() -ne 'Select Workspace Directory' -or `$windowClass.ToString() -ne '#32770') { return `$true }
        [uint32]`$processId = 0
        [void][DshDirectoryDialogWatcher]::GetWindowThreadProcessId(`$hwnd, [ref]`$processId)
        `$dialogs.Add([pscustomobject]@{ Hwnd = `$hwnd; ProcessId = `$processId })
        return `$true
    }
    [void][DshDirectoryDialogWatcher]::EnumWindows(`$callback, [IntPtr]::Zero)
    foreach (`$dialog in `$dialogs) {
        `$key = [string]`$dialog.Hwnd.ToInt64()
        if (`$seen.ContainsKey(`$key)) { continue }
        `$process = Get-CimInstance Win32_Process -Filter "ProcessId=`$(`$dialog.ProcessId)" -ErrorAction SilentlyContinue
        if (-not `$process -or [string]`$process.CommandLine -notlike ('*' + `$runtimeRoot + '*directory-picker-native*worker.cjs*')) { continue }
        `$seen[`$key] = `$true
        Start-Sleep -Milliseconds 250
        [void][DshDirectoryDialogWatcher]::SetWindowLongPtr(`$dialog.Hwnd, -8, `$owner)
        [void][DshDirectoryDialogWatcher]::SetWindowPos(`$dialog.Hwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
        [void][DshDirectoryDialogWatcher]::SetWindowPos(`$dialog.Hwnd, [IntPtr](-2), 0, 0, 0, 0, 0x0013)
        [void][DshDirectoryDialogWatcher]::SetForegroundWindow(`$dialog.Hwnd)
    }
    foreach (`$key in @(`$seen.Keys)) {
        if (-not [DshDirectoryDialogWatcher]::IsWindow([IntPtr]::new([Int64]`$key))) { `$seen.Remove(`$key) }
    }
    Start-Sleep -Milliseconds 100
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershell -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
    ) -WindowStyle Hidden | Out-Null
}

function Stop-DshNode {
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            $cl = [string]$p.CommandLine
            if ($cl -match 'dsh-(web-min|runtime)\\apps\\cli\\lib\\bin\.js' -or $cl -match '--profile web --port ' + $port) {
                if ($cl -match 'OpenAI\.Codex_|cua_node|dsh-runtime') {
                    Write-Info ('stop node pid=' + $p.ProcessId)
                    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {
        foreach ($p in @(Get-Process -Name 'node' -ErrorAction SilentlyContinue)) {
            try {
                $path = $p.Path
                if ($path -and $path -match 'cua_node|WindowsApps\\OpenAI') {
                    Write-Info ('stop node pid=' + $p.Id)
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
    }
}

function Restore-TaskbarIcon {
    if (Test-Path -LiteralPath $iconExe) {
        Start-Process -FilePath $iconExe -ArgumentList 'restore' -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
    }
    Get-Process -Name 'dsh-taskbar-icon', 'dsh-taskbar-host' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Repair-OneCgJunction([string]$linkPath, [string]$targetPath, [string]$label) {
    if (-not (Test-Path -LiteralPath $targetPath)) { return }
    if (-not (Test-Path -LiteralPath $linkPath)) { return }
    $item = Get-Item -LiteralPath $linkPath -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
    $target = [string]($item.Target)
    if ($target -notmatch 'WindowsApps\\OpenAI\.') { return }
    if ($target -eq $targetPath) { return }
    if ($item.PSIsContainer) { cmd /c ('rmdir "' + $linkPath + '"') | Out-Null }
    else { Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
    Write-Info ('retarget nm ' + $label)
}

function Repair-CgJunctions([string]$poolNm, [string]$cgNm) {
    if (-not (Test-Path -LiteralPath $poolNm) -or -not (Test-Path -LiteralPath $cgNm)) { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $poolNm -Force)) {
        $name = $item.Name
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Repair-OneCgJunction $item.FullName (Join-Path $cgNm $name) $name
            continue
        }
        # Nested junctions under scope folders (e.g. @napi-rs/canvas)
        if ($item.PSIsContainer -and $name.StartsWith('@')) {
            $cgScope = Join-Path $cgNm $name
            if (-not (Test-Path -LiteralPath $cgScope)) { continue }
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue)) {
                if (-not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                Repair-OneCgJunction $child.FullName (Join-Path $cgScope $child.Name) ($name + '/' + $child.Name)
            }
        }
    }
}

function Ensure-CgJunctionsFromManifest([string]$dshRoot, [string]$cgNm, [string]$manifestPath) {
    if (-not (Test-Path -LiteralPath $manifestPath)) { return 0 }
    if (-not (Test-Path -LiteralPath $cgNm)) { return 0 }
    $manifest = $null
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Info ('WARN bad release-manifest: ' + $_)
        return 0
    }
    $created = 0
    foreach ($j in @($manifest.cgJunctions)) {
        if (-not $j) { continue }
        $rel = [string]$j.path
        $fromCg = [string]$j.fromCg
        if (-not $rel -or -not $fromCg) { continue }
        $linkPath = Join-Path $dshRoot ($rel -replace '/', '\')
        $targetPath = Join-Path $cgNm ($fromCg -replace '/', '\')
        if (-not (Test-Path -LiteralPath $targetPath)) {
            Write-Info ('WARN CG missing for junction: ' + $fromCg)
            continue
        }
        if (Test-Path -LiteralPath $linkPath) {
            $item = Get-Item -LiteralPath $linkPath -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $cur = [string]$item.Target
                if ($cur -eq $targetPath) { continue }
                if ($item.PSIsContainer) { cmd /c ('rmdir "' + $linkPath + '"') | Out-Null }
                else { Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue }
            } else {
                # Real private dir wins; do not overwrite.
                continue
            }
        } else {
            $parent = Split-Path -Parent $linkPath
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
        }
        New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
        $created++
    }
    if ($created -gt 0) { Write-Info ('cg junctions created/updated: ' + $created) }
    return $created
}

function Ensure-WorkspaceJunctionsFromManifest([string]$dshRoot, [string]$manifestPath) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw ('release manifest missing: ' + $manifestPath)
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $created = 0
    foreach ($link in @($manifest.workspaceLinks)) {
        if (-not $link -or -not $link.path -or -not $link.target) { continue }
        $linkPath = Join-Path $dshRoot (([string]$link.path) -replace '/', '\')
        $targetPath = Join-Path $dshRoot (([string]$link.target) -replace '/', '\')
        if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
            throw ('workspace junction target missing: ' + [string]$link.target)
        }
        if (Test-Path -LiteralPath $linkPath) {
            $item = Get-Item -LiteralPath $linkPath -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ([string]$item.Target -eq $targetPath) { continue }
                Remove-ReparseOrFile $linkPath
            } else {
                throw ('workspace junction path is occupied by a real file or directory: ' + [string]$link.path)
            }
        } else {
            $parent = Split-Path -Parent $linkPath
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
        }
        New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
        $created++
    }
    if ($created -gt 0) { Write-Info ('workspace junctions created/updated: ' + $created) }
    return $created
}


function Set-PathLink([string]$linkPath, [string]$targetPath, [bool]$isDir) {
    if (-not (Test-Path -LiteralPath $targetPath)) { return $false }
    if (Test-Path -LiteralPath $linkPath) {
        $item = Get-Item -LiteralPath $linkPath -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $cur = [string]$item.Target
            if ($cur -eq $targetPath) { return $true }
            Remove-ReparseOrFile $linkPath
        } else {
            Remove-ReparseOrFile $linkPath
        }
    } else {
        $parent = Split-Path -Parent $linkPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
    }
    if ($isDir) {
        New-Item -ItemType Junction -Path $linkPath -Target $targetPath -Force | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath -Force | Out-Null
    }
    return $true
}

function Get-DefaultCgAssetForks {
    return @(
        [pscustomobject]@{ path = 'node_modules/@vscode/ripgrep-win32-x64/bin/rg.exe'; fromPackage = 'app/resources/rg.exe'; type = 'symlink' },
        [pscustomobject]@{ path = 'node_modules/node-pty/build'; fromPackage = 'app/resources/app.asar.unpacked/node_modules/node-pty/build'; type = 'junction' }
    )
}

function Ensure-CgAssetForks([string]$dshRoot, [string]$packageInstallLocation) {
    $nm = Join-Path $dshRoot 'node_modules'
    if (-not (Test-Path -LiteralPath $nm)) { return 0 }

    # Manifest first; fall back to built-in defaults. Dedup by link path.
    $forks = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $manifestPath = Join-Path $dshRoot 'meta\release-manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $man = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($f in @($man.cgAssetForks)) {
                if (-not $f -or -not $f.path -or -not $f.fromPackage) { continue }
                $key = ([string]$f.path).ToLowerInvariant()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $forks.Add($f) | Out-Null
            }
        } catch {
            Write-Info ('WARN cgAssetForks manifest: ' + $_)
        }
    }
    if ($forks.Count -eq 0) {
        foreach ($f in (Get-DefaultCgAssetForks)) {
            $forks.Add($f) | Out-Null
        }
    }

    $n = 0
    foreach ($f in $forks) {
        $linkPath = Join-Path $dshRoot (([string]$f.path) -replace '/', '\')
        $targetPath = Join-Path $packageInstallLocation (([string]$f.fromPackage) -replace '/', '\')
        if (-not (Test-Path -LiteralPath $targetPath)) {
            Write-Info ('WARN asset fork target missing: ' + $f.fromPackage)
            continue
        }
        $isDir = $false
        if ([string]$f.type -eq 'junction') { $isDir = $true }
        elseif ([string]$f.type -eq 'symlink') { $isDir = $false }
        else { $isDir = (Get-Item -LiteralPath $targetPath -Force).PSIsContainer }

        if (Set-PathLink $linkPath $targetPath $isDir) {
            $n++
            Write-Info ('fork ' + $f.path + ' <- ' + $f.fromPackage)
        }
    }

    # Drop heavy private native leftovers once build/ is forked from CG.
    foreach ($drop in @('prebuilds', 'third_party', 'src', 'deps')) {
        $p = Join-Path $nm ('node-pty\' + $drop)
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $it = Get-Item -LiteralPath $p -Force
        if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info ('drop private node-pty\' + $drop)
    }
    return $n
}

function Remove-ReparseOrFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($item.PSIsContainer) { cmd /c rmdir "`"$path`"" | Out-Null }
        else { [System.IO.File]::Delete($path) }
    } elseif ($item.PSIsContainer) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Set-OwlHostLink([string]$linkPath, [string]$targetPath) {
    if (-not (Test-Path -LiteralPath $targetPath)) { throw "missing target $targetPath" }
    $isDir = (Get-Item -LiteralPath $targetPath -Force).PSIsContainer
    # File symlinks need admin/Developer Mode; dirs use junctions.
    if (-not (Set-PathLink $linkPath $targetPath $isDir)) {
        throw ("failed to link $linkPath -> $targetPath")
    }
    return 'linked'
}

function Test-OwlHostNeedsSync([string]$hostDir, [string]$appDir, [string]$packageFullName) {
    $marked = ''
    if (Test-Path -LiteralPath $owlPkgMarker) {
        $marked = (Get-Content -LiteralPath $owlPkgMarker -Raw -ErrorAction SilentlyContinue).Trim()
    }
    if ($marked -ne $packageFullName) { return "package-marker:$marked" }

    $stubPath = Join-Path $hostDir 'owl-stub.exe'
    $srcStub = Join-Path $appDir 'ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $stubPath)) { return 'missing-owl-stub' }
    if (-not (Test-Path -LiteralPath $srcStub)) { return 'missing-package-ChatGPT.exe' }
    if ((Get-FileLen $stubPath) -ne (Get-FileLen $srcStub)) { return 'owl-stub-size-mismatch' }

    $elfPath = Join-Path $hostDir 'chrome_elf.dll'
    $srcElf = Join-Path $appDir 'chrome_elf.dll'
    if (Test-Path -LiteralPath $srcElf) {
        if (-not (Test-Path -LiteralPath $elfPath)) { return 'missing-chrome_elf' }
        if ((Get-FileLen $elfPath) -ne (Get-FileLen $srcElf)) { return 'chrome_elf-size-mismatch' }
    }

    $chrome = Join-Path $hostDir 'chrome.dll'
    if (-not (Test-Path -LiteralPath $chrome)) { return 'missing-chrome.dll' }
    try {
        $item = Get-Item -LiteralPath $chrome -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $target = [string]$item.Target
            $expected = Join-Path $appDir 'chrome.dll'
            if ($target -ne $expected -or -not (Test-Path -LiteralPath $target)) { return 'chrome.dll-stale-link' }
        }
    } catch {
        return 'chrome.dll-inspect-failed'
    }

    # Real local leftovers (not reparse) that are absent from package force a full sync.
    $keep = @('resources','owl-stub.exe','chrome_elf.dll','.codex-package-full-name','debug.log','owl-host.exe','owl-host.c')
    foreach ($item in @(Get-ChildItem -LiteralPath $hostDir -Force -ErrorAction SilentlyContinue)) {
        $name = $item.Name
        if ($keep -contains $name) { continue }
        if ($name -like '*.manifest') { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $appDir $name))) {
            return ('orphan-local:' + $name)
        }
    }
    return $null
}

function Sync-OwlHostFromPackage([string]$hostDir, [string]$appDir, [string]$packageFullName) {
    New-Item -ItemType Directory -Force -Path $hostDir | Out-Null
    Write-Info ('sync owl-host -> ' + $packageFullName)

    $hostResources = Join-Path $hostDir 'resources'
    $packageResources = Join-Path $appDir 'resources'
    New-Item -ItemType Directory -Force -Path $hostResources | Out-Null
    $owlIniSource = Join-Path $packageResources 'owl-app.ini'
    if (Test-Path -LiteralPath $owlIniSource -PathType Leaf) {
        $owlIni = Get-Content -LiteralPath $owlIniSource -Raw -Encoding UTF8
        $owlIni = $owlIni -replace '(?m)^UserDataDirectoryName=.*$', 'UserDataDirectoryName=DshOwl'
        [IO.File]::WriteAllText((Join-Path $hostResources 'owl-app.ini'), $owlIni, [Text.UTF8Encoding]::new($false))
    }
    $owlMetadataSource = Join-Path $packageResources 'owl-electron-app.json'
    if (Test-Path -LiteralPath $owlMetadataSource -PathType Leaf) {
        Copy-Item -LiteralPath $owlMetadataSource -Destination (Join-Path $hostResources 'owl-electron-app.json') -Force
    }

    $srcStub = Join-Path $appDir 'ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $srcStub)) { throw "package ChatGPT.exe missing: $srcStub" }
    Copy-Item -LiteralPath $srcStub -Destination (Join-Path $hostDir 'owl-stub.exe') -Force

    $srcElf = Join-Path $appDir 'chrome_elf.dll'
    if (Test-Path -LiteralPath $srcElf) {
        Copy-Item -LiteralPath $srcElf -Destination (Join-Path $hostDir 'chrome_elf.dll') -Force
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $hostDir -Force -File -ErrorAction SilentlyContinue)) {
        if ($item.Name -notlike '*.manifest') { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $appDir $item.Name))) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $appDir -Force -File -ErrorAction SilentlyContinue)) {
        if ($item.Name -notlike '*.manifest') { continue }
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $hostDir $item.Name) -Force
    }

    $skipNames = @(
        'resources', 'ChatGPT.exe', 'chrome_elf.dll', 'owl-stub.exe',
        'owl-host.exe', 'owl-host.c', 'debug.log', '.codex-package-full-name'
    )
    foreach ($item in @(Get-ChildItem -LiteralPath $appDir -Force)) {
        $name = $item.Name
        if ($skipNames -contains $name) { continue }
        if ($name -like '*.manifest') { continue }
        try { Set-OwlHostLink (Join-Path $hostDir $name) $item.FullName | Out-Null } catch {}
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $hostDir -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) {
        $name = $item.Name
        if ($skipNames -contains $name) { continue }
        $target = [string]($item.Target)
        if ($target -notmatch 'WindowsApps\\OpenAI\.') { continue }
        $dest = Join-Path $appDir $name
        if (-not (Test-Path -LiteralPath $dest)) {
            Remove-ReparseOrFile $item.FullName
            Write-Info ('removed stale owl-host link ' + $name)
            continue
        }
        if ($target -eq $dest) { continue }
        try { Set-OwlHostLink $item.FullName $dest | Out-Null } catch {}
    }

    # Drop local leftovers that no longer exist in the current package
    # (e.g. old package had Dictionaries/, current one does not).
    $keepExact = @{
        'resources' = $true
        'ChatGPT.exe' = $true
        'chrome_elf.dll' = $true
        'owl-stub.exe' = $true
        'owl-host.exe' = $true
        'owl-host.c' = $true
        'debug.log' = $true
        '.codex-package-full-name' = $true
        'dsh-desktop.json' = $true
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $hostDir -Force -ErrorAction SilentlyContinue)) {
        $name = $item.Name
        if ($keepExact.ContainsKey($name)) { continue }
        if ($name -like '*.manifest') {
            if (-not (Test-Path -LiteralPath (Join-Path $appDir $name))) {
                Remove-ReparseOrFile $item.FullName
                Write-Info ('removed orphan manifest ' + $name)
            }
            continue
        }
        $pkgPath = Join-Path $appDir $name
        if (Test-Path -LiteralPath $pkgPath) { continue }
        Remove-ReparseOrFile $item.FullName
        Write-Info ('removed orphan owl-host entry ' + $name)
    }

    Set-Content -LiteralPath $owlPkgMarker -Value $packageFullName -Encoding UTF8
    Write-Info 'owl-host sync done'
}

function Repair-OwlHostLinksLight([string]$hostDir, [string]$appDir) {
    foreach ($item in @(Get-ChildItem -LiteralPath $appDir -Force)) {
        $name = $item.Name
        if ($name -in @('resources', 'ChatGPT.exe', 'chrome_elf.dll')) { continue }
        if ($name -like '*.manifest') { continue }
        try { Set-OwlHostLink (Join-Path $hostDir $name) $item.FullName | Out-Null } catch {}
    }
}

function Assert-OwlHostReady([string]$hostDir, [string]$appDir) {
    if (-not (Test-Path -LiteralPath (Join-Path $hostDir 'owl-stub.exe'))) {
        Write-Info 'ERROR missing owl-stub.exe'
        return 3
    }
    $chromeDll = Join-Path $hostDir 'chrome.dll'
    if (-not (Test-Path -LiteralPath $chromeDll)) {
        Write-Info 'ERROR missing chrome.dll link'
        return 10
    }
    try {
        $chromeItem = Get-Item -LiteralPath $chromeDll -Force
        if ($chromeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $chromeTarget = [string]($chromeItem.Target)
            $expected = Join-Path $appDir 'chrome.dll'
            if ($chromeTarget -ne $expected -or -not (Test-Path -LiteralPath $chromeTarget)) {
                Write-Info ('ERROR chrome.dll stale: ' + $chromeTarget)
                return 11
            }
        }
    } catch {
        Write-Info ('ERROR chrome.dll inspect failed: ' + $_)
        return 12
    }
    return 0
}

function Start-DshNodeHidden([string]$packageFamilyName, [string]$nodePath) {
    $cmd = @"
`$ErrorActionPreference = 'Stop'
`$env:DSH_HOME = '$dshHome'
`$arguments = '"$bin" --profile web --port $port'
Start-Process -FilePath '$nodePath' -ArgumentList `$arguments -WorkingDirectory '$dsh' -WindowStyle Hidden
"@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Invoke-CommandInDesktopPackage -PackageFamilyName $packageFamilyName -AppId 'App' `
        -Command $ps `
        -Args "-NoProfile -WindowStyle Hidden -EncodedCommand $b64" `
        -PreventBreakaway | Out-Null
}

function Invoke-DshStart {
    Write-Info ('root=' + $root)
    if (-not (Assert-OwlUserDataAvailable)) { exit 14 }
    New-Item -ItemType Directory -Force -Path $ud, $owlHost | Out-Null

    try {
        $requirements = Assert-CodexReleaseRequirements $releaseManifest
    } catch {
        Write-Info ('ERROR ChatGPT runtime validation failed:' + [Environment]::NewLine + $_)
        exit 2
    }

    $isAdmin = Test-IsAdministrator
    if (-not $isAdmin) {
        Write-Info 'running with links prepared by launcher'
    }

    $pkg = $requirements.Package
    $node = $requirements.NodePath
    $cgNm = $requirements.CgNodeModules
    $appDir = $requirements.AppDir
    Write-Info ('package=' + $pkg.PackageFullName)

    if (-not (Test-Path -LiteralPath $bin)) { Write-Info ('ERROR missing ' + $bin); exit 4 }
    if (-not (Test-Path -LiteralPath $dshHome)) { Write-Info ('ERROR missing ' + $dshHome); exit 5 }

    Write-Info ('dsh=' + $dshLeaf)
    if ($isAdmin) {
        Ensure-WorkspaceJunctionsFromManifest $dsh $releaseManifest | Out-Null
        Ensure-CgJunctionsFromManifest $dsh $cgNm $releaseManifest | Out-Null
        Repair-CgJunctions (Join-Path $dsh 'node_modules') $cgNm
        Ensure-CgAssetForks $dsh $pkg.InstallLocation | Out-Null
    }

    $needReason = Test-OwlHostNeedsSync $owlHost $appDir $pkg.PackageFullName
    if ($needReason) {
        if (-not $isAdmin) {
            Write-Info ('ERROR runtime preparation required: ' + $needReason)
            Write-Info 'Launch through DeepSeek Harness (on ChatGPT).exe.'
            exit 15
        }
        Write-Info ('owl-host stale: ' + $needReason)
        [void](Stop-OwlStubUi)
        try {
            Sync-OwlHostFromPackage $owlHost $appDir $pkg.PackageFullName
        } catch {
            Write-Info ('ERROR owl-host sync failed: ' + $_)
            exit 13
        }
    } else {
        Write-Info 'owl-host up to date'
        if ($isAdmin) { Repair-OwlHostLinksLight $owlHost $appDir }
    }

    $readyCode = [int](Assert-OwlHostReady $owlHost $appDir | Select-Object -Last 1)
    if ($readyCode -ne 0) { exit $readyCode }

    $cfgPath = Join-Path $owlHost 'resources\app\dsh-desktop.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $cfgPath -Parent) | Out-Null
    Set-Content -LiteralPath $cfgPath -Value ('{ "url": "' + $url + '" }') -Encoding UTF8

    if (Test-LocalPort $port) {
        Write-Info ("port $port already up")
    } else {
        Write-Info 'starting DSH node'
        try {
            Start-DshNodeHidden $pkg.PackageFamilyName $node
        } catch {
            Write-Info ('ERROR node start failed: ' + $_)
            exit 6
        }
        $deadline = (Get-Date).AddSeconds(50)
        while (-not (Test-LocalPort $port)) {
            if ((Get-Date) -gt $deadline) {
                Write-Info 'ERROR: DSH port did not open'
                Write-Info "Run the stage CLI directly for diagnostics: node apps\cli\lib\bin.js --profile web --port $port"
                exit 7
            }
            Start-Sleep -Milliseconds 400
        }
        Write-Info ("listening $url")
    }

    [void](Stop-OwlStubUi)
    Restore-TaskbarIcon

    $owlArgs = '--no-sandbox --disable-gpu --user-data-dir="' + $ud + '"'
    Write-Info 'starting shell'
    try {
        Invoke-CommandInDesktopPackage -PackageFamilyName $pkg.PackageFamilyName -AppId 'App' `
            -Command $stub -Args $owlArgs -PreventBreakaway | Out-Null
    } catch {
        Write-Info ('ERROR shell start failed: ' + $_)
        exit 8
    }

    Start-Sleep -Seconds 5
    $parents = @()
    try {
        $parents = @(Get-CimInstance Win32_Process -Filter "Name='owl-stub.exe'" -ErrorAction Stop | Where-Object {
            $_.SessionId -eq 1 -and (-not $_.CommandLine -or $_.CommandLine -notmatch '--type=')
        })
    } catch {
        $parents = @(Get-Process -Name 'owl-stub' -ErrorAction SilentlyContinue | Where-Object {
            $_.SessionId -eq 1 -and $_.MainWindowHandle -ne [IntPtr]::Zero
        })
    }
    if ($parents.Count -eq 0) {
        Write-Info 'ERROR: owl-stub did not stay up'
        exit 9
    }
    Start-DirectoryDialogWatcher ([int]$parents[0].ProcessId)
    Write-Info ("OK $url")
    exit 0
}

function Invoke-DshStop {
    Write-Info 'stopping DSH desktop'
    Stop-DirectoryDialogWatcher
    Restore-TaskbarIcon
    [void](Stop-OwlStubUi)
    Stop-DshNode
    Start-Sleep -Milliseconds 300
    Write-Info 'stopped (ChatGPT.exe untouched)'
    exit 0
}

function Invoke-DshCleanup {
    if (-not (Test-IsAdministrator)) {
        Write-Info 'ERROR cleanup requires the elevated launcher EXE'
        exit 5
    }

    Write-Info 'admin cleanup'
    foreach ($name in @('ParasiteNode', 'ParasiteOwlHost', 'ParasiteElectron')) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Info ('removed task ' + $name)
        }
    }

    Get-Process -Name 'owl-stub' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq 0 } |
        ForEach-Object {
            Write-Info ('kill session-0 owl-stub pid=' + $_.Id)
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    Get-Process -Name 'dsh-taskbar-host', 'dsh-taskbar-icon' -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Stop-DirectoryDialogWatcher

    $junk = @(
        (Join-Path $root 'package-lock.json'),
        (Join-Path $runtime 'dsh-desktop-launch.log'),
        (Join-Path $runtime 'dsh-desktop.log'),
        (Join-Path $runtime 'dsh-node.log'),
        (Join-Path $runtime 'dsh-taskbar-icon.log'),
        (Join-Path $runtime 'dsh-hwnd.txt'),
        (Join-Path $owlHost 'debug.log'),
        (Join-Path $owlHost 'owl-host-log.txt')
    )
    foreach ($f in $junk) {
        if (Test-Path -LiteralPath $f) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            Write-Info ('removed ' + $f)
        }
    }

    Get-ChildItem -LiteralPath $runtime -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'owl-ud*' -and $_.Name -ne 'owl-ud-dsh' } |
        ForEach-Object {
            Write-Info ('remove old profile ' + $_.Name)
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }

    $old = Join-Path $env:LOCALAPPDATA 'ParasiteRuntime'
    if (Test-Path -LiteralPath $old) {
        Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info ('removed ' + $old)
    }

    Write-Info 'cleanup done'
    exit 0
}

function Invoke-DshApplyForks {
    Write-Info ('apply-forks dsh=' + $dsh)
    if (-not (Test-IsAdministrator)) {
        Write-Info 'ERROR apply-forks requires the elevated launcher EXE'
        exit 5
    }
    try {
        $requirements = Assert-CodexReleaseRequirements $releaseManifest
    } catch {
        Write-Info ('ERROR ChatGPT runtime validation failed:' + [Environment]::NewLine + $_)
        exit 2
    }
    $pkg = $requirements.Package
    $cgNm = $requirements.CgNodeModules
    $appDir = $requirements.AppDir
    Write-Info ('package=' + $pkg.PackageFullName)
    Ensure-WorkspaceJunctionsFromManifest $dsh $releaseManifest | Out-Null
    Ensure-CgJunctionsFromManifest $dsh $cgNm $releaseManifest | Out-Null
    Repair-CgJunctions (Join-Path $dsh 'node_modules') $cgNm
    $n = Ensure-CgAssetForks $dsh $pkg.InstallLocation
    $needReason = Test-OwlHostNeedsSync $owlHost $appDir $pkg.PackageFullName
    if ($needReason) {
        Sync-OwlHostFromPackage $owlHost $appDir $pkg.PackageFullName
    } else {
        Repair-OwlHostLinksLight $owlHost $appDir
    }
    $readyCode = [int](Assert-OwlHostReady $owlHost $appDir | Select-Object -Last 1)
    if ($readyCode -ne 0) { exit $readyCode }
    Write-Info ('apply-forks done (asset ops=' + $n + ')')
    exit 0
}

function Remove-ManifestRuntimeLinks([string]$dshRoot, [string]$manifestPath) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
    $paths = @($manifest.workspaceLinks | ForEach-Object { $_.path }) +
        @($manifest.cgJunctions | ForEach-Object { $_.path }) +
        @($manifest.cgAssetForks | ForEach-Object { $_.path })
    foreach ($relativePath in @($paths | Where-Object { $_ } | Sort-Object Length -Descending -Unique)) {
        $path = Join-Path $dshRoot (([string]$relativePath) -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Remove-ReparseOrFile $path
        }
    }
}

function Remove-AllRuntimeReparsePoints([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return }
    Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { Remove-ReparseOrFile $_.FullName }
}

function Invoke-DshUninstall {
    Write-Info 'uninstall cleanup'
    if (-not (Test-IsAdministrator)) {
        Write-Info 'ERROR uninstall requires the elevated launcher EXE'
        exit 5
    }
    Stop-DirectoryDialogWatcher
    Restore-TaskbarIcon
    [void](Stop-OwlStubUi)
    Stop-DshNode
    Remove-ManifestRuntimeLinks $dsh $releaseManifest
    Remove-AllRuntimeReparsePoints $dsh

    foreach ($generatedPath in @($owlHost, $ud)) {
        if (-not (Test-Path -LiteralPath $generatedPath)) { continue }
        Remove-AllRuntimeReparsePoints $generatedPath
        Remove-Item -LiteralPath $generatedPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Info 'uninstall cleanup done'
    exit 0
}

switch ($Action) {
    'start' { Invoke-DshStart }
    'stop' { Invoke-DshStop }
    'cleanup' { Invoke-DshCleanup }
    'apply-forks' { Invoke-DshApplyForks }
    'uninstall' { Invoke-DshUninstall }
}

