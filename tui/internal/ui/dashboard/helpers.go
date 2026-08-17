package dashboard

import (
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/kcenon/claude-docker/tui/internal/auth"
	"github.com/kcenon/claude-docker/tui/internal/config"
)

var hostGHToken = auth.HostGHToken

// startGHAuth reads the selected host gh token, writes only its matching .env
// key, and queues the narrowest recreate needed for running containers.
func (m Model) startGHAuth() (Model, tea.Cmd) {
	if m.env == nil {
		m = m.toast("gh-auth: .env not loaded", statusErr)
		return m, m.toastExpireCmd()
	}
	// Refuse before fetching a token. Save would refuse anyway, but reaching
	// it means a live GitHub token was pulled onto this machine for a write
	// that cannot happen -- and the user would read the failure as a gh
	// problem rather than a .env one (#358, item 7).
	if !m.env.CanPersist() {
		m = m.toast("gh-auth: .env could not be read; fix it and restart", statusErr)
		return m, m.toastExpireCmd()
	}
	mode := m.env.GitHubAuthMode()
	if mode != config.GHAuthShared && mode != config.GHAuthPerAccount {
		m = m.toast("gh-auth: GH_AUTH_MODE must be shared or per-account", statusErr)
		return m, m.toastExpireCmd()
	}
	m.busy = true
	client := m.client
	env := m.env
	user := ""
	key := "GH_TOKEN"
	label := "shared"
	var services []string
	if mode == config.GHAuthPerAccount {
		if m.cursor >= len(m.accounts) {
			m.busy = false
			m = m.toast("gh-auth: no account selected", statusErr)
			return m, m.toastExpireCmd()
		}
		acct := m.accounts[m.cursor]
		user = env.GHUser(acct.Letter)
		if user == "" {
			m.busy = false
			m = m.toast("gh-auth: GH_USER_"+strings.ToUpper(acct.Letter)+" is not configured", statusErr)
			return m, m.toastExpireCmd()
		}
		key = env.GHTokenKey(acct.Letter)
		label = acct.ServiceName + " (" + user + ")"
		if acct.IsRunning() {
			services = []string{acct.ServiceName}
		}
	}
	return m, func() tea.Msg {
		token, err := hostGHToken(user)
		if err != nil {
			return ghAuthAppliedMsg{err: err}
		}
		env.Set(key, token)
		if err := env.Save(); err != nil {
			return ghAuthAppliedMsg{err: fmt.Errorf("write .env: %w", err)}
		}
		recreate := len(services) > 0
		if mode == config.GHAuthShared {
			recreate = client.HasRunningContainers()
		}
		return ghAuthAppliedMsg{recreateNeeded: recreate, services: services, label: label}
	}
}

// composeErr reports a compose prefix that could not be resolved and returns
// the dashboard to an idle state.
//
// BuildComposeArgs fails when ISOLATION_MODE names an overlay that is not on
// disk, or names nothing recognizable. Both mean the containers this key would
// start would not have the boundary the operator configured, so the operation
// is abandoned here rather than handed to docker. Clearing busy matters as
// much as the message: every caller sits on a key handler that has already
// committed to an operation, and leaving the flag set wedges the dashboard.
func (m Model) composeErr(op string, err error) (Model, tea.Cmd) {
	m.busy = false
	m = m.toast(op+": "+err.Error(), statusErr)
	return m, m.toastExpireCmd()
}

// toast returns a copy of the model with a transient status message set.
// Callers should chain toastExpireCmd() so the message auto-clears.
func (m Model) toast(text string, level statusLevel) Model {
	m.statusText = text
	m.statusLevel = level
	m.statusExpiry = time.Now().Add(statusTTL)
	return m
}

// toastExpireCmd schedules a statusExpiredMsg after statusTTL.
func (m Model) toastExpireCmd() tea.Cmd {
	return tea.Tick(statusTTL, func(time.Time) tea.Msg {
		return statusExpiredMsg{}
	})
}

func levelOf(err error) statusLevel {
	if err != nil {
		return statusErr
	}
	return statusOK
}

func opResultText(name string, err error) string {
	if err != nil {
		return fmt.Sprintf("%s failed: %v", name, err)
	}
	return name + " completed"
}

func (m Model) hasRateLimitedAccounts() bool {
	for _, a := range m.accounts {
		if a.APIRateLimited && a.FiveHourUsage == nil {
			return true
		}
	}
	return false
}
