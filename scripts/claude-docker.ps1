#Requires -Version 5.1
<#
.SYNOPSIS
    claude-docker — multi-account CLI wrapper (Windows PowerShell port)
.DESCRIPTION
    PowerShell port of scripts/claude-docker.
    Run multiple Claude Code instances with independent accounts.
.PARAMETER Command
    The subcommand to execute.
.PARAMETER Arguments
    Additional arguments passed to the subcommand.
.EXAMPLE
    .\claude-docker.ps1 up
    .\claude-docker.ps1 claude
    .\claude-docker.ps1 claude claude-b
    .\claude-docker.ps1 gh-auth
    .\claude-docker.ps1 usage daily
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$Arguments = @()
)

$ErrorActionPreference = 'Stop'

# Platform guard: PowerShell 7 runs on Linux/macOS, but this wrapper assumes
# Windows Docker Desktop semantics (no docker-compose.linux.yml overlay, no
# POSIX UID/GID). Refuse to run outside Windows and point users at the bash
# wrapper instead.
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.OS -and $PSVersionTable.OS -notlike '*Windows*') {
    Write-Error "claude-docker.ps1 is Windows-only. Use ./scripts/claude-docker on macOS or Linux."
    exit 1
}

Import-Module "$PSScriptRoot\ClaudeDocker.psm1" -Force

$ProjectRoot = Split-Path $PSScriptRoot -Parent

# --- Account Directory Helpers -----------------------------------------------

function Get-AccountDirs {
    $stateBase = Join-Path $env:USERPROFILE '.claude-state'
    if (-not (Test-Path $stateBase)) { return @() }
    Get-ChildItem $stateBase -Directory -Filter 'account-*' | Select-Object -ExpandProperty FullName
}

function New-MergedConfigDir {
    <#
    .SYNOPSIS
    Build a temporary merged directory for ccusage. Creates junctions from each
    account's project subdirectories into a single temporary tree.
    #>
    $tmpDir = Join-Path $env:TEMP "claude-docker-$(New-Guid)"
    $projDir = Join-Path $tmpDir 'projects'
    New-Item -ItemType Directory -Path $projDir -Force | Out-Null

    foreach ($acctDir in Get-AccountDirs) {
        $acctProjects = Join-Path $acctDir 'projects'
        if (-not (Test-Path $acctProjects)) { continue }

        $acctName = Split-Path $acctDir -Leaf
        foreach ($proj in Get-ChildItem $acctProjects -Directory) {
            $linkName = "${acctName}_$($proj.Name)"
            $linkPath = Join-Path $projDir $linkName
            # Use directory junction (no admin required, unlike symlinks)
            cmd /c mklink /J "$linkPath" "$($proj.FullName)" 2>$null | Out-Null
        }
    }

    return $tmpDir
}

# --- Subcommands -------------------------------------------------------------

function Invoke-Up {
    Write-Host 'Starting containers...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot up --detach @Arguments
    Write-Host 'Containers started.' -ForegroundColor Green
    Write-Host ''
    Invoke-Compose -ProjectRoot $ProjectRoot ps
}

function Invoke-Down {
    Write-Host 'Stopping containers...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot down @Arguments
    Write-Host 'Containers stopped.' -ForegroundColor Green
}

function Invoke-Restart {
    Write-Host 'Restarting containers...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot restart @Arguments
    Write-Host 'Containers restarted.' -ForegroundColor Green
}

function Invoke-Logs {
    Invoke-Compose -ProjectRoot $ProjectRoot logs -f @Arguments
}

function Invoke-Ps {
    Invoke-Compose -ProjectRoot $ProjectRoot ps @Arguments
}

function Invoke-Exec {
    if ($Arguments.Count -eq 0) {
        Write-LogError 'Usage: claude-docker exec <service> [command...]'
        exit 1
    }

    $service = $Arguments[0]
    $rest = if ($Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] } else { @('bash') }

    Invoke-Compose -ProjectRoot $ProjectRoot exec $service @rest
}

function Invoke-Claude {
    $service = if ($Arguments.Count -gt 0) { $Arguments[0] } else { 'claude-a' }
    Write-Host "Starting Claude Code in " -ForegroundColor Cyan -NoNewline
    Write-Host $service -ForegroundColor White -NoNewline
    Write-Host '...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot exec $service claude
}

function Invoke-Auth {
    $service = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }

    # On Windows, look for file-based credentials from host Claude installation
    $credFile = Join-Path $env:USERPROFILE '.claude\.credentials.json'
    $creds = ''

    if (Test-Path $credFile) {
        $creds = Get-Content $credFile -Raw
    }

    if (-not $creds) {
        Write-LogWarn 'No credentials found at ~/.claude/.credentials.json'
        Write-Host 'Authenticate on the host first, then re-run this command:'
        Write-Host '  claude auth login' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host 'Or set API keys in .env (Path B):'
        Write-Host '  CLAUDE_API_KEY_A=sk-ant-...' -ForegroundColor DarkGray
        exit 1
    }

    # Determine which services to authenticate
    $services = if ($service) { @($service) } else { @('claude-a', 'claude-b') }

    Write-Host 'Injecting credentials from host' -ForegroundColor White

    foreach ($svc in $services) {
        $stateDir = switch ($svc) {
            'claude-a' { Join-Path $env:USERPROFILE '.claude-state\account-a' }
            'claude-b' { Join-Path $env:USERPROFILE '.claude-state\account-b' }
            default     { Join-Path $env:USERPROFILE ".claude-state\account-$svc" }
        }

        if (-not (Test-Path $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }

        $destCred = Join-Path $stateDir '.credentials.json'
        [System.IO.File]::WriteAllText($destCred, $creds, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  * $svc - credentials written" -ForegroundColor Green
    }

    Write-Host ''

    # Verify in first running container
    $cid = Get-ContainerId -ProjectRoot $ProjectRoot -Service $services[0]
    if ($cid) {
        Write-Host "Verifying ($($services[0])):" -ForegroundColor DarkGray
        & docker exec $cid claude auth status 2>&1
    }
    else {
        Write-LogInfo 'Containers not running. Credentials will be available on next start.'
    }
}

function Invoke-GhAuth {
    if (-not (Test-Command 'gh')) {
        Write-LogError 'gh CLI not found on host.'
        exit 1
    }

    $null = & gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-LogError 'GitHub CLI not authenticated on host.'
        Write-Host '  Run first: gh auth login -h github.com' -ForegroundColor DarkGray
        exit 1
    }

    $token = & gh auth token 2>$null
    if (-not $token) {
        Write-LogError 'Could not extract GitHub token from gh CLI.'
        exit 1
    }

    $envFile = Join-Path $ProjectRoot '.env'
    if (-not (Test-Path $envFile)) {
        Write-LogError ".env file not found at $envFile"
        exit 1
    }

    Set-EnvValue -Path $envFile -Key 'GH_TOKEN' -Value $token
    Write-Host 'GitHub token injected into .env' -ForegroundColor Green

    # Restart containers if running
    $running = Get-ContainerId -ProjectRoot $ProjectRoot -Service 'claude-a'
    if ($running) {
        Write-Host 'Restarting containers to apply...' -ForegroundColor Cyan
        Invoke-Compose -ProjectRoot $ProjectRoot down
        Invoke-Compose -ProjectRoot $ProjectRoot up --detach

        Start-Sleep -Seconds 2
        $cid = Get-ContainerId -ProjectRoot $ProjectRoot -Service 'claude-a'
        if ($cid) {
            Write-Host ''
            Write-Host 'Verifying GitHub auth in claude-a:' -ForegroundColor White
            & docker exec $cid gh auth status 2>&1
        }
    }
    else {
        Write-LogInfo 'Containers not running. Token will be available on next start.'
    }
}

function Invoke-Build {
    Write-Host 'Building Docker image...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot build @Arguments
    Write-Host 'Build complete.' -ForegroundColor Green
}

function Invoke-Update {
    Write-Host 'Updating Claude Code to latest version' -ForegroundColor White
    Write-Host ''

    Write-Host '[1/3] Rebuilding image (--no-cache)...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot build --no-cache

    Write-Host '[2/3] Recreating containers...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot up --detach --force-recreate

    Write-Host '[3/3] Verifying version...' -ForegroundColor Cyan
    $cid = Get-ContainerId -ProjectRoot $ProjectRoot -Service 'claude-a'
    if ($cid) {
        $version = & docker exec $cid claude --version 2>$null
        if (-not $version) { $version = 'unknown' }
        Write-Host ''
        Write-Host 'Update complete. ' -ForegroundColor Green -NoNewline
        Write-Host "Claude Code version: $version" -ForegroundColor White
    }
    else {
        Write-Host ''
        Write-Host 'Image rebuilt. ' -ForegroundColor Green -NoNewline
        Write-Host 'Start containers with: .\scripts\claude-docker.ps1 up' -ForegroundColor DarkGray
    }
}

function Invoke-Config {
    $baseArgs = Get-ComposeArgs -ProjectRoot $ProjectRoot
    Write-Host "Compose args: docker compose $($baseArgs -join ' ')" -ForegroundColor DarkGray
    Write-Host ''
    Invoke-Compose -ProjectRoot $ProjectRoot config @Arguments
}

function Invoke-ComposePass {
    Invoke-Compose -ProjectRoot $ProjectRoot @Arguments
}

function Invoke-Usage {
    if (-not (Test-Command 'npx')) {
        Write-LogError 'npx not found. Node.js is required to run ccusage.'
        Write-Host '  Install Node.js 20+: https://nodejs.org/' -ForegroundColor Cyan
        Write-Host '  Windows: winget install -e --id OpenJS.NodeJS.LTS' -ForegroundColor DarkGray
        exit 1
    }

    # Parse report type
    $reportType = 'daily'
    $passArgs = @()

    if ($Arguments.Count -gt 0) {
        switch ($Arguments[0]) {
            { $_ -in 'daily', 'monthly', 'session', 'blocks', 'statusline' } {
                $reportType = $Arguments[0]
                if ($Arguments.Count -gt 1) { $passArgs = $Arguments[1..($Arguments.Count - 1)] }
            }
            default {
                $passArgs = $Arguments
            }
        }
    }

    # Build merged config directory with junctions from all sources
    $mergedDir = New-MergedConfigDir

    try {
        # Check if any project data was found
        $projectCount = (Get-ChildItem (Join-Path $mergedDir 'projects') -Directory -ErrorAction SilentlyContinue).Count
        if ($projectCount -eq 0) {
            Write-LogError 'No session data found.'
            Write-Host '  Run Claude Code in a container first to generate usage data:' -ForegroundColor DarkGray
            Write-Host '  .\scripts\claude-docker.ps1 claude' -ForegroundColor DarkGray
            exit 1
        }

        Write-Host 'Token Usage Report' -ForegroundColor White
        Write-Host "Report type: $reportType" -ForegroundColor DarkGray
        Write-Host "Data sources ($projectCount projects):" -ForegroundColor DarkGray

        foreach ($acctDir in Get-AccountDirs) {
            $acctName = Split-Path $acctDir -Leaf
            $acctProjects = Join-Path $acctDir 'projects'
            if (Test-Path $acctProjects) {
                $count = (Get-ChildItem $acctProjects -Directory -ErrorAction SilentlyContinue).Count
                if ($count -gt 0) {
                    Write-Host '  * ' -ForegroundColor Green -NoNewline
                    Write-Host "$acctName " -NoNewline
                    Write-Host "($count projects)" -ForegroundColor DarkGray
                }
            }
        }

        Write-Host ''

        $env:CLAUDE_CONFIG_DIR = $mergedDir
        & npx ccusage@latest $reportType @passArgs
    }
    finally {
        $env:CLAUDE_CONFIG_DIR = $null
        if (Test-Path $mergedDir) {
            Remove-Item $mergedDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Show-Help {
    $baseArgs = Get-ComposeArgs -ProjectRoot $ProjectRoot
    $composeDisplay = "docker compose $($baseArgs -join ' ')"

    Write-Host ''
    Write-Host 'claude-docker' -ForegroundColor White -NoNewline
    Write-Host ' - multi-account CLI wrapper'
    Write-Host ''
    Write-Host 'USAGE' -ForegroundColor White
    Write-Host '  .\scripts\claude-docker.ps1 <command> [args...]'
    Write-Host ''
    Write-Host 'LIFECYCLE' -ForegroundColor White
    Write-Host '  up                    ' -ForegroundColor Green -NoNewline; Write-Host 'Start all containers'
    Write-Host '  down                  ' -ForegroundColor Green -NoNewline; Write-Host 'Stop all containers'
    Write-Host '  restart               ' -ForegroundColor Green -NoNewline; Write-Host 'Restart all containers'
    Write-Host '  build                 ' -ForegroundColor Green -NoNewline; Write-Host 'Build/rebuild Docker image'
    Write-Host '  update                ' -ForegroundColor Green -NoNewline; Write-Host 'Rebuild with latest Claude Code and recreate'
    Write-Host '  ps                    ' -ForegroundColor Green -NoNewline; Write-Host 'Show container status'
    Write-Host '  logs                  ' -ForegroundColor Green -NoNewline; Write-Host 'Follow container logs'
    Write-Host ''
    Write-Host 'INTERACTIVE' -ForegroundColor White
    Write-Host '  claude [service]      ' -ForegroundColor Green -NoNewline; Write-Host 'Start Claude Code (default: claude-a)'
    Write-Host '  auth [service]        ' -ForegroundColor Green -NoNewline; Write-Host 'Inject Claude credentials from host'
    Write-Host '  gh-auth               ' -ForegroundColor Green -NoNewline; Write-Host 'Inject GitHub token from host gh CLI'
    Write-Host '  exec <service>        ' -ForegroundColor Green -NoNewline; Write-Host 'Open shell in a service'
    Write-Host ''
    Write-Host 'USAGE TRACKING' -ForegroundColor White
    Write-Host '  usage [type] [flags]  ' -ForegroundColor Green -NoNewline; Write-Host 'Token usage report (default: daily)'
    Write-Host '                        Types: daily, monthly, session, blocks, statusline'
    Write-Host ''
    Write-Host 'ADVANCED' -ForegroundColor White
    Write-Host '  config                ' -ForegroundColor Green -NoNewline; Write-Host 'Show resolved compose configuration'
    Write-Host '  compose ...           ' -ForegroundColor Green -NoNewline; Write-Host 'Pass raw args to docker compose'
    Write-Host ''
    Write-Host 'SERVICES' -ForegroundColor White
    Write-Host '  claude-a              Account A (default)'
    Write-Host '  claude-b              Account B'
    Write-Host ''
    Write-Host 'DETECTED COMPOSE COMMAND' -ForegroundColor White
    Write-Host "  $composeDisplay" -ForegroundColor DarkGray
    Write-Host ''
}

# --- Main --------------------------------------------------------------------

switch ($Command) {
    'up'       { Invoke-Up }
    'down'     { Invoke-Down }
    'restart'  { Invoke-Restart }
    'logs'     { Invoke-Logs }
    'ps'       { Invoke-Ps }
    'exec'     { Invoke-Exec }
    'claude'   { Invoke-Claude }
    'auth'     { Invoke-Auth }
    'gh-auth'  { Invoke-GhAuth }
    'usage'    { Invoke-Usage }
    'build'    { Invoke-Build }
    'update'   { Invoke-Update }
    'config'   { Invoke-Config }
    'compose'  { Invoke-ComposePass }
    { $_ -in 'help', '--help', '-h' } { Show-Help }
    default {
        Write-Host "Unknown command: $Command" -ForegroundColor Red
        Show-Help
        exit 1
    }
}
