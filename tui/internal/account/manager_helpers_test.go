package account

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/kcenon/claude-docker/tui/internal/auth"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
)

// newTestManager builds a Manager with an isolated HOME so DiscoverStateDirs
// resolves to a tmp dir rather than the real user account state. The caller
// is responsible for creating account-* subdirectories under home/.claude-state
// before invoking discoverStateDirs.
func newTestManager(t *testing.T, env *config.Env) *Manager {
	t.Helper()
	if env == nil {
		env = config.NewEmptyEnv(filepath.Join(t.TempDir(), ".env"))
	}
	// docker.Client with empty project root never has compose containers, so
	// PS() simply returns nil/error (no docker-compose.yml). This keeps the
	// fetchContainerStatus test deterministic without a real docker daemon.
	client := docker.NewClient(t.TempDir(), env)
	return NewManager(env, client)
}

// TestDiscoverStateDirs verifies the helper indexes account directories by
// letter and extends NUM_ACCOUNTS so auto-discovered accounts beyond the
// configured count are still surfaced.
func TestDiscoverStateDirs(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	stateBase := filepath.Join(tmp, ".claude-state")
	for _, name := range []string{"account-a", "account-b", "account-c"} {
		if err := os.MkdirAll(filepath.Join(stateBase, name), 0755); err != nil {
			t.Fatalf("mkdir %s: %v", name, err)
		}
	}

	env := config.NewEmptyEnv(filepath.Join(tmp, ".env"))
	env.Set("NUM_ACCOUNTS", "1")
	m := newTestManager(t, env)

	stateDirs, n := m.discoverStateDirs()

	if n != 3 {
		t.Errorf("n = %d, want 3 (auto-detect should extend beyond NUM_ACCOUNTS=1)", n)
	}
	for _, letter := range []string{"a", "b", "c"} {
		sd, ok := stateDirs[letter]
		if !ok {
			t.Errorf("missing state dir for letter %q", letter)
			continue
		}
		want := filepath.Join(stateBase, "account-"+letter)
		if sd.Path != want {
			t.Errorf("stateDirs[%q].Path = %q, want %q", letter, sd.Path, want)
		}
	}
}

// TestDiscoverStateDirs_EmptyHomeUsesGeneratorDefault covers the first-run
// case where the user has no .claude-state directory or NUM_ACCOUNTS yet. The
// generator default still drives the count.
func TestDiscoverStateDirs_EmptyHomeUsesGeneratorDefault(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	env := config.NewEmptyEnv(filepath.Join(tmp, ".env"))
	m := newTestManager(t, env)

	stateDirs, n := m.discoverStateDirs()
	if n != 2 {
		t.Errorf("n = %d, want 2", n)
	}
	if len(stateDirs) != 0 {
		t.Errorf("stateDirs len = %d, want 0", len(stateDirs))
	}
}

func TestDiscoverStateDirs_CodexRuntime(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	stateBase := filepath.Join(tmp, ".codex-state")
	if err := os.MkdirAll(filepath.Join(stateBase, "account-a"), 0755); err != nil {
		t.Fatalf("mkdir codex state: %v", err)
	}

	env := config.NewEmptyEnv(filepath.Join(tmp, ".env"))
	env.Set("AGENT_RUNTIME", "codex")
	env.Set("NUM_ACCOUNTS", "1")
	m := newTestManager(t, env)

	stateDirs, n := m.discoverStateDirs()
	if n != 1 {
		t.Errorf("n = %d, want 1", n)
	}
	sd, ok := stateDirs["a"]
	if !ok {
		t.Fatal("missing codex state dir for account a")
	}
	if got, want := sd.Path, filepath.Join(stateBase, "account-a"); got != want {
		t.Errorf("codex state path = %q, want %q", got, want)
	}
}

func TestDiscoverStateDirs_GeminiRuntime(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	stateBase := filepath.Join(tmp, ".gemini-state")
	if err := os.MkdirAll(filepath.Join(stateBase, "account-a"), 0755); err != nil {
		t.Fatalf("mkdir gemini state: %v", err)
	}

	env := config.NewEmptyEnv(filepath.Join(tmp, ".env"))
	env.Set("AGENT_RUNTIME", "gemini")
	env.Set("NUM_ACCOUNTS", "1")
	m := newTestManager(t, env)

	stateDirs, n := m.discoverStateDirs()
	if n != 1 {
		t.Errorf("n = %d, want 1", n)
	}
	sd, ok := stateDirs["a"]
	if !ok {
		t.Fatal("missing gemini state dir for account a")
	}
	if got, want := sd.Path, filepath.Join(stateBase, "account-a"); got != want {
		t.Errorf("gemini state path = %q, want %q", got, want)
	}
}

// TestFetchContainerStatus confirms the helper returns an empty map when
// the docker client cannot enumerate containers (no compose project, no
// daemon). The orchestrator must continue to function in this degraded
// state, hence the swallowed error.
func TestFetchContainerStatus(t *testing.T) {
	m := newTestManager(t, nil)
	got := m.fetchContainerStatus()
	if got == nil {
		t.Fatal("fetchContainerStatus returned nil; want non-nil empty map")
	}
	if len(got) != 0 {
		t.Errorf("fetchContainerStatus len = %d, want 0 (no docker available in test env)", len(got))
	}
}

// TestEnrichGHAuth_NotRunning verifies the helper is a no-op for accounts
// whose containers are not running, and does not spawn a goroutine that
// could touch docker in the test environment.
func TestEnrichGHAuth_NotRunning(t *testing.T) {
	m := newTestManager(t, nil)
	var wg sync.WaitGroup

	cases := []struct {
		name string
		acct *Account
	}{
		{"stopped container", &Account{Letter: "a", ContainerStatus: ContainerStopped, ContainerID: "cid"}},
		{"running but no id", &Account{Letter: "a", ContainerStatus: ContainerRunning, ContainerID: ""}},
		{"not created", &Account{Letter: "a", ContainerStatus: ContainerNotCreated}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m.enrichGHAuth(c.acct, &wg)
			wg.Wait() // would deadlock if the helper added to wg by mistake
			if c.acct.GHAuthOK {
				t.Errorf("GHAuthOK = true, want false for %s", c.name)
			}
		})
	}
}

// TestGHAuthVerdict covers the auth verdict logic used by enrichGHAuth. The
// container check switched from `gh auth status` to `gh api user` because
// `gh auth status` exits non-zero when the mounted host gh config exposes an
// unusable `default` account alongside a working GH_TOKEN. The verdict must
// follow the command exit code: `gh api user` succeeding (exit 0) means the
// credential is valid even in that mixed-config case where `gh auth status`
// would fail.
func TestGHAuthVerdict(t *testing.T) {
	// A real exit-0 command stands in for `gh api user` succeeding.
	if err := exec.Command("true").Run(); err != nil {
		t.Fatalf("setup: `true` should exit 0: %v", err)
	} else if !ghAuthVerdict(err) {
		t.Error("ghAuthVerdict(nil) = false, want true (gh api user succeeded)")
	}

	// A real non-zero exit stands in for `gh auth status` style failure:
	// the verdict must be false so a failed check is not reported as OK.
	failErr := exec.Command("false").Run()
	if failErr == nil {
		t.Fatal("setup: `false` should exit non-zero")
	}
	if ghAuthVerdict(failErr) {
		t.Error("ghAuthVerdict(exit-error) = true, want false (command exited non-zero)")
	}
}

// TestEnrichAPIUsage_NonOAuthIsNoop verifies API usage enrichment skips
// accounts that don't have OAuth credentials (API key auth, no auth).
func TestEnrichAPIUsage_NonOAuthIsNoop(t *testing.T) {
	m := newTestManager(t, nil)
	results := make(map[string]apiResult)
	var mu sync.Mutex
	var wg sync.WaitGroup

	for _, authType := range []AuthType{AuthNone, AuthAPIKey} {
		acct := &Account{Letter: "a", AuthType: authType, StateDirPath: t.TempDir()}
		m.enrichAPIUsage(acct, results, &mu, &wg)
		wg.Wait()
		if acct.LastAPIStatus != "" {
			t.Errorf("auth=%v: LastAPIStatus = %q, want empty (helper should be no-op)", authType, acct.LastAPIStatus)
		}
	}
	if len(results) != 0 {
		t.Errorf("results len = %d, want 0", len(results))
	}
}

func TestBuildAccounts_CodexRuntime(t *testing.T) {
	tmp := t.TempDir()
	env := config.NewEmptyEnv(filepath.Join(tmp, ".env"))
	env.Set("AGENT_RUNTIME", "codex")
	env.Set("CODEX_API_KEY_A", "sk-openai")
	m := newTestManager(t, env)

	stateDir := config.StateDir{Letter: "a", Path: t.TempDir()}
	accounts := m.buildAccounts(1, map[string]config.StateDir{"a": stateDir}, map[string]docker.ContainerInfo{})
	if len(accounts) != 1 {
		t.Fatalf("len(accounts) = %d, want 1", len(accounts))
	}
	if got := accounts[0].ServiceName; got != "codex-a" {
		t.Errorf("ServiceName = %q, want codex-a", got)
	}
	if got := accounts[0].AuthType; got != AuthAPIKey {
		t.Errorf("AuthType = %v, want AuthAPIKey", got)
	}
}

// TestEnrichAPIUsage_CachedFresh verifies that an account whose limitline
// cache already supplied a FiveHourUsage value is marked "cached (fresh)"
// and skips the API call entirely (no goroutine spawned, no results).
func TestEnrichAPIUsage_CachedFresh(t *testing.T) {
	m := newTestManager(t, nil)
	results := make(map[string]apiResult)
	var mu sync.Mutex
	var wg sync.WaitGroup

	acct := &Account{
		Letter:        "a",
		AuthType:      AuthOAuth,
		StateDirPath:  t.TempDir(),
		FiveHourUsage: &UsageBucket{PercentUsed: 42},
	}
	m.enrichAPIUsage(acct, results, &mu, &wg)
	wg.Wait()

	if acct.LastAPIStatus != "cached (fresh)" {
		t.Errorf("LastAPIStatus = %q, want %q", acct.LastAPIStatus, "cached (fresh)")
	}
	if len(results) != 0 {
		t.Errorf("results len = %d, want 0 (cached should not record an API result)", len(results))
	}
}

// TestEnrichAPIUsage_CooldownActive verifies that an account inside the
// per-account cooldown window is marked rate-limited and skips the API.
func TestEnrichAPIUsage_CooldownActive(t *testing.T) {
	m := newTestManager(t, nil)
	results := make(map[string]apiResult)
	var mu sync.Mutex
	var wg sync.WaitGroup

	dir := t.TempDir()
	cooldownPath := filepath.Join(dir, apiCooldownFile)
	now := time.Now().UnixMilli()
	if err := os.WriteFile(cooldownPath, []byte(fmt.Sprintf("%d", now)), 0644); err != nil {
		t.Fatalf("write cooldown: %v", err)
	}

	acct := &Account{Letter: "a", AuthType: AuthOAuth, StateDirPath: dir}
	m.enrichAPIUsage(acct, results, &mu, &wg)
	wg.Wait()

	if !acct.APIRateLimited {
		t.Error("APIRateLimited = false, want true")
	}
	if acct.LastAPIStatus != "skipped (cooldown active)" {
		t.Errorf("LastAPIStatus = %q, want %q", acct.LastAPIStatus, "skipped (cooldown active)")
	}
	if len(results) != 0 {
		t.Errorf("results len = %d, want 0", len(results))
	}
}

// TestWriteCacheUpdates verifies a successful API result is persisted to
// the limitline cache file in the account's state directory, in the same
// JSON shape that parseLimitlineCache will later read back.
func TestWriteCacheUpdates(t *testing.T) {
	m := newTestManager(t, nil)

	dir := t.TempDir()
	resp := &auth.UsageAPIResponse{
		FiveHour: &auth.UsageBucket{
			Utilization: 17,
			ResetsAt:    time.Now().Add(1 * time.Hour).Format(time.RFC3339),
		},
		SevenDay: &auth.UsageBucket{
			Utilization: 100,
			ResetsAt:    time.Now().Add(48 * time.Hour).Format(time.RFC3339),
		},
	}
	results := map[string]apiResult{
		"a": {stateDirPath: dir, resp: resp},
	}
	accounts := []Account{{Letter: "a"}}

	m.writeCacheUpdates(accounts, results)

	cachePath := filepath.Join(dir, "limitline-usage-cache.json")
	if _, err := os.Stat(cachePath); err != nil {
		t.Fatalf("expected cache file at %s: %v", cachePath, err)
	}
	// Parse the file back through the existing parser to confirm round-trip.
	five, seven := parseLimitlineCache(cachePath)
	if five == nil {
		t.Fatal("parsed FiveHourUsage = nil, want populated")
	}
	if five.PercentUsed != 17 {
		t.Errorf("FiveHourUsage.PercentUsed = %d, want 17", five.PercentUsed)
	}
	if seven == nil {
		t.Fatal("parsed SevenDayUsage = nil, want populated")
	}
	if !seven.IsOverLimit {
		t.Error("SevenDayUsage.IsOverLimit = false, want true (utilization >= 100)")
	}
}

// TestWriteCacheUpdates_NoResults verifies the helper is a no-op when the
// API enrichment phase produced nothing (every account was cached, in
// cooldown, or non-OAuth).
func TestWriteCacheUpdates_NoResults(t *testing.T) {
	m := newTestManager(t, nil)
	dir := t.TempDir()
	accounts := []Account{{Letter: "a", StateDirPath: dir}}
	m.writeCacheUpdates(accounts, map[string]apiResult{})

	cachePath := filepath.Join(dir, "limitline-usage-cache.json")
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Errorf("cache file should not exist, stat err = %v", err)
	}
}
