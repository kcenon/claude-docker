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
}

# --- Account Helpers ---------------------------------------------------------

function Get-NumAccounts {
    <#
    .SYNOPSIS
    Read NUM_ACCOUNTS from .env (default: 2).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $envFile = Join-Path $ProjectRoot '.env'
    if (Test-Path $envFile) {
        $envData = Read-EnvFile -Path $envFile
        $n = $envData['NUM_ACCOUNTS']
        if ($n -and $n -match '^\d+$') { return [int]$n }
    }
    return 2
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
    indexing (claude-aa, claude-zz, ...).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $n = Get-NumAccounts -ProjectRoot $ProjectRoot
    $names = @()
    for ($i = 1; $i -le $n; $i++) {
        $names += "claude-$(ConvertTo-AccountLetter -Index $i)"
    }
    return $names
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

    # Worktree override: check if PROJECT_DIR_A is set in .env
    $envFile = Join-Path $ProjectRoot '.env'
    if (Test-Path $envFile) {
        $envData = Read-EnvFile -Path $envFile
        $pdirA = $envData['PROJECT_DIR_A']
        $wtFile = Join-Path $ProjectRoot 'docker-compose.worktree.yml'
        if ($pdirA -and (Test-Path $wtFile)) {
            $args_ += @('-f', $wtFile)
        }
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
    'Test-Command', 'ConvertTo-ForwardSlash',
    # Accounts
    'Get-NumAccounts', 'Get-ServiceNames', 'ConvertTo-AccountLetter',
    # .env
    'Read-EnvFile', 'Get-EnvValue', 'Write-EnvContent', 'Set-EnvValue',
    # Docker Compose
    'Get-ComposeArgs', 'Invoke-Compose', 'Get-ContainerId',
    # Directory
    'Get-FriendlySize', 'Get-DirectorySize'
)
