package dashboard

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/kcenon/claude-docker/tui/internal/account"
	"github.com/kcenon/claude-docker/tui/internal/ui/components"
)

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
