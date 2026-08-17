#!/usr/bin/env bash
# test_docs_contracts.sh - documentation claims that the tree can falsify
# (issue #360).
#
# Run:  bash tests/test_docs_contracts.sh
# Exits non-zero on any failure.
#
# Two invariants, both chosen because they are the ones that actually went
# stale. Isolated mode landed across #336-#341 and added a fourth compose file;
# the documents that *enumerate* the repository were not extended with it, and
# nothing noticed because prose has no compiler. `.env.example` drifted the
# other way: six keys in real use appeared in it zero times, while README tells
# the reader to `cp .env.example .env` as the complete manual path.
#
#   1. Every git-tracked docker-compose*.yml appears in README's Project
#      Structure tree, in the recovery command, and in the overlay table.
#   2. Every ${VAR} the base compose file reads appears in .env.example.
#
# What this deliberately does not do is check prose for correctness. It checks
# enumerations -- the places where a list in a document is supposed to mirror a
# list in the tree, and where "someone added a file" is the failure mode.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

README="$PROJECT_ROOT/README.md"
ENV_EXAMPLE="$PROJECT_ROOT/.env.example"
BASE_COMPOSE="$PROJECT_ROOT/docker-compose.yml"

PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
echo "=== every generated compose file is enumerated in README ==="
# ---------------------------------------------------------------------------

# git ls-files rather than a glob: an untracked docker-compose.override.yml a
# developer left in their checkout is not something README should have to list,
# and Glob would report it.
compose_files=$(git -C "$PROJECT_ROOT" ls-files 'docker-compose*.yml' | sort)

count=$(printf '%s\n' "$compose_files" | grep -c 'docker-compose')
if [ "$count" -lt 2 ]; then
    echo "  ERROR: found $count tracked compose files; the check would be vacuous" >&2
    exit 1
fi
echo "  (checking $count tracked compose files)"

# The recovery command README gives for restoring the committed copies. It has
# to name every generated file, or following it leaves one modified and the
# `Compose files are current` job still failing.
recovery_line=$(grep -n 'git checkout -- docker-compose' "$README" | head -1)
if [ -z "$recovery_line" ]; then
    fail "README has no 'git checkout -- docker-compose' recovery command"
    recovery_line=""
fi

# The Project Structure tree.
tree_block=$(awk '/^## Project Structure/,/^## License/' "$README")
if [ -z "$tree_block" ]; then
    echo "  ERROR: could not locate the Project Structure section" >&2
    exit 1
fi

# The overlay table: rows begin with | `docker-compose...
overlay_rows=$(grep -E '^\| `docker-compose[^`]*\.yml`' "$README")

for f in $compose_files; do
    if printf '%s' "$tree_block" | grep -qF "$f"; then
        pass "$f is in the Project Structure tree"
    else
        fail "$f is missing from the Project Structure tree"
    fi

    if [ -n "$recovery_line" ]; then
        if printf '%s' "$recovery_line" | grep -qF "$f"; then
            pass "$f is in the recovery command"
        else
            fail "$f is missing from the recovery command"
        fi
    fi

    if printf '%s' "$overlay_rows" | grep -qF "$f"; then
        pass "$f has an overlay-table row"
    else
        fail "$f has no overlay-table row"
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== every variable docker-compose.yml reads is in .env.example ==="
# ---------------------------------------------------------------------------
#
# README presents `cp .env.example .env` as the complete manual path, so a
# variable the compose file reads and the template never mentions is a setting
# the user cannot discover from the documented workflow.

# Extract ${NAME} and ${NAME:-default}. The name is the leading run of
# [A-Za-z_][A-Za-z0-9_]*; anything after : or } is the default and not a name.
compose_vars=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' "$BASE_COMPOSE" \
    | sed 's/^\${//' | sort -u)

var_count=$(printf '%s\n' "$compose_vars" | grep -c '.')
if [ "$var_count" -lt 5 ]; then
    echo "  ERROR: extracted only $var_count variables; the check would be vacuous" >&2
    exit 1
fi
echo "  (checking $var_count variables read by docker-compose.yml)"

# Names the compose file reads that .env.example has no reason to carry.
#
# HOME, UID and GID come from the invoking shell rather than from .env -- UID
# and GID are documented there anyway, because install.sh writes them on Linux,
# but HOME is never a .env key.
#
# The per-account suffixed forms are generated from a base name that IS in the
# template (PROJECT_DIR_A from the PROJECT_DIR_<X> block, and so on); listing
# every letter would make the template unreadable without telling the reader
# anything new.
skip_var() {
    case "$1" in
        HOME) return 0 ;;
        # <BASE>_<LETTER>: covered by the base name's block.
        *_[A-Z]|*_[A-Z][A-Z]) return 0 ;;
        *) return 1 ;;
    esac
}

for v in $compose_vars; do
    if skip_var "$v"; then
        continue
    fi
    # Matched anywhere in the template, commented or not: these are optional
    # settings, so the documented form is a commented example.
    if grep -qE "(^|[^A-Za-z0-9_])${v}([^A-Za-z0-9_]|$)" "$ENV_EXAMPLE"; then
        pass "$v is documented in .env.example"
    else
        fail "$v is read by docker-compose.yml but absent from .env.example"
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [ "$PASS" -eq 0 ]; then
    echo "  ERROR: no assertions ran" >&2
    exit 1
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
