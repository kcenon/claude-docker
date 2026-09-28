#Requires -Version 7.0
<#
.SYNOPSIS
    Create independent per-account clones for ISOLATION_MODE=isolated.
.DESCRIPTION
    PowerShell port of scripts/setup-isolated.sh.

    This is the isolated-mode counterpart to setup-worktrees.ps1, and the
    difference between them is the whole point of the two modes. `git worktree`
    gives each account its own working tree but ONE shared object store and
    administrative directory, so an account can still read every branch and
    rewrite refs the others depend on. This script produces fully independent
    clones instead: no hard links, no alternates, nothing shared.
.PARAMETER RepoDir
    Path to the source git repository (required).
.PARAMETER AccountCount
    Number of accounts to create clones for. Defaults to 2, matching the
    compose generator's NUM_ACCOUNTS default.
.PARAMETER DryRun
    Print clone/state/mount/network/resource plans without persistent writes.
    Requires Python 3.9+ on the host.
.EXAMPLE
    .\setup-isolated.ps1 -RepoDir C:\Projects\myapp -DryRun
    .\setup-isolated.ps1 -RepoDir C:\Projects\myapp -AccountCount 4
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepoDir,

    # A string, validated in the body against lib/index.ps1, rather than
    # [ValidateRange(1, 702)] on an [int] (#356). Two reasons: an attribute
    # binds before the body runs, so it cannot consult the shared bound and
    # has to re-spell it; and [int] makes PowerShell reject a non-numeric
    # value with its own binding error, where setup-isolated.sh prints
    # "account count must be an integer between 1 and 702 (got: ...)".
    # An int argument still binds -- PowerShell coerces it to string.
    [string]$AccountCount = '2',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Platform guard: PowerShell 7 runs on Linux and macOS, but this helper emits
# workspace paths for the Windows Docker Desktop workflow. Mixing those paths
# into the Unix bash lifecycle can leave isolated compose mounts unusable.
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.OS -and $PSVersionTable.OS -notlike '*Windows*') {
    Write-Error "setup-isolated.ps1 is Windows-only. Use ./scripts/setup-isolated.sh on macOS or Linux."
    exit 1
}

. (Join-Path $PSScriptRoot 'lib/host.ps1')
$policyArgs = @('setup', '--source', $RepoDir, '--count', $AccountCount)
if ($DryRun) { $policyArgs += '--dry-run' }
Invoke-HostPolicy -ProjectRoot (Split-Path -Parent $PSScriptRoot) @policyArgs
