# Project Structure

The repository layout. `tests/test_docs_contracts.sh` checks that every
generated compose file appears in this tree.

```
claude-docker/
+-- .dockerignore                      Docker build context exclusions
+-- Dockerfile                         Base image (Claude Code installed via Anthropic native installer)
+-- VERSION                            Default image tag read by generators and installers
+-- docker-compose.yml                 Generated: base config (Tier A)
+-- docker-compose.linux.yml           Generated: Linux override
+-- docker-compose.worktree.yml        Generated: worktree-mode override
+-- docker-compose.isolated.yml        Generated: isolated-mode override (hardened profile)
+-- docs/
|   +-- AUTHENTICATION.md              OAuth or API key, container login, GitHub CLI identities
|   +-- COMPOSE.md                     State and mounts, generated compose files, NUM_ACCOUNTS, timezone
|   +-- HOST_CONFIG.md                 Shared claude-config and container-side settings transformation
|   +-- ISOLATION.md                   Workspace isolation modes and their trust boundaries
|   +-- ISSUE-335-*.md                 Issue #335 review, validation and workflow evidence
|   +-- MAINTENANCE.md                 Base image, installed CLIs and the bump procedure
|   +-- PERFORMANCE.md                 Benchmark numbers of record
|   +-- PROJECT_STRUCTURE.md           This file
|   +-- README_POLICY.md               README evidence policy that scripts/readme_lint.py enforces
|   +-- RESOURCES.md                   Resource limits, Node heap headroom, memory per instance count
|   +-- RUNTIMES.md                    Codex and Gemini runtimes, adding a runtime
|   +-- TROUBLESHOOTING.md             Symptoms and fixes
|   +-- USAGE.md                       Command details behind the README quick reference
|   +-- benchmarks/                    Raw results cited by PERFORMANCE.md
+-- .env.example                       Environment template
+-- .gitignore
+-- .gitattributes                     LF line endings
+-- .github/                           Dependency updates and contribution guidance
|   +-- workflows/                     CI, documentation audit and cross-platform TUI release automation
+-- CONTRIBUTING.md                    Contribution and verification requirements
+-- LICENSE                            BSD 3-Clause
+-- README.md                          Entry page: status, quick start, command summary
+-- scripts/
|   +-- claude-docker                  CLI wrapper (bash)
|   +-- claude-docker.ps1              CLI wrapper (PowerShell)
|   +-- claude-docker.cmd              CLI wrapper (cmd.exe batch)
|   +-- ClaudeDocker.psm1              Shared PowerShell module
|   +-- generate-compose.sh            Compose file generator (bash)
|   +-- generate-compose.ps1           Compose file generator (PowerShell)
|   +-- entrypoint.sh                  Runtime bootstrap dispatcher + GitHub auth setup
|   +-- install.sh                     Interactive setup (bash)
|   +-- install.ps1                    Interactive setup (PowerShell)
|   +-- remove.sh                      Complete removal (bash)
|   +-- remove.ps1                     Complete removal (PowerShell)
|   +-- cleanup.sh                     Container/volume/worktree/state cleanup (bash)
|   +-- cleanup.ps1                    Same cleanup flow (PowerShell)
|   +-- setup-worktrees.sh             worktree-mode setup (bash)
|   +-- setup-worktrees.ps1            worktree-mode setup (PowerShell)
|   +-- setup-isolated.sh              isolated-mode clone setup (bash)
|   +-- setup-isolated.ps1             isolated-mode clone setup (PowerShell)
|   +-- test-concurrent-git.sh         E2E test (bash)
|   +-- test-concurrent-git.ps1        E2E test (PowerShell)
|   +-- test-entrypoint-settings.sh    Entrypoint settings normalization test (bash)
|   +-- readme_lint.py                 README evidence lint (docs/README_POLICY.md)
|   +-- lib/
|       +-- worktrees.sh               Which git worktrees the removers may delete (bash)
|       +-- parse_env.sh               Shared .env parser (bash)
|       +-- index.sh / index.ps1       Excel-style account index helpers
|       +-- runtime.sh                 Runtime registry reader (jq, awk fallback)
|       +-- isolation.sh               Isolation-mode resolution and the trust-boundary text
|       +-- resources.sh               Memory cap to Node heap arithmetic
|       +-- build-compose-cmd.sh       Compose overlay selection (bash)
|       +-- bootstrap-common.sh        Shared entrypoint helpers
|       +-- bootstrap-claude.sh        Per-runtime container bootstrap modules
|       +-- bootstrap-codex.sh         (dispatched by entrypoint.sh via the registry)
|       +-- bootstrap-gemini.sh
+-- tui/                               Bubble Tea multi-account dashboard (Go module)
|   +-- main.go
|   +-- Makefile
|   +-- go.mod / go.sum
|   +-- internal/                      account, auth, config, docker, ui subpackages
|       +-- config/runtimes.json       Runtime registry: cross-language single source of truth
+-- tests/                             Registry/parser/generator/auth/platform/entrypoint
    |                                  regression tests and fixtures
    +-- env_fixtures/
    +-- entrypoint_fixtures/
```
