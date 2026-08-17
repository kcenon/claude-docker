<!--
Base this PR on `develop`. `main` takes releases only.
See CONTRIBUTING.md for the cross-language parity rule these boxes are about.
-->

## What

<!-- The change, in a sentence or two. -->

## Why

<!--
The problem it solves. If this is a fix, say what the defect did to a user,
not only what the code did wrong.
-->

Closes #

## How

<!-- Anything a reviewer would otherwise have to reconstruct from the diff. -->

## Verification

<!--
What you ran, and what it said. Paste the failure the fix removes; a claim
that a test passes is weaker than a quote of it failing before the fix.
-->

---

### Cross-language parity

Most rules in this repository are implemented more than once. Tick what applies
and say **not applicable** where it does not — an unticked box with no reason
reads as an oversight.

- [ ] I changed a rule that exists in more than one of: `scripts/lib/*.sh`,
      `scripts/*.ps1` / `ClaudeDocker.psm1` / `scripts/lib/index.ps1`,
      `tui/internal/config`, `scripts/entrypoint.sh` — and **all** the copies
      move in this PR
- [ ] Per-runtime values (binary, build arg, state dir, config paths) are read
      from `tui/internal/config/runtimes.json`, not restated
- [ ] An equivalence test covers the rule I changed, or this PR adds one
- [ ] `docker-compose*.yml` regenerated if the generator changed
      (`rm -f .env && bash scripts/generate-compose.sh`)
- [ ] `VERSION` bumped if anything the `Dockerfile` `COPY`s changed — without
      it the change never reaches an existing installation

### Checks

- [ ] The new test fails against the unfixed code (quoted above)
- [ ] bash changes stay within bash 3.2 (macOS `/bin/bash`)
- [ ] No secrets, tokens or credentials in the diff
