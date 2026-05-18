// Package dashboard implements the main dashboard view.
package dashboard

import (
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/kcenon/claude-docker/tui/internal/account"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
)

// opKind identifies which multi-stage operation is in flight, so callbacks
// returning from tea.ExecProcess know what to do next.
type opKind int

const (
	opNone opKind = iota
	opUp
	opDown
	opBuild
	opBuildNoCache
	opUpdateBuild    // step 1 of update chain
	opUpdateRecreate // step 2 of update chain
	opRestart
	opGHAuthRecreate
)

// statusLevel controls toast color.
type statusLevel int

const (
	statusInfo statusLevel = iota
	statusOK
	statusErr
)

// statusTTL is how long a toast stays on screen before auto-clearing.
const statusTTL = 5 * time.Second

// Model is the dashboard bubbletea model.
type Model struct {
	manager       *account.Manager
	client        *docker.Client
	env           *config.Env
	accounts      []account.Account
	cursor        int
	width         int
	height        int
	loading       bool
	refreshing    bool // true while Refresh is in-flight
	tickActive    bool // true while a 1s tick chain is running (prevents duplicates)
	err           error
	retryCount    int       // number of auto-retries since TUI started
	lastRefreshAt time.Time // time of last refresh completion
	nextRetryAt   time.Time // scheduled time for next auto-retry (zero = no retry pending)

	// Action state (Docker rebuild / gh-auth / restart).
	busy            bool        // true while a background op is running
	showHelp        bool        // ? toggles a key-map overlay
	skipPermissions bool        // pass the runtime-specific permission bypass flag
	statusText      string      // last toast message
	statusLevel     statusLevel // toast color
	statusExpiry    time.Time   // when the toast should disappear
}

// New creates a new dashboard model.
func New(mgr *account.Manager, client *docker.Client, env *config.Env, skipPermissions bool) Model {
	return Model{
		manager:         mgr,
		client:          client,
		env:             env,
		loading:         true,
		skipPermissions: skipPermissions,
	}
}

// Init starts the initial data load.
// Clears any stale API cooldowns so the first refresh attempts the API fresh.
func (m Model) Init() tea.Cmd {
	m.manager.ClearAPICooldowns()
	return m.Refresh()
}

// Refresh triggers a data reload.
func (m Model) Refresh() tea.Cmd {
	mgr := m.manager
	return func() tea.Msg {
		accounts, err := mgr.ListAccounts()
		return accountsLoadedMsg{accounts: accounts, err: err}
	}
}

// SetSize updates the available rendering area.
func (m *Model) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// AccountCount returns the number of loaded accounts.
func (m Model) AccountCount() int {
	return len(m.accounts)
}
