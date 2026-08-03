#Requires -Version 5.1
<#
.SYNOPSIS
    Generate docker-compose files for N accounts.
.DESCRIPTION
    Reads NUM_ACCOUNTS and IMAGE_TAG from .env (or environment) and writes:
      docker-compose.yml          Base config (Tier A: shared source)
      docker-compose.worktree.yml Tier B override (per-account worktrees)
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

# Thin wrappers around the shared helpers in lib/index.ps1 so legacy call
# sites below keep working without rewriting each loop. Both helpers accept
# indices 1..702 and throw out-of-range otherwise.
function ConvertTo-Letter([int]$Index) {
    return Get-AccountLetter -Index $Index
}

function ConvertTo-UpperLetter([int]$Index) {
    return Get-AccountLetterUpper -Index $Index
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
        [void]$sb.AppendLine('      - ${PROJECT_DIR}:${CONTAINER_PROJECT_DIR:-/project}')
        [void]$sb.AppendLine("      - `${HOME}/${RtStateDir}/account-${letter}:${RtContainerConfigMount}")
        [void]$sb.AppendLine("      - `${HOME}/${RtHostConfigBasename}:${RtHostConfigMount}:ro")
        # The agents/skills volume is bound only for runtimes whose
        # registry entry sets mountsAgentsSkills (currently codex).
        if ($RtMountsAgentsSkills -eq $true) {
            [void]$sb.AppendLine('      - ${AGENTS_SKILLS_DIR:-${HOME}/.agents/skills}:/home/node/.agents/skills:ro')
        }
        [void]$sb.AppendLine('      - ${GH_CONFIG_DIR:-${HOME}/.config/gh}:/home/node/.config/gh:ro')
        [void]$sb.AppendLine("      - node_modules_${letter}:`${CONTAINER_PROJECT_DIR:-/project}/node_modules")
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
        [void]$sb.AppendLine('      - GH_TOKEN=${GH_TOKEN:-}')
        [void]$sb.AppendLine('      - GIT_USER_NAME=${GIT_USER_NAME:-}')
        [void]$sb.AppendLine('      - GIT_USER_EMAIL=${GIT_USER_EMAIL:-}')
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
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('services:')

    for ($i = 1; $i -le $NumAccounts; $i++) {
        $letter = ConvertTo-Letter $i
        $upper  = ConvertTo-UpperLetter $i
        $svc    = "$ServicePrefix-$letter"

        [void]$sb.AppendLine("  ${svc}:")
        [void]$sb.AppendLine("    working_dir: `${CONTAINER_PROJECT_DIR_${upper}:-/project-$letter}")
        [void]$sb.AppendLine('    volumes:')
        [void]$sb.AppendLine("      - `${PROJECT_DIR_${upper}}:`${CONTAINER_PROJECT_DIR_${upper}:-/project-$letter}")
        [void]$sb.AppendLine("      - node_modules_${letter}:`${CONTAINER_PROJECT_DIR_${upper}:-/project-$letter}/node_modules")

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
New-LinuxCompose
Write-LogSuccess 'Done.'
