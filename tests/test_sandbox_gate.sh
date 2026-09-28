#!/usr/bin/env bash
# Tests gate behavior with deterministic dependencies, not kernel support.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/account" "$WORK/project"
cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
echo "${FIXTURE_CLAUDE_VERSION:-2.1.83} (Claude Code)"
SH
cat > "$WORK/bin/bwrap" <<'SH'
#!/usr/bin/env bash
printf 'probe\n' >> "$FIXTURE_PROBE_LOG"
exit "${FIXTURE_PROBE_FAILURE:-0}"
SH
cat > "$WORK/bin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/socat"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" FIXTURE_PROBE_LOG="$WORK/probes"
export ISOLATION_MODE=isolated AGENT_RUNTIME=claude CLAUDE_CONFIG_DIR="$WORK/account"
cd "$WORK/project"
. "$ROOT/scripts/lib/bootstrap-sandbox.sh"
passed=0
settings() { printf '%s\n' "$1" > "$WORK/account/settings.json"; }
settings '{"sandbox":{"enabled":true},"permissions":{"deny":["Read(**/.env)"]}}'
runtime_sandbox_check >/dev/null
jq -e '.sandbox.enabled and .sandbox.failIfUnavailable and (.sandbox.allowUnsandboxedCommands == false) and (.permissions.deny == ["Read(**/.env)"])' "$WORK/account/settings.json" >/dev/null
passed=$((passed+1))
for failure in dependency version weaker malformed; do
    settings '{"sandbox":{"enabled":true}}'
    case "$failure" in
        dependency) export FIXTURE_PROBE_FAILURE=1 CLAUDE_ALLOW_DEGRADED_SETTINGS=1 ;;
        version) export FIXTURE_CLAUDE_VERSION=2.1.82 ;;
        weaker) settings '{"sandbox":{"enabled":true,"enableWeakerNestedSandbox":true}}' ;;
        malformed) settings '{' ;;
    esac
    if runtime_sandbox_check > "$WORK/failure.log" 2>&1; then
        echo "FAIL: sandbox gate accepted $failure" >&2; exit 1
    fi
    passed=$((passed+1))
    unset FIXTURE_PROBE_FAILURE FIXTURE_CLAUDE_VERSION CLAUDE_ALLOW_DEGRADED_SETTINGS
done
# The real entrypoint must run this gate without a shared configuration source.
settings '{"sandbox":{"enabled":true}}'
if CLAUDE_DOCKER_ROOT="$ROOT" CLAUDE_CONFIG_SOURCE="$WORK/absent" FIXTURE_PROBE_FAILURE=1 \
    CLAUDE_ALLOW_DEGRADED_SETTINGS=1 bash "$ROOT/scripts/entrypoint.sh" touch "$WORK/executed" > "$WORK/entrypoint.log" 2>&1; then
    echo 'FAIL: entrypoint accepted unsupported requested sandbox' >&2; exit 1
fi
test ! -e "$WORK/executed"
grep -q 'refusing the requested command' "$WORK/entrypoint.log"
passed=$((passed+1))
test -s "$WORK/probes"
printf 'sandbox gate: executed=%s passed=%s\n' "$passed" "$passed"
