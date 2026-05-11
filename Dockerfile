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
FROM node:26.1.0-slim@sha256:424cafd2a035ed2b2d74acc3142b68b426fb62a47742c80a75e7117db02d6b30

# Version pinning via build arg (omit for latest)
ARG CLAUDE_CODE_VERSION

WORKDIR /workspace

# Dev tools — single layer, cache cleaned.
# python3 is included so hook test harnesses (e.g. claude-config
# tests/hooks/test-*.sh) that validate JSON via `python3 -m json.tool`
# fall back correctly when jq is unavailable; the image stays slim
# because this is the interpreter only, no pip or venv.
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
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (gh) — separate layer for cache efficiency
# Why: gh releases change independently from apt packages
# The keyring is dearmored via gpg (the canonical method) instead of raw dd,
# and `gpg --show-keys` logs the fingerprint for post-build audit. Reviewers
# can cross-check the fingerprint against the value published by GitHub at
# build time to detect an upstream keyring swap.
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
RUN HOME=/home/node curl -fsSL https://claude.ai/install.sh \
      | HOME=/home/node bash -s -- ${CLAUDE_CODE_VERSION:+"$CLAUDE_CODE_VERSION"} \
    && chown -R node:node /home/node/.local /home/node/.claude 2>/dev/null || true \
    && chmod -R a+rX /home/node/.local \
    && rm -rf /root/.claude

# Add the native install location to PATH for all users
ENV PATH="/home/node/.local/bin:${PATH}"

# Install statusline tools globally (still npm packages)
RUN npm install -g ccstatusline claude-limitline \
    && npm cache clean --force

# Memory heap limit
ENV NODE_OPTIONS=--max-old-space-size=4096

# Pre-create .config directories with node ownership
# (prevents root-owned dir when Docker bind-mounts ~/.config/gh)
RUN mkdir -p /home/node/.config/ccstatusline \
    && chown -R node:node /home/node/.config

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
