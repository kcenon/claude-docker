#Requires -Version 5.1
<#
.SYNOPSIS
    Cleanup containers, worktrees, and state directories.
.DESCRIPTION
    PowerShell port of scripts/cleanup.sh.
    Stops containers, removes volumes, cleans up worktrees, and optionally
    removes state directories.
.PARAMETER RepoDir
    Git repository path for worktree cleanup (Tier B). Optional.
#>
[CmdletBinding()]
param(
    [string]$RepoDir
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\ClaudeDocker.psm1" -Force

$ProjectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $ProjectRoot

try {
    Write-Host '=== Stopping containers ===' -ForegroundColor Cyan
    & docker compose down --remove-orphans 2>$null
    # Ignore errors if no containers running

    Write-Host '=== Removing named volumes ===' -ForegroundColor Cyan
    & docker compose down -v 2>$null

    Write-Host '=== Removing worktrees (if Tier B) ===' -ForegroundColor Cyan
    if ($RepoDir -and (Test-Path (Join-Path $RepoDir '.git'))) {
        Push-Location $RepoDir
        try {
            $currentDir = (Get-Location).Path
            $worktrees = & git worktree list --porcelain 2>$null |
                Where-Object { $_ -match '^worktree (.+)$' } |
                ForEach-Object { $Matches[1] }

            foreach ($wt in $worktrees) {
                if ($wt -ne $currentDir) {
                    Write-Host "  Removing worktree: $wt"
                    & git worktree remove $wt --force 2>$null
                }
            }
        }
        finally {
            Pop-Location
        }
    }

    Write-Host '=== Removing state directories ===' -ForegroundColor Cyan
    if (Read-Confirmation -Question 'Remove ~/.claude-state/*?') {
        $statePath = Join-Path $env:USERPROFILE '.claude-state'
        if (Test-Path $statePath) {
            Remove-Item $statePath -Recurse -Force
            Write-Host '  State directories removed.'
        }
    }
    else {
        Write-Host '  Skipped.'
    }

    Write-Host '=== Cleanup complete ===' -ForegroundColor Green
}
finally {
    Pop-Location
}
