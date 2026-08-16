#!/usr/bin/env bash
# generate-compose.sh — Generate docker-compose files for N accounts.
#
# Reads NUM_ACCOUNTS and IMAGE_TAG from .env (or environment) and writes:
#   docker-compose.yml          Base config (Tier A: shared source)
#   docker-compose.worktree.yml Tier B override (per-account worktrees)
#   docker-compose.isolated.yml Isolated override (per-account clones)
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
        echo "Use: pwsh -ExecutionPolicy Bypass -File scripts\\generate-compose.ps1" >&2
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
# shellcheck source=lib/isolation.sh
. "$SCRIPT_DIR/lib/isolation.sh"
# shellcheck source=lib/resources.sh
. "$SCRIPT_DIR/lib/resources.sh"

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

# Node old-space limit, derived from the memory cap unless it is set
# explicitly. This one does NOT reproduce its historical value: the old
# hardcoded 4096 MiB heap sat exactly on the 4G cap, which is the defect
# issue #335 records rather than a default worth preserving. Regenerating
# lowers the heap to 3072 MiB at the default cap.
#
# Validated here, next to GH_AUTH_MODE and ISOLATION_MODE, for the same
# reason: the pair (cap, heap) is baked into the output as two literals, so a
# combination that would OOM-kill has to be rejected before the first output
# file is opened rather than discovered by a container dying under load.
NODE_HEAP_MB="$(resolve_node_heap_mib "$MEM_LIMIT" "${CONTAINER_NODE_HEAP_MB:-}")" || exit 1

# GitHub authentication is shared by default for backward compatibility.
# Per-account mode is validated before any compose file is opened so a missing
# mapping cannot leave a partially regenerated output behind.
GH_AUTH_MODE="${GH_AUTH_MODE:-shared}"
case "$GH_AUTH_MODE" in
    shared|per-account) ;;
    *)
        echo "Error: GH_AUTH_MODE must be shared or per-account (got: $GH_AUTH_MODE)" >&2
        exit 1
        ;;
esac

if [[ "$GH_AUTH_MODE" == "per-account" ]]; then
    for i in $(seq 1 "$NUM_ACCOUNTS"); do
        upper=$(index_to_upper "$i")
        user_var="GH_USER_${upper}"
        token_var="GH_TOKEN_${upper}"
        if [[ -z "${!user_var:-}" ]]; then
            echo "Error: $user_var is required when GH_AUTH_MODE=per-account" >&2
            exit 1
        fi
        if [[ -z "${!token_var:-}" ]]; then
            echo "Error: $token_var is required when GH_AUTH_MODE=per-account" >&2
            exit 1
        fi
    done
fi

# Isolation mode declares the workspace trust boundary. Validated here, next to
# GH_AUTH_MODE and for the same reason: an unusable value must be rejected
# before the first output file is opened, so a failure cannot leave a partially
# regenerated set behind.
#
# All four files are still generated in every mode. The mode decides which
# ones a caller composes together (lib/build-compose-cmd.sh), not which ones
# exist, so `compose-freshness` keeps comparing the same tracked set.
#
# NUM_ACCOUNTS is passed so the per-account workspace paths are checked for
# every account, not just the first: the compose builder only needs to know the
# mode is usable, but a file written here with an unset path for account C
# would fail at `up` instead of now.
ISOLATION_MODE_RESOLVED="$(require_supported_isolation_mode "$NUM_ACCOUNTS")" || exit 1

warn_unused_workspace_paths "$ISOLATION_MODE_RESOLVED"

# The network policy is resolved unconditionally, even under shared or worktree,
# because docker-compose.isolated.yml is written in every mode. Resolving it
# only when the mode is isolated would leave an invalid value undetected until
# somebody switched modes, which is the point at which a wrong network policy is
# hardest to notice.
ISOLATED_NETWORK_MODE_RESOLVED="$(resolve_isolated_network_mode)" || exit 1

# index_to_letter and index_to_upper provided by scripts/lib/index.sh.

# --- Shared emitters ----------------------------------------------------------

# emit_account_volumes MODE LETTER PROJECT_SOURCE PROJECT_TARGET
# Print the complete volume list for one account service, indented for a
# `volumes:` block.
#
# All three outputs that carry volumes come through here. The base config and
# the worktree overlay differ only in where the project comes from and where it
# lands; the isolated overlay additionally drops every shared host-home mount.
# Emitting all of them from one function is what keeps the common mounts
# identical, and that matters more than it used to: both overlays REPLACE this
# list rather than appending to it, so a mount missing here is missing from the
# resolved service entirely.
emit_account_volumes() {
    local mode="$1" letter="$2" project_source="$3" project_target="$4"

    echo "      - ${project_source}:${project_target}"

    # Per-account runtime state stays a host bind mount in every mode. It is
    # under $HOME, but it is not a *shared* surface: each account has its own
    # directory, so account A still cannot reach account B's state. Moving it
    # into a named volume would satisfy the letter of "no host home mounts"
    # while blinding the TUI, which discovers accounts by scanning
    # $HOME/<stateDir>/account-* on the host (tui/internal/config/state.go).
    echo "      - \${HOME}/${RT_STATE_DIR}/account-${letter}:${RT_CONTAINER_CONFIG_MOUNT}"

    # The remaining host-home mounts ARE shared surfaces: the read-only runtime
    # config tree, the agents/skills tree and the shared gh config resolve to
    # the same host path for every account. An isolated account receives none
    # of them (issue #335, stage 3). The runtime tolerates their absence --
    # bootstrap-claude.sh returns early when the config source is missing -- so
    # the container still starts, with no shared hooks, skills, commands,
    # statusline or CLAUDE.md. Restoring that through an allowlisted
    # per-account import is still open -- it is optional in the issue's own
    # wording and depends on a cross-repository decision; see docs/ISOLATION.md.
    if [[ "$mode" != "isolated" ]]; then
        echo "      - \${HOME}/${RT_HOST_CONFIG_BASENAME}:${RT_HOST_CONFIG_MOUNT}:ro"
        # The agents/skills volume is bound only for runtimes whose registry
        # entry sets mountsAgentsSkills (currently codex).
        if [[ "$RT_MOUNTS_AGENTS_SKILLS" == "true" ]]; then
            echo '      - ${AGENTS_SKILLS_DIR:-${HOME}/.agents/skills}:/home/node/.agents/skills:ro'
        fi
        if [[ "$GH_AUTH_MODE" == "shared" ]]; then
            echo "      - \${GH_CONFIG_DIR:-\${HOME}/.config/gh}:/home/node/.config/gh:ro"
        fi
    fi

    echo "      - node_modules_${letter}:${project_target}/node_modules"
}

# emit_account_environment MODE UPPER
# Print the complete environment list for one account service, indented for an
# `environment:` block.
#
# Both the base config and the isolated overlay come through here, and the
# isolated overlay tags its block `!override`. That tag is not decoration: an
# untagged block MERGES by key, so the base's shared-token entry would survive
# into an isolated service. Compose offers no way to remove a single inherited
# key -- `!reset` on an individual environment entry is ignored outright, and
# `!override` replaces the whole list -- so the isolated environment has to be
# re-emitted in full. Emitting both from one function is what keeps that
# duplication honest: a variable added below reaches every mode, and a
# credential withheld below is withheld everywhere it should be.
#
# The withholding is deliberately fail-closed. Anything not listed here never
# reaches an isolated service, so a credential added to the base later cannot
# leak into the isolated profile by being forgotten -- only by being written
# into the isolated branch on purpose.
emit_account_environment() {
    local mode="$1" upper="$2"

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
    # Baked as a literal, like the memory cap it is derived from. Emitting
    # \${CONTAINER_NODE_HEAP_MB:-...} instead would let the heap be changed in
    # .env without the cap moving with it, which is precisely the pairing this
    # value is validated to preserve.
    echo "      - NODE_OPTIONS=--max-old-space-size=${NODE_HEAP_MB}"

    # Only emit provider API keys when a per-account key is set at
    # generate time. Emitting an empty key makes SDKs prefer the
    # blank env var over persisted credentials. The variable read is
    # already per-account, so this needs no isolated-mode branch.
    local key_var="${RT_API_KEY_PREFIX}${upper}"
    if [[ -n "${!key_var:-}" ]]; then
        echo "      - ${RT_SDK_API_KEY_VAR}=\${${key_var}}"
    fi

    # GIT_USER_NAME/EMAIL are committer identity, not credentials: they name the
    # human rather than an account, and an isolated account still has to commit.
    # They are emitted in all three cases below.
    if [[ "$GH_AUTH_MODE" == "per-account" ]]; then
        # Already scoped: every account reads its own token variable, which is
        # exactly the contract issue #331 established. Isolated services reuse
        # it unchanged rather than growing a second mechanism.
        echo "      - GH_AUTH_MODE=per-account"
        echo "      - GH_USER=\${GH_USER_${upper}}"
        echo "      - GH_TOKEN=\${GH_TOKEN_${upper}}"
        echo "      - GIT_USER_NAME=\${GIT_USER_NAME_${upper}:-\${GIT_USER_NAME:-}}"
        echo "      - GIT_USER_EMAIL=\${GIT_USER_EMAIL_${upper}:-\${GIT_USER_EMAIL:-}}"
    elif [[ "$mode" == "isolated" ]]; then
        # No GitHub credential at all. The shared GH_TOKEN identifies one
        # account to GitHub, so handing the same value to every isolated
        # service would make the boundary decorative on the one surface that
        # carries write access to remote repositories (issue #335, stage 4).
        # The entrypoint already treats an unset GH_TOKEN as "no token": it
        # falls through to hosts.yml, which an isolated account does not have
        # either, and reports unauthenticated rather than failing to start.
        echo "      - GIT_USER_NAME=\${GIT_USER_NAME:-}"
        echo "      - GIT_USER_EMAIL=\${GIT_USER_EMAIL:-}"
    else
        echo "      - GH_TOKEN=\${GH_TOKEN:-}"
        echo "      - GIT_USER_NAME=\${GIT_USER_NAME:-}"
        echo "      - GIT_USER_EMAIL=\${GIT_USER_EMAIL:-}"
    fi

    if [[ "$mode" == "isolated" ]]; then
        # $HOME is on the read-only root filesystem, so `git config --global`
        # and `gh auth setup-git` cannot write ~/.gitconfig. Redirect the
        # global config into the per-account state mount, which is writable
        # and already account-private. Without this the entrypoint's
        # credential-helper setup fails silently and `git push` breaks with
        # no diagnostic. Requires git 2.32+ (image ships 2.39 on bookworm).
        echo "      - GIT_CONFIG_GLOBAL=${RT_CONTAINER_CONFIG_MOUNT}/gitconfig"
    fi
}

# emit_isolated_tmpfs
# Bounded writable scratch for the isolated profile's read-only root filesystem.
#
# Every path below is an image layer rather than a mount, so with
# read_only: true the first write to it fails. The inventory is what the
# entrypoint and toolchain actually write outside the account's own mounts:
#
#   /tmp                 general tool scratch
#   /home/node/.config   bootstrap-claude.sh creates the ccstatusline XDG link
#   /home/node/.cache    generic tool caches
#   /home/node/.npm      npm cache
#   /home/node/.agents   bootstrap-codex/gemini create skills/ under it
#
# /home/node/.local is deliberately absent: the agent CLI is installed there
# (Dockerfile) and is on PATH, so covering it with a tmpfs would hide the
# binary. $HOME itself is likewise left read-only; the one thing that needed to
# write there, the global git config, is redirected via GIT_CONFIG_GLOBAL.
#
# uid/gid repeat the host-user defaults the base stack uses for `user:`.
# Without them a tmpfs mounts root-owned with mode 1777 — writable by the
# service, but world-writable, which contradicts the point of this profile.
# /tmp keeps the conventional 1777 with its sticky bit instead, because tools
# expect a shared scratch there.
emit_isolated_tmpfs() {
    local owner="uid=\${UID:-1000},gid=\${GID:-1000},mode=0700"

    echo "    tmpfs:"
    echo "      - /tmp:mode=1777"
    echo "      - /home/node/.config:${owner}"
    echo "      - /home/node/.cache:${owner}"
    echo "      - /home/node/.npm:${owner}"
    echo "      - /home/node/.agents:${owner}"
}

# emit_isolated_service_network LETTER
# Print the network attachment for one isolated account service.
#
# The base stack declares no networks at all, so every service lands on the
# project-wide implicit `default` bridge and siblings can reach each other by
# service name. Declaring an explicit network here REPLACES that attachment
# rather than adding to it, which is what makes the separation real.
#
# `networks` and `network_mode` are mutually exclusive keys -- a service
# carrying both is rejected -- so the policy has to pick one at generate time
# and cannot be expressed as an interpolated ${VAR}. That is the same shape
# NUM_ACCOUNTS and GH_AUTH_MODE already have: the generated file is correct for
# the configuration it was generated from, and changing the key means
# regenerating.
emit_isolated_service_network() {
    local letter="$1"

    if [[ "$ISOLATED_NETWORK_MODE_RESOLVED" == "none" ]]; then
        echo "    network_mode: none"
    else
        echo "    networks:"
        echo "      - isolated_net_${letter}"
    fi
}

# emit_isolated_networks
# Print the top-level `networks:` block declaring one bridge per account.
#
# Ordinary bridges, not `internal: true`: outbound access to the model API and
# to git remotes has to keep working. What this buys is that A and B sit on
# different bridges, so neither appears in the other's DNS and neither can open
# a direct connection to it. Blocking egress is a proxy/firewall concern and is
# deliberately not attempted here.
emit_isolated_networks() {
    if [[ "$ISOLATED_NETWORK_MODE_RESOLVED" == "none" ]]; then
        return 0
    fi

    echo ""
    echo "networks:"
    local i letter
    for i in $(seq 1 "$NUM_ACCOUNTS"); do
        letter=$(index_to_letter "$i")
        echo "  isolated_net_${letter}:"
        echo "    driver: bridge"
    done
}

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
            emit_account_volumes shared "$letter" '${PROJECT_DIR}' '${CONTAINER_PROJECT_DIR:-/project}'
            echo "    environment:"
            emit_account_environment shared "$upper"
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
        echo "#"
        echo "# Every volume list below carries the !override merge tag, so it REPLACES the"
        echo "# base list instead of extending it. Compose merges volumes by container"
        echo "# target, and /project-<letter> is a different target from the base /project,"
        echo "# so without the tag the shared \${PROJECT_DIR} mount survived alongside the"
        echo "# worktree and stayed writable from inside the container (issue #335)."
        echo "# Requires a Compose release that supports !override (Docker Compose v2.24.4+)."
        echo "#"
        echo "# Worktrees are a concurrency tier, not a security boundary: the accounts"
        echo "# still share one git object store. See docs/ISOLATION.md."
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
            echo "    volumes: !override"
            emit_account_volumes worktree "$letter" \
                "\${PROJECT_DIR_${upper}}" \
                "\${CONTAINER_PROJECT_DIR_${upper}:-/project-${letter}}"

            if [[ "$i" -lt "$NUM_ACCOUNTS" ]]; then
                echo ""
            fi
        done
    } > "$outfile"

    echo "Generated: $outfile ($NUM_ACCOUNTS services)"
}

# --- Generate docker-compose.isolated.yml ------------------------------------

generate_isolated() {
    local outfile="$PROJECT_ROOT/docker-compose.isolated.yml"
    {
        echo "# docker-compose.isolated.yml"
        echo "# Generated by scripts/generate-compose — do not edit manually."
        echo "# Usage: docker compose -f docker-compose.yml -f docker-compose.isolated.yml up"
        echo "#"
        echo "# Each account mounts its own independent clone — separate working tree AND"
        echo "# separate git metadata, created by scripts/setup-isolated.sh. Unlike a"
        echo "# worktree, nothing is shared: there is no common object store to read other"
        echo "# branches from or rewrite refs in."
        echo "#"
        echo "# The volume lists carry !override so they REPLACE the base list. Compose"
        echo "# merges volumes by container target, so without the tag the shared"
        echo "# \${PROJECT_DIR} mount would survive alongside the clone (issue #335)."
        echo "# Requires a Compose release that supports !override (Docker Compose v2.24.4+)."
        echo "#"
        echo "# Shared host-home mounts are absent by design: no read-only host config"
        echo "# tree, no agents/skills tree, no shared gh config. An isolated account"
        echo "# therefore has no shared hooks, skills, commands, statusline or CLAUDE.md."
        echo "#"
        echo "# The container profile is hardened: read-only root filesystem, all"
        echo "# capabilities dropped, no-new-privileges, an init process and a bounded"
        echo "# PID limit. Every path the entrypoint writes to outside the account's own"
        echo "# mounts is a bounded tmpfs; \$HOME itself stays read-only, so the global"
        echo "# git config is redirected into the per-account state mount."
        echo "#"
        echo "# The environment lists carry !override for the same reason the volume"
        echo "# lists do. An untagged block merges by key, so the base stack's shared"
        echo "# GH_TOKEN would survive into every isolated service; Compose cannot"
        echo "# remove a single inherited key, so the list is re-emitted in full and"
        echo "# whatever is absent below is absent from the resolved service."
        echo "#"
        if [[ "$ISOLATED_NETWORK_MODE_RESOLVED" == "none" ]]; then
            echo "# ISOLATED_NETWORK_MODE=none: every account is detached from all"
            echo "# networks. Outbound agent, API and git access do not work. Regenerate"
            echo "# with ISOLATED_NETWORK_MODE=bridge to restore them."
        else
            echo "# Each account is on its own bridge network, so outbound access keeps"
            echo "# working while siblings cannot resolve or connect to each other."
            echo "# Egress allowlisting is a separate proxy/firewall concern."
        fi
        echo ""
        echo "services:"

        for i in $(seq 1 "$NUM_ACCOUNTS"); do
            local letter
            letter=$(index_to_letter "$i")
            local upper
            upper=$(index_to_upper "$i")
            local svc="${SERVICE_PREFIX}-${letter}"

            echo "  ${svc}:"
            echo "    working_dir: \${CONTAINER_ISOLATED_DIR_${upper}:-/workspace-${letter}}"
            echo "    read_only: true"
            echo "    init: true"
            echo "    cap_drop:"
            echo "      - ALL"
            echo "    security_opt:"
            echo "      - no-new-privileges:true"
            # The PID cap goes under deploy.resources.limits, not the legacy
            # top-level pids_limit key. The base stack already declares
            # deploy.resources.limits (cpus, memory); Compose treats the legacy
            # key and the deploy field as the same setting and rejects the
            # merged project outright when both appear.
            echo "    deploy:"
            echo "      resources:"
            echo "        limits:"
            echo "          pids: \${ISOLATED_PIDS_LIMIT:-1024}"
            emit_isolated_tmpfs
            emit_isolated_service_network "$letter"
            echo "    environment: !override"
            emit_account_environment isolated "$upper"
            echo "    volumes: !override"
            emit_account_volumes isolated "$letter" \
                "\${ISOLATED_WORKSPACE_${upper}}" \
                "\${CONTAINER_ISOLATED_DIR_${upper}:-/workspace-${letter}}"

            if [[ "$i" -lt "$NUM_ACCOUNTS" ]]; then
                echo ""
            fi
        done

        emit_isolated_networks
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
    generate_isolated
    generate_linux
    echo "Done."
}

main
