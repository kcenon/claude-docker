#!/usr/bin/env bash
# index.sh — Shared account-index helpers.
#
# Library file meant to be `source`d. The shebang doubles as a shellcheck
# shell directive (SC2148). Provides a single definition of:
#
#   index_to_letter N   1-based index → Excel-style lowercase (a, z, aa, zz)
#   index_to_upper  N   1-based index → Excel-style uppercase (A, Z, AA, ZZ)
#
# Values 1-26 are bit-for-bit identical to the former single-letter
# implementation that used to live in each consumer. The upper bound 702
# matches scripts/install.sh's NUM_ACCOUNTS validator.
#
# Consumers that also want get_service_names should source this file and
# implement the loop locally — they already vary on whether to read
# NUM_ACCOUNTS from .env or from a parameter, so there's no clean helper.

if [[ -n "${_CLAUDE_DOCKER_INDEX_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_INDEX_SH_SOURCED=1

index_to_letter() {
    local n="$1"
    local out=""
    local rem
    while (( n > 0 )); do
        rem=$(( (n - 1) % 26 ))
        out=$(printf "\\$(printf '%03o' $((97 + rem)))")$out
        n=$(( (n - 1) / 26 ))
    done
    printf '%s' "$out"
}

index_to_upper() {
    local n="$1"
    local out=""
    local rem
    while (( n > 0 )); do
        rem=$(( (n - 1) % 26 ))
        out=$(printf "\\$(printf '%03o' $((65 + rem)))")$out
        n=$(( (n - 1) / 26 ))
    done
    printf '%s' "$out"
}
