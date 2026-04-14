package account

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
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
}

// NewManager creates an account manager.
func NewManager(env *config.Env, client *docker.Client) *Manager {
	return &Manager{env: env, client: client}
}

// ListAccounts returns all configured accounts with enriched runtime status.
func (m *Manager) ListAccounts() ([]Account, error) {
	n := m.env.NumAccounts()

	// Get state dirs
	stateDirs, _ := config.DiscoverStateDirs()
	stateDirMap := make(map[string]config.StateDir)
	for _, sd := range stateDirs {
		stateDirMap[sd.Letter] = sd
		// Auto-detect accounts: extend n to cover discovered state dirs
		if idx := config.LetterToIndex(sd.Letter); idx > n {
			n = idx
		}
	}

	// Get container status
	containers, _ := m.client.PS()
	containerMap := make(map[string]docker.ContainerInfo)
	for _, c := range containers {
		containerMap[c.Service] = c
	}

	accounts := make([]Account, n)
	for i := 1; i <= n; i++ {
		letter := config.IndexToLetter(i)
		svcName := "claude-" + letter

		acct := Account{
			Letter:      letter,
			ServiceName: svcName,
		}

		// Resolve state directory
		if sd, ok := stateDirMap[letter]; ok {
			acct.StateDirPath = sd.Path
			acct.AuthType = detectAuthType(sd, m.env, letter)

			// Parse limitline cache for usage data (only from this account's own cache)
			if sd.HasLimitlineCache() {
				acct.FiveHourUsage, acct.SevenDayUsage = parseLimitlineCache(sd.LimitlineCachePath())
			}

			// JSONL token summary (always populated when data exists)
			if sessions, err := usage.ScanAccountSessions(sd.ProjectsDir()); err == nil && len(sessions) > 0 {
				opts := usage.AllTimeOptions()
				tokens := usage.AggregateSessions(sessions, opts)
				count := usage.CountFilteredSessions(sessions, opts)
				acct.Tokens = &TokenSummary{
					InputTokens:  tokens.InputTokens,
					OutputTokens: tokens.OutputTokens,
					CacheTokens:  tokens.CacheCreationInputTokens + tokens.CacheReadInputTokens,
					SessionCount: count,
				}
			}
		}

		// Resolve container status
		if ci, ok := containerMap[svcName]; ok {
			acct.ContainerID = ci.ID
			switch strings.ToLower(ci.State) {
			case "running":
				acct.ContainerStatus = ContainerRunning
			default:
				acct.ContainerStatus = ContainerStopped
			}
		}

		accounts[i-1] = acct
	}

	// Parallel enrichment: GH auth check + API usage fetch for accounts missing limitline
	var wg sync.WaitGroup
	for i := range accounts {
		acct := &accounts[i]

		// GH auth check (running containers only)
		if acct.ContainerStatus == ContainerRunning && acct.ContainerID != "" {
			wg.Add(1)
			go func(a *Account) {
				defer wg.Done()
				cmd := exec.Command("docker", "exec", a.ContainerID, "gh", "auth", "status")
				out, _ := cmd.CombinedOutput()
				if strings.Contains(string(out), "Logged in") {
					a.GHAuthOK = true
				}
			}(acct)
		}

		// Fetch usage from API when limitline cache is missing but credentials exist.
		// Skip if API was recently rate-limited (short cooldown per account).
		if acct.AuthType == AuthOAuth && acct.StateDirPath != "" {
			if acct.FiveHourUsage != nil {
				acct.LastAPIStatus = "cached (fresh)"
			} else if isAPICooldownActive(acct.StateDirPath) {
				acct.APIRateLimited = true
				acct.LastAPIStatus = "skipped (cooldown active)"
			} else {
				wg.Add(1)
				go func(a *Account) {
					defer wg.Done()
					sd := config.StateDir{Letter: a.Letter, Path: a.StateDirPath}
					token, err := auth.ReadOAuthToken(sd.CredentialsPath())
					if err != nil {
						a.LastAPIStatus = fmt.Sprintf("token err: %v", err)
						return
					}
					apiResp, err := auth.FetchUsage(token)
					if err != nil {
						var rlErr *auth.RateLimitError
						if errors.As(err, &rlErr) {
							writeAPICooldown(a.StateDirPath)
							a.APIRateLimited = true
							a.LastAPIStatus = "HTTP 429 (rate limited)"
						} else {
							a.LastAPIStatus = fmt.Sprintf("err: %v", err)
						}
						return
					}
					a.LastAPIStatus = "HTTP 200 (fresh)"
					if apiResp.FiveHour != nil {
						a.FiveHourUsage = &UsageBucket{
							PercentUsed: int(apiResp.FiveHour.Utilization),
							IsOverLimit: apiResp.FiveHour.Utilization >= 100,
							ResetAt:     apiResp.FiveHour.ResetsAt,
						}
					}
					if apiResp.SevenDay != nil {
						a.SevenDayUsage = &UsageBucket{
							PercentUsed: int(apiResp.SevenDay.Utilization),
							IsOverLimit: apiResp.SevenDay.Utilization >= 100,
							ResetAt:     apiResp.SevenDay.ResetsAt,
						}
					}
					// Cache to disk so future loads don't need API
					writeLimitlineCache(sd.LimitlineCachePath(), apiResp)
				}(acct)
			}
		}
	}
	wg.Wait()

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
