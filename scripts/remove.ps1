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

# Platform guard: PowerShell 7 runs on Linux and macOS, but this remover searches
# USERPROFILE and Windows-only tool locations and omits the Linux compose
# overlay. On Unix it can leave state and resources behind while reporting a
# completed removal.
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.OS -and $PSVersionTable.OS -notlike '*Windows*') {
    Write-Error "remove.ps1 is Windows-only. Use ./scripts/remove.sh on macOS or Linux."
    exit 1
}

Import-Module "$PSScriptRoot\ClaudeDocker.psm1" -Force

$ProjectRoot = Split-Path $PSScriptRoot -Parent
Initialize-StepCounter -Total 7

# Worktrees this run decided not to delete, or tried to and could not. The
# closing summary reports them; it used to assert unconditionally that nothing
# outside this repository was touched.
$script:WorktreesLeftBehind = @()

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

function Get-ManagedWorktreePath {
    <#
    .SYNOPSIS
    Paths this installer created, folded for comparison.
    .DESCRIPTION
    setup-worktrees and setup-isolated record every workspace they create
    under PROJECT_DIR_<X> / ISOLATED_WORKSPACE_<X>, so .env is the
    authoritative list of what this tool owns. Anything outside it belongs to
    the user and must never reach a recursive delete.

    Read from .env rather than derived from NUM_ACCOUNTS: at removal time the
    count may already have been lowered, and a workspace dropped from the
    count is still one this tool created.
    #>
    param([Parameter(Mandatory)][hashtable]$EnvData)

    $managed = @()
    foreach ($key in $EnvData.Keys) {
        if ($key -match '^(PROJECT_DIR|ISOLATED_WORKSPACE)_[A-Z]+$' -and $EnvData[$key]) {
            $managed += (ConvertTo-ComparablePath -Path $EnvData[$key])
        }
    }
    return $managed
}

function Remove-Worktrees {
    Write-LogStep 'Removing git worktrees'

    $projectDir = ''
    $managedPaths = @()
    $envFile = Join-Path $ProjectRoot '.env'
    if (Test-Path $envFile) {
        $envData = Read-EnvFile -Path $envFile
        $projectDir = $envData['PROJECT_DIR']
        $managedPaths = @(Get-ManagedWorktreePath -EnvData $envData)
    }

    if (-not $projectDir) {
        Write-LogInfo 'No PROJECT_DIR found in .env - skipping worktree removal'
        return
    }

    # In a *linked* worktree `.git` is a file, and Test-Path without -PathType
    # accepts it. That is how a user's own repository ended up one loop
    # iteration away from deletion: git lists the main working tree first, so
    # standing in a linked worktree points this function at somebody else's
    # tree. remove.sh:169 requires a directory; match it.
    $gitPath = Join-Path $projectDir '.git'
    if (Test-Path $gitPath -PathType Leaf) {
        Write-LogInfo "$projectDir is a linked git worktree, not a main repository - skipping worktree removal"
        return
    }
    if (-not (Test-Path $gitPath -PathType Container)) {
        Write-LogInfo "$projectDir is not a git repository - no worktrees to remove"
        return
    }

    $worktreeCount = 0
    Push-Location $projectDir
    try {
        $listed = @(& git worktree list --porcelain 2>$null |
            Where-Object { $_ -match '^worktree (.+)$' } |
            ForEach-Object { $Matches[1] })

        $removable = @(Select-RemovableWorktree -WorktreePath $listed `
            -CurrentPath (Get-Location).Path)

        foreach ($wtPath in $removable) {
            if (-not (Test-Path $wtPath)) { continue }

            Write-LogInfo "Removing worktree: $wtPath"
            & git worktree remove $wtPath --force 2>$null
            if ($LASTEXITCODE -eq 0) {
                $worktreeCount++
                continue
            }

            # git refused. Before escalating to a recursive delete, require the
            # path to be one this tool created -- git's refusal is often the
            # last thing standing between the fallback and a directory that was
            # never ours.
            if ($managedPaths -notcontains (ConvertTo-ComparablePath -Path $wtPath)) {
                Write-LogWarn "git refused to remove $wtPath, and it is not a workspace this installer created - left in place."
                $script:WorktreesLeftBehind += $wtPath
                continue
            }

            Write-LogWarn "Force removing: $wtPath"
            try {
                Remove-Item -LiteralPath $wtPath -Recurse -Force -ErrorAction Stop
                & git worktree prune 2>$null
                $worktreeCount++
            }
            catch {
                # Swallowing this is what reduced a destroyed repository to one
                # log line; a delete that fails at uninstall time is something
                # the user has to be told about.
                Write-LogError "Could not remove $($wtPath): $($_.Exception.Message)"
                $script:WorktreesLeftBehind += $wtPath
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

    # Offer every registered runtime's state directory, not just Claude's, so
    # a codex/gemini install does not leave its state orphaned. State-dir
    # names are resolved from the runtime registry (see #267, #273).
    $found = $false
    foreach ($runtime in Get-RuntimeList -ProjectRoot $ProjectRoot) {
        $stateDir = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $runtime -Field 'stateDir'
        if (-not $stateDir) { continue }
        $stateRoot = Join-Path $env:USERPROFILE $stateDir

        if (-not (Test-Path $stateRoot)) { continue }
        $found = $true

        # List what exists
        Write-Host "  Contents of ${stateRoot}:" -ForegroundColor DarkGray
        foreach ($item in Get-ChildItem $stateRoot -ErrorAction SilentlyContinue) {
            $size = Get-FriendlySize -Bytes (Get-DirectorySize -Path $item.FullName)
            Write-Host "    $($item.Name) ($size)" -ForegroundColor DarkGray
        }

        Write-Host ''
        if (Read-Confirmation -Question "Remove all $runtime state directories (~/$stateDir)?") {
            Remove-Item $stateRoot -Recurse -Force
            Write-LogSuccess "$runtime state directories removed"
        }
        else {
            Write-LogInfo "$runtime state directories kept"
        }
    }

    if (-not $found) {
        Write-LogInfo 'No state directories found'
    }
}

function Remove-FileWithAclFallback {
    <#
    .SYNOPSIS
    Delete a file, resetting its ACL first if the initial attempt is blocked.
    Legacy installers granted "(R,W)" which omits the DELETE bit, so a plain
    Remove-Item fails with "Access is denied" on .env and rotated backups.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    }
    catch [System.UnauthorizedAccessException] {
        Write-LogWarn "Access denied on $(Split-Path -Leaf $Path) — resetting ACL and retrying."
        # Restore inheritance so the parent ACL (which usually grants delete) applies.
        & icacls $Path /reset 2>$null | Out-Null
        & icacls $Path /grant:r "${env:USERNAME}:(M)" 2>$null | Out-Null
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    }
}

function Remove-EnvFile {
    Write-LogStep 'Removing .env configuration'

    $envFile = Join-Path $ProjectRoot '.env'

    if (-not (Test-Path $envFile)) {
        Write-LogInfo 'No .env file found'
        return
    }

    if (-not (Read-Confirmation -Question 'Remove .env file (contains API keys and paths)?')) {
        Write-LogInfo '.env kept'
        return
    }

    try {
        Remove-FileWithAclFallback -Path $envFile | Out-Null
        Write-LogSuccess '.env removed'
    }
    catch {
        Write-LogError ".env could not be removed: $($_.Exception.Message)"
        Write-Host '  Fix manually: ' -ForegroundColor DarkGray -NoNewline
        Write-Host "icacls `"$envFile`" /reset && del `"$envFile`"" -ForegroundColor DarkGray
        return
    }

    # Also sweep rotated backups that inherit the same legacy (R,W) ACL.
    $backupPattern = '.env.backup.*'
    $backups = Get-ChildItem -Path $ProjectRoot -Filter $backupPattern -File -ErrorAction SilentlyContinue
    foreach ($bk in $backups) {
        try {
            Remove-FileWithAclFallback -Path $bk.FullName | Out-Null
            Write-LogInfo "Removed backup: $($bk.Name)"
        }
        catch {
            Write-LogWarn "Could not remove backup $($bk.Name): $($_.Exception.Message)"
        }
    }
}

function Remove-HostTools {
    Write-LogStep 'Removing host-installed tools (optional)'

    Write-Host '  These tools were installed on the host for authentication.' -ForegroundColor DarkGray
    Write-Host '  Skip if you use them for other projects.' -ForegroundColor DarkGray
    Write-Host ''

    # Claude Code (native install or legacy npm global)
    if (Test-Command 'claude') {
        if (Read-Confirmation -Question 'Remove Claude Code from host?') {
            # Native install: ~/.local/bin/claude.exe + ~/.local/share/claude
            $localBin = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
            $localShare = Join-Path $env:USERPROFILE ".local\share\claude"
            if (Test-Path $localBin) { Remove-Item -Path $localBin -Force -ErrorAction SilentlyContinue }
            if (Test-Path $localShare) { Remove-Item -Path $localShare -Recurse -Force -ErrorAction SilentlyContinue }
            # Legacy npm global (if still present)
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

    if ($script:WorktreesLeftBehind.Count -gt 0) {
        Write-Host 'Worktrees left in place (review manually):' -ForegroundColor Yellow
        foreach ($wt in $script:WorktreesLeftBehind) {
            Write-Host "  - $wt"
        }
        Write-Host ''
    }

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
