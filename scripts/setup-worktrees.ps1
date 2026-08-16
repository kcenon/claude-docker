#Requires -Version 5.1
<#
.SYNOPSIS
    Setup git worktrees for Tier B concurrent editing (supports N accounts).
.DESCRIPTION
    PowerShell port of scripts/setup-worktrees.sh.
    Creates N git worktrees from branches for independent container editing.
.PARAMETER RepoDir
    Path to the git repository (required).
.PARAMETER Branches
    Branch names for worktrees. Defaults to ('worktree-a', 'worktree-b').
.EXAMPLE
    .\setup-worktrees.ps1 -RepoDir C:\Projects\myapp
    .\setup-worktrees.ps1 -RepoDir C:\Projects\myapp -Branches 'feat-a','feat-b','feat-c'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepoDir,

    [string[]]$Branches = @('worktree-a', 'worktree-b')
)

$ErrorActionPreference = 'Stop'

# Platform guard: PowerShell 7 runs on Linux and macOS, but this helper emits
# worktree paths for the Windows Docker Desktop workflow. Mixing those paths
# into the Unix bash lifecycle can leave Tier B compose mounts unusable.
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.OS -and $PSVersionTable.OS -notlike '*Windows*') {
    Write-Error "setup-worktrees.ps1 is Windows-only. Use ./scripts/setup-worktrees.sh on macOS or Linux."
    exit 1
}

# Excel-style account letters, shared with the generators and the installer.
# The arithmetic this replaces -- [char](96 + $idx) -- was correct only for
# the first 26 accounts and produced punctuation past 'z'. That was unreachable
# while install.ps1 passed exactly two branches; it is reachable now that the
# installer drives this from NUM_ACCOUNTS, whose validator allows up to 702.
# Nested two-argument Join-Path: the three-argument form is PowerShell 7+.
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'index.ps1')

$RepoDir = $RepoDir.TrimEnd('\', '/')

# Validate
if (-not (Test-Path (Join-Path $RepoDir '.git'))) {
    Write-Error "Error: $RepoDir is not a git repository"
    exit 1
}

Write-Host "Creating $($Branches.Count) worktree(s)..."

Push-Location $RepoDir
try {
    for ($i = 0; $i -lt $Branches.Count; $i++) {
        $idx = $i + 1
        $branch = $Branches[$i]
        $letter = Get-AccountLetter -Index $idx
        $upper  = Get-AccountLetterUpper -Index $idx
        $worktree = "${RepoDir}-${letter}"

        & git branch $branch 2>$null
        & git worktree add $worktree $branch

        Write-Host "  ${upper}: $worktree (branch: $branch)"
    }
}
finally {
    Pop-Location
}

Write-Host ''
Write-Host 'Add to .env:'
for ($i = 0; $i -lt $Branches.Count; $i++) {
    $idx = $i + 1
    $letter = Get-AccountLetter -Index $idx
    $upper  = Get-AccountLetterUpper -Index $idx
    Write-Host "  PROJECT_DIR_${upper}=${RepoDir}-${letter}"
}
