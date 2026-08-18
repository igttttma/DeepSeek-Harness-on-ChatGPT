param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$RequirementsScript,

    [string]$ResultPath = ''
)

$ErrorActionPreference = 'Stop'

try {
    if (-not (Test-Path -LiteralPath $RequirementsScript -PathType Leaf)) {
        throw ('requirements helper missing: ' + $RequirementsScript)
    }
    . $RequirementsScript
    $result = Assert-CodexReleaseRequirements $ManifestPath
    $message = 'OK: ' + $result.Package.PackageFullName
    if ($ResultPath) {
        [IO.File]::WriteAllText($ResultPath, $message, [Text.UTF8Encoding]::new($false))
    }
    Write-Host $message
    exit 0
} catch {
    $message = "DeepSeek Harness (on ChatGPT) cannot be installed because the local ChatGPT runtime is incomplete.`r`n`r`n$($_.Exception.Message)"
    if ($ResultPath) {
        [IO.File]::WriteAllText($ResultPath, $message, [Text.UTF8Encoding]::new($false))
    }
    [Console]::Error.WriteLine($message)
    exit 20
}
