#!/usr/bin/env bash
# worktrees.sh — Which git worktrees the removal steps are allowed to delete.
#
# Library file meant to be `source`d, but the shebang serves as an
# unambiguous shell directive for tooling (shellcheck SC2148).
#
# remove.sh and cleanup.sh both walk `git worktree list` and both used to
# delete everything except the tree they were standing in. That set is not the
# set this installer created: a user who runs `git worktree add ../proj-hotfix`
# in the same repository loses it, with --force and then rm -rf. The rules live
# here so the two scripts cannot drift apart again, and so they can be tested
# without running either remover.
#
# Public functions:
#   worktree_list_paths                       # paths git reports, in git order
#   worktree_selectable_paths CURRENT_PATH    # minus the main tree and CURRENT
#   worktree_is_owned PATH PROJECT_DIR [ENV]  # created by this installer?
#
# Ownership has exactly two sources, both of which the installer writes:
#   1. PROJECT_DIR_<X> and ISOLATED_WORKSPACE_<X> in .env, the paths
#      setup-worktrees and setup-isolated record.
#   2. The "<project>-<letter>" naming setup-worktrees.sh:49 produces, for
#      installations predating those keys or whose .env has been removed
#      already (remove.sh deletes .env in a later step than the worktrees).
#
# Requires: scripts/lib/parse_env.sh sourced before this file.

# Guard against double-sourcing.
if [[ -n "${_CLAUDE_DOCKER_WORKTREES_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_WORKTREES_SH_SOURCED=1

# _worktree_normalize PATH
# Drop a trailing slash so "/a/b" and "/a/b/" compare equal. The root is left
# alone; it is never a worktree, and trimming it would produce "".
_worktree_normalize() {
    local p="$1"
    [[ "$p" != "/" ]] && p="${p%/}"
    printf '%s' "$p"
}

# worktree_list_paths
# Print the worktree paths git reports for the current directory, one per
# line, in git's order — the main working tree first, including when this runs
# from a linked worktree.
#
# The prefix is stripped with parameter expansion rather than `awk '{print $2}'`
# because a path containing a space is one field to git and two to awk. That
# truncation is why cleanup.sh printed "Removing worktree: /Users/me/My" and
# left the real worktree in place.
worktree_list_paths() {
    local line
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) printf '%s\n' "${line#worktree }" ;;
        esac
    done < <(git worktree list --porcelain 2>/dev/null || true)
}

# worktree_selectable_paths CURRENT_PATH
# Print the worktrees that are candidates for removal: everything git listed
# except the main working tree and except CURRENT_PATH itself.
#
# Two independent guards, deliberately not one. Dropping the first entry works
# even when the caller is standing in a linked worktree, which is the case
# where its own path does not identify the repository at risk; comparing
# against CURRENT_PATH covers the ordinary case. This mirrors
# Select-RemovableWorktree in scripts/ClaudeDocker.psm1.
worktree_selectable_paths() {
    local current
    current="$(_worktree_normalize "${1:-}")"

    local first=1 path
    while IFS= read -r path; do
        if (( first )); then
            first=0
            continue
        fi
        [[ "$(_worktree_normalize "$path")" == "$current" ]] && continue
        printf '%s\n' "$path"
    done < <(worktree_list_paths)
}

# _worktree_env_keys ENV_FILE
# Print the per-account workspace keys present in ENV_FILE. PROJECT_DIR on its
# own does not match: the pattern requires a letter suffix.
_worktree_env_keys() {
    local env_file="$1"
    [[ -r "$env_file" ]] || return 0
    sed -n 's/^[[:space:]]*\(\(PROJECT_DIR\|ISOLATED_WORKSPACE\)_[A-Z][A-Z]*\)[[:space:]]*=.*/\1/p' \
        "$env_file" | sort -u
}

# worktree_is_owned PATH PROJECT_DIR [ENV_FILE]
# Return 0 when PATH is a workspace this installer created.
worktree_is_owned() {
    local path project_dir env_file
    path="$(_worktree_normalize "$1")"
    project_dir="$(_worktree_normalize "${2:-}")"
    env_file="${3:-}"

    # Source 1: the paths recorded in .env.
    if [[ -n "$env_file" && -r "$env_file" ]]; then
        local key value
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            value="$(parse_env_value "$env_file" "$key")"
            [[ -z "$value" ]] && continue
            if [[ "$(_worktree_normalize "$value")" == "$path" ]]; then
                return 0
            fi
        done < <(_worktree_env_keys "$env_file")
    fi

    # Source 2: the "<project>-<letter>" naming setup-worktrees.sh produces.
    #
    # The suffix is bounded to two characters because that is exactly what the
    # generator can emit: normalize_account_count caps the count at 702 and
    # index_to_letter turns 702 into "zz". Accepting [a-z]+ instead would
    # claim any sibling named after a lowercase word -- "<project>-clone",
    # "<project>-hotfix", "<project>-wip" all match, and those are precisely
    # the user-created worktrees this check exists to spare.
    #
    # The suffix is tested separately rather than interpolated into one
    # regex, because a project directory containing regex metacharacters
    # would otherwise widen the pattern.
    if [[ -n "$project_dir" && "$path" == "$project_dir"-* ]]; then
        local suffix="${path#"$project_dir"-}"
        if [[ "$suffix" =~ ^[a-z]{1,2}$ ]]; then
            return 0
        fi
    fi

    return 1
}
