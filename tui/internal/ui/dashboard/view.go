package dashboard

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/kcenon/claude-docker/tui/internal/config"
)

// View renders the dashboard.
func (m Model) View() string {
	if m.loading {
		return "  Loading accounts..."
	}
	// Three outcomes, three screens (#358, item 9). ListAccounts used to
	// return a nil error unconditionally, so this branch had no writer and a
	// dead docker daemon was indistinguishable from an install whose
	// containers had simply never been created -- two states whose fix is
	// entirely different.
	//
	// The error screen is only for the case with nothing else to draw. When
	// accounts were discovered from the state directories, they are worth
	// showing even though their container column is unknown, so the table
	// wins and the error becomes the banner below it.
	if m.err != nil && len(m.accounts) == 0 {
		return fmt.Sprintf("  Error: %v\n\n  Press [r] to retry", m.err)
	}
	if len(m.accounts) == 0 {
		return "  No accounts configured. Run the installer to set up accounts."
	}

	if m.showHelp {
		return renderHelp(m.env)
	}

	var b strings.Builder

	b.WriteString(renderIsolationBanner(m.env))

	// A degraded listing, drawn above the table it degrades. The STATUS
	// column reads "--" for every row in this state, which on its own looks
	// like "not created yet"; this line is what separates the two.
	if m.err != nil {
		b.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("#EF4444")).
			Render(fmt.Sprintf("  Warning: %v", m.err)) + "\n\n")
	}

	b.WriteString(renderAccountTable(m.accounts, m.cursor, m.width))
	b.WriteString("\n")

	runningCount := 0
	for _, a := range m.accounts {
		if a.IsRunning() {
			runningCount++
		}
	}

	actionsText := fmt.Sprintf(
		"  [u] Up  [d] Down  [r] Refresh  [Enter] Attach  [p] Perms  [?] Keys  (%d/%d running)",
		runningCount, len(m.accounts))
	if m.busy {
		actionsText = "  Busy... (keys disabled; see status below)"
	}
	actions := lipgloss.NewStyle().Foreground(lipgloss.Color("#6B7280")).
		Render(actionsText)
	if m.skipPermissions {
		actions += lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#EAB308")).
			Render("  [SKIP-PERMS]")
	}
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

// renderHelp shows the key-map overlay (dismissed by any key).
func renderHelp(env *config.Env) string {
	title := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#06B6D4")).
		Render("  Keybindings")
	key := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#E5E7EB"))
	desc := lipgloss.NewStyle().Foreground(lipgloss.Color("#9CA3AF"))
	runtime := env.RuntimeBinary()
	skipFlag := env.SkipPermissionsFlag()

	ghDescription := "Inject the active host gh token into .env (+ recreate)"
	if env.GitHubAuthMode() == config.GHAuthPerAccount {
		ghDescription = "Refresh selected account's configured host gh login"
	}
	rows := [][2]string{
		{"j / k", "Move cursor down / up"},
		{"Enter / c", "Attach to selected account's " + runtime + " session"},
		{"p", "Toggle " + skipFlag},
		{"r", "Refresh dashboard"},
		{"u / d", "docker compose up -d / down (all)"},
		{"b", "docker compose build (cached)"},
		{"B", "docker compose build --no-cache"},
		{"U", "Full update: rebuild --no-cache + force-recreate"},
		{"R", "Restart the selected container"},
		{"g", ghDescription},
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
