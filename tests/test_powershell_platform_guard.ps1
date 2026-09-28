# test_powershell_platform_guard.ps1 — Verifies the non-Windows platform guard
# on every PowerShell entry point that has a bash counterpart.
#
# The pwsh-tests CI job runs this file on Ubuntu, where PSVersionTable.OS
# exercises the real guard predicate. Each entry point is copied into an
# isolated directory before invocation so a missing or late guard fails on a
# missing dependency instead of reaching repository, Docker, or user state.
#
# Run:  pwsh -NoProfile -File tests/test_powershell_platform_guard.ps1
# Exits non-zero on any failure; prints a summary at the end.

param()

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

$script:Pass = 0
$script:Fail = 0

function Write-Pass {
    param([Parameter(Mandatory)][string]$Label)

    Write-Host ("  PASS  {0}" -f $Label)
    $script:Pass++
}

function Write-Fail {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Detail
    )

    Write-Host ("  FAIL  {0}`n        {1}" -f $Label, $Detail)
    $script:Fail++
}

# Keep this list explicit so every new PowerShell entry point requires a
# deliberate guard decision rather than silently inheriting one from a glob.
$Guarded = @(
    [pscustomobject]@{ Path = 'scripts/install.ps1'; Counterpart = './scripts/install.sh' }
    [pscustomobject]@{ Path = 'scripts/claude-docker.ps1'; Counterpart = './scripts/claude-docker' }
    [pscustomobject]@{ Path = 'scripts/generate-compose.ps1'; Counterpart = './scripts/generate-compose.sh' }
    [pscustomobject]@{ Path = 'scripts/cleanup.ps1'; Counterpart = './scripts/cleanup.sh' }
    [pscustomobject]@{ Path = 'scripts/remove.ps1'; Counterpart = './scripts/remove.sh' }
    [pscustomobject]@{ Path = 'scripts/setup-worktrees.ps1'; Counterpart = './scripts/setup-worktrees.sh' }
    [pscustomobject]@{ Path = 'scripts/setup-isolated.ps1'; Counterpart = './scripts/setup-isolated.sh' }
    [pscustomobject]@{ Path = 'scripts/test-concurrent-git.ps1'; Counterpart = './scripts/test-concurrent-git.sh' }
)

$isNonWindowsCore = $PSVersionTable.PSEdition -eq 'Core' -and
    $PSVersionTable.OS -and $PSVersionTable.OS -notlike '*Windows*'
if (-not $isNonWindowsCore) {
    Write-Host 'SKIP: the PowerShell platform guard requires PowerShell Core on Linux or macOS.'
    exit 0
}

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$sandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) "claude-docker-pwsh-guard-$PID-$(New-Guid)"
New-Item -ItemType Directory -Path $sandboxRoot | Out-Null

try {
    Write-Host '=== Non-Windows PowerShell platform guard ==='

    foreach ($entry in $Guarded) {
        $source = Join-Path $ProjectRoot $entry.Path
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            Write-Fail "$($entry.Path) exists" 'no such file'
            continue
        }

        $leaf = Split-Path $source -Leaf
        $caseRoot = Join-Path $sandboxRoot ([System.IO.Path]::GetFileNameWithoutExtension($leaf))
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $isolatedScript = Join-Path $caseRoot $leaf
        Copy-Item -LiteralPath $source -Destination $isolatedScript

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwsh
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        [void]$startInfo.ArgumentList.Add('-NoLogo')
        [void]$startInfo.ArgumentList.Add('-NoProfile')
        [void]$startInfo.ArgumentList.Add('-NonInteractive')
        [void]$startInfo.ArgumentList.Add('-File')
        [void]$startInfo.ArgumentList.Add($isolatedScript)

        # Mandatory parameter binding precedes a script body, so give the setup
        # helpers a harmless path. If a guard is absent, validation fails
        # inside the sandbox without touching a real repository.
        if ($entry.Path -in @('scripts/setup-worktrees.ps1', 'scripts/setup-isolated.ps1')) {
            [void]$startInfo.ArgumentList.Add('-RepoDir')
            [void]$startInfo.ArgumentList.Add((Join-Path $caseRoot 'missing-repository'))
        }

        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $output = "$stdout`n$stderr".Trim()

        if ($process.ExitCode -eq 1) {
            Write-Pass "$($entry.Path) refuses with exit 1"
        } else {
            Write-Fail "$($entry.Path) refuses with exit 1" "actual exit status: $($process.ExitCode)"
        }

        $refusal = "$leaf is Windows-only"
        if ($output.Contains($refusal, [System.StringComparison]::Ordinal)) {
            Write-Pass "$($entry.Path) says why it refused"
        } else {
            Write-Fail "$($entry.Path) says why it refused" "output was: $($output ?? '<empty>')"
        }

        if ($output.Contains($entry.Counterpart, [System.StringComparison]::Ordinal)) {
            Write-Pass "$($entry.Path) points at $($entry.Counterpart)"
        } else {
            Write-Fail "$($entry.Path) points at $($entry.Counterpart)" "output did not name it: $($output ?? '<empty>')"
        }
    }
}
finally {
    Remove-Item -LiteralPath $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Passed: {0}  Failed: {1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
