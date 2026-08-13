# ClaudeDocker.psm1 — Shared PowerShell module for claude-docker scripts
# Provides logging, prompts, Docker Compose helpers, and utility functions.
# Compatible with PowerShell 5.1+ and PowerShell 7+.

#Requires -Version 5.1

# --- Logging -----------------------------------------------------------------

# NOTE: The previous `$env:HOME = $env:USERPROFILE` workaround was removed.
# install.ps1 now writes HOME explicitly to .env at install time, so
# docker compose reads the correct value from .env without needing a runtime
# assignment on the caller's PowerShell session.

function Write-LogInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host '[INFO] ' -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}

function Write-LogSuccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host '[OK] ' -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-LogWarn {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host '[WARN] ' -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-LogError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host '[ERROR] ' -ForegroundColor Red -NoNewline
    Write-Host $Message
}

# Script-scoped step counter state
$Script:StepCurrent = 0
$Script:StepTotal = 0

function Initialize-StepCounter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Total)
    $Script:StepCurrent = 0
    $Script:StepTotal = $Total
}

function Write-LogStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    $Script:StepCurrent++
    Write-Host ''
    Write-Host "[$($Script:StepCurrent)/$($Script:StepTotal)] $Message" -ForegroundColor White
}

# --- Interactive Prompts -----------------------------------------------------

function Read-Selection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][string[]]$Options
    )

    Write-Host ''
    Write-Host $Question -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  $($i + 1)) " -ForegroundColor White -NoNewline
        Write-Host $Options[$i]
    }

    while ($true) {
        $choice = Read-Host "> Select [1-$($Options.Count)]"
        if ($choice -match '^\d+$') {
            $idx = [int]$choice
            if ($idx -ge 1 -and $idx -le $Options.Count) {
                return $Options[$idx - 1]
            }
        }
        Write-Host "  Invalid choice. Please enter 1-$($Options.Count)." -ForegroundColor Red
    }
}

function Read-Input {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Question,
        [string]$Default = ''
    )

    if ($Default) {
        $value = Read-Host "$Question [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        return $value
    }

    while ($true) {
        $value = Read-Host $Question
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        Write-Host '  This field is required.' -ForegroundColor Red
    }
}

function Read-Secret {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Question)

    $secure = Read-Host $Question -AsSecureString

    # Convert SecureString to plain text
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return ConvertFrom-SecureString -SecureString $secure -AsPlainText
    }
    else {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Read-Confirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Question,
        [string]$Default = 'n'
    )

    $hint = if ($Default -eq 'y') { 'Y/n' } else { 'y/N' }
    $answer = Read-Host "$Question [$hint]"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
    return $answer -match '^[Yy]'
}

# --- Utility Functions -------------------------------------------------------

function Test-Command {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function ConvertTo-ForwardSlash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return $Path -replace '\\', '/'
}

# --- .env File I/O -----------------------------------------------------------

function ConvertFrom-EnvLine {
    <#
    .SYNOPSIS
    Internal helper that parses a single KEY=VALUE line with the same
    normalization semantics as scripts/lib/parse_env.sh: strips CR,
    inline comments preceded by whitespace, trailing whitespace, and
    unwraps surrounding single or double quotes.
    Returns a two-element array @($key, $value) or $null if the line
    is a comment, blank, or has no '='.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $trimmed = $Line -replace "`r$", ''
    $trimmed = $trimmed -replace '^\s+', ''
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { return $null }

    $eqIdx = $trimmed.IndexOf('=')
    if ($eqIdx -lt 1) { return $null }

    $key = $trimmed.Substring(0, $eqIdx) -replace '\s+$', ''
    $value = $trimmed.Substring($eqIdx + 1)

    $value = $value -replace '\s+#.*$', ''
    $value = $value -replace '\s+$', ''
    if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") {
        $value = $matches[1]
    }
    return @($key, $value)
}

function Read-EnvFile {
    <#
    .SYNOPSIS
    Parse a .env file into a hashtable. Skips comments and blank lines.
    Handles CRLF, inline comments, quoted values, and trailing whitespace.
    Later duplicate keys win, matching POSIX shell env semantics.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $result = @{}
    if (-not (Test-Path $Path)) { return $result }

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $parsed = ConvertFrom-EnvLine -Line $line
        if ($null -ne $parsed) {
            $result[$parsed[0]] = $parsed[1]
        }
    }
    return $result
}

function Get-EnvValue {
    <#
    .SYNOPSIS
    Read a single key from a .env file, returning $null when the file is
    missing or the key is absent. Uses the same normalization rules as
    Read-EnvFile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not (Test-Path $Path)) { return $null }
    $last = $null
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $parsed = ConvertFrom-EnvLine -Line $line
        if ($null -ne $parsed -and $parsed[0] -eq $Key) {
            $last = $parsed[1]
        }
    }
    return $last
}

function Write-EnvContent {
    <#
    .SYNOPSIS
    Write string content to a file using BOM-free UTF-8 (docker compose compatible).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Protect-EnvFile {
    <#
    .SYNOPSIS
    Restrict a secret-bearing env file to the current Windows user.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        -not (Test-Path -LiteralPath $Path)) {
        return
    }
    & icacls $Path /inheritance:r /grant:r "${env:USERNAME}:(M)" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restrict permissions on $Path"
    }
}

function Set-EnvValue {
    <#
    .SYNOPSIS
    Update or append a key=value pair in a .env file. Values containing
    whitespace or '#' are wrapped in double quotes so a round-trip through
    Get-EnvValue is lossless.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    # Quote values that contain whitespace, '#', or look pre-quoted so the
    # value round-trips through Read-EnvFile / Get-EnvValue unchanged.
    $formatted = $Value
    if ($Value -match '[\s#]' -or $Value -match '^[''"]') {
        $escaped = $Value -replace '"', '\"'
        $formatted = '"{0}"' -f $escaped
    }

    $line = "$Key=$formatted"

    if (-not (Test-Path $Path)) {
        Write-EnvContent -Path $Path -Content "$line`n"
        Protect-EnvFile -Path $Path
        return
    }

    # Scan-and-replace the first matching KEY= line; leave others intact so
    # values containing regex metacharacters or '$n' backreferences are
    # handled literally.
    $keyPattern = "^\s*$([regex]::Escape($Key))="
    $lines = [System.IO.File]::ReadAllLines($Path)
    $replaced = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $replaced -and $lines[$i] -match $keyPattern) {
            $lines[$i] = $line
            $replaced = $true
        }
    }
    if (-not $replaced) {
        $lines += $line
    }

    Write-EnvContent -Path $Path -Content (($lines -join "`n") + "`n")
    Protect-EnvFile -Path $Path
}

# --- Account Helpers ---------------------------------------------------------

function Get-NumAccounts {
    <#
    .SYNOPSIS
    Resolve NUM_ACCOUNTS: environment, then .env, then 2.
    .DESCRIPTION
    Mirrors get_num_accounts in scripts/claude-docker and the order both
    compose generators use (#317). Get-AgentRuntime below already resolved
    AGENT_RUNTIME this way; NUM_ACCOUNTS was the one value that did not.

    The first source holding a non-empty value wins even if that value is
    invalid, so an exported NUM_ACCOUNTS=abc does not fall through to .env.
    An unusable value emits a warning and yields the default rather than an
    error, because the callers enumerate services for display.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $n = [Environment]::GetEnvironmentVariable('NUM_ACCOUNTS')
    if ([string]::IsNullOrEmpty($n)) {
        $envFile = Join-Path $ProjectRoot '.env'
        if (Test-Path $envFile) {
            $envData = Read-EnvFile -Path $envFile
            $n = $envData['NUM_ACCOUNTS']
        }
    }
    if ([string]::IsNullOrEmpty($n)) { return 2 }

    $parsedNumAccounts = 0
    if ($n -notmatch '^\d+$' -or
        -not [int]::TryParse([string]$n, [ref]$parsedNumAccounts) -or
        $parsedNumAccounts -lt 1 -or $parsedNumAccounts -gt 702) {
        Write-Warning "NUM_ACCOUNTS must be an integer between 1 and 702 (got: $n); using default 2."
        return 2
    }
    return $parsedNumAccounts
}

# --- Runtime registry --------------------------------------------------------
# Runtime-specific values are resolved from the JSON registry at
# tui/internal/config/runtimes.json — the cross-language single source of
# truth (see #267). The registry lives under tui/ so Go's go:embed can reach
# it; this module finds it relative to $ProjectRoot. The parsed registry is
# cached in a module-scoped variable so ConvertFrom-Json runs only once.

$script:RuntimeRegistryCache = $null

function Get-RuntimeRegistry {
    <#
    .SYNOPSIS
    Parse and cache runtimes.json from the project tree. Returns the parsed
    PSCustomObject. Parses once per module load.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    if ($null -ne $script:RuntimeRegistryCache) {
        return $script:RuntimeRegistryCache
    }
    $registryPath = Join-Path $ProjectRoot 'tui/internal/config/runtimes.json'
    if (-not (Test-Path $registryPath)) {
        throw "Runtime registry not found: $registryPath"
    }
    $script:RuntimeRegistryCache = Get-Content -Raw -Path $registryPath | ConvertFrom-Json
    return $script:RuntimeRegistryCache
}

function Get-RuntimeField {
    <#
    .SYNOPSIS
    Return the value of a single field for the named runtime from the
    registry. Returns $null if the runtime or field is absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Runtime,
        [Parameter(Mandatory)][string]$Field
    )

    $registry = Get-RuntimeRegistry -ProjectRoot $ProjectRoot
    $entry = $registry.runtimes.$Runtime
    if ($null -eq $entry) {
        return $null
    }
    return $entry.$Field
}

function Get-RuntimeList {
    <#
    .SYNOPSIS
    Return the registered runtime names from the registry, sorted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $registry = Get-RuntimeRegistry -ProjectRoot $ProjectRoot
    return @($registry.runtimes.PSObject.Properties.Name | Sort-Object)
}

function Get-AgentRuntime {
    <#
    .SYNOPSIS
    Resolve the selected agent runtime. Defaults to claude for compatibility.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $runtime = [Environment]::GetEnvironmentVariable('AGENT_RUNTIME')
    if ([string]::IsNullOrWhiteSpace($runtime)) {
        $envFile = Join-Path $ProjectRoot '.env'
        if (Test-Path $envFile) {
            $runtime = Get-EnvValue -Path $envFile -Key 'AGENT_RUNTIME'
        }
    }
    if ([string]::IsNullOrWhiteSpace($runtime)) {
        $runtime = 'claude'
    }
    $runtime = $runtime.ToLowerInvariant()
    # Validate against the registry rather than a hardcoded allowlist.
    $known = Get-RuntimeList -ProjectRoot $ProjectRoot
    if ($runtime -notin $known) {
        throw "AGENT_RUNTIME is not a known runtime (got: $runtime)"
    }
    return $runtime
}

function Get-ServicePrefix {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $runtime = Get-AgentRuntime -ProjectRoot $ProjectRoot
    return Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $runtime -Field 'servicePrefix'
}

function Get-PrimaryService {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    return "$(Get-ServicePrefix -ProjectRoot $ProjectRoot)-a"
}

function Get-AgentStateRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $runtime = Get-AgentRuntime -ProjectRoot $ProjectRoot
    $dirName = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $runtime -Field 'stateDir'
    return Join-Path $env:USERPROFILE $dirName
}

function ConvertTo-AccountLetter {
    <#
    .SYNOPSIS
    Convert a 1-based index to Excel-style lowercase letters (a, z, aa, az,
    ba, zz). Values 1-26 are bit-identical to the previous single-letter
    scheme.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Index)

    if ($Index -lt 1) { throw "Index must be 1 or greater (got: $Index)" }
    [int]$n = $Index
    $builder = ''
    while ($n -gt 0) {
        [int]$rem = ($n - 1) % 26
        $builder = [char]([int](97 + $rem)) + $builder
        [int]$n = [math]::Floor(($n - 1) / 26)
    }
    return $builder
}

function Get-ServiceNames {
    <#
    .SYNOPSIS
    Return an array of service names (claude-a, claude-b, ...) based on
    NUM_ACCOUNTS. Supports more than 26 via Excel-style double-letter
    indexing (claude-aa, claude-zz, ...). When AGENT_RUNTIME=codex, the
    service prefix becomes codex.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $n = Get-NumAccounts -ProjectRoot $ProjectRoot
    $prefix = Get-ServicePrefix -ProjectRoot $ProjectRoot
    $names = @()
    for ($i = 1; $i -le $n; $i++) {
        $names += "$prefix-$(ConvertTo-AccountLetter -Index $i)"
    }
    return $names
}

# --- Isolation mode ----------------------------------------------------------
#
# PowerShell port of scripts/lib/isolation.sh. The two must agree on
# resolution order, accepted names, and which per-account paths each mode
# requires, because a Windows user and a Linux user configuring the same
# repository have to get the same trust boundary.
# tests/test_isolation_modes.sh asserts that.

function Test-IsolationModeKnown {
    <#
    .SYNOPSIS
    Return $true when Mode is one of shared, worktree, isolated.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Mode)

    # -cin, not -in: PowerShell comparison operators ignore case by default,
    # which would make this predicate accept 'Shared' while the bash `case`
    # and the Go switch both reject it. Normalizing is the caller's job
    # (Get-IsolationMode lowercases first); this answers whether a value is
    # already one of the contract names.
    return $Mode -cin @('shared', 'worktree', 'isolated')
}

function Get-IsolationModeSummary {
    <#
    .SYNOPSIS
    One-line description of the trust boundary a mode provides.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Mode)

    switch ($Mode) {
        'shared' {
            return 'all accounts share one read-write project mount; appropriate only for mutually trusted accounts'
        }
        'worktree' {
            return 'each account mounts only its own worktree; git metadata stays shared, so this is a concurrency tier, not a security boundary'
        }
        'isolated' {
            return 'each account gets an independent clone with its own git metadata and state; no shared project mount and no shared host configuration'
        }
        default {
            throw "Unknown isolation mode: $Mode"
        }
    }
}

function Get-IsolationAccountVariable {
    <#
    .SYNOPSIS
    Name of the per-account workspace variable a mode reads, or '' for none.
    .DESCRIPTION
    Mirrors isolation_mode_account_var in lib/isolation.sh. One table so
    validation, warnings and the generators cannot disagree about which
    variable belongs to which mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Upper
    )

    switch ($Mode) {
        'worktree' { return "PROJECT_DIR_$Upper" }
        'isolated' { return "ISOLATED_WORKSPACE_$Upper" }
        default { return '' }
    }
}

function Get-IsolationSetupHint {
    <#
    .SYNOPSIS
    One-line "run this to create them" hint for a mode's workspaces.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Mode)

    switch ($Mode) {
        'worktree' { return 'Create the worktrees with scripts\setup-worktrees.ps1, which prints the paths to add.' }
        'isolated' { return 'Create the clones with scripts\setup-isolated.ps1, which prints the paths to add.' }
        default { return '' }
    }
}

function Get-IsolationValue {
    <#
    .SYNOPSIS
    Return a configuration key using the environment-then-.env order.
    .DESCRIPTION
    Module-internal (not exported). Mirrors _isolation_lookup in
    lib/isolation.sh. The legacy worktree inference, the per-account
    validation and the unused-path warning all need it, and a caller may have
    the value in the environment rather than only on disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Key
    )

    $value = [Environment]::GetEnvironmentVariable($Key)
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }

    $envFile = Join-Path $ProjectRoot '.env'
    if (-not (Test-Path $envFile)) { return '' }
    return (Get-EnvValue -Path $envFile -Key $Key)
}

function Get-IsolationMode {
    <#
    .SYNOPSIS
    Resolve the configured isolation mode.
    .DESCRIPTION
    Resolution order mirrors resolve_isolation_mode in lib/isolation.sh:
      1. ISOLATION_MODE in the caller's environment.
      2. ISOLATION_MODE in .env.
      3. Legacy inference: a .env declaring PROJECT_DIR_A resolves to
         worktree, because that is the variable Tier B installations set and
         the one Get-ComposeArgs used to key the overlay off.
      4. shared.
    An unrecognized value throws rather than degrading to shared.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $mode = [Environment]::GetEnvironmentVariable('ISOLATION_MODE')
    $envFile = Join-Path $ProjectRoot '.env'

    if ([string]::IsNullOrWhiteSpace($mode) -and (Test-Path $envFile)) {
        $mode = Get-EnvValue -Path $envFile -Key 'ISOLATION_MODE'
    }
    if ([string]::IsNullOrWhiteSpace($mode) -and
        -not [string]::IsNullOrWhiteSpace((Get-IsolationValue -ProjectRoot $ProjectRoot -Key 'PROJECT_DIR_A'))) {
        $mode = 'worktree'
    }

    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'shared' }
    $mode = $mode.ToLowerInvariant()

    if (-not (Test-IsolationModeKnown -Mode $mode)) {
        throw "ISOLATION_MODE must be shared, worktree or isolated (got: $mode)"
    }
    return $mode
}

function Get-SupportedIsolationMode {
    <#
    .SYNOPSIS
    Get-IsolationMode, then verify the mode's per-account workspace paths.
    .DESCRIPTION
    Callers that write files or start containers use this. Callers that only
    display configuration use Get-IsolationMode.

    AccountCount defaults to 1: overlay selection only needs to know the mode
    is usable at all, and account A is the one every installation has. The
    compose generator passes NUM_ACCOUNTS so a path missing for account C is
    caught before the first output file is opened. A mode whose paths are
    unset would otherwise reach Compose as an empty bind source, which fails
    later and less legibly than it does here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [ValidateRange(1, 702)][int]$AccountCount = 1
    )

    $mode = Get-IsolationMode -ProjectRoot $ProjectRoot

    for ($i = 1; $i -le $AccountCount; $i++) {
        # Uppercasing the Excel-style letter is correct for both 'a' -> 'A'
        # and 'aa' -> 'AA', so no separate uppercase converter is needed.
        $upper = (ConvertTo-AccountLetter -Index $i).ToUpperInvariant()
        $var = Get-IsolationAccountVariable -Mode $mode -Upper $upper
        # shared consumes no per-account path; nothing to check for any account.
        if ([string]::IsNullOrEmpty($var)) { break }

        if ([string]::IsNullOrWhiteSpace((Get-IsolationValue -ProjectRoot $ProjectRoot -Key $var))) {
            throw ("$var is required when ISOLATION_MODE=$mode. " + (Get-IsolationSetupHint -Mode $mode))
        }
    }

    return $mode
}

function Write-UnusedWorkspacePathWarning {
    <#
    .SYNOPSIS
    Warn about per-account workspace paths the active mode ignores.
    .DESCRIPTION
    Both families are checked, because both can be present at once: a user who
    tried isolated, went back to worktree, and left the clone paths in .env
    should be told the clones are now inert. Reports a surprise; decides
    nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Mode
    )

    if ($Mode -ne 'worktree' -and
        -not [string]::IsNullOrWhiteSpace((Get-IsolationValue -ProjectRoot $ProjectRoot -Key 'PROJECT_DIR_A'))) {
        Write-LogWarn "PROJECT_DIR_A is configured, but ISOLATION_MODE=$Mode ignores per-account worktree paths."
        if ($Mode -eq 'shared') {
            Write-LogWarn "Every account uses PROJECT_DIR. Set ISOLATION_MODE=worktree to mount the worktrees."
        }
        else {
            Write-LogWarn "Set ISOLATION_MODE=worktree to mount the worktrees."
        }
    }

    if ($Mode -ne 'isolated' -and
        -not [string]::IsNullOrWhiteSpace((Get-IsolationValue -ProjectRoot $ProjectRoot -Key 'ISOLATED_WORKSPACE_A'))) {
        Write-LogWarn "ISOLATED_WORKSPACE_A is configured, but ISOLATION_MODE=$Mode ignores per-account clone paths."
        Write-LogWarn "Set ISOLATION_MODE=isolated to mount the independent clones."
    }
}

# --- Docker Compose Helpers --------------------------------------------------

function Get-ComposeArgs {
    <#
    .SYNOPSIS
    Build the array of docker compose file arguments for the current configuration.
    Windows never uses docker-compose.linux.yml.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $args_ = @('-f', (Join-Path $ProjectRoot 'docker-compose.yml'))

    # Overlay selection follows the resolved isolation mode rather than the
    # presence of PROJECT_DIR_A. Get-IsolationMode still infers worktree from
    # that variable when ISOLATION_MODE is unset, so Tier B installations
    # predating the key keep the same overlay; an explicit mode now wins.
    $mode = Get-SupportedIsolationMode -ProjectRoot $ProjectRoot
    $overlay = switch ($mode) {
        'worktree' { 'docker-compose.worktree.yml' }
        'isolated' { 'docker-compose.isolated.yml' }
        default { '' }
    }

    if (-not [string]::IsNullOrEmpty($overlay)) {
        $overlayPath = Join-Path $ProjectRoot $overlay
        # A missing overlay would silently leave every account on the shared
        # /project mount -- the exact fall back the mode is chosen to avoid.
        if (-not (Test-Path $overlayPath)) {
            throw ("ISOLATION_MODE=$mode but $overlay is missing. " +
                   "Regenerate it with scripts\generate-compose.ps1 before starting containers.")
        }
        $args_ += @('-f', $overlayPath)
    }

    return $args_
}

function Invoke-Compose {
    <#
    .SYNOPSIS
    Execute docker compose with the correct file arguments.
    Replaces bash's eval "$compose_cmd ..." pattern with safe array splatting.
    .NOTES
    CAUTION: This is an advanced function (CmdletBinding + Parameter attributes).
    PowerShell intercepts short flags that match common parameters before they
    reach ValueFromRemainingArguments. Use long flags for Docker options:
      --detach (not -d, which maps to -Debug)
      --verbose (not -v, which maps to -Verbose)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(ValueFromRemainingArguments)][string[]]$ComposeArgs
    )

    $baseArgs = @(Get-ComposeArgs -ProjectRoot $ProjectRoot)
    $allArgs = $baseArgs + $ComposeArgs

    & docker compose @allArgs
}

function Get-ContainerId {
    <#
    .SYNOPSIS
    Get the Docker container ID for a compose service.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Service
    )

    $baseArgs = @(Get-ComposeArgs -ProjectRoot $ProjectRoot)
    $result = & docker compose @baseArgs ps -q $Service 2>$null
    return $result
}

# --- Directory Size Helper ---------------------------------------------------

function Get-FriendlySize {
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$Bytes)

    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DirectorySize {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return 0 }
    $size = (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum).Sum
    if ($null -eq $size) { return 0 }
    return [long]$size
}

# --- Exports -----------------------------------------------------------------

Export-ModuleMember -Function @(
    # Logging
    'Write-LogInfo', 'Write-LogSuccess', 'Write-LogWarn', 'Write-LogError',
    'Initialize-StepCounter', 'Write-LogStep',
    # Prompts
    'Read-Selection', 'Read-Input', 'Read-Secret', 'Read-Confirmation',
    # Utilities
    'Test-Command', 'ConvertTo-ForwardSlash', 'Protect-EnvFile',
    # Accounts
    'Get-NumAccounts', 'Get-AgentRuntime', 'Get-ServicePrefix',
    'Get-PrimaryService', 'Get-AgentStateRoot', 'Get-ServiceNames',
    'ConvertTo-AccountLetter',
    # Runtime registry
    'Get-RuntimeField', 'Get-RuntimeList',
    # Isolation mode
    'Test-IsolationModeKnown', 'Get-IsolationModeSummary', 'Get-IsolationMode',
    'Get-IsolationAccountVariable', 'Get-IsolationSetupHint',
    'Get-SupportedIsolationMode', 'Write-UnusedWorkspacePathWarning',
    # .env
    'Read-EnvFile', 'Get-EnvValue', 'Write-EnvContent', 'Set-EnvValue',
    # Docker Compose
    'Get-ComposeArgs', 'Invoke-Compose', 'Get-ContainerId',
    # Directory
    'Get-FriendlySize', 'Get-DirectorySize'
)
