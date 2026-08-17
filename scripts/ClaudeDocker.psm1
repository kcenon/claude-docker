# ClaudeDocker.psm1 — Shared PowerShell module for claude-docker scripts
# Provides logging, prompts, Docker Compose helpers, and utility functions.
# Requires PowerShell 7. Windows PowerShell 5.1 is not supported; see the
# Platform Support section of README.md and the decision recorded on #348.

#Requires -Version 7.0

# --- Shared account-index helpers --------------------------------------------
#
# lib/index.ps1 is the PowerShell side's single definition of the
# account-index rules, mirroring scripts/lib/index.sh. This module used to
# carry its own ConvertTo-AccountLetter instead, which guarded only the lower
# bound while Get-AccountLetter guards both -- so the same index produced a
# letter through one entry point and an error through the other (#356).
#
# Dot-sourced into module scope and re-exported below, so importing this
# module is enough; callers do not need to know the file exists.
. (Join-Path $PSScriptRoot 'lib' 'index.ps1')

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

function ConvertTo-ComparablePath {
    <#
    .SYNOPSIS
    Fold a path into a form two path strings can be compared with.
    .DESCRIPTION
    On Windows the same directory reaches this module in two spellings:
    `git worktree list --porcelain` emits forward slashes ("D:/Sources/x")
    while (Get-Location).Path always emits backslashes ("D:\Sources\x").
    Comparing those raw strings never matches, which is what let remove.ps1
    select the repository it was standing in for deletion (#342).

    Both separators fold to '/' and any trailing separator is dropped. The
    filesystem is not consulted, so a path that no longer exists still folds.
    Callers must pass absolute paths -- '..' segments are not resolved, and
    every producer here (git porcelain output, Get-Location) is absolute.

    Comparison by the caller is PowerShell's default case-insensitive one.
    That is right on Windows, the only platform these removers run on; on a
    case-sensitive filesystem it can only make two distinct worktrees look
    equal, which skips a removal rather than performing an extra one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    # ConvertTo-ForwardSlash rejects an empty string, and widening it would
    # relax a contract other callers rely on to catch a missing path.
    if ($Path -eq '') { return '' }

    $folded = ConvertTo-ForwardSlash -Path $Path
    # Trimming a root produces something that is not a path: "C:/" becomes
    # "C:" and "/" becomes "". No worktree is ever a root, so the only job
    # here is to leave one intact if it is passed.
    $trimmed = $folded.TrimEnd('/')
    if ($trimmed -eq '' -or $trimmed -match '^[A-Za-z]:$') { return $folded }
    return $trimmed
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

    # Unquote first, comment-strip second -- same rule as parse_env_value in
    # scripts/lib/parse_env.sh, and for the same reason (#356, row 9). With
    # the old order a # inside a quoted value started a comment, so
    # set_env_value wrote FOO="a # b" and this read back `"a`.
    $value = $value -replace '\s+$', ''
    if ($value -match '^"(.*)"(\s+#.*)?$' -or $value -match "^'(.*)'(\s+#.*)?$") {
        $value = $matches[1]
    }
    else {
        $value = $value -replace '\s+#.*$', ''
        $value = $value -replace '\s+$', ''
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

    $parsedNumAccounts = Get-NormalizedAccountCount -Value ([string]$n)
    if ($null -eq $parsedNumAccounts) {
        Write-Warning "NUM_ACCOUNTS must be an integer between 1 and $(Get-MaxAccountCount) (got: $n); using default 2."
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

function Get-AgentBinary {
    <#
    .SYNOPSIS
    The executable name to run inside the container for the active runtime.
    .DESCRIPTION
    Mirrors agent_binary in scripts/lib/runtime.sh, which reads the registry's
    `binary` field.

    Invoke-Update used to run Get-AgentRuntime -- the registry *key* -- as the
    command inside the container (#356, row 3). It works today only because
    key and binary are the same string for all three registered runtimes, so a
    runtime whose CLI is named differently from its key would exec something
    that does not exist. The bash wrapper has always used agent_binary here.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $runtime = Get-AgentRuntime -ProjectRoot $ProjectRoot
    return Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $runtime -Field 'binary'
}

function Get-AgentStateRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $runtime = Get-AgentRuntime -ProjectRoot $ProjectRoot
    $dirName = Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $runtime -Field 'stateDir'
    return Join-Path $env:USERPROFILE $dirName
}

# ConvertTo-AccountLetter lived here and is gone (#356). It was a second
# implementation of lib/index.ps1's Get-AccountLetter that guarded only the
# lower bound, so index 703 returned "aaa" through the module and threw
# through the library. Get-AccountLetter is re-exported from the dot-source at
# the top of this file; call that.

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
        $names += "$prefix-$(Get-AccountLetter -Index $i)"
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

function Test-IsolatedNetworkModeKnown {
    <#
    .SYNOPSIS
    Return $true when Mode is one of bridge, none.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Mode)

    # -cin for the same reason Test-IsolationModeKnown uses it: the bash `case`
    # is case-sensitive, so accepting 'Bridge' here would let a Windows user
    # configure a value a Linux user's generator rejects.
    return $Mode -cin @('bridge', 'none')
}

function Get-IsolatedNetworkModeSummary {
    <#
    .SYNOPSIS
    One-line description of the reachability a network policy provides.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Mode)

    switch ($Mode) {
        'bridge' {
            return 'each account is on its own bridge network; outbound access works, sibling discovery and direct connections do not'
        }
        'none' {
            return 'each account is detached from every network; no outbound agent, API or git access'
        }
        default {
            throw "Unknown isolated network mode: $Mode"
        }
    }
}

function Get-IsolatedNetworkMode {
    <#
    .SYNOPSIS
    Resolve the network policy the isolated mode applies.
    .DESCRIPTION
    Mirrors resolve_isolated_network_mode in lib/isolation.sh: environment,
    then .env, then bridge. No inference leg -- nothing predates this key, so
    an unset value means "never configured" rather than "configured the old
    way". An unrecognized value throws rather than falling back to bridge,
    because a typo that silently attaches every account to a network produces
    no other visible symptom.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $mode = Get-IsolationValue -ProjectRoot $ProjectRoot -Key 'ISOLATED_NETWORK_MODE'

    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'bridge' }
    $mode = $mode.ToLowerInvariant()

    if (-not (Test-IsolatedNetworkModeKnown -Mode $mode)) {
        throw "ISOLATED_NETWORK_MODE must be bridge or none (got: $mode)"
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
        # Validated in the body, not by [ValidateRange(1, 702)]: an attribute
        # binds before the body runs, so it cannot consult the shared bound
        # and has to re-spell it. That is the fifth copy #356 removed.
        [int]$AccountCount = 1
    )

    if ($null -eq (Get-NormalizedAccountCount -Value ([string]$AccountCount))) {
        throw "AccountCount must be between 1 and $(Get-MaxAccountCount) (got: $AccountCount)"
    }

    $mode = Get-IsolationMode -ProjectRoot $ProjectRoot

    for ($i = 1; $i -le $AccountCount; $i++) {
        # Uppercasing the Excel-style letter is correct for both 'a' -> 'A'
        # and 'aa' -> 'AA', so no separate uppercase converter is needed.
        $upper = (Get-AccountLetter -Index $i).ToUpperInvariant()
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

# --- Container Resource Envelope ---------------------------------------------
#
# Bash mirror: scripts/lib/resources.sh. The generated compose files carry the
# container memory cap and the Node old-space limit as two literals that have
# to agree; until issue #335 both were fixed values that happened to be equal,
# so V8 was allowed to grow its heap to the whole cgroup limit and the kernel
# reached the OOM killer before V8 reached the ceiling that would have made it
# collect garbage instead. The heap is therefore derived from the cap, and an
# explicitly configured heap is checked against it before any file is written.

# Smallest slice of the cap that must stay outside the Node heap. A floor
# rather than the whole rule: a percentage alone collapses to nothing on small
# caps, where the fixed costs (V8 itself, the runtime's node processes, git)
# do not shrink with the cap.
$script:NodeHeapMinHeadroomMib = 512

# Fraction of the cap reserved when that exceeds the floor, as a divisor.
# 25% is a convention, not a measurement -- see the note in
# scripts/lib/resources.sh, which this mirrors.
$script:NodeHeapHeadroomDivisor = 4

# Fractional digits kept when a byte value carries a decimal point. Three is
# 1 MiB of precision at GiB scale, and it is also what keeps the arithmetic
# inside [long] at the largest unit this accepts.
$script:ResourceFractionDigits = 3

function ConvertTo-MebibyteCount {
    <#
    .SYNOPSIS
    Convert a Docker byte value to a whole number of MiB.
    .DESCRIPTION
    The accepted syntax is the one Docker itself parses
    (go-units.RAMInBytes, reached through deploy.resources.limits.memory): a
    number with an optional k/m/g/t/p scale, an optional 'i', an optional 'b',
    and optional spaces, all case-insensitive -- 4G, 4g, 4GB, 4GiB, 4 g and
    4294967296 are the same value. Decimals are accepted for the same reason:
    1.5G is a working CONTAINER_MEM_LIMIT today, and this validator has no
    business rejecting a cap Docker would have taken.

    Returns $null when Value is not one of those, so the caller owns the
    diagnostic and can name the key the value came from.

    The result is floored, which is the conservative direction for every
    caller here: a cap reads as smaller than it is, never as larger.

    Arithmetic is [long]. A 4G cap is 4294967296 bytes, which overflows [int].
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $normalized = ($Value -replace '\s', '').ToLowerInvariant()
    if ([string]::IsNullOrEmpty($normalized)) { return $null }

    # Group 1 whole part, group 3 fractional digits, group 5 the scale letter
    # (empty for plain bytes, whether written as 4 or 4b).
    if ($normalized -notmatch '^([0-9]+)(\.([0-9]+))?(([kmgtp])i?b?|b)?$') { return $null }

    [long]$intPart = $Matches[1]
    # A group that did not participate is absent from $Matches rather than
    # present and empty, so both optional groups are read defensively. Reading
    # them directly would make an absent scale $null, which the switch below
    # would fall through, leaving the multiplier 0 and the whole value silently
    # wrong instead of rejected.
    $frac = if ($Matches.Contains(3)) { [string]$Matches[3] } else { '' }
    $scale = if ($Matches.Contains(5)) { [string]$Matches[5] } else { '' }

    [long]$mult = switch ($scale) {
        ''  { 1 }
        'k' { 1KB }
        'm' { 1MB }
        'g' { 1GB }
        't' { 1TB }
        'p' { 1PB }
    }

    [long]$bytes = $intPart * $mult
    if (-not [string]::IsNullOrEmpty($frac)) {
        if ($frac.Length -gt $script:ResourceFractionDigits) {
            $frac = $frac.Substring(0, $script:ResourceFractionDigits)
        }
        [long]$denominator = [math]::Pow(10, $frac.Length)
        # Floor, not a [long] cast: PowerShell rounds half to even on a cast,
        # so 1.5 would become 2 where the bash mirror truncates to 1.
        $bytes += [long][math]::Floor(([long]$frac * $mult) / $denominator)
    }

    return [long]([math]::Floor($bytes / 1MB))
}

function Get-NodeHeapHeadroomMib {
    <#
    .SYNOPSIS
    MiB that should stay outside the Node heap for a container capped at CapMib.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$CapMib)

    $headroom = [math]::Floor($CapMib / $script:NodeHeapHeadroomDivisor)
    if ($headroom -lt $script:NodeHeapMinHeadroomMib) {
        $headroom = $script:NodeHeapMinHeadroomMib
    }
    return [long]$headroom
}

function Resolve-NodeHeapMib {
    <#
    .SYNOPSIS
    Validated Node old-space limit, in MiB, for a container capped at MemLimit.
    .DESCRIPTION
    With ConfiguredHeapMb empty the value is derived from the cap; otherwise
    ConfiguredHeapMb is used as given. Either way the result is checked
    against the cap, and an unusable combination throws so the generator can
    refuse to open the first output file rather than write a stack that
    OOM-kills at run time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$MemLimit,
        [AllowEmptyString()][string]$ConfiguredHeapMb = ''
    )

    $capMib = ConvertTo-MebibyteCount -Value $MemLimit
    if ($null -eq $capMib) {
        throw "CONTAINER_MEM_LIMIT must be a byte value such as 4G, 4096m or 4294967296 (got: $MemLimit)"
    }

    # Checked before the heap so the advice below can always name a positive
    # ceiling to lower the heap to.
    if ($capMib -le $script:NodeHeapMinHeadroomMib) {
        throw ("CONTAINER_MEM_LIMIT=$MemLimit ($capMib MiB) leaves no room for a Node heap. " +
            "At least $($script:NodeHeapMinHeadroomMib) MiB of the cap must stay outside the heap, so the cap has to exceed that.")
    }

    if (-not [string]::IsNullOrEmpty($ConfiguredHeapMb)) {
        if ($ConfiguredHeapMb -notmatch '^[0-9]+$' -or [long]$ConfiguredHeapMb -eq 0) {
            throw "CONTAINER_NODE_HEAP_MB must be a positive whole number of MiB (got: $ConfiguredHeapMb)"
        }
        [long]$heap = $ConfiguredHeapMb
    }
    else {
        [long]$heap = $capMib - (Get-NodeHeapHeadroomMib -CapMib $capMib)
    }

    $headroom = $capMib - $heap
    if ($headroom -lt $script:NodeHeapMinHeadroomMib) {
        throw ("The Node heap limit does not leave enough of the container memory cap free. " +
            "CONTAINER_MEM_LIMIT=$MemLimit is $capMib MiB; a $heap MiB heap leaves $headroom MiB, " +
            "and at least $($script:NodeHeapMinHeadroomMib) MiB is required. " +
            "Set CONTAINER_NODE_HEAP_MB to at most $($capMib - $script:NodeHeapMinHeadroomMib), or raise CONTAINER_MEM_LIMIT.")
    }

    return $heap
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

# --- Worktree Selection -------------------------------------------------------

function Select-RemovableWorktree {
    <#
    .SYNOPSIS
    Given the worktree paths git reported and the tree the caller is standing
    in, return only the ones that are safe to remove.
    .DESCRIPTION
    remove.ps1 and cleanup.ps1 both walked `git worktree list --porcelain` and
    both excluded the current tree with a raw string comparison that cannot
    match on Windows (#342). The decision lives here so there is one copy to
    reason about, and so it can be exercised by a test without running either
    remover.

    Two independent guards, deliberately not one:

    1. The first porcelain entry is dropped unconditionally. git documents the
       main working tree as listed first, and it stays first even when the
       command runs from a linked worktree -- which is exactly the case where
       the caller's own path does not identify the repository at risk.
    2. Anything folding to the same path as -CurrentPath is dropped. This is
       the guard for the ordinary case, and the one the raw comparison lost.

    .PARAMETER WorktreePath
    Paths in the order `git worktree list --porcelain` reported them. Order
    carries meaning here; do not sort before calling.
    .PARAMETER CurrentPath
    The tree the caller is standing in, in any separator form.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][string[]]$WorktreePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentPath
    )

    $paths = @($WorktreePath | Where-Object { $_ })
    if ($paths.Count -le 1) { return @() }

    $current = ConvertTo-ComparablePath -Path $CurrentPath
    return @($paths |
        Select-Object -Skip 1 |
        Where-Object { (ConvertTo-ComparablePath -Path $_) -ne $current })
}

function Test-OwnedWorktreePath {
    <#
    .SYNOPSIS
    Report whether a worktree is one this installer created.
    .DESCRIPTION
    Not being the current tree is not the same as being ours. A user who runs
    `git worktree add ..\proj-hotfix` in the project repository has a worktree
    that the removers used to delete with --force, and then with a recursive
    delete when git declined.

    Ownership has exactly two sources, both written by this installer, and
    both are needed:

    1. PROJECT_DIR_<X> / ISOLATED_WORKSPACE_<X> in .env -- the paths
       setup-worktrees and setup-isolated record.
    2. The "<project>-<letter>" naming those scripts produce, for installs
       predating those keys and for the window in remove.ps1 where .env has
       already been deleted.

    Mirrors worktree_is_owned in scripts/lib/worktrees.sh. Matching is the
    case-insensitive default, which is correct on the only platform these
    scripts run on: there, two spellings that differ in case are one directory.
    .PARAMETER EnvData
    Parsed .env contents. Omit when .env is gone; source 2 still applies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProjectDir,
        [hashtable]$EnvData
    )

    $candidate = ConvertTo-ComparablePath -Path $Path

    if ($EnvData) {
        foreach ($key in $EnvData.Keys) {
            if ($key -notmatch '^(PROJECT_DIR|ISOLATED_WORKSPACE)_[A-Z]+$') { continue }
            if (-not $EnvData[$key]) { continue }
            if ((ConvertTo-ComparablePath -Path $EnvData[$key]) -eq $candidate) {
                return $true
            }
        }
    }

    if ($ProjectDir) {
        $prefix = ConvertTo-ComparablePath -Path $ProjectDir
        # StartsWith and a separate suffix test rather than one regex: a
        # project path containing regex metacharacters would otherwise widen
        # the pattern.
        if ($candidate.StartsWith("$prefix-", [System.StringComparison]::OrdinalIgnoreCase)) {
            $suffix = $candidate.Substring($prefix.Length + 1)
            # Two characters is exactly what the generator can emit: the
            # account count is capped at 702 and index 702 is "zz". A looser
            # [A-Za-z]+ would claim any sibling named after a word --
            # "<project>-clone", "<project>-hotfix" -- which are the
            # user-created worktrees this check exists to spare.
            if ($suffix -match '^[A-Za-z]{1,2}$') { return $true }
        }
    }

    return $false
}

# --- Cleanup Policy -----------------------------------------------------------

function Get-CleanupDecision {
    <#
    .SYNOPSIS
    Decide whether a destructive cleanup step may proceed.
    .DESCRIPTION
    cleanup.ps1 has two destructive steps and used to have two different
    policies for them: state-directory removal was gated on
    -Force / -SkipState / a prompt / a refusal on a non-interactive host, and
    backup removal simply ran. Both now route through this function, so the
    two cannot drift apart again, and the policy can be tested without a
    Windows host to run cleanup.ps1 on.

    Returns one of:
      remove  proceed without asking (-Force)
      skip    do nothing (-SkipState)
      refuse  abort; no answer is available and guessing would delete files
      ask     prompt the operator

    'refuse' rather than 'skip' on a non-interactive host is deliberate and
    mirrors cleanup.sh: a pipeline that meant to clean up and silently did
    not is its own failure, so the caller is told to pass a switch.
    .PARAMETER Interactive
    Whether a real console can answer. Passed in rather than detected here so
    the decision stays pure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Force,
        [Parameter(Mandatory)][bool]$Skip,
        [Parameter(Mandatory)][bool]$Interactive
    )

    if ($Force) { return 'remove' }
    if ($Skip) { return 'skip' }
    if (-not $Interactive) { return 'refuse' }
    return 'ask'
}

function Test-FileAgeExceedsDays {
    <#
    .SYNOPSIS
    Whether a file is older than -Days, using find(1)'s whole-day rule.
    .DESCRIPTION
    cleanup.sh selects backups with `find -mtime +N`, which truncates a
    file's age to whole days before comparing: a 7.5-day-old file reports 7,
    so `-mtime +7` does not match it. cleanup.ps1 compared against an exact
    `(Get-Date).AddDays(-N)` instant and did match it -- same flag, same
    value, opposite outcome.

    Truncation is the documented reading of "--backup-age-days N" and is what
    the existing bash fixture assumes, so PowerShell moves to bash rather
    than the other way round.
    .PARAMETER Now
    The reference instant. A parameter rather than Get-Date so a test can pin
    the comparison instead of racing the clock.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$LastWriteTime,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$Days
    )

    $ageDays = [math]::Floor(($Now - $LastWriteTime).TotalDays)
    return $ageDays -gt $Days
}

# --- Exports -----------------------------------------------------------------

Export-ModuleMember -Function @(
    # Logging
    'Write-LogInfo', 'Write-LogSuccess', 'Write-LogWarn', 'Write-LogError',
    'Initialize-StepCounter', 'Write-LogStep',
    # Prompts
    'Read-Selection', 'Read-Input', 'Read-Secret', 'Read-Confirmation',
    # Utilities
    'Test-Command', 'ConvertTo-ForwardSlash', 'ConvertTo-ComparablePath',
    'Protect-EnvFile',
    # Worktrees
    'Select-RemovableWorktree', 'Test-OwnedWorktreePath',
    # Cleanup policy
    'Get-CleanupDecision', 'Test-FileAgeExceedsDays',
    # Accounts
    'Get-NumAccounts', 'Get-AgentRuntime', 'Get-ServicePrefix',
    'Get-AgentBinary',
    'Get-PrimaryService', 'Get-AgentStateRoot', 'Get-ServiceNames',
    'Get-AccountLetter',
    'Get-AccountLetterUpper',
    'Get-NormalizedAccountCount',
    'Get-MaxAccountCount',
    # Runtime registry
    'Get-RuntimeField', 'Get-RuntimeList',
    # Isolation mode
    'Test-IsolationModeKnown', 'Get-IsolationModeSummary', 'Get-IsolationMode',
    'Get-IsolationAccountVariable', 'Get-IsolationSetupHint',
    'Get-SupportedIsolationMode', 'Write-UnusedWorkspacePathWarning',
    'Test-IsolatedNetworkModeKnown', 'Get-IsolatedNetworkModeSummary',
    'Get-IsolatedNetworkMode',
    # Container resource envelope
    'ConvertTo-MebibyteCount', 'Get-NodeHeapHeadroomMib', 'Resolve-NodeHeapMib',
    # .env
    'Read-EnvFile', 'Get-EnvValue', 'Write-EnvContent', 'Set-EnvValue',
    # Docker Compose
    'Get-ComposeArgs', 'Invoke-Compose', 'Get-ContainerId',
    # Directory
    'Get-FriendlySize', 'Get-DirectorySize'
)
