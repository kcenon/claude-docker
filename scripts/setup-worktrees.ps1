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
        $letter = [char](96 + $idx)  # a, b, c, ...
        $upper  = [char](64 + $idx)  # A, B, C, ...
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
    $letter = [char](96 + $idx)
    $upper  = [char](64 + $idx)
    Write-Host "  PROJECT_DIR_${upper}=${RepoDir}-${letter}"
}
