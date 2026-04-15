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
	"github.com/kcenon/claude-docker/tui/internal/auth"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/docker"
	"github.com/kcenon/claude-docker/tui/internal/ui/components"
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
	opUpdateBuild   // step 1 of update chain
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
	refreshing    bool      // true while Refresh is in-flight
	tickActive    bool      // true while a 1s tick chain is running (prevents duplicates)
	err           error
	retryCount    int       // number of auto-retries since TUI started
	lastRefreshAt time.Time // time of last refresh completion
	nextRetryAt   time.Time // scheduled time for next auto-retry (zero = no retry pending)

	// Action state (Docker rebuild / gh-auth / restart).
	busy         bool        // true while a background op is running
	showHelp     bool        // ? toggles a key-map overlay
	statusText   string      // last toast message
	statusLevel  statusLevel // toast color
	statusExpiry time.Time   // when the toast should disappear
}

// New creates a new dashboard model.
func New(mgr *account.Manager, client *docker.Client, env *config.Env) Model {
	return Model{
		manager: mgr,
		client:  client,
		env:     env,
		loading: true,
	}
}

type accountsLoadedMsg struct {
	accounts []account.Account
	err      error
}

type sessionFinishedMsg struct{ err error }

type uiTickMsg struct{} // 1-second tick drives both countdown display AND scheduled retry

// dockerOpDoneMsg arrives after a tea.ExecProcess handoff returns.
// kind lets the reducer decide whether to chain to the next stage
// (e.g. build → recreate during `U` update).
type dockerOpDoneMsg struct {
	kind opKind
	err  error
}

// ghAuthAppliedMsg is emitted after the gh-token write step completes.
// recreateNeeded = true triggers a follow-up `up -d --force-recreate` handoff.
type ghAuthAppliedMsg struct {
	err            error
	recreateNeeded bool
}

// statusExpiredMsg clears any stale toast once its TTL has passed.
type statusExpiredMsg struct{}

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

	case dockerOpDoneMsg:
		m.busy = false
		switch msg.kind {
		case opUp:
			m = m.toast(opResultText("Up", msg.err), levelOf(msg.err))
		case opDown:
			m = m.toast(opResultText("Down", msg.err), levelOf(msg.err))
		case opBuild:
			m = m.toast(opResultText("Build", msg.err), levelOf(msg.err))
		case opBuildNoCache:
			m = m.toast(opResultText("Rebuild (no-cache)", msg.err), levelOf(msg.err))
		case opRestart:
			m = m.toast(opResultText("Restart", msg.err), levelOf(msg.err))
		case opUpdateBuild:
			if msg.err != nil {
				m = m.toast(opResultText("Update (build)", msg.err), statusErr)
				return m, m.toastExpireCmd()
			}
			// Chain into recreate stage.
			m.busy = true
			bin, args := m.client.UpRecreateArgs()
			cmd := exec.Command(bin, args...)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return dockerOpDoneMsg{kind: opUpdateRecreate, err: err}
			})
		case opUpdateRecreate:
			m = m.toast(opResultText("Update", msg.err), levelOf(msg.err))
		case opGHAuthRecreate:
			m = m.toast(opResultText("GitHub auth + recreate", msg.err), levelOf(msg.err))
		}
		return m, tea.Batch(m.Refresh(), m.toastExpireCmd())

	case ghAuthAppliedMsg:
		if msg.err != nil {
			m.busy = false
			m = m.toast("gh-auth: "+msg.err.Error(), statusErr)
			return m, m.toastExpireCmd()
		}
		if !msg.recreateNeeded {
			m.busy = false
			m = m.toast("GitHub token written to .env (no running containers)", statusOK)
			return m, tea.Batch(m.Refresh(), m.toastExpireCmd())
		}
		// Containers are running — recreate them so the new GH_TOKEN takes effect.
		bin, args := m.client.UpRecreateArgs()
		cmd := exec.Command(bin, args...)
		return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
			return dockerOpDoneMsg{kind: opGHAuthRecreate, err: err}
		})

	case statusExpiredMsg:
		if !m.statusExpiry.IsZero() && !time.Now().Before(m.statusExpiry) {
			m.statusText = ""
			m.statusExpiry = time.Time{}
		}
		return m, nil

	case tea.KeyMsg:
		// When a background/blocking op is in flight, ignore everything except quit.
		if m.busy {
			return m, nil
		}
		// Help overlay is modal: any key other than quit closes it.
		if m.showHelp {
			m.showHelp = false
			return m, nil
		}

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
			m.busy = true
			m = m.toast("Starting containers (docker compose up -d)...", statusInfo)
			client := m.client
			return m, func() tea.Msg {
				err := client.Up()
				return dockerOpDoneMsg{kind: opUp, err: err}
			}
		case "d":
			m.busy = true
			m = m.toast("Stopping containers (docker compose down)...", statusInfo)
			client := m.client
			return m, func() tea.Msg {
				err := client.Down()
				return dockerOpDoneMsg{kind: opDown, err: err}
			}
		case "r":
			if m.refreshing {
				return m, nil // already refreshing, ignore
			}
			m.manager.ClearAPICooldowns()
			m.refreshing = true
			m.retryCount++ // manual refresh counts as a retry
			return m, m.Refresh()

		case "b":
			m.busy = true
			bin, args := m.client.BuildArgs(false)
			cmd := exec.Command(bin, args...)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return dockerOpDoneMsg{kind: opBuild, err: err}
			})

		case "B":
			m.busy = true
			bin, args := m.client.BuildArgs(true)
			cmd := exec.Command(bin, args...)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return dockerOpDoneMsg{kind: opBuildNoCache, err: err}
			})

		case "U":
			// Two-stage chain: build --no-cache → up -d --force-recreate.
			m.busy = true
			bin, args := m.client.BuildArgs(true)
			cmd := exec.Command(bin, args...)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return dockerOpDoneMsg{kind: opUpdateBuild, err: err}
			})

		case "R":
			if m.cursor >= len(m.accounts) {
				return m, nil
			}
			svc := m.accounts[m.cursor].ServiceName
			m.busy = true
			bin, args := m.client.RestartArgs(svc)
			cmd := exec.Command(bin, args...)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return dockerOpDoneMsg{kind: opRestart, err: err}
			})

		case "g":
			return m.startGHAuth()

		case "?":
			m.showHelp = true
			return m, nil
		}
	}

	return m, nil
}

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

	if m.showHelp {
		return renderHelp()
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

	actionsText := fmt.Sprintf(
		"  [u] Up  [d] Down  [r] Refresh  [Enter] Attach  [?] Keys  (%d/%d running)",
		runningCount, len(m.accounts))
	if m.busy {
		actionsText = "  Busy... (keys disabled; see status below)"
	}
	actions := lipgloss.NewStyle().Foreground(lipgloss.Color("#6B7280")).
		Render(actionsText)
	b.WriteString(actions)

	if m.statusText != "" {
		var color lipgloss.Color
		switch m.statusLevel {
		case statusOK:
			color = lipgloss.Color("#22C55E")
		case statusErr:
			color = lipgloss.Color("#EF4444")
		default:
			color = lipgloss.Color("#06B6D4")
		}
		toast := lipgloss.NewStyle().Foreground(color).Render("  " + m.statusText)
		b.WriteString("\n" + toast)
	}


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

// renderHelp shows the key-map overlay (dismissed by any key).
func renderHelp() string {
	title := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#06B6D4")).
		Render("  Keybindings")
	key := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#E5E7EB"))
	desc := lipgloss.NewStyle().Foreground(lipgloss.Color("#9CA3AF"))

	rows := [][2]string{
		{"j / k", "Move cursor down / up"},
		{"Enter / c", "Attach to selected account's claude session"},
		{"r", "Refresh dashboard"},
		{"u / d", "docker compose up -d / down (all)"},
		{"b", "docker compose build (cached)"},
		{"B", "docker compose build --no-cache"},
		{"U", "Full update: rebuild --no-cache + force-recreate"},
		{"R", "Restart the selected container"},
		{"g", "Inject host gh token into .env (+ recreate)"},
		{"?", "Toggle this help"},
		{"q / Ctrl+C", "Quit"},
	}

	var b strings.Builder
	b.WriteString(title + "\n\n")
	for _, row := range rows {
		b.WriteString("  " + key.Render(padPlain(row[0], 12)) + "  " + desc.Render(row[1]) + "\n")
	}
	b.WriteString("\n" + desc.Render("  Press any key to close."))
	return b.String()
}
