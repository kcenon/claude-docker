#!/usr/bin/env bash
# Host policy is shared with the PowerShell wrapper. No third-party packages.
host_policy() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo 'Error: Python 3.9+ is required for isolation validation and lifecycle transactions.' >&2
        return 1
    fi
    python3 "${SCRIPT_DIR}/lib/lifecycle.py" --root "$PROJECT_ROOT" "$@"
}
