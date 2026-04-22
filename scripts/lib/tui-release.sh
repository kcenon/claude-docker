#!/usr/bin/env bash
# tui-release.sh — download a prebuilt claude-docker-tui binary from GitHub Releases.
#
# Sourced by scripts/claude-docker (cmd_build_tui, cmd_tui) and scripts/install.sh
# (build_tui). Exposes:
#   download_tui_release <dest>
#
# The function auto-detects host OS/arch, fetches the matching asset and its
# .sha256 file from the "latest" release, verifies the checksum, and installs
# the binary at <dest>. Returns non-zero on any failure; never leaves a
# partially-installed binary at <dest>.
#
# Callers must define these helpers before sourcing (log_info/log_warn/log_error).
# To override the repo slug (e.g. for forks), export TUI_RELEASE_REPO.

TUI_RELEASE_REPO="${TUI_RELEASE_REPO:-kcenon/claude-docker}"

download_tui_release() {
    local dest="$1"
    if [[ -z "$dest" ]]; then
        log_error "download_tui_release: destination path required"
        return 2
    fi

    local os arch ext
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    ext=""
    case "$os" in
        linux|darwin) ;;
        mingw*|msys*|cygwin*) os="windows"; ext=".exe" ;;
        *)
            log_error "Unsupported OS for release download: $os"
            return 1
            ;;
    esac
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            log_error "Unsupported architecture for release download: $arch"
            return 1
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required to download the prebuilt TUI binary."
        return 1
    fi

    local asset="claude-docker-tui-${os}-${arch}${ext}"
    local base_url="https://github.com/${TUI_RELEASE_REPO}/releases/latest/download"
    local url="${base_url}/${asset}"
    local tmp
    tmp=$(mktemp -d) || {
        log_error "Failed to create temp directory for download."
        return 1
    }
    # shellcheck disable=SC2064 # want early expansion of $tmp
    trap "rm -rf '$tmp'" RETURN

    log_info "Downloading $asset from GitHub Releases..."
    if ! curl -fsSL --retry 3 -o "$tmp/$asset" "$url"; then
        log_error "Failed to download $url (no matching release asset?)"
        return 1
    fi
    if ! curl -fsSL --retry 3 -o "$tmp/$asset.sha256" "$url.sha256"; then
        log_error "Failed to download checksum for $asset"
        return 1
    fi

    local sha_cmd
    if command -v sha256sum >/dev/null 2>&1; then
        sha_cmd="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        sha_cmd="shasum -a 256"
    else
        log_error "No SHA256 tool available (need sha256sum or shasum)."
        return 1
    fi
    if ! ( cd "$tmp" && $sha_cmd -c "$asset.sha256" ) >/dev/null 2>&1; then
        log_error "SHA256 verification FAILED for $asset — aborting install."
        return 1
    fi

    # Stage into destination atomically: same filesystem, then rename.
    local dest_dir
    dest_dir=$(dirname -- "$dest")
    mkdir -p "$dest_dir"
    mv "$tmp/$asset" "${dest}.part"
    chmod +x "${dest}.part"
    mv "${dest}.part" "$dest"
    log_info "Installed $dest"
    return 0
}
