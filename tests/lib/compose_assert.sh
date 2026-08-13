#!/usr/bin/env bash
# compose_assert.sh — Resolved-compose assertions for isolation tests.
#
# Library file meant to be `source`d, but the shebang serves as an
# unambiguous shell directive for tooling (shellcheck SC2148).
#
# Issue #335 requires mount correctness to be asserted against the model
# `docker compose config` resolves, never against the source YAML. That is not
# a stylistic preference: the overlay defect this helper exists to catch was
# invisible in source form. docker-compose.worktree.yml named only the
# per-account worktree mount and looked correct; the inherited shared
# ${PROJECT_DIR} mount appeared only after Compose merged the two files by
# container target. A grep over the overlay would have reported success.
#
# Public functions:
#   compose_assert_requires        # skip/fail policy for missing docker or jq
#   resolved_service_mounts DIR SERVICE FILE...
#   resolved_mount_targets  DIR SERVICE FILE...
#   resolved_mount_sources  DIR SERVICE FILE...
#
# Callers own their own PASS/FAIL counters; these functions only report facts.

# Guard against double-sourcing.
if [[ -n "${_CLAUDE_DOCKER_COMPOSE_ASSERT_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_COMPOSE_ASSERT_SH_SOURCED=1

# compose_assert_requires
# Report whether the resolved-compose assertions can run at all.
#   0  docker and jq are both usable
#   1  a tool is missing and the caller should skip those assertions
#
# In CI a missing tool is a defect rather than an environment quirk, so this
# fails the run outright instead of returning a skip. That mirrors how
# test_compose_generator_equivalence.sh treats a missing pwsh: a dev host may
# lack the tool, a runner may not, and a hollow pass is worse than either.
compose_assert_requires() {
    local missing=()
    command -v docker >/dev/null 2>&1 || missing+=(docker)
    command -v jq >/dev/null 2>&1 || missing+=(jq)

    if [[ "${#missing[@]}" -eq 0 ]]; then
        return 0
    fi

    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "FAIL: ${missing[*]} unavailable in CI (both are preinstalled on ubuntu-latest)" >&2
        exit 1
    fi
    echo "NOTE: ${missing[*]} not installed locally; skipping resolved-compose assertions" >&2
    return 1
}

# resolved_service_mounts DIR SERVICE FILE...
# Print one "TYPE|SOURCE|TARGET" line per mount that SERVICE carries in the
# fully resolved model. Compose runs with DIR as its working directory so the
# sandbox's own .env and relative paths resolve exactly as they would for a
# user standing in that directory.
#
# Volume entries are normalized to the long syntax by `config`, so `source` is
# absent for anonymous volumes; it is emitted as an empty field rather than
# dropped, keeping the column count fixed for callers that split on '|'.
resolved_service_mounts() {
    local dir="$1" service="$2"
    shift 2

    local file_args=() f
    for f in "$@"; do
        file_args+=(-f "$f")
    done

    (cd "$dir" && docker compose "${file_args[@]}" config --format json) \
        | jq -r --arg svc "$service" '
            .services[$svc].volumes // []
            | .[]
            | [(.type // ""), (.source // ""), (.target // "")]
            | join("|")
        '
}

# resolved_mount_targets DIR SERVICE FILE...
# Print just the container-side target of every mount, one per line.
resolved_mount_targets() {
    resolved_service_mounts "$@" | cut -d'|' -f3
}

# resolved_mount_sources DIR SERVICE FILE...
# Print just the host-side source of every mount, one per line. Anonymous
# volumes contribute an empty line.
resolved_mount_sources() {
    resolved_service_mounts "$@" | cut -d'|' -f2
}
