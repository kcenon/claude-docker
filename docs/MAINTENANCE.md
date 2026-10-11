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

### Completing a Dependabot Base Image PR

Dependabot version updates target `develop`. A Docker update normally changes
only the `FROM` tag and digest. The image-version freshness and README checks
then fail until a maintainer adds the synchronization commit below.
Security updates target `main`; follow the same checks there, then the
`main` to `develop` synchronization rule in [CONTRIBUTING.md](../CONTRIBUTING.md).

1. **Verify the proposed digest independently.** Read the tag and digest from
   the PR's `FROM` line, then query Docker Hub from a trusted host:

   ```sh
   candidate_node='<version-from-PR>'
   curl -fsS "https://hub.docker.com/v2/repositories/library/node/tags/${candidate_node}-slim" | jq -r .digest
   curl -fsS "https://hub.docker.com/v2/repositories/library/node/tags/${candidate_node}-trixie-slim" | jq -r .digest
   ```

   Both results must equal the PR's digest to retain README's Debian trixie
   description. An authenticated registry manifest HEAD request and its
   `docker-content-digest` header are an alternative; request the multi-platform
   index rather than comparing a single-platform child manifest. If a tag has
   moved, investigate the exact proposed digest instead of silently substituting
   another image. Resolve any distribution change before updating the prose.

2. **Push a synchronization commit onto the Dependabot branch.** Check out its
   current head in a clean worktree. Retain the verified `FROM` change and update:

   | File | Synchronization |
   |---|---|
   | `VERSION` | Today's date, strictly later than the current image version. |
   | `Dockerfile` | The `Base:` and `digest-pinned` comments name the new tag. |
   | `docs/MAINTENANCE.md` | The current base declaration at the top names the new tag. |
   | `README.md` | The status line names both the new VERSION and base image. |
   | `docker-compose*.yml` | Regenerate using `bash scripts/generate-compose.sh` without a `.env` present. |

   Keep any installation's `.env` intact. With unchanged generator defaults,
   only image-tag defaults in `docker-compose.yml` should change; inspect any
   other generated difference. If today's date is already in VERSION, combine
   still-unpublished changes into the same planned image or wait for a later
   date before publishing a different image. Do not reuse a published tag or
   invent an unimplemented version suffix. Updating an existing PR's planned
   image must still leave VERSION changed relative to its base.

   A maintainer commit stops Dependabot from automatically rebasing that PR.
   Maintain its branch explicitly and retain the bot's original update.
   Run README/docs lint, docs contracts, Compose freshness and the applicable
   image checks; wait for the PR's CI to pass.

3. **Compare the build's keyring fingerprints.** Open the CI job named
   `Isolated mode: real containers` and find the
   `[build] GitHub CLI keyring fingerprint:` output. Compare the full key list
   and validity dates with a previous trusted build. Investigate unexpected
   additions, removals or expiry changes against the upstream key publication;
   a historical fingerprint alone is not a permanent allowlist. Record the
   compared run IDs and result in the PR.

4. **Squash with the dependency update subject.** After the checks and review,
   use `build(deps): bump node from <old>-slim to <new>-slim (#N)`. Include the
   synchronization and digest/keyring verification in the squash body.

Decision for #421: current Node base references are enforced by
`tests/test_docs_contracts.sh`. It compares concrete tags in Dockerfile comments
and this page's visible prose with `FROM`, asserts that the expected references
exist, and ignores fenced historical examples. Its behavior tests deliberately
introduce stale tags. The first actual Dependabot Docker update on `develop`
provides the live check of the complete procedure.
