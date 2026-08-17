#Requires -Version 7.0
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

# --- Exit Code Propagation ----------------------------------------------------

# What this script will exit with. The dispatch switch is the last statement in
# the file, so every branch used to fall off the end with rc=0 no matter what
# docker did.
#
# $ErrorActionPreference = 'Stop' does not cover this: a native command's
# non-zero exit is not a PowerShell error.
#
#   pwsh -NoProfile -Command "$ErrorActionPreference='Stop'; & cmd /c exit 7; 'reached'"
#   reached      <- and the caller sees rc=0
#
# The bash wrapper gets this from `set -euo pipefail`, which is why cmd_up can
# print "Containers started." unguarded and still be correct. The PowerShell
# port copied the structure without the guarantee underneath it.
$script:ExitCode = 0

function Test-ComposeSucceeded {
    <#
    .SYNOPSIS
    Record docker's exit code and report whether it succeeded.
    .DESCRIPTION
    Called immediately after an Invoke-Compose. $LASTEXITCODE is an automatic
    *global*, so the native command inside the module sets the same variable
    this reads -- no plumbing needed, only the reading that was missing.

    Returns $true on success so callers can gate their success message on it,
    which is the other half of the defect: "Containers started." printed after
    a missing image or an unresolvable bind source.
    #>
    param([Parameter(Mandatory)][string]$What)

    if ($LASTEXITCODE -ne 0) {
        $script:ExitCode = $LASTEXITCODE
        Write-LogError "$What failed (docker exited $LASTEXITCODE)."
        return $false
    }
    return $true
}

# --- Account Directory Helpers -----------------------------------------------

function Get-GhAuthMode {
    $mode = [Environment]::GetEnvironmentVariable('GH_AUTH_MODE')
    if ([string]::IsNullOrEmpty($mode)) {
        $mode = Get-EnvValue -Path (Join-Path $ProjectRoot '.env') -Key 'GH_AUTH_MODE'
    }
    if ([string]::IsNullOrEmpty($mode)) { $mode = 'shared' }
    $mode = $mode.ToLowerInvariant()
    if ($mode -notin @('shared', 'per-account')) {
        throw "GH_AUTH_MODE must be shared or per-account (got: $mode)"
    }
    return $mode
}

function Resolve-AccountLetter {
    param([Parameter(Mandatory)][string]$Target)

    $candidate = $Target.ToLowerInvariant()
    $prefix = Get-ServicePrefix -ProjectRoot $ProjectRoot
    if ($candidate.StartsWith("${prefix}-")) {
        $candidate = $candidate.Substring($prefix.Length + 1)
    }
    $count = Get-NumAccounts -ProjectRoot $ProjectRoot
    for ($i = 1; $i -le $count; $i++) {
        $letter = Get-AccountLetter -Index $i
        if ($candidate -eq $letter) { return $letter }
    }
    return $null
}

function Get-AccountEnvSuffix {
    param([Parameter(Mandatory)][string]$Letter)
    return $Letter.ToUpperInvariant()
}

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

function Show-IsolationMode {
    <#
    .SYNOPSIS
    Print the active isolation mode and the trust boundary it provides.
    .DESCRIPTION
    Mirrors show_isolation_mode in scripts/claude-docker. Startup and `config`
    both call it so the boundary a session runs under is stated rather than
    inferred from which compose files the caller happened to pass.

    Uses Get-IsolationMode, not the Supported variant: a user whose
    per-account workspace paths are missing should still be told which
    boundary was asked for before Get-ComposeArgs refuses to start on it.
    #>
    $mode = Get-IsolationMode -ProjectRoot $ProjectRoot
    Write-Host "Isolation mode: $mode"
    Write-Host "  $(Get-IsolationModeSummary -Mode $mode)" -ForegroundColor DarkGray
    # Only under isolated: no other mode reads the network policy, and printing
    # it elsewhere would suggest it applies when it does not.
    if ($mode -eq 'isolated') {
        $net = Get-IsolatedNetworkMode -ProjectRoot $ProjectRoot
        Write-Host "Network policy: $net"
        Write-Host "  $(Get-IsolatedNetworkModeSummary -Mode $net)" -ForegroundColor DarkGray
    }
    Write-UnusedWorkspacePathWarning -ProjectRoot $ProjectRoot -Mode $mode
}

function Invoke-Up {
    # Printed before the compose call so an unusable mode is diagnosed with
    # its description already on screen.
    Show-IsolationMode
    Write-Host ''
    Write-Host 'Starting containers...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot up --detach @Arguments
    if (-not (Test-ComposeSucceeded 'up')) { return }
    Write-Host 'Containers started.' -ForegroundColor Green
    Write-Host ''
    Invoke-Compose -ProjectRoot $ProjectRoot ps
    $null = Test-ComposeSucceeded 'ps'

    # Lightweight post-start GitHub auth check (non-blocking)
    Write-Host ''
    $primary = Get-PrimaryService -ProjectRoot $ProjectRoot
    $cid = Get-ContainerId -ProjectRoot $ProjectRoot -Service $primary
    if ($cid) {
        Start-Sleep -Seconds 2  # wait for entrypoint gh auth setup
        Test-AllContainerGhAuth | Out-Null
    }
}

function Invoke-Down {
    Write-Host 'Stopping containers...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot down @Arguments
    if (-not (Test-ComposeSucceeded 'down')) { return }
    Write-Host 'Containers stopped.' -ForegroundColor Green
}

function Invoke-Restart {
    Write-Host 'Restarting containers...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot restart @Arguments
    if (-not (Test-ComposeSucceeded 'restart')) { return }
    Write-Host 'Containers restarted.' -ForegroundColor Green
}

function Invoke-Logs {
    Invoke-Compose -ProjectRoot $ProjectRoot logs -f @Arguments
    $null = Test-ComposeSucceeded 'logs'
}

function Invoke-Ps {
    Invoke-Compose -ProjectRoot $ProjectRoot ps @Arguments
    $null = Test-ComposeSucceeded 'ps'
}

function Invoke-Exec {
    if ($Arguments.Count -eq 0) {
        Write-LogError 'Usage: claude-docker exec <service> [command...]'
        exit 1
    }

    $service = $Arguments[0]
    $rest = if ($Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] } else { @('bash') }

    Invoke-Compose -ProjectRoot $ProjectRoot exec $service @rest
    # exec's exit code is the command's, and a caller scripting around this
    # wrapper needs it.
    $null = Test-ComposeSucceeded 'exec'
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
    $null = Test-ComposeSucceeded "$label"
}

function Get-HostGhToken {
    param([string]$User = '')

    if ($User) {
        $token = & gh auth token --hostname github.com --user $User 2>$null
    }
    else {
        $token = & gh auth token 2>$null
    }
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]($token | Select-Object -First 1)).Trim()
}

function Invoke-GhAuthShared {
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

    $token = Get-HostGhToken
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
        Write-Host 'Recreating containers to apply...' -ForegroundColor Cyan
        Invoke-Compose -ProjectRoot $ProjectRoot up --detach --force-recreate
        # A failed recreate means the token was written to .env but no
        # container picked it up. Verifying auth after that would report a
        # stale answer, so stop here with the code recorded.
        if (-not (Test-ComposeSucceeded 'up --force-recreate')) { return }

        Start-Sleep -Seconds 2
        $cid = Get-ContainerId -ProjectRoot $ProjectRoot -Service $primary
        if ($cid) {
            Write-Host ''
            Write-Host "Verifying GitHub auth in ${primary}:" -ForegroundColor White
            Test-AllContainerGhAuth | Out-Null
        }
    }
    else {
        Write-LogInfo 'Containers not running. Token will be available on next start.'
    }
}

function Invoke-GhAuthPerAccount {
    if (-not (Test-Command 'gh')) {
        Write-LogError 'gh CLI not found on host.'
        exit 1
    }

    $all = $false
    $target = ''
    $login = ''
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        switch ($Arguments[$i]) {
            '--all' { $all = $true; break }
            '--user' {
                if ($i + 1 -ge $Arguments.Count -or [string]::IsNullOrEmpty($Arguments[$i + 1])) {
                    Write-LogError '--user requires a GitHub login.'
                    exit 1
                }
                $i++
                $login = $Arguments[$i]
                break
            }
            { $_.StartsWith('--') } {
                Write-LogError "Unknown gh-auth option: $_"
                exit 1
            }
            default {
                if ($target) {
                    Write-LogError 'Only one service or account letter may be selected.'
                    exit 1
                }
                $target = $Arguments[$i]
            }
        }
    }

    $envFile = Join-Path $ProjectRoot '.env'
    if (-not (Test-Path $envFile)) {
        Write-LogError ".env file not found at $envFile"
        exit 1
    }

    $letters = @()
    $users = @()
    $tokens = @()
    $services = @()
    if ($all) {
        if ($target -or $login) {
            Write-LogError 'gh-auth --all cannot be combined with a target or --user.'
            exit 1
        }
        $count = Get-NumAccounts -ProjectRoot $ProjectRoot
        for ($i = 1; $i -le $count; $i++) {
            $letter = Get-AccountLetter -Index $i
            $upper = Get-AccountEnvSuffix -Letter $letter
            $user = Get-EnvValue -Path $envFile -Key "GH_USER_${upper}"
            if (-not $user) {
                Write-LogError "GH_USER_${upper} is required for gh-auth --all."
                exit 1
            }
            $token = Get-HostGhToken -User $user
            if (-not $token) {
                Write-LogError "Could not extract a GitHub token for login '$user' (Account $upper)."
                exit 1
            }
            $letters += $letter
            $users += $user
            $tokens += $token
            $services += "$(Get-ServicePrefix -ProjectRoot $ProjectRoot)-$letter"
        }
    }
    else {
        if (-not $target -or -not $login) {
            Write-LogError 'Usage: claude-docker gh-auth <service-or-letter> --user <login>'
            exit 1
        }
        $letter = Resolve-AccountLetter -Target $target
        if (-not $letter) {
            Write-LogError "Unknown or unconfigured account target: $target"
            exit 1
        }
        $upper = Get-AccountEnvSuffix -Letter $letter
        $token = Get-HostGhToken -User $login
        if (-not $token) {
            Write-LogError "Could not extract a GitHub token for login '$login' (Account $upper)."
            exit 1
        }
        $letters += $letter
        $users += $login
        $tokens += $token
        $services += "$(Get-ServicePrefix -ProjectRoot $ProjectRoot)-$letter"
    }

    # Persist only after every requested token was retrieved successfully.
    for ($i = 0; $i -lt $letters.Count; $i++) {
        $upper = Get-AccountEnvSuffix -Letter $letters[$i]
        Set-EnvValue -Path $envFile -Key "GH_USER_${upper}" -Value $users[$i]
        Set-EnvValue -Path $envFile -Key "GH_TOKEN_${upper}" -Value $tokens[$i]
        Write-Host "  * Account $upper mapped to GitHub login '$($users[$i])'." -ForegroundColor Green
    }

    $runningServices = @()
    foreach ($service in $services) {
        if (Get-ContainerId -ProjectRoot $ProjectRoot -Service $service) {
            $runningServices += $service
        }
    }
    if ($runningServices.Count -eq 0) {
        Write-LogInfo 'Selected containers are not running. Tokens will be available on next start.'
        return
    }

    Write-Host 'Recreating selected container(s) to apply...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot up --detach --force-recreate @runningServices
    # Same as the shared path: verifying auth against containers that were not
    # recreated would report a stale answer.
    if (-not (Test-ComposeSucceeded 'up --force-recreate')) { return }
    Start-Sleep -Seconds 2
    foreach ($service in $runningServices) {
        Test-ContainerGhAuth -Service $service | Out-Null
    }
}

function Invoke-GhAuth {
    $mode = Get-GhAuthMode
    if ($mode -eq 'per-account') {
        Invoke-GhAuthPerAccount
        return
    }
    if ($Arguments.Count -gt 0 -and $Arguments[0] -ne '--all') {
        Write-LogError 'Targeted gh-auth requires GH_AUTH_MODE=per-account.'
        exit 1
    }
    Invoke-GhAuthShared
}

# --- GitHub Auth Helpers ------------------------------------------------------

function Update-SharedGhToken {
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

    $freshToken = Get-HostGhToken
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

function Update-PerAccountGhTokens {
    $envFile = Join-Path $ProjectRoot '.env'
    if (-not (Test-Command 'gh')) {
        Write-LogInfo 'gh CLI not found on host — skipping GitHub token refresh.'
        return $false
    }
    if (-not (Test-Path $envFile)) {
        Write-LogWarn '.env not found — cannot refresh per-account GitHub tokens.'
        return $false
    }

    $suffixes = @()
    $tokens = @()
    $count = Get-NumAccounts -ProjectRoot $ProjectRoot
    for ($i = 1; $i -le $count; $i++) {
        $upper = (Get-AccountLetter -Index $i).ToUpperInvariant()
        $user = Get-EnvValue -Path $envFile -Key "GH_USER_${upper}"
        if (-not $user) {
            Write-LogWarn "GH_USER_${upper} is missing; per-account token refresh skipped."
            return $false
        }
        $token = Get-HostGhToken -User $user
        if (-not $token) {
            Write-LogWarn "Could not extract a GitHub token for configured login '$user' (Account $upper)."
            return $false
        }
        $suffixes += $upper
        $tokens += $token
    }

    $changed = 0
    for ($i = 0; $i -lt $suffixes.Count; $i++) {
        $key = "GH_TOKEN_$($suffixes[$i])"
        if ((Get-EnvValue -Path $envFile -Key $key) -ne $tokens[$i]) {
            Set-EnvValue -Path $envFile -Key $key -Value $tokens[$i]
            $changed++
        }
    }
    Write-Host "  * Per-account GitHub tokens verified ($($suffixes.Count) account(s), $changed updated)." -ForegroundColor Green
    return $true
}

function Update-GhToken {
    if ((Get-GhAuthMode) -eq 'per-account') {
        return (Update-PerAccountGhTokens)
    }
    return (Update-SharedGhToken)
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

    $output = @(& docker exec $cid gh api user --jq .login 2>$null)
    $exitCode = $LASTEXITCODE
    $actual = ($output -join '').Trim()
    if ($exitCode -ne 0 -or -not $actual) {
        Write-Host "  ! GitHub auth: not configured ($Service)" -ForegroundColor Yellow
        Write-Host '    git push/pull and gh commands may fail.' -ForegroundColor DarkGray
        Write-Host '    Fix: .\scripts\claude-docker.ps1 gh-auth' -ForegroundColor DarkGray
        return $false
    }

    if ((Get-GhAuthMode) -eq 'per-account') {
        $prefix = Get-ServicePrefix -ProjectRoot $ProjectRoot
        $letter = $Service.Substring($prefix.Length + 1)
        $upper = $letter.ToUpperInvariant()
        $expected = Get-EnvValue -Path (Join-Path $ProjectRoot '.env') -Key "GH_USER_${upper}"
        if ($expected -and -not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "  ! GitHub auth: MISMATCH ($Service)" -ForegroundColor Yellow
            Write-Host "    actual: $actual"
            Write-Host "    expected: $expected (GH_USER_${upper})"
            return $false
        }
    }

    Write-Host "  * GitHub auth: $actual ($Service)" -ForegroundColor Green
    return $true
}

function Test-AllContainerGhAuth {
    $ok = $true
    foreach ($service in (Get-ServiceNames -ProjectRoot $ProjectRoot)) {
        if (Get-ContainerId -ProjectRoot $ProjectRoot -Service $service) {
            if (-not (Test-ContainerGhAuth -Service $service)) { $ok = $false }
        }
    }
    return $ok
}

function Invoke-Build {
    Write-Host 'Building Docker image...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot build @Arguments
    if (-not (Test-ComposeSucceeded 'build')) { return }
    Write-Host 'Build complete.' -ForegroundColor Green
}

function Invoke-Update {
    # The registry's `binary` field, not the runtime key: this value is exec'd
    # inside the container below (#356, row 3). cmd_update in the bash wrapper
    # calls agent_binary for the same reason.
    $binary = Get-AgentBinary -ProjectRoot $ProjectRoot
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
    # Recreating containers from an image that failed to build would replace a
    # working stack with a broken one, so this stops rather than continuing.
    if (-not (Test-ComposeSucceeded 'build --no-cache')) { return }

    Write-Host '[4/5] Recreating containers...' -ForegroundColor Cyan
    Invoke-Compose -ProjectRoot $ProjectRoot up --detach --force-recreate
    if (-not (Test-ComposeSucceeded 'up --force-recreate')) { return }

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
        Test-AllContainerGhAuth | Out-Null

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
        Write-LogError "Usage: claude-docker scale <N> (1-$(Get-MaxAccountCount))"
        exit 1
    }

    # Validated through lib/index.ps1, re-exported by ClaudeDocker.psm1 (#356).
    $rawCount = $Arguments[0]
    $newCount = Get-NormalizedAccountCount -Value ([string]$rawCount)
    if ($null -eq $newCount) {
        Write-LogError "Account count must be between 1 and $(Get-MaxAccountCount) (got: $rawCount)"
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
    # Validate the new count against the isolation contract BEFORE touching
    # .env. The generators are deliberately fail-closed so a failure "cannot
    # leave a partially regenerated set behind" -- but the caller had already
    # moved. On a worktree install holding only PROJECT_DIR_A/B, `scale 4`
    # wrote NUM_ACCOUNTS=4, created account-c and account-d, and then died on
    # "PROJECT_DIR_C is required when ISOLATION_MODE=worktree", leaving .env
    # saying 4 and the compose files saying 2.
    #
    # Nothing downstream catches that split: `up` resolves the mode with the
    # default account count of 1, so it passes and starts two containers,
    # while Get-ServiceNames, the TUI and the help text all read NUM_ACCOUNTS
    # and report four.
    try {
        $null = Get-SupportedIsolationMode -ProjectRoot $ProjectRoot -AccountCount $newCount
    }
    catch {
        Write-LogError "Cannot scale to $newCount account(s): $($_.Exception.Message)"
        Write-LogInfo "NUM_ACCOUNTS is unchanged at $currentCount."
        exit 1
    }

    Set-EnvValue -Path $envFile -Key 'NUM_ACCOUNTS' -Value $newCount

    # Create state directories for new accounts
    if ($newCount -gt $currentCount) {
        Write-Host 'Creating new state directories...' -ForegroundColor Cyan
        for ($i = $currentCount + 1; $i -le $newCount; $i++) {
            $letter = Get-AccountLetter -Index $i
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
        $null = Test-ComposeSucceeded 'down'
        Invoke-Compose -ProjectRoot $ProjectRoot up --detach
        if (-not (Test-ComposeSucceeded 'up')) { return }
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
    Show-IsolationMode
    Write-Host ''
    $baseArgs = Get-ComposeArgs -ProjectRoot $ProjectRoot
    Write-Host "Compose args: docker compose $($baseArgs -join ' ')" -ForegroundColor DarkGray
    Write-Host ''
    Invoke-Compose -ProjectRoot $ProjectRoot config @Arguments
    $null = Test-ComposeSucceeded 'config'
}

function Invoke-ComposePass {
    Invoke-Compose -ProjectRoot $ProjectRoot @Arguments
    # The raw pass-through: `compose --bogus-flag` must not exit 0.
    $null = Test-ComposeSucceeded 'compose'
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
    Write-Host '  gemini [service]      ' -ForegroundColor Green -NoNewline; Write-Host 'Start Google Gemini CLI (default: gemini-a)'
    Write-Host '  gh-auth [target]      ' -ForegroundColor Green -NoNewline; Write-Host 'Import shared or per-account host gh credentials'
    Write-Host '                        Per-account: <service-or-letter> --user <login> | --all'
    Write-Host '  exec <service> [cmd]  ' -ForegroundColor Green -NoNewline; Write-Host 'Open a shell or run a command in a service'
    Write-Host ''
    Write-Host 'USAGE TRACKING' -ForegroundColor White
    Write-Host '  usage [type] [flags]  ' -ForegroundColor Green -NoNewline; Write-Host 'Token usage report (default: daily)'
    Write-Host '                        Types: daily, monthly, session, blocks, statusline'
    Write-Host '                        Flags: --since, --until, --json, --breakdown, --compact'
    Write-Host ''
    Write-Host 'DASHBOARD' -ForegroundColor White
    Write-Host '  tui                   ' -ForegroundColor Green -NoNewline; Write-Host 'Launch multi-account dashboard TUI'
    Write-Host '  dashboard             ' -ForegroundColor Green -NoNewline; Write-Host 'Alias of tui'
    Write-Host '  build-tui             ' -ForegroundColor Green -NoNewline; Write-Host 'Rebuild TUI dashboard binary (requires Go 1.24+)'
    Write-Host ''
    Write-Host 'SCALING' -ForegroundColor White
    Write-Host '  scale <N>             ' -ForegroundColor Green -NoNewline; Write-Host "Set number of accounts (1-$(Get-MaxAccountCount)) and regenerate"
    Write-Host ''
    Write-Host 'ADVANCED' -ForegroundColor White
    Write-Host '  config                ' -ForegroundColor Green -NoNewline; Write-Host 'Show resolved compose configuration'
    Write-Host '  compose ...           ' -ForegroundColor Green -NoNewline; Write-Host 'Pass raw args to docker compose'
    Write-Host '  help                  ' -ForegroundColor Green -NoNewline; Write-Host 'Show this help'
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
        Write-Host "  Requires Go 1.24+ toolchain. Install with 'winget install GoLang.Go' or from https://go.dev/dl/" -ForegroundColor DarkGray
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
        Write-Host 'Go toolchain not found. Install Go 1.24+ first:' -ForegroundColor Red
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
    # `claude` / `codex` used to mask the agent's own exit code.
    exit $script:ExitCode
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

# The one place all sixteen branches needed. Without it every docker-backed
# subcommand fell off the end of the file with rc=0, whatever docker did.
exit $script:ExitCode
