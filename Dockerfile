# Base: node:20.18.1-slim (Debian/glibc)
# Pinned to a specific patch version AND content digest so rebuilds are
# byte-for-byte reproducible and any upstream repush of the tag is caught
# at build time as a digest mismatch. To bump:
#   1. Check <https://hub.docker.com/_/node/tags?name=slim> for the latest 20.x LTS
#   2. Capture the digest on a trusted host (REQUIRED, not optional):
#        docker pull node:<new-version>-slim \
#          && docker inspect --format='{{index .RepoDigests 0}}' node:<new-version>-slim
#   3. Update BOTH the tag and the @sha256: suffix in the FROM line below
#   4. Rebuild: docker compose build --no-cache
FROM node:20.18.1-slim@sha256:b2c8e0eb8a6aeeae33b2711f8f516003e27ee45804e270468d937b3214f2f0cc

# Use bash with pipefail for all RUN pipes so an upstream curl/gpg failure
# aborts the build instead of masking the error behind a downstream success.
# hadolint rule DL4006 requires this for any RUN that uses `|`.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Version pinning via build arg (omit for latest)
ARG CLAUDE_CODE_VERSION
ARG CODEX_CLI_VERSION

WORKDIR /workspace

# Dev tools — single layer, cache cleaned.
# python3 is included so hook test harnesses (e.g. claude-config
# tests/hooks/test-*.sh) that validate JSON via `python3 -m json.tool`
# fall back correctly when jq is unavailable; the image stays slim
# because this is the interpreter only, no pip or venv.
#
# DL3008 waived: rolling Debian base tracks security updates via the
# digest-pinned node:20.18.1-slim; per-package apt pins would be churn
# without a meaningful security benefit. Pinning policy tracked in #171.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git \
       curl \
       ca-certificates \
       jq \
       fzf \
       zsh \
       sudo \
       procps \
       python3 \
       tzdata \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (gh) — separate layer for cache efficiency
# Why: gh releases change independently from apt packages
# The keyring is dearmored via gpg (the canonical method) instead of raw dd,
# and `gpg --show-keys` logs the fingerprint for post-build audit. Reviewers
# can cross-check the fingerprint against the value published by GitHub at
# build time to detect an upstream keyring swap.
#
# DL3008 waived: same rolling-base rationale as the dev-tools layer above; see #171.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update && apt-get install -y --no-install-recommends gnupg; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /tmp/gh.gpg; \
    gpg --dearmor < /tmp/gh.gpg > /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "[build] GitHub CLI keyring fingerprint:"; \
    gpg --show-keys /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    rm /tmp/gh.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list > /dev/null; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*

# Install Claude Code via native installer (npm package is deprecated).
# The install script places:
#   $HOME/.local/bin/claude                              (symlink to versioned binary)
#   $HOME/.local/share/claude/versions/<VERSION>         (actual binary)
# We force $HOME to /home/node during install so the layout lands directly
# under the runtime user's home. This matters because:
#   1. `claude` self-detects as a proper native install at ~/.local/bin/,
#      avoiding /doctor's false-positive "leftover npm global install"
#      warning when the binary lives in /usr/local/bin.
#   2. The internal symlink chain (bin -> share/versions/<VERSION>) stays
#      intact without manual rewiring.
#   3. On Linux overrides with a custom UID/GID, world-readable permissions
#      on the versioned tree let any user exec it.
# Pin claude.ai installer to a known SHA256 to fail the image build
# if the upstream installer is unexpectedly modified. Refresh by
# computing the hash of the latest installer and bumping the ARG
# default below; CI will fail loudly when this drift occurs.
ARG CLAUDE_INSTALLER_SHA256=b315b46925a9bfb9422f2503dd5aa649f680832f4c076b22d87c39d578c3d830

RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && echo "${CLAUDE_INSTALLER_SHA256}  /tmp/claude-install.sh" | sha256sum -c - \
    && HOME=/home/node bash /tmp/claude-install.sh ${CLAUDE_CODE_VERSION:+"$CLAUDE_CODE_VERSION"} \
    && rm -f /tmp/claude-install.sh \
    && chown -R node:node /home/node/.local /home/node/.claude 2>/dev/null || true \
    && chmod -R a+rX /home/node/.local \
    && rm -rf /root/.claude

# Add the native install location to PATH for all users
ENV PATH="/home/node/.local/bin:${PATH}"

# Install Codex CLI and statusline tools globally (npm packages)
#
# DL3016 waived: @openai/codex, ccstatusline, and claude-limitline are
# latest-tracking helper packages; pinning them would block bug fixes without
# a security benefit. CODEX_CLI_VERSION is available when reproducibility is
# preferred for the Codex CLI.
# hadolint ignore=DL3016
RUN if [[ -n "${CODEX_CLI_VERSION:-}" ]]; then \
        npm install -g "@openai/codex@${CODEX_CLI_VERSION}" ccstatusline claude-limitline; \
    else \
        npm install -g @openai/codex ccstatusline claude-limitline; \
    fi \
    && npm cache clean --force

# Memory heap limit
ENV NODE_OPTIONS=--max-old-space-size=4096

# Pre-create ccstatusline XDG config dir world-writable.
#
# ccstatusline reads (and on first run writes defaults to) ~/.config/
# ccstatusline/settings.json — path derived from os.homedir(), not XDG_
# CONFIG_HOME. When docker-compose runs the container as the host UID/GID
# (see user: "${UID:-1000}:${GID:-1000}" in docker-compose.yml, added by
# commit a09f997), chown'ing this dir to node:node leaves the running
# process unable to write, and ccstatusline silently falls back to its
# hardcoded single-line default instead of the user's multi-line layout.
#
# Using chmod -R a+rwX (capital X grants execute on dirs/already-executables
# only, never on plain files) keeps the tree writable regardless of which
# UID the compose file chooses. gh mounts its own subdir read-only at
# runtime, so loosening the parent does not affect gh's token security.
RUN mkdir -p /home/node/.config/ccstatusline \
    && chmod -R a+rwX /home/node/.config

# Copy entrypoint script (symlinks host config into account state dir).
# Explicit chmod ensures the executable bit is set regardless of the host
# filesystem's core.filemode behavior (e.g., NTFS clones lose the +x bit).
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Run as non-root (node user UID 1000 is pre-created in node:20-slim)
USER node

# Entrypoint creates config symlinks, then runs the command
ENTRYPOINT ["entrypoint.sh"]
CMD ["sleep", "infinity"]
