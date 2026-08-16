#!/usr/bin/env bash
# parse_env.sh — Robust .env parser for claude-docker bash scripts.
#
# Library file meant to be `source`d, but the shebang serves as an
# unambiguous shell directive for tooling (shellcheck SC2148).
#
# Provides a single source of truth for reading and writing .env key/value
# pairs so that behavior stays consistent across install.sh, claude-docker,
# generate-compose.sh, remove.sh and any future consumers.
#
# Public functions:
#   parse_env_value FILE KEY            # print value for KEY, empty if absent
#   load_env_file   FILE [-x|-a]        # export all key/value pairs
#   set_env_value   FILE KEY VALUE      # insert or update KEY=VALUE in FILE
#
# Handled quirks:
#   - Trailing \r from CRLF line endings (Windows-authored .env files).
#   - Trailing whitespace.
#   - Inline unescaped comments preceded by whitespace  (KEY=value  # note).
#   - Surrounding single or double quotes on the value.
#   - Values containing '=' (only the first '=' separates key from value).
#   - Commented lines and blank lines.
#   - Duplicate keys: last match wins, matching POSIX shell env semantics.

# Guard against double-sourcing.
if [[ -n "${_CLAUDE_DOCKER_PARSE_ENV_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_PARSE_ENV_SH_SOURCED=1

# parse_env_value FILE KEY
# Print the normalized value of KEY from FILE to stdout. Prints nothing if
# the file is missing, unreadable, or the key is absent. Exit status is
# always 0 to let callers capture via command substitution without `|| true`.
parse_env_value() {
    local file="$1" key="$2"
    [[ -r "$file" ]] || return 0

    awk -v key="$key" '
        BEGIN { last = "" }
        # Skip full-line comments and blank lines.
        /^[[:space:]]*(#|$)/ { next }
        {
            # Find first = and split manually so values may contain =.
            eq_idx = index($0, "=")
            if (eq_idx == 0) { next }
            lhs = substr($0, 1, eq_idx - 1)
            # Trim surrounding whitespace from the key.
            sub(/^[[:space:]]+/, "", lhs)
            sub(/[[:space:]]+$/, "", lhs)
            if (lhs != key) { next }

            rhs = substr($0, eq_idx + 1)
            # Strip Windows CR.
            sub(/\r$/, "", rhs)
            # Strip inline comments: space(s) followed by # to end of line.
            sub(/[[:space:]]+#.*$/, "", rhs)
            # Strip trailing whitespace.
            sub(/[[:space:]]+$/, "", rhs)
            # Unquote single- or double-quoted values.
            if ((match(rhs, /^".*"$/) != 0) || (match(rhs, /^'"'"'.*'"'"'$/) != 0)) {
                rhs = substr(rhs, 2, length(rhs) - 2)
            }
            last = rhs
        }
        END { if (last != "") print last }
    ' "$file"
}

# load_env_file FILE [MODE]
# Read FILE and export matching KEY=VALUE pairs into the current shell.
# MODE controls behavior:
#   -x (default) exports only keys that are currently unset (composer-friendly).
#   -a           exports every key, overwriting existing values.
# Honors the same normalization rules as parse_env_value().
load_env_file() {
    local file="$1" mode="${2:--x}"
    [[ -r "$file" ]] || return 0

    local line key value eq_idx force=0
    [[ "$mode" == "-a" ]] && force=1

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip CR, leading whitespace.
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        eq_idx="${line%%=*}"
        [[ "$eq_idx" == "$line" ]] && continue  # no '=' → not a KV line
        key="$eq_idx"
        value="${line#*=}"

        # Trim trailing space on key.
        key="${key%"${key##*[![:space:]]}"}"
        # Strip inline comment (whitespace + #).
        if [[ "$value" =~ [[:space:]]#.*$ ]]; then
            value="${value%%[[:space:]]#*}"
        fi
        # Trim trailing whitespace on value.
        value="${value%"${value##*[![:space:]]}"}"
        # Unquote.
        if [[ "$value" =~ ^\".*\"$ ]] || [[ "$value" =~ ^\'.*\'$ ]]; then
            value="${value:1:${#value}-2}"
        fi

        if (( force )) || [[ -z "${!key:-}" ]]; then
            export "$key=$value"
        fi
    done < "$file"
}

# set_env_value FILE KEY VALUE
# Insert or update KEY=VALUE in FILE. If FILE does not exist, creates it.
#
# Values containing whitespace or '#' are surrounded with double quotes, and
# an embedded double quote is backslash-escaped inside them.
#
# The round-trip is NOT lossless for a value containing a double quote. This
# used to claim it was. parse_env_value strips the wrapping quotes but does
# not unescape, so `say "hi" now` is written as `"say \"hi\" now"` and read
# back as `say \"hi\" now`; Read-EnvFile and the Go LoadEnv behave the same
# way. Making it lossless means changing all three readers in lockstep, which
# belongs with the SSOT work in #356 -- so the claim is corrected here rather
# than left as documentation that is simply untrue (#354, item 8).
# tests/test_parse_env.sh pins the written bytes and the read-back value, so
# whichever way that decision goes, the change is visible.
set_env_value() {
    local file="$1" key="$2" value="$3"
    local formatted="$value"

    if [[ "$value" =~ [[:space:]\#] ]] || [[ "$value" =~ ^[\"\'] ]]; then
        # Escape embedded double quotes and wrap.
        formatted="\"${value//\"/\\\"}\""
    fi

    local line="${key}=${formatted}"

    if [[ ! -f "$file" ]]; then
        printf '%s\n' "$line" > "$file"
        return 0
    fi

    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        # Rewrite in place using a temp file to avoid sed delimiter issues
        # with values containing '/', '|', '&', etc.
        local tmp
        tmp=$(mktemp "${file}.XXXXXX") || return 1
        awk -v key="$key" -v repl="$line" '
            BEGIN { replaced = 0 }
            {
                # Match "^[[:space:]]*KEY=" with literal key.
                if (!replaced && match($0, "^[[:space:]]*" key "=") != 0) {
                    print repl
                    replaced = 1
                } else {
                    print $0
                }
            }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
    else
        # Ensure the file ends with a newline before appending.
        #
        # `$(tail -c1 "$file")` cannot be compared against $'\n': command
        # substitution strips trailing newlines, so it yields '' for a file
        # that already ends in one and the comparison was always true. Every
        # append therefore inserted a blank line first, and .env grew a gap
        # per key (#354, item 8).
        #
        # `tail -c1 | wc -l` answers the actual question: 1 when the last byte
        # is a newline, 0 when it is not.
        if [[ -s "$file" ]] && [[ "$(tail -c1 "$file" | wc -l)" -eq 0 ]]; then
            printf '\n' >> "$file"
        fi
        printf '%s\n' "$line" >> "$file"
    fi
}
