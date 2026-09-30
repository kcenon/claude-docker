# README Evidence Policy

The root [README](../README.md) is the entry page: status and version, features,
prerequisites, platform support, quick start, the command quick reference, and
short summaries that link to the reference pages in this directory. It must be
nonempty and at most 300 physical lines, including code, comments, and blank
lines. When a README section grows past one screen (about 50 lines), move it to
a `docs/` page and link it. Do not compress unrelated paragraphs or add filler to
meet the limit.

## Local Check

Run from the repository root:

```sh
python3 tests/test_readme_lint.py
python3 scripts/readme_lint.py
```

The [standard-library linter](../scripts/readme_lint.py) checks `README.md` by
default, resolves paths from its own checkout, and accepts explicit file paths
and `--root` for other checkouts or fixtures. Findings use
`path:line: rule: message`. Violations and unreadable files return a nonzero
status. It never uses the network and runs on the repository's Python 3.9
floor. [Documentation Audit](../.github/workflows/doc-audit.yml) runs the tests
and the linter on every pull request and on pushes to `main`. The `Dockerfile`
copies only `scripts/entrypoint.sh`, `scripts/lib/` and the runtime registry,
so the linter never reaches the image.

## Status and Version

After the title, and within the first 20 lines, show `Status: active`,
`Status: maintenance`, or `Status: experimental`. The status describes project
activity, not quality.

This repository publishes no GitHub releases, and pushing a `v*` tag publishes
TUI binaries through `release-tui.yml`, so the README cannot point at a release
tag. The same first 20 lines carry two values read from the tree instead:

- a link labelled with the `VERSION` value that targets the `VERSION` file, or
  the `v<VERSION>` release tag should one exist. `VERSION` is the image tag the
  compose generators and installers default to.
- the base image tag from the `Dockerfile`'s single `FROM` line, without the
  digest.

A change that bumps either value therefore updates the README status line, or
the linter fails; see [Bumping the Base Image](MAINTENANCE.md#bumping-the-base-image).

## Badges

Use badges only for workflows in this repository. The image URL and the click
URL must name the same `.yml` or `.yaml` file in `.github/workflows/`, and that
file must exist. Keep license and service links as prose.

## Claims and Density

Remove promotional qualifiers, including production-ready, enterprise-grade,
battle-tested, blazing, world-class, comprehensive, robust, seamless, 100%,
guaranteed, and zero-overhead, zero-warning, zero-leak, or zero-race wording. A
citation does not exempt a banned qualifier. Describe a capability by what the
repository shows, such as the check a script performs or the test that
exercises it.

The linter recognizes speedup multipliers, latency and throughput units,
percentages, test pass counts, and allocation counts in visible prose.
Measurement tables belong in a `docs/` page, even when sourced. Account counts,
versions, dates, configuration defaults, list numbers, link destinations, and
fenced or indented code are not measurements.

Density is `100 * distinct prose lines containing a qualifier or measurement /
total physical lines`. The maximum is 1.0 per 100 lines.

A headline figure may stay in the README only with an adjacent marker. The
marker links a `docs/` section that names the environment, date, command, and
raw result; [PERFORMANCE.md](PERFORMANCE.md) is the page for measured numbers:

```markdown
Measured claim. <!-- source: docs/<page>.md#<anchor> (YYYY-MM-DD, <environment>) -->
```

The parser checks marker structure and local links, not whether the measurement
supports the claim. Reviewers check that. A figure the linter does not
recognize, such as a disk-size comparison, is still a claim: remove it or give
it the same kind of source.

## Provenance

`scripts/readme_lint.py` is a port of the kcenon/common_system README lint at
commit `c2f4037`, by way of the kcenon/dcmtk-docker port at `7953067`, with the
same qualifier, measurement, marker, badge, length and density rules. It checks
only `README.md` and replaces the release-link rule with the `VERSION` and base
image checks above. It keeps the upstream Korean patterns, so later upstream
fixes stay easy to carry over. Like upstream, it reads an image dimension such
as `512x512` as a speedup (kcenon/dcmtk-docker#109).
