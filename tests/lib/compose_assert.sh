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

# resolved_service_env_keys DIR SERVICE FILE...
# Print the environment variable NAMES of one resolved service, one per line,
# sorted.
#
# Names only, never values. This helper resolves whatever .env the sandbox
# holds, and in CI the same code path runs against fixtures that put a
# placeholder token in exactly the slot a real one would occupy; a helper that
# printed values would put them in the job log the first time an assertion
# failed. Every question this file needs to answer about credentials -- is
# GH_TOKEN present, is it absent -- is answerable from the names alone.
resolved_service_env_keys() {
    local dir="$1" service="$2"
    shift 2

    local file_args=() f
    for f in "$@"; do
        file_args+=(-f "$f")
    done

    (cd "$dir" && docker compose "${file_args[@]}" config --format json) \
        | jq -r --arg svc "$service" '.services[$svc].environment // {} | keys[]'
}

# resolved_env_distinct DIR KEY SERVICE_A SERVICE_B FILE...
# Compare one environment variable across two resolved services and print
# `distinct`, `identical`, or `missing` -- never the values themselves.
#
# Presence of a key says only that a service has *a* credential; it cannot
# distinguish a correctly scoped setup from one where both accounts were handed
# the same token, which is the failure per-account auth exists to prevent. The
# comparison happens inside jq so the values stay out of the output and out of
# any CI log, which is why this is a helper rather than two greps in a caller.
resolved_env_distinct() {
    local dir="$1" key="$2" svc_a="$3" svc_b="$4"
    shift 4

    local file_args=() f
    for f in "$@"; do
        file_args+=(-f "$f")
    done

    (cd "$dir" && docker compose "${file_args[@]}" config --format json) \
        | jq -r --arg k "$key" --arg a "$svc_a" --arg b "$svc_b" '
            (.services[$a].environment[$k] // null) as $va
            | (.services[$b].environment[$k] // null) as $vb
            | if $va == null or $vb == null then "missing"
              elif $va == $vb then "identical"
              else "distinct"
              end
        '
}

# resolved_service_networks DIR SERVICE FILE...
# Print the network attachment of one resolved service: either one
# `network=NAME` line per attached network, or a single `network_mode=NAME`
# line when the service declares an explicit mode instead.
#
# Both spellings are reported by one helper because they are alternative
# answers to the same question, and a caller that grepped only for `network=`
# would read a detached service as "no assertion applies" rather than as the
# offline policy it is.
resolved_service_networks() {
    local dir="$1" service="$2"
    shift 2

    local file_args=() f
    for f in "$@"; do
        file_args+=(-f "$f")
    done

    (cd "$dir" && docker compose "${file_args[@]}" config --format json) \
        | jq -r --arg svc "$service" '
            .services[$svc] as $s
            | if $s.network_mode then "network_mode=\($s.network_mode)"
              else (($s.networks // {}) | keys[] | "network=\(.)")
              end
        '
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

# resolved_memory_envelope DIR SERVICE FILE...
# Print "HEAP_MIB CAP_MIB" for SERVICE in the resolved model: the heap ceiling
# carried by NODE_OPTIONS and the container memory cap, both in MiB.
#
# Compose normalizes each of these away from the form the generator wrote.
# `memory: 4G` resolves to the byte-count string "4294967296", and the
# environment list resolves to an object, so neither value can be read out of
# the generated YAML in the shape it is asserted in here.
#
# Printing this environment value is safe in a way the generic helper's
# key-only rule is not: NODE_OPTIONS is a resource setting, and the whole point
# of the assertion is the number it carries.
#
# Either field is empty when the service does not declare it, which callers
# should treat as a failure rather than as "no assertion applies".
#
# The heap extraction guards `capture` with `test` rather than suppressing its
# no-match error with the optional operator. `capture(...)?.mib` reads better
# and works locally on jq 1.8, but optional chaining is a 1.8 addition and
# ubuntu-latest ships 1.7.1, which rejects it at parse time -- so the whole
# filter fails to compile and every field comes back empty. Nothing here needs
# syntax newer than jq 1.5.
resolved_memory_envelope() {
    local dir="$1" service="$2"
    shift 2

    local file_args=() f
    for f in "$@"; do
        file_args+=(-f "$f")
    done

    (cd "$dir" && docker compose "${file_args[@]}" config --format json) \
        | jq -r --arg svc "$service" '
            .services[$svc] as $s
            | ($s.environment.NODE_OPTIONS // "") as $opts
            | (if ($opts | test("--max-old-space-size=[0-9]+"))
               then ($opts | capture("--max-old-space-size=(?<mib>[0-9]+)") | .mib)
               else "" end) as $heap
            | ($s.deploy.resources.limits.memory // "") as $mem
            | (if $mem == "" then "" else (($mem | tonumber) / 1048576 | floor | tostring) end) as $cap
            | "\($heap) \($cap)"
        '
}
