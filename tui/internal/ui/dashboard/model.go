// Package dashboard implements the main dashboard view.
package dashboard

import (
	"fmt"
	"os/exec"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/kcenon/claude-docker/tui/internal/account"
	"github.com/kcenon/claude-docker/tui/internal/docker"
	"github.com/kcenon/claude-docker/tui/internal/ui/components"
)

// Model is the dashboard bubbletea model.
type Model struct {
	manager       *account.Manager
	client        *docker.Client
	accounts      []account.Account
	cursor        int
	width         int
	height        int
	loading       bool
	refreshing    bool      // true while Refresh is in-flight
	tickActive    bool      // true while a 1s tick chain is running (prevents duplicates)
	err           error
	retryCount    int       // number of auto-retries since TUI started
	lastRefreshAt time.Time // time of last refresh completion
	nextRetryAt   time.Time // scheduled time for next auto-retry (zero = no retry pending)
}

// New creates a new dashboard model.
func New(mgr *account.Manager, client *docker.Client) Model {
	return Model{
		manager: mgr,
		client:  client,
		loading: true,
	}
}

type accountsLoadedMsg struct {
	accounts []account.Account
	err      error
}

type sessionFinishedMsg struct{ err error }

type uiTickMsg struct{} // 1-second tick drives both countdown display AND scheduled retry

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

// Update handles messages.
func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	switch msg := msg.(type) {
	case accountsLoadedMsg:
		m.loading = false
		m.refreshing = false
		m.accounts = msg.accounts
		m.err = msg.err
		m.lastRefreshAt = time.Now()
		// If any account is rate-limited, set next retry deadline and start a single 1s tick chain
		if m.hasRateLimitedAccounts() {
			m.nextRetryAt = m.lastRefreshAt.Add(30 * time.Second)
			// Only start a new tick if no chain is currently running
			if !m.tickActive {
				m.tickActive = true
				return m, tea.Tick(time.Second, func(time.Time) tea.Msg {
					return uiTickMsg{}
				})
			}
			return m, nil
		}
		m.nextRetryAt = time.Time{}
		m.tickActive = false
		return m, nil

	case uiTickMsg:
		// If refresh is in-flight, just reschedule without doing anything
		if m.refreshing {
			return m, tea.Tick(time.Second, func(time.Time) tea.Msg {
				return uiTickMsg{}
			})
		}
		// If nextRetryAt has arrived, trigger refresh once
		if !m.nextRetryAt.IsZero() && !time.Now().Before(m.nextRetryAt) {
			m.retryCount++
			m.refreshing = true
			m.nextRetryAt = time.Time{} // clear until refresh completes
			m.manager.ClearAPICooldowns()
			return m, tea.Batch(
				m.Refresh(),
				tea.Tick(time.Second, func(time.Time) tea.Msg {
					return uiTickMsg{}
				}),
			)
		}
		// Still counting down: keep ticking
		if !m.nextRetryAt.IsZero() {
			return m, tea.Tick(time.Second, func(time.Time) tea.Msg {
				return uiTickMsg{}
			})
		}
		// Done — stop the tick chain
		m.tickActive = false
		return m, nil

	case sessionFinishedMsg:
		// After Claude session ends, refresh account list
		return m, m.Refresh()

	case tea.KeyMsg:
		switch msg.String() {
		case "j", "down":
			if m.cursor < len(m.accounts)-1 {
				m.cursor++
			}
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
			}
		case "enter", "c":
			// Attach to selected account's Claude session
			if m.cursor < len(m.accounts) {
				acct := m.accounts[m.cursor]
				if acct.IsRunning() {
					bin, args := m.client.ExecArgs(acct.ServiceName, "claude")
					cmd := exec.Command(bin, args...)
					return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
						return sessionFinishedMsg{err: err}
					})
				}
			}
		case "u":
			client := m.client
			return m, tea.Batch(
				func() tea.Msg {
					client.Up()
					return nil
				},
				m.Refresh(),
			)
		case "d":
			client := m.client
			return m, tea.Batch(
				func() tea.Msg {
					client.Down()
					return nil
				},
				m.Refresh(),
			)
		case "r":
			if m.refreshing {
				return m, nil // already refreshing, ignore
			}
			m.manager.ClearAPICooldowns()
			m.refreshing = true
			m.retryCount++ // manual refresh counts as a retry
			return m, m.Refresh()
		}
	}

	return m, nil
}

// View renders the dashboard.
func (m Model) View() string {
	if m.loading {
		return "  Loading accounts..."
	}
	if m.err != nil {
		return fmt.Sprintf("  Error: %v\n\n  Press [r] to retry", m.err)
	}
	if len(m.accounts) == 0 {
		return "  No accounts configured. Run the installer to set up accounts."
	}

	var b strings.Builder

	b.WriteString(renderAccountTable(m.accounts, m.cursor, m.width))
	b.WriteString("\n")

	runningCount := 0
	for _, a := range m.accounts {
		if a.IsRunning() {
			runningCount++
		}
	}

	actions := lipgloss.NewStyle().Foreground(lipgloss.Color("#6B7280")).
		Render(fmt.Sprintf(
			"  [u] Up all  [d] Down all  [r] Refresh  [Enter] Attach  (%d/%d running)",
			runningCount, len(m.accounts)))
	b.WriteString(actions)


	// API retry status: visible when any account is rate-limited or currently refreshing
	if m.hasRateLimitedAccounts() || m.refreshing {
		var statusText string
		if m.refreshing {
			statusText = fmt.Sprintf("  ⟳ refreshing... (try #%d)", m.retryCount)
		} else {
			nextIn := "soon"
			if !m.nextRetryAt.IsZero() {
				secs := int(time.Until(m.nextRetryAt).Seconds())
				if secs < 0 {
					secs = 0
				}
				nextIn = fmt.Sprintf("%ds", secs)
			}
			statusText = fmt.Sprintf(
				"  ⟳ auto-retry #%d  last: %s  next: %s",
				m.retryCount, m.lastRefreshAt.Format("15:04:05"), nextIn)
		}
		status := lipgloss.NewStyle().Foreground(lipgloss.Color("#EAB308")).
			Render(statusText)
		b.WriteString("\n" + status)

		// Per-account last API status (debug info)
		for _, a := range m.accounts {
			if a.LastAPIStatus != "" {
				detail := lipgloss.NewStyle().Foreground(lipgloss.Color("#6B7280")).
					Render(fmt.Sprintf("    %s: %s", a.ServiceName, a.LastAPIStatus))
				b.WriteString("\n" + detail)
			}
		}
	}

	return b.String()
}

func renderAccountTable(accounts []account.Account, cursor int, width int) string {
	var b strings.Builder

	const (
		colService  = 12
		colStatus   = 10
		colAuth     = 8
		colGH       = 10
		colFiveHour = 22
		colSevenDay = 22
	)

	header := "  " +
		padPlain("SERVICE", colService) +
		padPlain("STATUS", colStatus) +
		padPlain("AUTH", colAuth) +
		padPlain("GH AUTH", colGH) +
		padPlain("5h USED / LEFT", colFiveHour) +
		padPlain("7d USED / LEFT", colSevenDay)
	b.WriteString(lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#9CA3AF")).
		Render(header) + "\n")

	b.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("#374151")).
		Render("  " + strings.Repeat("─", min(76, width-4))) + "\n")

	// Styles
	styleGreen := lipgloss.NewStyle().Foreground(lipgloss.Color("#22C55E"))
	styleRed := lipgloss.NewStyle().Foreground(lipgloss.Color("#EF4444"))
	styleYellow := lipgloss.NewStyle().Foreground(lipgloss.Color("#EAB308"))
	styleMuted := lipgloss.NewStyle().Foreground(lipgloss.Color("#6B7280"))
	styleLabel := lipgloss.NewStyle().Foreground(lipgloss.Color("#9CA3AF"))

	for i, acct := range accounts {
		prefix := "  "
		if i == cursor {
			prefix = "> "
		}

		svcCell := padPlain(acct.ServiceName, colService)

		var statusCell string
		switch acct.ContainerStatus {
		case account.ContainerRunning:
			statusCell = padStyled("running", colStatus, styleGreen)
		case account.ContainerStopped:
			statusCell = padStyled("stopped", colStatus, styleRed)
		default:
			statusCell = padStyled("--", colStatus, styleMuted)
		}

		authCell := padStyled(acct.AuthType.String(), colAuth, styleLabel)

		var ghCell string
		if !acct.IsRunning() {
			ghCell = padStyled("--", colGH, styleMuted)
		} else if acct.GHAuthOK {
			ghCell = padStyled("OK", colGH, styleGreen)
		} else {
			ghCell = padStyled("FAIL", colGH, styleRed)
		}

		var fiveHourCell, sevenDayCell string
		if acct.FiveHourUsage != nil {
			gauge := components.RenderMiniGauge(acct.FiveHourUsage.PercentUsed, 6)
			reset := styleMuted.Render(" " + components.FormatResetIn(acct.FiveHourUsage.ResetAt))
			combined := gauge + reset
			fiveHourCell = combined + ansiPad(combined, colFiveHour)
		} else if acct.APIRateLimited {
			fiveHourCell = padStyled("API limited", colFiveHour, styleYellow)
		} else {
			fiveHourCell = padStyled("--", colFiveHour, styleMuted)
		}

		if acct.SevenDayUsage != nil {
			gauge := components.RenderMiniGauge(acct.SevenDayUsage.PercentUsed, 6)
			reset := styleMuted.Render(" " + components.FormatResetIn(acct.SevenDayUsage.ResetAt))
			combined := gauge + reset
			sevenDayCell = combined + ansiPad(combined, colSevenDay)
		} else if acct.APIRateLimited {
			sevenDayCell = padStyled("API limited", colSevenDay, styleYellow)
		} else {
			sevenDayCell = padStyled("--", colSevenDay, styleMuted)
		}

		row := prefix + svcCell + statusCell + authCell + ghCell + fiveHourCell + sevenDayCell

		if i == cursor {
			row = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#06B6D4")).
				Render(prefix+padPlain(acct.ServiceName, colService)) +
				statusCell + authCell + ghCell + fiveHourCell + sevenDayCell
		}

		b.WriteString(row + "\n")
	}

	return b.String()
}

func padPlain(s string, width int) string {
	if len(s) >= width {
		return s
	}
	return s + strings.Repeat(" ", width-len(s))
}

func padStyled(text string, width int, style lipgloss.Style) string {
	padded := padPlain(text, width)
	return style.Render(padded)
}

func ansiPad(styledStr string, targetWidth int) string {
	visualWidth := lipgloss.Width(styledStr)
	if visualWidth >= targetWidth {
		return ""
	}
	return strings.Repeat(" ", targetWidth-visualWidth)
}

func (m Model) hasRateLimitedAccounts() bool {
	for _, a := range m.accounts {
		if a.APIRateLimited && a.FiveHourUsage == nil {
			return true
		}
	}
	return false
}


func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
