#Requires -Version 5.1
<#
.SYNOPSIS
    Setup git worktrees for Tier B concurrent editing.
.DESCRIPTION
    PowerShell port of scripts/setup-worktrees.sh.
    Creates two git worktrees from branches for independent container editing.
.PARAMETER RepoDir
    Path to the git repository (required).
.PARAMETER BranchA
    Branch name for worktree A (default: worktree-a).
.PARAMETER BranchB
    Branch name for worktree B (default: worktree-b).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepoDir,

    [string]$BranchA = 'worktree-a',
    [string]$BranchB = 'worktree-b'
)

$ErrorActionPreference = 'Stop'

$RepoDir = $RepoDir.TrimEnd('\', '/')
$WorktreeA = "${RepoDir}-a"
$WorktreeB = "${RepoDir}-b"

# Validate
if (-not (Test-Path (Join-Path $RepoDir '.git'))) {
    Write-Error "Error: $RepoDir is not a git repository"
    exit 1
}

# Create branches if they don't exist (based on current HEAD)
Push-Location $RepoDir
try {
    & git branch $BranchA 2>$null
    & git branch $BranchB 2>$null

    # Create worktrees
    & git worktree add $WorktreeA $BranchA
    & git worktree add $WorktreeB $BranchB
}
finally {
    Pop-Location
}

Write-Host 'Worktrees created:'
Write-Host "  A: $WorktreeA (branch: $BranchA)"
Write-Host "  B: $WorktreeB (branch: $BranchB)"
Write-Host ''
Write-Host 'Add to .env:'
Write-Host "  PROJECT_DIR_A=$WorktreeA"
Write-Host "  PROJECT_DIR_B=$WorktreeB"
