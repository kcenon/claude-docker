package dashboard

import (
	"fmt"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/kcenon/claude-docker/tui/internal/auth"
)

// startGHAuth reads the host gh token, writes it to .env, and — if any
// container is running — queues a recreate handoff so containers pick up
// the new GH_TOKEN. Synchronous .env write is fine (no blocking I/O beyond
// a single file); the slow container restart is done via tea.ExecProcess.
func (m Model) startGHAuth() (Model, tea.Cmd) {
	if m.env == nil {
		m = m.toast("gh-auth: .env not loaded", statusErr)
		return m, m.toastExpireCmd()
	}
	m.busy = true
	client := m.client
	env := m.env
	return m, func() tea.Msg {
		token, err := auth.HostGHToken()
		if err != nil {
			return ghAuthAppliedMsg{err: err}
		}
		env.Set("GH_TOKEN", token)
		if err := env.Save(); err != nil {
			return ghAuthAppliedMsg{err: fmt.Errorf("write .env: %w", err)}
		}
		return ghAuthAppliedMsg{recreateNeeded: client.HasRunningContainers()}
	}
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
