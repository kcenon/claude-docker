# tui-release.ps1 — download a prebuilt claude-docker-tui binary from GitHub Releases.
#
# Dot-source this file with:
#
#   . (Join-Path $PSScriptRoot 'lib' 'tui-release.ps1')
#
# Mirrors scripts/lib/tui-release.sh. Exposes:
#
#   Install-TuiRelease -Destination <path>
#
# Auto-detects host arch (always windows on this script), fetches the matching
# asset and its .sha256 file from the "latest" release of $env:TUI_RELEASE_REPO
# (falls back to 'kcenon/claude-docker'), verifies the checksum, and installs
# the binary at -Destination. Returns $true on success, $false on any failure;
# never leaves a partially-installed binary at -Destination.
#
# Requires Write-LogInfo / Write-LogWarn / Write-LogError from ClaudeDocker.psm1
# to be loaded by the caller.

# No re-source guard: see lib/index.ps1 for rationale (PowerShell `& file.ps1`
# uses sibling script scopes, so a $Global guard would suppress definitions in
# any later sibling script).

function Install-TuiRelease {
    <#
    .SYNOPSIS
    Download, checksum-verify, and install a prebuilt claude-docker-tui binary
    from GitHub Releases. PowerShell port of download_tui_release (bash).
    .PARAMETER Destination
    Absolute path where the binary should be installed (e.g. tui\claude-docker-tui.exe).
    .OUTPUTS
    [bool] $true on success, $false on any failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destination
    )

    $repo = if ($env:TUI_RELEASE_REPO) { $env:TUI_RELEASE_REPO } else { 'kcenon/claude-docker' }

    # Architecture detection — Windows-only port, so OS is fixed.
    $procArch = $env:PROCESSOR_ARCHITECTURE
    $arch = switch -Regex ($procArch) {
        '^(AMD64|x86_64)$' { 'amd64' }
        '^(ARM64|aarch64)$' { 'arm64' }
        default { $null }
    }
    if (-not $arch) {
        Write-LogError "Unsupported architecture for release download: $procArch"
        return $false
    }

    $asset = "claude-docker-tui-windows-${arch}.exe"
    $baseUrl = "https://github.com/${repo}/releases/latest/download"
    $url = "${baseUrl}/${asset}"
    $shaUrl = "${url}.sha256"

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $assetPath = Join-Path $tmp $asset
    $shaPath = "$assetPath.sha256"

    try {
        Write-LogInfo "Downloading $asset from GitHub Releases..."
        try {
            # Invoke-WebRequest follows redirects (GitHub Releases → S3) by default.
            # -UseBasicParsing keeps PS 5.1 from instantiating IE for HTML parsing.
            Invoke-WebRequest -Uri $url -OutFile $assetPath -UseBasicParsing -ErrorAction Stop
            Invoke-WebRequest -Uri $shaUrl -OutFile $shaPath -UseBasicParsing -ErrorAction Stop
        }
        catch {
            Write-LogError "Failed to download $url ($($_.Exception.Message))"
            return $false
        }

        # Checksum file format from sha256sum/shasum -a 256: "<hex>  <filename>".
        # PS 5.1 has no -Raw default for Get-Content; explicit single-line read.
        $expected = (Get-Content $shaPath -TotalCount 1).Split(' ')[0].ToLowerInvariant()
        if (-not $expected -or $expected.Length -lt 64) {
            Write-LogError "SHA256 checksum file is malformed for $asset"
            return $false
        }
        $actual = (Get-FileHash -Path $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -ne $actual) {
            Write-LogError "SHA256 verification FAILED for $asset - aborting install."
            return $false
        }

        # Stage to <dest>.part then rename so a failure mid-copy never leaves a
        # corrupt binary at the final path.
        $destDir = Split-Path -Parent $Destination
        if ($destDir -and -not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        $partPath = "${Destination}.part"
        Move-Item -Path $assetPath -Destination $partPath -Force
        Move-Item -Path $partPath -Destination $Destination -Force

        Write-LogInfo "Installed $Destination"
        return $true
    }
    finally {
        if (Test-Path $tmp) { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
