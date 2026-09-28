package dashboard

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

func padPlain(s string, width int) string {
	visual := lipgloss.Width(s)
	if visual >= width {
		return s
	}
	return s + strings.Repeat(" ", width-visual)
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

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
