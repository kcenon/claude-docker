package dashboard

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/kcenon/claude-docker/tui/internal/account"
	"github.com/kcenon/claude-docker/tui/internal/config"
	"github.com/kcenon/claude-docker/tui/internal/ui/components"
)

// renderIsolationBanner names the active workspace trust boundary above the
// account table.
//
// The mode decides whether one account can read or write another's files, and
// this dashboard is where an operator picks an account to attach to, so the
// boundary is stated here rather than left to be inferred from the paths in
// the table. Colour carries the same message as the text: shared is a warning
// tone because it is the weakest boundary, and a mode this build cannot start
// is red.
func renderIsolationBanner(env *config.Env) string {
	mode := env.IsolationMode()

	var colour lipgloss.Color
	switch mode {
	case config.IsolationWorktree:
		colour = lipgloss.Color("#06B6D4")
	case config.IsolationShared:
		colour = lipgloss.Color("#EAB308")
	default:
		// isolated, and any value the shell layers would refuse outright.
		colour = lipgloss.Color("#EF4444")
	}

	label := lipgloss.NewStyle().Bold(true).Foreground(colour).
		Render("  Isolation: " + mode)
	tagline := lipgloss.NewStyle().Foreground(lipgloss.Color("#6B7280")).
		Render("  " + config.IsolationModeTagline(mode))

	return label + tagline + "\n\n"
}

func renderAccountTable(accounts []account.Account, cursor int, width int) string {
	var b strings.Builder

	const (
		colService  = 12
		colStatus   = 10
		colAuth     = 8
		colGH       = 24
		colFiveHour = 22
		colSevenDay = 22
	)

	header := "  " +
		padPlain("SERVICE", colService) +
		padPlain("STATUS", colStatus) +
		padPlain("AUTH", colAuth) +
		padPlain("GITHUB LOGIN", colGH) +
		padPlain("5h USED / LEFT", colFiveHour) +
		padPlain("7d USED / LEFT", colSevenDay)
	b.WriteString(lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#9CA3AF")).
		Render(header) + "\n")

	b.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("#374151")).
		Render("  "+strings.Repeat("─", min(76, width-4))) + "\n")

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
		} else if acct.GHLoginMismatch {
			ghCell = padStyled(acct.GHLogin+" != "+acct.GHExpectedLogin, colGH, styleYellow)
		} else if acct.GHAuthOK {
			ghCell = padStyled(acct.GHLogin, colGH, styleGreen)
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
