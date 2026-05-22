package account

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"sync"

	"github.com/kcenon/claude-docker/tui/internal/auth"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
	"github.com/kcenon/claude-docker/tui/internal/usage"
)

// Helpers for ListAccounts. The orchestrator in manager.go calls these in
// sequence; each helper owns one phase of the listing workflow and is
// independently unit-tested in manager_helpers_test.go.

// discoverStateDirs enumerates account state directories and returns them
// keyed by letter, alongside the effective account count (NUM_ACCOUNTS or
// the highest discovered letter index, whichever is larger).
func (m *Manager) discoverStateDirs() (map[string]config.StateDir, int) {
	n := m.env.NumAccounts()
	dirs, _ := config.DiscoverStateDirsForRuntime(m.env.AgentRuntime())
	stateDirMap := make(map[string]config.StateDir, len(dirs))
	for _, sd := range dirs {
		stateDirMap[sd.Letter] = sd
		// Auto-detect accounts: extend n to cover discovered state dirs.
		if idx := config.LetterToIndex(sd.Letter); idx > n {
			n = idx
		}
	}
	return stateDirMap, n
}

// fetchContainerStatus queries docker compose and returns container info
// keyed by service name. A docker error degrades to an empty map so listing
// still works when the daemon is unreachable.
func (m *Manager) fetchContainerStatus() map[string]docker.ContainerInfo {
	containers, _ := m.client.PS()
	out := make(map[string]docker.ContainerInfo, len(containers))
	for _, c := range containers {
		out[c.Service] = c
	}
	return out
}

// buildAccounts constructs the Account skeletons for indexes 1..n with
// state-dir resolution, auth type, limitline cache, JSONL token summary,
// and container status applied.
func (m *Manager) buildAccounts(n int, stateDirs map[string]config.StateDir, containerMap map[string]docker.ContainerInfo) []Account {
	accounts := make([]Account, n)
	runtime := m.env.AgentRuntime()
	servicePrefix := m.env.ServicePrefix()
	claudeUsage := m.env.SupportsClaudeUsage()
	for i := 1; i <= n; i++ {
		letter := config.IndexToLetter(i)
		svcName := servicePrefix + "-" + letter

		acct := Account{
			Letter:      letter,
			ServiceName: svcName,
			Runtime:     runtime,
		}

		if sd, ok := stateDirs[letter]; ok {
			acct.StateDirPath = sd.Path
			acct.AuthType = detectAuthType(sd, m.env, letter)

			// Parse Claude limitline cache for usage data (this account's own cache).
			if claudeUsage && sd.HasLimitlineCache() {
				acct.FiveHourUsage, acct.SevenDayUsage = parseLimitlineCache(sd.LimitlineCachePath())
			}

			// JSONL token summary (always populated when session data exists).
			// Uses the manager-scoped cache so unchanged session files are
			// not re-read and re-decoded on every dashboard refresh.
			if claudeUsage {
				if sessions, err := usage.ScanAccountSessionsWithCache(sd.ProjectsDir(), m.usageCache); err == nil && len(sessions) > 0 {
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
		}

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
	return accounts
}

// apiResult captures a successful API usage response so writeCacheUpdates
// can persist it to disk. Stored per letter to keep the writer pure.
type apiResult struct {
	stateDirPath string
	resp         *auth.UsageAPIResponse
}

// enrichAccounts performs the parallel enrichment phase: GH auth check on
// running containers and API usage fetch for OAuth accounts whose limitline
// cache is stale or missing. Returns a map of successful API responses,
// indexed by account letter, for downstream cache persistence.
func (m *Manager) enrichAccounts(accounts []Account) map[string]apiResult {
	results := make(map[string]apiResult)
	var resultsMu sync.Mutex
	var wg sync.WaitGroup

	for i := range accounts {
		acct := &accounts[i]
		m.enrichGHAuth(acct, &wg)
		m.enrichAPIUsage(acct, results, &resultsMu, &wg)
	}
	wg.Wait()
	return results
}

// enrichGHAuth runs `gh auth status` inside the account's running container
// and sets GHAuthOK on success. No-op when the container is not running.
func (m *Manager) enrichGHAuth(a *Account, wg *sync.WaitGroup) {
	if a.ContainerStatus != ContainerRunning || a.ContainerID == "" {
		return
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		cmd := exec.Command("docker", "exec", a.ContainerID, "gh", "auth", "status")
		out, _ := cmd.CombinedOutput()
		if strings.Contains(string(out), "Logged in") {
			a.GHAuthOK = true
		}
	}()
}

// enrichAPIUsage fetches usage from the limitline API for OAuth accounts
// when the on-disk cache is stale or missing. Honors the per-account
// cooldown so we don't hammer the API after a 429. Successful responses
// are recorded in results for writeCacheUpdates to persist.
func (m *Manager) enrichAPIUsage(a *Account, results map[string]apiResult, mu *sync.Mutex, wg *sync.WaitGroup) {
	if m.env != nil && !m.env.SupportsClaudeUsage() {
		return
	}
	if a.AuthType != AuthOAuth || a.StateDirPath == "" {
		return
	}
	if a.FiveHourUsage != nil {
		a.LastAPIStatus = "cached (fresh)"
		return
	}
	if isAPICooldownActive(a.StateDirPath) {
		a.APIRateLimited = true
		a.LastAPIStatus = "skipped (cooldown active)"
		return
	}

	wg.Add(1)
	go func() {
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
		mu.Lock()
		results[a.Letter] = apiResult{stateDirPath: a.StateDirPath, resp: apiResp}
		mu.Unlock()
	}()
}

// writeCacheUpdates persists successful API responses to disk so the next
// listing can read from the limitline cache instead of hitting the API.
// Failures here are intentionally swallowed: cache writes are best-effort
// and must not fail the listing.
func (m *Manager) writeCacheUpdates(accounts []Account, results map[string]apiResult) {
	for _, a := range accounts {
		r, ok := results[a.Letter]
		if !ok {
			continue
		}
		sd := config.StateDir{Letter: a.Letter, Path: r.stateDirPath}
		writeLimitlineCache(sd.LimitlineCachePath(), r.resp)
	}
}
