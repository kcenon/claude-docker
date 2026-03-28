#!/usr/bin/env bash
# Re-authentication script for claude-docker
# Manages authentication for all installed Claude Code accounts:
# - View current auth status for all accounts
# - Re-authenticate OAuth tokens (Path A)
# - Update or rotate API keys (Path B)
# - Switch individual accounts between Path A and Path B
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

STATE_ROOT="$HOME/.claude-state"

# Map account directory names to .env API key variable names
declare -A ACCOUNT_ENV_MAP=(
    ["account-a"]="CLAUDE_API_KEY_A"
    ["account-b"]="CLAUDE_API_KEY_B"
    ["account-manager"]="CLAUDE_API_KEY_MANAGER"
    ["account-w1"]="CLAUDE_API_KEY_1"
    ["account-w2"]="CLAUDE_API_KEY_2"
    ["account-w3"]="CLAUDE_API_KEY_3"
)

# Map account names to compose service names (for restart)
declare -A ACCOUNT_SERVICE_MAP=(
    ["account-a"]="claude-a"
    ["account-b"]="claude-b"
    ["account-manager"]="manager"
    ["account-w1"]="worker-1"
    ["account-w2"]="worker-2"
    ["account-w3"]="worker-3"
)

# --- Utility Functions --------------------------------------------------------

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

prompt_confirm() {
    local question="$1"
    local default="${2:-n}"
    local yn_hint="y/N"
    [[ "$default" == "y" ]] && yn_hint="Y/n"
    read -rp "$(echo -e "${YELLOW}${question} [${yn_hint}]: ${NC}")" answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

prompt_select() {
    local question="$1"
    shift
    local options=("$@")
    local choice=""
    echo -e "\n${YELLOW}${question}${NC}" > /dev/tty
    for i in "${!options[@]}"; do
        echo -e "  ${BOLD}$((i + 1)))${NC} ${options[$i]}" > /dev/tty
    done
    while true; do
        read -rp "$(echo -e "${YELLOW}> Select [1-${#options[@]}]: ${NC}")" choice < /dev/tty > /dev/tty
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice - 1))]}"
            return 0
        fi
        echo -e "${RED}  Invalid choice.${NC}" > /dev/tty
    done
}

prompt_secret() {
    local question="$1"
    local value=""
    read -rsp "$(echo -e "${YELLOW}${question}: ${NC}")" value < /dev/tty > /dev/tty
    echo "" > /dev/tty
    echo "$value"
}

# --- Account Discovery --------------------------------------------------------

discover_accounts() {
    local accounts=()
    if [[ -d "$STATE_ROOT" ]]; then
        for dir in "$STATE_ROOT"/account-*; do
            [[ -d "$dir" ]] && accounts+=("$(basename "$dir")")
        done
    fi
    echo "${accounts[@]}"
}

# --- Auth Status Detection ----------------------------------------------------

get_auth_type() {
    local account="$1"
    local state_dir="$STATE_ROOT/$account"
    local env_var="${ACCOUNT_ENV_MAP[$account]:-}"
    local env_file="$PROJECT_ROOT/.env"

    local has_oauth=false
    local has_apikey=false

    # Check OAuth credentials
    if [[ -f "$state_dir/.credentials.json" ]]; then
        has_oauth=true
    fi

    # Check API key in .env
    if [[ -n "$env_var" ]] && [[ -f "$env_file" ]]; then
        local key_value
        key_value=$(grep -E "^${env_var}=" "$env_file" 2>/dev/null | cut -d'=' -f2- || true)
        if [[ -n "$key_value" ]] && [[ "$key_value" != "sk-ant-..." ]]; then
            has_apikey=true
        fi
    fi

    if [[ "$has_apikey" == true ]]; then
        echo "api-key"  # API key takes precedence (per SRS-5.3.3)
    elif [[ "$has_oauth" == true ]]; then
        echo "oauth"
    else
        echo "none"
    fi
}

get_oauth_status() {
    local account="$1"
    local cred_file="$STATE_ROOT/$account/.credentials.json"

    if [[ ! -f "$cred_file" ]]; then
        echo "no-credentials"
        return
    fi

    local expires_at
    expires_at=$(jq -r '.claudeAiOauth.expiresAt // 0' "$cred_file" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)

    if (( expires_at > now )); then
        local remaining=$(( (expires_at - now) / 3600 ))
        echo "valid (${remaining}h remaining)"
    elif (( expires_at > 0 )); then
        # Token expired, but refresh token may still work
        echo "expired (refresh may work)"
    else
        echo "unknown"
    fi
}

get_apikey_preview() {
    local account="$1"
    local env_var="${ACCOUNT_ENV_MAP[$account]:-}"
    local env_file="$PROJECT_ROOT/.env"

    if [[ -z "$env_var" ]] || [[ ! -f "$env_file" ]]; then
        echo "not-set"
        return
    fi

    local key_value
    key_value=$(grep -E "^${env_var}=" "$env_file" 2>/dev/null | cut -d'=' -f2- || true)

    if [[ -z "$key_value" ]] || [[ "$key_value" == "sk-ant-..." ]]; then
        echo "not-set"
    else
        # Show first 12 chars + masked rest
        echo "${key_value:0:12}...${key_value: -4}"
    fi
}

# --- Display Functions --------------------------------------------------------

show_status() {
    echo ""
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}  Account Authentication Status${NC}"
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo ""

    local accounts
    read -ra accounts <<< "$(discover_accounts)"

    if [[ ${#accounts[@]} -eq 0 ]]; then
        log_warn "No accounts found in $STATE_ROOT"
        log_info "Run scripts/install.sh first to create account directories."
        return 1
    fi

    printf "  ${BOLD}%-20s %-10s %-15s %s${NC}\n" "ACCOUNT" "AUTH" "STATUS" "DETAIL"
    echo "  ────────────────────────────────────────────────────────────────"

    for account in "${accounts[@]}"; do
        local auth_type
        auth_type=$(get_auth_type "$account")
        local status=""
        local detail=""

        case "$auth_type" in
            oauth)
                status=$(get_oauth_status "$account")
                if [[ "$status" == valid* ]]; then
                    detail="${GREEN}$status${NC}"
                else
                    detail="${YELLOW}$status${NC}"
                fi
                printf "  %-20s %-10s " "$account" "OAuth"
                echo -e "$detail"
                ;;
            api-key)
                detail=$(get_apikey_preview "$account")
                printf "  %-20s %-10s ${GREEN}%-15s${NC} %s\n" "$account" "API Key" "configured" "$detail"
                ;;
            none)
                printf "  %-20s %-10s ${RED}%-15s${NC}\n" "$account" "—" "not configured"
                ;;
        esac
    done

    echo ""
}

# --- Authentication Actions ---------------------------------------------------

do_oauth_login() {
    local account="$1"
    local state_dir="$STATE_ROOT/$account"

    if ! command -v claude &>/dev/null; then
        log_error "Claude Code not installed on host. Install with: npm install -g @anthropic-ai/claude-code"
        return 1
    fi

    log_info "Starting OAuth login for $account..."
    log_info "A browser window will open for authentication."
    echo ""

    if CLAUDE_CONFIG_DIR="$state_dir" claude auth login; then
        log_success "$account: OAuth login successful"
        return 0
    else
        log_error "$account: OAuth login failed"
        return 1
    fi
}

do_set_apikey() {
    local account="$1"
    local env_var="${ACCOUNT_ENV_MAP[$account]:-}"
    local env_file="$PROJECT_ROOT/.env"

    if [[ -z "$env_var" ]]; then
        log_error "No .env variable mapping for $account"
        return 1
    fi

    local new_key
    new_key=$(prompt_secret "Enter API key for $account (sk-ant-...)")

    if [[ -z "$new_key" ]]; then
        log_error "Empty key. Cancelled."
        return 1
    fi

    if [[ ! "$new_key" =~ ^sk-ant- ]]; then
        log_warn "Key does not start with 'sk-ant-'. Proceeding anyway."
    fi

    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found at $env_file"
        log_info "Run scripts/install.sh first."
        return 1
    fi

    # Update or add the key in .env
    if grep -qE "^${env_var}=" "$env_file" 2>/dev/null; then
        # Replace existing line
        sed -i.bak "s|^${env_var}=.*|${env_var}=${new_key}|" "$env_file"
        rm -f "${env_file}.bak"
        log_success "$account: API key updated in .env ($env_var)"
    elif grep -qE "^# *${env_var}=" "$env_file" 2>/dev/null; then
        # Uncomment and set
        sed -i.bak "s|^# *${env_var}=.*|${env_var}=${new_key}|" "$env_file"
        rm -f "${env_file}.bak"
        log_success "$account: API key set in .env ($env_var)"
    else
        # Append
        echo "${env_var}=${new_key}" >> "$env_file"
        log_success "$account: API key added to .env ($env_var)"
    fi
}

do_remove_apikey() {
    local account="$1"
    local env_var="${ACCOUNT_ENV_MAP[$account]:-}"
    local env_file="$PROJECT_ROOT/.env"

    if [[ -z "$env_var" ]] || [[ ! -f "$env_file" ]]; then
        return 0
    fi

    # Comment out the key line
    if grep -qE "^${env_var}=" "$env_file" 2>/dev/null; then
        sed -i.bak "s|^${env_var}=|# ${env_var}=|" "$env_file"
        rm -f "${env_file}.bak"
        log_info "$account: API key commented out in .env"
    fi
}

do_remove_oauth() {
    local account="$1"
    local cred_file="$STATE_ROOT/$account/.credentials.json"

    if [[ -f "$cred_file" ]]; then
        rm -f "$cred_file"
        log_info "$account: OAuth credentials removed"
    fi
}

restart_service() {
    local account="$1"
    local service="${ACCOUNT_SERVICE_MAP[$account]:-}"

    if [[ -z "$service" ]]; then
        return 0
    fi

    cd "$PROJECT_ROOT"
    if docker compose ps --format '{{.Name}}' 2>/dev/null | grep -q "$service"; then
        log_info "Restarting container $service to apply new credentials..."
        docker compose restart "$service" 2>/dev/null || true
    fi
}

# --- Interactive Menu ---------------------------------------------------------

manage_single_account() {
    local account="$1"
    local auth_type
    auth_type=$(get_auth_type "$account")

    echo ""
    echo -e "${BOLD}Managing: $account${NC} (current: $auth_type)"

    local action
    action=$(prompt_select "What do you want to do?" \
        "Re-authenticate with OAuth (Path A — browser login)" \
        "Set/update API key (Path B — console key)" \
        "Switch to OAuth (remove API key, use OAuth)" \
        "Switch to API key (remove OAuth, use API key)" \
        "Skip this account")

    case "$action" in
        *"Re-authenticate with OAuth"*)
            do_oauth_login "$account"
            restart_service "$account"
            ;;
        *"Set/update API key"*)
            do_set_apikey "$account"
            restart_service "$account"
            ;;
        *"Switch to OAuth"*)
            do_remove_apikey "$account"
            do_oauth_login "$account"
            restart_service "$account"
            ;;
        *"Switch to API key"*)
            do_set_apikey "$account"
            do_remove_oauth "$account"
            restart_service "$account"
            ;;
        *"Skip"*)
            log_info "Skipped $account"
            ;;
    esac
}

# --- Batch Operations ---------------------------------------------------------

batch_oauth_reauth() {
    local accounts
    read -ra accounts <<< "$(discover_accounts)"

    log_info "Re-authenticating all accounts via OAuth..."
    echo ""

    for account in "${accounts[@]}"; do
        echo -e "${BOLD}--- $account ---${NC}"
        if prompt_confirm "Re-authenticate $account?"; then
            do_oauth_login "$account"
            restart_service "$account"
        else
            log_info "Skipped $account"
        fi
        echo ""
    done
}

batch_apikey_update() {
    local accounts
    read -ra accounts <<< "$(discover_accounts)"

    log_info "Updating API keys for all accounts..."
    echo ""

    for account in "${accounts[@]}"; do
        local env_var="${ACCOUNT_ENV_MAP[$account]:-}"
        [[ -z "$env_var" ]] && continue

        echo -e "${BOLD}--- $account ($env_var) ---${NC}"
        if prompt_confirm "Update API key for $account?"; then
            do_set_apikey "$account"
            restart_service "$account"
        else
            log_info "Skipped $account"
        fi
        echo ""
    done
}

batch_verify_all() {
    local accounts
    read -ra accounts <<< "$(discover_accounts)"

    log_info "Verifying authentication for all running containers..."
    echo ""

    cd "$PROJECT_ROOT"
    for account in "${accounts[@]}"; do
        local service="${ACCOUNT_SERVICE_MAP[$account]:-}"
        [[ -z "$service" ]] && continue

        printf "  %-20s %-15s " "$account" "$service"

        if ! docker compose ps --format '{{.Name}}' 2>/dev/null | grep -q "$service"; then
            echo -e "${DIM}not running${NC}"
            continue
        fi

        local result
        result=$(docker compose exec -T "$service" claude auth status 2>&1 || true)

        if echo "$result" | grep -qi "authenticated\|logged in\|active"; then
            echo -e "${GREEN}authenticated${NC}"
        elif echo "$result" | grep -qi "api.key\|API"; then
            echo -e "${GREEN}api-key active${NC}"
        else
            echo -e "${RED}not authenticated${NC}"
        fi
    done
    echo ""
}

# --- Main Menu ----------------------------------------------------------------

show_menu() {
    echo ""
    local choice
    choice=$(prompt_select "Choose an action:" \
        "View all account status" \
        "Manage a single account" \
        "Re-authenticate ALL accounts (OAuth)" \
        "Update ALL API keys" \
        "Verify auth in running containers" \
        "Exit")

    case "$choice" in
        *"View all"*)
            show_status
            show_menu
            ;;
        *"Manage a single"*)
            local accounts
            read -ra accounts <<< "$(discover_accounts)"
            if [[ ${#accounts[@]} -eq 0 ]]; then
                log_warn "No accounts found."
                show_menu
                return
            fi
            local selected
            selected=$(prompt_select "Select account:" "${accounts[@]}")
            manage_single_account "$selected"
            show_menu
            ;;
        *"Re-authenticate ALL"*)
            batch_oauth_reauth
            show_menu
            ;;
        *"Update ALL API"*)
            batch_apikey_update
            show_menu
            ;;
        *"Verify auth"*)
            batch_verify_all
            show_menu
            ;;
        *"Exit"*)
            echo ""
            log_info "Done."
            ;;
    esac
}

# --- Main ---------------------------------------------------------------------

main() {
    echo ""
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}  Claude Docker — Authentication Manager${NC}"
    echo -e "${BOLD}${CYAN}============================================${NC}"

    # Show current status first
    show_status || exit 1

    # Interactive menu
    show_menu
}

main "$@"
