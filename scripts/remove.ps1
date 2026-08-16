#Requires -Version 7.0
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

function Get-ComposeArgsForMode {
    <#
    .SYNOPSIS
    Build the compose command for exactly one isolation mode.
    .DESCRIPTION
    This used to attach base + worktree unconditionally and call it "the widest
    compose command covering all possible overlays". It is not a valid set. The
    worktree and isolated overlays both carry `!override` volume lists and
    disagree on working_dir, and the worktree overlay interpolates
    ${PROJECT_DIR_A} -- which an isolated install never sets, so compose
    refuses the whole file with "invalid spec: :/project-a: empty section
    between colons".

    That failure was discarded by `2>$null`, so an isolated teardown fell
    through to a bare `docker compose down` that did not know the isolated
    overlay, and the isolated_net_* bridge networks survived a run that
    reported "Removal Complete".

    Windows never needs the linux override.
    #>
    param([Parameter(Mandatory)][string]$Mode)

    $args_ = @('-f', (Join-Path $ProjectRoot 'docker-compose.yml'))
    switch ($Mode) {
        'worktree' { $args_ += @('-f', (Join-Path $ProjectRoot 'docker-compose.worktree.yml')) }
        'isolated' { $args_ += @('-f', (Join-Path $ProjectRoot 'docker-compose.isolated.yml')) }
    }
    return $args_
}

function Get-TeardownMode {
    <#
    .SYNOPSIS
    The modes worth attempting, in order.
    .DESCRIPTION
    Removal has to catch resources from whatever mode the installation is in
    now and from modes it used to be in -- switching leaves the previous
    stack's containers and networks behind, and this is the script meant to
    find them. So every mode whose overlay exists gets its own `down`, rather
    than one `down` carrying every overlay.
    #>
    $modes = @('shared')
    if (Test-Path (Join-Path $ProjectRoot 'docker-compose.worktree.yml')) { $modes += 'worktree' }
    if (Test-Path (Join-Path $ProjectRoot 'docker-compose.isolated.yml')) { $modes += 'isolated' }
    return $modes
}

# --- Removal Steps ------------------------------------------------------------

function Remove-ContainersAndVolumes {
    Write-LogStep 'Stopping and removing containers + volumes'

    Push-Location $ProjectRoot
    try {
        # One `down` per mode. A mode this installation was never in will
        # usually fail on an unset per-account path, and that is expected --
        # what is not acceptable is the previous behaviour, where the
        # configured mode's failure looked identical to it because both were
        # discarded.
        $failed = @()
        foreach ($mode in Get-TeardownMode) {
            $modeArgs = @(Get-ComposeArgsForMode -Mode $mode)
            Write-LogInfo "Stopping containers ($mode stack)..."
            $out = & docker compose @modeArgs down --remove-orphans -v 2>&1
            if ($LASTEXITCODE -ne 0) {
                $failed += $mode
                Write-LogWarn "  $mode stack: docker compose down exited $LASTEXITCODE"
                foreach ($line in @($out)) { Write-Host "      $line" -ForegroundColor DarkGray }
            }
        }

        if ($failed.Count -gt 0) {
            Write-LogWarn "Teardown did not complete for: $($failed -join ', ')"
            Write-LogWarn '  A mode this installation never used is expected to fail here.'
            Write-LogWarn "  Check 'docker ps -a' and 'docker network ls' if resources remain."
        }

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
    $envData = $null
    $envFile = Join-Path $ProjectRoot '.env'
    if (Test-Path $envFile) {
        $envData = Read-EnvFile -Path $envFile
        $projectDir = $envData['PROJECT_DIR']
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

        # Not being the current tree is not the same as being ours. Ownership
        # gates the target list, not just the fallback: a worktree the user
        # added themselves in this repository was previously removed with
        # --force before any fallback was reached.
        $targets = @()
        foreach ($wtPath in $removable) {
            if (-not (Test-Path $wtPath)) { continue }
            if (Test-OwnedWorktreePath -Path $wtPath -ProjectDir $projectDir -EnvData $envData) {
                $targets += $wtPath
            }
            else {
                Write-LogInfo "Keeping worktree not created by claude-docker: $wtPath"
            }
        }

        if ($targets.Count -eq 0) {
            Write-LogInfo 'No claude-docker worktrees found'
            return
        }

        # Every other destructive step here prompts for itself. This one did
        # not, and the run-level "Proceed with removal?" never names what is
        # about to go.
        Write-Host ''
        Write-Host 'Worktrees to remove:' -ForegroundColor White
        foreach ($wtPath in $targets) { Write-Host "  - $wtPath" }
        Write-Host ''
        if (-not (Read-Confirmation -Question "Remove the $($targets.Count) worktree(s) listed above?")) {
            Write-LogInfo 'Worktrees kept'
            return
        }

        foreach ($wtPath in $targets) {
            Write-LogInfo "Removing worktree: $wtPath"
            & git worktree remove $wtPath --force 2>$null
            if ($LASTEXITCODE -eq 0) {
                $worktreeCount++
                continue
            }

            # No recursive-delete fallback. git declining to remove a worktree
            # it created is information -- the path is locked, or it is not the
            # tree we think it is. Escalating past that refusal is what turned
            # a wrong path into data loss.
            Write-LogWarn "git declined to remove $wtPath - left in place."
            Write-LogWarn '  Inspect it and remove it manually if it is no longer needed.'
            $script:WorktreesLeftBehind += $wtPath
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
