#!/usr/bin/env bash
# resources.sh — Container resource envelope helpers for bash callers.
#
# Library file meant to be `source`d, but the shebang serves as an
# unambiguous shell directive for tooling (shellcheck SC2148).
#
# The generated compose files carry two memory settings that have to agree:
#
#   deploy.resources.limits.memory  the cap the kernel enforces on the whole
#                                   container (CONTAINER_MEM_LIMIT)
#   NODE_OPTIONS=--max-old-space-size=N
#                                   the ceiling V8 lets its old space grow to
#                                   before it gives up and throws
#
# Until issue #335 both were fixed values that happened to be equal: a 4 GiB
# cap and a 4096 MiB heap. That is not a safe pair. The old space is only one
# of several things inside the container's memory cgroup -- V8's other heap
# spaces, native allocations from node modules, every subprocess an agent
# spawns (git, ripgrep, package managers, compilers) and the page cache for
# the bind mounts all draw on the same cap. A heap allowed to reach the cap on
# its own means the container is killed by the OOM killer at some point before
# V8 ever reaches the limit that would have made it collect garbage instead.
# An OOM kill is also the less useful of the two failures: it takes the whole
# container down with no JavaScript stack, where the heap limit surfaces as a
# catchable allocation error in the process that caused it.
#
# So the heap limit is derived from the cap rather than set beside it, and an
# explicitly configured value is checked against the cap before any compose
# file is written.
#
# Public functions:
#   resource_mib_from_byte_value VALUE     # Compose byte value -> whole MiB
#   node_heap_headroom_mib CAP_MIB         # headroom this cap should reserve
#   resolve_node_heap_mib CAP [HEAP_MB]    # validated heap in MiB, or fail
#
# Requires: nothing. Deliberately free of .env lookups so the arithmetic can
# be exercised directly; callers pass the resolved values in.

# Guard against double-sourcing.
if [[ -n "${_CLAUDE_DOCKER_RESOURCES_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_RESOURCES_SH_SOURCED=1

# Smallest slice of the container memory cap that must stay outside the Node
# heap. A floor rather than the whole rule: a percentage alone collapses to
# nothing on small caps, where the fixed costs (V8 itself, the runtime's own
# node processes, git) do not shrink with the cap.
NODE_HEAP_MIN_HEADROOM_MIB=512

# Fraction of the cap reserved when that is larger than the floor, expressed
# as a divisor: 4 means a quarter of the cap.
#
# 25% is a convention, not a measurement. Nothing in this repository has yet
# measured the steady-state non-heap footprint of an agent container, and the
# benchmark matrix that would (issue #335, "1/2/4-account benchmark results")
# is still open. It is stated here as a convention on purpose, so that
# replacing it later is a matter of substituting a measured number rather than
# discovering what the number was supposed to mean.
NODE_HEAP_HEADROOM_DIVISOR=4

# Fractional digits kept when a byte value carries a decimal point. Three is
# 1 MiB of precision at GiB scale, and it is also what keeps the arithmetic
# inside a signed 64-bit integer at the largest unit this accepts: 999 * 1 PiB
# is 1.1e18, where a fourth digit would overflow.
RESOURCE_FRACTION_DIGITS=3

# resource_mib_from_byte_value VALUE
# Print VALUE as a whole number of MiB, or return 1 without printing.
#
# The accepted syntax is the one Docker itself parses (go-units.RAMInBytes,
# reached through deploy.resources.limits.memory): a number with an optional
# k/m/g/t/p scale, an optional `i`, an optional `b`, and optional spaces, all
# case-insensitive -- 4G, 4g, 4GB, 4GiB, 4 g and 4294967296 are the same
# value. Decimals are accepted for the same reason: `1.5G` is a working
# CONTAINER_MEM_LIMIT today, and this validator has no business rejecting a
# cap that Docker would have taken.
#
# The result is floored, which is the conservative direction for every caller
# here: a cap of 1536k floors to 1 MiB rather than rounding up to 2, so a
# headroom check reads the cap as smaller than it is and never as larger.
resource_mib_from_byte_value() {
    local raw="${1:-}"
    local value int_part frac scale mult bytes denom

    value="$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [[ -n "$value" ]] || return 1

    # Group 1 whole part, group 3 fractional digits, group 5 the scale letter
    # (empty for plain bytes, whether written as `4` or `4b`).
    if [[ "$value" =~ ^([0-9]+)(\.([0-9]+))?(([kmgtp])i?b?|b)?$ ]]; then
        int_part="${BASH_REMATCH[1]}"
        frac="${BASH_REMATCH[3]}"
        scale="${BASH_REMATCH[5]}"
    else
        return 1
    fi

    case "$scale" in
        '')  mult=1 ;;
        k)   mult=1024 ;;
        m)   mult=$(( 1024 ** 2 )) ;;
        g)   mult=$(( 1024 ** 3 )) ;;
        t)   mult=$(( 1024 ** 4 )) ;;
        p)   mult=$(( 1024 ** 5 )) ;;
    esac

    bytes=$(( int_part * mult ))
    if [[ -n "$frac" ]]; then
        frac="${frac:0:RESOURCE_FRACTION_DIGITS}"
        denom=$(( 10 ** ${#frac} ))
        # 10# forces base 10: a fraction like .05 arrives as the string 05,
        # which bash arithmetic would otherwise read as octal.
        bytes=$(( bytes + (10#$frac * mult) / denom ))
    fi

    printf '%s' "$(( bytes / 1024 / 1024 ))"
}

# node_heap_headroom_mib CAP_MIB
# Print the number of MiB that should stay outside the Node heap for a
# container capped at CAP_MIB.
node_heap_headroom_mib() {
    local cap_mib="${1:-0}"
    local headroom=$(( cap_mib / NODE_HEAP_HEADROOM_DIVISOR ))

    if (( headroom < NODE_HEAP_MIN_HEADROOM_MIB )); then
        headroom=$NODE_HEAP_MIN_HEADROOM_MIB
    fi

    printf '%s' "$headroom"
}

# resolve_node_heap_mib MEM_LIMIT [CONFIGURED_HEAP_MB]
# Print the Node old-space limit, in MiB, for a container whose memory cap is
# MEM_LIMIT. With CONFIGURED_HEAP_MB empty the value is derived from the cap;
# otherwise CONFIGURED_HEAP_MB is used as given. Either way the result is
# checked against the cap.
#
# Diagnostics go to stderr and the function returns 1, so a caller can treat
# it exactly like the other generator-side validators: refuse to open the
# first output file rather than write a stack that OOM-kills at run time.
resolve_node_heap_mib() {
    local mem_limit="${1:-}" configured="${2:-}"
    local cap_mib heap headroom

    if ! cap_mib="$(resource_mib_from_byte_value "$mem_limit")"; then
        echo "Error: CONTAINER_MEM_LIMIT must be a byte value such as 4G, 4096m or 4294967296 (got: ${mem_limit})" >&2
        return 1
    fi

    # Checked before the heap so that the advice below can always name a
    # positive ceiling to lower the heap to.
    if (( cap_mib <= NODE_HEAP_MIN_HEADROOM_MIB )); then
        echo "Error: CONTAINER_MEM_LIMIT=${mem_limit} (${cap_mib} MiB) leaves no room for a Node heap." >&2
        echo "       At least ${NODE_HEAP_MIN_HEADROOM_MIB} MiB of the cap must stay outside the heap, so the cap has to exceed that." >&2
        return 1
    fi

    if [[ -n "$configured" ]]; then
        # 10# on every arithmetic use of this value, and the value normalized
        # to decimal before it is emitted (#356, row 5).
        #
        # Without it a leading zero makes bash read the number as octal, and
        # the two generators stopped agreeing on the same .env:
        #
        #   CONTAINER_NODE_HEAP_MB=008
        #     bash  ((: 008: value too great for base -- the generator aborted
        #           on a shell-internal error, never reaching its own message
        #     pwsh  8, accepted
        #   CONTAINER_NODE_HEAP_MB=007
        #     bash  NODE_OPTIONS=--max-old-space-size=007
        #     pwsh  NODE_OPTIONS=--max-old-space-size=7
        #
        # resource_mib_from_byte_value above already used 10# for exactly this
        # reason; this function did not. Leading zeros are accepted rather than
        # rejected, matching normalize_account_count in lib/index.sh.
        if [[ ! "$configured" =~ ^[0-9]+$ ]] || (( 10#$configured == 0 )); then
            echo "Error: CONTAINER_NODE_HEAP_MB must be a positive whole number of MiB (got: ${configured})" >&2
            return 1
        fi
        heap=$(( 10#$configured ))
    else
        local reserved
        reserved="$(node_heap_headroom_mib "$cap_mib")"
        heap=$(( cap_mib - reserved ))
    fi

    headroom=$(( cap_mib - heap ))
    if (( headroom < NODE_HEAP_MIN_HEADROOM_MIB )); then
        echo "Error: the Node heap limit does not leave enough of the container memory cap free." >&2
        echo "       CONTAINER_MEM_LIMIT=${mem_limit} is ${cap_mib} MiB; a ${heap} MiB heap leaves ${headroom} MiB, and at least ${NODE_HEAP_MIN_HEADROOM_MIB} MiB is required." >&2
        echo "       Set CONTAINER_NODE_HEAP_MB to at most $(( cap_mib - NODE_HEAP_MIN_HEADROOM_MIB )), or raise CONTAINER_MEM_LIMIT." >&2
        return 1
    fi

    printf '%s' "$heap"
}
