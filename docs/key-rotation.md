# Key Rotation Procedure

Procedures for rotating secrets used by the claude-docker orchestration system.

## Secrets Inventory

| Secret | Location | Purpose | Rotation trigger |
|--------|----------|---------|-----------------|
| `WORKER_AUTH_TOKEN` | `.env` | Bearer token for worker HTTP API authentication | Compromise, routine (quarterly) |
| `REDIS_PASSWORD` | `.env` | Redis `--requirepass` authentication | Compromise, routine (quarterly) |
| `ANTHROPIC_API_KEY_*` | `.env` | Anthropic Console API access | Compromise, staff change, routine (per Anthropic policy) |
| OAuth credentials | `~/.claude-state/account-*/` | Subscription account access | Compromise, account revocation, token expiry |

---

## Rotating `WORKER_AUTH_TOKEN` and `REDIS_PASSWORD`

These two secrets are injected into all orchestration containers at startup via
environment variables. Rotation requires stopping the orchestration stack,
updating `.env`, and restarting.

### Procedure

**1. Generate new secrets.**

```bash
NEW_WORKER_AUTH_TOKEN=$(openssl rand -hex 32)
NEW_REDIS_PASSWORD=$(openssl rand -hex 32)
echo "New WORKER_AUTH_TOKEN: $NEW_WORKER_AUTH_TOKEN"
echo "New REDIS_PASSWORD:    $NEW_REDIS_PASSWORD"
```

**2. Save the current session (if an analysis is in progress).**

```bash
scripts/claude-docker save
```

Verify the archive:

```bash
scripts/claude-docker sessions
```

**3. Stop the orchestration stack.**

```bash
scripts/claude-docker down
```

All in-flight tasks are abandoned. Complete or cancel them before stopping if
possible.

**4. Update `.env`.**

Open `.env` and replace the old values:

```bash
# Cross-platform (macOS + Linux)
perl -i -pe "s/^WORKER_AUTH_TOKEN=.*/WORKER_AUTH_TOKEN=${NEW_WORKER_AUTH_TOKEN}/" .env
perl -i -pe "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=${NEW_REDIS_PASSWORD}/" .env
```

Verify the update (values should not be empty):

```bash
grep "WORKER_AUTH_TOKEN\|REDIS_PASSWORD" .env
```

**5. Restart the stack.**

```bash
scripts/claude-docker up
```

The new secrets are injected automatically via Docker Compose environment
variable substitution. Redis starts with the new `--requirepass` value; all
containers receive the updated `WORKER_AUTH_TOKEN` and `REDIS_PASSWORD`.

**6. Verify.**

```bash
# Check Redis connectivity (should print PONG)
scripts/claude-docker status

# Dispatch a test task
scripts/claude-docker dispatch worker-1 "echo rotation test"
```

**7. Destroy the old secret values from your shell history.**

```bash
history -d $(history 1 | awk '{print $1}')   # bash
# or clear the specific history entry manually
```

---

## Rotating `ANTHROPIC_API_KEY_*`

### When to rotate

- Immediate: key exposed in logs, version control, or to unauthorized parties
- Planned: staff departure with key access, or per your organization's API key
  rotation policy

### Procedure

**1. Generate a new key** in the [Anthropic Console](https://console.anthropic.com/)
under **API Keys**. Do not delete the old key yet.

**2. Stop the affected containers.**

```bash
scripts/claude-docker down
```

**3. Update `.env`.**

Replace the old key value for the affected account(s):

```
CLAUDE_API_KEY_1=sk-ant-<new-key>
```

**4. Restart and verify.**

```bash
scripts/claude-docker up
scripts/claude-docker exec worker-1 claude --version   # smoke test
```

**5. Revoke the old key** in the Anthropic Console once the new key is verified.

---

## Rotating OAuth Tokens (Path A — Subscription Accounts)

OAuth tokens auto-refresh while the `refreshToken` in `.credentials.json` is
valid. Manual rotation is needed when:

- The account password is changed
- The account session is revoked (by the user or Anthropic)
- The token file is corrupted or deleted
- You suspect credential compromise

### macOS

```bash
# 1. Re-authenticate on the host
claude auth login

# 2. Re-inject credentials into all containers
scripts/claude-docker auth

# 3. Verify
scripts/claude-docker exec manager claude auth status
scripts/claude-docker exec worker-1 claude auth status
```

### Linux / WSL2

```bash
# Re-authenticate inside each container
scripts/claude-docker exec manager claude auth login
scripts/claude-docker exec worker-1 claude auth login
scripts/claude-docker exec worker-2 claude auth login
scripts/claude-docker exec worker-3 claude auth login
```

Each `claude auth login` command prints a URL; open it in a browser and
complete OAuth. The token is saved to the bind-mounted state directory and
persists across container restarts.

---

## Emergency Rotation (Suspected Compromise)

If you suspect any secret has been compromised, follow these steps in order:

1. **Stop all containers immediately.**

   ```bash
   scripts/claude-docker down
   ```

2. **Revoke the compromised credential** at the source:
   - API key: revoke in Anthropic Console
   - OAuth token: change Anthropic account password, which invalidates all
     refresh tokens
   - `WORKER_AUTH_TOKEN` / `REDIS_PASSWORD`: rotate as above (no external
     revocation needed — they are local secrets)

3. **Audit container logs** for unauthorized task executions.

   ```bash
   scripts/claude-docker logs | grep '"event":"task'
   ```

4. **Rotate all orchestration secrets** (`WORKER_AUTH_TOKEN`, `REDIS_PASSWORD`)
   as described above, even if only one appears compromised.

5. **Inspect `.env` and state directories** for unexpected modifications.

   ```bash
   ls -la .env ~/.claude-state/account-*/
   stat -f "%Sp %Su %N" .env   # macOS
   stat -c "%A %U %n" .env     # Linux
   ```

6. **Restart with new secrets.**

   ```bash
   scripts/claude-docker up
   ```

7. **Document the incident**: what was exposed, when, and what was rotated.

---

## Rotation Schedule

| Secret | Recommended interval | Trigger for immediate rotation |
|--------|---------------------|-------------------------------|
| `WORKER_AUTH_TOKEN` | Quarterly | Compromise, container escape |
| `REDIS_PASSWORD` | Quarterly | Compromise, container escape |
| `ANTHROPIC_API_KEY_*` | Per Anthropic policy | Exposure, staff change |
| OAuth tokens | Automatic (auto-refresh) | Account password change, revocation |

---

## Verifying Secret Hygiene

Run these checks periodically to ensure secrets are not exposed:

```bash
# Confirm .env is not tracked by git
git ls-files .env && echo "WARNING: .env is tracked" || echo "OK: .env not tracked"

# Confirm .env permissions are 0600
ls -la .env     # should show -rw-------

# Confirm state directory permissions are 0700
ls -ld ~/.claude-state/account-*/   # should show drwx------

# Confirm credential files are 0600
find ~/.claude-state -name ".credentials.json" -ls 2>/dev/null

# Scan git history for accidental secret commits
git log --all --diff-filter=A --name-only --pretty=format: | grep "^\.env$"
```

---

## References

- [threat-model.md](threat-model.md) — STRIDE analysis of threats these rotations mitigate
- [architecture.md — Authentication Strategy](architecture.md#authentication-strategy)
- [install.sh](../scripts/install.sh) — Auto-generation of `WORKER_AUTH_TOKEN` and `REDIS_PASSWORD`
