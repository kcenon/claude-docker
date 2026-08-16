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
	GHLogin         string
	GHExpectedLogin string
	GHLoginMismatch bool

	// Claude-only fields. These stay zero/nil for runtimes that do not
	// expose a Claude-style OAuth usage endpoint; the dashboard then
	// renders "--" for usage. See #271.
	//
	// There was a Tokens *TokenSummary here as well, described as a
	// "JSONL-derived fallback when limitline is unavailable". The fallback was
	// never implemented: the field was written on every refresh and read only
	// by HasUsageData, which had no caller. Filling it walked
	// ~/.claude-state/account-*/projects/**.jsonl on every refresh and on
	// every --json invocation, for a value nothing rendered. Removed in #358
	// (item 14); the dashboard still shows "--" when limitline has no data,
	// exactly as before.
	FiveHourUsage  *UsageBucket
	SevenDayUsage  *UsageBucket
	APIRateLimited bool   // true when usage API returned 429 recently
	LastAPIStatus  string // debug: last API status ("200", "429", "err: ...", "skipped (cooldown)", "cached")
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
