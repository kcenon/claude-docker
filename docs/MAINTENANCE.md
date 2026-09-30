# Maintenance

What the image installs and pins, and how to move its base image.

## Bumping the Base Image

The `Dockerfile` pins **`node:26.10.0-slim` and its content digest**, so the
base layers stay fixed when the upstream tag moves. A digest-qualified reference
selects that content; it does not require the tag to keep pointing to it.

Inside the image, **Claude Code is installed via Anthropic's official native
installer** (`https://claude.ai/install.sh`). The downloaded script is checked
against `CLAUDE_INSTALLER_SHA256` before execution. It places `claude` at
`/home/node/.local/bin/claude`. Optional build arguments `CLAUDE_CODE_VERSION`,
`CODEX_CLI_VERSION`, and `GEMINI_CLI_VERSION` select individual CLI versions;
empty values follow current releases. The installer checksum is a separate
build argument from the Claude Code version.

The complete image is **not byte-for-byte reproducible**: APT packages
(including GitHub CLI), unversioned npm tools (`ccstatusline` and
`claude-limitline`), and CLI versions left unset can change between builds.
Selecting a CLI version does not pin those other dependencies.

To bump the Node base:

1. Check the current `FROM` tag, then check
   <https://hub.docker.com/_/node/tags?name=slim> for a newer release in that
   major version (currently 26.x)
2. Capture the digest on a trusted host (**required**, not optional):
   ```bash
   docker pull node:<new-version>-slim
   docker inspect --format='{{index .RepoDigests 0}}' node:<new-version>-slim
   ```
3. Update the `FROM` line in `Dockerfile` — **both** the tag and the
   `@sha256:` suffix must be updated together. Synchronize the version
   references in its comments, this page and the README status line at the
   same time
4. Update `VERSION` at the repo root to today's date
   (e.g. `2026.04.17`). Both `scripts/generate-compose.sh`/`.ps1` and
   `scripts/install.sh`/`.ps1` read this file, so regenerating compose
   or running `install` picks up the new default automatically. Do not
   hand-edit the generated `docker-compose.yml` — its header forbids it.
   The committed compose files embed the tag as their default, so the bump
   must carry a regeneration from a clean checkout or worktree with no `.env`
   (`scripts/generate-compose.sh`) in the same change or the
   `Compose files are current` job fails. Do not delete a working installation's
   `.env` just to produce the repository defaults. Update the README status
   line in the same change: `scripts/readme_lint.py` fails until README links
   the new `VERSION` value and names the new base image tag.
5. Rebuild everything from scratch: `docker compose build --no-cache`
6. Check the build log for the `[build] GitHub CLI keyring fingerprint:` line
   and confirm it matches prior builds (unexpected changes may indicate an
   upstream keyring swap)
