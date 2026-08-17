#Requires -Version 7.0
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
    pwsh -ExecutionPolicy Bypass -File scripts\install.ps1
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
#   <runtime buildArg> (optional; CLAUDE_CODE_VERSION, CODEX_CLI_VERSION or
#     GEMINI_CLI_VERSION, whichever the selected runtime names),
#   CLAUDE_API_KEY_A/B (Path B only),
#   PROJECT_DIR_A/B + CONTAINER_PROJECT_DIR_A/B (Tier B only),
#   GIT_USER_NAME, GIT_USER_EMAIL (optional),
#   GH_AUTH_MODE + GH_USER_<LETTER>/GH_TOKEN_<LETTER> (per-account only),
#   GH_TOKEN + GH_CONFIG_DIR (optional shared-mode host gh configuration)
#
# Windows note: UID/GID are intentionally NOT written. Windows has no POSIX
# UID/GID concept, and docker-compose.linux.yml (which consumes them) is not
# activated on the Windows/WSL2 Docker Desktop backend. WSL2 users running
# the Linux container with WSL2-backed Docker should use scripts/install.sh
# from inside WSL2 instead, so UID/GID is correctly populated.

Import-Module "$PSScriptRoot\ClaudeDocker.psm1" -Force
. (Join-Path $PSScriptRoot 'lib' 'index.ps1')

$ProjectRoot = Split-Path $PSScriptRoot -Parent

# --- Configuration State -----------------------------------------------------

$Script:AuthPath = ''
$Script:Tier = ''
$Script:SourceDir = ''
$Script:RuntimeVersion = ''
$Script:RuntimeBuildArg = ''
$Script:RuntimeDisplayName = ''
$Script:ApiKeyA = ''
$Script:ApiKeyB = ''
# Selected agent runtime (claude, codex, gemini, ...). Defaults to claude so a
# non-interactive or default install behaves exactly as before (see #273).
$Script:Runtime = 'claude'
$Script:GhAuthMode = 'shared'
$Script:GhUsers = @()
$Script:GhTokens = @()

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

# Test-GoInstalled returns $true when Go >= 1.21 is available.
# Go is OPTIONAL — only required for building the TUI dashboard binary.
function Test-GoInstalled {
    if (-not (Test-Command 'go')) { return $false }
    $raw = (& go version 2>$null) -replace '.*go(\d+\.\d+).*', '$1'
    if (-not $raw -or -not ($raw -match '^\d+\.\d+$')) { return $false }
    $parts = $raw.Split('.')
    [int]$major = $parts[0]
    [int]$minor = $parts[1]
    if ($major -gt 1 -or ($major -eq 1 -and $minor -ge 21)) {
        Write-LogSuccess "Go $raw detected (TUI build available)"
        return $true
    }
    Write-LogWarn "Go $raw detected but version < 1.21 — TUI build will be skipped"
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
            'go' {
                & winget install -e --id GoLang.Go --accept-source-agreements --accept-package-agreements
                Write-LogWarn 'Go installed. You may need to restart your terminal for PATH updates.'
            }
        }
        return ($LASTEXITCODE -eq 0)
    }

    Write-LogError "winget not found. Please install $Tool manually:"
    switch ($Tool) {
        'docker' { Write-LogInfo '  https://www.docker.com/products/docker-desktop/' }
        'git'    { Write-LogInfo '  https://git-scm.com/download/win' }
        'node'   { Write-LogInfo '  https://nodejs.org/' }
        'go'     { Write-LogInfo '  https://go.dev/dl/' }
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

    # Agent runtime. Options are read from the runtime registry; claude is
    # listed first so accepting the default keeps today's behavior. A single
    # registered runtime skips the prompt entirely.
    $runtimes = @(Get-RuntimeList -ProjectRoot $ProjectRoot)
    if ($runtimes -contains 'claude') {
        $runtimes = @('claude') + ($runtimes | Where-Object { $_ -ne 'claude' })
    }
    if ($runtimes.Count -gt 1) {
        $Script:Runtime = Read-Selection `
            -Question 'Which agent runtime will you use?' `
            -Options $runtimes
    }
    elseif ($runtimes.Count -eq 1) {
        $Script:Runtime = $runtimes[0]
    }
    Write-LogInfo "Agent runtime: $($Script:Runtime)"

    # Auth Path
    $authChoice = Read-Selection `
        -Question 'Which authentication method will you use?' `
        -Options @(
            'OAuth - Claude.ai Pro/Max/Team subscription (browser login inside container)',
            'API key - Anthropic Console account (paste key)'
        )
    $Script:AuthPath = if ($authChoice -like 'OAuth*') { 'A' } else { 'B' }
    $label = if ($Script:AuthPath -eq 'A') { 'OAuth' } else { 'API key' }
    Write-LogInfo "Authentication method: $label"

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

    # Runtime CLI version. The prompt is unconditional, so it also runs for a
    # codex or gemini install -- and the value used to be written as
    # CLAUDE_CODE_VERSION regardless (#356, row 4). That dropped the chosen
    # runtime's own pin and fed the number to the Claude installer inside the
    # image instead. The variable name comes from the registry now, the same
    # way generate-compose.ps1 resolves it.
    $Script:RuntimeBuildArg = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Script:Runtime -Field 'buildArg'
    $Script:RuntimeDisplayName = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Script:Runtime -Field 'displayName'
    $Script:RuntimeVersion = Read-Input -Question "$($Script:RuntimeDisplayName) version (enter specific version or 'latest')" -Default 'latest'
    if ($Script:RuntimeVersion -eq 'latest') {
        $Script:RuntimeVersion = ''
        Write-LogInfo "$($Script:RuntimeDisplayName) version: latest"
    }
    else {
        Write-LogInfo "$($Script:RuntimeDisplayName) version: $($Script:RuntimeVersion)"
    }

    # Number of accounts. The prompt and its validation live in a function so a
    # test can drive this path; see Read-AccountCount.
    $normalizedAccounts = Read-AccountCount
    if ($null -eq $normalizedAccounts) { exit 1 }
    $Script:NumAccounts = $normalizedAccounts
    Write-LogInfo "Accounts: $($Script:NumAccounts)"

    # GitHub authentication mode. Per-account setup reads each explicitly
    # named stored login without changing the active host account.
    $ghChoice = Read-Selection `
        -Question 'How should containers authenticate to GitHub?' `
        -Options @(
            "Shared account - use the host's active gh account in every container",
            'Per-account - map a different stored gh login to each container'
        )
    if ($ghChoice -like 'Per-account*') {
        $Script:GhAuthMode = 'per-account'
        if (-not (Test-Command 'gh')) {
            Write-LogError 'Per-account GitHub setup requires the host gh CLI.'
            exit 1
        }
        Write-Host ''
        Write-Host 'Enter host GitHub logins already stored by gh:' -ForegroundColor Cyan
        for ($i = 1; $i -le $Script:NumAccounts; $i++) {
            $upper = Get-AccountLetterUpper -Index $i
            $login = Read-Input -Question "GitHub login for Account $upper"
            $token = & gh auth token --hostname github.com --user $login 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $token) {
                Write-LogError "Could not read a stored github.com token for '$login'."
                Write-LogInfo 'Authenticate it first with: gh auth login --hostname github.com'
                exit 1
            }
            $Script:GhUsers += $login
            $Script:GhTokens += ([string]($token | Select-Object -First 1)).Trim()
        }
        Write-LogSuccess "Per-account GitHub mappings collected ($($Script:NumAccounts) accounts)"
    }
    else {
        $Script:GhAuthMode = 'shared'
        Write-LogInfo 'GitHub authentication: shared account'
    }

    # API keys (Path B). The .env variable prefix is resolved from the runtime
    # registry (CLAUDE_API_KEY_ / CODEX_API_KEY_ / GEMINI_API_KEY_ / ...).
    $Script:ApiKeys = @()
    if ($Script:AuthPath -eq 'B') {
        $apiKeyPrefix = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Script:Runtime -Field 'apiKeyVarPrefix'
        Write-Host ''
        Write-Host "Enter Console API keys (written as ${apiKeyPrefix}<LETTER>):" -ForegroundColor Cyan
        for ($i = 1; $i -le $Script:NumAccounts; $i++) {
            $letter = Get-AccountLetterUpper -Index $i  # A, B, ..., Z, AA, ZZ
            $Script:ApiKeys += Read-Secret -Question "API key for Account $letter"
        }

        if (-not $Script:ApiKeys[0]) {
            Write-LogError 'At least the first API key is required for Path B.'
            exit 1
        }
        Write-LogSuccess "API keys collected ($($Script:NumAccounts) accounts)"
    }
}

# --- .env Generation ----------------------------------------------------------

function Get-EnvBackupTimestamp {
    <#
    .SYNOPSIS
    The suffix both installers put on a .env backup: "utc" + UTC yyyyMMddHHmmss.
    .DESCRIPTION
    One format on both sides (#356, row 8). install.sh wrote a 10-digit
    `date +%s` epoch while this wrote 14-digit yyyyMMddHHmmss, and both rotate
    by name sort -- so a 14-digit "2026..." outranked every epoch and
    alternating the two installers on one project root kept the three newest
    *PowerShell* backups rather than the three newest backups.

    UTC rather than local: local time is not monotonic across a DST
    fall-back, and the rotation depends on name order matching chronological
    order.

    An earlier version of this note claimed the switch to UTC was harmless
    here because "the format itself is unchanged, so existing backups keep
    sorting correctly". That was wrong for any host east of UTC. This function
    used to return LOCAL time in the same 14-digit shape, so legacy backups are
    the same width as new ones and a name sort compares them digit for digit --
    and a local stamp runs ahead of a UTC stamp taken at the same instant. On a
    UTC+9 host every legacy backup from the previous nine hours outranked a
    brand-new one, and Remove-StaleEnvBackups deleted the file Copy-Item had
    just written, in the same invocation.

    The "utc" prefix fixes it: a leading letter sorts above every digit, so any
    stamp in this format outranks any stamp in either legacy format regardless
    of timezone, and legacy backups rotate out first. Nothing parses the suffix
    back -- cleanup.ps1 and remove.ps1 match the `.env.backup.*` glob and
    select by file age.
    #>
    [CmdletBinding()]
    param()
    return 'utc' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
}

function Read-AccountCount {
    <#
    .SYNOPSIS
    Prompt for the account count and validate it through the shared rule.
    .DESCRIPTION
    Returns the normalized count, or $null after reporting the range when the
    answer is not usable.

    The upper bound is "zz" from Excel-style letter enumeration; the validator
    catches typos like 2600 without capping legitimate multi-tenant setups at
    the historic 26-account ceiling. Both the bound and the parse come from
    lib/index.ps1 (#356), so this prompt cannot drift from what the generator
    will accept a moment later.

    It is a function rather than inline lines because the only way to reach the
    validation used to be running the whole interactive installer. No test
    could get to it, so nothing in CI would notice an edit that went back to
    typing the bound at this call site -- the regression #356 asks to be
    guarded against. tests/test_num_accounts_precedence.sh drives it with
    Read-Input stubbed.
    #>
    [CmdletBinding()]
    param()
    $maxAccounts = Get-MaxAccountCount
    $numInput = Read-Input -Question "Number of accounts to configure (1-$maxAccounts)" -Default '2'
    $normalized = Get-NormalizedAccountCount -Value $numInput
    if ($null -eq $normalized) {
        Write-LogError "Number of accounts must be an integer between 1 and $maxAccounts (got: $numInput)."
        return $null
    }
    return $normalized
}

function Remove-StaleEnvBackups {
    param(
        [Parameter(Mandatory)][string]$EnvFile,
        [int]$Keep = 3
    )
    $dir = Split-Path -Parent $EnvFile
    $pattern = (Split-Path -Leaf $EnvFile) + '.backup.*'
    Get-ChildItem -Path $dir -Filter $pattern -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -Skip $Keep |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function New-EnvFile {
    Write-LogStep 'Generating .env configuration'

    $envFile = Join-Path $ProjectRoot '.env'

    if (Test-Path $envFile) {
        if (-not (Read-Confirmation -Question 'Existing .env found. Overwrite?')) {
            Write-LogWarn 'Keeping existing .env. Some settings may not match your choices.'
            return
        }
        $timestamp = Get-EnvBackupTimestamp
        $backup = "${envFile}.backup.${timestamp}"
        Copy-Item $envFile $backup
        # Grant Modify (R,W,D) so Remove-StaleEnvBackups and remove.ps1 can
        # delete rotated backups. Full (F) would allow ACL changes — unneeded.
        & icacls $backup /inheritance:r /grant:r "${env:USERNAME}:(M)" 2>$null | Out-Null
        Remove-StaleEnvBackups -EnvFile $envFile -Keep 3
        Write-LogInfo "Backed up existing .env to $(Split-Path -Leaf $backup)"
    }

    $projectDir = ConvertTo-ForwardSlash -Path $Script:SourceDir
    $homePath = ConvertTo-ForwardSlash -Path $env:USERPROFILE

    # Seed IMAGE_TAG from repo-root VERSION so a freshly installed .env
    # matches the declared default; falls back to today's date if missing.
    $versionFile = Join-Path $ProjectRoot 'VERSION'
    if (Test-Path $versionFile) {
        $imageTag = (Get-Content $versionFile -TotalCount 1).Trim()
    }
    if ([string]::IsNullOrEmpty($imageTag)) {
        $imageTag = Get-Date -Format 'yyyy.MM.dd'
    }

    $lines = @()
    $lines += "# Generated by install.ps1 - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ''
    $lines += '# ==== Required ===='
    $lines += "NUM_ACCOUNTS=$($Script:NumAccounts)"
    $lines += "PROJECT_DIR=$projectDir"
    $lines += 'CONTAINER_PROJECT_DIR=/project'
    $lines += "IMAGE_TAG=$imageTag"
    $lines += ''
    $lines += '# ==== Windows: HOME for Docker Compose volume expansion ===='
    $lines += "HOME=$homePath"
    $lines += ''

    # AGENT_RUNTIME is written only for non-default runtimes; omitting it for
    # claude keeps a default install byte-compatible with prior runs.
    if ($Script:Runtime -ne 'claude') {
        $lines += '# ==== Agent Runtime ===='
        $lines += "AGENT_RUNTIME=$($Script:Runtime)"
        $lines += ''
    }

    $lines += '# ==== Claude Config Source (optional) ===='
    $lines += '# Set to a path inside the container to source config directly from a repo.'
    $lines += '# Example: /project/claude-config/global'
    $lines += '#CLAUDE_CONFIG_SOURCE='
    $lines += ''

    if ($Script:RuntimeVersion) {
        $lines += "# ==== $($Script:RuntimeDisplayName) Version ===="
        $lines += "$($Script:RuntimeBuildArg)=$($Script:RuntimeVersion)"
        $lines += ''
    }

    if ($Script:AuthPath -eq 'B') {
        # API-key variable prefix is resolved from the runtime registry.
        $apiKeyPrefix = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Script:Runtime -Field 'apiKeyVarPrefix'
        $lines += '# ==== Path B: Console API Keys ===='
        for ($i = 1; $i -le $Script:NumAccounts; $i++) {
            $letter = Get-AccountLetterUpper -Index $i  # A, B, ..., Z, AA, ZZ
            $lines += "${apiKeyPrefix}${letter}=$($Script:ApiKeys[$i - 1])"
        }
        $lines += ''
    }

    # Record the chosen tier as an explicit isolation mode. Resolution would
    # infer worktree from PROJECT_DIR_A anyway, but writing the key means a
    # user reading .env later sees the trust boundary stated instead of having
    # to derive it from which other variables are set.
    $lines += '# ==== Workspace isolation ===='
    $lines += '# shared | worktree | isolated -- see docs/ISOLATION.md'
    if ($Script:Tier -eq 'B') {
        $lines += 'ISOLATION_MODE=worktree'
    } else {
        $lines += 'ISOLATION_MODE=shared'
    }
    $lines += ''

    if ($Script:Tier -eq 'B') {
        $lines += '# ==== Tier B: Git Worktree Paths ===='
        $lines += '# (populated after worktree setup)'
        for ($i = 1; $i -le $Script:NumAccounts; $i++) {
            $upper = Get-AccountLetterUpper -Index $i
            $lower = Get-AccountLetter -Index $i
            $lines += "PROJECT_DIR_${upper}="
            $lines += "CONTAINER_PROJECT_DIR_${upper}=/project-${lower}"
        }
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

    # Host timezone (auto-detect IANA name so container date/time matches host).
    # Windows reports zones as Windows IDs (e.g. "Korea Standard Time"); map to
    # IANA via .NET 6+ TimeZoneInfo. Older runtimes lacking the helper fall
    # through silently — compose generator defaults TZ to UTC.
    $hostTz = $env:TZ
    if (-not $hostTz) {
        try {
            $winTz = (Get-TimeZone).Id
            $ianaId = $null
            if ([System.TimeZoneInfo]::TryConvertWindowsIdToIanaId($winTz, [ref]$ianaId)) {
                $hostTz = $ianaId
            }
        } catch {
            $hostTz = $null
        }
    }
    if ($hostTz) {
        $lines += '# ==== Timezone ===='
        $lines += "TZ=$hostTz"
        $lines += ''
    }

    if ($Script:GhAuthMode -eq 'per-account') {
        $lines += '# ==== GitHub CLI (per account) ===='
        $lines += 'GH_AUTH_MODE=per-account'
        for ($i = 1; $i -le $Script:NumAccounts; $i++) {
            $upper = Get-AccountLetterUpper -Index $i
            $lines += "GH_USER_${upper}=$($Script:GhUsers[$i - 1])"
            $lines += "GH_TOKEN_${upper}=$($Script:GhTokens[$i - 1])"
        }
        $lines += ''
    }
    else {
        # Shared GitHub CLI token (auto-detect from the active host account)
        if (Test-Command 'gh') {
            $null = & gh auth status 2>&1
            if ($LASTEXITCODE -eq 0) {
                $ghToken = & gh auth token 2>$null
                if ($ghToken) {
                    $lines += '# ==== GitHub CLI ===='
                    $lines += "GH_TOKEN=$ghToken"
                    $lines += ''
                }
            }
        }

        # Shared GitHub CLI config directory for read-only volume mount.
        # Windows: %APPDATA%\GitHub CLI (not ~/.config/gh)
        $ghConfigDir = Join-Path $env:APPDATA 'GitHub CLI'
        if (Test-Path $ghConfigDir) {
            $lines += "GH_CONFIG_DIR=$(ConvertTo-ForwardSlash -Path $ghConfigDir)"
            $lines += ''
        }
    }

    $content = ($lines -join "`n") + "`n"
    Write-EnvContent -Path $envFile -Content $content

    # Restrict file permissions (Windows ACL equivalent of chmod 600).
    # Modify (M) = R,W,D — needed so remove.ps1 can delete the .env later.
    # R,W alone blocks deletion because DELETE is a separate Windows ACL bit.
    Protect-EnvFile -Path $envFile

    Write-LogSuccess ".env generated at $envFile"

    # Handed to Invoke-ComposeGeneration, which now runs as its own step after
    # the worktrees exist.
    $Script:ImageTag = $imageTag
}

# --- Compose Generation --------------------------------------------------------

# Invoke-ComposeGeneration runs the compose generator against the finished
# .env.
#
# This used to be the last thing New-EnvFile did, which put it before
# Invoke-WorktreeSetup in the step list. For Tier B that meant handing the
# generator a .env declaring ISOLATION_MODE=worktree with empty PROJECT_DIR_*
# placeholders, and Get-SupportedIsolationMode throws on that by design (it
# does not distinguish empty from unset). With $ErrorActionPreference = 'Stop'
# the throw aborted the install. The ordering was structural, not a race.
#
# The generator is not wrong -- tests/test_isolation_modes.sh pins that exact
# refusal as a contract. The installer was violating it, so the installer
# moved.
#
# Invoke-ImageBuild still runs before this, on the committed
# docker-compose.yml. That is deliberate and safe: the image does not depend on
# the account count, the runtime or the isolation mode.
function Invoke-ComposeGeneration {
    Write-LogInfo "Generating compose files for $($Script:NumAccounts) account(s)..."
    & "$PSScriptRoot\generate-compose.ps1" -NumAccounts $Script:NumAccounts -ImageTag $Script:ImageTag
}

# --- Directory Creation -------------------------------------------------------

function New-StateDirs {
    Write-LogStep 'Creating state directories'

    # Host config directory and per-account state directory are both resolved
    # from the runtime registry (see #273). The host config dir is the
    # basename of containerHome (e.g. /home/node/.claude -> .claude); the
    # state-dir name is the registry's stateDir field verbatim.
    $containerHome = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Script:Runtime -Field 'containerHome'
    $configDir = ($containerHome -split '/')[-1]
    $stateDir = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Script:Runtime -Field 'stateDir'

    $dirs = @((Join-Path $env:USERPROFILE $configDir))
    for ($i = 1; $i -le $Script:NumAccounts; $i++) {
        $letter = Get-AccountLetter -Index $i
        $dirs += (Join-Path $env:USERPROFILE (Join-Path $stateDir "account-$letter"))
    }

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
        if ($Script:RuntimeVersion) {
            $buildArgs = @('--build-arg', "$($Script:RuntimeBuildArg)=$($Script:RuntimeVersion)")
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

# --- TUI Dashboard Build ------------------------------------------------------

# Invoke-TUIBuild compiles the Go-based TUI dashboard. Optional — silently
# skips when Go toolchain is missing or tui/ directory is absent.
function Invoke-TUIBuild {
    $tuiDir = Join-Path $ProjectRoot 'tui'
    $goMod = Join-Path $tuiDir 'go.mod'

    if (-not (Test-Path $tuiDir) -or -not (Test-Path $goMod)) {
        Write-LogInfo "TUI source not found at $tuiDir — skipping TUI build."
        return
    }

    Write-LogStep 'Building TUI dashboard'

    if (-not (Test-GoInstalled)) {
        Write-LogWarn 'Go toolchain not available.'
        # The prebuilt-binary offer that used to be here fetched
        # releases/latest, and this repository publishes no releases -- so it
        # could only fail, after asking the user to wait for it.
        Write-LogInfo "The TUI is built from source; install Go 1.24+ and re-run 'scripts\claude-docker.ps1 build-tui' later."
        if (Read-Confirmation -Question 'Install Go automatically now?' -Default 'y') {
            if (-not (Install-Prerequisite -Tool 'go')) {
                Write-LogWarn 'Failed to install Go. Skipping TUI build.'
                return
            }
            if (-not (Test-GoInstalled)) {
                Write-LogWarn 'Go install did not complete. Skipping TUI build.'
                return
            }
        }
        else {
            return
        }
    }

    Write-LogInfo 'Compiling claude-docker-tui (this may take up to a minute)...'
    Push-Location $tuiDir
    try {
        # Resolve module dependencies first
        & go mod download 2>&1 | Select-Object -Last 3

        # Version stamp from git
        $version = 'dev'
        try {
            $gitVer = & git -C $ProjectRoot rev-parse --short HEAD 2>$null
            if ($gitVer) { $version = $gitVer }
        } catch {}

        & go build -ldflags "-X main.version=$version" -o claude-docker-tui.exe . 2>&1 | Select-Object -Last 5

        $binary = Join-Path $tuiDir 'claude-docker-tui.exe'
        if (Test-Path $binary) {
            $size = [math]::Round((Get-Item $binary).Length / 1MB, 1)
            Write-LogSuccess "TUI dashboard built: tui\claude-docker-tui.exe (${size}MB)"
            Write-LogInfo 'Launch with: scripts\claude-docker.ps1 tui'
        }
        else {
            Write-LogWarn 'TUI binary not found after build. Check output above for errors.'
        }
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

            # Remove worktree placeholders from .env and move the declared
            # mode back to shared. Leaving ISOLATION_MODE=worktree behind
            # would make the next run refuse to start, since the paths that
            # mode requires have just been deleted.
            $envFile = Join-Path $ProjectRoot '.env'
            if (Test-Path $envFile) {
                $content = [System.IO.File]::ReadAllText($envFile)
                $content = $content -replace '(?m)^# ==== Tier B:.*\r?\n', ''
                $content = $content -replace '(?m)^# \(populated after.*\r?\n', ''
                # Over the same range New-EnvFile wrote, not the literals A and
                # B: a 4-account install used to leave PROJECT_DIR_C= and
                # PROJECT_DIR_D= behind.
                for ($j = 1; $j -le $Script:NumAccounts; $j++) {
                    $u = Get-AccountLetterUpper -Index $j
                    $content = $content -replace "(?m)^PROJECT_DIR_${u}=.*\r?\n", ''
                    $content = $content -replace "(?m)^CONTAINER_PROJECT_DIR_${u}=.*\r?\n", ''
                }
                Write-EnvContent -Path $envFile -Content $content
                Set-EnvValue -Path $envFile -Key 'ISOLATION_MODE' -Value 'shared'
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

    # Driven by NumAccounts, matching the placeholders New-EnvFile writes.
    # This used to prompt for exactly two branches and write back exactly
    # PROJECT_DIR_A and PROJECT_DIR_B, so a Tier B install with more than two
    # accounts left the rest empty. setup-worktrees.ps1 already takes a
    # [string[]]; only the caller was fixed at two.
    $branches = @()
    $letters = @()
    for ($i = 1; $i -le $Script:NumAccounts; $i++) {
        $lower = Get-AccountLetter -Index $i
        $upper = Get-AccountLetterUpper -Index $i
        $letters += $lower
        $branches += (Read-Input -Question "Branch name for Container $upper" -Default "worktree-$lower")
    }

    Write-LogInfo 'Creating worktrees...'
    # One invocation with the whole array: setup-worktrees.ps1 derives each
    # worktree's letter from the branch's position, so splitting the call
    # would restart the numbering at "a".
    & "$PSScriptRoot\setup-worktrees.ps1" -RepoDir $Script:SourceDir -Branches $branches

    $envFile = Join-Path $ProjectRoot '.env'
    $base = $Script:SourceDir.TrimEnd('\', '/')
    Write-LogSuccess 'Worktrees created:'
    for ($i = 0; $i -lt $letters.Count; $i++) {
        $lower = $letters[$i]
        $upper = $lower.ToUpperInvariant()
        $worktree = "$base-$lower"
        # Forward slashes for Docker.
        Set-EnvValue -Path $envFile -Key "PROJECT_DIR_$upper" `
            -Value (ConvertTo-ForwardSlash -Path $worktree)
        Write-LogInfo "  ${upper}: $worktree (branch: $($branches[$i]))"
    }
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

    # Skip entirely for non-Node projects so Python/Go/Rust/etc. users do
    # not see a misleading "npm install skipped or failed" warning on every
    # container and do not pay the npm registry round-trip for nothing.
    $pkgJson = Join-Path $Script:SourceDir 'package.json'
    if (-not (Test-Path $pkgJson -PathType Leaf)) {
        Write-LogInfo "No package.json at $($Script:SourceDir) — skipping npm install."
        return
    }

    # Service names use the selected runtime's registry servicePrefix
    # (claude-a, codex-a, gemini-a, ...) so npm install targets the right
    # containers (see #273).
    $servicePrefix = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Script:Runtime -Field 'servicePrefix'
    $services = @()
    for ($i = 1; $i -le $Script:NumAccounts; $i++) {
        $services += "$servicePrefix-$(Get-AccountLetter -Index $i)"
    }

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

    # The primary service name and the runtime binary are resolved from the
    # registry (claude-a/claude, codex-a/codex, gemini-a/gemini — see #273).
    $servicePrefix = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Script:Runtime -Field 'servicePrefix'
    $runtimeBinary = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $Script:Runtime -Field 'binary'
    $primarySvc = "$servicePrefix-a"

    # Check container is running
    $psOutput = Invoke-Compose -ProjectRoot $ProjectRoot ps --format '{{.Name}}' 2>$null
    if ($psOutput -match $primarySvc) {
        Write-LogSuccess "Container $primarySvc is running"
    }
    else {
        Write-LogError "Container $primarySvc is not running"
        Write-LogInfo "Check logs: docker compose logs $primarySvc"
        return
    }

    # Check the runtime CLI is available
    $version = Invoke-Compose -ProjectRoot $ProjectRoot exec -T $primarySvc $runtimeBinary --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-LogSuccess "$runtimeBinary is available ($version)"
    }
    else {
        Write-LogWarn "Could not verify $runtimeBinary (container may still be starting)"
    }

    # Check auth status (Path A: OAuth login required; Path B: API key validates)
    $null = Invoke-Compose -ProjectRoot $ProjectRoot exec -T $primarySvc $runtimeBinary auth status 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-LogSuccess 'Authentication verified'
    }
    else {
        Write-LogWarn 'Authentication not verified (may need browser login or API key check)'
    }

    # Verify GitHub independently in every running service. A missing or
    # mismatched login remains non-blocking but is rendered explicitly.
    for ($i = 1; $i -le $Script:NumAccounts; $i++) {
        $letter = Get-AccountLetter -Index $i
        $upper = Get-AccountLetterUpper -Index $i
        $svc = "$servicePrefix-$letter"
        if (-not (Get-ContainerId -ProjectRoot $ProjectRoot -Service $svc)) { continue }

        $output = @(Invoke-Compose -ProjectRoot $ProjectRoot exec -T $svc gh api user --jq .login 2>$null)
        $ghExit = $LASTEXITCODE
        $actual = ($output -join '').Trim()
        if ($ghExit -ne 0 -or -not $actual) {
            Write-LogWarn "${svc}: GitHub authentication is not configured"
            continue
        }
        if ($Script:GhAuthMode -eq 'per-account') {
            $expected = $Script:GhUsers[$i - 1]
            if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
                Write-LogWarn "${svc}: GitHub login mismatch (actual: $actual, expected: $expected)"
                continue
            }
        }
        Write-LogSuccess "${svc}: GitHub login verified ($actual)"
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

    # Advertise TUI dashboard when the binary is present (built locally or
    # downloaded as a prebuilt release).
    $tuiBinary = Join-Path $ProjectRoot 'tui\claude-docker-tui.exe'
    if (Test-Path $tuiBinary) {
        Write-Host '  # Interactive multi-account dashboard (recommended)' -ForegroundColor Cyan
        Write-Host '  .\scripts\claude-docker.ps1 tui'
        Write-Host ''
    }

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

    # Echo the exact compose invocation so users can reproduce it manually
    # without re-deriving the -f file list.
    $composeArgs = Get-ComposeArgs -ProjectRoot $ProjectRoot
    $composeCmd = 'docker compose ' + ($composeArgs -join ' ') + ' up -d'
    Write-Host 'Compose command for this setup:' -ForegroundColor White
    Write-Host "  $composeCmd" -ForegroundColor Green
    Write-Host ''
}

# --- Main ---------------------------------------------------------------------

if ($env:CLAUDE_DOCKER_INSTALL_LIBRARY_ONLY -eq '1') {
    return
}

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
$totalSteps = 9  # prereqs, env, dirs, build, tui-build, auth, start, deps, verify
if ($Script:Tier -eq 'B') { $totalSteps++ }
Initialize-StepCounter -Total $totalSteps

# Show configuration summary
Write-Host ''
Write-Host 'Configuration Summary:' -ForegroundColor White
Write-Host "  Platform:        Windows"
Write-Host "  Authentication:  Path $($Script:AuthPath)"
Write-Host "  Source sharing:  Tier $($Script:Tier)"
Write-Host "  Project:         $($Script:SourceDir)"
Write-Host "  $($Script:RuntimeDisplayName) version:  $(if ($Script:RuntimeVersion) { $Script:RuntimeVersion } else { 'latest' })"
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
Invoke-TUIBuild
Invoke-AuthSetup
Invoke-WorktreeSetup
# After Invoke-WorktreeSetup, so a Tier B .env has its PROJECT_DIR_* populated
# before the generator validates the mode it declares.
Invoke-ComposeGeneration
Start-Containers
Install-Dependencies
Invoke-Verification
Show-Summary
