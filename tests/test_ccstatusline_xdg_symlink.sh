#!/usr/bin/env bash
# test_ccstatusline_xdg_symlink.sh — Verify the XDG symlink block in
# scripts/entrypoint.sh works under the conditions that broke it in
# production:
#
#   1. Symlink gets created when $XDG_CCSL is writable and a source
#      settings.json exists at $ACCOUNT_DIR/ccstatusline/.
#   2. Stale symlink pointing at a moved target is replaced on restart.
#   3. When $XDG_CCSL is owned by another UID and not writable, the
#      entrypoint prints the "could not create XDG symlink" warning to
#      stderr — the signal that tells users their statusline is missing
#      because of a permission mismatch, not a ccstatusline bug.
#
# Why this file exists: the original XDG fix (commit 9af34d5) was silently
# regressed when docker-compose.yml switched to `user: "${UID}:${GID}"`
# (commit a09f997), because the Dockerfile chown'd the dir to node:node
# and the container now runs as the host UID. The regression was invisible
# — ccstatusline kept running, just with its hardcoded default layout.
# This test codifies the path so the next regression trips in CI.
#
# Run: bash tests/test_ccstatusline_xdg_symlink.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$SCRIPT_DIR/../scripts/entrypoint.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

fail() { echo -e "  ${RED}FAIL${NC}: $*"; FAIL=$((FAIL + 1)); }
pass() { echo -e "  ${GREEN}PASS${NC}: $*"; PASS=$((PASS + 1)); }

# Mini fixture builder: lay out a host CONFIG_SOURCE and ACCOUNT_DIR with
# a known ccstatusline settings.json, plus a target XDG_CCSL dir under
# the caller-provided permissions mode.
make_fixture() {
    local root="$1" xdg_mode="${2:-755}"
    mkdir -p "$root/config-source/ccstatusline"
    mkdir -p "$root/account/ccstatusline"
    mkdir -p "$root/xdg"
    printf '{"version":3,"lines":[[{"id":"1","type":"model"}]]}\n' \
        > "$root/config-source/ccstatusline/settings.json"
    # Account dir mirrors config source via a symlink (matches what the
    # earlier loop in entrypoint.sh sets up).
    ln -sfn "$root/config-source/ccstatusline/settings.json" \
        "$root/account/ccstatusline/settings.json"
    chmod "$xdg_mode" "$root/xdg"
}

# Run the XDG block of entrypoint.sh against a fabricated environment.
# We extract the block (lines between the "Symlink ccstatusline" marker
# and the closing "fi" that matches it) instead of sourcing the whole
# entrypoint, which would try to create /home/node paths and call
# generate_container_settings on unrelated inputs.
run_xdg_block() {
    local root="$1"
    local xdg="$root/xdg" account="$root/account" src="$root/config-source"

    # Shim the paths the block hardcodes. XDG_CCSL is a local var in the
    # real script; we override by redefining the literal via sed.
    local tmp_block
    tmp_block=$(mktemp)
    awk '
        /# Symlink ccstatusline config to XDG path/ { capture=1 }
        capture { print }
        capture && /^    fi$/ { exit }
    ' "$ENTRYPOINT" > "$tmp_block"

    # Redirect the block's hardcoded /home/node/.config/ccstatusline to
    # our fixture. The block also references $ACCOUNT_DIR and
    # $CONFIG_SOURCE — those we set via env so no patching is needed.
    sed -i.bak "s|/home/node/.config/ccstatusline|$xdg/ccstatusline|g" "$tmp_block"

    ACCOUNT_DIR="$account" CONFIG_SOURCE="$src" bash "$tmp_block" 2>"$root/stderr"
    local rc=$?
    rm -f "$tmp_block" "$tmp_block.bak"
    return $rc
}

# ---------------------------------------------------------------------------
echo "== Test 1: fresh writable XDG dir → symlink created =="
# ---------------------------------------------------------------------------
ROOT=$(mktemp -d)
make_fixture "$ROOT"
run_xdg_block "$ROOT" || fail "block exited non-zero on happy path"

if [ -L "$ROOT/xdg/ccstatusline/settings.json" ]; then
    target=$(readlink "$ROOT/xdg/ccstatusline/settings.json")
    if [ "$target" = "$ROOT/account/ccstatusline/settings.json" ]; then
        pass "symlink points to ACCOUNT_DIR source"
    else
        fail "symlink points to $target (expected account source)"
    fi
else
    fail "no symlink created at $ROOT/xdg/ccstatusline/settings.json"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
echo "== Test 2: stale symlink to removed target is replaced =="
# ---------------------------------------------------------------------------
ROOT=$(mktemp -d)
make_fixture "$ROOT"
# Pre-populate with a stale symlink to a nonexistent path — simulates a
# container restart after CLAUDE_CONFIG_SOURCE was redirected. The parent
# dir must exist first; make_fixture creates xdg/ but not xdg/ccstatusline/.
mkdir -p "$ROOT/xdg/ccstatusline"
ln -sfn "/nonexistent/old/settings.json" "$ROOT/xdg/ccstatusline/settings.json"
run_xdg_block "$ROOT"

new_target=$(readlink "$ROOT/xdg/ccstatusline/settings.json" 2>/dev/null || echo "")
if [ "$new_target" = "$ROOT/account/ccstatusline/settings.json" ]; then
    pass "stale symlink rewritten to current source"
else
    fail "stale symlink not replaced (points to '$new_target')"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
echo "== Test 3: unwritable XDG dir → warning on stderr, no crash =="
# ---------------------------------------------------------------------------
ROOT=$(mktemp -d)
make_fixture "$ROOT"
# Drop write perms on xdg/ccstatusline to simulate the chown+UID mismatch
# that caused the production regression. We cannot change ownership
# without root, but removing write bits for the current user achieves the
# same EACCES from ln(1)'s perspective.
mkdir -p "$ROOT/xdg/ccstatusline"
chmod 555 "$ROOT/xdg/ccstatusline"
run_xdg_block "$ROOT"
block_rc=$?

if [ "$block_rc" -eq 0 ]; then
    pass "block exits cleanly even when symlink cannot be created"
else
    fail "block failed with rc=$block_rc (should degrade gracefully)"
fi

if grep -q "could not create XDG symlink" "$ROOT/stderr"; then
    pass "warning printed to stderr"
else
    fail "no warning printed (stderr: $(cat "$ROOT/stderr"))"
fi

# Restore perms so mktemp cleanup can remove the tree.
chmod 755 "$ROOT/xdg/ccstatusline"
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
echo "== Test 4: CONFIG_SOURCE fallback when ACCOUNT_DIR is empty =="
# ---------------------------------------------------------------------------
ROOT=$(mktemp -d)
make_fixture "$ROOT"
# Remove the account-side settings so only CONFIG_SOURCE is available.
rm -f "$ROOT/account/ccstatusline/settings.json"
run_xdg_block "$ROOT"

target=$(readlink "$ROOT/xdg/ccstatusline/settings.json" 2>/dev/null || echo "")
if [ "$target" = "$ROOT/config-source/ccstatusline/settings.json" ]; then
    pass "falls back to CONFIG_SOURCE when ACCOUNT_DIR lacks settings.json"
else
    fail "fallback did not reach CONFIG_SOURCE (target='$target')"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
