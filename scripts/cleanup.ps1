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
.PARAMETER Backups
    Remove stale .env.backup.* and .env.bak files older than -BackupAgeDays
    days from the project root. Preserves .env, .env.example, and fresh
    backups.
.PARAMETER BackupAgeDays
    Age threshold in days for -Backups removal. Default: 7.
#>
[CmdletBinding()]
param(
    [string]$RepoDir,
    [Alias('Yes')][switch]$Force,
    [Alias('No')][switch]$SkipState,
    [Alias('B')][switch]$Backups,
    [int]$BackupAgeDays = 7
)

# Platform guard: PowerShell 7 runs on Linux and macOS, but this script resolves
# runtime state through USERPROFILE. That is not the state root created by the
# bash installer, so cleanup can report success while leaving the real state
# behind.
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.OS -and $PSVersionTable.OS -notlike '*Windows*') {
    Write-Error "cleanup.ps1 is Windows-only. Use ./scripts/cleanup.sh on macOS or Linux."
    exit 1
}

if ($Force -and $SkipState) {
    Write-Error '-Force and -SkipState are mutually exclusive.'
    exit 2
}

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\ClaudeDocker.psm1" -Force

$ProjectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $ProjectRoot

try {
    if ($Backups) {
        Write-Host "=== Removing stale .env backup files (>$BackupAgeDays days) ===" -ForegroundColor Cyan
        $cutoff = (Get-Date).AddDays(-$BackupAgeDays)
        Get-ChildItem -Path $ProjectRoot -Filter '.env.backup.*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force
        Get-ChildItem -Path $ProjectRoot -Filter '.env.bak' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force
    }

    Write-Host '=== Stopping containers ===' -ForegroundColor Cyan
    & docker compose down --remove-orphans 2>$null
    # Ignore errors if no containers running

    Write-Host '=== Removing named volumes ===' -ForegroundColor Cyan
    & docker compose down -v 2>$null

    Write-Host '=== Removing worktrees (if Tier B) ===' -ForegroundColor Cyan
    if ($RepoDir -and (Test-Path (Join-Path $RepoDir '.git'))) {
        # .env names the workspaces the installer created. Read before the
        # Push-Location so the path stays relative to the project root.
        $envData = $null
        $envFile = Join-Path $ProjectRoot '.env'
        if (Test-Path $envFile) { $envData = Read-EnvFile -Path $envFile }

        Push-Location $RepoDir
        try {
            $listed = @(& git worktree list --porcelain 2>$null |
                Where-Object { $_ -match '^worktree (.+)$' } |
                ForEach-Object { $Matches[1] })

            # The raw current-directory comparison this replaces could not
            # match on Windows -- git reports forward slashes, Get-Location
            # backslashes -- so -RepoDir itself was offered up for removal
            # (#342). git refuses for a main working tree, but not when
            # -RepoDir names a linked one, which is the tree the check
            # existed to preserve.
            $removable = @(Select-RemovableWorktree -WorktreePath $listed `
                -CurrentPath (Get-Location).Path)

            # Ownership check and failure reporting kept in step with
            # cleanup.sh: a worktree the user added themselves is not this
            # tool's to delete, and a refusal that is swallowed reads as a
            # successful removal.
            foreach ($wt in $removable) {
                if (-not (Test-OwnedWorktreePath -Path $wt -ProjectDir $RepoDir -EnvData $envData)) {
                    Write-Host "  Keeping worktree not created by claude-docker: $wt"
                    continue
                }
                Write-Host "  Removing worktree: $wt"
                & git worktree remove $wt --force 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "git declined to remove $wt - left in place."
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
        $shouldRemove = Read-Confirmation -Question "Remove every runtime's state directory (~/.*-state)?"
    }

    if ($shouldRemove) {
        # Remove every registered runtime's state directory, not just
        # Claude's, so a codex/gemini install is fully cleaned up (see #273).
        foreach ($runtime in Get-RuntimeList -ProjectRoot $ProjectRoot) {
            $stateDir = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $runtime -Field 'stateDir'
            if (-not $stateDir) { continue }
            $statePath = Join-Path $env:USERPROFILE $stateDir
            if (Test-Path $statePath) {
                Remove-Item $statePath -Recurse -Force
                Write-Host "  Removed: ~/$stateDir"
            }
        }
        Write-Host '  State directories removed.'
    }
    else {
        Write-Host '  Skipped.'
    }

    Write-Host '=== Cleanup complete ===' -ForegroundColor Green
}
finally {
    Pop-Location
}
