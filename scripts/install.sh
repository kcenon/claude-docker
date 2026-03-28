#!/usr/bin/env bash
# Interactive setup script for claude-docker
# Guides users through environment setup via Q&A, auto-detects platform,
# checks prerequisites, generates .env, builds images, and starts containers.
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
NC='\033[0m' # No Color

TOTAL_STEPS=0
CURRENT_STEP=0

# Collected configuration
PLATFORM=""
AUTH_PATH=""
TIER=""
ORCHESTRATION="no"
FIREWALL="no"
SOURCE_DIR=""
CLAUDE_VERSION=""
API_KEY_A=""
API_KEY_B=""
API_KEY_MANAGER=""
API_KEY_W1=""
API_KEY_W2=""
API_KEY_W3=""
WORKER_COUNT=3

# --- Utility Functions --------------------------------------------------------

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { CURRENT_STEP=$((CURRENT_STEP + 1)); echo -e "\n${BOLD}[$CURRENT_STEP/$TOTAL_STEPS] $1${NC}"; }

prompt_select() {
    local question="$1"
    shift
    local options=("$@")
    local choice=""

    echo -e "\n${YELLOW}${question}${NC}"
    for i in "${!options[@]}"; do
        echo -e "  ${BOLD}$((i + 1)))${NC} ${options[$i]}"
    done

    while true; do
        read -rp "$(echo -e "${YELLOW}> Select [1-${#options[@]}]: ${NC}")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice - 1))]}"
            return 0
        fi
        echo -e "${RED}  Invalid choice. Please enter 1-${#options[@]}.${NC}"
    done
}

prompt_input() {
    local question="$1"
    local default="${2:-}"
    local value=""

    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${YELLOW}${question} [${default}]: ${NC}")" value
        echo "${value:-$default}"
    else
        while [[ -z "$value" ]]; do
            read -rp "$(echo -e "${YELLOW}${question}: ${NC}")" value
            [[ -z "$value" ]] && echo -e "${RED}  This field is required.${NC}"
        done
        echo "$value"
    fi
}

prompt_secret() {
    local question="$1"
    local value=""
    read -rsp "$(echo -e "${YELLOW}${question}: ${NC}")" value
    echo ""
    echo "$value"
}

prompt_confirm() {
    local question="$1"
    local default="${2:-n}"
    local yn_hint="y/N"
    [[ "$default" == "y" ]] && yn_hint="Y/n"

    read -rp "$(echo -e "${YELLOW}${question} [${yn_hint}]: ${NC}")" answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

check_command() {
    command -v "$1" &>/dev/null
}

# --- Platform Detection -------------------------------------------------------

detect_platform() {
    case "$(uname -s)" in
        Linux*)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl2"
            else
                echo "linux"
            fi
            ;;
        Darwin*)
            echo "macos"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

platform_label() {
    case "$1" in
        linux) echo "Linux" ;;
        macos) echo "macOS" ;;
        wsl2)  echo "Windows (WSL2)" ;;
        *)     echo "Unknown" ;;
    esac
}

# --- Prerequisite Checks -----------------------------------------------------

check_docker() {
    if check_command docker; then
        local version
        version=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
        log_success "Docker $version detected"
        return 0
    fi
    return 1
}

check_docker_compose() {
    if docker compose version &>/dev/null; then
        local version
        version=$(docker compose version --short 2>/dev/null)
        log_success "Docker Compose $version detected"
        return 0
    fi
    return 1
}

check_node() {
    if check_command node; then
        local version
        version=$(node --version 2>/dev/null)
        log_success "Node.js $version detected"
        return 0
    fi
    return 1
}

check_git() {
    if check_command git; then
        local version
        version=$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        log_success "Git $version detected"
        return 0
    fi
    return 1
}

install_prerequisite() {
    local tool="$1"

    case "$PLATFORM" in
        linux|wsl2)
            if check_command apt-get; then
                log_info "Installing $tool via apt-get..."
                sudo apt-get update -qq
                case "$tool" in
                    docker)
                        sudo apt-get install -y -qq docker.io docker-compose-plugin
                        sudo usermod -aG docker "$USER"
                        log_warn "Added $USER to docker group. You may need to log out and back in."
                        ;;
                    node)
                        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
                        sudo apt-get install -y -qq nodejs
                        ;;
                    git) sudo apt-get install -y -qq git ;;
                esac
            else
                log_error "apt-get not found. Please install $tool manually."
                return 1
            fi
            ;;
        macos)
            if check_command brew; then
                log_info "Installing $tool via Homebrew..."
                case "$tool" in
                    docker)
                        log_warn "Docker Desktop is required on macOS."
                        log_info "Please download from: https://www.docker.com/products/docker-desktop/"
                        log_info "After installing, restart this script."
                        return 1
                        ;;
                    node) brew install node@20 ;;
                    git)  brew install git ;;
                esac
            else
                log_error "Homebrew not found. Please install $tool manually."
                log_info "Install Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                return 1
            fi
            ;;
    esac
}

run_prerequisite_checks() {
    log_step "Checking prerequisites"

    local missing=()

    check_docker || missing+=("docker")
    check_docker_compose || missing+=("docker-compose")
    check_git || missing+=("git")

    # Node.js only required for Path A (OAuth) authentication
    if [[ "$AUTH_PATH" == "A" ]]; then
        check_node || missing+=("node")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_success "All prerequisites satisfied"
        return 0
    fi

    log_warn "Missing prerequisites: ${missing[*]}"

    for tool in "${missing[@]}"; do
        if [[ "$tool" == "docker-compose" ]]; then
            log_error "docker compose plugin is required. Install Docker with compose plugin."
            continue
        fi

        if prompt_confirm "Install $tool automatically?"; then
            install_prerequisite "$tool" || {
                log_error "Failed to install $tool. Please install manually and re-run."
                exit 1
            }
        else
            log_error "$tool is required. Please install it and re-run."
            exit 1
        fi
    done

    log_success "Prerequisites resolved"
}

# --- Q&A Collection -----------------------------------------------------------

collect_configuration() {
    echo -e "\n${BOLD}${CYAN}=== Configuration ===${NC}\n"

    # Auth Path
    local auth_choice
    auth_choice=$(prompt_select \
        "Which authentication method will you use?" \
        "Path A: Subscription (Pro/Max/Team) — OAuth browser login" \
        "Path B: Console API key — paste key directly")
    [[ "$auth_choice" == *"Path A"* ]] && AUTH_PATH="A" || AUTH_PATH="B"
    log_info "Authentication: Path $AUTH_PATH"

    # Sharing Tier
    local tier_choice
    tier_choice=$(prompt_select \
        "How should containers share source code?" \
        "Tier A: Shared bind mount (simple, one writes at a time)" \
        "Tier B: Git worktrees (safe concurrent editing)")
    [[ "$tier_choice" == *"Tier A"* ]] && TIER="A" || TIER="B"
    log_info "Source sharing: Tier $TIER"

    # Orchestration
    if prompt_confirm "Enable Phase 5 orchestration (manager + 3 workers + Redis)?"; then
        ORCHESTRATION="yes"
        log_info "Orchestration: enabled"
    else
        log_info "Orchestration: disabled (standard 2-container setup)"
    fi

    # Firewall
    if prompt_confirm "Enable outbound firewall (iptables whitelist)?"; then
        FIREWALL="yes"
        log_info "Firewall: enabled"
    else
        log_info "Firewall: disabled"
    fi

    # Project directory
    SOURCE_DIR=$(prompt_input "Absolute path to your project source code" "$(pwd)")
    SOURCE_DIR=$(cd "$SOURCE_DIR" 2>/dev/null && pwd || echo "$SOURCE_DIR")

    if [[ ! -d "$SOURCE_DIR" ]]; then
        log_error "Directory does not exist: $SOURCE_DIR"
        exit 1
    fi

    # Windows WSL2 path check
    if [[ "$PLATFORM" == "wsl2" ]] && [[ "$SOURCE_DIR" == /mnt/* ]]; then
        log_error "Source must be on WSL2 filesystem (e.g., /home/$USER/...), not NTFS (/mnt/c/...)"
        log_error "NTFS is ~27x slower. Move your project to the WSL2 filesystem first."
        exit 1
    fi

    log_info "Project directory: $SOURCE_DIR"

    # Claude Code version
    CLAUDE_VERSION=$(prompt_input "Claude Code version (leave empty for latest)" "")
    if [[ -n "$CLAUDE_VERSION" ]]; then
        log_info "Claude Code version: $CLAUDE_VERSION"
    else
        log_info "Claude Code version: latest"
    fi

    # API keys (Path B)
    if [[ "$AUTH_PATH" == "B" ]]; then
        echo -e "\n${CYAN}Enter Console API keys (from console.anthropic.com):${NC}"
        API_KEY_A=$(prompt_secret "API key for Account A (sk-ant-...)")
        API_KEY_B=$(prompt_secret "API key for Account B (sk-ant-...)")

        if [[ -z "$API_KEY_A" || -z "$API_KEY_B" ]]; then
            log_error "Both API keys are required for Path B."
            exit 1
        fi
        log_success "API keys collected (2 accounts)"
    fi

    # Orchestration API keys
    if [[ "$ORCHESTRATION" == "yes" && "$AUTH_PATH" == "B" ]]; then
        echo -e "\n${CYAN}Enter API keys for orchestration accounts:${NC}"
        API_KEY_MANAGER=$(prompt_secret "API key for Manager")
        API_KEY_W1=$(prompt_secret "API key for Worker 1")
        API_KEY_W2=$(prompt_secret "API key for Worker 2")
        API_KEY_W3=$(prompt_secret "API key for Worker 3")
        WORKER_COUNT=$(prompt_input "Number of workers" "3")
        log_success "Orchestration API keys collected"
    fi
}

# --- .env Generation ----------------------------------------------------------

generate_env() {
    log_step "Generating .env configuration"

    local env_file="$PROJECT_ROOT/.env"

    if [[ -f "$env_file" ]]; then
        if ! prompt_confirm "Existing .env found. Overwrite?"; then
            log_warn "Keeping existing .env. Some settings may not match your choices."
            return 0
        fi
        cp "$env_file" "${env_file}.backup.$(date +%s)"
        log_info "Backed up existing .env"
    fi

    {
        echo "# Generated by install.sh — $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "# ==== Required ===="
        echo "PROJECT_DIR=$SOURCE_DIR"
        echo ""

        if [[ -n "$CLAUDE_VERSION" ]]; then
            echo "# ==== Claude Code Version ===="
            echo "CLAUDE_CODE_VERSION=$CLAUDE_VERSION"
            echo ""
        fi

        if [[ "$AUTH_PATH" == "B" ]]; then
            echo "# ==== Path B: Console API Keys ===="
            echo "CLAUDE_API_KEY_A=$API_KEY_A"
            echo "CLAUDE_API_KEY_B=$API_KEY_B"
            echo ""
        fi

        if [[ "$TIER" == "B" ]]; then
            echo "# ==== Tier B: Git Worktree Paths ===="
            echo "# (populated after worktree setup)"
            echo "PROJECT_DIR_A="
            echo "PROJECT_DIR_B="
            echo ""
        fi

        if [[ "$PLATFORM" == "linux" ]]; then
            echo "# ==== Linux: UID/GID ===="
            echo "UID=$(id -u)"
            echo "GID=$(id -g)"
            echo ""
        fi

        if [[ "$ORCHESTRATION" == "yes" ]]; then
            echo "# ==== Phase 5: Orchestration ===="
            echo "WORKER_COUNT=$WORKER_COUNT"
            if [[ "$AUTH_PATH" == "B" ]]; then
                echo "CLAUDE_API_KEY_MANAGER=$API_KEY_MANAGER"
                echo "CLAUDE_API_KEY_1=$API_KEY_W1"
                echo "CLAUDE_API_KEY_2=$API_KEY_W2"
                echo "CLAUDE_API_KEY_3=$API_KEY_W3"
            fi
            echo ""
        fi
    } > "$env_file"

    log_success ".env generated at $env_file"
}

# --- Directory Creation -------------------------------------------------------

create_state_dirs() {
    log_step "Creating state directories"

    local dirs=(
        "$HOME/.claude-state/account-a"
        "$HOME/.claude-state/account-b"
    )

    if [[ "$ORCHESTRATION" == "yes" ]]; then
        dirs+=(
            "$HOME/.claude-state/account-manager"
            "$HOME/.claude-state/account-w1"
            "$HOME/.claude-state/account-w2"
            "$HOME/.claude-state/account-w3"
            "$HOME/.claude-state/analysis-archive/sessions"
        )
    fi

    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_info "Already exists: $dir"
        else
            mkdir -p "$dir"
            chmod 700 "$dir"
            log_success "Created: $dir"
        fi
    done
}

# --- Docker Build -------------------------------------------------------------

build_image() {
    log_step "Building Docker image"

    cd "$PROJECT_ROOT"

    local build_args=""
    if [[ -n "$CLAUDE_VERSION" ]]; then
        build_args="--build-arg CLAUDE_CODE_VERSION=$CLAUDE_VERSION"
    fi

    log_info "Building claude-code-base:latest (this may take a few minutes)..."
    # shellcheck disable=SC2086
    docker compose build $build_args 2>&1 | tail -5

    log_success "Docker image built successfully"
}

# --- Authentication -----------------------------------------------------------

run_authentication() {
    log_step "Setting up authentication"

    if [[ "$AUTH_PATH" == "B" ]]; then
        log_success "Path B: API keys configured in .env (no browser login needed)"
        return 0
    fi

    # Path A: OAuth browser login
    log_info "Path A: Browser login required for each account"

    if ! check_command claude; then
        log_info "Installing Claude Code on host for authentication..."
        npm install -g @anthropic-ai/claude-code 2>&1 | tail -3
    fi

    local accounts=("account-a" "account-b")
    if [[ "$ORCHESTRATION" == "yes" ]]; then
        accounts+=("account-manager" "account-w1" "account-w2" "account-w3")
    fi

    for account in "${accounts[@]}"; do
        local state_dir="$HOME/.claude-state/$account"

        if [[ -f "$state_dir/.credentials.json" ]]; then
            log_info "$account: credentials already exist, skipping"
            continue
        fi

        echo -e "\n${BOLD}Authenticating: $account${NC}"
        log_info "A browser window will open for OAuth login..."

        if CLAUDE_CONFIG_DIR="$state_dir" claude auth login; then
            log_success "$account: authenticated"
        else
            log_error "$account: authentication failed"
            if ! prompt_confirm "Continue without authenticating $account?"; then
                exit 1
            fi
        fi
    done

    log_success "Authentication complete"
}

# --- Worktree Setup (Tier B) -------------------------------------------------

setup_worktrees() {
    if [[ "$TIER" != "B" ]]; then
        return 0
    fi

    log_step "Setting up git worktrees (Tier B)"

    if [[ ! -d "$SOURCE_DIR/.git" ]]; then
        log_error "$SOURCE_DIR is not a git repository. Tier B requires git."
        log_error "Switch to Tier A or initialize a git repo first."
        exit 1
    fi

    local branch_a
    local branch_b
    branch_a=$(prompt_input "Branch name for Container A" "worktree-a")
    branch_b=$(prompt_input "Branch name for Container B" "worktree-b")

    log_info "Creating worktrees..."
    "$SCRIPT_DIR/setup-worktrees.sh" "$SOURCE_DIR" "$branch_a" "$branch_b"

    local worktree_a="${SOURCE_DIR%/}-a"
    local worktree_b="${SOURCE_DIR%/}-b"

    # Update .env with worktree paths
    local env_file="$PROJECT_ROOT/.env"
    sed -i.tmp "s|^PROJECT_DIR_A=.*|PROJECT_DIR_A=$worktree_a|" "$env_file"
    sed -i.tmp "s|^PROJECT_DIR_B=.*|PROJECT_DIR_B=$worktree_b|" "$env_file"
    rm -f "${env_file}.tmp"

    log_success "Worktrees created:"
    log_info "  A: $worktree_a (branch: $branch_a)"
    log_info "  B: $worktree_b (branch: $branch_b)"
}

# --- Compose Command Builder --------------------------------------------------

build_compose_cmd() {
    local cmd="docker compose -f docker-compose.yml"

    if [[ "$PLATFORM" == "linux" ]]; then
        cmd+=" -f docker-compose.linux.yml"
    fi

    if [[ "$TIER" == "B" ]]; then
        cmd+=" -f docker-compose.worktree.yml"
    fi

    if [[ "$ORCHESTRATION" == "yes" ]]; then
        cmd+=" -f docker-compose.orchestration.yml"
    fi

    if [[ "$FIREWALL" == "yes" ]]; then
        cmd+=" -f docker-compose.firewall.yml"
    fi

    echo "$cmd"
}

# --- Container Startup --------------------------------------------------------

start_containers() {
    log_step "Starting containers"

    cd "$PROJECT_ROOT"

    local compose_cmd
    compose_cmd=$(build_compose_cmd)

    if [[ "$PLATFORM" == "linux" ]]; then
        export UID GID
        UID=$(id -u)
        GID=$(id -g)
    fi

    log_info "Compose command: $compose_cmd up -d"
    eval "$compose_cmd up -d" 2>&1

    log_success "Containers started"
}

# --- Dependency Installation --------------------------------------------------

install_dependencies() {
    log_step "Installing project dependencies in containers"

    cd "$PROJECT_ROOT"

    local compose_cmd
    compose_cmd=$(build_compose_cmd)

    local services=("claude-a" "claude-b")
    if [[ "$ORCHESTRATION" == "yes" ]]; then
        services=("manager" "worker-1" "worker-2" "worker-3")
    fi

    for svc in "${services[@]}"; do
        log_info "Installing npm dependencies in $svc..."
        if eval "$compose_cmd exec -T $svc npm install --prefix /workspace" 2>&1 | tail -3; then
            log_success "$svc: dependencies installed"
        else
            log_warn "$svc: npm install skipped or failed (project may not have package.json)"
        fi
    done
}

# --- Firewall Setup -----------------------------------------------------------

setup_firewall() {
    if [[ "$FIREWALL" != "yes" ]]; then
        return 0
    fi

    log_step "Activating outbound firewall"

    local compose_cmd
    compose_cmd=$(build_compose_cmd)

    local services=("claude-a" "claude-b")
    if [[ "$ORCHESTRATION" == "yes" ]]; then
        services=("manager" "worker-1" "worker-2" "worker-3")
    fi

    for svc in "${services[@]}"; do
        log_info "Applying firewall rules in $svc..."
        if eval "$compose_cmd exec -T $svc bash /scripts/init-firewall.sh" 2>&1 | tail -3; then
            log_success "$svc: firewall active"
        else
            log_warn "$svc: firewall setup failed (may need NET_ADMIN capability)"
        fi
    done
}

# --- Verification -------------------------------------------------------------

run_verification() {
    log_step "Verifying setup"

    cd "$PROJECT_ROOT"

    local compose_cmd
    compose_cmd=$(build_compose_cmd)
    local primary_svc="claude-a"
    [[ "$ORCHESTRATION" == "yes" ]] && primary_svc="manager"

    # Check container is running
    if eval "$compose_cmd ps --format '{{.Name}}' 2>/dev/null" | grep -q "$primary_svc"; then
        log_success "Container $primary_svc is running"
    else
        log_error "Container $primary_svc is not running"
        log_info "Check logs: $compose_cmd logs $primary_svc"
        return 1
    fi

    # Check Claude Code is available
    if eval "$compose_cmd exec -T $primary_svc claude --version" 2>/dev/null; then
        log_success "Claude Code is available"
    else
        log_warn "Could not verify Claude Code (container may still be starting)"
    fi

    # Check auth status
    if eval "$compose_cmd exec -T $primary_svc claude auth status" 2>/dev/null; then
        log_success "Authentication verified"
    else
        log_warn "Authentication not verified (may need browser login or API key check)"
    fi
}

# --- Summary ------------------------------------------------------------------

print_summary() {
    local compose_cmd
    compose_cmd=$(build_compose_cmd)

    echo ""
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo -e "${BOLD}${GREEN}  Setup Complete!${NC}"
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo ""
    echo -e "${BOLD}Configuration:${NC}"
    echo -e "  Platform:        $(platform_label "$PLATFORM")"
    echo -e "  Authentication:  Path $AUTH_PATH"
    echo -e "  Source sharing:  Tier $TIER"
    echo -e "  Orchestration:   $ORCHESTRATION"
    echo -e "  Firewall:        $FIREWALL"
    echo -e "  Project:         $SOURCE_DIR"
    echo ""
    echo -e "${BOLD}Quick Commands:${NC}"
    echo ""

    if [[ "$ORCHESTRATION" == "yes" ]]; then
        echo -e "  ${CYAN}# Enter manager container${NC}"
        echo -e "  $compose_cmd exec manager bash"
        echo ""
        echo -e "  ${CYAN}# Start Claude Code in manager${NC}"
        echo -e "  $compose_cmd exec manager claude"
        echo ""
        echo -e "  ${CYAN}# Use manager helpers${NC}"
        echo -e "  $compose_cmd exec manager bash -c 'source /scripts/manager-helpers.sh && dispatch_task worker-1 \"your prompt\"'"
    else
        echo -e "  ${CYAN}# Start Claude Code (Account A)${NC}"
        echo -e "  $compose_cmd exec claude-a claude"
        echo ""
        echo -e "  ${CYAN}# Start Claude Code (Account B) — in a separate terminal${NC}"
        echo -e "  $compose_cmd exec claude-b claude"
    fi

    echo ""
    echo -e "  ${CYAN}# Stop all containers${NC}"
    echo -e "  $compose_cmd down"
    echo ""
    echo -e "  ${CYAN}# View logs${NC}"
    echo -e "  $compose_cmd logs -f"
    echo ""

    if [[ "$AUTH_PATH" == "A" ]]; then
        echo -e "${DIM}  Token expired? Run on HOST (not in container):${NC}"
        echo -e "${DIM}  CLAUDE_CONFIG_DIR=~/.claude-state/account-a claude auth login${NC}"
    fi

    echo ""
    echo -e "${BOLD}Compose command for this setup:${NC}"
    echo -e "  ${GREEN}$compose_cmd up -d${NC}"
    echo ""
}

# --- Main ---------------------------------------------------------------------

main() {
    echo ""
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}  Claude Docker — Interactive Setup${NC}"
    echo -e "${BOLD}${CYAN}============================================${NC}"

    # Platform detection
    PLATFORM=$(detect_platform)
    if [[ "$PLATFORM" == "unknown" ]]; then
        log_error "Unsupported platform: $(uname -s)"
        exit 1
    fi
    log_info "Detected platform: $(platform_label "$PLATFORM")"

    # WSL2 specific warnings
    if [[ "$PLATFORM" == "wsl2" ]]; then
        log_warn "Windows/WSL2 detected. Ensure:"
        log_warn "  - Docker Desktop is running with WSL2 backend"
        log_warn "  - Source code is on WSL2 filesystem (not /mnt/c/)"
        echo ""
    fi

    # Collect user configuration
    collect_configuration

    # Calculate total steps based on choices
    TOTAL_STEPS=7  # base: prereqs, env, dirs, build, auth, start, verify
    [[ "$TIER" == "B" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    [[ "$FIREWALL" == "yes" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    TOTAL_STEPS=$((TOTAL_STEPS + 1))  # dependency install

    # Show configuration summary
    echo ""
    echo -e "${BOLD}Configuration Summary:${NC}"
    echo -e "  Platform:        $(platform_label "$PLATFORM")"
    echo -e "  Authentication:  Path $AUTH_PATH"
    echo -e "  Source sharing:  Tier $TIER"
    echo -e "  Orchestration:   $ORCHESTRATION"
    echo -e "  Firewall:        $FIREWALL"
    echo -e "  Project:         $SOURCE_DIR"
    echo -e "  Claude version:  ${CLAUDE_VERSION:-latest}"
    echo ""

    if ! prompt_confirm "Proceed with this configuration?" "y"; then
        log_info "Setup cancelled."
        exit 0
    fi

    # Execute setup steps
    run_prerequisite_checks
    generate_env
    create_state_dirs
    build_image
    run_authentication
    setup_worktrees
    start_containers
    install_dependencies
    setup_firewall
    run_verification
    print_summary
}

main "$@"
