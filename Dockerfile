# Base: node:20-slim (Debian/glibc)
FROM node:20-slim

# Version pinning via build arg (omit for latest)
ARG CLAUDE_CODE_VERSION

WORKDIR /workspace

# Dev tools — single layer, cache cleaned
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
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (gh) — separate layer for cache efficiency
# Why: gh releases change independently from apt packages
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

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

# Copy entrypoint script (symlinks host config into account state dir)
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

# Run as non-root (node user UID 1000 is pre-created in node:20-slim)
USER node

# Entrypoint creates config symlinks, then runs the command
ENTRYPOINT ["entrypoint.sh"]
CMD ["sleep", "infinity"]
