#!/usr/bin/env bash
# Complete removal script for claude-docker
# Reverses everything install.sh set up: containers, volumes, images,
# worktrees, state directories, archive, .env, and optionally host tools.
set -euo pipefail

# --- Constants & Colors -------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# --- Compose Command Discovery ------------------------------------------------

# Build the widest compose command covering all possible overlays.
# This ensures we catch containers/volumes from any configuration.
build_full_compose_cmd() {
    local cmd="docker compose -f docker-compose.yml"
    local platform
    platform=$(detect_platform)

    [[ "$platform" == "linux" ]] && [[ -f "$PROJECT_ROOT/docker-compose.linux.yml" ]] && \
        cmd+=" -f docker-compose.linux.yml"
    [[ -f "$PROJECT_ROOT/docker-compose.worktree.yml" ]] && \
        cmd+=" -f docker-compose.worktree.yml"
    [[ -f "$PROJECT_ROOT/docker-compose.orchestration.yml" ]] && \
        cmd+=" -f docker-compose.orchestration.yml"
    [[ -f "$PROJECT_ROOT/docker-compose.firewall.yml" ]] && \
        cmd+=" -f docker-compose.firewall.yml"

    echo "$cmd"
}

# --- Main Removal Steps -------------------------------------------------------

remove_containers_and_volumes() {
    log_step "Stopping and removing containers + volumes"

    cd "$PROJECT_ROOT"

    local compose_cmd
    compose_cmd=$(build_full_compose_cmd)

    # Stop all running containers from any compose config
    log_info "Stopping containers..."
    eval "$compose_cmd down --remove-orphans -v" 2>/dev/null || true

    # Also try base compose alone (in case overlay files were deleted)
    docker compose down --remove-orphans -v 2>/dev/null || true

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
    local project_dir=""
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        project_dir=$(grep -E '^PROJECT_DIR=' "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | cut -d'=' -f2- || true)
    fi

    if [[ -z "$project_dir" ]]; then
        log_info "No PROJECT_DIR found in .env — skipping worktree removal"
        return 0
    fi

    if [[ ! -d "$project_dir/.git" ]]; then
        log_info "$project_dir is not a git repository — no worktrees to remove"
        return 0
    fi

    # Find worktrees created by setup-worktrees.sh (named {project}-a, {project}-b)
    local worktree_count=0
    cd "$project_dir"
    while IFS= read -r wt_line; do
        local wt_path="${wt_line#worktree }"
        if [[ "$wt_path" != "$(pwd)" ]] && [[ -d "$wt_path" ]]; then
            log_info "Removing worktree: $wt_path"
            git worktree remove "$wt_path" --force 2>/dev/null || {
                log_warn "Force removing: $wt_path"
                rm -rf "$wt_path" 2>/dev/null || true
                git worktree prune 2>/dev/null || true
            }
            worktree_count=$((worktree_count + 1))
        fi
    done < <(git worktree list --porcelain 2>/dev/null | grep "^worktree " || true)

    if [[ $worktree_count -eq 0 ]]; then
        log_info "No worktrees found"
    else
        log_success "$worktree_count worktree(s) removed"
    fi
}

remove_state_directories() {
    log_step "Removing state directories"

    local state_root="$HOME/.claude-state"

    if [[ ! -d "$state_root" ]]; then
        log_info "No state directories found at $state_root"
        return 0
    fi

    # List what exists
    echo -e "${DIM}  Contents of $state_root/:${NC}"
    ls -1 "$state_root" 2>/dev/null | while read -r item; do
        local size
        size=$(du -sh "$state_root/$item" 2>/dev/null | cut -f1)
        echo -e "${DIM}    $item ($size)${NC}"
    done

    # Analysis archive — ask separately (may contain valuable session history)
    if [[ -d "$state_root/analysis-archive" ]]; then
        local session_count=0
        if [[ -f "$state_root/analysis-archive/index.json" ]]; then
            session_count=$(jq '.sessions | length' "$state_root/analysis-archive/index.json" 2>/dev/null || echo 0)
        fi
        echo ""
        if prompt_confirm "Remove analysis archive ($session_count sessions)?"; then
            rm -rf "$state_root/analysis-archive"
            log_success "Analysis archive removed"
        else
            log_info "Analysis archive preserved"
        fi
    fi

    # Account state directories
    echo ""
    if prompt_confirm "Remove all account state directories (~/.claude-state)?"; then
        # If archive was preserved, move it out first
        local archive_preserved=false
        if [[ -d "$state_root/analysis-archive" ]]; then
            mv "$state_root/analysis-archive" "/tmp/claude-archive-$$"
            archive_preserved=true
        fi

        rm -rf "$state_root"
        log_success "State directories removed"

        # Restore archive if preserved
        if [[ "$archive_preserved" == true ]]; then
            mkdir -p "$state_root"
            mv "/tmp/claude-archive-$$" "$state_root/analysis-archive"
            log_info "Analysis archive restored to $state_root/analysis-archive"
        fi
    else
        log_info "State directories kept"
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

    # Claude Code (npm global)
    if command -v claude &>/dev/null; then
        if prompt_confirm "Remove Claude Code from host (npm global)?"; then
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
