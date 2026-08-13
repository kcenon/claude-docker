#Requires -Version 5.1
<#
.SYNOPSIS
    Generate docker-compose files for N accounts.
.DESCRIPTION
    Reads NUM_ACCOUNTS and IMAGE_TAG from .env (or environment) and writes:
      docker-compose.yml          Base config (Tier A: shared source)
      docker-compose.worktree.yml Tier B override (per-account worktrees)
      docker-compose.isolated.yml Isolated override (per-account clones)
      docker-compose.linux.yml    Linux UID/GID override
.EXAMPLE
    .\scripts\generate-compose.ps1
    .\scripts\generate-compose.ps1 -NumAccounts 4
#>
[CmdletBinding()]
param(
    [int]$NumAccounts = 0,
    [string]$ImageTag = ''
)

$ErrorActionPreference = 'Stop'

# Platform guard: PowerShell 7 runs on Linux and macOS, but this Windows port
# can persist Windows host paths into compose files that the bash lifecycle
# then reads as Unix paths. Refuse before reading configuration or writing any
# compose file.
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.OS -and $PSVersionTable.OS -notlike '*Windows*') {
    Write-Error "generate-compose.ps1 is Windows-only. Use ./scripts/generate-compose.sh on macOS or Linux."
    exit 1
}

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent $ScriptDir

Import-Module (Join-Path $ScriptDir 'ClaudeDocker.psm1') -Force
. (Join-Path $ScriptDir 'lib' 'index.ps1')

# --- Read configuration -------------------------------------------------------

$envFile = Join-Path $ProjectRoot '.env'
$envData = @{}
if (Test-Path $envFile) {
    $envData = Read-EnvFile -Path $envFile
}

# Resolve a configuration value the way the bash generator does: a value already
# present in the caller's environment wins over the .env entry, which wins over
# the built-in default. parse_env.sh states that rule for load_env_file, and
# generate-compose.sh inherits it for every value it reads.
function Resolve-EnvOrDefault([string]$Key, [string]$Default) {
    $val = [Environment]::GetEnvironmentVariable($Key)
    if (-not [string]::IsNullOrEmpty($val)) { return $val }
    if ($envData.ContainsKey($Key) -and -not [string]::IsNullOrEmpty($envData[$Key])) {
        return $envData[$Key]
    }
    return $Default
}

# NUM_ACCOUNTS and IMAGE_TAG are also exposed as parameters, so an explicit
# argument outranks that chain. Until #315 these two skipped the environment
# step entirely and consulted .env alone, so NUM_ACCOUNTS=5 in the environment
# produced two services here while generate-compose.sh produced five.
if ($NumAccounts -eq 0) {
    $fromEnv = Resolve-EnvOrDefault 'NUM_ACCOUNTS' ''
    if ([string]::IsNullOrEmpty($fromEnv)) {
        $NumAccounts = 2
    }
    else {
        $parsedNumAccounts = 0
        if ($fromEnv -notmatch '^\d+$' -or
            -not [int]::TryParse([string]$fromEnv, [ref]$parsedNumAccounts)) {
            Write-Error "NUM_ACCOUNTS must be an integer between 1 and 702 (got: $fromEnv)"
            exit 1
        }
        $NumAccounts = $parsedNumAccounts
    }
}

if ([string]::IsNullOrEmpty($ImageTag)) {
    $ImageTag = Resolve-EnvOrDefault 'IMAGE_TAG' ''
    if ([string]::IsNullOrEmpty($ImageTag)) {
        # Fall back to the repo-root VERSION file — single source of truth
        # shared with install.ps1 and the "Bumping the Base Image" README
        # procedure. Final fallback is 'latest' if VERSION is absent.
        $versionFile = Join-Path $ProjectRoot 'VERSION'
        if (Test-Path $versionFile) {
            $ImageTag = (Get-Content $versionFile -TotalCount 1).Trim()
        }
        if ([string]::IsNullOrEmpty($ImageTag)) {
            $ImageTag = 'latest'
        }
    }
}

if ($NumAccounts -lt 1 -or $NumAccounts -gt 702) {
    Write-Error "NUM_ACCOUNTS must be an integer between 1 and 702 (got: $NumAccounts)"
    exit 1
}

$AgentRuntime = Get-AgentRuntime -ProjectRoot $ProjectRoot
$ServicePrefix = Get-ServicePrefix -ProjectRoot $ProjectRoot
$PrimaryService = Get-PrimaryService -ProjectRoot $ProjectRoot

# Runtime registry bundle. Every per-runtime value the generator emits is
# resolved once here from runtimes.json, so the loops below are pure variable
# substitution with no `if ($AgentRuntime -eq 'codex')` branching. The bash
# generator (generate-compose.sh) builds the same bundle.
function Get-RtField([string]$Field) {
    return Get-RuntimeField -ProjectRoot $ProjectRoot -Runtime $AgentRuntime -Field $Field
}
$RtBuildArg            = Get-RtField 'buildArg'
$RtStateDir            = Get-RtField 'stateDir'
$RtHostConfigMount     = Get-RtField 'hostConfigMount'
$RtContainerConfigMount = Get-RtField 'containerConfigMount'
$RtApiKeyPrefix        = Get-RtField 'apiKeyVarPrefix'
$RtSdkApiKeyVar        = Get-RtField 'sdkApiKeyVar'
$RtConfigDirEnv        = Get-RtField 'configDirEnv'
# Value the configDirEnv variable carries — decoupled from containerConfigMount
# (issue #280). Equal to containerConfigMount for runtimes whose config-dir env
# var IS the config directory (claude, codex); the parent path for runtimes
# (gemini) whose CLI appends its own subdirectory.
$RtConfigDirEnvValue   = Get-RtField 'configDirEnvValue'
$RtConfigSourceEnv     = Get-RtField 'configSourceEnv'
# Whether this runtime needs the separate agents/skills compose volume.
# Only codex binds it; claude obtains skills via its host config mount and
# gemini via its own config mount, so neither needs the extra volume.
$RtMountsAgentsSkills  = Get-RtField 'mountsAgentsSkills'
# Host-side config directory basename (e.g. .claude, .codex) — the host
# mount whose container target is <hostConfigMount>. Derived from the
# container config mount basename, which the registry keeps in sync.
$RtHostConfigBasename  = '.' + ($RtContainerConfigMount -split '\.')[-1]

# Container resource envelope (override via .env or host env). Defaults
# reproduce the historical hardcoded values so existing installs see no
# behavior change after regenerating.
$CpuLimit       = Resolve-EnvOrDefault 'CONTAINER_CPU_LIMIT' '2'
$CpuReservation = Resolve-EnvOrDefault 'CONTAINER_CPU_RESERVATION' '1'
$MemLimit       = Resolve-EnvOrDefault 'CONTAINER_MEM_LIMIT' '4G'
$MemReservation = Resolve-EnvOrDefault 'CONTAINER_MEM_RESERVATION' '2G'

# GitHub authentication is shared by default for backward compatibility.
# Validate per-account mappings before opening any output file so failures do
# not leave partially regenerated compose files behind.
$GhAuthMode = (Resolve-EnvOrDefault 'GH_AUTH_MODE' 'shared').ToLowerInvariant()
if ($GhAuthMode -notin @('shared', 'per-account')) {
    Write-Error "GH_AUTH_MODE must be shared or per-account (got: $GhAuthMode)"
    exit 1
}
if ($GhAuthMode -eq 'per-account') {
    for ($i = 1; $i -le $NumAccounts; $i++) {
        $upper = Get-AccountLetterUpper -Index $i
        foreach ($key in @("GH_USER_${upper}", "GH_TOKEN_${upper}")) {
            if ([string]::IsNullOrEmpty((Resolve-EnvOrDefault $key ''))) {
                Write-Error "$key is required when GH_AUTH_MODE=per-account"
                exit 1
            }
        }
    }
}

# Isolation mode declares the workspace trust boundary. Validated here, next to
# GH_AUTH_MODE and for the same reason: an unusable value must be rejected
# before the first output file is opened, so a failure cannot leave a partially
# regenerated set behind.
#
# All four files are still generated in every mode. The mode decides which
# ones a caller composes together (Get-ComposeArgs), not which ones exist, so
# `compose-freshness` keeps comparing the same tracked set.
#
# -AccountCount makes the per-account workspace check cover every account, not
# just the first: the compose builder only needs to know the mode is usable,
# but a file written here with an unset path for account C would fail at `up`
# instead of now.
try {
    $IsolationMode = Get-SupportedIsolationMode -ProjectRoot $ProjectRoot -AccountCount $NumAccounts
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

Write-UnusedWorkspacePathWarning -ProjectRoot $ProjectRoot -Mode $IsolationMode

# Thin wrappers around the shared helpers in lib/index.ps1 so legacy call
# sites below keep working without rewriting each loop. Both helpers accept
# indices 1..702 and throw out-of-range otherwise.
function ConvertTo-Letter([int]$Index) {
    return Get-AccountLetter -Index $Index
}

function ConvertTo-UpperLetter([int]$Index) {
    return Get-AccountLetterUpper -Index $Index
}

# --- Shared emitters ----------------------------------------------------------

function Get-AccountVolumeLines {
    <#
    .SYNOPSIS
    Return the complete volume list for one account service, indented for a
    `volumes:` block.
    .DESCRIPTION
    Mirrors emit_account_volumes in generate-compose.sh. All three outputs that
    carry volumes come through here. The base config and the worktree overlay
    differ only in where the project comes from and where it lands; the
    isolated overlay additionally drops every shared host-home mount. Producing
    all of them from one function is what keeps the common mounts identical,
    and that matters more than it used to: both overlays REPLACE this list
    rather than appending to it, so a mount missing here is missing from the
    resolved service.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('shared', 'worktree', 'isolated')][string]$Mode,
        [Parameter(Mandatory)][string]$Letter,
        [Parameter(Mandatory)][string]$ProjectSource,
        [Parameter(Mandatory)][string]$ProjectTarget
    )

    $lines = @("      - ${ProjectSource}:${ProjectTarget}")

    # Per-account runtime state stays a host bind mount in every mode. It is
    # under $HOME, but it is not a *shared* surface: each account has its own
    # directory, so account A still cannot reach account B's state. Moving it
    # into a named volume would satisfy the letter of "no host home mounts"
    # while blinding the TUI, which discovers accounts by scanning
    # $HOME/<stateDir>/account-* on the host (tui/internal/config/state.go).
    $lines += "      - `${HOME}/${RtStateDir}/account-${Letter}:${RtContainerConfigMount}"

    # The remaining host-home mounts ARE shared surfaces: the read-only runtime
    # config tree, the agents/skills tree and the shared gh config resolve to
    # the same host path for every account. An isolated account receives none
    # of them (issue #335, stage 3). The runtime tolerates their absence --
    # bootstrap-claude.sh returns early when the config source is missing -- so
    # the container still starts, with no shared hooks, skills, commands,
    # statusline or CLAUDE.md. Restoring that through an allowlisted
    # per-account import is stage 4; see docs/ISOLATION.md.
    if ($Mode -ne 'isolated') {
        $lines += "      - `${HOME}/${RtHostConfigBasename}:${RtHostConfigMount}:ro"
        # The agents/skills volume is bound only for runtimes whose registry
        # entry sets mountsAgentsSkills (currently codex).
        if ($RtMountsAgentsSkills -eq $true) {
            $lines += '      - ${AGENTS_SKILLS_DIR:-${HOME}/.agents/skills}:/home/node/.agents/skills:ro'
        }
        if ($GhAuthMode -eq 'shared') {
            $lines += '      - ${GH_CONFIG_DIR:-${HOME}/.config/gh}:/home/node/.config/gh:ro'
        }
    }

    $lines += "      - node_modules_${Letter}:${ProjectTarget}/node_modules"
    return $lines
}

# --- Generate docker-compose.yml ---------------------------------------------

function New-BaseCompose {
    $outFile = Join-Path $ProjectRoot 'docker-compose.yml'
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine('# docker-compose.yml — Base config (Tier A: shared source)')
    [void]$sb.AppendLine('# Generated by scripts/generate-compose — do not edit manually.')
    [void]$sb.AppendLine('# Regenerate: scripts/generate-compose.sh OR scripts/generate-compose.ps1')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('services:')

    for ($i = 1; $i -le $NumAccounts; $i++) {
        $letter = ConvertTo-Letter $i
        $upper  = ConvertTo-UpperLetter $i
        $svc    = "$ServicePrefix-$letter"

        [void]$sb.AppendLine("  ${svc}:")

        if ($i -eq 1) {
            [void]$sb.AppendLine('    build:')
            [void]$sb.AppendLine('      context: .')
            [void]$sb.AppendLine('      args:')
            [void]$sb.AppendLine("        ${RtBuildArg}: `${${RtBuildArg}:-}")
        }

        [void]$sb.AppendLine("    image: claude-code-base:`${IMAGE_TAG:-$ImageTag}")

        if ($i -gt 1) {
            [void]$sb.AppendLine('    depends_on:')
            [void]$sb.AppendLine("      - $PrimaryService")
        }

        [void]$sb.AppendLine('    working_dir: ${CONTAINER_PROJECT_DIR:-/project}')
        # Emit UID/GID rationale into the generated yaml so users reading
        # the committed file see why the user line falls back to 1000:1000.
        # The bash generator emits the same four lines verbatim.
        [void]$sb.AppendLine("    # Match the host user's UID/GID so bind-mounted paths")
        [void]$sb.AppendLine("    # (`${HOME}/${RtStateDir}/account-*) stay writable from")
        [void]$sb.AppendLine('    # inside the container. Falls back to 1000:1000 (the')
        [void]$sb.AppendLine('    # upstream node:20-slim default) when UID/GID are unset.')
        [void]$sb.AppendLine('    user: "${UID:-1000}:${GID:-1000}"')
        [void]$sb.AppendLine('    stdin_open: true')
        [void]$sb.AppendLine('    tty: true')
        [void]$sb.AppendLine('    volumes:')
        foreach ($volumeLine in (Get-AccountVolumeLines -Mode 'shared' -Letter $letter `
                    -ProjectSource '${PROJECT_DIR}' `
                    -ProjectTarget '${CONTAINER_PROJECT_DIR:-/project}')) {
            [void]$sb.AppendLine($volumeLine)
        }
        [void]$sb.AppendLine('    environment:')
        [void]$sb.AppendLine('      - TERM=xterm-256color')
        [void]$sb.AppendLine('      - TZ=${TZ:-UTC}')
        # When the container runs as the host UID instead of node(1000),
        # the passwd entry for that UID is missing, so $HOME defaults to
        # /. Pinning HOME keeps runtime state, ~/.config, etc. resolvable.
        [void]$sb.AppendLine('      - HOME=/home/node')
        # AGENT_RUNTIME is now always emitted (previously codex-only).
        # The entrypoint defaults to claude when unset, so emitting it
        # for claude too is functionally inert and keeps the env block
        # uniform across runtimes.
        [void]$sb.AppendLine("      - AGENT_RUNTIME=${AgentRuntime}")
        [void]$sb.AppendLine("      - ${RtConfigDirEnv}=${RtConfigDirEnvValue}")
        [void]$sb.AppendLine("      - ${RtConfigSourceEnv}=`${${RtConfigSourceEnv}:-}")
        # CLAUDE_NORMALIZE_CRLF is a claude-only env var (read directly by
        # the entrypoint, no codex equivalent). The registry has no field
        # for it, so this one line stays gated on the runtime id.
        if ($AgentRuntime -eq 'claude') {
            [void]$sb.AppendLine('      - CLAUDE_NORMALIZE_CRLF=${CLAUDE_NORMALIZE_CRLF:-}')
        }
        [void]$sb.AppendLine('      - NODE_OPTIONS=--max-old-space-size=4096')
        # Only emit provider API keys when a per-account key is set at
        # generate time. Emitting an empty key makes SDKs prefer the blank env
        # var over persisted credentials in the mounted state dir.
        $keyVarName = "${RtApiKeyPrefix}${upper}"
        $keyValue = [Environment]::GetEnvironmentVariable($keyVarName)
        if ([string]::IsNullOrEmpty($keyValue) -and $envData.ContainsKey($keyVarName)) {
            $keyValue = $envData[$keyVarName]
        }
        if (-not [string]::IsNullOrEmpty($keyValue)) {
            [void]$sb.AppendLine("      - ${RtSdkApiKeyVar}=`${${keyVarName}}")
        }
        if ($GhAuthMode -eq 'per-account') {
            $ghUserVar = "GH_USER_${upper}"
            $ghTokenVar = "GH_TOKEN_${upper}"
            $gitNameVar = "GIT_USER_NAME_${upper}"
            $gitEmailVar = "GIT_USER_EMAIL_${upper}"
            [void]$sb.AppendLine('      - GH_AUTH_MODE=per-account')
            [void]$sb.AppendLine("      - GH_USER=`${${ghUserVar}}")
            [void]$sb.AppendLine("      - GH_TOKEN=`${${ghTokenVar}}")
            [void]$sb.AppendLine("      - GIT_USER_NAME=`${${gitNameVar}:-`${GIT_USER_NAME:-}}")
            [void]$sb.AppendLine("      - GIT_USER_EMAIL=`${${gitEmailVar}:-`${GIT_USER_EMAIL:-}}")
        }
        else {
            [void]$sb.AppendLine('      - GH_TOKEN=${GH_TOKEN:-}')
            [void]$sb.AppendLine('      - GIT_USER_NAME=${GIT_USER_NAME:-}')
            [void]$sb.AppendLine('      - GIT_USER_EMAIL=${GIT_USER_EMAIL:-}')
        }
        [void]$sb.AppendLine('    deploy:')
        [void]$sb.AppendLine('      resources:')
        [void]$sb.AppendLine('        limits:')
        [void]$sb.AppendLine("          cpus: `"$CpuLimit`"")
        [void]$sb.AppendLine("          memory: $MemLimit")
        [void]$sb.AppendLine('        reservations:')
        [void]$sb.AppendLine("          cpus: `"$CpuReservation`"")
        [void]$sb.AppendLine("          memory: $MemReservation")
        [void]$sb.AppendLine('    command: ["sleep", "infinity"]')

        if ($i -lt $NumAccounts) {
            [void]$sb.AppendLine('')
        }
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('volumes:')
    for ($i = 1; $i -le $NumAccounts; $i++) {
        $letter = ConvertTo-Letter $i
        [void]$sb.AppendLine("  node_modules_${letter}:")
    }

    Write-EnvContent -Path $outFile -Content $sb.ToString()
    Write-LogInfo "Generated: $outFile ($NumAccounts services)"
}

# --- Generate docker-compose.worktree.yml ------------------------------------

function New-WorktreeCompose {
    $outFile = Join-Path $ProjectRoot 'docker-compose.worktree.yml'
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine('# docker-compose.worktree.yml')
    [void]$sb.AppendLine('# Generated by scripts/generate-compose — do not edit manually.')
    [void]$sb.AppendLine('# Usage: docker compose -f docker-compose.yml -f docker-compose.worktree.yml up')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# Every volume list below carries the !override merge tag, so it REPLACES the')
    [void]$sb.AppendLine('# base list instead of extending it. Compose merges volumes by container')
    [void]$sb.AppendLine('# target, and /project-<letter> is a different target from the base /project,')
    [void]$sb.AppendLine('# so without the tag the shared ${PROJECT_DIR} mount survived alongside the')
    [void]$sb.AppendLine('# worktree and stayed writable from inside the container (issue #335).')
    [void]$sb.AppendLine('# Requires a Compose release that supports !override (Docker Compose v2.24.4+).')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# Worktrees are a concurrency tier, not a security boundary: the accounts')
    [void]$sb.AppendLine('# still share one git object store. See docs/ISOLATION.md.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('services:')

    for ($i = 1; $i -le $NumAccounts; $i++) {
        $letter = ConvertTo-Letter $i
        $upper  = ConvertTo-UpperLetter $i
        $svc    = "$ServicePrefix-$letter"

        [void]$sb.AppendLine("  ${svc}:")
        [void]$sb.AppendLine("    working_dir: `${CONTAINER_PROJECT_DIR_${upper}:-/project-$letter}")
        [void]$sb.AppendLine('    volumes: !override')
        foreach ($volumeLine in (Get-AccountVolumeLines -Mode 'worktree' -Letter $letter `
                    -ProjectSource "`${PROJECT_DIR_${upper}}" `
                    -ProjectTarget "`${CONTAINER_PROJECT_DIR_${upper}:-/project-$letter}")) {
            [void]$sb.AppendLine($volumeLine)
        }

        if ($i -lt $NumAccounts) {
            [void]$sb.AppendLine('')
        }
    }

    Write-EnvContent -Path $outFile -Content $sb.ToString()
    Write-LogInfo "Generated: $outFile ($NumAccounts services)"
}

# --- Generate docker-compose.isolated.yml ------------------------------------

function New-IsolatedCompose {
    $outFile = Join-Path $ProjectRoot 'docker-compose.isolated.yml'
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine('# docker-compose.isolated.yml')
    [void]$sb.AppendLine('# Generated by scripts/generate-compose — do not edit manually.')
    [void]$sb.AppendLine('# Usage: docker compose -f docker-compose.yml -f docker-compose.isolated.yml up')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# Each account mounts its own independent clone — separate working tree AND')
    [void]$sb.AppendLine('# separate git metadata, created by scripts/setup-isolated.sh. Unlike a')
    [void]$sb.AppendLine('# worktree, nothing is shared: there is no common object store to read other')
    [void]$sb.AppendLine('# branches from or rewrite refs in.')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# The volume lists carry !override so they REPLACE the base list. Compose')
    [void]$sb.AppendLine('# merges volumes by container target, so without the tag the shared')
    [void]$sb.AppendLine('# ${PROJECT_DIR} mount would survive alongside the clone (issue #335).')
    [void]$sb.AppendLine('# Requires a Compose release that supports !override (Docker Compose v2.24.4+).')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# Shared host-home mounts are absent by design: no read-only host config')
    [void]$sb.AppendLine('# tree, no agents/skills tree, no shared gh config. An isolated account')
    [void]$sb.AppendLine('# therefore has no shared hooks, skills, commands, statusline or CLAUDE.md.')
    [void]$sb.AppendLine('# Credential environment variables and per-account networks are NOT yet')
    [void]$sb.AppendLine('# scoped — that is stage 4. See docs/ISOLATION.md.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('services:')

    for ($i = 1; $i -le $NumAccounts; $i++) {
        $letter = ConvertTo-Letter $i
        $upper  = ConvertTo-UpperLetter $i
        $svc    = "$ServicePrefix-$letter"

        [void]$sb.AppendLine("  ${svc}:")
        [void]$sb.AppendLine("    working_dir: `${CONTAINER_ISOLATED_DIR_${upper}:-/workspace-$letter}")
        [void]$sb.AppendLine('    volumes: !override')
        foreach ($volumeLine in (Get-AccountVolumeLines -Mode 'isolated' -Letter $letter `
                    -ProjectSource "`${ISOLATED_WORKSPACE_${upper}}" `
                    -ProjectTarget "`${CONTAINER_ISOLATED_DIR_${upper}:-/workspace-$letter}")) {
            [void]$sb.AppendLine($volumeLine)
        }

        if ($i -lt $NumAccounts) {
            [void]$sb.AppendLine('')
        }
    }

    Write-EnvContent -Path $outFile -Content $sb.ToString()
    Write-LogInfo "Generated: $outFile ($NumAccounts services)"
}

# --- Generate docker-compose.linux.yml ----------------------------------------

function New-LinuxCompose {
    $outFile = Join-Path $ProjectRoot 'docker-compose.linux.yml'
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine('# docker-compose.linux.yml')
    [void]$sb.AppendLine('# Generated by scripts/generate-compose — do not edit manually.')
    [void]$sb.AppendLine('# Usage: docker compose -f docker-compose.yml -f docker-compose.linux.yml up')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('services:')

    for ($i = 1; $i -le $NumAccounts; $i++) {
        $letter = ConvertTo-Letter $i
        $svc    = "$ServicePrefix-$letter"

        [void]$sb.AppendLine("  ${svc}:")
        [void]$sb.AppendLine('    user: "${UID}:${GID}"')
        [void]$sb.AppendLine('    environment:')
        [void]$sb.AppendLine('      - HOME=/home/node')

        if ($i -lt $NumAccounts) {
            [void]$sb.AppendLine('')
        }
    }

    Write-EnvContent -Path $outFile -Content $sb.ToString()
    Write-LogInfo "Generated: $outFile ($NumAccounts services)"
}

# --- Main ---------------------------------------------------------------------

Write-LogInfo "Generating compose files for $NumAccounts account(s)..."
New-BaseCompose
New-WorktreeCompose
New-IsolatedCompose
New-LinuxCompose
Write-LogSuccess 'Done.'
