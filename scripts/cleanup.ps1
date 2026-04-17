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
.PARAMETER Force
    Remove state directories without prompting. Without -Force, an
    interactive console prompts y/N; a non-interactive host (CI, piped
    stdin) aborts instead of hanging.
.PARAMETER SkipState
    Decline state-directory removal non-interactively. Useful in automation
    that only wants container/volume/worktree cleanup.
#>
[CmdletBinding()]
param(
    [string]$RepoDir,
    [Alias('Yes')][switch]$Force,
    [Alias('No')][switch]$SkipState
)

if ($Force -and $SkipState) {
    Write-Error '-Force and -SkipState are mutually exclusive.'
    exit 2
}

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
    $shouldRemove = $false
    if ($Force) {
        $shouldRemove = $true
    } elseif ($SkipState) {
        $shouldRemove = $false
    } else {
        # Interactive-only path: detect a real host that can accept input.
        # Read-Confirmation throws on non-interactive hosts (ServerRemoteHost,
        # redirected stdin) which prevents CI hangs.
        $interactive = ($Host.Name -ne 'ServerRemoteHost') -and (-not [Console]::IsInputRedirected)
        if (-not $interactive) {
            Write-Error '  stdin is not interactive. Pass -Force to remove state non-interactively, or -SkipState to skip.'
            exit 1
        }
        $shouldRemove = Read-Confirmation -Question 'Remove ~/.claude-state/*?'
    }

    if ($shouldRemove) {
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
