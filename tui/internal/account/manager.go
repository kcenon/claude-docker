package account

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/kcenon/claude-docker/tui/internal/auth"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
	"github.com/kcenon/claude-docker/tui/internal/usage"
)

// Manager provides CRUD operations on accounts.
type Manager struct {
	env    *config.Env
	client *docker.Client
	// usageCache memoizes parsed JSONL session files across ListAccounts
	// calls. Unchanged files (same size+mtime) are returned from the cache
	// instead of being re-read and re-decoded, which keeps refresh cost
	// proportional to changed data rather than total accumulated history.
	usageCache *usage.Cache
	// cooldowns tracks per-account API backoff in memory. It was a file in
	// each state directory until #358; see apiCooldowns for why that was a
	// worse place for a 25-second value with no cross-process reader.
	cooldowns *apiCooldowns
}

// NewManager creates an account manager.
func NewManager(env *config.Env, client *docker.Client) *Manager {
	return &Manager{
		env:        env,
		client:     client,
		usageCache: usage.NewCache(),
		cooldowns:  newAPICooldowns(),
	}
}

// ListAccounts returns all configured accounts with enriched runtime status.
//
// The method is a thin orchestrator over five focused helpers (defined in
// manager_helpers.go); each helper owns one phase of the listing workflow.
// Side-effects (cache writes, cooldown writes) and error policy match the
// previous monolithic impl: non-fatal phases swallow their errors and
// degrade gracefully.
func (m *Manager) ListAccounts() ([]Account, error) {
	stateDirs, n := m.discoverStateDirs()
	containerMap := m.fetchContainerStatus()
	accounts := m.buildAccounts(n, stateDirs, containerMap)
	apiResults := m.enrichAccounts(accounts)
	m.writeCacheUpdates(accounts, apiResults)
	return accounts, nil
}

// detectAuthType resolves an account's authentication method from the
// runtime registry, with no per-runtime branching. Runtimes that expose a
// Claude-style OAuth usage endpoint (SupportsUsage) treat an OAuth
// credential as AuthOAuth and rank it above an API key; other runtimes
// treat the credential as opaque login state (AuthLogin) and rank an API
// key first. A nil env degrades to a Claude-shaped lookup.
func detectAuthType(sd config.StateDir, env *config.Env, letter string) AuthType {
	spec, _ := config.LookupRuntime(config.RuntimeClaude)
	apiKey := ""
	if env != nil {
		spec = env.RuntimeSpec()
		apiKey = env.APIKey(letter)
	}
	if spec.SupportsUsage {
		if sd.HasAnyCredential(spec) {
			return AuthOAuth
		}
		if apiKey != "" {
			return AuthAPIKey
		}
		return AuthNone
	}
	if apiKey != "" {
		return AuthAPIKey
	}
	if sd.HasAnyCredential(spec) {
		return AuthLogin
	}
	return AuthNone
}

// limitlineCache matches the structure of limitline-usage-cache.json
type limitlineCache struct {
	Usage struct {
		FiveHour *limitlineBucket `json:"fiveHour"`
		SevenDay *limitlineBucket `json:"sevenDay"`
	} `json:"usage"`
}

type limitlineBucket struct {
	PercentUsed int    `json:"percentUsed"`
	IsOverLimit bool   `json:"isOverLimit"`
	ResetAt     string `json:"resetAt"`
}

func parseLimitlineCache(path string) (*UsageBucket, *UsageBucket) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil
	}

	var cache limitlineCache
	if err := json.Unmarshal(data, &cache); err != nil {
		return nil, nil
	}

	now := time.Now()
	var fiveHour, sevenDay *UsageBucket

	// Only return data if its reset time is in the future (data still valid for current period)
	if cache.Usage.FiveHour != nil && !isResetPassed(cache.Usage.FiveHour.ResetAt, now) {
		fiveHour = &UsageBucket{
			PercentUsed: cache.Usage.FiveHour.PercentUsed,
			IsOverLimit: cache.Usage.FiveHour.IsOverLimit,
			ResetAt:     cache.Usage.FiveHour.ResetAt,
		}
	}

	if cache.Usage.SevenDay != nil && !isResetPassed(cache.Usage.SevenDay.ResetAt, now) {
		sevenDay = &UsageBucket{
			PercentUsed: cache.Usage.SevenDay.PercentUsed,
			IsOverLimit: cache.Usage.SevenDay.IsOverLimit,
			ResetAt:     cache.Usage.SevenDay.ResetAt,
		}
	}

	return fiveHour, sevenDay
}

// isResetPassed returns true if the reset time has already passed (data is from a previous period).
func isResetPassed(resetAt string, now time.Time) bool {
	if resetAt == "" {
		return true // no reset time = treat as expired
	}
	t, err := time.Parse(time.RFC3339, resetAt)
	if err != nil {
		// Try without nano precision
		t, err = time.Parse("2006-01-02T15:04:05.000Z", resetAt)
		if err != nil {
			return true
		}
	}
	return now.After(t)
}

// writeLimitlineCache writes API response to disk in the same format as
// claude-limitline. Returns an error so the caller can decide; the write is
// still best-effort, but "best-effort" now means a caller chose to ignore it
// rather than the function having nothing to report.
func writeLimitlineCache(path string, resp *auth.UsageAPIResponse) error {
	cache := map[string]interface{}{
		"timestamp": time.Now().UnixMilli(),
		"usage": map[string]interface{}{
			"fiveHour": func() interface{} {
				if resp.FiveHour == nil {
					return nil
				}
				return map[string]interface{}{
					"percentUsed": int(resp.FiveHour.Utilization),
					"isOverLimit": resp.FiveHour.Utilization >= 100,
					"resetAt":     resp.FiveHour.ResetsAt,
				}
			}(),
			"sevenDay": func() interface{} {
				if resp.SevenDay == nil {
					return nil
				}
				return map[string]interface{}{
					"percentUsed": int(resp.SevenDay.Utilization),
					"isOverLimit": resp.SevenDay.Utilization >= 100,
					"resetAt":     resp.SevenDay.ResetsAt,
				}
			}(),
		},
	}

	data, err := json.Marshal(cache)
	if err != nil {
		return fmt.Errorf("marshal limitline cache: %w", err)
	}
	return writeFileAtomic(path, data)
}

// writeFileAtomic writes data to path through a temp file in the same
// directory, chmods it 0600, and renames it into place (#358, item 5).
//
// Two reasons, both real for limitline-usage-cache.json:
//
//   - The host's claude-limitline tool writes the same file. os.WriteFile
//     truncates and then writes, so a read interleaved with it sees a
//     truncated document; parseLimitlineCache returns (nil, nil) for that and
//     the dashboard draws "--" with nothing said about why. A rename is
//     atomic, so a reader sees either the old file or the new one.
//   - 0644 made a file describing an account's API usage world-readable. 0600
//     matches what Env.Save already does for .env, and what install.sh sets
//     for the credentials file next to it.
//
// The sequence is Env.Save's; it existed in-tree and was simply not applied
// here.
func writeFileAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create tmp: %w", err)
	}
	tmpName := tmp.Name()
	// Removes the temp file on every failure path below; a no-op once the
	// rename has consumed it.
	defer os.Remove(tmpName)

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("write tmp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close tmp: %w", err)
	}
	if err := os.Chmod(tmpName, 0600); err != nil {
		return fmt.Errorf("chmod tmp: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("rename: %w", err)
	}
	return nil
}

const apiCooldownDuration = 25 * time.Second

// apiCooldowns records, per account letter, when the usage API last returned
// 429 (#358, item 5).
//
// This used to be a .tui-api-cooldown file in each account state directory.
// Nothing else in the repository reads that file -- no script, no other Go
// package -- and the value lives for 25 seconds, so the filesystem bought
// nothing and cost two things: a read-only state directory made every write
// fail with no signal at all, and the stale files outlived the process that
// wrote them.
//
// Guarded by its own mutex because enrichAPIUsage records a 429 from a
// per-account goroutine while the others are still running.
type apiCooldowns struct {
	mu sync.Mutex
	at map[string]time.Time
}

func newAPICooldowns() *apiCooldowns {
	return &apiCooldowns{at: make(map[string]time.Time)}
}

// active reports whether this account is still inside its backoff window.
func (c *apiCooldowns) active(letter string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	t, ok := c.at[letter]
	return ok && time.Since(t) < apiCooldownDuration
}

// record marks this account as rate-limited as of now.
func (c *apiCooldowns) record(letter string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.at[letter] = time.Now()
}

// clearExpired drops only the entries whose window has elapsed.
func (c *apiCooldowns) clearExpired() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for letter, t := range c.at {
		if time.Since(t) >= apiCooldownDuration {
			delete(c.at, letter)
		}
	}
}

// ClearAPICooldowns drops expired cooldowns so the next refresh retries the
// API for those accounts.
//
// Expired ones only. The `r` key called this unconditionally, which cleared a
// cooldown recorded a second ago and re-issued the call the 429 was telling us
// to stop making -- the 25s backoff existed but any keypress skipped it
// (#358, item 10 is the same defect seen from update.go).
func (m *Manager) ClearAPICooldowns() {
	m.cooldowns.clearExpired()
}
