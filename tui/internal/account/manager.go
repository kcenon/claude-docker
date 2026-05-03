package account

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/kcenon/claude-docker/tui/internal/auth"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
)

// Manager provides CRUD operations on accounts.
type Manager struct {
	env    *config.Env
	client *docker.Client
}

// NewManager creates an account manager.
func NewManager(env *config.Env, client *docker.Client) *Manager {
	return &Manager{env: env, client: client}
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

func detectAuthType(sd config.StateDir, env *config.Env, letter string) AuthType {
	if sd.HasCredentials() {
		return AuthOAuth
	}
	if env.APIKey(letter) != "" {
		return AuthAPIKey
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

// writeLimitlineCache writes API response to disk in the same format as claude-limitline.
func writeLimitlineCache(path string, resp *auth.UsageAPIResponse) {
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
		return
	}
	os.WriteFile(path, data, 0644)
}

const apiCooldownFile = ".tui-api-cooldown"
const apiCooldownDuration = 25 * time.Second

// isAPICooldownActive returns true if the API was recently rate-limited
// and we should skip retrying for this account.
func isAPICooldownActive(stateDirPath string) bool {
	data, err := os.ReadFile(filepath.Join(stateDirPath, apiCooldownFile))
	if err != nil {
		return false
	}
	ts, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return false
	}
	return time.Since(time.UnixMilli(ts)) < apiCooldownDuration
}

// writeAPICooldown records that the API returned 429 for this account.
func writeAPICooldown(stateDirPath string) {
	ts := fmt.Sprintf("%d", time.Now().UnixMilli())
	os.WriteFile(filepath.Join(stateDirPath, apiCooldownFile), []byte(ts), 0644)
}

// ClearAPICooldowns removes all API cooldown files so the next refresh retries the API.
func (m *Manager) ClearAPICooldowns() {
	stateDirs, _ := config.DiscoverStateDirs()
	for _, sd := range stateDirs {
		os.Remove(filepath.Join(sd.Path, apiCooldownFile))
	}
}
