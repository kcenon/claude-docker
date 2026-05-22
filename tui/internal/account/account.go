// Package account provides the Account domain model and management operations.
package account

// AuthType represents the authentication method for an account.
type AuthType int

const (
	AuthNone   AuthType = iota
	AuthOAuth           // .credentials.json present
	AuthAPIKey          // provider API key set in .env
	AuthLogin           // runtime-specific login state present
)

func (a AuthType) String() string {
	switch a {
	case AuthOAuth:
		return "OAuth"
	case AuthAPIKey:
		return "Key"
	case AuthLogin:
		return "Login"
	default:
		return "--"
	}
}

// ContainerStatus represents the current state of a container.
type ContainerStatus int

const (
	ContainerNotCreated ContainerStatus = iota
	ContainerRunning
	ContainerStopped
)

func (c ContainerStatus) String() string {
	switch c {
	case ContainerRunning:
		return "running"
	case ContainerStopped:
		return "stopped"
	default:
		return "not created"
	}
}

// UsageBucket holds rate limit info from limitline cache.
type UsageBucket struct {
	PercentUsed int
	IsOverLimit bool
	ResetAt     string
}

// TokenSummary holds JSONL-derived token counts (fallback when limitline is unavailable).
type TokenSummary struct {
	InputTokens  int64
	OutputTokens int64
	CacheTokens  int64 // cache_creation + cache_read
	SessionCount int
}

// Total returns the total token count.
func (t TokenSummary) Total() int64 {
	return t.InputTokens + t.OutputTokens + t.CacheTokens
}

// Account represents a single agent account with its runtime state.
type Account struct {
	Letter          string
	ServiceName     string
	Runtime         string // agent runtime name (e.g. "claude", "codex"); set from env.AgentRuntime()
	StateDirPath    string
	AuthType        AuthType
	ContainerStatus ContainerStatus
	ContainerID     string
	GHAuthOK        bool

	// Claude-only fields. These stay zero/nil for runtimes that do not
	// expose a Claude-style OAuth usage endpoint; the dashboard then
	// renders "--" for usage. See #271.
	FiveHourUsage  *UsageBucket
	SevenDayUsage  *UsageBucket
	Tokens         *TokenSummary // JSONL-derived fallback when limitline is unavailable
	APIRateLimited bool          // true when usage API returned 429 recently
	LastAPIStatus  string        // debug: last API status ("200", "429", "err: ...", "skipped (cooldown)", "cached")
}

// HasUsageData returns true if any usage data is available (limitline or JSONL).
func (a *Account) HasUsageData() bool {
	return a.FiveHourUsage != nil || (a.Tokens != nil && a.Tokens.Total() > 0)
}

// IsRunning returns true if the container is running.
func (a *Account) IsRunning() bool {
	return a.ContainerStatus == ContainerRunning
}

// IsOverLimit returns true if any usage bucket is over limit.
func (a *Account) IsOverLimit() bool {
	if a.FiveHourUsage != nil && a.FiveHourUsage.IsOverLimit {
		return true
	}
	if a.SevenDayUsage != nil && a.SevenDayUsage.IsOverLimit {
		return true
	}
	return false
}
