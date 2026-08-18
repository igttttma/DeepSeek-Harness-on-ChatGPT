function Get-CodexDesktopPackage {
    $candidates = @(Get-AppxPackage -Name 'OpenAI.Codex*' -ErrorAction SilentlyContinue)
    if (-not $candidates) {
        $candidates = @(Get-AppxPackage -Name 'OpenAI.*' -ErrorAction SilentlyContinue)
    }
    $candidates |
        Where-Object {
            $app = Join-Path $_.InstallLocation 'app'
            Test-Path -LiteralPath $app -PathType Container
        } |
        Sort-Object {
            try { [version]$_.Version } catch { [version]'0.0.0.0' }
        } -Descending |
        Select-Object -First 1
}

function Test-CodexReleaseRequirements([string]$manifestPath) {
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $package = Get-CodexDesktopPackage
    if (-not $package) {
        $errors.Add('Microsoft Store ChatGPT/Codex (OpenAI.Codex) is not installed for this user.') | Out-Null
        return [pscustomobject]@{ Success = $false; Package = $null; Errors = @($errors) }
    }

    $appDir = Join-Path $package.InstallLocation 'app'
    $nodePath = Join-Path $appDir 'resources\cua_node\bin\node.exe'
    $cgNodeModules = Join-Path $appDir 'resources\cua_node\bin\node_modules'
    foreach ($requiredPath in @(
        $nodePath,
        $cgNodeModules,
        (Join-Path $appDir 'ChatGPT.exe'),
        (Join-Path $appDir 'chrome.dll')
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            $errors.Add('Missing ChatGPT runtime path: ' + $requiredPath) | Out-Null
        }
    }

    if (-not (Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue)) {
        $errors.Add('Windows command Invoke-CommandInDesktopPackage is unavailable.') | Out-Null
    }

    $manifest = $null
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $errors.Add('Release manifest is missing: ' + $manifestPath) | Out-Null
    } else {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $errors.Add('Release manifest is invalid: ' + $_) | Out-Null
        }
    }

    if ($manifest) {
        foreach ($junction in @($manifest.cgJunctions)) {
            if (-not $junction -or -not $junction.fromCg) { continue }
            $target = Join-Path $cgNodeModules (([string]$junction.fromCg) -replace '/', '\')
            if (-not (Test-Path -LiteralPath $target -PathType Container)) {
                $errors.Add('Missing ChatGPT node module: ' + [string]$junction.fromCg) | Out-Null
            }
        }
        foreach ($fork in @($manifest.cgAssetForks)) {
            if (-not $fork -or -not $fork.fromPackage) { continue }
            $target = Join-Path $package.InstallLocation (([string]$fork.fromPackage) -replace '/', '\')
            $expectedType = [string]$fork.type
            $exists = if ($expectedType -eq 'junction') {
                Test-Path -LiteralPath $target -PathType Container
            } elseif ($expectedType -eq 'symlink') {
                Test-Path -LiteralPath $target -PathType Leaf
            } else {
                Test-Path -LiteralPath $target
            }
            if (-not $exists) {
                $errors.Add('Missing ChatGPT asset fork target: ' + [string]$fork.fromPackage) | Out-Null
            }
        }
    }

    return [pscustomobject]@{
        Success       = ($errors.Count -eq 0)
        Package       = $package
        Errors        = @($errors)
        AppDir        = $appDir
        NodePath      = $nodePath
        CgNodeModules = $cgNodeModules
    }
}

function Assert-CodexReleaseRequirements([string]$manifestPath) {
    $result = Test-CodexReleaseRequirements $manifestPath
    if (-not $result.Success) {
        throw (($result.Errors | ForEach-Object { '- ' + $_ }) -join [Environment]::NewLine)
    }
    return $result
}
