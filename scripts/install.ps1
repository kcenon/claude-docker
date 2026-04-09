#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive setup script for claude-docker (Windows PowerShell port).
.DESCRIPTION
    PowerShell port of scripts/install.sh.
    Guides users through environment setup via Q&A, checks prerequisites,
    generates .env, builds images, and starts containers.
.EXAMPLE
    .\scripts\install.ps1
    # or from cmd.exe:
    powershell -ExecutionPolicy Bypass -File scripts\install.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Platform guard: PowerShell 7 (Core) runs on Linux and macOS, but this script
# writes Windows-specific state (USERPROFILE paths, docker-compose without the
# Linux UID/GID override). Refuse to run outside Windows and point users at the
# bash installer.
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.OS -and $PSVersionTable.OS -notlike '*Windows*') {
    Write-Error "install.ps1 is Windows-only. Use ./scripts/install.sh on macOS or Linux."
    exit 1
}

# Canonical .env key list (must be written by all platform installers):
#   HOME, PROJECT_DIR, CONTAINER_PROJECT_DIR, CLAUDE_CONFIG_SOURCE (optional),
#   CLAUDE_CODE_VERSION (optional), CLAUDE_API_KEY_A/B (Path B only),
#   PROJECT_DIR_A/B + CONTAINER_PROJECT_DIR_A/B (Tier B only),
#   GIT_USER_NAME, GIT_USER_EMAIL (optional)
#
# Windows note: UID/GID are intentionally NOT written. Windows has no POSIX
# UID/GID concept, and docker-compose.linux.yml (which consumes them) is not
# activated on the Windows/WSL2 Docker Desktop backend. WSL2 users running
# the Linux container with WSL2-backed Docker should use scripts/install.sh
# from inside WSL2 instead, so UID/GID is correctly populated.

Import-Module "$PSScriptRoot\ClaudeDocker.psm1" -Force

$ProjectRoot = Split-Path $PSScriptRoot -Parent

# --- Configuration State -----------------------------------------------------

$Script:AuthPath = ''
$Script:Tier = ''
$Script:SourceDir = ''
$Script:ClaudeVersion = ''
$Script:ApiKeyA = ''
$Script:ApiKeyB = ''

# --- I/O Latency Benchmark ---------------------------------------------------

function Measure-IoLatency {
    param([string]$Dir)

    $tmpFile = Join-Path $Dir ".io_benchmark_$PID"
    try {
        $elapsed = (Measure-Command {
            [System.IO.File]::WriteAllBytes($tmpFile, (New-Object byte[] 4096))
            $null = [System.IO.File]::ReadAllBytes($tmpFile)
        }).TotalMilliseconds
        return [math]::Round($elapsed)
    }
    catch {
        return 0
    }
    finally {
        if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
    }
}

# --- Prerequisite Checks -----------------------------------------------------

function Test-DockerDesktopRunning {
    $null -ne (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)
}

function Start-DockerDesktop {
    $exePaths = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Docker\Docker Desktop.exe"
    )

    $exePath = $exePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $exePath) {
        Write-LogError 'Docker Desktop executable not found.'
        Write-LogInfo 'Please install Docker Desktop: https://www.docker.com/products/docker-desktop/'
        return $false
    }

    Write-LogInfo 'Starting Docker Desktop...'
    Start-Process $exePath
    Write-LogInfo 'Waiting for Docker daemon to start (up to 60s)...'

    $elapsed = 0
    while ($elapsed -lt 60) {
        Start-Sleep -Seconds 2
        $elapsed += 2
        Write-Host '.' -NoNewline
        $info = & docker info 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host ''
            Write-LogSuccess 'Docker Desktop is now running'
            return $true
        }
    }

    Write-Host ''
    Write-LogError 'Docker Desktop failed to start within 60 seconds'
    Write-LogInfo 'Please start Docker Desktop manually and re-run this script.'
    return $false
}

function Test-Docker {
    if (-not (Test-Command 'docker')) { return $false }

    $version = & docker --version 2>$null
    $verNum = if ($version -match '(\d+\.\d+)') { $Matches[1] } else { 'unknown' }

    $info = & docker info 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-LogSuccess "Docker $verNum detected and running"
        return $true
    }

    Write-LogWarn "Docker $verNum installed but daemon is not running"
    return (Start-DockerDesktop)
}

function Test-DockerCompose {
    $result = & docker compose version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $version = & docker compose version --short 2>$null
        Write-LogSuccess "Docker Compose $version detected"
        return $true
    }
    return $false
}

function Test-GitInstalled {
    if (Test-Command 'git') {
        $version = & git --version 2>$null
        $verNum = if ($version -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { 'unknown' }
        Write-LogSuccess "Git $verNum detected"
        return $true
    }
    return $false
}

function Test-NodeInstalled {
    if (Test-Command 'node') {
        $version = & node --version 2>$null
        Write-LogSuccess "Node.js $version detected"
        return $true
    }
    return $false
}

function Install-Prerequisite {
    param([string]$Tool)

    if (Test-Command 'winget') {
        Write-LogInfo "Installing $Tool via winget..."
        switch ($Tool) {
            'docker' {
                & winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
                Write-LogWarn 'Docker Desktop installed. You may need to restart your terminal or PC.'
            }
            'git' {
                & winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements
                Write-LogWarn 'Git installed. You may need to restart your terminal for PATH updates.'
            }
            'node' {
                & winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
                Write-LogWarn 'Node.js installed. You may need to restart your terminal for PATH updates.'
            }
        }
        return ($LASTEXITCODE -eq 0)
    }

    Write-LogError "winget not found. Please install $Tool manually:"
    switch ($Tool) {
        'docker' { Write-LogInfo '  https://www.docker.com/products/docker-desktop/' }
        'git'    { Write-LogInfo '  https://git-scm.com/download/win' }
        'node'   { Write-LogInfo '  https://nodejs.org/' }
    }
    return $false
}

function Invoke-PrerequisiteChecks {
    Write-LogStep 'Checking prerequisites'

    $missing = @()

    if (-not (Test-Docker))        { $missing += 'docker' }
    if (-not (Test-DockerCompose)) { $missing += 'docker-compose' }
    if (-not (Test-GitInstalled))  { $missing += 'git' }

    if ($missing.Count -eq 0) {
        Write-LogSuccess 'All prerequisites satisfied'
        if (-not (Test-Command 'npx')) {
            Write-LogWarn "Node.js/npx not found on host. The 'usage' subcommand requires it."
            Write-LogInfo 'Install Node.js for token usage reports: https://nodejs.org/'
        }
        return
    }

    Write-LogWarn "Missing prerequisites: $($missing -join ', ')"

    foreach ($tool in $missing) {
        if ($tool -eq 'docker-compose') {
            Write-LogError 'docker compose plugin is required. Install Docker Desktop (includes compose).'
            continue
        }

        if (Read-Confirmation -Question "Install $tool automatically?") {
            if (-not (Install-Prerequisite -Tool $tool)) {
                Write-LogError "Failed to install $tool. Please install manually and re-run."
                exit 1
            }
        }
        else {
            Write-LogError "$tool is required. Please install it and re-run."
            exit 1
        }
    }

    Write-LogSuccess 'Prerequisites resolved'
}

# --- Q&A Collection -----------------------------------------------------------

function Get-Configuration {
    Write-Host ''
    Write-Host '=== Configuration ===' -ForegroundColor Cyan
    Write-Host ''

    # Auth Path
    $authChoice = Read-Selection `
        -Question 'Which authentication method will you use?' `
        -Options @(
            'Path A: Subscription (Pro/Max/Team) - OAuth browser login',
            'Path B: Console API key - paste key directly'
        )
    $Script:AuthPath = if ($authChoice -like '*Path A*') { 'A' } else { 'B' }
    Write-LogInfo "Authentication: Path $($Script:AuthPath)"

    # Sharing Tier
    $tierChoice = Read-Selection `
        -Question 'How should containers share source code?' `
        -Options @(
            'Tier A: Shared bind mount (simple, one writes at a time)',
            'Tier B: Git worktrees (safe concurrent editing)'
        )
    $Script:Tier = if ($tierChoice -like '*Tier A*') { 'A' } else { 'B' }
    Write-LogInfo "Source sharing: Tier $($Script:Tier)"

    # Project directory
    $defaultDir = (Get-Location).Path
    $Script:SourceDir = Read-Input -Question 'Absolute path to your project source code' -Default $defaultDir

    if (-not (Test-Path $Script:SourceDir -PathType Container)) {
        Write-LogError "Directory does not exist: $($Script:SourceDir)"
        exit 1
    }

    # Resolve to full path
    $Script:SourceDir = (Resolve-Path $Script:SourceDir).Path

    # I/O latency benchmark
    $ioLatency = Measure-IoLatency -Dir $Script:SourceDir
    if ($ioLatency -gt 50) {
        Write-LogWarn "Slow I/O detected (${ioLatency}ms). Consider using a local SSD."
    }
    else {
        Write-LogSuccess "I/O latency: ${ioLatency}ms (OK)"
    }

    Write-LogInfo "Project directory: $($Script:SourceDir)"

    # Claude Code version
    $Script:ClaudeVersion = Read-Input -Question "Claude Code version (enter specific version or 'latest')" -Default 'latest'
    if ($Script:ClaudeVersion -eq 'latest') {
        $Script:ClaudeVersion = ''
        Write-LogInfo 'Claude Code version: latest'
    }
    else {
        Write-LogInfo "Claude Code version: $($Script:ClaudeVersion)"
    }

    # API keys (Path B)
    if ($Script:AuthPath -eq 'B') {
        Write-Host ''
        Write-Host 'Enter Console API keys (from console.anthropic.com):' -ForegroundColor Cyan
        $Script:ApiKeyA = Read-Secret -Question 'API key for Account A (sk-ant-...)'
        $Script:ApiKeyB = Read-Secret -Question 'API key for Account B (sk-ant-...)'

        if (-not $Script:ApiKeyA -or -not $Script:ApiKeyB) {
            Write-LogError 'Both API keys are required for Path B.'
            exit 1
        }
        Write-LogSuccess 'API keys collected (2 accounts)'
    }
}

# --- .env Generation ----------------------------------------------------------

function New-EnvFile {
    Write-LogStep 'Generating .env configuration'

    $envFile = Join-Path $ProjectRoot '.env'

    if (Test-Path $envFile) {
        if (-not (Read-Confirmation -Question 'Existing .env found. Overwrite?')) {
            Write-LogWarn 'Keeping existing .env. Some settings may not match your choices.'
            return
        }
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        Copy-Item $envFile "${envFile}.backup.${timestamp}"
        Write-LogInfo 'Backed up existing .env'
    }

    $projectDir = ConvertTo-ForwardSlash -Path $Script:SourceDir
    $homePath = ConvertTo-ForwardSlash -Path $env:USERPROFILE

    $lines = @()
    $lines += "# Generated by install.ps1 - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ''
    $lines += '# ==== Required ===='
    $lines += "PROJECT_DIR=$projectDir"
    $lines += 'CONTAINER_PROJECT_DIR=/project'
    $lines += ''
    $lines += '# ==== Windows: HOME for Docker Compose volume expansion ===='
    $lines += "HOME=$homePath"
    $lines += ''
    $lines += '# ==== Claude Config Source (optional) ===='
    $lines += '# Set to a path inside the container to source config directly from a repo.'
    $lines += '# Example: /project/claude-config/global'
    $lines += '#CLAUDE_CONFIG_SOURCE='
    $lines += ''

    if ($Script:ClaudeVersion) {
        $lines += '# ==== Claude Code Version ===='
        $lines += "CLAUDE_CODE_VERSION=$($Script:ClaudeVersion)"
        $lines += ''
    }

    if ($Script:AuthPath -eq 'B') {
        $lines += '# ==== Path B: Console API Keys ===='
        $lines += "CLAUDE_API_KEY_A=$($Script:ApiKeyA)"
        $lines += "CLAUDE_API_KEY_B=$($Script:ApiKeyB)"
        $lines += ''
    }

    if ($Script:Tier -eq 'B') {
        $lines += '# ==== Tier B: Git Worktree Paths ===='
        $lines += '# (populated after worktree setup)'
        $lines += 'PROJECT_DIR_A='
        $lines += 'PROJECT_DIR_B='
        $lines += 'CONTAINER_PROJECT_DIR_A=/project-a'
        $lines += 'CONTAINER_PROJECT_DIR_B=/project-b'
        $lines += ''
    }

    # Git identity (auto-detect from host)
    $gitName = & git config --global user.name 2>$null
    $gitEmail = & git config --global user.email 2>$null
    if ($gitName -or $gitEmail) {
        $lines += '# ==== Git Identity ===='
        if ($gitName)  { $lines += "GIT_USER_NAME=$gitName" }
        if ($gitEmail) { $lines += "GIT_USER_EMAIL=$gitEmail" }
        $lines += ''
    }

    $content = ($lines -join "`n") + "`n"
    Write-EnvContent -Path $envFile -Content $content

    # Restrict file permissions (Windows ACL equivalent of chmod 600)
    & icacls $envFile /inheritance:r /grant:r "${env:USERNAME}:(R,W)" 2>$null | Out-Null

    Write-LogSuccess ".env generated at $envFile"
}

# --- Directory Creation -------------------------------------------------------

function New-StateDirs {
    Write-LogStep 'Creating state directories'

    $dirs = @(
        (Join-Path $env:USERPROFILE '.claude-state\account-a'),
        (Join-Path $env:USERPROFILE '.claude-state\account-b'),
        (Join-Path $env:USERPROFILE '.claude')
    )

    foreach ($dir in $dirs) {
        if (Test-Path $dir) {
            Write-LogInfo "Already exists: $dir"
        }
        else {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-LogSuccess "Created: $dir"
        }
    }
}

# --- Docker Build -------------------------------------------------------------

function Invoke-ImageBuild {
    Write-LogStep 'Building Docker image'

    Push-Location $ProjectRoot
    try {
        $buildArgs = @()
        if ($Script:ClaudeVersion) {
            $buildArgs = @('--build-arg', "CLAUDE_CODE_VERSION=$($Script:ClaudeVersion)")
        }

        Write-LogInfo 'Building claude-code-base:latest (this may take a few minutes)...'
        & docker compose build @buildArgs 2>&1 | Select-Object -Last 5

        if ($LASTEXITCODE -ne 0) {
            Write-LogError 'Docker build failed.'
            exit 1
        }

        Write-LogSuccess 'Docker image built successfully'
    }
    finally {
        Pop-Location
    }
}

# --- Authentication -----------------------------------------------------------

function Invoke-AuthSetup {
    Write-LogStep 'Setting up authentication'

    if ($Script:AuthPath -eq 'B') {
        Write-LogSuccess 'Path B: API keys configured in .env (no browser login needed)'
        return
    }

    Write-LogInfo 'Path A: OAuth will be configured inside containers after startup'
    Write-LogInfo 'Each container stores credentials in its bind-mounted state directory'
    Write-LogInfo 'You will authenticate when running claude for the first time in each container'
    Write-LogSuccess 'Authentication will be handled after container startup'
}

# --- Worktree Setup (Tier B) -------------------------------------------------

function Invoke-WorktreeSetup {
    if ($Script:Tier -ne 'B') { return }

    Write-LogStep 'Setting up git worktrees (Tier B)'

    while (-not (Test-Path (Join-Path $Script:SourceDir '.git'))) {
        Write-LogWarn "$($Script:SourceDir) is not a git repository. Tier B requires git."

        $recovery = Read-Selection `
            -Question 'How would you like to proceed?' `
            -Options @(
                'Enter a different project directory (must be a git repo)',
                'Fall back to Tier A (shared bind mount, no worktrees)'
            )

        if ($recovery -like '*Tier A*') {
            Write-LogInfo 'Switching to Tier A (shared bind mount)'
            $Script:Tier = 'A'

            # Remove worktree placeholders from .env
            $envFile = Join-Path $ProjectRoot '.env'
            if (Test-Path $envFile) {
                $content = [System.IO.File]::ReadAllText($envFile)
                $content = $content -replace '(?m)^# ==== Tier B:.*\r?\n', ''
                $content = $content -replace '(?m)^# \(populated after.*\r?\n', ''
                $content = $content -replace '(?m)^PROJECT_DIR_A=.*\r?\n', ''
                $content = $content -replace '(?m)^PROJECT_DIR_B=.*\r?\n', ''
                $content = $content -replace '(?m)^CONTAINER_PROJECT_DIR_A=.*\r?\n', ''
                $content = $content -replace '(?m)^CONTAINER_PROJECT_DIR_B=.*\r?\n', ''
                Write-EnvContent -Path $envFile -Content $content
            }

            Write-LogSuccess 'Switched to Tier A'
            return
        }

        # User chose to enter a different directory
        $newDir = Read-Input -Question 'Absolute path to git repository'
        if (-not (Test-Path $newDir -PathType Container)) {
            Write-LogError "Directory does not exist: $newDir"
            continue
        }
        $newDir = (Resolve-Path $newDir).Path
        $Script:SourceDir = $newDir

        # Update PROJECT_DIR in .env
        $envFile = Join-Path $ProjectRoot '.env'
        if (Test-Path $envFile) {
            Set-EnvValue -Path $envFile -Key 'PROJECT_DIR' -Value (ConvertTo-ForwardSlash -Path $newDir)
        }
        Write-LogInfo "Project directory updated: $newDir"
    }

    $branchA = Read-Input -Question 'Branch name for Container A' -Default 'worktree-a'
    $branchB = Read-Input -Question 'Branch name for Container B' -Default 'worktree-b'

    Write-LogInfo 'Creating worktrees...'
    & "$PSScriptRoot\setup-worktrees.ps1" -RepoDir $Script:SourceDir -BranchA $branchA -BranchB $branchB

    $worktreeA = "$($Script:SourceDir.TrimEnd('\', '/'))-a"
    $worktreeB = "$($Script:SourceDir.TrimEnd('\', '/'))-b"

    # Update .env with worktree paths (forward slashes for Docker)
    $envFile = Join-Path $ProjectRoot '.env'
    $wtA = ConvertTo-ForwardSlash -Path $worktreeA
    $wtB = ConvertTo-ForwardSlash -Path $worktreeB
    Set-EnvValue -Path $envFile -Key 'PROJECT_DIR_A' -Value $wtA
    Set-EnvValue -Path $envFile -Key 'PROJECT_DIR_B' -Value $wtB

    Write-LogSuccess 'Worktrees created:'
    Write-LogInfo "  A: $worktreeA (branch: $branchA)"
    Write-LogInfo "  B: $worktreeB (branch: $branchB)"
}

# --- Container Startup --------------------------------------------------------

function Start-Containers {
    Write-LogStep 'Starting containers'

    Push-Location $ProjectRoot
    try {
        Write-LogInfo 'Starting with docker compose up -d...'
        Invoke-Compose -ProjectRoot $ProjectRoot up --detach 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-LogError 'Failed to start containers.'
            exit 1
        }

        Write-LogSuccess 'Containers started'
    }
    finally {
        Pop-Location
    }
}

# --- Dependency Installation --------------------------------------------------

function Install-Dependencies {
    Write-LogStep 'Installing project dependencies in containers'

    $services = @('claude-a', 'claude-b')

    foreach ($svc in $services) {
        Write-LogInfo "Installing npm dependencies in $svc..."
        $output = Invoke-Compose -ProjectRoot $ProjectRoot exec -T $svc npm install 2>&1
        if ($LASTEXITCODE -eq 0) {
            $output | Select-Object -Last 3
            Write-LogSuccess "$svc`: dependencies installed"
        }
        else {
            Write-LogWarn "$svc`: npm install skipped or failed (project may not have package.json)"
        }
    }
}

# --- Verification -------------------------------------------------------------

function Invoke-Verification {
    Write-LogStep 'Verifying setup'

    $primarySvc = 'claude-a'

    # Check container is running
    $psOutput = Invoke-Compose -ProjectRoot $ProjectRoot ps --format '{{.Name}}' 2>$null
    if ($psOutput -match $primarySvc) {
        Write-LogSuccess "Container $primarySvc is running"
    }
    else {
        Write-LogError "Container $primarySvc is not running"
        Write-LogInfo 'Check logs: docker compose logs claude-a'
        return
    }

    # Check Claude Code is available
    $version = Invoke-Compose -ProjectRoot $ProjectRoot exec -T $primarySvc claude --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-LogSuccess "Claude Code is available ($version)"
    }
    else {
        Write-LogWarn 'Could not verify Claude Code (container may still be starting)'
    }
}

# --- Summary ------------------------------------------------------------------

function Show-Summary {
    Write-Host ''
    Write-Host '============================================' -ForegroundColor Green
    Write-Host '  Setup Complete!' -ForegroundColor Green
    Write-Host '============================================' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Configuration:' -ForegroundColor White
    Write-Host "  Platform:        Windows"
    Write-Host "  Authentication:  Path $($Script:AuthPath)"
    Write-Host "  Source sharing:  Tier $($Script:Tier)"
    Write-Host "  Project:         $($Script:SourceDir)"
    Write-Host ''
    Write-Host 'Quick Commands (via CLI wrapper):' -ForegroundColor White
    Write-Host ''
    Write-Host '  # Start Claude Code' -ForegroundColor Cyan
    Write-Host '  .\scripts\claude-docker.ps1 claude'
    Write-Host ''
    Write-Host '  # Start second account (separate terminal)' -ForegroundColor Cyan
    Write-Host '  .\scripts\claude-docker.ps1 claude claude-b'
    Write-Host ''
    Write-Host '  # Container management' -ForegroundColor Cyan
    Write-Host '  .\scripts\claude-docker.ps1 ps       ' -NoNewline; Write-Host '# status' -ForegroundColor DarkGray
    Write-Host '  .\scripts\claude-docker.ps1 logs     ' -NoNewline; Write-Host '# follow logs' -ForegroundColor DarkGray
    Write-Host '  .\scripts\claude-docker.ps1 down     ' -NoNewline; Write-Host '# stop all' -ForegroundColor DarkGray
    Write-Host '  .\scripts\claude-docker.ps1 restart  ' -NoNewline; Write-Host '# restart all' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  # See all commands' -ForegroundColor Cyan
    Write-Host '  .\scripts\claude-docker.ps1 help'
    Write-Host ''

    if ($Script:AuthPath -eq 'A') {
        Write-Host '  First run? Authenticate inside the container:' -ForegroundColor DarkGray
        Write-Host '  .\scripts\claude-docker.ps1 claude' -ForegroundColor DarkGray
        Write-Host '  (Follow the OAuth prompt - credentials persist in bind-mounted state dir)' -ForegroundColor DarkGray
        Write-Host ''
    }
}

# --- Main ---------------------------------------------------------------------

Write-Host ''
Write-Host '============================================' -ForegroundColor Cyan
Write-Host '  Claude Docker - Interactive Setup' -ForegroundColor Cyan
Write-Host '============================================' -ForegroundColor Cyan
Write-Host ''
Write-LogInfo 'Detected platform: Windows'
Write-Host ''

# Collect user configuration
Get-Configuration

# Calculate total steps based on choices
$totalSteps = 8  # prereqs, env, dirs, build, auth, start, deps, verify
if ($Script:Tier -eq 'B') { $totalSteps++ }
Initialize-StepCounter -Total $totalSteps

# Show configuration summary
Write-Host ''
Write-Host 'Configuration Summary:' -ForegroundColor White
Write-Host "  Platform:        Windows"
Write-Host "  Authentication:  Path $($Script:AuthPath)"
Write-Host "  Source sharing:  Tier $($Script:Tier)"
Write-Host "  Project:         $($Script:SourceDir)"
Write-Host "  Claude version:  $(if ($Script:ClaudeVersion) { $Script:ClaudeVersion } else { 'latest' })"
Write-Host ''

if (-not (Read-Confirmation -Question 'Proceed with this configuration?' -Default 'y')) {
    Write-LogInfo 'Setup cancelled.'
    exit 0
}

# Execute setup steps
Invoke-PrerequisiteChecks
New-EnvFile
New-StateDirs
Invoke-ImageBuild
Invoke-AuthSetup
Invoke-WorktreeSetup
Start-Containers
Install-Dependencies
Invoke-Verification
Show-Summary
