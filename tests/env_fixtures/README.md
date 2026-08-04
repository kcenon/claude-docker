# Compose validation fixtures

The Compose fixtures listed in the first table are used by the
`.github/workflows/ci.yml` `compose-validate` matrix. Each selected fixture is
copied to the repo root as `.env`, then `scripts/generate-compose.sh` and
`docker compose config` run against it. Not every `*.env` file in this
directory belongs to that matrix; parser-only fixtures are listed separately.

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

Parser tests use these additional fixtures without generating Compose files:

| Fixture | Exercises |
|---------|-----------|
| `edge-cases.env` | Comments, empty values, quotes, embedded `#`/`=`, and whitespace |
| `duplicate-keys.env` | Last-definition-wins behavior for repeated keys |

## Running locally

```bash
cd claude-docker

# Refuse to overwrite a real installation or unrelated generated-file edits.
if [ -e .env ]; then
  echo "Refusing to replace existing .env" >&2
  exit 1
fi
if ! git diff --quiet -- \
  docker-compose.yml docker-compose.linux.yml docker-compose.worktree.yml; then
  echo "Refusing to replace modified Compose files" >&2
  exit 1
fi

trap 'rm -f .env; git restore -- docker-compose.yml docker-compose.linux.yml docker-compose.worktree.yml' EXIT
cp tests/env_fixtures/n5.env .env
bash scripts/generate-compose.sh
docker compose config > /dev/null && echo OK
```

The `EXIT` trap removes only the fixture `.env` (the guard proved it did not
exist beforehand) and restores only Compose files that the second guard proved
were clean. Run the equivalent test in a disposable clone on native Windows;
the fixture workflow itself is Bash-based and runs on Linux CI.
