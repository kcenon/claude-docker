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
#   resolved_mount_manifest DIR FILE...
#   duplicate_writable_sources DIR FILE...
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

# resolved_service_hardening DIR SERVICE FILE...
# Print the container-hardening fields of one resolved service as KEY=VALUE
# lines. List-valued fields are rendered as sorted compact JSON so a caller can
# match the whole list exactly instead of grepping for a substring -- the
# difference between asserting "all capabilities are dropped" and accepting a
# list that merely mentions ALL among others.
resolved_service_hardening() {
    local dir="$1" service="$2"
    shift 2

    local file_args=() f
    for f in "$@"; do
        file_args+=(-f "$f")
    done

    (cd "$dir" && docker compose "${file_args[@]}" config --format json) \
        | jq -r --arg svc "$service" '
            .services[$svc] as $s
            | [
                "user=\($s.user // "")",
                "read_only=\($s.read_only // false)",
                "init=\($s.init // false)",
                "pids=\($s.deploy.resources.limits.pids // "")",
                "cap_drop=\(($s.cap_drop // []) | sort | tostring)",
                "security_opt=\(($s.security_opt // []) | sort | tostring)",
                "git_config_global=\($s.environment.GIT_CONFIG_GLOBAL // "")"
              ]
            | .[]
        '
}

# resolved_service_tmpfs DIR SERVICE FILE...
# Print one tmpfs entry per line, as it appears in the resolved model
# (`TARGET` or `TARGET:OPTIONS`). Callers that only care about the mount point
# should `cut -d: -f1`.
resolved_service_tmpfs() {
    local dir="$1" service="$2"
    shift 2

    local file_args=() f
    for f in "$@"; do
        file_args+=(-f "$f")
    done

    (cd "$dir" && docker compose "${file_args[@]}" config --format json) \
        | jq -r --arg svc "$service" '.services[$svc].tmpfs // [] | .[]'
}

# resolved_mount_manifest DIR FILE...
# Print one "SERVICE|TYPE|SOURCE|TARGET|ACCESS" line per mount across every
# service in the resolved model, sorted so the output is stable to diff.
# ACCESS is `ro` or `rw`.
#
# This is the machine-readable mount manifest issue #335 asks tests to produce.
# Per-service assertions answer "does account A have what it should"; only a
# whole-model view can answer the cross-account question, which is whether any
# host path is writable from two accounts at once.
resolved_mount_manifest() {
    local dir="$1"
    shift

    local file_args=() f
    for f in "$@"; do
        file_args+=(-f "$f")
    done

    (cd "$dir" && docker compose "${file_args[@]}" config --format json) \
        | jq -r '
            .services
            | to_entries[]
            | .key as $svc
            | (.value.volumes // [])[]
            | [
                $svc,
                (.type // ""),
                (.source // ""),
                (.target // ""),
                (if .read_only then "ro" else "rw" end)
              ]
            | join("|")
        ' \
        | sort
}

# duplicate_writable_sources DIR FILE...
# Print every host path that more than one service bind-mounts writable, one
# per line. Empty output is the pass condition: no account can reach another's
# workspace or state through a shared host path.
#
# Read-only binds are deliberately excluded. A shared read-only mount is a
# capability question (which config does an account see) rather than a
# containment breach, and shared modes legitimately have several.
#
# Named volumes are excluded too: `node_modules_a` is per-account by name, and
# a genuinely shared named volume would show up as the same source in two
# services only if the generator emitted it that way, which the per-service
# assertions already cover.
duplicate_writable_sources() {
    resolved_mount_manifest "$@" \
        | awk -F'|' '$2 == "bind" && $5 == "rw" && $3 != "" { print $1 "|" $3 }' \
        | sort -u \
        | cut -d'|' -f2 \
        | sort \
        | uniq -d
}
