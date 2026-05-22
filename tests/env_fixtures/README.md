# Compose validation fixtures

Used by `.github/workflows/ci.yml` `compose-validate` matrix. Each `*.env` file
is copied to the repo root as `.env`, then `scripts/generate-compose.sh` and
`docker compose config` run against it.

| Fixture | Exercises |
|---------|-----------|
| `minimal.env` | Default 2-account Tier A setup without API keys |
| `tier-b.env` | Worktree paths (`PROJECT_DIR_A/B`, `CONTAINER_PROJECT_DIR_A/B`) |
| `n5.env` | `NUM_ACCOUNTS=5` scaling path (claude-a..claude-e) |
| `n30.env` | `NUM_ACCOUNTS=30` Excel-style letter enumeration (#178) |
| `with-special-chars.env` | Values containing `#`, `=`, quotes, whitespace — exercises the #170 parser |
| `codex.env` | `AGENT_RUNTIME=codex` runtime selection (codex-a/codex-b services) |
| `gemini.env` | `AGENT_RUNTIME=gemini` runtime selection (gemini-a/gemini-b services, #272) |

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
