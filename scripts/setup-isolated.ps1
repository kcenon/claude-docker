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
.EXAMPLE
    .\setup-isolated.ps1 -RepoDir C:\Projects\myapp
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
    [string]$AccountCount = '2'
)

$ErrorActionPreference = 'Stop'

# Platform guard: PowerShell 7 runs on Linux and macOS, but this helper emits
# workspace paths for the Windows Docker Desktop workflow. Mixing those paths
# into the Unix bash lifecycle can leave isolated compose mounts unusable.
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.OS -and $PSVersionTable.OS -notlike '*Windows*') {
    Write-Error "setup-isolated.ps1 is Windows-only. Use ./scripts/setup-isolated.sh on macOS or Linux."
    exit 1
}

. (Join-Path $PSScriptRoot 'lib' 'index.ps1')

$RepoDir = $RepoDir.TrimEnd('\', '/')

if (-not (Test-Path (Join-Path $RepoDir '.git'))) {
    Write-Error "Error: $RepoDir is not a git repository"
    exit 1
}

# Same order as setup-isolated.sh: the repository check first, then the count,
# so the two report the same failure for the same invocation.
# The normalized value goes into a NEW variable rather than back onto
# $AccountCount, and that is not a style choice.
#
# A param() type constraint follows the variable for its whole lifetime, not
# just the binding. $AccountCount is [string], so `$AccountCount = $null`
# stores '' -- and `$null -eq ''` is false, so the guard below never fired.
# -AccountCount 703 and -AccountCount abc were both accepted in silence, and
# the run went on to create zero clones and print a success summary, while
# setup-isolated.sh rejected the same arguments. The check read correctly and
# did nothing, which is why the .sh/.ps1 pair looked symmetric (#356).
$accountTotal = Get-NormalizedAccountCount -Value $AccountCount
if ($null -eq $accountTotal) {
    Write-Error "Error: account count must be an integer between 1 and $(Get-MaxAccountCount) (got: $AccountCount)"
    exit 1
}

function Set-CloneOrigin {
    <#
    .SYNOPSIS
    Repoint a fresh clone's origin at the source repository's own upstream.
    .DESCRIPTION
    `git clone <local-path>` sets origin to that path. An isolated container
    never sees it -- the shared source is precisely what this mode hides -- so
    an origin left pointing there makes fetch and push fail from inside the
    container. Any credential embedded in the upstream URL is stripped rather
    than copied into N clones.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Source
    )

    $upstream = & git -C $Source remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstream)) {
        Write-Host "     note: $Source has no origin remote; the clone keeps a local-path origin"
        return
    }
    $upstream = $upstream.Trim()

    # Only http(s) URLs carrying userinfo are rewritten. `ssh://git@host/path`
    # and `git@host:path` put the SSH user -- not a secret -- in that position,
    # and stripping it would break authentication.
    if ($upstream -match '^(https?://)[^/@]*@(.*)$') {
        $upstream = $Matches[1] + $Matches[2]
        Write-Host '     note: removed credentials embedded in the origin URL'
    }

    & git -C $Target remote set-url origin $upstream
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set origin on $Target"
    }
}

Write-Host "Creating $accountTotal independent clone(s)..."

for ($i = 1; $i -le $accountTotal; $i++) {
    $letter = Get-AccountLetter -Index $i
    $upper = Get-AccountLetterUpper -Index $i
    $target = "${RepoDir}-isolated-${letter}"

    if (Test-Path (Join-Path $target '.git')) {
        # Idempotent: an existing clone is left exactly as it is. Re-cloning
        # would discard whatever that account has been working on.
        Write-Host "  ${upper}: $target (already a clone, left unchanged)"
        continue
    }

    if (Test-Path $target) {
        Write-Error "Error: $target exists but is not a git repository."
        Write-Error '       Move or remove it yourself; this script never deletes host paths.'
        exit 1
    }

    # --no-hardlinks is the flag that makes this independent. Cloning a local
    # path hardlinks the object store by default, which would leave every
    # account sharing objects -- the property that disqualifies worktree mode
    # as a security boundary. Untracked files (.env, credentials) are never
    # cloned, so nothing secret travels from the source tree.
    & git clone --no-hardlinks $RepoDir $target
    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed for $target"
    }
    Set-CloneOrigin -Target $target -Source $RepoDir

    Write-Host "  ${upper}: $target (independent clone)"
}

Write-Host ''
Write-Host 'Add to .env:'
Write-Host '  ISOLATION_MODE=isolated'
for ($i = 1; $i -le $accountTotal; $i++) {
    $letter = Get-AccountLetter -Index $i
    $upper = Get-AccountLetterUpper -Index $i
    Write-Host "  ISOLATED_WORKSPACE_${upper}=${RepoDir}-isolated-${letter}"
}
Write-Host ''
Write-Host 'Then regenerate compose: scripts\generate-compose.ps1'
