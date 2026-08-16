#!/usr/bin/env bash
# Complete removal script for claude-docker
# Reverses everything install.sh set up: containers, volumes, images,
# worktrees, state directories, .env, and optionally host tools.
set -euo pipefail

# Platform guard: refuse to run on native Windows shells (Git Bash, MSYS,
# Cygwin). This script reverses what install.sh set up, and install.sh already
# refuses on those platforms - so there is no bash-created installation to
# reverse there, only a PowerShell one that remove.ps1 owns. Running anyway
# would walk MSYS-flavored paths and report success having removed nothing
# (#306).
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "Error: remove.sh is not supported on native Windows shells." >&2
        echo "Use: pwsh -ExecutionPolicy Bypass -File scripts\\remove.ps1" >&2
        exit 1 ;;
esac

# --- Constants & Colors -------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/parse_env.sh
. "$SCRIPT_DIR/lib/parse_env.sh"
# shellcheck source=lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# worktrees.sh decides which worktrees this installer owns; sourced after
# parse_env.sh, which it reads .env through.
# shellcheck source=lib/worktrees.sh
. "$SCRIPT_DIR/lib/worktrees.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CURRENT_STEP=0
TOTAL_STEPS=7

# --- Utility Functions --------------------------------------------------------

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { CURRENT_STEP=$((CURRENT_STEP + 1)); echo -e "\n${BOLD}[$CURRENT_STEP/$TOTAL_STEPS] $1${NC}"; }

prompt_confirm() {
    local question="$1"
    local default="${2:-n}"
    local yn_hint="y/N"
    [[ "$default" == "y" ]] && yn_hint="Y/n"

    read -rp "$(echo -e "${YELLOW}${question} [${yn_hint}]: ${NC}")" answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

detect_platform() {
    case "$(uname -s)" in
        Linux*)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl2"
            else
                echo "linux"
            fi
            ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}

# --- Compose Command Builder --------------------------------------------------

# Populate the global COMPOSE_CMD array with `docker compose -f ...` so
# callers invoke it as `"${COMPOSE_CMD[@]}" down ...` instead of building and
# eval'ing a string. Mirrors the pattern in scripts/install.sh (see
# build_compose_cmd there, introduced in #201). Array form preserves quoting
# of paths containing spaces, which was the source of issue #155.
#
# remove.sh must catch containers/volumes from any configuration, so the
# widest overlay set is included whenever the override files exist on disk.
COMPOSE_CMD=()

# build_compose_cmd_for_mode MODE
# Populate COMPOSE_CMD for exactly one isolation mode.
#
# This used to attach base + linux + worktree unconditionally and call that the
# "widest overlay set". It is not a valid set. The worktree and isolated
# overlays both carry `!override` volume lists and disagree on working_dir, and
# the worktree overlay interpolates ${PROJECT_DIR_A} -- which an isolated
# install never sets:
#
#     $ docker compose config
#     warning: The "PROJECT_DIR_A" variable is not set.
#     invalid spec: :/project-a: empty section between colons
#
# That failure was discarded by `2>/dev/null || true`, so an isolated teardown
# fell through to a bare `docker compose down` that did not know the isolated
# overlay -- and the isolated_net_* bridge networks survived a run that
# reported "Removal Complete".
build_compose_cmd_for_mode() {
    local mode="$1"
    COMPOSE_CMD=(docker compose -f "${PROJECT_ROOT}/docker-compose.yml")

    local platform
    platform=$(detect_platform)

    if [[ "$platform" == "linux" ]] && [[ -f "${PROJECT_ROOT}/docker-compose.linux.yml" ]]; then
        COMPOSE_CMD+=(-f "${PROJECT_ROOT}/docker-compose.linux.yml")
    fi

    case "$mode" in
        worktree) COMPOSE_CMD+=(-f "${PROJECT_ROOT}/docker-compose.worktree.yml") ;;
        isolated) COMPOSE_CMD+=(-f "${PROJECT_ROOT}/docker-compose.isolated.yml") ;;
    esac
}

# teardown_modes
# The modes worth attempting, one per line.
#
# Removal has to catch resources from whatever mode the installation is in now
# *and* from modes it used to be in -- switching leaves the previous stack's
# containers and networks behind, and this is the script that is supposed to
# find them. So every mode whose overlay exists is attempted, one `down` each,
# rather than one `down` carrying every overlay.
teardown_modes() {
    echo "shared"
    [[ -f "${PROJECT_ROOT}/docker-compose.worktree.yml" ]] && echo "worktree"
    [[ -f "${PROJECT_ROOT}/docker-compose.isolated.yml" ]] && echo "isolated"
    return 0
}

# --- Main Removal Steps -------------------------------------------------------

remove_containers_and_volumes() {
    log_step "Stopping and removing containers + volumes"

    cd "$PROJECT_ROOT"

    # One `down` per mode. A mode the installation was never in will usually
    # fail here on an unset per-account path, and that is fine and expected --
    # what is not fine is the previous behaviour, where the *configured*
    # mode's failure looked identical to it because both were discarded.
    # Every attempt reports its outcome, and the summary names any that did
    # not succeed.
    local mode rc out
    local -a failed=()
    while IFS= read -r mode; do
        build_compose_cmd_for_mode "$mode"
        log_info "Stopping containers ($mode stack)..."
        rc=0
        out=$("${COMPOSE_CMD[@]}" down --remove-orphans -v 2>&1) || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            failed+=("$mode")
            log_warn "  $mode stack: docker compose down exited $rc"
            printf '%s\n' "$out" | sed 's/^/      /' >&2
        fi
    done < <(teardown_modes)

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_warn "Teardown did not complete for: ${failed[*]}"
        log_warn "  A mode this installation never used is expected to fail here."
        log_warn "  Check 'docker ps -a' and 'docker network ls' if resources remain."
    fi

    # Remove any dangling containers with the project prefix
    local project_containers
    project_containers=$(docker ps -a --filter "label=com.docker.compose.project=claude-docker" -q 2>/dev/null || true)
    if [[ -n "$project_containers" ]]; then
        log_info "Removing leftover containers..."
        echo "$project_containers" | xargs -r docker rm -f 2>/dev/null || true
    fi

    log_success "Containers and volumes removed"
}

remove_docker_image() {
    log_step "Removing Docker image"

    local image="claude-code-base:latest"

    if docker image inspect "$image" &>/dev/null; then
        if prompt_confirm "Remove Docker image '$image'?"; then
            docker rmi "$image" 2>/dev/null || {
                log_warn "Image in use by other containers. Force removing..."
                docker rmi -f "$image" 2>/dev/null || true
            }
            log_success "Image '$image' removed"
        else
            log_info "Image kept"
        fi
    else
        log_info "Image '$image' not found (already removed or never built)"
    fi

    # Clean up dangling images from failed builds
    local dangling
    dangling=$(docker images -f "dangling=true" -q 2>/dev/null || true)
    if [[ -n "$dangling" ]]; then
        log_info "Cleaning dangling images..."
        echo "$dangling" | xargs -r docker rmi 2>/dev/null || true
    fi
}

remove_worktrees() {
    log_step "Removing git worktrees"

    # Read PROJECT_DIR from .env if it exists
    local env_file="$PROJECT_ROOT/.env"
    local project_dir=""
    if [[ -f "$env_file" ]]; then
        project_dir=$(parse_env_value "$env_file" "PROJECT_DIR")
    fi

    if [[ -z "$project_dir" ]]; then
        log_info "No PROJECT_DIR found in .env — skipping worktree removal"
        return 0
    fi

    if [[ ! -d "$project_dir/.git" ]]; then
        log_info "$project_dir is not a git repository — no worktrees to remove"
        return 0
    fi

    # Partition what git reports into worktrees this installer created and
    # worktrees the user made themselves. The loop this replaces took
    # "not the current directory" as the whole test, so a `git worktree add
    # ../proj-hotfix` in the same repository was removed with --force and then
    # rm -rf. The comment claimed to be looking for setup-worktrees.sh's
    # names; now it actually is (scripts/lib/worktrees.sh).
    local targets=() skipped=() wt_path
    cd "$project_dir"
    while IFS= read -r wt_path; do
        [[ -d "$wt_path" ]] || continue
        if worktree_is_owned "$wt_path" "$project_dir" "$env_file"; then
            targets+=("$wt_path")
        else
            skipped+=("$wt_path")
        fi
    done < <(worktree_selectable_paths "$(pwd)")

    # Guarded by the count rather than expanding the array directly: bash 3.2
    # (still what macOS ships) errors on "${arr[@]}" for an empty array under
    # `set -u`.
    if [[ ${#skipped[@]} -gt 0 ]]; then
        for wt_path in "${skipped[@]}"; do
            log_info "Keeping worktree not created by claude-docker: $wt_path"
        done
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        log_info "No claude-docker worktrees found"
        return 0
    fi

    # Every other destructive step in this script prompts for itself
    # (remove_docker_image, remove_state_directories, remove_env_file). This
    # one did not, and the single "Proceed with removal?" at the top never
    # names what is about to go, so the user could not see the list.
    echo ""
    echo -e "${BOLD}Worktrees to remove:${NC}"
    for wt_path in "${targets[@]}"; do
        echo "  - $wt_path"
    done
    echo ""
    if ! prompt_confirm "Remove the ${#targets[@]} worktree(s) listed above?"; then
        log_info "Worktrees kept"
        return 0
    fi

    local worktree_count=0
    for wt_path in "${targets[@]}"; do
        log_info "Removing worktree: $wt_path"
        if git worktree remove "$wt_path" --force 2>/dev/null; then
            worktree_count=$((worktree_count + 1))
            continue
        fi
        # No rm -rf fallback. git refusing to remove a worktree it created is
        # information, not an obstacle: the path is locked, or it is not the
        # tree we think it is. Escalating past that refusal is what turned a
        # wrong path into data loss.
        log_warn "git declined to remove $wt_path — left in place"
        log_warn "  Inspect it and remove it manually if it is no longer needed."
    done

    if [[ $worktree_count -eq 0 ]]; then
        log_info "No worktrees removed"
    else
        log_success "$worktree_count worktree(s) removed"
    fi
}

remove_state_directories() {
    log_step "Removing state directories"

    # Offer every registered runtime's state directory, not just Claude's,
    # so a codex/gemini install does not leave its state orphaned. State-dir
    # names are resolved from the runtime registry (see #267, #273).
    #
    # runtime_list output is collected into an array first: prompt_confirm
    # reads from stdin, so iterating via `done < <(runtime_list)` would let
    # the prompt consume the runtime stream instead of the user's answer.
    local runtimes=()
    local runtime
    while IFS= read -r runtime; do
        [[ -n "$runtime" ]] && runtimes+=("$runtime")
    done < <(runtime_list)

    local found=0
    local state_dir state_root
    for runtime in "${runtimes[@]}"; do
        state_dir="$(runtime_field "$runtime" "stateDir")"
        [[ -z "$state_dir" ]] && continue
        state_root="$HOME/$state_dir"

        if [[ ! -d "$state_root" ]]; then
            continue
        fi
        found=1

        # List what exists
        echo -e "${DIM}  Contents of $state_root/:${NC}"
        ls -1 "$state_root" 2>/dev/null | while read -r item; do
            local size
            size=$(du -sh "$state_root/$item" 2>/dev/null | cut -f1)
            echo -e "${DIM}    $item ($size)${NC}"
        done

        echo ""
        if prompt_confirm "Remove all $runtime state directories (~/$state_dir)?"; then
            rm -rf "$state_root"
            log_success "$runtime state directories removed"
        else
            log_info "$runtime state directories kept"
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        log_info "No state directories found"
    fi
}

remove_env_file() {
    log_step "Removing .env configuration"

    cd "$PROJECT_ROOT"

    if [[ -f .env ]]; then
        if prompt_confirm "Remove .env file (contains API keys and paths)?"; then
            rm -f .env
            log_success ".env removed"
        else
            log_info ".env kept"
        fi
    else
        log_info "No .env file found"
    fi
}

remove_host_tools() {
    log_step "Removing host-installed tools (optional)"

    local platform
    platform=$(detect_platform)

    echo -e "${DIM}  These tools were installed on the host by install.sh for${NC}"
    echo -e "${DIM}  authentication (Path A). Skip if you use them for other projects.${NC}"
    echo ""

    # Claude Code (native install or legacy npm global)
    if command -v claude &>/dev/null; then
        if prompt_confirm "Remove Claude Code from host?"; then
            # Native install: ~/.local/bin/claude + ~/.local/share/claude
            rm -f "$HOME/.local/bin/claude" 2>/dev/null || true
            rm -rf "$HOME/.local/share/claude" 2>/dev/null || true
            # Legacy npm global (if still present)
            npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
            log_success "Claude Code removed from host"
        else
            log_info "Claude Code kept on host"
        fi
    else
        log_info "Claude Code not installed on host"
    fi
}

print_summary() {
    log_step "Removal complete"

    echo ""
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo -e "${BOLD}${GREEN}  Removal Complete${NC}"
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo ""
    echo -e "${BOLD}What was removed:${NC}"
    echo "  - Docker containers and named volumes"
    echo "  - Docker image (if confirmed)"
    echo "  - Git worktrees (if any)"
    echo "  - State directories (if confirmed)"
    echo "  - .env file (if confirmed)"
    echo ""
    echo -e "${BOLD}What was NOT removed:${NC}"
    echo "  - This repository (claude-docker/)"
    echo "  - Docker Engine itself"
    echo "  - Your project source code"
    echo ""
    echo -e "${DIM}To reinstall: scripts/install.sh${NC}"
    echo ""
}

# --- Main ---------------------------------------------------------------------

main() {
    echo ""
    echo -e "${BOLD}${RED}============================================${NC}"
    echo -e "${BOLD}${RED}  Claude Docker — Complete Removal${NC}"
    echo -e "${BOLD}${RED}============================================${NC}"
    echo ""
    log_warn "This will remove all claude-docker components from your system."
    echo ""

    if ! prompt_confirm "Proceed with removal?"; then
        log_info "Removal cancelled."
        exit 0
    fi

    remove_containers_and_volumes
    remove_docker_image
    remove_worktrees
    remove_state_directories
    remove_env_file
    remove_host_tools
    print_summary
}

main "$@"
