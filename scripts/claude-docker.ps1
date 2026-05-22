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
    $stateBase = Get-AgentStateRoot -ProjectRoot $ProjectRoot
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

    # Lightweight post-start GitHub auth check (non-blocking)
    Write-Host ''
    $primary = Get-PrimaryService -ProjectRoot $ProjectRoot
    $cid = Get-ContainerId -ProjectRoot $ProjectRoot -Service $primary
    if ($cid) {
        Start-Sleep -Seconds 2  # wait for entrypoint gh auth setup
        Test-ContainerGhAuth -Service $primary | Out-Null
    }
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

function Invoke-Agent {
    <#
    .SYNOPSIS
    Unified runtime-launch subcommand, replacing the former Invoke-Claude /
    Invoke-Codex pair. $Subcommand is the runtime name the user typed
    (claude or codex). Binary, skip-permissions flag, and extra run args are
    all read from the registry.
    #>
    param([Parameter(Mandatory)][string]$Subcommand)

    $runtime = Get-AgentRuntime -ProjectRoot $ProjectRoot

    # Wrong-runtime guard, preserved verbatim from the former Invoke-Codex:
    # a codex subcommand only works when AGENT_RUNTIME selects codex. Kept
    # codex-specific so claude's prior behavior under any AGENT_RUNTIME is
    # unchanged.
    if ($Subcommand -eq 'codex' -and $runtime -ne 'codex') {
        Write-LogError 'codex command requires AGENT_RUNTIME=codex. Set it in .env, regenerate compose files, then run again.'
        exit 1
    }

    # Runtime values for the subcommand the user typed. The former
    # Invoke-Claude always launched the claude binary regardless of
    # AGENT_RUNTIME, so resolve from the subcommand to keep that behavior.
    $binary       = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Subcommand -Field 'binary'
    $skipFlag     = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Subcommand -Field 'skipPermissionsFlag'
    $extraRunArgs = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Subcommand -Field 'extraRunArgs'
    $servicePrefix = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Subcommand -Field 'servicePrefix'
    $label        = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Subcommand -Field 'displayName'

    # Skip-permissions flags accepted: the runtime's own flag plus the
    # universal --dangerously-skip-permissions alias (a no-op duplicate for
    # claude, the historical alias codex also honored).
    $skipPerms = $false
    $service = ''
    foreach ($arg in $Arguments) {
        if ($arg -eq $skipFlag -or $arg -eq '--dangerously-skip-permissions') {
            $skipPerms = $true
        } elseif (-not $service) {
            $service = $arg
        }
    }
    # Default service is keyed off the subcommand (claude-a / codex-a).
    if (-not $service) { $service = "$servicePrefix-a" }

    # Pretty launch banner: the label is the runtime's registry displayName,
    # so every registered runtime prints a correct name (not just claude/codex).
    Write-Host "Starting $label in " -ForegroundColor Cyan -NoNewline
    Write-Host $service -ForegroundColor White -NoNewline
    Write-Host '...' -ForegroundColor Cyan

    # Build argv: binary, then registry extraRunArgs (split on whitespace;
    # the codex entry expands to  -c cli_auth_credentials_store="file" ),
    # then the skip-permissions flag when requested.
    $agentArgs = @($binary)
    if (-not [string]::IsNullOrWhiteSpace($extraRunArgs)) {
        $agentArgs += ($extraRunArgs -split '\s+')
    }
    if ($skipPerms) {
        $agentArgs += $skipFlag
    }
    Invoke-Compose -ProjectRoot $ProjectRoot exec $service @agentArgs
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
    $primary = Get-PrimaryService -ProjectRoot $ProjectRoot
    $running = Get-ContainerId -ProjectRoot $ProjectRoot -Service $primary
    if ($running) {
        Write-Host 'Restarting containers to apply...' -ForegroundColor Cyan
        Invoke-Compose -ProjectRoot $ProjectRoot down
        Invoke-Compose -ProjectRoot $ProjectRoot up --detach

        Start-Sleep -Seconds 2
        $cid = Get-ContainerId -ProjectRoot $ProjectRoot -Service $primary
        if ($cid) {
            Write-Host ''
            Write-Host "Verifying GitHub auth in ${primary}:" -ForegroundColor White
            & docker exec $cid gh auth status 2>&1
        }
    }
    else {
        Write-LogInfo 'Containers not running. Token will be available on next start.'
    }
}

# --- GitHub Auth Helpers ------------------------------------------------------

function Update-GhToken {
    <#
    .SYNOPSIS
    Refresh GH_TOKEN in .env from the host's gh CLI.
    Returns $true if token was verified/refreshed, $false if gh is unavailable.
    Non-blocking: callers should treat $false as a warning, not an error.
    Named with the approved PowerShell verb "Update" (was "Refresh" which is
    not in Get-Verb and would trigger unapproved-verb warnings if exported).
    #>
    $envFile = Join-Path $ProjectRoot '.env'

    if (-not (Test-Command 'gh')) {
        Write-LogInfo 'gh CLI not found on host — skipping GitHub token refresh.'
        return $false
    }

    $null = & gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-LogWarn 'GitHub CLI not authenticated on host.'
        Write-Host '  Run: gh auth login -h github.com' -ForegroundColor DarkGray
        Write-Host '  Then: .\scripts\claude-docker.ps1 gh-auth' -ForegroundColor DarkGray
        return $false
    }

    $freshToken = & gh auth token 2>$null
    if (-not $freshToken) {
        Write-LogWarn 'Could not extract GitHub token from host gh CLI.'
        return $false
    }

    # Compare with current .env value
    $currentToken = ''
    if (Test-Path $envFile) {
        $envData = Read-EnvFile -Path $envFile
        $currentToken = $envData['GH_TOKEN']
    }

    if ($freshToken -eq $currentToken) {
        Write-Host '  * GH_TOKEN is current — no update needed.' -ForegroundColor Green
        return $true
    }

    # Update or append GH_TOKEN
    if (-not (Test-Path $envFile)) {
        Write-LogWarn '.env not found — cannot save GH_TOKEN.'
        return $false
    }
    Set-EnvValue -Path $envFile -Key 'GH_TOKEN' -Value $freshToken

    if (-not $currentToken) {
        Write-Host '  * GH_TOKEN added to .env.' -ForegroundColor Green
    }
    else {
        Write-Host '  * GH_TOKEN refreshed in .env (token changed).' -ForegroundColor Green
    }
    return $true
}

function Test-ContainerGhAuth {
    <#
    .SYNOPSIS
    Verify GitHub auth inside a running container.
    Returns $true if gh auth is OK, $false otherwise.

    .DESCRIPTION
    Uses `gh api user` rather than `gh auth status`: when GH_TOKEN coexists
    with a mounted host gh config, `gh auth status` also evaluates the
    unusable mounted `default` account and exits non-zero even though the
    token works. `gh api user` checks the credential path gh actually uses
    for API calls.
    #>
    param([string]$Service = 'claude-a')

    $cid = Get-ContainerId -ProjectRoot $ProjectRoot -Service $Service
    if (-not $cid) { return $false }

    $null = & docker exec $cid gh api user --jq .login 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  * GitHub auth: OK ($Service)" -ForegroundColor Green
        return $true
    }
    else {
        Write-Host "  ! GitHub auth: not configured ($Service)" -ForegroundColor Yellow
        Write-Host '    git push/pull and gh commands may fail.' -ForegroundColor DarkGray
        Write-Host '    Fix: .\scripts\claude-docker.ps1 gh-auth' -ForegroundColor DarkGray
        return $false
    }
}

function Invoke-Build {
    Write-Host 'Building Docker image...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot build @Arguments
    Write-Host 'Build complete.' -ForegroundColor Green
}

function Invoke-Update {
    $binary = Get-AgentRuntime -ProjectRoot $ProjectRoot
    Write-Host "Updating $binary CLI to latest version" -ForegroundColor White
    Write-Host ''

    # Pre-check and refresh GitHub auth token from host
    Write-Host '[1/5] Checking GitHub auth on host...' -ForegroundColor Cyan
    $ghOk = Update-GhToken
    Write-Host ''

    if (-not $ghOk) {
        Write-Host '[2/5] Skipping token refresh (gh unavailable or unauthenticated)' -ForegroundColor Cyan
    }
    else {
        Write-Host '[2/5] GitHub token verified' -ForegroundColor Cyan
    }
    Write-Host ''

    Write-Host '[3/5] Rebuilding image (--no-cache)...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot build --no-cache

    Write-Host '[4/5] Recreating containers...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot up --detach --force-recreate

    # Verify version and GitHub auth
    Write-Host '[5/5] Verifying...' -ForegroundColor Cyan
    $primary = Get-PrimaryService -ProjectRoot $ProjectRoot
    $cid = Get-ContainerId -ProjectRoot $ProjectRoot -Service $primary
    if ($cid) {
        $version = & docker exec $cid $binary --version 2>$null
        if (-not $version) { $version = 'unknown' }
        Write-Host "  * $binary version: $version" -ForegroundColor Green

        # Wait briefly for entrypoint to complete gh auth setup
        Start-Sleep -Seconds 2
        Test-ContainerGhAuth -Service $primary | Out-Null

        Write-Host ''
        Write-Host 'Update complete.' -ForegroundColor Green
    }
    else {
        Write-Host ''
        Write-Host 'Image rebuilt. ' -ForegroundColor Green -NoNewline
        Write-Host 'Start containers with: .\scripts\claude-docker.ps1 up' -ForegroundColor DarkGray
    }
}

function Invoke-Scale {
    if ($Arguments.Count -eq 0) {
        Write-LogError 'Usage: claude-docker scale <N> (1-26)'
        exit 1
    }

    $newCount = [int]$Arguments[0]
    if ($newCount -lt 1 -or $newCount -gt 26) {
        Write-LogError "Account count must be between 1 and 26 (got: $newCount)"
        exit 1
    }

    $currentCount = Get-NumAccounts -ProjectRoot $ProjectRoot
    Write-Host "Scaling: $currentCount -> $newCount account(s)" -ForegroundColor White

    # Update NUM_ACCOUNTS in .env
    $envFile = Join-Path $ProjectRoot '.env'
    if (-not (Test-Path $envFile)) {
        Write-LogError '.env not found. Run install.ps1 first.'
        exit 1
    }
    Set-EnvValue -Path $envFile -Key 'NUM_ACCOUNTS' -Value $newCount

    # Create state directories for new accounts
    if ($newCount -gt $currentCount) {
        Write-Host 'Creating new state directories...' -ForegroundColor Cyan
        for ($i = $currentCount + 1; $i -le $newCount; $i++) {
            $letter = ConvertTo-AccountLetter -Index $i
            $stateDir = Join-Path (Get-AgentStateRoot -ProjectRoot $ProjectRoot) "account-$letter"
            if (-not (Test-Path $stateDir)) {
                New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
                Write-Host "  + account-$letter" -ForegroundColor Green
            }
        }
    }

    # Warn about memory
    $totalMem = $newCount * 4
    if ($newCount -ge 4) {
        Write-LogWarn "Total memory limit: ${totalMem}G ($newCount x 4G). Ensure sufficient host RAM."
    }

    # Regenerate compose files
    Write-Host 'Regenerating compose files...' -ForegroundColor Cyan
    & "$PSScriptRoot\generate-compose.ps1" -NumAccounts $newCount

    # Restart containers if running
    $primary = Get-PrimaryService -ProjectRoot $ProjectRoot
    $running = Get-ContainerId -ProjectRoot $ProjectRoot -Service $primary
    if ($running) {
        Write-Host 'Restarting containers...' -ForegroundColor Cyan
        Invoke-Compose -ProjectRoot $ProjectRoot down
        Invoke-Compose -ProjectRoot $ProjectRoot up --detach
    }

    Write-Host "Scaled to $newCount account(s)." -ForegroundColor Green

    # Show summary
    Write-Host ''
    Write-Host 'Active services:' -ForegroundColor White
    foreach ($svc in (Get-ServiceNames -ProjectRoot $ProjectRoot)) {
        Write-Host "  * $svc" -ForegroundColor Green
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
    # Usage aggregation availability is a per-runtime registry capability
    # (supportsUsage), not a hardcoded claude-only check.
    $runtime = Get-AgentRuntime -ProjectRoot $ProjectRoot
    if ((Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $runtime -Field 'supportsUsage') -ne $true) {
        Write-LogError 'usage is currently Claude-only; Codex usage aggregation is not supported.'
        exit 1
    }

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
    Write-Host '  update                ' -ForegroundColor Green -NoNewline; Write-Host 'Rebuild with latest agent CLI and recreate'
    Write-Host '  ps                    ' -ForegroundColor Green -NoNewline; Write-Host 'Show container status'
    Write-Host '  logs                  ' -ForegroundColor Green -NoNewline; Write-Host 'Follow container logs'
    Write-Host ''
    Write-Host 'INTERACTIVE' -ForegroundColor White
    Write-Host '  claude [service]      ' -ForegroundColor Green -NoNewline; Write-Host 'Start Claude Code (default: claude-a)'
    Write-Host '  codex [service]       ' -ForegroundColor Green -NoNewline; Write-Host 'Start OpenAI Codex CLI (default: codex-a)'
    Write-Host '  gh-auth               ' -ForegroundColor Green -NoNewline; Write-Host 'Inject GitHub token from host gh CLI'
    Write-Host '  exec <service>        ' -ForegroundColor Green -NoNewline; Write-Host 'Open shell in a service'
    Write-Host ''
    Write-Host 'USAGE TRACKING' -ForegroundColor White
    Write-Host '  usage [type] [flags]  ' -ForegroundColor Green -NoNewline; Write-Host 'Token usage report (default: daily)'
    Write-Host '                        Types: daily, monthly, session, blocks, statusline'
    Write-Host ''
    Write-Host 'SCALING' -ForegroundColor White
    Write-Host '  scale <N>             ' -ForegroundColor Green -NoNewline; Write-Host 'Set number of accounts (1-26) and regenerate'
    Write-Host ''
    Write-Host 'ADVANCED' -ForegroundColor White
    Write-Host '  config                ' -ForegroundColor Green -NoNewline; Write-Host 'Show resolved compose configuration'
    Write-Host '  compose ...           ' -ForegroundColor Green -NoNewline; Write-Host 'Pass raw args to docker compose'
    Write-Host ''
    $numAccts = Get-NumAccounts -ProjectRoot $ProjectRoot
    Write-Host "SERVICES ($numAccts configured)" -ForegroundColor White
    $svcNames = @(Get-ServiceNames -ProjectRoot $ProjectRoot)
    for ($idx = 0; $idx -lt $svcNames.Count; $idx++) {
        $svc = $svcNames[$idx]
        $prefix = Get-ServicePrefix -ProjectRoot $ProjectRoot
        $suffix = ($svc -replace "^$([regex]::Escape($prefix))-", '').ToUpper()
        $label = "Account $suffix"
        if ($idx -eq 0) { $label += ' (default)' }
        Write-Host "  $($svc.PadRight(22))" -ForegroundColor Green -NoNewline; Write-Host $label
    }
    Write-Host ''
    Write-Host 'DETECTED COMPOSE COMMAND' -ForegroundColor White
    Write-Host "  $composeDisplay" -ForegroundColor DarkGray
    Write-Host ''
}

# --- Main --------------------------------------------------------------------

function Invoke-Tui {
    $tuiBin = Join-Path $ProjectRoot 'tui\claude-docker-tui.exe'
    if (-not (Test-Path $tuiBin)) {
        Write-Host "TUI binary not found at $tuiBin" -ForegroundColor Red
        Write-Host "  Run 'scripts\claude-docker.ps1 build-tui' to build it." -ForegroundColor White
        Write-Host "  Requires Go 1.21+ toolchain. Install with 'winget install GoLang.Go' or from https://go.dev/dl/" -ForegroundColor DarkGray
        exit 1
    }
    & $tuiBin @Arguments
    exit $LASTEXITCODE
}

function Invoke-BuildTui {
    $tuiDir = Join-Path $ProjectRoot 'tui'
    if (-not (Test-Path (Join-Path $tuiDir 'go.mod'))) {
        Write-Host "TUI source not found at $tuiDir" -ForegroundColor Red
        exit 1
    }
    if (-not (Get-Command 'go' -ErrorAction SilentlyContinue)) {
        Write-Host 'Go toolchain not found. Install Go 1.21+ first:' -ForegroundColor Red
        Write-Host '  winget install GoLang.Go' -ForegroundColor DarkGray
        Write-Host '  or: https://go.dev/dl/' -ForegroundColor DarkGray
        exit 1
    }

    Write-Host 'Building TUI dashboard...' -ForegroundColor Cyan
    $version = 'dev'
    try {
        $gitVer = & git -C $ProjectRoot rev-parse --short HEAD 2>$null
        if ($gitVer) { $version = $gitVer }
    } catch {}

    Push-Location $tuiDir
    try {
        & go mod download 2>&1 | Select-Object -Last 3
        & go build -ldflags "-X main.version=$version" -o claude-docker-tui.exe . 2>&1

        $binary = Join-Path $tuiDir 'claude-docker-tui.exe'
        if (Test-Path $binary) {
            $size = [math]::Round((Get-Item $binary).Length / 1MB, 1)
            Write-Host "TUI built: tui\claude-docker-tui.exe (${size}MB)" -ForegroundColor Green
            Write-Host "  Launch with scripts\claude-docker.ps1 tui" -ForegroundColor White
        } else {
            Write-Host 'Build failed - binary not produced.' -ForegroundColor Red
            exit 1
        }
    }
    finally {
        Pop-Location
    }
}

# Runtime subcommands (claude, codex, ...) route to the unified Invoke-Agent
# rather than being enumerated below, so a new registry entry needs no change
# here. Matched before the static switch.
if ($Command -in (Get-RuntimeList -ProjectRoot $ProjectRoot)) {
    Invoke-Agent -Subcommand $Command
    return
}

switch ($Command) {
    'up'         { Invoke-Up }
    'down'       { Invoke-Down }
    'restart'    { Invoke-Restart }
    'logs'       { Invoke-Logs }
    'ps'         { Invoke-Ps }
    'exec'       { Invoke-Exec }
    'tui'        { Invoke-Tui }
    'dashboard'  { Invoke-Tui }
    'gh-auth'    { Invoke-GhAuth }
    'usage'      { Invoke-Usage }
    'build'      { Invoke-Build }
    'build-tui'  { Invoke-BuildTui }
    'update'     { Invoke-Update }
    'scale'      { Invoke-Scale }
    'config'     { Invoke-Config }
    'compose'    { Invoke-ComposePass }
    { $_ -in 'help', '--help', '-h' } { Show-Help }
    default {
        Write-Host "Unknown command: $Command" -ForegroundColor Red
        Show-Help
        exit 1
    }
}
