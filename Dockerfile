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

# Install Claude Code and statusline tools globally
RUN npm install -g @anthropic-ai/claude-code${CLAUDE_CODE_VERSION:+@$CLAUDE_CODE_VERSION} \
       ccstatusline claude-limitline \
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
