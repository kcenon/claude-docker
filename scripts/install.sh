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
SOURCE_DIR=""
CLAUDE_VERSION=""
API_KEY_A=""
API_KEY_B=""

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

    # UI output goes to /dev/tty so it's visible even inside $(...) substitution
    echo -e "\n${YELLOW}${question}${NC}" > /dev/tty
    for i in "${!options[@]}"; do
        echo -e "  ${BOLD}$((i + 1)))${NC} ${options[$i]}" > /dev/tty
    done

    while true; do
        read -rp "$(echo -e "${YELLOW}> Select [1-${#options[@]}]: ${NC}")" choice < /dev/tty > /dev/tty
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            # Only the selected value goes to stdout (captured by caller)
            echo "${options[$((choice - 1))]}"
            return 0
        fi
        echo -e "${RED}  Invalid choice. Please enter 1-${#options[@]}.${NC}" > /dev/tty
    done
}

prompt_input() {
    local question="$1"
    local default="${2:-}"
    local value=""

    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${YELLOW}${question} [${default}]: ${NC}")" value < /dev/tty > /dev/tty
        echo "${value:-$default}"
    else
        while [[ -z "$value" ]]; do
            read -rp "$(echo -e "${YELLOW}${question}: ${NC}")" value < /dev/tty > /dev/tty
            [[ -z "$value" ]] && echo -e "${RED}  This field is required.${NC}" > /dev/tty
        done
        echo "$value"
    fi
}

prompt_secret() {
    local question="$1"
    local value=""
    read -rsp "$(echo -e "${YELLOW}${question}: ${NC}")" value < /dev/tty > /dev/tty
    echo "" > /dev/tty
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

# Measure filesystem I/O latency with a single write+read+delete cycle.
# Returns latency in milliseconds.
measure_io_latency() {
    local dir="$1"
    local tmp_file="${dir}/.io_benchmark_$$"

    if date +%s%N 2>/dev/null | grep -qE '^[0-9]{10,}$'; then
        # Linux: nanosecond precision
        local start_ns end_ns
        start_ns=$(date +%s%N)
        printf '%0.s0' {1..4096} > "$tmp_file" 2>/dev/null
        sync 2>/dev/null || true
        cat "$tmp_file" > /dev/null 2>&1
        rm -f "$tmp_file"
        end_ns=$(date +%s%N)
        echo $(( (end_ns - start_ns) / 1000000 ))
    else
        # macOS: use perl for sub-second timing
        perl -MTime::HiRes=time -e '
            my $f = "'"$tmp_file"'";
            my $s = time();
            open(my $fh, ">", $f) and print $fh "0"x4096 and close($fh);
            open($fh, "<", $f) and my @d = <$fh> and close($fh);
            unlink $f;
            printf "%d\n", (time() - $s) * 1000;
        ' 2>/dev/null || echo "0"
    fi
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
    if ! check_command docker; then
        # State 1: Not installed
        return 1
    fi

    local version
    version=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)

    # State 2 or 3: Installed — check if daemon is running
    if docker info &>/dev/null; then
        # State 3: Installed + running
        log_success "Docker $version detected and running"
        return 0
    fi

    # State 2: Installed but daemon not running
    log_warn "Docker $version installed but daemon is not running"
    start_docker_daemon
}

start_docker_daemon() {
    case "$PLATFORM" in
        macos)
            if [[ -d "/Applications/Docker.app" ]]; then
                log_info "Starting Docker Desktop..."
                open -a Docker
                log_info "Waiting for Docker daemon to start (up to 60s)..."
                local elapsed=0
                while ! docker info &>/dev/null && (( elapsed < 60 )); do
                    sleep 2
                    elapsed=$((elapsed + 2))
                    printf "." > /dev/tty
                done
                echo "" > /dev/tty
                if docker info &>/dev/null; then
                    log_success "Docker Desktop is now running"
                    return 0
                else
                    log_error "Docker Desktop failed to start within 60 seconds"
                    log_info "Please start Docker Desktop manually and re-run this script."
                    return 1
                fi
            else
                log_error "Docker Desktop app not found at /Applications/Docker.app"
                log_info "Please install Docker Desktop: https://www.docker.com/products/docker-desktop/"
                return 1
            fi
            ;;
        linux)
            log_info "Starting Docker daemon via systemctl..."
            if check_command systemctl; then
                sudo systemctl start docker 2>/dev/null && {
                    sleep 2
                    if docker info &>/dev/null; then
                        log_success "Docker daemon started"
                        return 0
                    fi
                }
            fi
            # Fallback: try service command
            if check_command service; then
                sudo service docker start 2>/dev/null && {
                    sleep 2
                    if docker info &>/dev/null; then
                        log_success "Docker daemon started"
                        return 0
                    fi
                }
            fi
            log_error "Failed to start Docker daemon"
            log_info "Try manually: sudo systemctl start docker"
            return 1
            ;;
        wsl2)
            log_info "Checking Docker Desktop WSL2 integration..."
            # WSL2 relies on Docker Desktop running on the Windows host
            log_warn "Docker Desktop must be running on the Windows host."
            log_info "Please start Docker Desktop from the Windows Start menu,"
            log_info "ensure WSL2 integration is enabled (Settings > Resources > WSL integration),"
            log_info "then re-run this script."
            return 1
            ;;
    esac
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
                        log_info "Installing Docker Desktop via Homebrew Cask..."
                        if brew install --cask docker; then
                            log_success "Docker Desktop installed"
                            log_info "Starting Docker Desktop for the first time..."
                            open -a Docker
                            log_info "Waiting for Docker daemon to initialize (up to 90s)..."
                            local elapsed=0
                            while ! docker info &>/dev/null && (( elapsed < 90 )); do
                                sleep 3
                                elapsed=$((elapsed + 3))
                                printf "." > /dev/tty
                            done
                            echo "" > /dev/tty
                            if docker info &>/dev/null; then
                                log_success "Docker Desktop is running"
                            else
                                log_warn "Docker Desktop installed but not yet ready."
                                log_info "Please finish Docker Desktop setup and re-run this script."
                                return 1
                            fi
                        else
                            log_error "Homebrew cask install failed."
                            log_info "Install manually: https://www.docker.com/products/docker-desktop/"
                            return 1
                        fi
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

    # Node.js no longer required on host — auth happens inside containers

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_success "All prerequisites satisfied"
        # Soft check: Node.js for host-side usage tracking (not required for core functionality)
        if ! check_command npx; then
            log_warn "Node.js/npx not found on host. The 'usage' subcommand requires it."
            log_info "Install Node.js for token usage reports: https://nodejs.org/"
        fi
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

    # I/O latency benchmark
    local io_latency_ms
    io_latency_ms=$(measure_io_latency "$SOURCE_DIR")
    if (( io_latency_ms > 50 )); then
        log_warn "Slow I/O detected (${io_latency_ms}ms). NTFS mounts can be up to 27x slower than native."
        log_warn "Consider using WSL2 ext4 filesystem or a local SSD."
    else
        log_success "I/O latency: ${io_latency_ms}ms (OK)"
    fi

    log_info "Project directory: $SOURCE_DIR"

    # Claude Code version
    CLAUDE_VERSION=$(prompt_input "Claude Code version (enter specific version or 'latest')" "latest")
    if [[ "$CLAUDE_VERSION" == "latest" ]]; then
        CLAUDE_VERSION=""
        log_info "Claude Code version: latest"
    else
        log_info "Claude Code version: $CLAUDE_VERSION"
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

    } > "$env_file"

    chmod 600 "$env_file"
    log_success ".env generated at $env_file (permissions: 600)"
}

# --- Directory Creation -------------------------------------------------------

create_state_dirs() {
    log_step "Creating state directories"

    local dirs=(
        "$HOME/.claude-state/account-a"
        "$HOME/.claude-state/account-b"
        "$HOME/.claude"
    )

    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            # Enforce permissions on existing dirs (may have been created with defaults)
            chmod 700 "$dir"
            log_info "Already exists (permissions enforced): $dir"
        else
            mkdir -p "$dir"
            chmod 700 "$dir"
            log_success "Created: $dir"
        fi
    done

    # Harden any existing credential files (Path A OAuth stores .credentials.json)
    local cred_files
    cred_files=$(find "$HOME/.claude-state" -name "*.credentials.json" -o -name ".credentials.json" 2>/dev/null || true)
    if [[ -n "$cred_files" ]]; then
        while IFS= read -r cfile; do
            chmod 600 "$cfile"
        done <<< "$cred_files"
        log_success "Credential file permissions set to 600"
    fi
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

    # Path A: OAuth — authenticate inside containers, not on the host.
    # On macOS, host 'claude auth login' stores tokens in Keychain which
    # cannot be bind-mounted into Linux containers. Container-internal auth
    # stores tokens in .credentials.json inside the bind-mounted state dir,
    # ensuring persistence across restarts.
    log_info "Path A: OAuth will be configured inside containers after startup"
    log_info "Each container stores credentials in its bind-mounted state directory"
    log_info "You will authenticate when running 'claude' for the first time in each container"
    log_success "Authentication will be handled after container startup"
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

    for svc in "${services[@]}"; do
        log_info "Installing npm dependencies in $svc..."
        if eval "$compose_cmd exec -T $svc npm install" 2>&1 | tail -3; then
            log_success "$svc: dependencies installed"
        else
            log_warn "$svc: npm install skipped or failed (project may not have package.json)"
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
    echo -e "  Project:         $SOURCE_DIR"
    echo ""
    echo -e "${BOLD}Quick Commands (via CLI wrapper):${NC}"
    echo ""
    echo -e "  ${CYAN}# Start Claude Code${NC}"
    echo -e "  scripts/claude-docker claude"
    echo ""

    echo -e "  ${CYAN}# Start second account (separate terminal)${NC}"
    echo -e "  scripts/claude-docker claude claude-b"

    echo ""
    echo -e "  ${CYAN}# Container management${NC}"
    echo -e "  scripts/claude-docker ps       ${DIM}# status${NC}"
    echo -e "  scripts/claude-docker logs     ${DIM}# follow logs${NC}"
    echo -e "  scripts/claude-docker down     ${DIM}# stop all${NC}"
    echo -e "  scripts/claude-docker restart  ${DIM}# restart all${NC}"
    echo ""
    echo -e "  ${CYAN}# See all commands${NC}"
    echo -e "  scripts/claude-docker help"
    echo ""

    if [[ "$AUTH_PATH" == "A" ]]; then
        echo -e "${DIM}  First run? Authenticate inside the container:${NC}"
        echo -e "${DIM}  scripts/claude-docker claude${NC}"
        echo -e "${DIM}  (Follow the OAuth prompt — credentials persist in bind-mounted state dir)${NC}"
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
    TOTAL_STEPS=8  # prereqs, env, dirs, build, auth, start, deps, verify
    [[ "$TIER" == "B" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))

    # Show configuration summary
    echo ""
    echo -e "${BOLD}Configuration Summary:${NC}"
    echo -e "  Platform:        $(platform_label "$PLATFORM")"
    echo -e "  Authentication:  Path $AUTH_PATH"
    echo -e "  Source sharing:  Tier $TIER"
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
    run_verification
    print_summary
}

main "$@"
