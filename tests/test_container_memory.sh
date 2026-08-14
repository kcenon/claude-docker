#!/usr/bin/env bash
# test_container_memory.sh -- Node heap limit against the container memory cap
# (issue #335, stage 5).
#
# The generated compose files carry two numbers that have to agree: the cgroup
# memory cap and the ceiling V8 is allowed to grow its old space to. Before
# this they were independent literals that happened to be equal -- a 4 GiB cap
# and a 4096 MiB heap -- so a container reached the OOM killer before V8
# reached the limit that would have made it collect garbage instead.
#
# What is under test is therefore a relationship, not a value, and it fails
# quietly in both directions:
#
# 1. Arithmetic. A parser that rejects `1.5G`, or reads `4G` as 4 bytes, turns
#    a working installation into a failed generation or an unguarded heap.
#    Section 1 pins the accepted syntax against what Docker itself parses.
#
# 2. Sequencing. The pair is baked into the output as two literals, so an
#    unusable combination has to be refused before the first output file is
#    opened. Section 3 asserts the refusal AND that nothing was written -- a
#    validator that runs halfway through generation leaves a stack whose two
#    numbers disagree, which is worse than the state it replaced.
#
# 3. Resolution. `memory: 4G` resolves to a byte-count string and the
#    environment list resolves to an object, so section 4 reads both from
#    `docker compose config` rather than from the YAML the generator wrote.
#
# Every generator runs inside a throwaway sandbox holding only the files it
# reads. The committed compose files are digested before and after as an
# observable guard, the same protocol test_isolation_modes.sh uses.
#
# No fixture carries a credential; the only values here are sizes.
#
# Run:  bash tests/test_container_memory.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/compose_assert.sh
. "$SCRIPT_DIR/lib/compose_assert.sh"
# shellcheck source=../scripts/lib/resources.sh
. "$PROJECT_ROOT/scripts/lib/resources.sh"

OUTPUTS=(
    docker-compose.yml
    docker-compose.worktree.yml
    docker-compose.isolated.yml
    docker-compose.linux.yml
)

PLACEHOLDER_HOME="/tmp/claude-docker-memory-home"
PLACEHOLDER_PROJECT="/tmp/claude-docker-memory-project"
PLACEHOLDER_ISO_A="/tmp/claude-docker-memory-clone-a"
PLACEHOLDER_ISO_B="/tmp/claude-docker-memory-clone-b"

PASS=0
FAIL=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# The bash generator refuses to run on native Windows shells, so this test is
# a Linux/macOS/WSL one. Say so rather than reporting failures the caller has
# no way to act on.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "NOTE: generate-compose.sh does not run on native Windows shells; use WSL." >&2
        echo "== Summary: SKIPPED (native Windows shell) =="
        exit 0 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

compose_digest() {
    local f
    for f in "${OUTPUTS[@]}"; do
        if [[ -f "$PROJECT_ROOT/$f" ]]; then
            cksum <"$PROJECT_ROOT/$f"
        else
            echo "absent $f"
        fi
    done
}
DIGEST_BEFORE="$(compose_digest)"

# make_bare_sandbox NAME -- project root holding only what a generator reads,
# with no compose files present. scripts/ is copied wholesale so the sandbox
# stays correct when a new lib module is added.
make_bare_sandbox() {
    local dir="$WORK/$1"
    mkdir -p "$dir/tui/internal/config"
    cp -r "$PROJECT_ROOT/scripts" "$dir/scripts"
    cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$dir/tui/internal/config/"
    [[ -f "$PROJECT_ROOT/VERSION" ]] && cp "$PROJECT_ROOT/VERSION" "$dir/"
    printf '%s' "$dir"
}

# write_env DIR LINE...  -- stage a placeholder .env in a sandbox.
write_env() {
    local dir="$1"
    shift
    printf '%s\n' "$@" >"$dir/.env"
}

# run_generator DIR -- run the bash generator in DIR with the caller's memory
# keys cleared first, so a value left in the developer's shell cannot change
# what a case means. Output lands in DIR/.gen.log; the exit status is returned.
run_generator() {
    local dir="$1"
    local rc=0
    env -u CONTAINER_MEM_LIMIT -u CONTAINER_NODE_HEAP_MB -u NUM_ACCOUNTS \
        -u ISOLATION_MODE -u ISOLATED_WORKSPACE_A \
        bash "$dir/scripts/generate-compose.sh" >"$dir/.gen.log" 2>&1 || rc=$?
    return "$rc"
}

# assert_no_output_written DIR LABEL -- fail when a refused generation left any
# compose file behind. The sandbox starts with none, so any file at all is a
# partial write.
assert_no_output_written() {
    local dir="$1" label="$2"
    local found=() f
    for f in "${OUTPUTS[@]}"; do
        [[ -f "$dir/$f" ]] && found+=("$f")
    done
    if [[ "${#found[@]}" -eq 0 ]]; then
        pass "$label: nothing written"
    else
        fail "$label: partial output left behind (${found[*]})"
    fi
}

# --- 1. Byte-value parsing ----------------------------------------------------
#
# The accepted syntax is not this project's invention: it is what Docker's own
# go-units parser takes for deploy.resources.limits.memory. Narrowing it would
# make generation fail on caps that work today, which is a regression this
# change has no reason to introduce.

echo "== byte-value parsing =="

# INPUT|EXPECTED_MIB
while IFS='|' read -r input expected; do
    [[ -n "$input" ]] || continue
    actual="$(resource_mib_from_byte_value "$input" || echo REJECTED)"
    if [[ "$actual" == "$expected" ]]; then
        pass "parse: $input -> $expected MiB"
    else
        fail "parse: $input -> $actual MiB (want $expected)"
    fi
done <<'EOF'
4G|4096
4g|4096
4GB|4096
4gb|4096
4GiB|4096
4 G|4096
4096m|4096
4096M|4096
4194304k|4096
4294967296|4096
4294967296b|4096
1.5G|1536
0.5G|512
2.25G|2304
1.08G|1105
1.9999G|2046
1T|1048576
1536k|1
EOF

# The last two rows above are not extra coverage of the same thing.
#
# 1.08G pins base-10 reading of the fraction: bash arithmetic treats a leading
# zero as octal, and 08 is not a valid octal literal, so dropping the 10#
# prefix turns this input into a hard error rather than a wrong number.
#
# 1.9999G pins the documented precision cap. The fraction is truncated to
# three digits, so this resolves the same as 1.999G -- deliberate, because a
# longer fraction at the largest accepted unit overflows a signed 64-bit
# integer, and an overflowed cap is a silently wrong one.

# Rejected inputs. Each would otherwise be read as some number, and the wrong
# number here is worse than no number: it silently moves the cap the heap is
# validated against.
for bad in "" "bogus" "-1" "4x" "4bb" "G4" "4G4" "1..5G" "4,096m"; do
    if resource_mib_from_byte_value "$bad" >/dev/null 2>&1; then
        fail "parse: '$bad' accepted, should be rejected"
    else
        pass "parse: '$bad' rejected"
    fi
done

# --- 2. Heap derivation -------------------------------------------------------

echo "== heap derivation =="

while IFS='|' read -r cap expected; do
    [[ -n "$cap" ]] || continue
    actual="$(resolve_node_heap_mib "$cap" 2>/dev/null || echo REJECTED)"
    if [[ "$actual" == "$expected" ]]; then
        pass "derive: cap $cap -> heap $expected MiB"
    else
        fail "derive: cap $cap -> heap $actual MiB (want $expected)"
    fi
done <<'EOF'
1G|512
2G|1536
4G|3072
8G|6144
16G|12288
1024m|512
513m|1
512m|REJECTED
256m|REJECTED
EOF

# The floor is what makes small caps safe: a flat 25% would leave 256 MiB of a
# 1 GiB container for everything that is not the JavaScript heap, and the fixed
# costs -- V8 itself, the runtime's node processes, git -- do not shrink with
# the cap.
if [[ "$(node_heap_headroom_mib 1024)" == "512" && "$(node_heap_headroom_mib 8192)" == "2048" ]]; then
    pass "headroom: floor applies below 2G, proportion above it"
else
    fail "headroom: want 512 at 1024 MiB and 2048 at 8192 MiB, got $(node_heap_headroom_mib 1024) and $(node_heap_headroom_mib 8192)"
fi

# An explicitly configured heap is used as given when it fits, and refused when
# it does not. The boundary is exact on purpose: one MiB either side of it
# decides whether a container is generated at all.
if [[ "$(resolve_node_heap_mib 4G 3584 2>/dev/null)" == "3584" ]]; then
    pass "explicit: 3584 MiB heap accepted at a 4G cap (exactly 512 MiB headroom)"
else
    fail "explicit: 3584 MiB heap refused at a 4G cap"
fi
if resolve_node_heap_mib 4G 3585 >/dev/null 2>&1; then
    fail "explicit: 3585 MiB heap accepted at a 4G cap (511 MiB headroom)"
else
    pass "explicit: 3585 MiB heap refused at a 4G cap"
fi
for bad in 0 -512 abc 3.5; do
    if resolve_node_heap_mib 4G "$bad" >/dev/null 2>&1; then
        fail "explicit: heap '$bad' accepted"
    else
        pass "explicit: heap '$bad' rejected"
    fi
done

# --- 3. Generator sequencing --------------------------------------------------

echo "== generator =="

dir="$(make_bare_sandbox gen-default)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT"
if run_generator "$dir"; then
    if grep -q -- '--max-old-space-size=3072' "$dir/docker-compose.yml" &&
       grep -q -- '--max-old-space-size=3072' "$dir/docker-compose.isolated.yml"; then
        pass "default: 4G cap yields a 3072 MiB heap in both stacks"
    else
        fail "default: heap is not 3072 MiB in both stacks"
    fi
else
    fail "default: generation failed"
    cat "$dir/.gen.log" >&2
fi

dir="$(make_bare_sandbox gen-custom-cap)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "CONTAINER_MEM_LIMIT=8G"
if run_generator "$dir" && grep -q -- '--max-old-space-size=6144' "$dir/docker-compose.yml"; then
    pass "custom cap: 8G yields a 6144 MiB heap"
else
    fail "custom cap: 8G did not yield a 6144 MiB heap"
fi

dir="$(make_bare_sandbox gen-explicit-heap)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "CONTAINER_NODE_HEAP_MB=2048"
if run_generator "$dir" && grep -q -- '--max-old-space-size=2048' "$dir/docker-compose.yml"; then
    pass "explicit heap: an in-range value is emitted as configured"
else
    fail "explicit heap: 2048 MiB not emitted"
fi

# The three refusals. Each asserts the exit status, that the diagnostic names
# the key the user has to change, and that no file was written.
dir="$(make_bare_sandbox gen-heap-at-cap)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "CONTAINER_NODE_HEAP_MB=4096"
if run_generator "$dir"; then
    fail "heap at cap: generation succeeded with no headroom"
else
    if grep -q 'CONTAINER_NODE_HEAP_MB' "$dir/.gen.log"; then
        pass "heap at cap: refused, diagnostic names CONTAINER_NODE_HEAP_MB"
    else
        fail "heap at cap: refused without naming CONTAINER_NODE_HEAP_MB"
    fi
    assert_no_output_written "$dir" "heap at cap"
fi

dir="$(make_bare_sandbox gen-cap-too-small)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "CONTAINER_MEM_LIMIT=384m"
if run_generator "$dir"; then
    fail "tiny cap: generation succeeded with a cap below the headroom floor"
else
    if grep -q 'CONTAINER_MEM_LIMIT' "$dir/.gen.log"; then
        pass "tiny cap: refused, diagnostic names CONTAINER_MEM_LIMIT"
    else
        fail "tiny cap: refused without naming CONTAINER_MEM_LIMIT"
    fi
    assert_no_output_written "$dir" "tiny cap"
fi

dir="$(make_bare_sandbox gen-bad-cap)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "CONTAINER_MEM_LIMIT=four-gigs"
if run_generator "$dir"; then
    fail "unparseable cap: generation succeeded"
else
    pass "unparseable cap: refused"
    assert_no_output_written "$dir" "unparseable cap"
fi

# --- 4. Resolved model --------------------------------------------------------
#
# The assertion is the invariant itself rather than either literal: whatever
# the cap is, the heap has to sit below it with the documented headroom. Read
# from `docker compose config`, because that is the only place both numbers
# exist in comparable units.

echo "== resolved model =="

if compose_assert_requires; then
    dir="$(make_bare_sandbox resolved)"
    write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
        "ISOLATION_MODE=isolated" \
        "ISOLATED_WORKSPACE_A=$PLACEHOLDER_ISO_A" \
        "ISOLATED_WORKSPACE_B=$PLACEHOLDER_ISO_B" \
        "CONTAINER_MEM_LIMIT=6G"
    if ! run_generator "$dir"; then
        fail "resolved: generation failed"
        cat "$dir/.gen.log" >&2
    else
        for spec in "base:claude-a:docker-compose.yml" \
                    "base:claude-b:docker-compose.yml" \
                    "isolated:claude-a:docker-compose.yml docker-compose.isolated.yml" \
                    "isolated:claude-b:docker-compose.yml docker-compose.isolated.yml"; do
            label="${spec%%:*}"
            rest="${spec#*:}"
            service="${rest%%:*}"
            # shellcheck disable=SC2086  # deliberate word-split into -f arguments
            read -r heap cap <<<"$(resolved_memory_envelope "$dir" "$service" ${rest#*:})"

            if [[ -z "$heap" || -z "$cap" ]]; then
                fail "resolved $label/$service: heap or cap missing (heap='$heap' cap='$cap')"
            elif (( cap != 6144 )); then
                fail "resolved $label/$service: cap resolved to $cap MiB, want 6144"
            elif (( heap >= cap )); then
                fail "resolved $label/$service: heap $heap MiB is not below the $cap MiB cap"
            elif (( cap - heap < 512 )); then
                fail "resolved $label/$service: only $(( cap - heap )) MiB of headroom"
            else
                pass "resolved $label/$service: heap $heap MiB under a $cap MiB cap"
            fi
        done
    fi
else
    echo "  SKIP  resolved-model assertions (docker/jq unavailable)"
fi

# --- 5. Committed files untouched --------------------------------------------

if [[ "$(compose_digest)" == "$DIGEST_BEFORE" ]]; then
    pass "committed compose files untouched"
else
    fail "committed compose files were modified by this test"
fi

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
[[ "$FAIL" -eq 0 ]]
