#Requires -Version 5.1
<#
.SYNOPSIS
    Complete removal script for claude-docker (Windows PowerShell port).
.DESCRIPTION
    PowerShell port of scripts/remove.sh.
    Reverses everything install.ps1 set up: containers, volumes, images,
    worktrees, state directories, .env, and optionally host tools.
.EXAMPLE
    .\scripts\remove.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\ClaudeDocker.psm1" -Force

$ProjectRoot = Split-Path $PSScriptRoot -Parent
Initialize-StepCounter -Total 7

# --- Compose Command Discovery ------------------------------------------------

function Get-FullComposeArgs {
    <#
    .SYNOPSIS
    Build the widest compose command covering all possible overlays.
    Ensures we catch containers/volumes from any configuration.
    #>
    $args_ = @('-f', (Join-Path $ProjectRoot 'docker-compose.yml'))

    # Windows never needs linux override
    # Always include worktree overlay if it exists (to catch Tier B resources)
    $wtFile = Join-Path $ProjectRoot 'docker-compose.worktree.yml'
    if (Test-Path $wtFile) {
        $args_ += @('-f', $wtFile)
    }

    return $args_
}

# --- Removal Steps ------------------------------------------------------------

function Remove-ContainersAndVolumes {
    Write-LogStep 'Stopping and removing containers + volumes'

    Push-Location $ProjectRoot
    try {
        Write-LogInfo 'Stopping containers...'
        $fullArgs = @(Get-FullComposeArgs)
        & docker compose @fullArgs down --remove-orphans -v 2>$null

        # Also try base compose alone (in case overlay files were deleted)
        & docker compose down --remove-orphans -v 2>$null

        # Remove any dangling containers with the project prefix
        $containers = & docker ps -a --filter 'label=com.docker.compose.project=claude-docker' -q 2>$null
        if ($containers) {
            Write-LogInfo 'Removing leftover containers...'
            foreach ($cid in $containers) {
                & docker rm -f $cid 2>$null | Out-Null
            }
        }

        Write-LogSuccess 'Containers and volumes removed'
    }
    finally {
        Pop-Location
    }
}

function Remove-DockerImage {
    Write-LogStep 'Removing Docker image'

    $image = 'claude-code-base:latest'

    $inspect = & docker image inspect $image 2>&1
    if ($LASTEXITCODE -eq 0) {
        if (Read-Confirmation -Question "Remove Docker image '$image'?") {
            & docker rmi $image 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-LogWarn 'Image in use by other containers. Force removing...'
                & docker rmi -f $image 2>$null
            }
            Write-LogSuccess "Image '$image' removed"
        }
        else {
            Write-LogInfo 'Image kept'
        }
    }
    else {
        Write-LogInfo "Image '$image' not found (already removed or never built)"
    }

    # Clean up dangling images
    $dangling = & docker images -f 'dangling=true' -q 2>$null
    if ($dangling) {
        Write-LogInfo 'Cleaning dangling images...'
        foreach ($imgId in $dangling) {
            & docker rmi $imgId 2>$null | Out-Null
        }
    }
}

function Remove-Worktrees {
    Write-LogStep 'Removing git worktrees'

    $projectDir = ''
    $envFile = Join-Path $ProjectRoot '.env'
    if (Test-Path $envFile) {
        $envData = Read-EnvFile -Path $envFile
        $projectDir = $envData['PROJECT_DIR']
    }

    if (-not $projectDir) {
        Write-LogInfo 'No PROJECT_DIR found in .env - skipping worktree removal'
        return
    }

    if (-not (Test-Path (Join-Path $projectDir '.git'))) {
        Write-LogInfo "$projectDir is not a git repository - no worktrees to remove"
        return
    }

    $worktreeCount = 0
    Push-Location $projectDir
    try {
        $currentDir = (Get-Location).Path
        $worktrees = & git worktree list --porcelain 2>$null |
            Where-Object { $_ -match '^worktree (.+)$' } |
            ForEach-Object { $Matches[1] }

        foreach ($wtPath in $worktrees) {
            if ($wtPath -ne $currentDir -and (Test-Path $wtPath)) {
                Write-LogInfo "Removing worktree: $wtPath"
                & git worktree remove $wtPath --force 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-LogWarn "Force removing: $wtPath"
                    Remove-Item $wtPath -Recurse -Force -ErrorAction SilentlyContinue
                    & git worktree prune 2>$null
                }
                $worktreeCount++
            }
        }
    }
    finally {
        Pop-Location
    }

    if ($worktreeCount -eq 0) {
        Write-LogInfo 'No worktrees found'
    }
    else {
        Write-LogSuccess "$worktreeCount worktree(s) removed"
    }
}

function Remove-StateDirectories {
    Write-LogStep 'Removing state directories'

    $stateRoot = Join-Path $env:USERPROFILE '.claude-state'

    if (-not (Test-Path $stateRoot)) {
        Write-LogInfo "No state directories found at $stateRoot"
        return
    }

    # List what exists
    Write-Host "  Contents of ${stateRoot}:" -ForegroundColor DarkGray
    foreach ($item in Get-ChildItem $stateRoot -ErrorAction SilentlyContinue) {
        $size = Get-FriendlySize -Bytes (Get-DirectorySize -Path $item.FullName)
        Write-Host "    $($item.Name) ($size)" -ForegroundColor DarkGray
    }

    Write-Host ''
    if (Read-Confirmation -Question 'Remove all account state directories (~/.claude-state)?') {
        Remove-Item $stateRoot -Recurse -Force
        Write-LogSuccess 'State directories removed'
    }
    else {
        Write-LogInfo 'State directories kept'
    }
}

function Remove-EnvFile {
    Write-LogStep 'Removing .env configuration'

    $envFile = Join-Path $ProjectRoot '.env'

    if (Test-Path $envFile) {
        if (Read-Confirmation -Question 'Remove .env file (contains API keys and paths)?') {
            Remove-Item $envFile -Force
            Write-LogSuccess '.env removed'
        }
        else {
            Write-LogInfo '.env kept'
        }
    }
    else {
        Write-LogInfo 'No .env file found'
    }
}

function Remove-HostTools {
    Write-LogStep 'Removing host-installed tools (optional)'

    Write-Host '  These tools were installed on the host for authentication.' -ForegroundColor DarkGray
    Write-Host '  Skip if you use them for other projects.' -ForegroundColor DarkGray
    Write-Host ''

    # Claude Code (npm global)
    if (Test-Command 'claude') {
        if (Read-Confirmation -Question 'Remove Claude Code from host (npm global)?') {
            & npm uninstall -g @anthropic-ai/claude-code 2>$null
            Write-LogSuccess 'Claude Code removed from host'
        }
        else {
            Write-LogInfo 'Claude Code kept on host'
        }
    }
    else {
        Write-LogInfo 'Claude Code not installed on host'
    }
}

function Show-RemovalSummary {
    Write-Host ''
    Write-Host '============================================' -ForegroundColor Green
    Write-Host '  Removal Complete' -ForegroundColor Green
    Write-Host '============================================' -ForegroundColor Green
    Write-Host ''
    Write-Host 'What was removed:' -ForegroundColor White
    Write-Host '  - Docker containers and named volumes'
    Write-Host '  - Docker image (if confirmed)'
    Write-Host '  - Git worktrees (if any)'
    Write-Host '  - State directories (if confirmed)'
    Write-Host '  - .env file (if confirmed)'
    Write-Host ''
    Write-Host 'What was NOT removed:' -ForegroundColor White
    Write-Host '  - This repository (claude-docker\)'
    Write-Host '  - Docker Desktop itself'
    Write-Host '  - Your project source code'
    Write-Host ''
    Write-Host 'To reinstall: .\scripts\install.ps1' -ForegroundColor DarkGray
    Write-Host ''
}

# --- Main ---------------------------------------------------------------------

Write-Host ''
Write-Host '============================================' -ForegroundColor Red
Write-Host '  Claude Docker - Complete Removal' -ForegroundColor Red
Write-Host '============================================' -ForegroundColor Red
Write-Host ''
Write-LogWarn 'This will remove all claude-docker components from your system.'
Write-Host ''

if (-not (Read-Confirmation -Question 'Proceed with removal?')) {
    Write-LogInfo 'Removal cancelled.'
    exit 0
}

Remove-ContainersAndVolumes
Remove-DockerImage
Remove-Worktrees
Remove-StateDirectories
Remove-EnvFile
Remove-HostTools
Show-RemovalSummary
