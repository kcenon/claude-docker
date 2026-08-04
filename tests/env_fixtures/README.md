# Compose validation fixtures

Used by `.github/workflows/ci.yml` `compose-validate` matrix. Each `*.env` file
is copied to the repo root as `.env`, then `scripts/generate-compose.sh` and
`docker compose config` run against it.

`tests/test_compose_generator_equivalence.sh` is a second consumer: it stages
`minimal`, `codex`, `gemini`, `github-per-account`, and `n5` into throwaway
sandboxes and asserts the bash and PowerShell generators produce the same
files. It adds one input the table below cannot express — `NUM_ACCOUNTS` and
`IMAGE_TAG` supplied through the environment instead of a `.env` file, which
is the path #315 fixed.

| Fixture | Exercises |
|---------|-----------|
| `minimal.env` | Default 2-account Tier A setup without API keys |
| `tier-b.env` | Worktree paths (`PROJECT_DIR_A/B`, `CONTAINER_PROJECT_DIR_A/B`) |
| `n5.env` | `NUM_ACCOUNTS=5` scaling path (claude-a..claude-e) |
| `n30.env` | `NUM_ACCOUNTS=30` Excel-style letter enumeration (#178) |
| `with-special-chars.env` | Values containing `#`, `=`, quotes, whitespace — exercises the #170 parser |
| `codex.env` | `AGENT_RUNTIME=codex` runtime selection (codex-a/codex-b services) |
| `gemini.env` | `AGENT_RUNTIME=gemini` runtime selection (gemini-a/gemini-b services, #272) |
| `github-per-account.env` | Two isolated GitHub logins/tokens and account A Git identity overrides |

## Running locally

```bash
cd claude-docker
cp tests/env_fixtures/n5.env .env
bash scripts/generate-compose.sh
docker compose config > /dev/null && echo OK
```

Clean up afterwards so the fixture `.env` does not leak into day-to-day runs:

```bash
git checkout -- .env 2>/dev/null || rm .env
```
