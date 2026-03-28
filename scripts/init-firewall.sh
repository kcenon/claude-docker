#!/usr/bin/env bash
# Outbound firewall for Claude Code containers (SRS-7.3, SDS Section 3.4)
# Restricts egress to only whitelisted services: DNS, SSH, npm, GitHub, Anthropic API.
# Modeled after: https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "[dry-run] Rules will be printed but NOT applied."
fi

# Domains allowed for HTTPS (port 443) egress
ALLOWED_DOMAINS=(
    "registry.npmjs.org"
    "registry.npmmirror.com"
    "github.com"
    "api.github.com"
    "api.anthropic.com"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Wrapper: execute iptables or print the command in dry-run mode
ipt() {
    if $DRY_RUN; then
        echo "[dry-run] iptables $*"
    else
        iptables "$@"
    fi
}

log() { echo ":: $*"; }

die() { echo "ERROR: $*" >&2; exit 1; }

# Resolve a hostname to its A-record IPv4 addresses.
# Falls back from dig -> host -> getent depending on what is installed.
resolve() {
    local domain="$1"
    local ips=""

    if command -v dig &>/dev/null; then
        ips=$(dig +short +tries=3 +time=5 A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    elif command -v host &>/dev/null; then
        ips=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF}')
    elif command -v getent &>/dev/null; then
        ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    fi

    if [[ -z "$ips" ]]; then
        die "Failed to resolve $domain — check DNS connectivity"
    fi
    echo "$ips"
}

# Validate an IPv4 address (basic check)
valid_ip() {
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if ! command -v iptables &>/dev/null; then
    die "iptables not found. Install iptables or run inside a container with NET_ADMIN."
fi

# Verify we actually have permission to manipulate iptables
if ! $DRY_RUN; then
    if ! iptables -L -n &>/dev/null 2>&1; then
        die "Cannot run iptables. Ensure the container has cap_add: [NET_ADMIN, NET_RAW]."
    fi
fi

# ---------------------------------------------------------------------------
# Phase 1: Preserve Docker DNS NAT rules, then flush everything
# ---------------------------------------------------------------------------

if ! $DRY_RUN; then
    log "Saving Docker DNS NAT rules (if any)..."
    DOCKER_DNS_RULES=$(iptables-save -t nat 2>/dev/null | grep "127\.0\.0\.11" || true)

    log "Flushing existing rules (idempotent reset)..."
    iptables -F
    iptables -X 2>/dev/null || true
    iptables -t nat -F
    iptables -t nat -X 2>/dev/null || true
    iptables -t mangle -F
    iptables -t mangle -X 2>/dev/null || true

    # Restore Docker embedded DNS resolution
    if [[ -n "${DOCKER_DNS_RULES:-}" ]]; then
        log "Restoring Docker DNS NAT rules..."
        iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
        iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
        echo "$DOCKER_DNS_RULES" | while IFS= read -r rule; do
            [[ -n "$rule" ]] && iptables -t nat $rule 2>/dev/null || true
        done
    fi
fi

# ---------------------------------------------------------------------------
# Phase 2: Allow essential traffic before setting DROP policy
# ---------------------------------------------------------------------------

log "Allowing loopback traffic..."
ipt -A INPUT  -i lo -j ACCEPT
ipt -A OUTPUT -o lo -j ACCEPT

log "Allowing established/related connections..."
ipt -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
ipt -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

log "Allowing DNS (UDP+TCP port 53)..."
ipt -A OUTPUT -p udp --dport 53 -j ACCEPT
ipt -A OUTPUT -p tcp --dport 53 -j ACCEPT
# DNS responses are handled by the ESTABLISHED,RELATED rule above;
# no separate INPUT sport-53 rule needed (avoids INPUT bypass risk).

log "Allowing SSH (port 22) for git operations..."
ipt -A OUTPUT -p tcp --dport 22 -j ACCEPT

# ---------------------------------------------------------------------------
# Phase 3: Allow host/Docker network traffic
# ---------------------------------------------------------------------------

HOST_IP=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}' || true)
if [[ -n "$HOST_IP" ]]; then
    HOST_NETWORK=$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.0\/24/')
    log "Allowing Docker host network ($HOST_NETWORK)..."
    ipt -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
    ipt -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
fi

# ---------------------------------------------------------------------------
# Phase 4: Resolve whitelisted domains and allow HTTPS to their IPs
# ---------------------------------------------------------------------------

log "Resolving whitelisted domains and adding HTTPS rules..."

for domain in "${ALLOWED_DOMAINS[@]}"; do
    log "  Resolving $domain..."
    ips=$(resolve "$domain")

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if ! valid_ip "$ip"; then
            echo "  WARNING: Skipping invalid IP '$ip' for $domain"
            continue
        fi
        log "    Allow $ip ($domain)"
        ipt -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
    done <<< "$ips"
done

# ---------------------------------------------------------------------------
# Phase 5: Log and reject everything else
# ---------------------------------------------------------------------------

log "Adding LOG rule for blocked outbound traffic..."
ipt -A OUTPUT -m limit --limit 5/min -j LOG \
    --log-prefix "FIREWALL_BLOCKED: " --log-level 4

log "Setting default OUTPUT policy to DROP..."
ipt -P INPUT   DROP
ipt -P FORWARD DROP
ipt -P OUTPUT  DROP

# Explicit REJECT at the end for faster feedback to blocked connections
ipt -A OUTPUT -j REJECT --reject-with icmp-port-unreachable

log "Firewall configuration complete."

# ---------------------------------------------------------------------------
# Phase 6: Verification (skip in dry-run)
# ---------------------------------------------------------------------------

if ! $DRY_RUN; then
    log "Verifying firewall..."

    # Blocked host should fail
    if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
        die "Verification FAILED — example.com is reachable (should be blocked)"
    else
        log "  PASS: example.com is blocked"
    fi

    # Allowed host should succeed
    if curl --connect-timeout 5 -s https://api.github.com/zen >/dev/null 2>&1; then
        log "  PASS: api.github.com is reachable"
    else
        echo "  WARNING: api.github.com unreachable — GitHub IPs may have changed"
    fi

    log "Firewall active. Use 'iptables -L -n -v' to inspect rules."
fi
