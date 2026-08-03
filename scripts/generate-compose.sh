#!/usr/bin/env bash
# generate-compose.sh — Generate docker-compose files for N accounts.
#
# Reads NUM_ACCOUNTS and IMAGE_TAG from .env (or environment) and writes:
#   docker-compose.yml          Base config (Tier A: shared source)
#   docker-compose.worktree.yml Tier B override (per-account worktrees)
#   docker-compose.linux.yml    Linux UID/GID override
#
# Usage:
#   scripts/generate-compose.sh              # Uses .env defaults
#   NUM_ACCOUNTS=4 scripts/generate-compose.sh  # Override via env
set -euo pipefail

# Platform guard: same rationale as install.sh - refuse to run on native
# Windows shells (Git Bash, MSYS, Cygwin), where this script fails twice over.
# The paths it bakes into the compose files are MSYS-flavored, and Windows `jq`
# writes stdout in text mode, so the runtime-registry reads come back with a
# trailing CR and a correctly-registered runtime is rejected as unknown. The
# guard sits ahead of the first registry read specifically so that misleading
# "AGENT_RUNTIME is not a known runtime" error is never reached (#306).
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "Error: generate-compose.sh is not supported on native Windows shells." >&2
        echo "Use: powershell -ExecutionPolicy Bypass -File scripts\\generate-compose.ps1" >&2
        exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/parse_env.sh
. "$SCRIPT_DIR/lib/parse_env.sh"
# shellcheck source=lib/index.sh
. "$SCRIPT_DIR/lib/index.sh"
# shellcheck source=lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"

# --- Read configuration -------------------------------------------------------

# Values already in the caller's environment win over .env entries.
load_env_file "$PROJECT_ROOT/.env"

NUM_ACCOUNTS="${NUM_ACCOUNTS:-2}"
# Validate before any registry lookup so unusable input always reaches this
# generator-owned diagnostic and cannot flow into arithmetic below.
RAW_NUM_ACCOUNTS="$NUM_ACCOUNTS"
if ! NUM_ACCOUNTS=$(normalize_account_count "$RAW_NUM_ACCOUNTS"); then
    echo "Error: NUM_ACCOUNTS must be an integer between 1 and 702 (got: $RAW_NUM_ACCOUNTS)" >&2
    exit 1
fi

AGENT_RUNTIME="$(agent_runtime)"
SERVICE_PREFIX="$(agent_service_prefix)"
PRIMARY_SERVICE="${SERVICE_PREFIX}-a"

# Runtime registry bundle. Every per-runtime value the generator emits is
# resolved once here from runtimes.json, so the loops below are pure variable
# substitution with no `if [[ == codex ]]` branching. Adding a runtime to the
# registry is then sufficient to make the generator emit correct compose.
RT_BUILD_ARG="$(runtime_field "$AGENT_RUNTIME" buildArg)"
RT_STATE_DIR="$(runtime_field "$AGENT_RUNTIME" stateDir)"
RT_HOST_CONFIG_MOUNT="$(runtime_field "$AGENT_RUNTIME" hostConfigMount)"
RT_CONTAINER_CONFIG_MOUNT="$(runtime_field "$AGENT_RUNTIME" containerConfigMount)"
RT_API_KEY_PREFIX="$(runtime_field "$AGENT_RUNTIME" apiKeyVarPrefix)"
RT_SDK_API_KEY_VAR="$(runtime_field "$AGENT_RUNTIME" sdkApiKeyVar)"
RT_CONFIG_DIR_ENV="$(runtime_field "$AGENT_RUNTIME" configDirEnv)"
# Value the configDirEnv variable carries — decoupled from containerConfigMount
# (issue #280). Equal to containerConfigMount for runtimes whose config-dir env
# var IS the config directory (claude, codex); the parent path for runtimes
# (gemini) whose CLI appends its own subdirectory.
RT_CONFIG_DIR_ENV_VALUE="$(runtime_field "$AGENT_RUNTIME" configDirEnvValue)"
RT_CONFIG_SOURCE_ENV="$(runtime_field "$AGENT_RUNTIME" configSourceEnv)"
# Whether this runtime needs the separate agents/skills compose volume.
# Only codex binds it; claude obtains skills via its host config mount and
# gemini via its own config mount, so neither needs the extra volume.
RT_MOUNTS_AGENTS_SKILLS="$(runtime_field "$AGENT_RUNTIME" mountsAgentsSkills)"
# Host-side config directory basename (e.g. .claude, .codex) — the host
# mount whose container target is <hostConfigMount>. Derived from the
# container config mount basename, which the registry keeps in sync.
RT_HOST_CONFIG_BASENAME=".${RT_CONTAINER_CONFIG_MOUNT##*.}"

# IMAGE_TAG defaults come from the repo-root VERSION file — single source of
# truth shared with install.sh and the "Bumping the Base Image" README
# procedure. Falls back to "latest" if VERSION is missing (e.g. the user is
# running the script from an older clone or a sparse checkout).
if [[ -z "${IMAGE_TAG:-}" ]]; then
    if [[ -f "$PROJECT_ROOT/VERSION" ]]; then
        IMAGE_TAG="$(head -n1 "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')"
    fi
    IMAGE_TAG="${IMAGE_TAG:-latest}"
fi

# Container resource envelope (override via .env or host env). Defaults
# reproduce the historical hardcoded values so existing installs see no
# behavior change after regenerating.
CPU_LIMIT="${CONTAINER_CPU_LIMIT:-2}"
CPU_RESERVATION="${CONTAINER_CPU_RESERVATION:-1}"
MEM_LIMIT="${CONTAINER_MEM_LIMIT:-4G}"
MEM_RESERVATION="${CONTAINER_MEM_RESERVATION:-2G}"

# index_to_letter and index_to_upper provided by scripts/lib/index.sh.

# --- Generate docker-compose.yml ---------------------------------------------

generate_base() {
    local outfile="$PROJECT_ROOT/docker-compose.yml"
    {
        echo "# docker-compose.yml — Base config (Tier A: shared source)"
        echo "# Generated by scripts/generate-compose — do not edit manually."
        echo "# Regenerate: scripts/generate-compose.sh OR scripts/generate-compose.ps1"
        echo ""
        echo "services:"

        for i in $(seq 1 "$NUM_ACCOUNTS"); do
            local letter
            letter=$(index_to_letter "$i")
            local upper
            upper=$(index_to_upper "$i")
            local svc="${SERVICE_PREFIX}-${letter}"

            echo "  ${svc}:"

            # Only the first service builds the image
            if [[ "$i" -eq 1 ]]; then
                echo "    build:"
                echo "      context: ."
                echo "      args:"
                echo "        ${RT_BUILD_ARG}: \${${RT_BUILD_ARG}:-}"
            fi

            echo "    image: claude-code-base:\${IMAGE_TAG:-${IMAGE_TAG}}"

            # All services after the first depend on the first account service
            # for build ordering.
            if [[ "$i" -gt 1 ]]; then
                echo "    depends_on:"
                echo "      - ${PRIMARY_SERVICE}"
            fi

            echo "    working_dir: \${CONTAINER_PROJECT_DIR:-/project}"
            echo "    # Match the host user's UID/GID so bind-mounted paths"
            echo "    # (\${HOME}/${RT_STATE_DIR}/account-*) stay writable from"
            echo "    # inside the container. Falls back to 1000:1000 (the"
            echo "    # upstream node:20-slim default) when UID/GID are unset."
            echo "    user: \"\${UID:-1000}:\${GID:-1000}\""
            echo "    stdin_open: true"
            echo "    tty: true"
            echo "    volumes:"
            echo "      - \${PROJECT_DIR}:\${CONTAINER_PROJECT_DIR:-/project}"
            echo "      - \${HOME}/${RT_STATE_DIR}/account-${letter}:${RT_CONTAINER_CONFIG_MOUNT}"
            echo "      - \${HOME}/${RT_HOST_CONFIG_BASENAME}:${RT_HOST_CONFIG_MOUNT}:ro"
            # The agents/skills volume is bound only for runtimes whose
            # registry entry sets mountsAgentsSkills (currently codex).
            if [[ "$RT_MOUNTS_AGENTS_SKILLS" == "true" ]]; then
                echo '      - ${AGENTS_SKILLS_DIR:-${HOME}/.agents/skills}:/home/node/.agents/skills:ro'
            fi
            echo "      - \${GH_CONFIG_DIR:-\${HOME}/.config/gh}:/home/node/.config/gh:ro"
            echo "      - node_modules_${letter}:\${CONTAINER_PROJECT_DIR:-/project}/node_modules"
            echo "    environment:"
            echo "      - TERM=xterm-256color"
            echo "      - TZ=\${TZ:-UTC}"
            # When the container runs as the host UID instead of node(1000),
            # the passwd entry for that UID is missing, so \$HOME defaults
            # to /. Pinning HOME keeps runtime state, ~/.config, etc.
            # resolvable.
            echo "      - HOME=/home/node"
            # AGENT_RUNTIME is now always emitted (previously codex-only).
            # The entrypoint defaults to claude when unset, so emitting it
            # for claude too is functionally inert and keeps the env block
            # uniform across runtimes.
            echo "      - AGENT_RUNTIME=${AGENT_RUNTIME}"
            echo "      - ${RT_CONFIG_DIR_ENV}=${RT_CONFIG_DIR_ENV_VALUE}"
            echo "      - ${RT_CONFIG_SOURCE_ENV}=\${${RT_CONFIG_SOURCE_ENV}:-}"
            # CLAUDE_NORMALIZE_CRLF is a claude-only env var (read directly by
            # the entrypoint, no codex equivalent). The registry has no field
            # for it, so this one line stays gated on the runtime id.
            if [[ "$AGENT_RUNTIME" == "claude" ]]; then
                echo "      - CLAUDE_NORMALIZE_CRLF=\${CLAUDE_NORMALIZE_CRLF:-}"
            fi
            echo "      - NODE_OPTIONS=--max-old-space-size=4096"
            # Only emit provider API keys when a per-account key is set at
            # generate time. Emitting an empty key makes SDKs prefer the
            # blank env var over persisted credentials.
            local key_var="${RT_API_KEY_PREFIX}${upper}"
            if [[ -n "${!key_var:-}" ]]; then
                echo "      - ${RT_SDK_API_KEY_VAR}=\${${key_var}}"
            fi
            echo "      - GH_TOKEN=\${GH_TOKEN:-}"
            echo "      - GIT_USER_NAME=\${GIT_USER_NAME:-}"
            echo "      - GIT_USER_EMAIL=\${GIT_USER_EMAIL:-}"
            echo "    deploy:"
            echo "      resources:"
            echo "        limits:"
            echo "          cpus: \"${CPU_LIMIT}\""
            echo "          memory: ${MEM_LIMIT}"
            echo "        reservations:"
            echo "          cpus: \"${CPU_RESERVATION}\""
            echo "          memory: ${MEM_RESERVATION}"
            echo "    command: [\"sleep\", \"infinity\"]"

            # Blank line between services (but not after the last one)
            if [[ "$i" -lt "$NUM_ACCOUNTS" ]]; then
                echo ""
            fi
        done

        echo ""
        echo "volumes:"
        for i in $(seq 1 "$NUM_ACCOUNTS"); do
            local letter
            letter=$(index_to_letter "$i")
            echo "  node_modules_${letter}:"
        done
    } > "$outfile"

    echo "Generated: $outfile ($NUM_ACCOUNTS services)"
}

# --- Generate docker-compose.worktree.yml ------------------------------------

generate_worktree() {
    local outfile="$PROJECT_ROOT/docker-compose.worktree.yml"
    {
        echo "# docker-compose.worktree.yml"
        echo "# Generated by scripts/generate-compose — do not edit manually."
        echo "# Usage: docker compose -f docker-compose.yml -f docker-compose.worktree.yml up"
        echo ""
        echo "services:"

        for i in $(seq 1 "$NUM_ACCOUNTS"); do
            local letter
            letter=$(index_to_letter "$i")
            local upper
            upper=$(index_to_upper "$i")
            local svc="${SERVICE_PREFIX}-${letter}"

            echo "  ${svc}:"
            echo "    working_dir: \${CONTAINER_PROJECT_DIR_${upper}:-/project-${letter}}"
            echo "    volumes:"
            echo "      - \${PROJECT_DIR_${upper}}:\${CONTAINER_PROJECT_DIR_${upper}:-/project-${letter}}"
            echo "      - node_modules_${letter}:\${CONTAINER_PROJECT_DIR_${upper}:-/project-${letter}}/node_modules"

            if [[ "$i" -lt "$NUM_ACCOUNTS" ]]; then
                echo ""
            fi
        done
    } > "$outfile"

    echo "Generated: $outfile ($NUM_ACCOUNTS services)"
}

# --- Generate docker-compose.linux.yml ----------------------------------------

generate_linux() {
    local outfile="$PROJECT_ROOT/docker-compose.linux.yml"
    {
        echo "# docker-compose.linux.yml"
        echo "# Generated by scripts/generate-compose — do not edit manually."
        echo "# Usage: docker compose -f docker-compose.yml -f docker-compose.linux.yml up"
        echo ""
        echo "services:"

        for i in $(seq 1 "$NUM_ACCOUNTS"); do
            local letter
            letter=$(index_to_letter "$i")
            local svc="${SERVICE_PREFIX}-${letter}"

            echo "  ${svc}:"
            echo "    user: \"\${UID}:\${GID}\""
            echo "    environment:"
            echo "      - HOME=/home/node"

            if [[ "$i" -lt "$NUM_ACCOUNTS" ]]; then
                echo ""
            fi
        done
    } > "$outfile"

    echo "Generated: $outfile ($NUM_ACCOUNTS services)"
}

# --- Main ---------------------------------------------------------------------

main() {
    echo "Generating compose files for $NUM_ACCOUNTS account(s)..."
    generate_base
    generate_worktree
    generate_linux
    echo "Done."
}

main
